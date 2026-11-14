import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:iceibank_app/config.dart';
import 'package:iceibank_app/services/api_client.dart';
import 'package:iceibank_app/services/monitor_lideranca.dart';
import 'package:iceibank_app/services/sessao.dart';

/// Testes sem rede: o MockClient (do proprio pacote http) faz o papel das agencias.
void main() {
  http.Response json(int status, Object corpo) => http.Response.bytes(
        utf8.encode(jsonEncode(corpo)),
        status,
        headers: {'content-type': 'application/json'},
      );

  test('painel: agencia fora do ar e pulada, a lider vem da proxima', () async {
    final consultadas = <int>[];
    final cliente = MockClient((requisicao) async {
      consultadas.add(requisicao.url.port);
      if (requisicao.url.port == portaAgencia(0)) {
        throw http.ClientException('Connection refused', requisicao.url);
      }
      return json(200, {'idAgencia': 1, 'liderAtual': 2});
    });
    final monitor = MonitorLideranca(ApiClient(Sessao.vazia(), cliente: cliente));

    await monitor.verificarAgora();

    expect(consultadas, [portaAgencia(0), portaAgencia(1)]);
    expect(monitor.estado.lider, 2);
    expect(monitor.estado.agenciaConsultada, 1);
    expect(monitor.estado.erro, isNull);
    monitor.dispose();
  });

  test('painel: depois de achar uma agencia que responde, comeca por ela', () async {
    final consultadas = <int>[];
    final cliente = MockClient((requisicao) async {
      consultadas.add(requisicao.url.port);
      if (requisicao.url.port == portaAgencia(0)) {
        throw http.ClientException('Connection refused', requisicao.url);
      }
      return json(200, {'idAgencia': 1, 'liderAtual': 1});
    });
    final monitor = MonitorLideranca(ApiClient(Sessao.vazia(), cliente: cliente));

    await monitor.verificarAgora();
    consultadas.clear();
    await monitor.verificarAgora();

    expect(consultadas, [portaAgencia(1)]);
    monitor.dispose();
  });

  test('painel: nenhuma agencia responde -> estado de erro visivel', () async {
    final cliente = MockClient((requisicao) async {
      throw http.ClientException('Connection refused', requisicao.url);
    });
    final monitor = MonitorLideranca(ApiClient(Sessao.vazia(), cliente: cliente));

    await monitor.verificarAgora();

    expect(monitor.estado.erro, isNotNull);
    expect(monitor.estado.lider, isNull);
    monitor.dispose();
  });

  test('painel: liderAtual null = eleicao em andamento', () async {
    final cliente = MockClient((_) async => json(200, {'idAgencia': 0, 'liderAtual': null}));
    final monitor = MonitorLideranca(ApiClient(Sessao.vazia(), cliente: cliente));

    await monitor.verificarAgora();

    expect(monitor.estado.erro, isNull);
    expect(monitor.estado.lider, isNull);
    expect(monitor.estado.agenciaConsultada, 0);
    monitor.dispose();
  });

  test('saque com saldo insuficiente vira ApiErro 400 com a mensagem do backend', () async {
    final cliente = MockClient((_) async => json(400, {'erro': 'Saldo insuficiente.'}));
    final api = ApiClient(Sessao(token: 'x'), cliente: cliente);

    await expectLater(
      api.sacar(0, 999),
      throwsA(isA<ApiErro>()
          .having((e) => e.status, 'status', 400)
          .having((e) => e.mensagem, 'mensagem', 'Saldo insuficiente.')),
    );
  });

  test('transferencia vai para a agencia da conta de ORIGEM, com o token', () async {
    late http.Request enviada;
    final cliente = MockClient((requisicao) async {
      enviada = requisicao;
      return json(200, {'mensagem': 'Transferencia publicada...', 'status': 'publicada'});
    });
    final api = ApiClient(Sessao(token: 'abc'), cliente: cliente);

    final resultado = await api.transferir(4, 2, 10);

    expect(enviada.url.port, portaAgencia(1)); // 4 % 3 = 1
    expect(enviada.url.path, '/transferencias');
    expect(enviada.headers['Authorization'], 'Bearer abc');
    expect(jsonDecode(enviada.body), {'idOrigem': 4, 'idDestino': 2, 'valor': 10});
    expect(resultado.assincrona, isTrue);
  });
}
