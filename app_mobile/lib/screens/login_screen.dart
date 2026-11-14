import 'package:material_ui/material_ui.dart';

import '../services/api_client.dart';
import 'home_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key, required this.api, this.aviso});

  final ApiClient api;

  /// Mensagem mostrada ao abrir a tela, ex.: "Sessao expirada" depois de um 401.
  final String? aviso;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _usuario = TextEditingController();
  final _senha = TextEditingController();
  bool _carregando = false;
  String? _erro;

  @override
  void initState() {
    super.initState();
    _erro = widget.aviso;
  }

  @override
  void dispose() {
    _usuario.dispose();
    _senha.dispose();
    super.dispose();
  }

  Future<void> _entrar() async {
    final usuario = _usuario.text.trim();
    final senha = _senha.text;
    if (usuario.isEmpty || senha.isEmpty) {
      setState(() => _erro = 'Informe usuario e senha.');
      return;
    }
    setState(() {
      _carregando = true;
      _erro = null;
    });
    try {
      await widget.api.login(usuario, senha);
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(builder: (_) => HomeScreen(api: widget.api)),
      );
    } on ApiErro catch (erro) {
      if (!mounted) return;
      setState(() => _erro = erro.naoAutorizado ? 'Usuario ou senha invalidos.' : erro.mensagem);
    } finally {
      if (mounted) setState(() => _carregando = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tema = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Icon(Icons.account_balance, size: 56, color: tema.colorScheme.primary),
                  const SizedBox(height: 12),
                  Text('ICEIBank', textAlign: TextAlign.center, style: tema.textTheme.headlineMedium),
                  const SizedBox(height: 32),
                  TextField(
                    controller: _usuario,
                    decoration: const InputDecoration(labelText: 'Usuário', border: OutlineInputBorder()),
                    textInputAction: TextInputAction.next,
                    enabled: !_carregando,
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _senha,
                    decoration: const InputDecoration(labelText: 'Senha', border: OutlineInputBorder()),
                    obscureText: true,
                    onSubmitted: (_) => _entrar(),
                    enabled: !_carregando,
                  ),
                  if (_erro != null) ...[
                    const SizedBox(height: 16),
                    MensagemErro(texto: _erro!),
                  ],
                  const SizedBox(height: 24),
                  FilledButton(
                    onPressed: _carregando ? null : _entrar,
                    child: _carregando
                        ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Text('Entrar'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Caixa de erro visivel, reaproveitada nas telas (requisito 8.1: tratamento
/// visivel dos erros da API).
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
