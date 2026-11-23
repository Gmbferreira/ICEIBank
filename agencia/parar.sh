#!/usr/bin/env bash
# Derruba agencias do ICEIBank pela porta (equivalente a fechar a janela no Windows).
#     ./agencia/parar.sh          # derruba as 3
#     ./agencia/parar.sh 1        # derruba so a agencia 1
set -uo pipefail
PORTA_BASE="${PORTA_BASE:-4021}"
AGENCIAS=("$@")
[[ ${#AGENCIAS[@]} -eq 0 ]] && AGENCIAS=(0 1 2)
for id in "${AGENCIAS[@]}"; do
    porta=$((PORTA_BASE + id))
    pids=$(pgrep -f "uvicorn src.app:app --port $porta" | tr '\n' ' ' | xargs || true)
    if [[ -z "$pids" ]]; then
        echo "Agencia $id (porta $porta): nao estava rodando."
    else
        kill $pids && echo "Agencia $id (porta $porta): encerrada (PID $pids)."
    fi
done
