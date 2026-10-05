import threading


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