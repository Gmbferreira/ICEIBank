import asyncio

import httpx

import src.config as config

# Tempo maximo de espera por uma resposta de outra agencia. Passou disso, a
# agencia e tratada como fora do ar (ver pergunta 3 da Parte B em RESPOSTAS.md).
TIMEOUT_SEGUNDOS = 1.0


class ServicoBully:
    """Eleicao de lider pelo algoritmo de Bully (Garcia-Molina, 1982).

    Regra central: vence sempre a agencia de MAIOR id entre as que estao ativas.
      1. Quem inicia uma eleicao manda ELEICAO para todas as agencias de id maior.
      2. Se nenhuma responder, ela mesma vira lider e anuncia (COORDENADOR) a todas.
      3. Se alguma maior responder, essa assume a eleicao - quem perguntou so espera
         o anuncio do coordenador.
      4. Quem recebe ELEICAO de um id menor responde (o 200 da rota e o "OK") e
         inicia a propria eleicao, porque tambem e candidata.

    Concorrencia: tudo aqui roda no event loop do FastAPI (rotas async e tarefas
    asyncio), entao lider_atual e eleicao_em_andamento so sao alterados por uma
    unica thread e nao precisam de lock. O relogio vetorial, que tambem e usado
    pela thread do consumidor do RabbitMQ, ja tem a propria lock.
    """

    def __init__(self, id_agencia, relogio, registro):
        self.id_agencia = id_agencia
        self.relogio = relogio
        self.registro = registro
        self.lider_atual = None
        self.eleicao_em_andamento = False
        # O asyncio guarda so referencias fracas das tarefas criadas com
        # create_task: sem guardar aqui, uma eleicao em segundo plano poderia ser
        # coletada pelo garbage collector no meio da execucao.
        self._tarefas = set()

    def _agencias_com_id_maior(self):
        return [a for a in config.AGENCIAS if a["id"] > self.id_agencia]

    def _outras_agencias(self):
        return [a for a in config.AGENCIAS if a["id"] != self.id_agencia]

    async def _enviar(self, cliente, url, corpo):
        """POST para outra agencia. Devolve True se ela respondeu com sucesso.

        Qualquer httpx.HTTPError (conexao recusada, timeout, resposta 4xx/5xx via
        raise_for_status) conta como "nao respondeu" - mesmo comportamento do
        axios no exemplo em Node, que lanca excecao nesses tres casos.
        """
        try:
            resposta = await cliente.post(url, json=corpo)
            resposta.raise_for_status()
            return True
        except httpx.HTTPError:
            return False

    def agendar_eleicao(self):
        """Dispara uma eleicao em segundo plano, sem esperar o resultado."""
        tarefa = asyncio.create_task(self.iniciar_eleicao())
        self._tarefas.add(tarefa)
        tarefa.add_done_callback(self._tarefas.discard)

    async def iniciar_eleicao(self):
        if self.eleicao_em_andamento:
            return
        self.eleicao_em_andamento = True
        vetor = self.relogio.evento_local()
        self.registro.registrar("ELEICAO_INICIADA", vetor, {"idAgencia": self.id_agencia})

        alguem_respondeu = False
        async with httpx.AsyncClient(timeout=TIMEOUT_SEGUNDOS) as cliente:
            for agencia in self._agencias_com_id_maior():
                vetor_envio = self.relogio.ao_enviar()
                respondeu = await self._enviar(
                    cliente,
                    f"{agencia['url']}/bully/eleicao",
                    {"origemId": self.id_agencia, "vetorEnvio": vetor_envio},
                )
                alguem_respondeu = alguem_respondeu or respondeu

        self.eleicao_em_andamento = False

        if not alguem_respondeu:
            await self.tornar_me_lider()
        # Se alguem maior respondeu, e essa agencia quem conduz a propria eleicao
        # e, no fim, anuncia o resultado via /bully/coordenador.

    async def tornar_me_lider(self):
        self.lider_atual = self.id_agencia
        vetor = self.relogio.evento_local()
        self.registro.registrar("TORNOU_LIDER", vetor, {"idAgencia": self.id_agencia})

        async with httpx.AsyncClient(timeout=TIMEOUT_SEGUNDOS) as cliente:
            for agencia in self._outras_agencias():
                vetor_envio = self.relogio.ao_enviar()
                # Agencia fora do ar e ignorada: ela descobre a lider quando voltar
                # (ao subir, ela mesma inicia uma eleicao).
                await self._enviar(
                    cliente,
                    f"{agencia['url']}/bully/coordenador",
                    {"liderId": self.id_agencia, "vetorEnvio": vetor_envio},
                )

    def receber_eleicao(self, origem_id, vetor_recebido):
        vetor = self.relogio.ao_receber(vetor_recebido)
        self.registro.registrar("ELEICAO_RECEBIDA", vetor, {"de": origem_id, "minhaId": self.id_agencia})
        # A rota devolve 200 logo em seguida (o "OK" implicito), e a propria
        # eleicao roda em segundo plano. Se a rota esperasse essa eleicao terminar,
        # ela consultaria as agencias maiores e a resposta passaria de 1 segundo:
        # quem perguntou acharia que esta agencia esta fora do ar.
        self.agendar_eleicao()

    def receber_coordenador(self, lider_id, vetor_recebido):
        self.lider_atual = lider_id
        vetor = self.relogio.ao_receber(vetor_recebido)
        self.registro.registrar("LIDER_ANUNCIADO", vetor, {"liderId": lider_id, "agencia": self.id_agencia})

    def obter_lider_atual(self):
        return self.lider_atual

    def encerrar(self):
        """Cancela eleicoes ainda em andamento quando o servidor desliga."""
        for tarefa in list(self._tarefas):
            tarefa.cancel()
