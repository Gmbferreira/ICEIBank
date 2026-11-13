from fastapi import APIRouter, Depends, HTTPException, Request
from fastapi.responses import JSONResponse

import src.config as config
from src.controllers.auth import obter_usuario_atual
from src.models.contas import Conta, CriarContaRequest, SincronizarRequest, ValorRequest

router = APIRouter(prefix="/contas", tags=["contas"])

TIPOS_SINCRONIZAVEIS = ("DEPOSITO", "SAQUE")


def conta_como_dict(conta):
    """Conta -> dict, no pydantic 2 (model_dump) ou no 1 (dict)."""
    return conta.model_dump() if hasattr(conta, "model_dump") else conta.dict()


@router.post("", status_code=201, dependencies=[Depends(obter_usuario_atual)])
def criar_conta(request: Request, dados: CriarContaRequest):
    relogio = request.app.state.relogio
    registro = request.app.state.registro
    contas = request.app.state.contas
    id_agencia = request.app.state.id_agencia

    if config.agencia_responsavel(dados.id) != id_agencia:
        raise HTTPException(status_code=400, detail=f"Conta {dados.id} nao pertence a esta agencia.")
    if dados.id in contas:
        raise HTTPException(status_code=409, detail="Conta ja existe.")

    ts = relogio.evento_local()
    conta = Conta(id=dados.id, nomeAluno=dados.nomeAluno, saldo=dados.saldoInicial)
    contas[dados.id] = conta
    registro.registrar("CRIAR_CONTA", ts, {
        "id": dados.id,
        "nomeAluno": dados.nomeAluno,
        "saldoInicial": dados.saldoInicial,
    })
    return conta


@router.get("/{id_conta}", dependencies=[Depends(obter_usuario_atual)])
def consultar_saldo(request: Request, id_conta: int):
    relogio = request.app.state.relogio
    contas = request.app.state.contas
    conta = contas.get(id_conta)
    if conta is None:
        raise HTTPException(status_code=404, detail="Conta nao encontrada nesta agencia.")
    # Sprint 3: devolve tambem o vetor atual da agencia. O app guarda esse vetor
    # junto com o saldo e o reenvia ao sincronizar uma operacao feita offline.
    # Campo a mais na resposta: o frontend web (Sprint 1) simplesmente o ignora.
    return {**conta_como_dict(conta), "vetorAtual": relogio.obter_vetor_atual()}


@router.post("/{id_conta}/depositar", dependencies=[Depends(obter_usuario_atual)])
def depositar(request: Request, id_conta: int, dados: ValorRequest):
    relogio = request.app.state.relogio
    registro = request.app.state.registro
    contas = request.app.state.contas

    conta = contas.get(id_conta)
    if conta is None:
        raise HTTPException(status_code=404, detail="Conta nao encontrada nesta agencia.")

    ts = relogio.evento_local()
    conta.saldo += dados.valor
    registro.registrar("DEPOSITO", ts, {"id": id_conta, "valor": dados.valor, "novoSaldo": conta.saldo})
    return conta


@router.post("/{id_conta}/sacar", dependencies=[Depends(obter_usuario_atual)])
def sacar(request: Request, id_conta: int, dados: ValorRequest):
    relogio = request.app.state.relogio
    registro = request.app.state.registro
    contas = request.app.state.contas

    conta = contas.get(id_conta)
    if conta is None:
        raise HTTPException(status_code=404, detail="Conta nao encontrada nesta agencia.")
    if conta.saldo < dados.valor:
        raise HTTPException(status_code=400, detail="Saldo insuficiente.")

    ts = relogio.evento_local()
    conta.saldo -= dados.valor
    registro.registrar("SAQUE", ts, {"id": id_conta, "valor": dados.valor, "novoSaldo": conta.saldo})
    return conta


@router.post("/{id_conta}/sincronizar", dependencies=[Depends(obter_usuario_atual)])
def sincronizar_operacao_pendente(request: Request, id_conta: int, dados: SincronizarRequest):
    """Sprint 3, Parte E: aplica uma operacao feita offline pelo app, se for seguro.

    O app manda junto o vetorConhecido (o vetorAtual da ultima leitura da conta).
      - Igual ao vetor atual da agencia: nada mudou desde entao -> aplica (200).
      - Diferente: algo aconteceu na agencia enquanto o app estava offline ->
        NAO aplica as cegas e devolve 409 com o estado atual, para o app decidir.
    """
    relogio = request.app.state.relogio
    registro = request.app.state.registro
    contas = request.app.state.contas

    conta = contas.get(id_conta)
    if conta is None:
        raise HTTPException(status_code=404, detail="Conta nao encontrada nesta agencia.")

    tipo = dados.tipo.strip().upper()
    if tipo not in TIPOS_SINCRONIZAVEIS:
        raise HTTPException(status_code=400, detail="Tipo de operacao pendente nao suportado.")
    if dados.valor <= 0:
        raise HTTPException(status_code=400, detail="Valor deve ser maior que zero.")
    if len(dados.vetorConhecido) != config.NUMERO_AGENCIAS:
        raise HTTPException(
            status_code=400,
            detail=f"vetorConhecido deve ter {config.NUMERO_AGENCIAS} posicoes (uma por agencia).",
        )

    def aplicar():
        # Roda dentro da lock do relogio, so se os vetores forem iguais.
        if tipo == "SAQUE":
            if conta.saldo < dados.valor:
                raise HTTPException(status_code=400, detail="Saldo insuficiente.")
            conta.saldo -= dados.valor
        else:
            conta.saldo += dados.valor

    relacao, vetor = relogio.executar_se_atual(dados.vetorConhecido, aplicar)

    if relacao != "IGUAIS":
        # Resposta montada direto (e nao via HTTPException): o tratador de erros
        # do app.py embrulharia tudo em {"erro": {...}}, e o app precisa de
        # vetorAtual e contaAtual no nivel de cima do JSON.
        return JSONResponse(status_code=409, content={
            "erro": "Conflito detectado: o estado da conta mudou desde a ultima sincronizacao do app.",
            "relacao": relacao,
            "vetorConhecido": dados.vetorConhecido,
            "vetorAtual": vetor,
            "contaAtual": conta_como_dict(conta),
        })

    registro.registrar("SINCRONIZACAO_OFFLINE", vetor, {
        "id": id_conta,
        "tipo": tipo,
        "valor": dados.valor,
        "novoSaldo": conta.saldo,
        "vetorConhecido": dados.vetorConhecido,
    })
    # Devolve tambem o vetor novo: se o app tiver outra operacao pendente na fila,
    # ela foi registrada com o vetor ANTIGO e daria conflito com a mudanca que o
    # proprio app acabou de fazer. Com este vetor, o app atualiza a proxima.
    return {**conta_como_dict(conta), "vetorAtual": vetor}


@router.get("/{id_conta}/historico", dependencies=[Depends(obter_usuario_atual)])
def historico_conta(request: Request, id_conta: int):
    """Funcionalidade adicional: lista os eventos registrados da conta,
    ordenados pelo relogio vetorial."""
    registro = request.app.state.registro
    contas = request.app.state.contas

    if id_conta not in contas:
        raise HTTPException(status_code=404, detail="Conta nao encontrada nesta agencia.")
    return {"conta": id_conta, "eventos": registro.ler_eventos_por_conta(id_conta)}
