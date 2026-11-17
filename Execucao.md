# Execução - ICEIBank

Todos os comandos são para o PowerShell. `ICEIBank` é a raiz do repositório
(`C:\Projetos\DesWeb\ICEIBank`).

## Preparação (uma vez só)

- Pasta `ICEIBank\agencia`, rode `python -m venv .venv`
- Pasta `ICEIBank\agencia`, rode `.\.venv\Scripts\pip.exe install -r requirements.txt`
- Pasta `ICEIBank\frontend`, rode `npm install`
- Pasta `ICEIBank\app_mobile`, rode `flutter pub get`

A URL do RabbitMQ (CloudAMQP) fica em `agencia\.env`, fora do Git. Se o arquivo não
existir, o `subir.ps1` pergunta a URL na primeira vez e grava o arquivo.

## Sempre antes de qualquer sprint

- Pasta `ICEIBank`, rode `.\agencia\subir.ps1` (abre uma janela por agência, portas 4021, 4022 e 4023)

As contas ficam em memória: a cada vez que as agências sobem, é preciso criar as
contas de novo (passo "contas" abaixo).

## Sprint 1 e 2 - Frontend web, JWT, RabbitMQ e relógio vetorial

Linha do tempo causal (rodar logo depois de subir as agências, antes de criar as contas):
- Pasta `ICEIBank`, rode `.\agencia\testar.ps1 -Etapa timeline`
- Pasta `ICEIBank\agencia`, rode `.\.venv\Scripts\python.exe mesclar_logs.py`

Para uma linha do tempo limpa, antes de subir as agências mova os arquivos
`agencia\data\*.jsonl` para outra pasta: o vetor zera a cada reinício e o script
avisa quando os logs misturam execuções.

Transferência assíncrona entre agências:
- Pasta `ICEIBank`, rode `.\agencia\testar.ps1 -Etapa preparar`
- Pasta `ICEIBank`, rode `.\agencia\testar.ps1 -Etapa transferencia`

Resiliência e dead-letter queue:
- Pasta `ICEIBank`, rode `$env:RABBITMQ_URL = (Get-Content agencia\.env | Where-Object { $_ -like 'RABBITMQ_URL=*' }) -replace '^RABBITMQ_URL=',''`
- Feche a janela da agência 1
- Pasta `ICEIBank`, rode `.\agencia\testar.ps1 -Etapa resiliencia`
- Pasta `ICEIBank`, rode `.\agencia\subir.ps1 -Agencias 1`
- Pasta `ICEIBank`, rode `.\agencia\testar.ps1 -Etapa pos`

Frontend web (login admin / icei123):
- Pasta `ICEIBank\frontend`, rode `npm run dev` e abra o endereço que o Vite mostrar (normalmente http://localhost:5173)

## Sprint 3 - Bully, app Flutter e offline-first

Contas de teste (0, 1, 2 e 3, saldo 100):
- Pasta `ICEIBank`, rode `.\agencia\testar.ps1 -Etapa contas`

Eleição inicial (Parte A):
- Pasta `ICEIBank`, rode `.\agencia\testar.ps1 -Etapa lider`

Conflito de sincronização no backend (Parte E):
- Pasta `ICEIBank`, rode `.\agencia\testar.ps1 -Etapa sincronizar`

App Flutter (Partes D e F) - feche o Android Studio antes, para sobrar memória:
- Pasta `ICEIBank\app_mobile`, rode `flutter emulators --launch Small_Phone`
- Pasta `ICEIBank\app_mobile`, rode `flutter devices` (o emulador deve aparecer como `emulator-5554`)
- Pasta `ICEIBank\app_mobile`, rode `flutter run -d emulator-5554 --release`

- No app: login admin / icei123, consulte a conta 3. Para o modo offline, ligue o modo
avião do emulador, faça um depósito (fica pendente) e desligue o modo avião (sincroniza sozinho).

Failover (Parte B):
- Feche a janela da agência 2 e observe o painel do app mudar para a agência 1
- Pasta `ICEIBank`, rode `.\agencia\testar.ps1 -Etapa lider`
- Pasta `ICEIBank`, rode `.\agencia\subir.ps1 -Agencias 2` (a agência 2 volta e retoma a liderança)

Histórico de lideranças (Parte C), com HH:MM = horário em que as agências subiram:
- Pasta `ICEIBank\agencia`, rode `.\.venv\Scripts\python.exe historico_lideranca.py --desde HH:MM`

Testes automáticos do app:
- Pasta `ICEIBank\app_mobile`, rode `flutter test`

## Problemas conhecidos

- `emulator-5554 is offline`: pasta qualquer, rode
  `& "$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe" kill-server` e depois
  `& "$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe" devices`
- Tela preta no app: no Device Manager do Android Studio, edite o emulador e mude
  Graphics para Hardware.
- App lento ou "isn't responding": rode com `--release` (o modo debug é bem mais lento).
- "Conta não encontrada" no app: as agências reiniciaram; rode a etapa `contas` de novo.
