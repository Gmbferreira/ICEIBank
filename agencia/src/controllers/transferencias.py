import pika
from fastapi import APIRouter, Depends, HTTPException, Request
from fastapi.concurrency import run_in_threadpool

import src.config as config
from src.controllers.auth import obter_usuario_atual
from src.models.contas import TransferenciaRequest
from src.services.mensageria import descrever_erro, publicar, routing_key_credito

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

    # Caso entre agencias (Sprint 2): em vez de chamar a outra agencia por REST,
    # publica-se um evento na exchange. Quem aplica o credito e a agencia de
    # destino, quando ela estiver disponivel - mesmo que esteja fora do ar no
    # momento da publicacao, porque a mensagem fica retida na fila duravel.
    vetor_envio = relogio.ao_enviar()

    try:
        # O publicacao e bloqueante (pika), entao vai para uma thread do pool:
        # se fosse direto aqui, travaria o event loop do servidor.
        await run_in_threadpool(
            publicar,
            routing_key_credito(agencia_destino),
            {
                "idConta": dados.idDestino,
                "valor": dados.valor,
                "vetorEnvio": vetor_envio,
                "origemAgencia": id_agencia,
            },
        )
    except (pika.exceptions.AMQPError, OSError) as erro:
        # O broker nao assumiu a mensagem, entao o debito acima e desfeito: aqui
        # NAO ha o problema do Sprint 1 (dinheiro pendurado sem entrega). Com a
        # publicacao confirmada pelo broker, "publicou" significa "o broker
        # assumiu a responsabilidade de entregar".
        registro.registrar("TRANSFERENCIA_PUBLICACAO_FALHOU", relogio.evento_local(), {
            "idOrigem": dados.idOrigem,
            "idDestino": dados.idDestino,
            "valor": dados.valor,
            "erro": descrever_erro(erro),
        })
        conta_origem.saldo += dados.valor
        raise HTTPException(
            status_code=502,
            detail="Falha ao publicar a transferencia no broker. Debito revertido.",
        )

    registro.registrar("TRANSFERENCIA_PUBLICADA", vetor_envio, {
        "idOrigem": dados.idOrigem,
        "idDestino": dados.idDestino,
        "valor": dados.valor,
        "agenciaDestino": agencia_destino,
        "routingKey": routing_key_credito(agencia_destino),
    })

    # Repare na mudanca de sentido da resposta: 200 significa "a mensagem foi
    # publicada", nao "o credito ja foi aplicado na outra agencia".
    return {
        "mensagem": "Transferencia publicada para a agencia de destino (entrega assincrona).",
        "status": "publicada",
    }