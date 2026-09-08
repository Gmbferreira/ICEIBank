# OFFSET pessoal (dois últimos dígitos da matrícula/RA) para portas exclusivas.
OFFSET = 21

NUMERO_AGENCIAS = 3
PORTA_BASE = 4000 + OFFSET

AGENCIAS = [
    {"id": 0, "url": f"http://localhost:{PORTA_BASE}"},
    {"id": 1, "url": f"http://localhost:{PORTA_BASE + 1}"},
    {"id": 2, "url": f"http://localhost:{PORTA_BASE + 2}"},
]


def agencia_responsavel(id_conta: int) -> int:
    """Particao: a agencia dona da conta e definida por id_conta % numero_de_agencias."""
    return id_conta % NUMERO_AGENCIAS