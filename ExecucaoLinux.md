# Execução - ICEIBank (Linux)

Equivalente ao `Execucao.md` (Windows/PowerShell). Todos os comandos são para o bash,
a partir da raiz do repositório (`ICEIBank`).

## Pré-requisitos do sistema (uma vez só)

| Ferramenta | Como foi instalada (Arch) |
|---|---|
| Python 3 + venv, Node/npm, curl, jq | já vêm no sistema |
| JDK 21 | `sudo pacman -S --needed jdk21-openjdk` |
| Flutter (stable) | `git clone --depth 1 -b stable https://github.com/flutter/flutter.git ~/development/flutter` |
| Android SDK | command-line tools em `~/Android/Sdk/cmdline-tools/latest`, depois `sdkmanager --licenses` e `sdkmanager "platform-tools" "emulator" "platforms;android-36" "build-tools;36.1.0" "system-images;android-35;google_apis;x86_64"` |
| Emulador | `avdmanager create avd -n Small_Phone -k "system-images;android-35;google_apis;x86_64" -d small_phone` |

No `~/.bashrc`:

```bash
export ANDROID_HOME="$HOME/Android/Sdk"
export PATH="$HOME/development/flutter/bin:$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools:$ANDROID_HOME/emulator:$PATH"
```

## Preparação do projeto (uma vez só)

```bash
cd agencia && python3 -m venv .venv && .venv/bin/pip install -r requirements.txt && cd ..
cd frontend && npm install && cd ..
cd app_mobile && flutter pub get && cd ..
```

A URL do RabbitMQ (CloudAMQP) fica em `agencia/.env`, fora do Git. Se o arquivo não
existir, o `subir.sh` pergunta a URL na primeira vez e grava o arquivo.

## Sempre antes de qualquer sprint

```bash
./agencia/subir.sh
```

Abre uma janela de terminal por agência (portas 4021, 4022 e 4023). Para derrubar uma
agência: feche a janela dela ou rode `./agencia/parar.sh <id>`; para subir de novo,
`./agencia/subir.sh <id>`. `./agencia/parar.sh` sem argumento derruba as três.

As contas ficam em memória: a cada vez que as agências sobem, é preciso criar as
contas de novo (etapa `contas`).

## Sprint 1 e 2 - Frontend web, JWT, RabbitMQ e relógio vetorial

Linha do tempo causal (logo depois de subir as agências, antes de criar as contas):

```bash
./agencia/testar.sh timeline
cd agencia && .venv/bin/python mesclar_logs.py; cd ..
```

Para uma linha do tempo limpa, antes de subir as agências mova os arquivos
`agencia/data/*.jsonl` para outra pasta.

Transferência assíncrona entre agências:

```bash
./agencia/testar.sh preparar
./agencia/testar.sh transferencia
```

Resiliência e dead-letter queue:

```bash
./agencia/parar.sh 1
./agencia/testar.sh resiliencia
./agencia/subir.sh 1
./agencia/testar.sh pos
```

Filas do RabbitMQ a qualquer momento (o `testar.sh` já lê a URL do `agencia/.env`):

```bash
cd agencia && RABBITMQ_URL=$(sed -n 's/^RABBITMQ_URL=//p' .env) .venv/bin/python filas.py --alerta --corpo; cd ..
```

Frontend web (login admin / icei123):

```bash
cd frontend && npm run dev
```

Abra o endereço que o Vite mostrar (normalmente http://localhost:5173).

## Sprint 3 - Bully, app Flutter e offline-first

```bash
./agencia/testar.sh contas        # contas 0, 1, 2 e 3 com saldo 100
./agencia/testar.sh lider         # eleição inicial (Parte A)
./agencia/testar.sh sincronizar   # conflito de sincronização (Parte E)
```

App Flutter (Partes D e F):

```bash
cd app_mobile
flutter emulators --launch Small_Phone
flutter devices                   # deve aparecer emulator-5554
flutter run -d emulator-5554 --release
```

No app: login admin / icei123, consulte a conta 3. Para o modo offline, ligue o modo
avião do emulador, faça um depósito (fica pendente) e desligue o modo avião.

Failover (Parte B):

```bash
./agencia/parar.sh 2              # o painel do app muda para a agência 1
./agencia/testar.sh lider
./agencia/subir.sh 2              # a agência 2 volta e retoma a liderança
```

Histórico de lideranças (Parte C), com HH:MM = horário em que as agências subiram:

```bash
cd agencia && .venv/bin/python historico_lideranca.py --desde HH:MM
```

Testes automáticos do app:

```bash
cd app_mobile && flutter test
```

## Problemas conhecidos (Linux)

- `emulator-5554 is offline`: `adb kill-server && adb devices`.
- Emulador sem aceleração: o usuário precisa acessar `/dev/kvm` (`ls -l /dev/kvm`).
- Pouca RAM: feche o navegador antes de abrir o emulador; ele está configurado com 2 GB.
- "Conta não encontrada" no app: as agências reiniciaram; rode `./agencia/testar.sh contas`.
- Agência esquecida consumindo a fila: `pgrep -af uvicorn` e `./agencia/parar.sh`.
- `testar.sh lider` sem consenso (ex.: agência 2 dizendo que a líder é a 1): as agências
  subiram no mesmo instante e um anúncio de COORDENADOR atrasado da agência menor foi
  aceito pela maior. O `subir.sh` já espera 2 s entre as agências para evitar isso; se
  acontecer, `./agencia/parar.sh 2 && ./agencia/subir.sh 2` (e recrie as contas).
