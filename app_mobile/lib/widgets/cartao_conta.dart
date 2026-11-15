import 'package:material_ui/material_ui.dart';

import '../config.dart';
import '../services/armazenamento_local.dart';
import '../util/formatacao.dart';

/// Cartao da conta exibida, sempre montado a partir do cache local (Parte F).
///
/// - Com operacoes pendentes, o numero grande e o saldo PROVISORIO (UI
///   otimista), com selo de destaque, e o ultimo saldo confirmado pela agencia
///   aparece logo abaixo: a pessoa nunca ve so o valor esperado.
/// - Sem resposta da agencia, mostra de quando e o dado ("ultimo dado conhecido").
class CartaoConta extends StatelessWidget {
  const CartaoConta({
    super.key,
    required this.cache,
    required this.saldoProvisorio,
    required this.pendentes,
    required this.offline,
  });

  final ContaEmCache cache;
  final double saldoProvisorio;

  /// Quantas operacoes da conta estao na fila (fora as em conflito).
  final int pendentes;

  /// A ultima tentativa de falar com a agencia da conta falhou por conexao.
  final bool offline;

  @override
  Widget build(BuildContext context) {
    final tema = Theme.of(context);
    final cores = tema.colorScheme;
    final conta = cache.conta;
    final provisorio = pendentes > 0;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Conta ${conta.id} • ${conta.nomeAluno}', style: tema.textTheme.titleMedium),
            if (offline) ...[
              const SizedBox(height: 8),
              _Selo(
                icone: Icons.cloud_off,
                texto: 'Sem conexão com a agência • último dado conhecido, de '
                    '${formatarDataHora(cache.atualizadaEm)}',
                fundo: cores.surfaceContainerHighest,
                frente: cores.onSurfaceVariant,
              ),
            ],
            const SizedBox(height: 8),
            Text(
              formatarReais(provisorio ? saldoProvisorio : conta.saldo),
              style: tema.textTheme.headlineMedium?.copyWith(
                color: provisorio ? cores.tertiary : null,
                fontStyle: provisorio ? FontStyle.italic : null,
              ),
            ),
            if (provisorio) ...[
              const SizedBox(height: 4),
              _Selo(
                icone: Icons.schedule,
                texto: 'Saldo provisório • $pendentes '
                    '${pendentes == 1 ? 'operação pendente' : 'operações pendentes'} de sincronização',
                fundo: cores.tertiaryContainer,
                frente: cores.onTertiaryContainer,
              ),
              const SizedBox(height: 4),
              Text(
                'Confirmado pela agência: ${formatarReais(conta.saldo)}',
                style: tema.textTheme.bodyMedium,
              ),
            ],
            const SizedBox(height: 8),
            Text(
              'Agência ${conta.agencia} (porta ${portaAgencia(conta.agencia)})',
              style: tema.textTheme.bodyMedium,
            ),
            if (conta.vetorAtual.isNotEmpty)
              Text(
                'Relógio vetorial da agência: [${conta.vetorAtual.join(', ')}]',
                style: tema.textTheme.bodySmall,
              ),
          ],
        ),
      ),
    );
  }
}

class _Selo extends StatelessWidget {
  const _Selo({required this.icone, required this.texto, required this.fundo, required this.frente});

  final IconData icone;
  final String texto;
  final Color fundo;
  final Color frente;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(color: fundo, borderRadius: BorderRadius.circular(16)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icone, size: 16, color: frente),
          const SizedBox(width: 6),
          Flexible(child: Text(texto, style: TextStyle(color: frente, fontSize: 13))),
        ],
      ),
    );
  }
}
