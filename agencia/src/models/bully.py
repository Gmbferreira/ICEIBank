from pydantic import BaseModel


class EleicaoRequest(BaseModel):
    origemId: int
    vetorEnvio: list[int]


class CoordenadorRequest(BaseModel):
    liderId: int
    vetorEnvio: list[int]
