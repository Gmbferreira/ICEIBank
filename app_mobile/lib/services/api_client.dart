import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config.dart';
import '../models/conta.dart';
import 'sessao.dart';

/// Erro devolvido pela API (ou pela falta dela).
///
/// status 0 = nao houve resposta HTTP (agencia fora do ar, sem rede, timeout).
/// Para os demais, mensagem vem do campo "erro" do corpo, no mesmo formato que o
/// backend usa para todos os erros ({"erro": "..."}), como no api.ts do web.
class ApiErro implements Exception {
  const ApiErro(this.status, this.mensagem, {this.agencia, this.corpo});

  final int status;
  final String mensagem;
  final int? agencia;

  /// Corpo JSON completo da resposta de erro. Na Parte F, o 409 da
  /// sincronizacao traz aqui o vetorAtual e a contaAtual.
  final Object? corpo;

  bool get semConexao => status == 0;
  bool get naoAutorizado => status == 401;

  @override
  String toString() => semConexao ? mensagem : 'HTTP $status: $mensagem';
}

/// Cliente da API das agencias - o equivalente mobile do frontend/src/api.ts.
///
/// Diferenca de design em relacao ao web: la a pessoa escolhe a "agencia de
/// entrada" num seletor. Aqui o app escolhe sozinho a agencia dona da conta
/// (id % 3), a mesma regra do backend. Isso funciona porque as 3 agencias
/// assinam o JWT com o mesmo segredo: o token vale em qualquer uma.
class ApiClient {
  ApiClient(this.sessao, {http.Client? cliente}) : _http = cliente ?? http.Client();

  final Sessao sessao;
  final http.Client _http;

  Future<Object?> _requisicao(
    int agencia,
    String metodo,
    String caminho, {
    Map<String, Object?>? corpo,
  }) async {
    final uri = Uri.parse('${urlAgencia(agencia)}$caminho');
    final cabecalhos = <String, String>{};
    final token = sessao.token;
    if (token != null) cabecalhos['Authorization'] = 'Bearer $token';
    if (corpo != null) cabecalhos['Content-Type'] = 'application/json';

    final http.Response resposta;
    try {
      final envio = metodo == 'GET'
          ? _http.get(uri, headers: cabecalhos)
          : _http.post(uri, headers: cabecalhos, body: jsonEncode(corpo));
      resposta = await envio.timeout(timeoutRequisicao);
    } on TimeoutException {
      throw ApiErro(0, 'Agencia $agencia nao respondeu a tempo.', agencia: agencia);
    } on http.ClientException {
      // Conexao recusada / sem rede. O pacote http embrulha o erro de socket
      // nesta excecao, tanto no Android quanto no navegador.
      throw ApiErro(0, 'Sem conexao com a agencia $agencia.', agencia: agencia);
    }

    Object? json;
    if (resposta.bodyBytes.isNotEmpty) {
      try {
        json = jsonDecode(utf8.decode(resposta.bodyBytes));
      } on FormatException {
        json = null;
      }
    }

    if (resposta.statusCode < 200 || resposta.statusCode >= 300) {
      var mensagem = 'Erro HTTP ${resposta.statusCode}';
      if (json is Map && json['erro'] != null) mensagem = json['erro'].toString();
      throw ApiErro(resposta.statusCode, mensagem, agencia: agencia, corpo: json);
    }
    return json;
  }

  /// Faz login e guarda o token na sessao.
  ///
  /// Tenta a agencia 0; se ela nao responder, tenta a 1 e depois a 2 - qualquer
  /// uma serve, porque o segredo do JWT e o mesmo nas tres. Erros com resposta
  /// (ex.: 401 de credenciais invalidas) nao passam para a proxima agencia: a
  /// resposta seria a mesma.
  Future<void> login(String usuario, String senha) async {
    ApiErro? ultimaFalha;
    for (final agencia in idsAgencias) {
      try {
        final json = await _requisicao(
          agencia,
          'POST',
          '/auth/login',
          corpo: {'usuario': usuario, 'senha': senha},
        ) as Map<String, dynamic>;
        await sessao.salvar(
          json['access_token'] as String,
          (json['expiracao_min'] as num?)?.toInt() ?? 30,
        );
        return;
      } on ApiErro catch (erro) {
        if (!erro.semConexao) rethrow;
        ultimaFalha = erro;
      }
    }
    throw ApiErro(
      0,
      'Nenhuma agencia respondeu. Elas estao no ar? (${ultimaFalha?.mensagem ?? ''})',
    );
  }

  Future<void> logout() => sessao.limpar();

  /// Saldo da conta, consultado na agencia dona dela.
  Future<Conta> consultarSaldo(int idConta) async {
    final json = await _requisicao(agenciaResponsavel(idConta), 'GET', '/contas/$idConta');
    return Conta.fromJson(json as Map<String, dynamic>);
  }
}
