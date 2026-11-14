import 'dart:async';

import 'package:flutter/foundation.dart';

import '../config.dart';
import 'api_client.dart';

/// Ultimo resultado conhecido do painel de lideranca.
class EstadoLideranca {
  const EstadoLideranca({
    this.lider,
    this.agenciaConsultada,
    this.atualizadoEm,
    this.erro,
  });

  /// ID da agencia lider; null = a agencia consultada ainda nao conhece uma
  /// lider (eleicao em andamento).
  final int? lider;

  /// Qual agencia respondeu a consulta. Durante um failover, agencias
  /// diferentes podem responder lideres diferentes por alguns segundos - por
  /// isso o painel mostra de onde veio a resposta.
  final int? agenciaConsultada;

  /// Quando a ultima consulta terminou (com ou sem sucesso).
  final DateTime? atualizadoEm;

  /// Preenchido quando nenhuma das agencias respondeu.
  final String? erro;

  /// Ainda nao houve nenhuma consulta concluida.
  bool get aguardandoPrimeiraConsulta => atualizadoEm == null;
}

/// Consulta GET /bully/lider periodicamente para o painel do app (Parte D).
///
/// - Intervalo de 3 s, o mesmo do heartbeat das agencias: o painel reflete uma
///   troca de lider poucos segundos depois de o backend concluir a reeleicao.
/// - Como o heartbeat do backend, a proxima consulta so e agendada depois que a
///   atual termina: com agencias fora do ar (timeouts), as consultas nunca se
///   acumulam.
/// - Tenta primeiro a ultima agencia que respondeu; se ela nao responder, tenta
///   as outras antes de desistir (requisito 8.1).
/// - Quem usa chama parar() quando o app vai para segundo plano, para nao gastar
///   bateria e rede com um painel que ninguem esta vendo.
class MonitorLideranca extends ChangeNotifier {
  MonitorLideranca(this.api, {this.intervalo = const Duration(seconds: 3)});

  final ApiClient api;
  final Duration intervalo;

  EstadoLideranca _estado = const EstadoLideranca();
  EstadoLideranca get estado => _estado;

  int _agenciaPreferida = 0;
  bool _ativo = false;
  bool _consultando = false;
  bool _descartado = false;
  Timer? _proximaConsulta;

  bool get ativo => _ativo;

  void iniciar() {
    if (_ativo || _descartado) return;
    _ativo = true;
    _ciclo();
  }

  void parar() {
    _ativo = false;
    _proximaConsulta?.cancel();
    _proximaConsulta = null;
  }

  Future<void> _ciclo() async {
    if (!_ativo) return;
    await verificarAgora();
    if (!_ativo) return;
    _proximaConsulta = Timer(intervalo, _ciclo);
  }

  /// Uma consulta imediata (tambem usada pelo botao de atualizar e pelos testes).
  Future<void> verificarAgora() async {
    if (_consultando || _descartado) return;
    _consultando = true;
    try {
      final ordem = [
        _agenciaPreferida,
        ...idsAgencias.where((a) => a != _agenciaPreferida),
      ];
      for (final agencia in ordem) {
        try {
          final resposta = await api.consultarLider(agencia);
          _agenciaPreferida = agencia;
          _publicar(EstadoLideranca(
            lider: resposta.liderAtual,
            agenciaConsultada: agencia,
            atualizadoEm: DateTime.now(),
          ));
          return;
        } catch (_) {
          // Agencia fora do ar, com erro HTTP ou com resposta inesperada: tenta
          // a proxima. Nenhuma excecao pode escapar daqui, senao o ciclo de
          // consultas (_ciclo) pararia para sempre.
          continue;
        }
      }
      _publicar(EstadoLideranca(
        erro: 'Nenhuma das ${idsAgencias.length} agências respondeu.',
        atualizadoEm: DateTime.now(),
      ));
    } finally {
      _consultando = false;
    }
  }

  void _publicar(EstadoLideranca novo) {
    if (_descartado) return;
    _estado = novo;
    notifyListeners();
  }

  @override
  void dispose() {
    _descartado = true;
    parar();
    super.dispose();
  }
}
