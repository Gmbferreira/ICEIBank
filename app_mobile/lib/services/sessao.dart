import 'package:shared_preferences/shared_preferences.dart';

/// Guarda o token JWT entre aberturas do app.
///
/// Equivalente ao localStorage do frontend web (api.ts: salvarToken /
/// tokenAtual / limparToken). Guarda tambem quando o token expira, calculado a
/// partir do expiracao_min devolvido no login, para o app ja abrir na tela de
/// login quando o token salvo estiver vencido - em vez de descobrir isso so no
/// primeiro 401.
class Sessao {
  Sessao({this.token, this.expiraEm});

  /// Sessao sem login (usada nos testes e quando nao ha nada salvo).
  Sessao.vazia() : this();

  static const _chaveToken = 'iceibank_token';
  static const _chaveExpiraEm = 'iceibank_token_expira_em';

  String? token;
  DateTime? expiraEm;

  bool get ativa {
    final limite = expiraEm;
    return token != null && (limite == null || DateTime.now().isBefore(limite));
  }

  static Future<Sessao> carregar() async {
    final prefs = await SharedPreferences.getInstance();
    final expiraMs = prefs.getInt(_chaveExpiraEm);
    return Sessao(
      token: prefs.getString(_chaveToken),
      expiraEm: expiraMs == null ? null : DateTime.fromMillisecondsSinceEpoch(expiraMs),
    );
  }

  Future<void> salvar(String novoToken, int expiracaoMin) async {
    token = novoToken;
    expiraEm = DateTime.now().add(Duration(minutes: expiracaoMin));
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_chaveToken, novoToken);
    await prefs.setInt(_chaveExpiraEm, expiraEm!.millisecondsSinceEpoch);
  }

  Future<void> limpar() async {
    token = null;
    expiraEm = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_chaveToken);
    await prefs.remove(_chaveExpiraEm);
  }
}
