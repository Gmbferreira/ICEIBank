import threading


class RelogioLamport:
    """Relogio logico de Lamport (carimbo de tempo parcialmente ordenado).

    Tres regras:
      1. evento_local:  incrementa e usa o valor.
      2. ao_enviar:     incrementa e anexa o valor a mensagem.
      3. ao_receber:    contador = max(contador_local, timestamp_recebido) + 1.
    """

    def __init__(self):
        self.contador = 0
        # Em Python com FastAPI, requisições concorrentes podem acessar o mesmo
        # contador (ex.: uvicorn multi-thread). A lock evita condição de corrida
        # nas tres operações - o mesmo cuidado do "synchronized" do exemplo Java.
        self._lock = threading.Lock()

    def evento_local(self):
        with self._lock:
            self.contador += 1
            return self.contador

    def ao_enviar(self):
        with self._lock:
            self.contador += 1
            return self.contador

    def ao_receber(self, timestamp_recebido):
        with self._lock:
            self.contador = max(self.contador, timestamp_recebido) + 1
            return self.contador