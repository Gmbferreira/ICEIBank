import os
from contextlib import asynccontextmanager

from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse

import src.config as config
from src.controllers import auth, bully, contas, transferencias
from src.services.mensageria import (
    CreditoRecusado,
    fechar_publicador,
    iniciar_consumidor,
    parar_consumidor,
)
from src.services.bully_service import ServicoBully
from src.services.registro_eventos import RegistroEventos
from src.services.relogio_vetorial import RelogioVetorial


def processar_credito_remoto(app, mensagem):
    """Consumidor do RabbitMQ: aplica um credito publicado por outra agencia.

    Nao passa pelo HTTP (FastAPI) e portanto nao tem token JWT - a mensagem ja
    foi publicada por outra agencia, dentro do mesmo dominio de confianca do
    banco (ver discussao em RESPOSTAS.md, Parte C).

    O log do vetor e o ponto central do sprint: o vetor recebido vem anexado na
    mensagem e e incorporado pela regra 3 (ao_receber) antes de registrar o
    evento, e o que fica gravado e o vetor RESULTANTE - e ele que permite dizer
    mais tarde se este credito foi causa de algum evento local posterior.

    Levantar CreditoRecusado (e nao apenas registrar e voltar) e o que leva a
    mensagem para a dead-letter queue: um return aqui faria o consumidor
    confirmar (ack) o delivery_tag e o credito nao aplicavel sumiria sem deixar
    rastro.
    """
    relogio = app.state.relogio
    registro = app.state.registro
    contas = app.state.contas

    id_conta = mensagem["idConta"]
    valor = mensagem["valor"]
    origem_agencia = mensagem["origemAgencia"]

    vetor = relogio.ao_receber(mensagem["vetorEnvio"])

    conta = contas.get(id_conta)
    if conta is None:
        # Caso conhecido e reproduzido na Parte C: as contas vivem em memoria,
        # entao se esta agencia reiniciou, a conta que deveria receber o credito
        # nao existe mais - a mensagem chegou, mas nao ha onde aplicar o valor.
        motivo = "conta nao encontrada"
        registro.registrar("CREDITO_REMOTO_FALHOU", vetor, {
            "idConta": id_conta,
            "valor": valor,
            "origemAgencia": origem_agencia,
            "motivo": motivo,
        })
        raise CreditoRecusado(
            f"conta {id_conta} nao existe nesta agencia (credito de {valor} "
            f"publicado pela agencia {origem_agencia})"
        )

    conta.saldo += valor
    registro.registrar("TRANSFERENCIA_CREDITO_REMOTO", vetor, {
        "idConta": id_conta,
        "valor": valor,
        "origemAgencia": origem_agencia,
    })


def create_app():
    id_agencia = int(os.getenv("AGENCIA_ID", "0"))
    agencia_config = next((a for a in config.AGENCIAS if a["id"] == id_agencia), None)
    if agencia_config is None:
        raise RuntimeError(f"Agencia {id_agencia} nao configurada em config.py")

    @asynccontextmanager
    async def lifespan(app):
        # O consumidor sobe junto com o servidor: sem ele, esta agencia nao
        # receberia os creditos publicados pelas outras.
        iniciar_consumidor(id_agencia, lambda mensagem: processar_credito_remoto(app, mensagem))
        # Sprint 3: ao subir, a agencia ja dispara a propria eleicao para descobrir
        # (ou estabelecer) quem e a lider. Vai em segundo plano: se rodasse aqui
        # dentro do startup, o servidor so aceitaria conexoes depois de a eleicao
        # terminar, e nao conseguiria responder as eleicoes das outras agencias.
        app.state.bully.agendar_eleicao()
        yield
        app.state.bully.encerrar()
        parar_consumidor()
        fechar_publicador()

    app = FastAPI(title=f"ICEIBank - Agencia {id_agencia}", lifespan=lifespan)

    # CORS liberado para desenvolvimento (o frontend roda em outra porta).
    app.add_middleware(
        CORSMiddleware,
        allow_origins=["*"],
        allow_credentials=False,
        allow_methods=["*"],
        allow_headers=["*"],
    )

    # Estado compartilhado por todos os controllers desta agencia.
    app.state.id_agencia = id_agencia
    app.state.relogio = RelogioVetorial(id_agencia, config.NUMERO_AGENCIAS)
    app.state.registro = RegistroEventos(f"agencia-{id_agencia}")
    app.state.contas = {}
    app.state.bully = ServicoBully(id_agencia, app.state.relogio, app.state.registro)

    @app.exception_handler(HTTPException)
    async def http_exception_handler(request, exc):
        # Mesmo formato de erro do exemplo da disciplina: {"erro": "..."}.
        return JSONResponse(status_code=exc.status_code, content={"erro": exc.detail})

    app.include_router(auth.router)
    app.include_router(contas.router)
    app.include_router(transferencias.router)
    app.include_router(bully.router)
    return app


app = create_app()