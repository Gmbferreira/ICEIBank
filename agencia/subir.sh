#!/usr/bin/env bash
# Sobe as agencias do ICEIBank no Linux, cada uma na sua propria janela de terminal
# (equivalente ao subir.ps1).
#
# Como usar (de qualquer pasta):
#     ./agencia/subir.sh            # sobe as 3 agencias
#     ./agencia/subir.sh 2          # sobe (ou ressobe) so a agencia 2
#     ./agencia/subir.sh 0 1        # sobe as agencias 0 e 1
#
# RABBITMQ_URL: usa a variavel do terminal se ja estiver definida; senao le de
# agencia/.env; senao pergunta e grava em agencia/.env (nao versionado).
#
# Sem ambiente grafico (ou com SEM_JANELA=1), as agencias sobem em segundo plano
# e o log de cada uma vai para agencia/data/agencia-<id>.log.
# Para derrubar uma agencia: feche a janela dela (ou ./agencia/parar.sh <id>).

set -euo pipefail

PASTA_AGENCIA="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON="$PASTA_AGENCIA/.venv/bin/python"
ARQUIVO_ENV="$PASTA_AGENCIA/.env"
PORTA_BASE="${PORTA_BASE:-4021}"   # 4000 + OFFSET 21 (config.py)

AGENCIAS=("$@")
[[ ${#AGENCIAS[@]} -eq 0 ]] && AGENCIAS=(0 1 2)

if [[ ! -x "$PYTHON" ]]; then
    echo -e "\e[31mAmbiente virtual nao encontrado em $PASTA_AGENCIA/.venv\e[0m"
    echo "Crie e instale as dependencias uma vez:"
    echo "    cd agencia && python3 -m venv .venv && .venv/bin/pip install -r requirements.txt"
    exit 1
fi

ler_url_do_env() {
    [[ -f "$ARQUIVO_ENV" ]] || return 0
    sed -n 's/^[[:space:]]*RABBITMQ_URL[[:space:]]*=[[:space:]]*//p' "$ARQUIVO_ENV" \
        | head -1 | sed -e "s/^[\"']//" -e "s/[\"']\$//"
}

URL="${RABBITMQ_URL:-}"
ORIGEM="variavel do terminal"
if [[ -z "$URL" ]]; then
    URL="$(ler_url_do_env)"
    ORIGEM="agencia/.env"
fi
if [[ -z "$URL" ]]; then
    echo -e "\e[33mRABBITMQ_URL nao encontrada (nem no terminal, nem em agencia/.env).\e[0m"
    read -rp "Cole a URL AMQP do CloudAMQP (amqps://usuario:senha@host/vhost): " URL
    URL="$(echo "$URL" | xargs)"
    if [[ -z "$URL" ]]; then
        echo -e "\e[31mSem a URL do RabbitMQ as agencias nao sobem. Abortando.\e[0m"
        exit 1
    fi
    umask 077
    printf '%s\n' "# URL do RabbitMQ (CloudAMQP) usada pelo subir.sh. Contem a senha:" \
        "# NAO versionar (o .gitignore ja ignora arquivos .env)." \
        "RABBITMQ_URL=$URL" > "$ARQUIVO_ENV"
    ORIGEM="digitada agora (salva em agencia/.env)"
fi

porta_em_uso() { ss -ltnH "sport = :$1" 2>/dev/null | grep -q .; }

abrir_terminal() {
    # $1 = titulo, resto = comando
    local titulo="$1"; shift
    if [[ -n "${SEM_JANELA:-}" || ( -z "${WAYLAND_DISPLAY:-}" && -z "${DISPLAY:-}" ) ]]; then
        return 1
    fi
    if command -v xdg-terminal-exec >/dev/null; then
        setsid -f xdg-terminal-exec --title="$titulo" -- "$@" >/dev/null 2>&1 && return 0
    fi
    for t in ghostty alacritty kitty foot konsole gnome-terminal xterm; do
        command -v "$t" >/dev/null || continue
        case "$t" in
            gnome-terminal) setsid -f gnome-terminal --title="$titulo" -- "$@" ;;
            konsole)        setsid -f konsole -p tabtitle="$titulo" -e "$@" ;;
            *)              setsid -f "$t" --title="$titulo" -e "$@" ;;
        esac >/dev/null 2>&1 && return 0
    done
    return 1
}

echo
echo -e "\e[36m=== Subindo agencias: ${AGENCIAS[*]} ===\e[0m"
echo "    $(date '+%d/%m/%Y %H:%M:%S')"
echo "    RABBITMQ_URL: $ORIGEM"

export RABBITMQ_URL="$URL"
mkdir -p "$PASTA_AGENCIA/data"

# Intervalo entre as subidas: no Windows cada janela do PowerShell leva alguns
# segundos para abrir, o que espalhava as eleicoes iniciais. Subindo as tres no
# mesmo instante, um anuncio de COORDENADOR atrasado de uma agencia menor pode
# chegar depois que a maior ja se elegeu (ver receber_coordenador no Bully).
INTERVALO_SUBIDA="${INTERVALO_SUBIDA:-2}"
primeira=1
for id in $(printf '%s\n' "${AGENCIAS[@]}" | sort -un); do
    [[ $primeira -eq 0 ]] && sleep "$INTERVALO_SUBIDA"
    primeira=0
    if [[ ! "$id" =~ ^[0-2]$ ]]; then
        echo -e "\e[31m  Agencia invalida: $id (use 0, 1 ou 2)\e[0m"; continue
    fi
    porta=$((PORTA_BASE + id))
    if porta_em_uso "$porta"; then
        echo -e "\e[33m  Agencia $id : porta $porta ja esta em uso (agencia ja rodando?) - pulei.\e[0m"
        continue
    fi
    titulo="Agencia $id - porta $porta"
    # Sem --reload (ver README: duplicaria o consumidor). Se a agencia cair, a
    # janela fica aberta mostrando o erro ate apertar Enter.
    cmd="cd '$PASTA_AGENCIA' && AGENCIA_ID=$id '$PYTHON' -m uvicorn src.app:app --port $porta; echo; read -rp 'Agencia $id encerrada. Enter para fechar a janela.'"
    if abrir_terminal "$titulo" bash -c "$cmd"; then
        echo -e "\e[32m  Agencia $id : janela aberta (porta $porta)\e[0m"
    else
        log="$PASTA_AGENCIA/data/agencia-$id.log"
        (cd "$PASTA_AGENCIA" && AGENCIA_ID=$id setsid nohup "$PYTHON" -m uvicorn src.app:app --port "$porta" >"$log" 2>&1 &)
        echo -e "\e[32m  Agencia $id : em segundo plano (porta $porta), log em agencia/data/agencia-$id.log\e[0m"
    fi
done

echo
echo -e "\e[33m  Para conferir a lider depois de alguns segundos:\e[0m"
echo -e "\e[33m      ./agencia/testar.sh lider\e[0m"
echo -e "\e[33m  Para derrubar uma agencia: feche a janela dela ou ./agencia/parar.sh <id>\e[0m"
