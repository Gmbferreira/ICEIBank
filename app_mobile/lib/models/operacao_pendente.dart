import '../config.dart';

/// Tipos aceitos por POST /contas/{id}/sincronizar (Parte E).
const String tipoDeposito = 'DEPOSITO';
const String tipoSaque = 'SAQUE';

enum EstadoOperacao {
  /// Na fila, esperando conexao com a agencia dona da conta.
  pendente,

  /// A agencia recusou com 409: a conta mudou enquanto o app estava offline.
  /// Fica parada ate a pessoa escolher "Aplicar mesmo assim" ou "Descartar".
  conflito,
}

/// Operacao de escrita feita sem conexao com a agencia (Parte F).
///
/// Guarda o vetorConhecido: o vetorAtual que o app tinha da conta quando a
/// operacao foi registrada. E ele que a agencia compara com o vetor dela.
class OperacaoPendente {
  OperacaoPendente({
    required this.id,
    required this.idConta,
    required this.tipo,
    required this.valor,
    required this.vetorConhecido,
    required this.criadaEm,
    this.estado = EstadoOperacao.pendente,
    this.saldoReal,
    this.vetorAtualConflito,
  });

  /// Identificador local (so para a fila do app; a agencia nao conhece).
  final String id;
  final int idConta;
  final String tipo;
  final double valor;
  final DateTime criadaEm;

  /// Pode ser trocado pelo sincronizador: depois que uma operacao anterior da
  /// mesma agencia e aplicada, o vetor avanca por causa do proprio app.
  List<int> vetorConhecido;

  EstadoOperacao estado;

  /// Preenchidos no 409: saldo verdadeiro da conta na agencia e o vetor dela
  /// naquele momento (usado em "Aplicar mesmo assim").
  double? saldoReal;
  List<int>? vetorAtualConflito;

  bool get ehSaque => tipo == tipoSaque;
  bool get emConflito => estado == EstadoOperacao.conflito;
  int get agencia => agenciaResponsavel(idConta);

  /// Efeito esperado no saldo (usado no saldo provisorio da UI otimista).
  double get efeito => ehSaque ? -valor : valor;

  String get descricao => ehSaque ? 'Saque' : 'Depósito';

  Map<String, Object?> toJson() => {
        'id': id,
        'idConta': idConta,
        'tipo': tipo,
        'valor': valor,
        'vetorConhecido': vetorConhecido,
        'criadaEm': criadaEm.millisecondsSinceEpoch,
        'estado': estado.name,
        'saldoReal': saldoReal,
        'vetorAtualConflito': vetorAtualConflito,
      };

  factory OperacaoPendente.fromJson(Map<String, dynamic> json) {
    List<int>? vetor(Object? valor) =>
        (valor as List<dynamic>?)?.map((v) => (v as num).toInt()).toList();
    return OperacaoPendente(
      id: json['id'] as String,
      idConta: (json['idConta'] as num).toInt(),
      tipo: json['tipo'] as String,
      valor: (json['valor'] as num).toDouble(),
      vetorConhecido: vetor(json['vetorConhecido']) ?? <int>[],
      criadaEm: DateTime.fromMillisecondsSinceEpoch((json['criadaEm'] as num).toInt()),
      estado: EstadoOperacao.values.firstWhere(
        (e) => e.name == json['estado'],
        orElse: () => EstadoOperacao.pendente,
      ),
      saldoReal: (json['saldoReal'] as num?)?.toDouble(),
      vetorAtualConflito: vetor(json['vetorAtualConflito']),
    );
  }
}
