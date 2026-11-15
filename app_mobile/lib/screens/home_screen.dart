import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../config.dart';
import '../models/conta.dart';
import '../models/operacao_pendente.dart';
import '../services/api_client.dart';
import '../services/armazenamento_local.dart';
import '../services/monitor_lideranca.dart';
import '../services/sincronizador.dart';
import '../util/formatacao.dart';
import '../widgets/cartao_conta.dart';
import '../widgets/dialogo_operacao.dart';
import '../widgets/lista_pendentes.dart';
import '../widgets/mensagem_erro.dart';
import '../widgets/painel_lideranca.dart';
import 'login_screen.dart';

/// Tela principal: painel da lider (atualizado sozinho), consulta de saldo e as
/// operacoes da conta consultada (deposito, saque, transferencia).
///
/// Parte F (offline-first): o cartao da conta e sempre montado a partir do
/// cache local; sem conexao com a agencia, depositos e saques entram na fila de
/// pendentes do Sincronizador em vez de falhar.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.api, required this.armazenamento});

  final ApiClient api;
  final ArmazenamentoLocal armazenamento;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _idConta = TextEditingController();
  late final MonitorLideranca _monitor;
  late final Sincronizador _sincronizador;
  late final AppLifecycleListener _ciclodeVida;
  late final StreamSubscription<AvisoSincronizacao> _assinaturaAvisos;

  bool _carregando = false;
  bool _semAgencias = false;

  /// Conta exibida. Os dados dela vem do cache (Sincronizador.contaEmCache).
  int? _idExibido;
  String? _erro;

  @override
  void initState() {
    super.initState();
    _monitor = MonitorLideranca(widget.api)
      ..addListener(_aoMudarLideranca)
      ..iniciar();
    _sincronizador = Sincronizador(widget.api, widget.armazenamento)
      ..addListener(_aoMudarFila)
      ..aoReconectar = _atualizarContaExibida
      ..iniciar();
    _assinaturaAvisos = _sincronizador.avisos.listen(_aoAviso);
    // App em segundo plano nao precisa consultar a lider nem tentar sincronizar:
    // pausa os dois e retoma ao voltar. No Android o connectivity_plus nao
    // recebe eventos em segundo plano, entao a volta tambem e um gatilho.
    _ciclodeVida = AppLifecycleListener(
      onResume: () {
        _monitor.iniciar();
        _sincronizador.iniciar();
      },
      onHide: () {
        _monitor.parar();
        _sincronizador.parar();
      },
    );
  }

  @override
  void dispose() {
    _ciclodeVida.dispose();
    _assinaturaAvisos.cancel();
    _sincronizador.dispose();
    _monitor.dispose();
    _idConta.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------ eventos

  void _aoMudarFila() {
    if (mounted) setState(() {});
  }

  /// Gatilho extra de sincronizacao: o painel passou de "nenhuma agencia
  /// respondeu" para uma resposta. Funciona mesmo quando o evento de rede do
  /// connectivity_plus nao chega (ex.: agencia que caiu e voltou).
  void _aoMudarLideranca() {
    final semAgencias = _monitor.estado.erro != null;
    if (_semAgencias && !semAgencias) _sincronizador.agenciaVoltou();
    _semAgencias = semAgencias;
  }

  void _aoAviso(AvisoSincronizacao aviso) {
    if (aviso.precisaLogin) {
      _voltarAoLogin(aviso.texto);
      return;
    }
    if (!mounted) return;
    final cores = Theme.of(context).colorScheme;
    // Sem hideCurrentSnackBar: avisos de sincronizacao entram na fila do
    // ScaffoldMessenger, para nenhum (ex.: um conflito) sumir antes de ser lido.
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(aviso.texto, style: aviso.problema ? TextStyle(color: cores.onErrorContainer) : null),
      backgroundColor: aviso.problema ? cores.errorContainer : null,
      duration: Duration(seconds: aviso.problema ? 10 : 5),
      showCloseIcon: true,
    ));
  }

  /// Depois de uma reconexao, busca de novo a conta exibida, para o cartao
  /// deixar de mostrar o dado antigo como "offline".
  Future<void> _atualizarContaExibida() async {
    final id = _idExibido;
    if (id == null || _carregando) return;
    try {
      await _lerConta(id);
    } on ApiErro {
      // Ainda sem conexao: o cartao continua com o ultimo dado conhecido.
    }
  }

  // ------------------------------------------------------------ acoes

  /// GET da conta; sucesso vai para o cache local, falta de conexao marca a
  /// agencia como sem resposta.
  Future<Conta> _lerConta(int id) async {
    try {
      final conta = await widget.api.consultarSaldo(id);
      await _sincronizador.registrarLeitura(conta);
      return conta;
    } on ApiErro catch (erro) {
      if (erro.semConexao) _sincronizador.marcarSemResposta(agenciaResponsavel(id));
      rethrow;
    }
  }

  Future<void> _consultar() async {
    final id = int.tryParse(_idConta.text.trim());
    if (id == null) {
      setState(() => _erro = 'Informe o número da conta.');
      return;
    }
    await _executar(() async {
      try {
        await _lerConta(id);
      } on ApiErro catch (erro) {
        // Sem conexao, mas com dado salvo: mostra o ultimo dado conhecido
        // (o cartao avisa que esta offline e de quando e o dado).
        if (erro.semConexao && _sincronizador.contaEmCache(id) != null) {
          if (mounted) setState(() => _idExibido = id);
          return null;
        }
        if (erro.semConexao) {
          throw ApiErro(
            0,
            '${erro.mensagem} Esta conta ainda não foi consultada neste aparelho, '
            'então não há dado salvo para mostrar offline.',
          );
        }
        rethrow;
      }
      if (mounted) setState(() => _idExibido = id);
      return null;
    }, limparConta: true);
  }

  Future<void> _depositar() async {
    final id = _idExibido!;
    final dados = await pedirOperacao(context, titulo: 'Depositar na conta $id', rotuloConfirmar: 'Depositar');
    if (dados == null) return;
    await _operar(id, tipoDeposito, dados.valor);
  }

  Future<void> _sacar() async {
    final id = _idExibido!;
    final dados = await pedirOperacao(context, titulo: 'Sacar da conta $id', rotuloConfirmar: 'Sacar');
    if (dados == null) return;
    await _operar(id, tipoSaque, dados.valor);
  }

  /// Deposito ou saque: online quando der; sem conexao, vai para a fila.
  Future<void> _operar(int id, String tipo, double valor) async {
    final nome = tipo == tipoSaque ? 'Saque' : 'Depósito';

    // Com operacoes ja na fila, a nova tambem entra nela: aplicar esta direto
    // furaria a ordem e avancaria o vetor da agencia, fazendo as pendentes
    // anteriores darem conflito por causa do proprio app.
    if (_sincronizador.temPendencias(id)) {
      await _guardarOffline(id, tipo, valor, motivo: 'Há operações pendentes nesta conta');
      unawaited(_sincronizador.sincronizar());
      return;
    }

    await _executar(() async {
      try {
        if (tipo == tipoSaque) {
          await widget.api.sacar(id, valor);
        } else {
          await widget.api.depositar(id, valor);
        }
      } on ApiErro catch (erro) {
        if (!erro.semConexao) rethrow;
        _sincronizador.marcarSemResposta(agenciaResponsavel(id));
        await _guardarOffline(id, tipo, valor, motivo: 'Sem conexão com a agência ${agenciaResponsavel(id)}');
        return null;
      }
      return '$nome de ${formatarReais(valor)} realizado.';
    });
  }

  Future<void> _guardarOffline(int id, String tipo, double valor, {required String motivo}) async {
    final nome = tipo == tipoSaque ? 'saque' : 'depósito';
    try {
      await _sincronizador.registrarOffline(id, tipo, valor);
      _avisar('$motivo: $nome de ${formatarReais(valor)} guardado como pendente. '
          'Ele será sincronizado automaticamente quando a conexão voltar.');
    } on OperacaoOfflineInvalida catch (erro) {
      if (mounted) setState(() => _erro = erro.mensagem);
    }
  }

  Future<void> _transferir() async {
    final id = _idExibido!;
    if (_sincronizador.temPendencias(id)) {
      setState(() => _erro = 'Há operações offline pendentes nesta conta. Aguarde a sincronização '
          '(ou resolva o conflito) antes de transferir.');
      return;
    }
    final dados = await pedirOperacao(
      context,
      titulo: 'Transferir da conta $id',
      rotuloConfirmar: 'Transferir',
      contaOrigem: id,
      pedirDestino: true,
    );
    if (dados == null || !mounted) return;
    final destino = dados.contaDestino!;
    await _executar(() async {
      final ResultadoTransferencia resultado;
      try {
        resultado = await widget.api.transferir(id, destino, dados.valor);
      } on ApiErro catch (erro) {
        if (!erro.semConexao) rethrow;
        _sincronizador.marcarSemResposta(agenciaResponsavel(id));
        // Transferencia nao entra na fila: o /sincronizar so aceita deposito e
        // saque, e uma transferencia pode envolver duas agencias (Sprint 2).
        throw ApiErro(
          0,
          '${erro.mensagem} Transferências não ficam pendentes offline: '
          'tente de novo quando a conexão voltar.',
        );
      }
      final valor = formatarReais(dados.valor);
      return resultado.assincrona
          ? 'Transferência de $valor enviada para a conta $destino (agência ${agenciaResponsavel(destino)}). '
              'O débito já foi feito; o crédito chega de forma assíncrona, pelo RabbitMQ.'
          : 'Transferência de $valor para a conta $destino concluída.';
    });
  }

  /// Executa uma chamada a API com indicador de carregamento e erro visivel.
  ///
  /// Depois de uma operacao online bem-sucedida, consulta o saldo de novo: a
  /// resposta do deposito/saque nao traz o vetorAtual, e o cache precisa dele
  /// atualizado para o modo offline.
  Future<void> _executar(Future<String?> Function() acao, {bool limparConta = false}) async {
    setState(() {
      _carregando = true;
      _erro = null;
    });
    try {
      final mensagem = await acao();
      if (mensagem != null) {
        final id = _idExibido;
        if (id != null) {
          try {
            await _lerConta(id);
          } on ApiErro {
            // A operacao ja foi feita; so a releitura falhou. O cartao fica com
            // o ultimo dado conhecido ate a proxima leitura.
          }
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
        if (limparConta) _idExibido = null;
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
    _sincronizador.parar();
    await widget.api.logout();
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(
        builder: (_) => LoginScreen(api: widget.api, armazenamento: widget.armazenamento, aviso: aviso),
      ),
    );
  }

  // ------------------------------------------------------------ tela

  @override
  Widget build(BuildContext context) {
    final id = _idExibido;
    final cache = id == null ? null : _sincronizador.contaEmCache(id);
    final operacoes = id == null ? const <OperacaoPendente>[] : _sincronizador.operacoesDa(id);
    final outrasPendentes = _sincronizador.fila.where((o) => o.idConta != id).length;

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
            if (cache != null) ...[
              const SizedBox(height: 16),
              CartaoConta(
                cache: cache,
                saldoProvisorio: _sincronizador.saldoProvisorio(cache.conta.id) ?? cache.conta.saldo,
                pendentes: operacoes.where((o) => !o.emConflito).length,
                offline: _sincronizador.agenciaSemResposta(cache.conta.agencia),
              ),
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
              if (operacoes.isNotEmpty) ...[
                const SizedBox(height: 16),
                ListaPendentes(
                  operacoes: operacoes,
                  enviandoId: _sincronizador.enviandoId,
                  aoAplicar: _sincronizador.aplicarMesmoAssim,
                  aoDescartar: _sincronizador.descartar,
                  aoSincronizarAgora: _sincronizador.sincronizar,
                ),
              ],
            ],
            if (outrasPendentes > 0) ...[
              const SizedBox(height: 12),
              Text(
                outrasPendentes == 1
                    ? '1 operação offline de outra conta aguardando sincronização.'
                    : '$outrasPendentes operações offline de outras contas aguardando sincronização.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ],
        ),
      ),
    );
  }
}
