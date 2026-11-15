import 'package:material_ui/material_ui.dart';

import '../models/operacao_pendente.dart';
import '../util/formatacao.dart';

/// Operacoes offline da conta exibida (Parte F).
///
/// Pendentes aparecem com o selo "Pendente de sincronizacao". Uma operacao em
/// conflito (409) mostra o saldo real devolvido pela agencia e as duas acoes:
/// "Aplicar mesmo assim" e "Descartar" - quem decide e a pessoa.
class ListaPendentes extends StatelessWidget {
  const ListaPendentes({
    super.key,
    required this.operacoes,
    required this.enviandoId,
    required this.aoAplicar,
    required this.aoDescartar,
    required this.aoSincronizarAgora,
  });

  final List<OperacaoPendente> operacoes;
  final String? enviandoId;
  final void Function(String id) aoAplicar;
  final void Function(String id) aoDescartar;
  final VoidCallback aoSincronizarAgora;

  @override
  Widget build(BuildContext context) {
    final tema = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(child: Text('Operações offline', style: tema.textTheme.titleSmall)),
            IconButton(
              tooltip: 'Tentar sincronizar agora',
              icon: const Icon(Icons.sync),
              onPressed: enviandoId == null ? aoSincronizarAgora : null,
            ),
          ],
        ),
        for (final operacao in operacoes)
          _ItemOperacao(
            operacao: operacao,
            enviando: operacao.id == enviandoId,
            aoAplicar: () => aoAplicar(operacao.id),
            aoDescartar: () => aoDescartar(operacao.id),
          ),
      ],
    );
  }
}

class _ItemOperacao extends StatelessWidget {
  const _ItemOperacao({
    required this.operacao,
    required this.enviando,
    required this.aoAplicar,
    required this.aoDescartar,
  });

  final OperacaoPendente operacao;
  final bool enviando;
  final VoidCallback aoAplicar;
  final VoidCallback aoDescartar;

  @override
  Widget build(BuildContext context) {
    final tema = Theme.of(context);
    final cores = tema.colorScheme;
    final conflito = operacao.emConflito;
    final titulo = '${operacao.descricao} de ${formatarReais(operacao.valor)}';
    final detalhe = 'Registrado offline às ${formatarHora(operacao.criadaEm)} • '
        'vetor conhecido [${operacao.vetorConhecido.join(', ')}]';

    return Card(
      color: conflito ? cores.errorContainer : null,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  operacao.ehSaque ? Icons.remove_circle_outline : Icons.add_circle_outline,
                  color: conflito ? cores.onErrorContainer : null,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    titulo,
                    style: tema.textTheme.titleSmall?.copyWith(color: conflito ? cores.onErrorContainer : null),
                  ),
                ),
                if (enviando)
                  const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                else if (!conflito)
                  Chip(
                    avatar: const Icon(Icons.schedule, size: 16),
                    label: const Text('Pendente de sincronização'),
                    visualDensity: VisualDensity.compact,
                    backgroundColor: cores.tertiaryContainer,
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              detalhe,
              style: tema.textTheme.bodySmall?.copyWith(color: conflito ? cores.onErrorContainer : null),
            ),
            if (conflito) ...[
              const SizedBox(height: 8),
              Text(
                'Conflito: a conta mudou na agência enquanto o app estava offline, e esta '
                'operação NÃO foi aplicada. Saldo real informado pela agência: '
                '${formatarReais(operacao.saldoReal ?? 0)} '
                '(vetor [${(operacao.vetorAtualConflito ?? const []).join(', ')}]).',
                style: TextStyle(color: cores.onErrorContainer),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton(
                    onPressed: enviando ? null : aoAplicar,
                    child: const Text('Aplicar mesmo assim'),
                  ),
                  OutlinedButton(
                    onPressed: enviando ? null : aoDescartar,
                    child: const Text('Descartar'),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
