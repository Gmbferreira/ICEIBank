# ICEIBank

Banco simplificado dividido em agências. Cada agência é uma partição independente de
contas, executada como um serviço REST independente. Todos os eventos são carimbados
com relógio lógico de Lamport, e os logs das agências podem ser mesclados em uma única
linha do tempo ordenada pelo relógio.

## Sprint 1

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
fica Connected e pode consumir a mensagem antes da hora.

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

```powershell
cd agencia
python mesclar_logs.py
```

> No Sprint 2 o `mesclar_logs.py` ainda ordena pelo timestamp de Lamport (campo
> `timestampLamport` dos logs do Sprint 1). A migração para o relógio vetorial
> está prevista para a Etapa 5. Até lá, apague os logs antigos em
> `agencia/data/` antes de gerar a linha do tempo, ou o script não vai encontrar
> `timestampVetorial` nos eventos do Sprint 1.

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
| GET | `/contas/{id}/historico` | JWT | **Extra:** histórico pela Lamport |
| POST | `/transferencias` | JWT | Transferência (o backend decide local/interagência) |
| POST | `/contas/{id}/creditar-remoto` | token de serviço | Chamada interna entre agências |

Testes prontos com `curl` na evidência `evidencias/sprint1/` (sessão 4 do
`RESPOSTAS.md` / planilha de sprint).