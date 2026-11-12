<#
    Sobe as agencias do ICEIBank, cada uma na sua propria janela do PowerShell.

    Janelas separadas de proposito: cada uma mostra o log da sua agencia (o que vai
    para os prints de evidencia), e derrubar uma agencia - como no failover da
    Parte B do Sprint 3 - e so fechar a janela dela.

    Como usar (de qualquer pasta):
        .\agencia\subir.ps1                  # sobe as 3 agencias
        .\agencia\subir.ps1 -Agencias 2      # sobe (ou ressobe) so a agencia 2
        .\agencia\subir.ps1 -Agencias 0,1    # sobe as agencias 0 e 1

    RABBITMQ_URL: usa a variavel do terminal se ja estiver definida; senao le de
    agencia\.env; senao pergunta e grava em agencia\.env para as proximas vezes.
    O .env NAO e versionado (.gitignore), porque a URL carrega a senha.
#>

param(
    [ValidateRange(0, 2)]
    [int[]]$Agencias = @(0, 1, 2),
    # 4021 = 4000 + OFFSET 21 (config.py), igual ao testar.ps1.
    [int]$PortaBase = 4021
)

$pastaAgencia = $PSScriptRoot
$python = Join-Path $pastaAgencia ".venv\Scripts\python.exe"
$arquivoEnv = Join-Path $pastaAgencia ".env"

# ---------------------------------------------------------------- pre-requisitos

if (-not (Test-Path $python)) {
    Write-Host "Ambiente virtual nao encontrado em $pastaAgencia\.venv" -ForegroundColor Red
    Write-Host "Crie e instale as dependencias uma vez:" -ForegroundColor Yellow
    Write-Host "    cd agencia"
    Write-Host "    python -m venv .venv"
    Write-Host "    .\.venv\Scripts\Activate.ps1"
    Write-Host "    pip install -r requirements.txt"
    exit 1
}

function Ler-UrlDoEnv {
    if (-not (Test-Path $arquivoEnv)) { return $null }
    foreach ($linha in Get-Content $arquivoEnv) {
        $linha = $linha.Trim()
        if ($linha -eq "" -or $linha.StartsWith("#")) { continue }
        $partes = $linha.Split("=", 2)
        if ($partes.Count -eq 2 -and $partes[0].Trim() -eq "RABBITMQ_URL") {
            return $partes[1].Trim().Trim('"').Trim("'")
        }
    }
    return $null
}

$url = $env:RABBITMQ_URL
$origemUrl = "variavel do terminal"
if (-not $url) {
    $url = Ler-UrlDoEnv
    $origemUrl = "agencia\.env"
}
if (-not $url) {
    Write-Host "RABBITMQ_URL nao encontrada (nem no terminal, nem em agencia\.env)." -ForegroundColor Yellow
    $url = (Read-Host "Cole a URL AMQP do CloudAMQP (amqps://usuario:senha@host/vhost)").Trim()
    if (-not $url) {
        Write-Host "Sem a URL do RabbitMQ as agencias nao sobem. Abortando." -ForegroundColor Red
        exit 1
    }
    $conteudo = @(
        "# URL do RabbitMQ (CloudAMQP) usada pelo subir.ps1. Contem a senha:",
        "# NAO versionar (o .gitignore ja ignora arquivos .env).",
        "RABBITMQ_URL=$url"
    )
    Set-Content -Path $arquivoEnv -Value $conteudo -Encoding ASCII
    $origemUrl = "digitada agora (salva em agencia\.env)"
}

function Porta-EmUso([int]$porta) {
    $conexao = Get-NetTCPConnection -LocalPort $porta -State Listen -ErrorAction SilentlyContinue
    return $null -ne $conexao
}

# ---------------------------------------------------------------- subida

Write-Host ""
Write-Host "=== Subindo agencias: $($Agencias -join ', ') ===" -ForegroundColor Cyan
Write-Host ("    " + (Get-Date -Format "dd/MM/yyyy HH:mm:ss"))
Write-Host "    RABBITMQ_URL: $origemUrl"

# As janelas novas herdam as variaveis de ambiente deste processo: assim a URL
# (que tem caracteres especiais) nao precisa passar por linha de comando. Os
# valores originais sao restaurados no fim, para nao "sujar" este terminal.
$agenciaIdOriginal = $env:AGENCIA_ID
$urlOriginal = $env:RABBITMQ_URL
$env:RABBITMQ_URL = $url

try {
    foreach ($id in ($Agencias | Sort-Object -Unique)) {
        $porta = $PortaBase + $id
        if (Porta-EmUso $porta) {
            Write-Host "  Agencia $id : porta $porta ja esta em uso (agencia ja rodando?) - pulei." -ForegroundColor Yellow
            continue
        }

        $env:AGENCIA_ID = "$id"
        $titulo = "Agencia $id - porta $porta"
        # -NoExit: se a agencia falhar no startup, a janela continua aberta
        # mostrando o erro. Sem --reload (ver README: duplicaria o consumidor).
        $comando = "`$Host.UI.RawUI.WindowTitle = '$titulo'; & '$python' -m uvicorn src.app:app --port $porta"
        Start-Process powershell -WorkingDirectory $pastaAgencia -ArgumentList @("-NoExit", "-Command", $comando) | Out-Null
        Write-Host "  Agencia $id : janela aberta (porta $porta)" -ForegroundColor Green
    }
}
finally {
    $env:AGENCIA_ID = $agenciaIdOriginal
    $env:RABBITMQ_URL = $urlOriginal
}

Write-Host ""
Write-Host "  Para conferir a lider depois de alguns segundos:" -ForegroundColor Yellow
Write-Host "      .\agencia\testar.ps1 -Etapa lider" -ForegroundColor Yellow
Write-Host "  Para derrubar uma agencia, feche a janela dela." -ForegroundColor Yellow
