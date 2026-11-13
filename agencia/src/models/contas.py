from pydantic import BaseModel


class Conta(BaseModel):
    id: int
    nomeAluno: str
    saldo: float


class CriarContaRequest(BaseModel):
    id: int
    nomeAluno: str
    saldoInicial: float = 0.0


class ValorRequest(BaseModel):
    valor: float


class TransferenciaRequest(BaseModel):
    idOrigem: int
    idDestino: int
    valor: float


class LoginRequest(BaseModel):
    usuario: str
    senha: str


class SincronizarRequest(BaseModel):
    """Operacao feita offline pelo app, enviada ao reconectar (Sprint 3, Parte E).

    tipo:           "DEPOSITO" ou "SAQUE" (validado no controller, para devolver
                    400 no formato {"erro": ...} em vez do 422 do pydantic).
    vetorConhecido: o vetorAtual que o app tinha na ultima leitura da conta.
    """

    tipo: str
    valor: float
    vetorConhecido: list[int]
