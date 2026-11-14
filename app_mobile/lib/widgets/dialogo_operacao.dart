import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../util/formatacao.dart';

/// O que a pessoa digitou no dialogo de operacao.
class DadosOperacao {
  const DadosOperacao(this.valor, {this.contaDestino});

  final double valor;
  final int? contaDestino;
}

/// Abre um dialogo pedindo o valor (e, na transferencia, a conta de destino).
/// Devolve null se a pessoa cancelar.
Future<DadosOperacao?> pedirOperacao(
  BuildContext context, {
  required String titulo,
  required String rotuloConfirmar,
  int? contaOrigem,
  bool pedirDestino = false,
}) {
  return showDialog<DadosOperacao>(
    context: context,
    builder: (_) => _DialogoOperacao(
      titulo: titulo,
      rotuloConfirmar: rotuloConfirmar,
      contaOrigem: contaOrigem,
      pedirDestino: pedirDestino,
    ),
  );
}

class _DialogoOperacao extends StatefulWidget {
  const _DialogoOperacao({
    required this.titulo,
    required this.rotuloConfirmar,
    required this.pedirDestino,
    this.contaOrigem,
  });

  final String titulo;
  final String rotuloConfirmar;
  final bool pedirDestino;
  final int? contaOrigem;

  @override
  State<_DialogoOperacao> createState() => _DialogoOperacaoState();
}

class _DialogoOperacaoState extends State<_DialogoOperacao> {
  final _form = GlobalKey<FormState>();
  final _valor = TextEditingController();
  final _destino = TextEditingController();

  @override
  void dispose() {
    _valor.dispose();
    _destino.dispose();
    super.dispose();
  }

  String? _validarValor(String? texto) {
    final valor = lerValor(texto ?? '');
    if (valor == null) return 'Informe um valor, ex.: 20,50';
    if (valor <= 0) return 'O valor deve ser maior que zero';
    return null;
  }

  String? _validarDestino(String? texto) {
    final destino = int.tryParse((texto ?? '').trim());
    if (destino == null) return 'Informe a conta de destino';
    if (destino == widget.contaOrigem) return 'A conta de destino deve ser outra';
    return null;
  }

  void _confirmar() {
    if (!_form.currentState!.validate()) return;
    Navigator.of(context).pop(DadosOperacao(
      lerValor(_valor.text)!,
      contaDestino: widget.pedirDestino ? int.parse(_destino.text.trim()) : null,
    ));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.titulo),
      content: Form(
        key: _form,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.pedirDestino) ...[
              TextFormField(
                controller: _destino,
                decoration: const InputDecoration(labelText: 'Conta de destino', border: OutlineInputBorder()),
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                validator: _validarDestino,
                autofocus: true,
              ),
              const SizedBox(height: 16),
            ],
            TextFormField(
              controller: _valor,
              decoration: const InputDecoration(
                labelText: 'Valor',
                prefixText: 'R\$ ',
                border: OutlineInputBorder(),
              ),
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))],
              validator: _validarValor,
              autofocus: !widget.pedirDestino,
              onFieldSubmitted: (_) => _confirmar(),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancelar')),
        FilledButton(onPressed: _confirmar, child: Text(widget.rotuloConfirmar)),
      ],
    );
  }
}
