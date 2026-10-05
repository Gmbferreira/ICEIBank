<#
    Sprint 2 - roteiro de teste do ICEIBank (Publish/Subscribe via RabbitMQ).

    Este script existe para nao depender de colar comandos longos no PowerShell:
    no PowerShell 5.1 as aspas duplas de um JSON escrito a mao sao removidas ao
    passar para um executavel nativo (curl.exe), e blocos de funcao colados em
    varias linhas se desmontam no prompt de continuacao. Aqui tudo e construido
    com objetos do PowerShell e convertido em JSON internamente.

    Como usar (as 3 agencias precisam estar no ar, uma por terminal):
        .\agencia\testar.ps1 -Etapa preparar
        .\agencia\testar.ps1 -Etapa transferencia
        .\agencia\testar.ps1 -Etapa resiliencia
        .\agencia\testar.ps1 -Etapa pos

    Cada etapa imprime Get-Date antes da acao, para o print ter data/hora visivel.
#>

param(
    [ValidateSet("preparar", "transferencia", "resiliencia", "pos", "timeline", "todas")]
    [string]$Etapa = "todas",
    # 4021 = 4000 + OFFSET 21 (config.py). As tres agencias ficam em
    # PortaBase, PortaBase+1 e PortaBase+2.
    [int]$PortaBase = 4021,
    [string]$Usuario = "admin",
    [string]$Senha = "icei123",
    [double]$Valor = 0
)

$script:TOKEN = $null

function Mostrar-Data([string]$titulo) {
    Write-Host ""
    Write-Host "=== $titulo ===" -ForegroundColor Cyan
    Write-Host ("    " + (Get-Date -Format "dd/MM/yyyy HH:mm:ss"))
}

function Get-StatusCode($erro) {
    # Funciona no PowerShell 5.1 (StatusCode.value__) e no 7+ (int direto).
    $resposta = $erro.Exception.Response
    if ($null -eq $resposta) { return "erro" }
    if ($resposta.StatusCode -is [int]) { return $resposta.StatusCode }
    return $resposta.StatusCode.value__
}

function Invoke-Api {
    param(
        [int]$Agencia,
        [string]$Rota,
        [string]$Metodo = "GET",
        $Corpo = $null,
        [switch]$Silencioso
    )
    $url = "http://localhost:$($PortaBase + $Agencia)$Rota"
    $cabecalhos = @{}
    if ($script:TOKEN) { $cabecalhos["Authorization"] = "Bearer $($script:TOKEN)" }
    $params = @{
        Uri = $url
        Method = $Metodo
        Headers = $cabecalhos
        ContentType = "application/json"
    }
    if ($null -ne $Corpo) { $params["Body"] = ($Corpo | ConvertTo-Json -Compress) }

    Write-Host "  -> $Metodo $url"
    if ($null -ne $Corpo) { Write-Host "     corpo: $($params["Body"])" }
    try {
        $resposta = Invoke-RestMethod @params
        if (-not $Silencioso) {
            Write-Host "     resposta: $($resposta | ConvertTo-Json -Compress -Depth 5)" -ForegroundColor Green
        }
        return $resposta
    }
    catch {
        $status = Get-StatusCode $_
        $detalhe = $_.ErrorDetails.Message
        if (-not $detalhe) { $detalhe = $_.Exception.Message }
        Write-Host "     resposta: HTTP $status - $detalhe" -ForegroundColor Red
        return $null
    }
}

function Conectar {
    Mostrar-Data "Login (agencia 0, porta $PortaBase) - usuario '$Usuario'"
    $resposta = Invoke-Api -Agencia 0 -Rota "/auth/login" -Metodo "POST" -Corpo @{ usuario = $Usuario; senha = $Senha } -Silencioso
    if ($null -eq $resposta) {
        Write-Host ""
        Write-Host "Nao foi possivel fazer login. As agencias estao no ar? (terminal propio, com AGENCIA_ID e RABBITMQ_URL definidos)" -ForegroundColor Red
        exit 1
    }
    $script:TOKEN = $resposta.access_token
    $inicio = $script:TOKEN.Substring(0, 12)
    Write-Host "     token obtido: $inicio... ($($resposta.expiracao_min) min de validade)" -ForegroundColor Green
}

function Mostrar-Filas {
    param([switch]$Corpo)
    Mostrar-Data "Filas no RabbitMQ (mensagens retidas / consumidores)"
    $python = Join-Path $PSScriptRoot ".venv\Scripts\python.exe"
    if (-not (Test-Path $python)) { $python = Join-Path $PSScriptRoot ".venv/Scripts/python.exe" }
    if (-not (Test-Path $python)) {
        Write-Host "     .venv nao encontrado em $PSScriptRoot - pulei a consulta das filas." -ForegroundColor Yellow
        return
    }
    if (-not $env:RABBITMQ_URL) {
        Write-Host "     RABBITMQ_URL nao definida neste terminal - pulei a consulta das filas." -ForegroundColor Yellow
        return
    }
    $opcoes = @("--alerta")
    if ($Corpo) { $opcoes += "--corpo" }
    & $python (Join-Path $PSScriptRoot "filas.py") @opcoes
}

# ---------------------------------------------------------------- etapas

function EtapaPreparar {
    Conectar
    Mostrar-Data "Criando a conta 0 na agencia 0 (id 0 % 3 = 0, saldo 100)"
    Invoke-Api -Agencia 0 -Rota "/contas" -Metodo "POST" -Corpo @{ id = 0; nomeAluno = "Ana"; saldoInicial = 100 } | Out-Null

    Mostrar-Data "Criando a conta 1 na agencia 1 (id 1 % 3 = 1, saldo 0)"
    Invoke-Api -Agencia 1 -Rota "/contas" -Metodo "POST" -Corpo @{ id = 1; nomeAluno = "Bia"; saldoInicial = 0 } | Out-Null

    Write-Host ""
    Write-Host "Contas criadas. HTTP 409 aqui significa 'ja existia' - sem problema, se ja era o caso." -ForegroundColor Yellow
}

function EtapaTransferencia {
    Conectar
    $v = if ($Valor -gt 0) { $Valor } else { 30 }

    Mostrar-Data "Transferencia entre agencias: conta 0 (agencia 0) -> conta 1 (agencia 1), valor $v"
    Write-Host "  HTTP 200 aqui significa 'mensagem publicada'. O credito na agencia 1 e assincrono:" -ForegroundColor Yellow
    Write-Host "  veja no terminal da agencia 1 a linha [Vetor [...]] TRANSFERENCIA_CREDITO_REMOTO." -ForegroundColor Yellow
    Invoke-Api -Agencia 0 -Rota "/transferencias" -Metodo "POST" -Corpo @{ idOrigem = 0; idDestino = 1; valor = $v } | Out-Null

    Start-Sleep -Seconds 2
    Mostrar-Data "Saldos depois da entrega (agencia 0 = 100-v, agencia 1 = v)"
    Invoke-Api -Agencia 0 -Rota "/contas/0" | Out-Null
    Invoke-Api -Agencia 1 -Rota "/contas/1" | Out-Null
    Mostrar-Filas
}

function EtapaResiliencia {
    Conectar
    $v = if ($Valor -gt 0) { $Valor } else { 20 }

    Write-Host ""
    Write-Host "  ATENCAO: a agencia 1 precisa estar FORA DO AR agora (Ctrl+C no terminal dela)." -ForegroundColor Yellow
    Write-Host "  Se ela estiver no ar, este teste demonstra so o caminho feliz." -ForegroundColor Yellow

    Mostrar-Data "Transferencia com a agencia 1 fora do ar: conta 0 -> conta 1, valor $v"
    Write-Host "  Repare que a resposta ainda e HTTP 200: a mensagem foi publicada e retida na fila." -ForegroundColor Yellow
    Invoke-Api -Agencia 0 -Rota "/transferencias" -Metodo "POST" -Corpo @{ idOrigem = 0; idDestino = 1; valor = $v } | Out-Null

    Start-Sleep -Seconds 1
    Mostrar-Data "A mensagem ficou retida em fila-agencia-1 (a agencia esta fora do ar)"
    Mostrar-Filas
    Write-Host ""
    Write-Host "  Proximo passo: suba a agencia 1 de novo e rode -Etapa pos. O credito nao sera" -ForegroundColor Yellow
    Write-Host "  aplicado (a conta 1 sumiu no restart) e deve parar em fila-agencia-1.falhas." -ForegroundColor Yellow
}

function EtapaPos {
    Conectar
    Mostrar-Data "Apos subir a agencia 1 de novo: a conta 1 ainda existe?"
    Write-Host "  Esperado: HTTP 404 - as contas vivem em memoria e sumiram no restart." -ForegroundColor Yellow
    Invoke-Api -Agencia 1 -Rota "/contas/1" | Out-Null

    Start-Sleep -Seconds 2
    Mostrar-Data "O credito recusado foi preservado na dead-letter queue?"
    Write-Host "  No terminal da agencia 1: [Vetor [...]] CREDITO_REMOTO_FALHOU (conta nao encontrada)" -ForegroundColor Yellow
    Write-Host "  E a fila principal esvaziou: o credito nao sumiu, foi guardado em" -ForegroundColor Yellow
    Write-Host "  fila-agencia-1.falhas (1 mensagem), em vez de ser descartado em silencio." -ForegroundColor Yellow
    Invoke-Api -Agencia 1 -Rota "/contas/0" | Out-Null
    Mostrar-Filas -Corpo
}

function EtapaTimeline {
    Conectar

    Write-Host ""
    Write-Host "  Cenario da linha do tempo causal: 3 agencias operam, duas transferencias" -ForegroundColor Yellow
    Write-Host "  atravessam o broker e uma terceira chega na agencia 2 carregando o componente" -ForegroundColor Yellow
    Write-Host "  da agencia 0 no vetor - que e a prova de que o vetorial guarda causalidade." -ForegroundColor Yellow

    Mostrar-Data "1/6 Criando a conta 0 na agencia 0 (vetor [1,0,0])"
    Invoke-Api -Agencia 0 -Rota "/contas" -Metodo "POST" -Corpo @{ id = 0; nomeAluno = "Ana"; saldoInicial = 100 } | Out-Null

    Mostrar-Data "2/6 Criando a conta 1 na agencia 1 (vetor [0,1,0] - CONCORRENTE com o anterior)"
    Invoke-Api -Agencia 1 -Rota "/contas" -Metodo "POST" -Corpo @{ id = 1; nomeAluno = "Bia"; saldoInicial = 0 } | Out-Null

    Mostrar-Data "3/6 Criando a conta 2 na agencia 2 (vetor [0,0,1] - CONCORRENTE com as duas)"
    Invoke-Api -Agencia 2 -Rota "/contas" -Metodo "POST" -Corpo @{ id = 2; nomeAluno = "Carla"; saldoInicial = 60 } | Out-Null

    Mostrar-Data "4/6 Deposito local na agencia 1 (de onde sai o dinheiro da proxima transferencia)"
    Invoke-Api -Agencia 1 -Rota "/contas/1/depositar" -Metodo "POST" -Corpo @{ valor = 25 } | Out-Null

    Mostrar-Data "5/6 Transferencia 0 -> 1 (agencia 0 publica, agencia 1 recebe e funde o vetor)"
    Invoke-Api -Agencia 0 -Rota "/transferencias" -Metodo "POST" -Corpo @{ idOrigem = 0; idDestino = 1; valor = 30 } | Out-Null

    Start-Sleep -Seconds 2
    Mostrar-Data "6/6 Transferencia 1 -> 2 (o credito na agencia 2 carrega [x,y,0] e vira [x,y,1])"
    Invoke-Api -Agencia 1 -Rota "/transferencias" -Metodo "POST" -Corpo @{ idOrigem = 1; idDestino = 2; valor = 10 } | Out-Null

    Start-Sleep -Seconds 2
    Write-Host ""
    Write-Host "  Saldos finais (confere que os tres creditos assincronos chegaram):" -ForegroundColor Yellow
    Invoke-Api -Agencia 0 -Rota "/contas/0" | Out-Null
    Invoke-Api -Agencia 1 -Rota "/contas/1" | Out-Null
    Invoke-Api -Agencia 2 -Rota "/contas/2" | Out-Null

    Write-Host ""
    Write-Host "  Agora gere a linha do tempo unificada em outro terminal:" -ForegroundColor Yellow
    Write-Host "      cd agencia; python mesclar_logs.py" -ForegroundColor Yellow
}

# ---------------------------------------------------------------- execucao

switch ($Etapa) {
    "preparar" { EtapaPreparar }
    "transferencia" { EtapaTransferencia }
    "resiliencia" { EtapaResiliencia }
    "pos" { EtapaPos }
    "timeline" { EtapaTimeline }
    "todas" {
        EtapaPreparar
        EtapaTransferencia
    }
}