import threading

from src.services.comparar_vetores import comparar_vetores


class RelogioVetorial:
    """Relogio vetorial: um contador por agencia, comparavel componente a componente.

    Tres regras:
      1. evento_local:  incrementa a propria posicao do vetor.
      2. ao_enviar:     incrementa a propria posicao e anexa o vetor a mensagem.
      3. ao_receber:    para todo i, vetor[i] = max(vetor[i], vetor_recebido[i]);
                        depois incrementa a propria posicao.

    Por que substitui o relogio de Lamport (Sprint 1): um unico numero so
    garante a ordem de ida ("se A causou B, entao timestamp(A) < timestamp(B)").
    Com numeros diferentes nao da para saber se A causou B ou se os dois eventos
    sao concorrentes. O vetor separa os dois casos: A causou B sse vetor(A) <=
    vetor(B) em todas as posicoes; caso nenhum vetor seja menor-ou-igual ao
    outro, sao comprovadamente concorrentes.

    Todas as operacoes devolvem uma COPIA do vetor (list), para que quem recebe
    nao consiga alterar o estado interno do relogio.
    """

    def __init__(self, id_agencia, numero_agencias):
        self.id_agencia = id_agencia
        self.vetor = [0] * numero_agencias
        # Em Python com FastAPI, requisições concorrentes podem acessar o mesmo
        # vetor (ex.: uvicorn multi-thread), e no Sprint 2 o consumidor de
        # mensagens roda em outra thread. A lock evita condição de corrida nas
        # tres operações - mesmo cuidado do "synchronized" do exemplo Java.
        self._lock = threading.Lock()

    def evento_local(self):
        with self._lock:
            self.vetor[self.id_agencia] += 1
            return list(self.vetor)

    def ao_enviar(self):
        with self._lock:
            self.vetor[self.id_agencia] += 1
            return list(self.vetor)

    def ao_receber(self, vetor_recebido):
        with self._lock:
            for i in range(len(self.vetor)):
                self.vetor[i] = max(self.vetor[i], vetor_recebido[i])
            self.vetor[self.id_agencia] += 1
            return list(self.vetor)

    # ------------------------------------------------------------ Sprint 3

    def obter_vetor_atual(self):
        """Le o vetor SEM incrementa-lo (ler nao e um evento).

        Usado pela consulta de saldo: o app guarda esse vetor e o devolve depois,
        ao sincronizar uma operacao feita offline.
        """
        with self._lock:
            return list(self.vetor)

    def executar_se_atual(self, vetor_conhecido, operacao):
        """Compara e aplica de forma atomica (sincronizacao offline-first).

        Dentro da lock do relogio:
          - se vetor_conhecido == vetor atual, nada aconteceu na agencia desde a
            leitura do app: executa `operacao()` e registra o evento local
            (incrementa a propria posicao);
          - senao, nao executa nada.

        Devolve (relacao, vetor): a relacao vetor_conhecido x vetor atual
        ("IGUAIS", "ANTES", "DEPOIS" ou "CONCORRENTES") e o vetor resultante.

        Por que comparar e aplicar juntos: no exemplo em Node (uma thread so) a
        comparacao e a aplicacao em sequencia sao seguras. Aqui as rotas "def"
        rodam numa pool de threads e o consumidor do RabbitMQ em outra thread:
        entre comparar e aplicar, um deposito concorrente poderia avancar o vetor,
        e a operacao offline seria aplicada as cegas - exatamente o que este
        endpoint existe para impedir. Como TODO evento da agencia incrementa o
        vetor passando por esta mesma lock, comparar e incrementar aqui dentro
        fecha essa janela.

        Se `operacao()` levantar excecao (ex.: saldo insuficiente), o vetor nao e
        incrementado e a excecao sobe para quem chamou.
        """
        with self._lock:
            relacao = comparar_vetores(vetor_conhecido, self.vetor)
            if relacao != "IGUAIS":
                return relacao, list(self.vetor)
            operacao()
            self.vetor[self.id_agencia] += 1
            return relacao, list(self.vetor)
