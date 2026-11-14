import 'package:material_ui/material_ui.dart';

/// Caixa de erro visivel, reaproveitada nas telas (requisito 8.1: tratamento
/// visivel dos erros retornados pela API).
class MensagemErro extends StatelessWidget {
  const MensagemErro({super.key, required this.texto});

  final String texto;

  @override
  Widget build(BuildContext context) {
    final cores = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: cores.errorContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline, color: cores.onErrorContainer),
          const SizedBox(width: 8),
          Expanded(child: Text(texto, style: TextStyle(color: cores.onErrorContainer))),
        ],
      ),
    );
  }
}
