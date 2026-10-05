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