import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../config.dart';
import '../models/conta.dart';
import '../services/api_client.dart';
import '../services/monitor_lideranca.dart';
import '../util/formatacao.dart';
import '../widgets/dialogo_operacao.dart';
import '../widgets/mensagem_erro.dart';
import '../widgets/painel_lideranca.dart';
import 'login_screen.dart';

/// Tela principal: painel da lider (atualizado sozinho), consulta de saldo e as
/// operacoes da conta consultada (deposito, saque, transferencia).
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.api});

  final ApiClient api;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _idConta = TextEditingController();
  late final MonitorLideranca _monitor;
  late final AppLifecycleListener _ciclodeVida;

  bool _carregando = false;
  Conta? _conta;
  String? _erro;

  @override
  void initState() {
    super.initState();
    _monitor = MonitorLideranca(widget.api)..iniciar();
    // App em segundo plano nao precisa consultar a lider: pausa o polling para
    // economizar bateria e rede, e retoma (com uma consulta imediata) ao voltar.
    _ciclodeVida = AppLifecycleListener(
      onResume: _monitor.iniciar,
      onHide: _monitor.parar,
    );
  }

  @override
  void dispose() {
    _ciclodeVida.dispose();
    _monitor.dispose();
    _idConta.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------ acoes

  Future<void> _consultar() async {
    final id = int.tryParse(_idConta.text.trim());
    if (id == null) {
      setState(() => _erro = 'Informe o número da conta.');
      return;
    }
    await _executar(() async {
      final conta = await widget.api.consultarSaldo(id);
      if (mounted) setState(() => _conta = conta);
      return null;
    }, limparConta: true);
  }

  Future<void> _depositar() async {
    final conta = _conta!;
    final dados = await pedirOperacao(context, titulo: 'Depositar na conta ${conta.id}', rotuloConfirmar: 'Depositar');
    if (dados == null) return;
    await _executar(() async {
      await widget.api.depositar(conta.id, dados.valor);
      return 'Depósito de ${formatarReais(dados.valor)} realizado.';
    });
  }

  Future<void> _sacar() async {
    final conta = _conta!;
    final dados = await pedirOperacao(context, titulo: 'Sacar da conta ${conta.id}', rotuloConfirmar: 'Sacar');
    if (dados == null) return;
    await _executar(() async {
      await widget.api.sacar(conta.id, dados.valor);
      return 'Saque de ${formatarReais(dados.valor)} realizado.';
    });
  }

  Future<void> _transferir() async {
    final conta = _conta!;
    final dados = await pedirOperacao(
      context,
      titulo: 'Transferir da conta ${conta.id}',
      rotuloConfirmar: 'Transferir',
      contaOrigem: conta.id,
      pedirDestino: true,
    );
    if (dados == null) return;
    final destino = dados.contaDestino!;
    await _executar(() async {
      final resultado = await widget.api.transferir(conta.id, destino, dados.valor);
      final valor = formatarReais(dados.valor);
      return resultado.assincrona
          ? 'Transferência de $valor enviada para a conta $destino (agência ${agenciaResponsavel(destino)}). '
              'O débito já foi feito; o crédito chega de forma assíncrona, pelo RabbitMQ.'
          : 'Transferência de $valor para a conta $destino concluída.';
    });
  }

  /// Executa uma chamada a API com indicador de carregamento e erro visivel.
  ///
  /// Depois de uma operacao bem-sucedida, consulta o saldo de novo: a resposta do
  /// deposito/saque nao traz o vetorAtual, e o app precisa dele atualizado para
  /// o modo offline (Parte F).
  Future<void> _executar(Future<String?> Function() acao, {bool limparConta = false}) async {
    setState(() {
      _carregando = true;
      _erro = null;
    });
    try {
      final mensagem = await acao();
      if (mensagem != null) {
        final atual = _conta;
        if (atual != null) {
          final conta = await widget.api.consultarSaldo(atual.id);
          if (mounted) setState(() => _conta = conta);
        }
        _avisar(mensagem);
      }
    } on ApiErro catch (erro) {
      if (erro.naoAutorizado) {
        await _voltarAoLogin('Sessão expirada ou inválida (${erro.mensagem}). Entre de novo.');
        return;
      }
      if (!mounted) return;
      setState(() {
        if (limparConta) _conta = null;
        _erro = erro.mensagem;
      });
    } finally {
      if (mounted) setState(() => _carregando = false);
    }
  }

  void _avisar(String mensagem) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(mensagem), duration: const Duration(seconds: 5)));
  }

  Future<void> _voltarAoLogin(String? aviso) async {
    _monitor.parar();
    await widget.api.logout();
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(builder: (_) => LoginScreen(api: widget.api, aviso: aviso)),
    );
  }

  // ------------------------------------------------------------ tela

  @override
  Widget build(BuildContext context) {
    final conta = _conta;
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
            PainelLideranca(monitor: _monitor),
            const SizedBox(height: 24),
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
                  child: const Text('Consultar'),
                ),
              ],
            ),
            if (_carregando) ...[
              const SizedBox(height: 16),
              const LinearProgressIndicator(),
            ],
            if (_erro != null) ...[
              const SizedBox(height: 16),
              MensagemErro(texto: _erro!),
            ],
            if (conta != null) ...[
              const SizedBox(height: 16),
              CartaoConta(conta: conta),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.tonalIcon(
                    onPressed: _carregando ? null : _depositar,
                    icon: const Icon(Icons.add),
                    label: const Text('Depositar'),
                  ),
                  FilledButton.tonalIcon(
                    onPressed: _carregando ? null : _sacar,
                    icon: const Icon(Icons.remove),
                    label: const Text('Sacar'),
                  ),
                  FilledButton.tonalIcon(
                    onPressed: _carregando ? null : _transferir,
                    icon: const Icon(Icons.swap_horiz),
                    label: const Text('Transferir'),
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

class CartaoConta extends StatelessWidget {
  const CartaoConta({super.key, required this.conta});

  final Conta conta;

  @override
  Widget build(BuildContext context) {
    final tema = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Conta ${conta.id} • ${conta.nomeAluno}', style: tema.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(formatarReais(conta.saldo), style: tema.textTheme.headlineMedium),
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
