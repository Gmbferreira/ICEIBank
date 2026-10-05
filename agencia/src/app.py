import os

from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse

import src.config as config
from src.controllers import auth, contas, transferencias
from src.services.registro_eventos import RegistroEventos
from src.services.relogio_vetorial import RelogioVetorial


def create_app():
    id_agencia = int(os.getenv("AGENCIA_ID", "0"))
    agencia_config = next((a for a in config.AGENCIAS if a["id"] == id_agencia), None)
    if agencia_config is None:
        raise RuntimeError(f"Agencia {id_agencia} nao configurada em config.py")

    app = FastAPI(title=f"ICEIBank - Agencia {id_agencia}")

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

    @app.exception_handler(HTTPException)
    async def http_exception_handler(request, exc):
        # Mesmo formato de erro do exemplo da disciplina: {"erro": "..."}.
        return JSONResponse(status_code=exc.status_code, content={"erro": exc.detail})

    app.include_router(auth.router)
    app.include_router(contas.router)
    app.include_router(transferencias.router)
    return app


app = create_app()