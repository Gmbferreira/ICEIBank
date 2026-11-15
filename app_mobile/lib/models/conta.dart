import '../config.dart';

/// Conta bancaria como a API devolve em GET /contas/{id}.
///
/// vetorAtual (Sprint 3): o relogio vetorial da agencia no momento da leitura.
/// O app guarda esse vetor no cache local e o envia junto de cada operacao
/// feita offline, para a agencia detectar se algo mudou nesse meio tempo.
class Conta {
  const Conta({
    required this.id,
    required this.nomeAluno,
    required this.saldo,
    this.vetorAtual = const [],
  });

  final int id;
  final String nomeAluno;
  final double saldo;
  final List<int> vetorAtual;

  /// Agencia dona da conta (id % 3).
  int get agencia => agenciaResponsavel(id);

  factory Conta.fromJson(Map<String, dynamic> json) {
    final vetor = (json['vetorAtual'] as List<dynamic>?) ?? const [];
    return Conta(
      id: (json['id'] as num).toInt(),
      nomeAluno: (json['nomeAluno'] as String?) ?? '',
      saldo: (json['saldo'] as num).toDouble(),
      vetorAtual: vetor.map((v) => (v as num).toInt()).toList(),
    );
  }

  /// Mesmo formato da API, para o cache local (Parte F).
  Map<String, Object?> toJson() => {
        'id': id,
        'nomeAluno': nomeAluno,
        'saldo': saldo,
        'vetorAtual': vetorAtual,
      };
}
