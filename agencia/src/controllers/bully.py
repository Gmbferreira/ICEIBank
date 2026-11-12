from fastapi import APIRouter, Request

from src.models.bully import CoordenadorRequest, EleicaoRequest

router = APIRouter(prefix="/bully", tags=["bully"])

# As tres rotas sao "async def" de proposito: assim rodam no event loop do
# servidor, o mesmo das tarefas de eleicao (asyncio.create_task exige um loop
# rodando na thread atual). Uma rota "def" comum rodaria numa thread do pool.
#
# Sem JWT, como no roteiro: sao mensagens entre agencias, nao de clientes (ver
# pergunta 3 da Parte A em RESPOSTAS.md).


@router.post("/eleicao")
async def receber_eleicao(request: Request, dados: EleicaoRequest):
    request.app.state.bully.receber_eleicao(dados.origemId, dados.vetorEnvio)
    return {"mensagem": "OK"}


@router.post("/coordenador")
async def receber_coordenador(request: Request, dados: CoordenadorRequest):
    request.app.state.bully.receber_coordenador(dados.liderId, dados.vetorEnvio)
    return {"mensagem": "OK"}


@router.get("/lider")
async def obter_lider(request: Request):
    return {
        "idAgencia": request.app.state.id_agencia,
        "liderAtual": request.app.state.bully.obter_lider_atual(),
    }
