#!/usr/bin/env bash
# Roteiro de testes do ICEIBank no Linux (equivalente ao testar.ps1).
#
#     ./agencia/testar.sh preparar
#     ./agencia/testar.sh transferencia
#     ./agencia/testar.sh resiliencia      (com a agencia 1 fora do ar)
#     ./agencia/testar.sh pos
#     ./agencia/testar.sh timeline         (logo depois de subir, antes de "contas")
#     ./agencia/testar.sh lider
#     ./agencia/testar.sh sincronizar
#     ./agencia/testar.sh contas
#     ./agencia/testar.sh todas            (preparar + transferencia)
#
# Variaveis opcionais: PORTA_BASE (4021), USUARIO (admin), SENHA (icei123), VALOR.
# A RABBITMQ_URL (usada so para listar as filas) vem do terminal ou de agencia/.env.

set -uo pipefail

PASTA_AGENCIA="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORTA_BASE="${PORTA_BASE:-4021}"
USUARIO="${USUARIO:-admin}"
SENHA="${SENHA:-icei123}"
VALOR="${VALOR:-0}"
ETAPA="${1:-todas}"
TOKEN=""

command -v jq >/dev/null || { echo "Precisa do jq (sudo pacman -S jq)."; exit 1; }

if [[ -z "${RABBITMQ_URL:-}" && -f "$PASTA_AGENCIA/.env" ]]; then
    RABBITMQ_URL="$(sed -n 's/^[[:space:]]*RABBITMQ_URL[[:space:]]*=[[:space:]]*//p' "$PASTA_AGENCIA/.env" \
        | head -1 | sed -e "s/^[\"']//" -e "s/[\"']\$//")"
    export RABBITMQ_URL
fi

CIANO=$'\e[36m'; VERDE=$'\e[32m'; VERMELHO=$'\e[31m'; AMARELO=$'\e[33m'; FIM=$'\e[0m'
aviso() { echo "${AMARELO}  $*${FIM}"; }
valor_ou() { awk -v v="$VALOR" -v p="$1" 'BEGIN{print (v>0)?v:p}'; }

mostrar_data() {
    echo
    echo "${CIANO}=== $1 ===${FIM}"
    echo "    $(date '+%d/%m/%Y %H:%M:%S')"
}

# api <agencia> <metodo> <rota> [corpo-json] [silencioso]
# Imprime o corpo da resposta em $RESP e o status em $STATUS; retorna 0 se 2xx.
api() {
    local agencia="$1" metodo="$2" rota="$3" corpo="${4:-}" silencioso="${5:-}"
    local url="http://127.0.0.1:$((PORTA_BASE + agencia))$rota"
    local args=(-s -o /tmp/.iceibank_resp.$$ -w '%{http_code}' -X "$metodo" -H 'Content-Type: application/json')
    [[ -n "$TOKEN" ]] && args+=(-H "Authorization: Bearer $TOKEN")
    [[ -n "$corpo" ]] && args+=(--data "$corpo")
    echo "  -> $metodo $url"
    [[ -n "$corpo" ]] && echo "     corpo: $corpo"
    STATUS=$(curl "${args[@]}" "$url" 2>/dev/null) || STATUS="erro"
    RESP=$(cat /tmp/.iceibank_resp.$$ 2>/dev/null); rm -f /tmp/.iceibank_resp.$$
    if [[ "$STATUS" =~ ^2 ]]; then
        [[ -z "$silencioso" ]] && echo "${VERDE}     resposta: $(echo "$RESP" | jq -c . 2>/dev/null || echo "$RESP")${FIM}"
        return 0
    fi
    [[ "$STATUS" == "000" ]] && STATUS="erro (agencia fora do ar?)"
    echo "${VERMELHO}     resposta: HTTP $STATUS - $RESP${FIM}"
    return 1
}

conectar() {
    mostrar_data "Login (agencia 0, porta $PORTA_BASE) - usuario '$USUARIO'"
    if ! api 0 POST /auth/login "$(jq -nc --arg u "$USUARIO" --arg s "$SENHA" '{usuario:$u,senha:$s}')" silencioso; then
        echo
        echo "${VERMELHO}Nao foi possivel fazer login. As agencias estao no ar? (./agencia/subir.sh)${FIM}"
        exit 1
    fi
    TOKEN=$(echo "$RESP" | jq -r .access_token)
    echo "${VERDE}     token obtido: ${TOKEN:0:12}... ($(echo "$RESP" | jq -r .expiracao_min) min de validade)${FIM}"
}

mostrar_filas() {
    mostrar_data "Filas no RabbitMQ (mensagens retidas / consumidores)"
    if [[ -z "${RABBITMQ_URL:-}" ]]; then
        aviso "RABBITMQ_URL nao definida (nem em agencia/.env) - pulei a consulta das filas."
        return
    fi
    "$PASTA_AGENCIA/.venv/bin/python" "$PASTA_AGENCIA/filas.py" --alerta "$@"
}

criar_conta() { api "$1" POST /contas "$(jq -nc --argjson id "$2" --arg n "$3" --argjson s "$4" '{id:$id,nomeAluno:$n,saldoInicial:$s}')" "${5:-}"; }
transferir()  { api "$1" POST /transferencias "$(jq -nc --argjson o "$2" --argjson d "$3" --argjson v "$4" '{idOrigem:$o,idDestino:$d,valor:$v}')"; }

# ---------------------------------------------------------------- etapas

etapa_preparar() {
    conectar
    mostrar_data "Criando a conta 0 na agencia 0 (id 0 % 3 = 0, saldo 100)"
    criar_conta 0 0 Ana 100
    mostrar_data "Criando a conta 1 na agencia 1 (id 1 % 3 = 1, saldo 0)"
    criar_conta 1 1 Bia 0
    echo
    aviso "Contas criadas. HTTP 409 aqui significa 'ja existia' - sem problema, se ja era o caso."
}

etapa_transferencia() {
    conectar
    local v; v=$(valor_ou 30)
    mostrar_data "Transferencia entre agencias: conta 0 (agencia 0) -> conta 1 (agencia 1), valor $v"
    aviso "HTTP 200 aqui significa 'mensagem publicada'. O credito na agencia 1 e assincrono:"
    aviso "veja no terminal da agencia 1 a linha [Vetor [...]] TRANSFERENCIA_CREDITO_REMOTO."
    transferir 0 0 1 "$v"
    sleep 2
    mostrar_data "Saldos depois da entrega (agencia 0 = 100-v, agencia 1 = v)"
    api 0 GET /contas/0
    api 1 GET /contas/1
    mostrar_filas
}

etapa_resiliencia() {
    conectar
    local v; v=$(valor_ou 20)
    echo
    aviso "ATENCAO: a agencia 1 precisa estar FORA DO AR agora (./agencia/parar.sh 1)."
    aviso "Se ela estiver no ar, este teste demonstra so o caminho feliz."
    mostrar_data "Transferencia com a agencia 1 fora do ar: conta 0 -> conta 1, valor $v"
    aviso "Repare que a resposta ainda e HTTP 200: a mensagem foi publicada e retida na fila."
    transferir 0 0 1 "$v"
    sleep 1
    mostrar_data "A mensagem ficou retida em fila-agencia-1 (a agencia esta fora do ar)"
    mostrar_filas
    echo
    aviso "Proximo passo: suba a agencia 1 de novo (./agencia/subir.sh 1) e rode 'pos'. O credito nao"
    aviso "sera aplicado (a conta 1 sumiu no restart) e deve parar em fila-agencia-1.falhas."
}

etapa_pos() {
    conectar
    mostrar_data "Apos subir a agencia 1 de novo: a conta 1 ainda existe?"
    aviso "Esperado: HTTP 404 - as contas vivem em memoria e sumiram no restart."
    api 1 GET /contas/1
    sleep 2
    mostrar_data "O credito recusado foi preservado na dead-letter queue?"
    aviso "No terminal da agencia 1: [Vetor [...]] CREDITO_REMOTO_FALHOU (conta nao encontrada)"
    aviso "E a fila principal esvaziou: o credito nao sumiu, foi guardado em"
    aviso "fila-agencia-1.falhas (1 mensagem), em vez de ser descartado em silencio."
    api 1 GET /contas/0
    mostrar_filas --corpo
}

etapa_timeline() {
    conectar
    echo
    aviso "Cenario da linha do tempo causal: 3 agencias operam, duas transferencias"
    aviso "atravessam o broker e uma terceira chega na agencia 2 carregando o componente"
    aviso "da agencia 0 no vetor - que e a prova de que o vetorial guarda causalidade."
    mostrar_data "1/6 Criando a conta 0 na agencia 0 (vetor [1,0,0])"
    criar_conta 0 0 Ana 100
    mostrar_data "2/6 Criando a conta 1 na agencia 1 (vetor [0,1,0] - CONCORRENTE com o anterior)"
    criar_conta 1 1 Bia 0
    mostrar_data "3/6 Criando a conta 2 na agencia 2 (vetor [0,0,1] - CONCORRENTE com as duas)"
    criar_conta 2 2 Carla 60
    mostrar_data "4/6 Deposito local na agencia 1 (de onde sai o dinheiro da proxima transferencia)"
    api 1 POST /contas/1/depositar '{"valor":25}'
    mostrar_data "5/6 Transferencia 0 -> 1 (agencia 0 publica, agencia 1 recebe e funde o vetor)"
    transferir 0 0 1 30
    sleep 2
    mostrar_data "6/6 Transferencia 1 -> 2 (o credito na agencia 2 carrega [x,y,0] e vira [x,y,1])"
    transferir 1 1 2 10
    sleep 2
    echo
    aviso "Saldos finais (confere que os tres creditos assincronos chegaram):"
    api 0 GET /contas/0
    api 1 GET /contas/1
    api 2 GET /contas/2
    echo
    aviso "Agora gere a linha do tempo unificada:"
    aviso "    cd agencia && .venv/bin/python mesclar_logs.py"
}

etapa_lider() {
    # Nao precisa de login: as rotas /bully/* sao entre agencias, sem JWT.
    mostrar_data "Lider atual segundo cada agencia (GET /bully/lider)"
    local lideres=() no_ar=0
    printf '%-8s %-6s %-11s %s\n' Agencia Porta Status LiderAtual
    printf '%-8s %-6s %-11s %s\n' ------- ----- ------ ----------
    for a in 0 1 2; do
        local porta=$((PORTA_BASE + a)) r lider
        if r=$(curl -s --max-time 2 "http://127.0.0.1:$porta/bully/lider"); then
            lider=$(echo "$r" | jq -r '.liderAtual // "(nenhuma)"')
            printf '%-8s %-6s %-11s %s\n' "$a" "$porta" "no ar" "$lider"
            lideres+=("$lider"); no_ar=$((no_ar + 1))
        else
            printf '%-8s %-6s %-11s %s\n' "$a" "$porta" "fora do ar" "-"
        fi
    done
    echo
    local unicos; unicos=$(printf '%s\n' "${lideres[@]}" | sort -u)
    if [[ $no_ar -eq 0 ]]; then
        echo "${VERMELHO}  Nenhuma agencia respondeu. Elas estao no ar?${FIM}"
    elif [[ $(echo "$unicos" | wc -l) -eq 1 && "$unicos" != "(nenhuma)" ]]; then
        echo "${VERDE}  Consenso: as $no_ar agencias no ar concordam que a lider e a agencia $unicos.${FIM}"
    else
        aviso "Ainda sem consenso (eleicao em andamento?). Espere alguns segundos e rode de novo."
    fi
}

# sincronizar_op <agencia> <conta> <tipo> <valor> <vetor-json>  -> $STATUS, $RESP
sincronizar_op() {
    local corpo; corpo=$(jq -nc --arg t "$3" --argjson v "$4" --argjson vet "$5" '{tipo:$t,valor:$v,vetorConhecido:$vet}')
    local url="http://127.0.0.1:$((PORTA_BASE + $1))/contas/$2/sincronizar"
    echo "  -> POST $url"
    echo "     corpo: $corpo"
    STATUS=$(curl -s -o /tmp/.iceibank_resp.$$ -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
        -H "Authorization: Bearer $TOKEN" --data "$corpo" "$url")
    RESP=$(cat /tmp/.iceibank_resp.$$); rm -f /tmp/.iceibank_resp.$$
    local cor="$VERMELHO"; [[ "$STATUS" == 200 ]] && cor="$VERDE"; [[ "$STATUS" == 409 ]] && cor="$AMARELO"
    echo "${cor}     HTTP $STATUS - resposta:"
    echo "$RESP" | jq . 2>/dev/null || echo "$RESP"
    echo -n "$FIM"
}

etapa_sincronizar() {
    conectar
    local v; v=$(valor_ou 20)
    mostrar_data "1/5 Criando a conta 3 na agencia 0 (HTTP 409 'ja existe' aqui e normal)"
    criar_conta 0 3 Dani 100 silencioso
    mostrar_data "2/5 App le o saldo e guarda o vetorAtual (o 'vetorConhecido' da operacao offline)"
    api 0 GET /contas/3 || exit 1
    local vetor_antigo; vetor_antigo=$(echo "$RESP" | jq -c .vetorAtual)
    echo "${CIANO}     vetor guardado pelo app: $vetor_antigo${FIM}"
    mostrar_data "3/5 Enquanto o app esta 'offline', um deposito de 50 acontece por outro caminho"
    api 0 POST /contas/3/depositar '{"valor":50}'
    mostrar_data "4/5 App reconecta e sincroniza um SAQUE de $v com o vetor ANTIGO - esperado HTTP 409"
    sincronizar_op 0 3 SAQUE "$v" "$vetor_antigo"
    if [[ "$STATUS" != 409 ]]; then
        echo "${VERMELHO}  Esperava HTTP 409 com o corpo do conflito. Interrompendo.${FIM}"; exit 1
    fi
    local vetor_novo; vetor_novo=$(echo "$RESP" | jq -c '.vetorAtual // .detail.vetorAtual')
    aviso "Conflito detectado: vetor conhecido $vetor_antigo x atual $vetor_novo."
    aviso "A operacao NAO foi aplicada; a agencia devolveu o estado real da conta."
    mostrar_data "5/5 Sincronizando de novo com o vetorAtual devolvido no 409 - esperado HTTP 200"
    sincronizar_op 0 3 SAQUE "$v" "$vetor_novo"
    [[ "$STATUS" == 200 ]] && echo "${VERDE}  Sincronizacao aplicada. No terminal da agencia 0: SINCRONIZACAO_OFFLINE.${FIM}"
}

etapa_contas() {
    conectar
    local nomes=(Ana Bia Carla Dani)
    for id in 0 1 2 3; do
        mostrar_data "Criando a conta $id (${nomes[$id]}) na agencia $((id % 3)), saldo 100"
        criar_conta $((id % 3)) "$id" "${nomes[$id]}" 100
    done
    mostrar_data "Saldos atuais das contas de teste"
    for id in 0 1 2 3; do api $((id % 3)) GET "/contas/$id"; done
    echo
    aviso "Contas prontas. HTTP 409 na criacao significa 'ja existia' - sem problema."
}

case "$ETAPA" in
    preparar)      etapa_preparar ;;
    transferencia) etapa_transferencia ;;
    resiliencia)   etapa_resiliencia ;;
    pos)           etapa_pos ;;
    timeline)      etapa_timeline ;;
    lider)         etapa_lider ;;
    sincronizar)   etapa_sincronizar ;;
    contas)        etapa_contas ;;
    todas)         etapa_preparar; etapa_transferencia ;;
    *) echo "Etapa invalida: $ETAPA (preparar|transferencia|resiliencia|pos|timeline|lider|sincronizar|contas|todas)"; exit 1 ;;
esac
