// Formatacoes simples usadas nas telas (sem depender do pacote intl).

/// 1234.5 -> "R$ 1234,50"
String formatarReais(double valor) => 'R\$ ${valor.toStringAsFixed(2).replaceAll('.', ',')}';

/// DateTime -> "18:52:07"
String formatarHora(DateTime hora) {
  String dois(int n) => n.toString().padLeft(2, '0');
  return '${dois(hora.hour)}:${dois(hora.minute)}:${dois(hora.second)}';
}

/// Le um valor digitado aceitando virgula ou ponto ("20,50" ou "20.50").
/// Devolve null se nao for um numero.
double? lerValor(String texto) => double.tryParse(texto.trim().replaceAll(',', '.'));
