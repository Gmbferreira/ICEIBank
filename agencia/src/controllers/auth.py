import jwt
from fastapi import APIRouter, Depends, HTTPException
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer

from src.models.contas import LoginRequest
from src.services import auth_service

router = APIRouter(prefix="/auth", tags=["auth"])

seguranca = HTTPBearer(auto_error=False)


@router.post("/login", tags=["auth"])
def login(dados: LoginRequest):
    if not auth_service.autenticar_usuario(dados.usuario, dados.senha):
        raise HTTPException(status_code=401, detail="Credenciais invalidas.")
    token = auth_service.gerar_token(dados.usuario)
    return {
        "access_token": token,
        "tipo": "bearer",
        "expiracao_min": auth_service.TOKEN_EXPIRACAO_MIN,
    }


def obter_usuario_atual(credenciais: HTTPAuthorizationCredentials = Depends(seguranca)):
    """Dependencia que protege as rotas de contas/transferencias: exige um
    token JWT valido (assinatura correta e nao expirado)."""
    if credenciais is None:
        raise HTTPException(status_code=401, detail="Token de autenticacao ausente.")
    try:
        return auth_service.validar_token(credenciais.credentials)
    except jwt.ExpiredSignatureError:
        raise HTTPException(status_code=401, detail="Token expirado.")
    except jwt.InvalidTokenError:
        raise HTTPException(status_code=401, detail="Token invalido.")


def obter_token_servico(credenciais: HTTPAuthorizationCredentials = Depends(seguranca)):
    """Dependencia exclusiva da chamada interna agencia-a-agencia.

    Decisao de design (ver RESPOSTAS.md): creditar-remoto exige um token com o
    claim 'servico: true', que so as proprias agencias conseguem gerar. O token
    de usuario do frontend (sem esse claim) nao e aceito nessa rota.
    """
    payload = obter_usuario_atual(credenciais)
    if not payload.get("servico"):
        raise HTTPException(status_code=401, detail="Token de servico exigido para chamada interna.")
    return payload