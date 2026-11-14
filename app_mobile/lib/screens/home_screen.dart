import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../config.dart';
import '../models/conta.dart';
import '../services/api_client.dart';
import 'login_screen.dart';

/// Tela principal. Nesta etapa: consulta de saldo.
/// Proxima etapa (Parte D, continuacao): deposito, saque, transferencia e o
/// painel da lider atual.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.api});

  final ApiClient api;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _idConta = TextEditingController();
  bool _carregando = false;
  Conta? _conta;
  String? _erro;

  @override
  void dispose() {
    _idConta.dispose();
    super.dispose();
  }

  Future<void> _consultar() async {
    final id = int.tryParse(_idConta.text.trim());
    if (id == null) {
      setState(() => _erro = 'Informe o número da conta.');
      return;
    }
    setState(() {
      _carregando = true;
      _erro = null;
    });
    try {
      final conta = await widget.api.consultarSaldo(id);
      if (!mounted) return;
      setState(() => _conta = conta);
    } on ApiErro catch (erro) {
      if (erro.naoAutorizado) {
        await _voltarAoLogin('Sessão expirada ou inválida (${erro.mensagem}). Entre de novo.');
        return;
      }
      if (!mounted) return;
      setState(() {
        _conta = null;
        _erro = erro.mensagem;
      });
    } finally {
      if (mounted) setState(() => _carregando = false);
    }
  }

  Future<void> _voltarAoLogin(String? aviso) async {
    await widget.api.logout();
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(builder: (_) => LoginScreen(api: widget.api, aviso: aviso)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('ICEIBank'),
        actions: [
          IconButton(
            tooltip: 'Sair',
            icon: const Icon(Icons.logout),
            onPressed: () => _voltarAoLogin(null),
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _idConta,
                    decoration: const InputDecoration(
                      labelText: 'Número da conta',
                      border: OutlineInputBorder(),
                    ),
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    onSubmitted: (_) => _consultar(),
                  ),
                ),
                const SizedBox(width: 12),
                FilledButton(
                  onPressed: _carregando ? null : _consultar,
                  child: _carregando
                      ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Text('Consultar'),
                ),
              ],
            ),
            if (_erro != null) ...[
              const SizedBox(height: 16),
              MensagemErro(texto: _erro!),
            ],
            if (_conta != null) ...[
              const SizedBox(height: 16),
              CartaoConta(conta: _conta!),
            ],
          ],
        ),
      ),
    );
  }
}

class CartaoConta extends StatelessWidget {
  const CartaoConta({super.key, required this.conta});

  final Conta conta;

  @override
  Widget build(BuildContext context) {
    final tema = Theme.of(context);
    final saldo = conta.saldo.toStringAsFixed(2).replaceAll('.', ',');
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Conta ${conta.id} • ${conta.nomeAluno}', style: tema.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text('R\$ $saldo', style: tema.textTheme.headlineMedium),
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
