import httpx
from fastapi import APIRouter, Depends, HTTPException, Request

import src.config as config
from src.controllers.auth import obter_token_servico, obter_usuario_atual
from src.models.contas import CreditarRemotoRequest, TransferenciaRequest
from src.services.auth_service import gerar_token_servico

router = APIRouter(tags=["transferencias"])


@router.post("/transferencias", dependencies=[Depends(obter_usuario_atual)])
async def transferir(request: Request, dados: TransferenciaRequest):
    relogio = request.app.state.relogio
    registro = request.app.state.registro
    contas = request.app.state.contas
    id_agencia = request.app.state.id_agencia

    conta_origem = contas.get(dados.idOrigem)
    if conta_origem is None:
        raise HTTPException(status_code=404, detail="Conta de origem nao encontrada nesta agencia.")
    if conta_origem.saldo < dados.valor:
        raise HTTPException(status_code=400, detail="Saldo insuficiente.")

    agencia_destino = config.agencia_responsavel(dados.idDestino)

    # O debito e sempre local, pois esta agencia e a dona da conta de origem.
    vetor_debito = relogio.evento_local()
    conta_origem.saldo -= dados.valor
    registro.registrar("TRANSFERENCIA_DEBITO", vetor_debito, {
        "idOrigem": dados.idOrigem,
        "idDestino": dados.idDestino,
        "valor": dados.valor,
    })

    if agencia_destino == id_agencia:
        # Caso simples: mesma agencia, credita direto (sem mensagem entre agencias,
        # portanto sem ao_enviar/ao_receber do relogio vetorial).
        conta_destino = contas.get(dados.idDestino)
        if conta_destino is None:
            conta_origem.saldo += dados.valor
            raise HTTPException(status_code=404, detail="Conta de destino nao encontrada.")
        vetor_credito = relogio.evento_local()
        conta_destino.saldo += dados.valor
        registro.registrar("TRANSFERENCIA_CREDITO", vetor_credito, {
            "idOrigem": dados.idOrigem,
            "idDestino": dados.idDestino,
            "valor": dados.valor,
        })
        return {"mensagem": "Transferencia concluida (mesma agencia)."}

    # Caso entre agencias: chama a agencia de destino diretamente via REST.
    vetor_envio = relogio.ao_enviar()
    url_destino = next(a for a in config.AGENCIAS if a["id"] == agencia_destino)["url"]
    token_servico = gerar_token_servico(id_agencia)

    try:
        async with httpx.AsyncClient(timeout=5.0) as cliente:
            resposta = await cliente.post(
                f"{url_destino}/contas/{dados.idDestino}/creditar-remoto",
                json={
                    "valor": dados.valor,
                    "timestampVetorial": vetor_envio,
                    "origemAgencia": id_agencia,
                },
                headers={"Authorization": f"Bearer {token_servico}"},
            )
        resposta.raise_for_status()
    except httpx.HTTPError as erro:
        # LIMITACAO CONHECIDA: se esta chamada falhar, o debito ja aplicado
        # acima NAO e revertido - o dinheiro "desaparece" temporariamente.
        # Resolver isso de forma correta (atomicidade sob falha) e assunto do
        # Sprint 4 (transacao distribuida 2PC/Saga). Aqui registramos a
        # inconsistencia no log.
        registro.registrar("TRANSFERENCIA_FALHOU", relogio.evento_local(), {
            "idOrigem": dados.idOrigem,
            "idDestino": dados.idDestino,
            "valor": dados.valor,
            "erro": str(erro),
        })
        raise HTTPException(
            status_code=502,
            detail="Falha ao contatar agencia de destino. Debito ja aplicado - inconsistencia conhecida (ver Sprint 4).",
        )

    return {"mensagem": "Transferencia concluida (entre agencias)."}


@router.post("/contas/{id_conta}/creditar-remoto", dependencies=[Depends(obter_token_servico)])
def creditar_remoto(request: Request, id_conta: int, dados: CreditarRemotoRequest):
    relogio = request.app.state.relogio
    registro = request.app.state.registro
    contas = request.app.state.contas

    # Ao RECEBER uma mensagem de outra agencia, o relogio vetorial e atualizado
    # com base no vetor recebido - regra 3 do algoritmo.
    vetor = relogio.ao_receber(dados.timestampVetorial)

    conta = contas.get(id_conta)
    if conta is None:
        raise HTTPException(status_code=404, detail="Conta nao encontrada nesta agencia.")

    conta.saldo += dados.valor
    registro.registrar("TRANSFERENCIA_CREDITO_REMOTO", vetor, {
        "idConta": id_conta,
        "valor": dados.valor,
        "origemAgencia": dados.origemAgencia,
    })
    return {"mensagem": "Credito remoto aplicado.", "saldoAtual": conta.saldo}