import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:iceibank_app/models/conta.dart';
import 'package:iceibank_app/models/operacao_pendente.dart';
import 'package:iceibank_app/services/api_client.dart';
import 'package:iceibank_app/services/armazenamento_local.dart';
import 'package:iceibank_app/services/sessao.dart';
import 'package:iceibank_app/services/sincronizador.dart';

/// Testes da Parte F, sem rede e sem plugin de conectividade: o MockClient faz
/// o papel da agencia e o armazenamento usa os valores falsos do
/// shared_preferences.
void main() {
  http.Response json(int status, Object corpo) => http.Response.bytes(
        utf8.encode(jsonEncode(corpo)),
        status,
        headers: {'content-type': 'application/json'},
      );

  // Conta 3 -> agencia 0. Saldo 100, vetor [5, 0, 0] na ultima leitura.
  const conta3 = Conta(id: 3, nomeAluno: 'Ana', saldo: 100, vetorAtual: [5, 0, 0]);

  late ArmazenamentoLocal armazenamento;
  late List<Map<String, dynamic>> enviados;
  late List<AvisoSincronizacao> avisos;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    armazenamento = await ArmazenamentoLocal.abrir();
    await armazenamento.salvarConta(conta3);
    enviados = [];
    avisos = [];
  });

  Sincronizador criar(Future<http.Response> Function(Map<String, dynamic> corpo) agencia) {
    final cliente = MockClient((requisicao) async {
      final corpo = jsonDecode(requisicao.body) as Map<String, dynamic>;
      enviados.add(corpo);
      return agencia(corpo);
    });
    final sincronizador = Sincronizador(
      ApiClient(Sessao(token: 'x'), cliente: cliente),
      armazenamento,
      conectividade: const Stream.empty(),
    );
    sincronizador.avisos.listen(avisos.add);
    return sincronizador;
  }

  Future<void> esvaziarEventos() => Future<void>.delayed(Duration.zero);

  test('operacao offline guarda o vetor do cache e entra no saldo provisorio', () async {
    final s = criar((_) async => throw http.ClientException('offline'));

    final op = await s.registrarOffline(3, tipoDeposito, 50);

    expect(op.vetorConhecido, [5, 0, 0]);
    expect(s.saldoProvisorio(3), 150);
    expect(s.agenciaSemResposta(0), isTrue);
    // A fila sobrevive a um "reinicio" do app.
    final relida = await ArmazenamentoLocal.abrir();
    expect(relida.lerFila().single.valor, 50);
    s.dispose();
  });

  test('saque offline maior que o saldo provisorio nem entra na fila', () async {
    final s = criar((_) async => throw http.ClientException('offline'));

    await expectLater(s.registrarOffline(3, tipoSaque, 150), throwsA(isA<OperacaoOfflineInvalida>()));
    expect(s.fila, isEmpty);
    s.dispose();
  });

  test('sem conexao na sincronizacao: a fila e mantida', () async {
    final s = criar((_) async => throw http.ClientException('offline'));
    await s.registrarOffline(3, tipoDeposito, 50);

    await s.sincronizar();

    expect(s.fila, hasLength(1));
    expect(s.fila.single.estado, EstadoOperacao.pendente);
    s.dispose();
  });

  test('duas operacoes: a segunda usa o vetor devolvido pela primeira', () async {
    var vetor = [5, 0, 0];
    var saldo = 100.0;
    final s = criar((corpo) async {
      final conhecido = (corpo['vetorConhecido'] as List).cast<int>();
      if (conhecido.join() != vetor.join()) {
        return json(409, {'erro': 'Conflito', 'vetorAtual': vetor, 'contaAtual': {'id': 3, 'nomeAluno': 'Ana', 'saldo': saldo}});
      }
      vetor = [vetor[0] + 1, 0, 0];
      saldo += (corpo['tipo'] == tipoSaque ? -1 : 1) * (corpo['valor'] as num).toDouble();
      return json(200, {'id': 3, 'nomeAluno': 'Ana', 'saldo': saldo, 'vetorAtual': vetor});
    });
    await s.registrarOffline(3, tipoDeposito, 50);
    await s.registrarOffline(3, tipoSaque, 30);

    await s.sincronizar();
    await esvaziarEventos();

    expect(enviados.map((c) => c['vetorConhecido']), [
      [5, 0, 0],
      [6, 0, 0],
    ]);
    expect(s.fila, isEmpty);
    expect(s.contaEmCache(3)!.conta.saldo, 120);
    expect(avisos.last.texto, contains('2 operações'));
    s.dispose();
  });

  test('409 em deposito: reaplicado automaticamente com o vetor novo, com aviso', () async {
    final s = criar((corpo) async {
      if ((corpo['vetorConhecido'] as List).first == 5) {
        return json(409, {
          'erro': 'Conflito',
          'vetorAtual': [7, 0, 0],
          'contaAtual': {'id': 3, 'nomeAluno': 'Ana', 'saldo': 140},
        });
      }
      return json(200, {'id': 3, 'nomeAluno': 'Ana', 'saldo': 190, 'vetorAtual': [8, 0, 0]});
    });
    await s.registrarOffline(3, tipoDeposito, 50);

    await s.sincronizar();
    await esvaziarEventos();

    expect(enviados.map((c) => c['vetorConhecido']), [
      [5, 0, 0],
      [7, 0, 0],
    ]);
    expect(s.fila, isEmpty);
    expect(avisos.first.problema, isTrue);
    expect(avisos.first.texto, contains('reaplicado'));
    s.dispose();
  });

  test('409 em saque: fica em conflito com o saldo real ate a pessoa decidir', () async {
    var aceitar = false;
    final s = criar((corpo) async {
      if (!aceitar) {
        return json(409, {
          'erro': 'Conflito',
          'vetorAtual': [7, 0, 0],
          'contaAtual': {'id': 3, 'nomeAluno': 'Ana', 'saldo': 40},
        });
      }
      return json(200, {'id': 3, 'nomeAluno': 'Ana', 'saldo': 10, 'vetorAtual': [8, 0, 0]});
    });
    await s.registrarOffline(3, tipoSaque, 30);

    await s.sincronizar();
    await esvaziarEventos();

    // Nao reenviou sozinho, marcou o conflito e o cache passou ao saldo REAL.
    expect(enviados, hasLength(1));
    final op = s.fila.single;
    expect(op.estado, EstadoOperacao.conflito);
    expect(op.saldoReal, 40);
    expect(s.contaEmCache(3)!.conta.saldo, 40);
    expect(s.saldoProvisorio(3), 40);
    expect(avisos.single.problema, isTrue);

    // Nova rodada automatica nao mexe na operacao em conflito.
    await s.sincronizar();
    expect(enviados, hasLength(1));

    // "Aplicar mesmo assim" reenvia com o vetor que veio no 409.
    aceitar = true;
    await s.aplicarMesmoAssim(op.id);
    expect(enviados.last['vetorConhecido'], [7, 0, 0]);
    expect(s.fila, isEmpty);
    expect(s.contaEmCache(3)!.conta.saldo, 10);
    s.dispose();
  });

  test('descartar remove a operacao em conflito sem chamar a agencia', () async {
    final s = criar((_) async => json(409, {
          'erro': 'Conflito',
          'vetorAtual': [7, 0, 0],
          'contaAtual': {'id': 3, 'nomeAluno': 'Ana', 'saldo': 40},
        }));
    await s.registrarOffline(3, tipoSaque, 30);
    await s.sincronizar();

    await s.descartar(s.fila.single.id);

    expect(s.fila, isEmpty);
    expect(enviados, hasLength(1));
    s.dispose();
  });

  test('400 (saldo insuficiente) tira a operacao da fila, com aviso', () async {
    final s = criar((_) async => json(400, {'erro': 'Saldo insuficiente.'}));
    await s.registrarOffline(3, tipoSaque, 30);

    await s.sincronizar();
    await esvaziarEventos();

    expect(s.fila, isEmpty);
    expect(avisos.single.texto, contains('Saldo insuficiente.'));
    s.dispose();
  });
}
