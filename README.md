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
  revertido. Isso é proposital neste sprint — a atomicidade é resolvida no
  Sprint 4 com transações distribuídas (2PC/Saga).
- **Autenticação**: JWT protegendo todas as rotas de contas/transferências.
- **Frontend**: React + TypeScript + Tailwind (Vite).
- **Funcionalidade adicional**: histórico de transações por conta
  (`GET /contas/{id}/historico`).

Ver `RESPOSTAS.md` para as decisões de design e questões do roteiro.

## Como rodar

OBS: OFFSET pessoal = 21 (dois últimos dígitos da matrícula/RA).

### Backend (3 terminais — Windows PowerShell)

```powershell
cd agencia
python -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -r requirements.txt

# Terminal 1
$env:AGENCIA_ID=0; uvicorn src.app:app --port 4021
# Terminal 2
$env:AGENCIA_ID=1; uvicorn src.app:app --port 4022
# Terminal 3
$env:AGENCIA_ID=2; uvicorn src.app:app --port 4023
```

Credenciais de login (padrão): `admin` / `icei123`.

### Linha do tempo unificada (Parte E)

```powershell
cd agencia
python mesclar_logs.py
```

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
| POST | `/auth/login` | — | Login; retorna JWT |
| POST | `/contas` | JWT | Criar conta (só se `id % 3 === agência`) |
| GET | `/contas/{id}` | JWT | Consultar saldo |
| POST | `/contas/{id}/depositar` | JWT | Depósito |
| POST | `/contas/{id}/sacar` | JWT | Saque |
| GET | `/contas/{id}/historico` | JWT | **Extra:** histórico pela Lamport |
| POST | `/transferencias` | JWT | Transferência (o backend decide local/interagência) |
| POST | `/contas/{id}/creditar-remoto` | token de serviço | Chamada interna entre agências |

Testes prontos com `curl` na evidência `evidencias/sprint1/` (sessão 4 do
`RESPOSTAS.md` / planilha de sprint).