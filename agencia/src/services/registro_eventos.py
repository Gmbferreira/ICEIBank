import json
import os
from datetime import datetime, timezone


class RegistroEventos:
    """Grava eventos da agencia em um arquivo JSONL (uma linha JSON por evento).

    Cada evento guarda dois carimbos de tempo:
      - timestampLamport: o relogio logico (usado para tomada de decisao).
      - horaParede:       o relogio fisico da maquina, apenas para fins de
                          comparação na linha do tempo (nao usado em decisao).
    """

    def __init__(self, nome_agencia):
        self.nome_agencia = nome_agencia
        # src/services/ -> src/ -> agencia/ -> data/
        pasta_agencia = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
        pasta_dados = os.path.join(pasta_agencia, "data")
        os.makedirs(pasta_dados, exist_ok=True)
        self.caminho_arquivo = os.path.join(pasta_dados, f"eventos-{nome_agencia}.jsonl")

    def registrar(self, tipo, timestamp_lamport, detalhes):
        evento = {
            "agencia": self.nome_agencia,
            "tipo": tipo,
            "timestampLamport": timestamp_lamport,
            "horaParede": datetime.now(timezone.utc).isoformat(),
            "detalhes": detalhes,
        }
        with open(self.caminho_arquivo, "a", encoding="utf-8") as arquivo:
            arquivo.write(json.dumps(evento, ensure_ascii=False) + "\n")
        print(f"[Lamport {timestamp_lamport}] {tipo} {detalhes}")
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
        """Funcionalidade adicional: eventos de uma conta, ordenados por Lamport."""
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
        eventos.sort(key=lambda e: e["timestampLamport"])
        return eventos