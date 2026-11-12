# ICEIBank

Banco simplificado dividido em agências. Cada agência é uma partição independente de
contas, executada como um serviço REST independente. As transferências entre agências
trocam mensagens por RabbitMQ (publish/subscribe) e cada evento é carimbado com um
**relógio vetorial**, o que permite mesclar os logs das agências em uma única linha do
tempo **causalmente consistente** - a ordem respeita causa e efeito e marca explicitamente
onde a ordem é arbitrária.

## Sprint 1 (histórico)

- **Backend**: Python + FastAPI (MVC/REST), 3 instâncias da mesma aplicação
  (`AGENCIA_ID=0|1|2`), portas `4021/4022/4023` (OFFSET 21).
- **Relógio de Lamport**: contador inteiro por agência com as três regras
  (evento local, ao enviar, ao receber).
- **Transferências**: locais (mesma agência) e entre agências (chamada REST
  direta entre agências).
- **Limitação conhecida (intencional)**: se uma transferência entre agências
  falhar no meio (agência de destino fora do ar), o débito aplicado NÃO é
  revertido. Isso é proposital neste sprint - a atomicidade é resolvida no
  Sprint 4 com transações distribuídas (2PC/Saga).
- **Autenticação**: JWT protegendo todas as rotas de contas/transferências.
- **Frontend**: React + TypeScript + Tailwind (Vite).
- **Funcionalidade adicional**: histórico de transações por conta
  (`GET /contas/{id}/historico`).

## Sprint 2 (estado atual)

- **Relógio vetorial** no lugar do Lamport: vetor com uma posição por agência
  (`[n_0, n_1, n_2]`), com as três regras - `evento_local()` incrementa a posição
  própria, `ao_enviar()` carimba o vetor no payload e `ao_receber()` faz a
  fusão por componente com `max()` antes de incrementar a posição própria.
  É o `max()` na fusão que distingue o vetor do Lamport: o crédito recebido na
  agência 2 carrega o componente da agência 0, provando a cadeia causal.
- **Relógio de parede** (`horaParede`, ISO 8601 UTC) gravado junto com cada
  evento. Ele **não** ordena nada por si só - serve apenas de desempate para
  eventos concorrentes, e como registro de auditoria.
- **Transferências entre agências via RabbitMQ**: a agência de origem debita
  localmente e publica com confirmação do broker; a de destino credita a partir
  do consumidor. Não existe mais chamada HTTP entre agências.
- **Dead-letter queue**: crédito recusado (regra de negócio) ou erro inesperado
  vai para `fila-agencia-<id>.falhas` em vez de ser perdido.
- **Frontend**: exibe o vetor de cada evento no histórico.
- **Evidências**: `evidencias/sprint2/` com as capturas do publish/subscribe,
  da resiliência e da DLQ.

O débito continua **não** revertido quando o destino está fora do ar. A mudança é de
outra natureza: o crédito não se perde, ele fica retido na fila `fila-agencia-<id>`
até a agência voltar (fila durável, sem TTL), então a entrega é garantida sem
duplicidade. Atomicidade real (débito e crédito visíveis como uma só transação)
continua sendo problema do Sprint 4.

Ver `RESPOSTAS.md` para as decisões de design e questões do roteiro.

## Como rodar

OBS: OFFSET pessoal = 21 (dois últimos dígitos da matrícula/RA).

### Backend (3 terminais - Windows PowerShell)

```powershell
cd agencia
python -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -r requirements.txt
```

No **mesmo terminal**, antes de subir a agência, defina a URL do RabbitMQ
(CloudAMQP). A agência falha no startup com uma mensagem clara se ela faltar -
não versionar essa variável, ela carrega a senha:

```powershell
$env:RABBITMQ_URL = "amqps://<usuario>:<senha>@<host>/<vhost>"
```

Depois, um terminal por agência:

```powershell
# Terminal 1
$env:AGENCIA_ID=0; uvicorn src.app:app --port 4021
# Terminal 2
$env:AGENCIA_ID=1; uvicorn src.app:app --port 4022
# Terminal 3
$env:AGENCIA_ID=2; uvicorn src.app:app --port 4023
```

**Atalho (Sprint 3):** `.\agencia\subir.ps1` faz o mesmo de uma vez: abre uma
janela do PowerShell por agência, já com `AGENCIA_ID`, porta e `RABBITMQ_URL`
definidos. A URL é lida do terminal ou de `agencia\.env` (não versionado); se não
existir, o script pergunta e salva nesse arquivo. Para subir só uma agência (ex.:
religar a líder no teste de failover): `.\agencia\subir.ps1 -Agencias 2`.

Cada agência imprime no startup a linha de consumo, que confirma que a topologia
foi declarada:

```text
[RabbitMQ] agencia 0 consumindo fila-agencia-0 (routing key agencia.0.creditar)
```

**Não use `--reload`**: ele reinicia o processo no primeiro arquivo alterado e
abre um consumidor duplicado na mesma fila.

Credenciais de login (padrão): `admin` / `icei123`.

### Topologia do RabbitMQ

| Recurso | Tipo | Papel |
|---|---|---|
| `iceibank.eventos` | exchange `topic`, durable | entrada das transferências entre agências |
| `fila-agencia-<id>` | fila durable | uma por agência, ligada à exchange por `agencia.<id>.creditar` |
| `iceibank.dlx` | exchange `topic`, durable | dead-letter exchange |
| `fila-agencia-<id>.falhas` | fila durable, TTL 7 dias | mensagens que a agência recebeu e não conseguiu aplicar |

A fila principal é declarada com `x-dead-letter-exchange` e
`x-dead-letter-routing-key`, e é o broker (não a aplicação) que faz o
encaminhamento quando o consumidor faz `basic_nack(requeue=False)`.

Para inspecionar as filas (precisa da `RABBITMQ_URL` definida no terminal):

```powershell
.\agencia\filas.py --alerta --corpo
```

O aviso de "mais de um consumidor" importa: como as filas são compartilhadas por
todas as agências do mesmo vhost, uma instância esquecida de um teste anterior
fica Connected e pode consumir a mensagem antes da hora - o crédito vai para o
processo errado e o saldo que você confere na tela não bate. Vale checar **antes**
de rodar qualquer cenário:

```powershell
# deve listar 1 consumidor por fila; se listar mais, há processo esquecido
.\agencia\filas.py --alerta
```

Para caçar e encerrar o processo esquecido, cada agência do venv ocupa dois PIDs
(um shim e o interpretador filho), então mate a árvore inteira:

```powershell
Get-CimInstance Win32_Process -Filter "Name like '%python%'" |
  Where-Object { $_.CommandLine -match '--port 402[123]' } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
```

### Testes do Publish/Subscribe (4º terminal)

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy RemoteSigned
.\agencia\testar.ps1 -Etapa preparar
.\agencia\testar.ps1 -Etapa transferencia
# Ctrl+C na agência 1, depois:
.\agencia\testar.ps1 -Etapa resiliencia
# suba a agência 1 de novo, depois:
.\agencia\testar.ps1 -Etapa pos
```

### Linha do tempo unificada (Parte E)

Para uma linha do tempo limpa, os logs precisam vir de **uma única execução**: o
relógio vetorial vive na memória e zera a cada reinício da agência, então eventos de
execuções diferentes não são comparáveis entre si (todos recomeçaram do zero). O
script detecta isso e avisa quando vetores se repetem.

```powershell
# 1) com as 3 agências no ar, em um terminal limpo:
Remove-Item agencia\data\*.jsonl -ErrorAction SilentlyContinue
.\agencia\testar.ps1 -Etapa timeline
# 2) e então, em outro terminal:
cd agencia
python mesclar_logs.py
```

O `-Etapa timeline` monta um cenário que exercita justamente o que o vetor prova:
as três contas nascem concorrentes, e a transferência 1→2 faz o crédito chegar na
agência 2 carregando o componente da agência 0 (`[3,5,0]` publicada → `[3,5,1]`
creditada). Na saída, os eventos são ordenados topologicamente e os pares vizinhos
sem relação de causa são listados à parte, marcados como ordem arbitrária.

O `mesclar_logs.py` também aceita `--csv` para exportar a tabela, e ainda converte
eventos antigos do Sprint 1 (campo `timestampLamport`) para vetor, colocando o
contador na posição da própria agência - útil só para não quebrar a leitura de logs
antigos, não para misturar execuções.

### Frontend (outro terminal)

```powershell
cd frontend
npm install
npm run dev
# abrir http://localhost:5173 e escolher a agência de entrada no seletor
```

## Endpoints principais

| Verbo | Rota | Autenticação | Descrição |
|-------|------|--------------|-----------|
| POST | `/auth/login` | - | Login; retorna JWT |
| POST | `/contas` | JWT | Criar conta (só se `id % 3 === agência`) |
| GET | `/contas/{id}` | JWT | Consultar saldo |
| POST | `/contas/{id}/depositar` | JWT | Depósito |
| POST | `/contas/{id}/sacar` | JWT | Saque |
| GET | `/contas/{id}/historico` | JWT | **Extra:** histórico ordenado pelo relógio vetorial |
| POST | `/transferencias` | JWT | Transferência (o backend decide local/interagência) |

No Sprint 1 existia `POST /contas/{id}/creditar-remoto`, interno, protegido por um
token de serviço. A rota **deixou de existir**: o crédito remoto passou a chegar pelo
consumidor do RabbitMQ, e sem chamada HTTP entre agências não há mais o que esse
token autorizasse.

Testes prontos com `curl` na evidência `evidencias/sprint1/` (sessão 4 do
`RESPOSTAS.md` / planilha de sprint).