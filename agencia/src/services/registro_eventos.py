import json
import os
from datetime import datetime, timezone


class RegistroEventos:
    """Grava eventos da agencia em um arquivo JSONL (uma linha JSON por evento).

    Cada evento guarda dois carimbos de tempo:
      - timestampVetorial: o relogio vetorial (usado para tomada de decisao).
                           E um vetor com uma posicao por agencia, o que permite
                           afirmar, alem da ordem, se dois eventos sao causais ou
                           concorrentes.
      - horaParede:        o relogio fisico da maquina, apenas para fins de
                           comparação na linha do tempo (nao usado em decisao).
    """

    def __init__(self, nome_agencia):
        self.nome_agencia = nome_agencia
        # src/services/ -> src/ -> agencia/ -> data/
        pasta_agencia = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
        pasta_dados = os.path.join(pasta_agencia, "data")
        os.makedirs(pasta_dados, exist_ok=True)
        self.caminho_arquivo = os.path.join(pasta_dados, f"eventos-{nome_agencia}.jsonl")

    def registrar(self, tipo, timestamp_vetorial, detalhes):
        evento = {
            "agencia": self.nome_agencia,
            "tipo": tipo,
            "timestampVetorial": timestamp_vetorial,
            "horaParede": datetime.now(timezone.utc).isoformat(),
            "detalhes": detalhes,
        }
        with open(self.caminho_arquivo, "a", encoding="utf-8") as arquivo:
            arquivo.write(json.dumps(evento, ensure_ascii=False) + "\n")
        # flush=True e obrigatorio: em terminal o stdout e line-buffered e a
        # linha aparece na hora, mas com a saida redirecionada para arquivo
        # (Test-Path, Tee-Object, log de evidencia) o Python usa buffer de bloco e
        # o evento so apareceria no fim do processo - ou nunca, se o processo fosse
        # derrubado com Ctrl+C antes.
        print(f"[Vetor {timestamp_vetorial}] {tipo} {detalhes}", flush=True)
        return evento

    def ler_eventos(self):
        if not os.path.exists(self.caminho_arquivo):
            return []
        eventos = []
        with open(self.caminho_arquivo, encoding="utf-8") as arquivo:
            for linha in arquivo:
                if linha.strip():
                    eventos.append(json.loads(linha))
        return eventos

    def ler_eventos_por_conta(self, id_conta):
        """Funcionalidade adicional: eventos de uma conta, ordenados pelo vetor."""
        eventos = []
        for evento in self.ler_eventos():
            detalhes = evento.get("detalhes", {})
            if (
                detalhes.get("id") == id_conta
                or detalhes.get("idOrigem") == id_conta
                or detalhes.get("idDestino") == id_conta
                or detalhes.get("idConta") == id_conta
            ):
                eventos.append(evento)
        # Em Python, listas sao comparaveis elemento a elemento: o sort usa o
        # vetor como chave, nao o numero de Lamport do Sprint 1.
        eventos.sort(key=lambda e: e["timestampVetorial"])
        return eventos