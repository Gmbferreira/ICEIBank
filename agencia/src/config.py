# OFFSET pessoal (dois últimos dígitos da matrícula/RA) para portas exclusivas.
OFFSET = 21

NUMERO_AGENCIAS = 3
PORTA_BASE = 4000 + OFFSET

# 127.0.0.1 e nao "localhost": no Windows, localhost tenta primeiro o IPv6 (::1),
# onde o uvicorn nao escuta, e so depois cai no IPv4 - o que pode levar perto de
# 2 s. Com o timeout de 1 s do Bully, uma agencia VIVA seria tratada como fora do
# ar, e o heartbeat dispararia eleicoes falsas a cada ciclo.
AGENCIAS = [
    {"id": 0, "url": f"http://127.0.0.1:{PORTA_BASE}"},
    {"id": 1, "url": f"http://127.0.0.1:{PORTA_BASE + 1}"},
    {"id": 2, "url": f"http://127.0.0.1:{PORTA_BASE + 2}"},
]


def agencia_responsavel(id_conta: int) -> int:
    """Particao: a agencia dona da conta e definida por id_conta % numero_de_agencias."""
    return id_conta % NUMERO_AGENCIAS