from fastapi import APIRouter, Depends, HTTPException, Request

import src.config as config
from src.controllers.auth import obter_usuario_atual
from src.models.contas import Conta, CriarContaRequest, ValorRequest

router = APIRouter(prefix="/contas", tags=["contas"])


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
    contas = request.app.state.contas
    conta = contas.get(id_conta)
    if conta is None:
        raise HTTPException(status_code=404, detail="Conta nao encontrada nesta agencia.")
    return conta


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


@router.get("/{id_conta}/historico", dependencies=[Depends(obter_usuario_atual)])
def historico_conta(request: Request, id_conta: int):
    """Funcionalidade adicional: lista os eventos registrados da conta,
    ordenados pelo relogio vetorial."""
    registro = request.app.state.registro
    contas = request.app.state.contas

    if id_conta not in contas:
        raise HTTPException(status_code=404, detail="Conta nao encontrada nesta agencia.")
    return {"conta": id_conta, "eventos": registro.ler_eventos_por_conta(id_conta)}