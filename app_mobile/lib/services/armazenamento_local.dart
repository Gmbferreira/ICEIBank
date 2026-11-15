import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/conta.dart';
import '../models/operacao_pendente.dart';

/// Ultima leitura conhecida de uma conta, e quando ela foi feita.
class ContaEmCache {
  const ContaEmCache(this.conta, this.atualizadaEm);

  final Conta conta;
  final DateTime atualizadaEm;
}

/// Armazenamento local do modo offline-first (Parte F).
///
/// Usa o shared_preferences (ja usado para o token): no Android ele grava num
/// arquivo XML do app, no navegador no localStorage. Os dados sao pequenos
/// (algumas contas consultadas e uma fila curta), entao cada lista e guardada
/// como um JSON numa unica chave. Os dados ficam tambem em memoria: a tela le
/// daqui a cada reconstrucao, sem decodificar JSON de novo.
class ArmazenamentoLocal {
  ArmazenamentoLocal._(this._prefs) {
    _contas = _lerContas();
    _fila = _lerFila();
  }

  static Future<ArmazenamentoLocal> abrir() async =>
      ArmazenamentoLocal._(await SharedPreferences.getInstance());

  static const _chaveContas = 'iceibank_cache_contas';
  static const _chaveFila = 'iceibank_fila_pendentes';

  final SharedPreferences _prefs;
  late Map<int, ContaEmCache> _contas;
  late List<OperacaoPendente> _fila;

  // ------------------------------------------------------------ contas

  ContaEmCache? conta(int id) => _contas[id];

  /// Guarda o saldo e o vetorAtual mais recentes de uma conta.
  Future<void> salvarConta(Conta conta, {DateTime? em}) async {
    _contas[conta.id] = ContaEmCache(conta, em ?? DateTime.now());
    final json = {
      for (final c in _contas.values)
        '${c.conta.id}': {
          'conta': c.conta.toJson(),
          'atualizadaEm': c.atualizadaEm.millisecondsSinceEpoch,
        },
    };
    await _prefs.setString(_chaveContas, jsonEncode(json));
  }

  Map<int, ContaEmCache> _lerContas() {
    final texto = _prefs.getString(_chaveContas);
    if (texto == null) return {};
    try {
      final json = jsonDecode(texto) as Map<String, dynamic>;
      return {
        for (final entrada in json.entries)
          int.parse(entrada.key): ContaEmCache(
            Conta.fromJson((entrada.value as Map)['conta'] as Map<String, dynamic>),
            DateTime.fromMillisecondsSinceEpoch(((entrada.value as Map)['atualizadaEm'] as num).toInt()),
          ),
      };
    } catch (_) {
      // Cache corrompido nao pode impedir o app de abrir: comeca vazio.
      return {};
    }
  }

  // ------------------------------------------------------------ fila

  /// Copia da fila de operacoes pendentes, na ordem em que foram registradas.
  List<OperacaoPendente> lerFila() => List.of(_fila);

  Future<void> salvarFila(List<OperacaoPendente> fila) async {
    _fila = List.of(fila);
    await _prefs.setString(_chaveFila, jsonEncode(_fila.map((o) => o.toJson()).toList()));
  }

  List<OperacaoPendente> _lerFila() {
    final texto = _prefs.getString(_chaveFila);
    if (texto == null) return [];
    try {
      return (jsonDecode(texto) as List<dynamic>)
          .map((o) => OperacaoPendente.fromJson(o as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }
}
