import 'package:material_ui/material_ui.dart';

import '../config.dart';
import '../services/monitor_lideranca.dart';
import '../util/formatacao.dart';

/// Painel com a agencia lider atual, atualizado sozinho pelo MonitorLideranca.
class PainelLideranca extends StatelessWidget {
  const PainelLideranca({super.key, required this.monitor});

  final MonitorLideranca monitor;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: monitor,
      builder: (context, _) {
        final tema = Theme.of(context);
        final cores = tema.colorScheme;
        final estado = monitor.estado;

        final IconData icone;
        final String titulo;
        final String detalhe;
        Color fundo = cores.primaryContainer;
        Color texto = cores.onPrimaryContainer;

        if (estado.aguardandoPrimeiraConsulta) {
          icone = Icons.hourglass_top;
          titulo = 'Consultando…';
          detalhe = 'Procurando uma agência que responda';
        } else if (estado.erro != null) {
          icone = Icons.cloud_off;
          titulo = 'Indisponível';
          detalhe = '${estado.erro} Nova tentativa em instantes.';
          fundo = cores.errorContainer;
          texto = cores.onErrorContainer;
        } else if (estado.lider == null) {
          icone = Icons.how_to_vote;
          titulo = 'Eleição em andamento';
          detalhe = 'A agência ${estado.agenciaConsultada} ainda não conhece uma líder';
          fundo = cores.tertiaryContainer;
          texto = cores.onTertiaryContainer;
        } else {
          icone = Icons.workspace_premium;
          titulo = 'Agência ${estado.lider}';
          detalhe = 'porta ${portaAgencia(estado.lider!)} • informado pela agência ${estado.agenciaConsultada}';
        }

        final atualizado = estado.atualizadoEm;
        return Card(
          color: fundo,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Icon(icone, size: 40, color: texto),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Líder atual', style: tema.textTheme.labelLarge?.copyWith(color: texto)),
                      Text(titulo, style: tema.textTheme.headlineSmall?.copyWith(color: texto)),
                      Text(detalhe, style: tema.textTheme.bodySmall?.copyWith(color: texto)),
                      if (atualizado != null)
                        Text(
                          'Atualizado às ${formatarHora(atualizado)} (a cada ${monitor.intervalo.inSeconds} s)',
                          style: tema.textTheme.bodySmall?.copyWith(color: texto),
                        ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'Atualizar agora',
                  icon: Icon(Icons.refresh, color: texto),
                  onPressed: monitor.verificarAgora,
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
