import datetime
import os

import jwt

# Chave secreta de assinatura do JWT (em producao, via variavel de ambiente).
SECRET_KEY = os.getenv("JWT_SECRET", "iceibank-chave-de-desenvolvimento")

# Tempo de expiracao do token de usuario (minutos).
TOKEN_EXPIRACAO_MIN = int(os.getenv("JWT_EXP_MIN", "30"))

# Credenciais de admin (configuraveis por variavel de ambiente).
ADMIN_USUARIO = os.getenv("ADMIN_USUARIO", "admin")
ADMIN_SENHA = os.getenv("ADMIN_SENHA", "icei123")


class CredenciaisInvalidas(Exception):
    pass


def autenticar_usuario(usuario, senha):
    return usuario == ADMIN_USUARIO and senha == ADMIN_SENHA


def _payload_base(usuario):
    agora = datetime.datetime.now(datetime.timezone.utc)
    return {
        "sub": usuario,
        "iat": agora,
        "exp": agora + datetime.timedelta(minutes=TOKEN_EXPIRACAO_MIN),
    }


def gerar_token(usuario, **claims_extra):
    payload = _payload_base(usuario)
    payload.update(claims_extra)
    return jwt.encode(payload, SECRET_KEY, algorithm="HS256")


def gerar_token_servico(id_agencia_origem, validade_min=2):
    """Token curto para a chamada interna agencia-a-agencia (creditar-remoto).

    Decisao de design (ver RESPOSTAS.md): chamadas internas NAO usam o token de
    usuario do frontend; usam um token de servico com claim 'servico: true',
    assinado com a mesma chave, com expiracao curta. O frontend nunca recebe
    esse claim.
    """
    payload = {
        "sub": f"agencia-{id_agencia_origem}",
        "iat": datetime.datetime.now(datetime.timezone.utc),
        "exp": datetime.datetime.now(datetime.timezone.utc)
        + datetime.timedelta(minutes=validade_min),
        "servico": True,
    }
    return jwt.encode(payload, SECRET_KEY, algorithm="HS256")


def gerar_token_expirado(usuario="teste"):
    """Usado apenas para evidenciar o cenario 'token expirado' nos testes."""
    payload = {
        "sub": usuario,
        "iat": datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(hours=1),
        "exp": datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(minutes=1),
    }
    return jwt.encode(payload, SECRET_KEY, algorithm="HS256")


def validar_token(token):
    return jwt.decode(token, SECRET_KEY, algorithms=["HS256"])