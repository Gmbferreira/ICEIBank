import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';

import '../models/conta.dart';
import '../models/operacao_pendente.dart';
import '../util/formatacao.dart';
import 'api_client.dart';
import 'armazenamento_local.dart';

/// Mensagem para a tela mostrar (snackbar) depois de uma sincronizacao.
class AvisoSincronizacao {
  const AvisoSincronizacao(this.texto, {this.problema = false, this.precisaLogin = false});

  final String texto;

  /// true quando algo nao saiu como a pessoa esperava (conflito, recusa).
  final bool problema;

  /// true no 401: o token venceu. A fila fica guardada e a sincronizacao
  /// continua depois do novo login.
  final bool precisaLogin;
}

/// Operacao offline que nao pode nem entrar na fila (ex.: saque maior que o
/// saldo provisorio).
class OperacaoOfflineInvalida implements Exception {
  const OperacaoOfflineInvalida(this.mensagem);

  final String mensagem;

  @override
  String toString() => mensagem;
}

enum _Desfecho { aplicada, conflito, recusada, semConexao, naoAutorizado }

class _Resultado {
  const _Resultado(this.desfecho, {this.conta, this.conflito, this.mensagem});

  final _Desfecho desfecho;
  final Conta? conta;
  final ConflitoSincronizacao? conflito;
  final String? mensagem;
}

/// Fila de operacoes offline e sincronizacao automatica (Parte F).
///
/// Gatilhos da sincronizacao (nenhum depende de a pessoa apertar algo):
///   1. connectivity_plus avisando que o aparelho voltou a ter rede;
///   2. agenciaVoltou(), chamado pela tela quando o painel de lideranca volta a
///      receber resposta depois de ficar sem nenhuma agencia;
///   3. uma nova tentativa a cada [intervaloRetentativa] enquanto houver
///      operacoes pendentes.
/// O 1 sozinho nao basta: ter rede nao significa que a agencia responde (ela
/// pode ter caido e voltado, ou o Wi-Fi pode estar ligado sem rota ate ela).
///
/// Tratamento do 409 (decisao da RESPOSTAS 9.6 P3):
///   - deposito: reenviado uma vez, automaticamente, com o vetorAtual do 409
///     (somar um valor nao depende do saldo anterior) e com aviso na tela;
///   - saque: fica "em conflito", com o saldo real ao lado, ate a pessoa
///     escolher aplicarMesmoAssim() ou descartar(). As operacoes seguintes da
///     mesma conta esperam essa decisao.
class Sincronizador extends ChangeNotifier {
  Sincronizador(
    this.api,
    this.armazenamento, {
    this.conectividade,
    this.intervaloRetentativa = const Duration(seconds: 10),
  }) {
    _fila = armazenamento.lerFila();
  }

  final ApiClient api;
  final ArmazenamentoLocal armazenamento;
  final Duration intervaloRetentativa;

  /// Fonte dos eventos de rede. Nulo = connectivity_plus (os testes passam um
  /// stream proprio, para nao depender do plugin).
  final Stream<List<ConnectivityResult>>? conectividade;

  late List<OperacaoPendente> _fila;
  final _avisos = StreamController<AvisoSincronizacao>.broadcast();
  final Set<int> _agenciasSemResposta = {};

  StreamSubscription<List<ConnectivityResult>>? _assinaturaRede;
  Timer? _retentativa;
  bool _rodando = false;
  bool _descartado = false;
  String? _enviandoId;

  /// Chamado depois de uma sincronizacao disparada por reconexao, para a tela
  /// atualizar a conta exibida (o dado de cache deixa de ser "offline").
  VoidCallback? aoReconectar;

  // ------------------------------------------------------------ leitura

  Stream<AvisoSincronizacao> get avisos => _avisos.stream;

  List<OperacaoPendente> get fila => List.unmodifiable(_fila);

  /// ID da operacao sendo enviada agora (a tela mostra um indicador nela).
  String? get enviandoId => _enviandoId;

  List<OperacaoPendente> operacoesDa(int idConta) =>
      _fila.where((o) => o.idConta == idConta).toList();

  bool temPendencias(int idConta) => _fila.any((o) => o.idConta == idConta);

  ContaEmCache? contaEmCache(int idConta) => armazenamento.conta(idConta);

  /// true quando a ultima tentativa de falar com a agencia falhou por falta de
  /// conexao. A tela usa para marcar o dado exibido como "offline".
  bool agenciaSemResposta(int agencia) => _agenciasSemResposta.contains(agencia);

  /// Saldo da UI otimista: o ultimo saldo confirmado pela agencia mais o efeito
  /// das operacoes ainda pendentes. Operacoes em conflito ficam de fora: elas
  /// nao foram aplicadas, e o saldo do cache ja e o real devolvido pelo 409.
  double? saldoProvisorio(int idConta) {
    final cache = armazenamento.conta(idConta);
    if (cache == null) return null;
    return _fila
        .where((o) => o.idConta == idConta && !o.emConflito)
        .fold<double>(cache.conta.saldo, (saldo, o) => saldo + o.efeito);
  }

  // ------------------------------------------------------------ registro

  /// Guarda uma leitura bem-sucedida da conta (saldo + vetorAtual).
  Future<void> registrarLeitura(Conta conta) async {
    _agenciasSemResposta.remove(conta.agencia);
    await armazenamento.salvarConta(conta);
    _notificar();
  }

  void marcarSemResposta(int agencia) {
    if (_agenciasSemResposta.add(agencia)) _notificar();
  }

  /// Coloca uma operacao na fila, com o vetorAtual que o app tem da conta.
  Future<OperacaoPendente> registrarOffline(int idConta, String tipo, double valor) async {
    final cache = armazenamento.conta(idConta);
    if (cache == null || cache.conta.vetorAtual.isEmpty) {
      throw const OperacaoOfflineInvalida(
        'Esta conta ainda não foi consultada com conexão neste aparelho: '
        'sem o último vetor da agência, a operação não pode ficar pendente.',
      );
    }
    if (tipo == tipoSaque) {
      final disponivel = saldoProvisorio(idConta) ?? cache.conta.saldo;
      if (valor > disponivel + 0.000001) {
        throw OperacaoOfflineInvalida(
          'Saldo provisório insuficiente (${formatarReais(disponivel)}). '
          'O app não guarda saques offline maiores que o saldo conhecido.',
        );
      }
    }
    final operacao = OperacaoPendente(
      id: '${DateTime.now().microsecondsSinceEpoch}',
      idConta: idConta,
      tipo: tipo,
      valor: valor,
      vetorConhecido: List.of(cache.conta.vetorAtual),
      criadaEm: DateTime.now(),
    );
    _fila.add(operacao);
    _agenciasSemResposta.add(operacao.agencia);
    await armazenamento.salvarFila(_fila);
    _notificar();
    return operacao;
  }

  // ------------------------------------------------------------ gatilhos

  void iniciar() {
    if (_descartado) return;
    _assinaturaRede ??= (conectividade ?? Connectivity().onConnectivityChanged).listen((resultado) {
      // A lista so contem "none" quando nao ha nenhuma rede.
      if (!resultado.contains(ConnectivityResult.none)) _reconectou();
    });
    _retentativa ??= Timer.periodic(intervaloRetentativa, (_) {
      if (_fila.any((o) => !o.emConflito)) sincronizar();
    });
    sincronizar();
  }

  void parar() {
    _assinaturaRede?.cancel();
    _assinaturaRede = null;
    _retentativa?.cancel();
    _retentativa = null;
  }

  /// O painel de lideranca voltou a receber resposta de alguma agencia.
  void agenciaVoltou() => _reconectou();

  Future<void> _reconectou() async {
    await sincronizar();
    aoReconectar?.call();
  }

  // ------------------------------------------------------------ sincronizacao

  /// Envia a fila, na ordem, para POST /contas/{id}/sincronizar.
  Future<void> sincronizar() async {
    if (_rodando || _descartado || !api.sessao.ativa) return;
    if (!_fila.any((o) => !o.emConflito)) return;
    _rodando = true;
    var aplicadas = 0;
    final agenciasFora = <int>{};
    final contasBloqueadas = <int>{};
    try {
      for (final operacao in List.of(_fila)) {
        if (_descartado) return;
        if (!_fila.contains(operacao)) continue;
        if (operacao.emConflito) {
          contasBloqueadas.add(operacao.idConta);
          continue;
        }
        if (contasBloqueadas.contains(operacao.idConta) || agenciasFora.contains(operacao.agencia)) {
          continue;
        }

        var resultado = await _enviar(operacao, operacao.vetorConhecido);

        if (resultado.desfecho == _Desfecho.conflito && !operacao.ehSaque) {
          // Deposito: nova tentativa automatica com o vetor que a agencia mandou.
          final conflito = resultado.conflito!;
          resultado = await _enviar(operacao, conflito.vetorAtual);
          if (resultado.desfecho == _Desfecho.aplicada) {
            aplicadas++;
            _avisar(AvisoSincronizacao(
              'Conflito na conta ${operacao.idConta}: o saldo mudou na agência enquanto o app '
              'estava offline (saldo real: ${formatarReais(conflito.contaAtual.saldo)}). '
              'O depósito pendente de ${formatarReais(operacao.valor)} foi reaplicado '
              'automaticamente; saldo agora: ${formatarReais(resultado.conta!.saldo)}.',
              problema: true,
            ));
            continue;
          }
        }

        switch (resultado.desfecho) {
          case _Desfecho.aplicada:
            aplicadas++;
          case _Desfecho.conflito:
            contasBloqueadas.add(operacao.idConta);
            _avisar(AvisoSincronizacao(
              '${operacao.descricao} pendente de ${formatarReais(operacao.valor)} na conta '
              '${operacao.idConta} NÃO foi aplicado: o saldo mudou na agência enquanto o app '
              'estava offline (saldo real: ${formatarReais(resultado.conflito!.contaAtual.saldo)}). '
              'Escolha aplicar mesmo assim ou descartar.',
              problema: true,
            ));
          case _Desfecho.recusada:
            _avisar(AvisoSincronizacao(
              '${operacao.descricao} pendente de ${formatarReais(operacao.valor)} na conta '
              '${operacao.idConta} foi recusado pela agência: ${resultado.mensagem}',
              problema: true,
            ));
          case _Desfecho.semConexao:
            agenciasFora.add(operacao.agencia);
          case _Desfecho.naoAutorizado:
            _avisar(const AvisoSincronizacao(
              'Sessão expirada. As operações pendentes continuam guardadas e serão '
              'sincronizadas depois que você entrar de novo.',
              problema: true,
              precisaLogin: true,
            ));
            return;
        }
      }
    } finally {
      _rodando = false;
      if (aplicadas > 0) {
        _avisar(AvisoSincronizacao(aplicadas == 1
            ? '1 operação pendente sincronizada com a agência.'
            : '$aplicadas operações pendentes sincronizadas com a agência.'));
      }
      _notificar();
    }
  }

  /// "Aplicar mesmo assim": reenvia a operacao em conflito com o vetor que a
  /// agencia devolveu no 409. Se a conta mudou de novo nesse meio tempo, volta
  /// a dar conflito (com o saldo novo na tela).
  Future<void> aplicarMesmoAssim(String id) async {
    final operacao = _buscar(id);
    if (operacao == null || !operacao.emConflito || _rodando) return;
    _rodando = true;
    try {
      final resultado = await _enviar(operacao, operacao.vetorAtualConflito ?? operacao.vetorConhecido);
      switch (resultado.desfecho) {
        case _Desfecho.aplicada:
          _avisar(AvisoSincronizacao(
            '${operacao.descricao} de ${formatarReais(operacao.valor)} aplicado na conta '
            '${operacao.idConta}. Saldo: ${formatarReais(resultado.conta!.saldo)}.',
          ));
        case _Desfecho.conflito:
          _avisar(AvisoSincronizacao(
            'A conta ${operacao.idConta} mudou de novo (saldo real: '
            '${formatarReais(resultado.conflito!.contaAtual.saldo)}). Confira e decida outra vez.',
            problema: true,
          ));
        case _Desfecho.recusada:
          _avisar(AvisoSincronizacao(
            '${operacao.descricao} recusado pela agência: ${resultado.mensagem}',
            problema: true,
          ));
        case _Desfecho.semConexao:
          _avisar(const AvisoSincronizacao(
            'Sem conexão com a agência. A operação continua em conflito, aguardando sua decisão.',
            problema: true,
          ));
        case _Desfecho.naoAutorizado:
          _avisar(const AvisoSincronizacao(
            'Sessão expirada. Entre de novo para decidir sobre a operação em conflito.',
            problema: true,
            precisaLogin: true,
          ));
      }
    } finally {
      _rodando = false;
      _notificar();
    }
    // Libera as operacoes seguintes da mesma conta, se houver.
    await sincronizar();
  }

  /// "Descartar": tira a operacao em conflito da fila sem aplicar.
  Future<void> descartar(String id) async {
    final operacao = _buscar(id);
    if (operacao == null || _rodando) return;
    _fila.remove(operacao);
    await armazenamento.salvarFila(_fila);
    _avisar(AvisoSincronizacao(
      '${operacao.descricao} pendente de ${formatarReais(operacao.valor)} na conta '
      '${operacao.idConta} descartado. Nada foi alterado na agência.',
    ));
    _notificar();
    await sincronizar();
  }

  /// Uma tentativa de envio. Atualiza fila e cache conforme a resposta.
  Future<_Resultado> _enviar(OperacaoPendente operacao, List<int> vetor) async {
    _enviandoId = operacao.id;
    _notificar();
    try {
      final conta = await api.sincronizar(operacao.idConta, operacao.tipo, operacao.valor, vetor);
      _fila.remove(operacao);
      // O vetor da agencia avancou por causa desta propria operacao. As
      // proximas da mesma agencia que partiram do mesmo vetor passam a usar o
      // novo; sem isso, a segunda operacao offline daria um conflito "falso".
      for (final proxima in _fila) {
        if (proxima.agencia == operacao.agencia && listEquals(proxima.vetorConhecido, vetor)) {
          proxima.vetorConhecido = List.of(conta.vetorAtual);
        }
      }
      _agenciasSemResposta.remove(operacao.agencia);
      await armazenamento.salvarConta(conta);
      await armazenamento.salvarFila(_fila);
      return _Resultado(_Desfecho.aplicada, conta: conta);
    } on ApiErro catch (erro) {
      if (erro.semConexao || erro.status >= 500) {
        _agenciasSemResposta.add(operacao.agencia);
        return const _Resultado(_Desfecho.semConexao);
      }
      _agenciasSemResposta.remove(operacao.agencia);
      if (erro.naoAutorizado) return const _Resultado(_Desfecho.naoAutorizado);

      final conflito = erro.status == 409 ? ConflitoSincronizacao.de(erro) : null;
      if (conflito != null) {
        operacao
          ..estado = EstadoOperacao.conflito
          ..saldoReal = conflito.contaAtual.saldo
          ..vetorAtualConflito = conflito.vetorAtual;
        // O cache passa a mostrar o estado REAL da conta, devolvido pela agencia.
        await armazenamento.salvarConta(conflito.contaAtual);
        await armazenamento.salvarFila(_fila);
        return _Resultado(_Desfecho.conflito, conflito: conflito);
      }

      // 400 (saldo insuficiente, valor invalido), 404 (conta inexistente):
      // repetir daria a mesma resposta. Sai da fila, com aviso.
      _fila.remove(operacao);
      await armazenamento.salvarFila(_fila);
      return _Resultado(_Desfecho.recusada, mensagem: erro.mensagem);
    } finally {
      _enviandoId = null;
    }
  }

  OperacaoPendente? _buscar(String id) {
    for (final operacao in _fila) {
      if (operacao.id == id) return operacao;
    }
    return null;
  }

  void _avisar(AvisoSincronizacao aviso) {
    if (!_descartado) _avisos.add(aviso);
  }

  void _notificar() {
    if (!_descartado) notifyListeners();
  }

  @override
  void dispose() {
    _descartado = true;
    parar();
    _avisos.close();
    super.dispose();
  }
}
