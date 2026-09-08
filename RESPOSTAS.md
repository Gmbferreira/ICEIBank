# RESPOSTAS - ICEIBank Sprint 1

Aluno: Guilherme Martini Brina Ferreira
Matrícula/RA 1153221

## Resumo do que foi entregue

- Serviço de agência em **Python + FastAPI** (arquitetura MVC: rotas/controllers,
  models, services), executado 3 vezes com `AGENCIA_ID=0|1|2` nas portas
  `4021/4022/4023` (OFFSET 21 = 4000 + 21).
- Partição de contas entre as 3 agências: `id_conta % 3`.
- CRUD de contas + depósito/saque, cada operação carimbada com relógio de Lamport.
- Transferência local (mesma agência) e entre agências (chamada REST direta entre
  agências, com `aoEnviar`/`aoReceber` do relógio de Lamport).
- Limitação conhecida implementada e registrada: falha de transferência entre
  agências não reverte o débito (registra `TRANSFERENCIA_FALHOU` no log e retorna 502).
- Script `agencia/mesclar_logs.py` que mescla os logs das 3 agências em uma única
  linha do tempo ordenada pelo timestamp de Lamport.
- Autenticação JWT (PyJWT) protegendo todas as rotas de contas e transferências,
  com os três cenários de teste (sem token, token válido, token expirado).
- Frontend web **React + TypeScript + Tailwind (Vite)** consumindo a API autenticada.
- **Funcionalidade adicional**: histórico de transações por conta.

Evidências em `evidencias/sprint1/` (prints reais capturados no Windows, com
`Get-Date` visível nos terminais).

---

## Funcionalidade adicional (seção 2.1) - Histórico de transações por conta

**O que faz:** o endpoint `GET /contas/{id}/historico` (autenticado) lê o arquivo
JSONL de eventos da própria agência, filtra os eventos que envolvem a conta
(`id`, `idOrigem`, `idDestino` ou `idConta` - cobre criação, depósito, saque,
débito, crédito local e crédito remoto) e os retorna **ordenados pelo timestamp
de Lamport**, do mais antigo para o mais recente.

**Por que escolhi:** todas as operações obrigatórias já ficam registradas no log
de eventos (a matéria-prima da linha do tempo da Parte E). O histórico reaproveita
esse mesmo log para dar **visibilidade da "vida" da conta**, algo que os endpoints
obrigatórios não entregam: o saldo atual mostra só o estado final, mas não o que
aconteceu com a conta (quem transferiu para ela, quanto entrou/saiu, em que ordem
lógica). É comportamento novo e observável, com valor real para um usuário do banco.

**Onde está no código:**
- `agencia/src/services/registro_eventos.py` → `ler_eventos_por_conta(id_conta)`
- `agencia/src/controllers/contas.py` → rota `GET /contas/{id}/historico`
- Exibido no frontend (`frontend/src/App.tsx`) no botão "Histórico".

**Evidência:** `evidencias/sprint1/funcionalidade-adicional.png`

Durante o teste no Linux, o histórico da conta 0 retornou, em ordem de Lamport:
`CRIAR_CONTA(1) → DEPOSITO(3) → SAQUE(4) → TRANSFERENCIA_DEBITO(5) →
TRANSFERENCIA_DEBITO(7) → TRANSFERENCIA_CREDITO(8)` - mesma ordem das operações
executadas na API.

---

## Parte B (seção 6.4)

**P1 - Por que o relógio de Lamport usa `max(contador_local, timestampRecebido) + 1`
ao receber, em vez de simplesmente adotar o timestamp recebido?**

Se o processo simplesmente adotasse o valor recebido, o relógio local poderia
**retroceder**. Exemplo: a agência local está no contador 10 (já processou eventos
locais) e recebe uma mensagem de uma agência mais lenta com timestamp 3. Se adotasse
3, "esqueceria" que já estava em 10 - um evento novo teria carimbo menor que eventos
que o influenciaram, quebrando a regra "se A aconteceu antes de B causalmente, então
timestamp(A) < timestamp(B)". O `max(local, recebido)` garante que o relógio **nunca
retrocede** e incorpora o conhecimento causal do remetente (todos os eventos que ele
já processou até aquele ponto). O `+1` garante que o **evento de recebimento** seja
estritamente maior do que ambos, preservando a ordenação causal.

**P2 - Agência 0 no contador 10 recebe mensagem com timestamp 3. Novo valor?**

`max(10, 3) + 1 = 11`. A agência 0 fica em 11, não em 3 nem em 10. Isso mostra que
agências que processam muitos eventos (contador alto) **"puxam" para cima** as
agências mais lentas com quem trocam mensagens; o relógio de Lamport não mede
"tempo real", apenas a ordem de eventos **dentro de cada fluxo causal**. No meu
teste isso ficou visível: a `agencia-1`, que tinha feito apenas 1 evento (contador
em 1), ao receber o crédito remoto da `agencia-0` (que já estava em 5/6) saltou
direto para `Lamport 7` no `TRANSFERENCIA_CREDITO_REMOTO`.

---

## Parte D (seção 8.3)

**P1 - Por que transferência local não usa `aoEnviar()/aoReceber()`?**

As regras 2 e 3 do relógio de Lamport existem **por causa da troca de mensagens
entre processos distintos**: `aoEnviar` carimba a mensagem antes de despacharla a
outro processo, e `aoReceber` incorpora o timestamp alheio ao chegar. Numa
transferência local, origem e destino estão **na mesma agência, no mesmo processo**:
não há mensagem atravessando a rede, e as duas operações (débito e crédito) são
eventos locais sincronizados no mesmo relógio (`eventoLocal()`). No código, o débito
é `TS 5` e o crédito local é `TS 6` (no teste saiu `TRANSFERENCIA_DEBITO` Lamport 5 e
`TRANSFERENCIA_CREDITO` Lamport 7, ambos na mesma agência, sequenciais). Já na
transferência entre agências, o crédito acontece no processo remoto, então é preciso
de `aoEnviar()` (na origem) e `aoReceber()` (no destino) - visível no teste com o
salto do contador da agência de destino (1 → 7).

**P2 - Reproduza a falha conhecida. O saldo da origem foi revertido?**

Não. Derrubei a agência de destino (porta 4022) e tentei transferir `0 → 1` o valor
de 10: a resposta foi `HTTP 502` com "Falha ao contatar agência de destino. Débito já
aplicado - inconsistência conhecida", e o saldo da conta de origem **caiu** (no teste,
de 70 para 60), sem incremento na conta de destino (agência estava fora do ar). O
evento `TRANSFERENCIA_FALHOU` foi gravado no log JSONL da agência de origem. Isso
significa uma inconsistência temporária: o dinheiro saiu da origem mas não chegou ao
destino - para um banco real isso viola a atomicidade esperada de uma transferência
(débito e crédito deveriam ser "tudo ou nada"). É a limitação **intencional** deste
sprint, deixada de propósito para ser resolvida no Sprint 4.

**P3 - Duas formas de corrigir no Sprint 4 (alto nível):**

1. **Saga (compensação):** a transferência vira uma sequência de passos com ações
   compensatórias. Se o crédito remoto falhar, a agência de origem executa uma
   **compensação** (crédito de volta na conta de origem, registrando no log), e o
   sistema segue consistente. Simples e tolerante a falhas parciais, mas não "dura"
   imediatamente (há uma janela de inconsistência enquanto a compensação não roda).
2. **Two-Phase Commit (2PC):** um **coordenador** pede a todas as agências envolvidas
   que se preparem (`prepare`); só se todas confirmarem capacidade de aplicar, o
   coordenador manda `commit` e o débito/crédito são aplicados juntos; se qualquer
   uma recusar ou falhar, o coordenador manda `abort` e todas estão garantidas a
   reverter. Garante atomicidade forte, mas tem problemas clássicos (bloqueio,
   ponto único de falha do coordenador).

---

## Parte E (seção 10.3)

**P1 - O que significa Lamport não garantir a "volta"?**

A propriedade garantida é só a **ida**: *se* A aconteceu antes de B causalmente,
então `timestamp(A) < timestamp(B)`. A volta não vale - `timestamp(A) < timestamp(B)`
**não** implica que A influenciou B. Na linha do tempo, dois eventos com timestamps
diferentes podem perfeitamente ser **concorrentes** (independentes), apenas ordenados
arbitrariamente pelo sort. Então, o relógio de Lamport produz uma **ordem total**, mas
que pode inserir eventos concorrentes em qualquer posição - a ordem total é uma
"arbitragem" conveniente, não um registro fiel de causalidade.

**P2 - Lamport sozinho seria suficiente? Por que motiva o relógio vetorial?**

Não. No meu teste, a linha do tempo unificada mostrou **empates de timestamp** entre
agências diferentes - ex.: `[Lamport 1] agencia-0 CRIAR_CONTA` e `[Lamport 1]
agencia-1 CRIAR_CONTA` (criações independentes e concorrentes), e `[Lamport 7]
agencia-0 TRANSFERENCIA_DEBITO` e `[Lamport 7] agencia-1 TRANSFERENCIA_CREDITO_REMOTO`
(uma tem o mesmo valor mas são eventos independentes). Empate já revela concorrência,
mas quando os timestamps são **diferentes** Lamport não diz se a ordem é causal ou
apenas arbitrária. Nos casos empatados, a comparação com `horaParede` mostrou que as
ordens coincidem (o evento do Lamport 1 da agencia-0 tem hora .804 e o da agencia-1,
.812), mas hora de parede não é confiável entre máquinas diferentes. O **relógio
vetorial** resolve isso mantendo um vetor de contadores (um por processo): `A` causou
`B` ⟺ `vetor(A) < vetor(B)` componente a componente; senão, são concorrentes. É isso
que o Sprint 2 vai implementar junto com a mensageria.

---

## Parte F (seção 11.3)

**P1 - Autenticação x autorização. O que a implementação verifica?**

- **Autenticação** (quem é você): verificada - o login valida credenciais e emite o
  JWT; cada requisição protegida valida a assinatura e a expiração do token.
- **Autorização** (o que você pode fazer): **não** é verificada em relação a dono de
  conta. Qualquer usuário autenticado **consegue sacar/depositar/transferir de
  qualquer conta** que ele saiba o número, desde que a conta esteja naquela agência.
  Ou seja: um usuário autenticado consegue, sim, sacar de uma conta que não é dele.
  Isso é uma limitação documentada - o roteiro foca no mecanismo de token; vincular
  usuário→contas (RBAC/ownership) é trabalho que cabe num próximo incremento.

**P2 - Por que o servidor não consulta um BD para validar o JWT a cada requisição?**

Porque o JWT é **autocontido e assinado**: o payload (quem é, quando expira) viaja
dentro do token e a assinatura é verificada **matematicamente** com a chave secreta
(no caso, HMAC-SHA256). O servidor só precisa recomputar o HMAC e comparar com a
assinatura do token + checar `exp` - tudo em memória, sem rede para BD. Implicação de
escalabilidade: os servidores **não guardam estado de sessão**, então qualquer
instância/worker pode validar qualquer requisição de forma independente (escala
horizontal trivial, sem sticky sessions e sem replica de sessão). Comparado a sessões
em memória no servidor (que exigem estado compartilhado/memcache e amarram o cliente
a uma instância), o JWT é muito mais simples de escalar; o trade-off é que o logout
não é imediato (o token só morre no `exp`).

**P3 - E se a chave secreta vazasse?**

Qualquer pessoa poderia **forjar tokens válidos**: escolher qualquer usuário, qualquer
`exp` futura e, principalmente, o claim `servico: true` - que é o que autoriza a
chamada interna `creditar-remoto` entre agências. Ou seja, um atacante com a chave
poderia operar qualquer conta e até **emitir créditos remotos**, movimentando dinheiro
entre agências em seu favor, sem nunca passar pelo login. A assinatura deixa de ser
uma barreira. Por isso o segredo deve vir de variável de ambiente (`JWT_SECRET`),
não ficar fixo no código (aqui deixei um valor default apenas para desenvolvimento),
e deve ser rotacionado se houver suspeita de vazamento.

**Decisão de design - formato das credenciais:** usuário + senha (JSON em
`POST /auth/login`), com um único usuário administrador definido por variáveis de
ambiente (`ADMIN_USUARIO`/`ADMIN_SENHA`, padrão `admin`/`icei123`). Escolhi esse modelo
por simplicidade: o sprint não pede cadastro/múltiplos usuários, e assim o login fica
testável de imediato. O token expira em 30 minutos (`JWT_EXP_MIN`), com `iat` e `exp` no
payload. Alternativa considerada (vincular login a número de conta) foi descartada porque
amarraria a autenticação à partição de contas.

**Decisão de design - chamada interna `creditar-remoto`:** a chamada agência-a-agência
**não** usa o token de usuário do frontend. Ela usa um **token de serviço** (`claim
servico: true`), assinado com a mesma chave, com **expiração curta (2 min)**, gerado
pela própria agência de origem na hora. A rota `creditar-remoto` exige esse claim -
tokens de usuário são rejeitados com 401 (testado). Justificativa: (a) as agências
fazem parte do mesmo domínio de confiança do banco, então faz sentido um mecanismo
próprio e curto de máquina-a-máquina; (b) o frontend **nunca** recebe esse claim,
reduzindo a superfície de abuso; (c) mantém a chamada interna **autenticada** (não é
rota aberta). O risco residual é o mesmo compartilhado: se a chave secreta vazar,
qualquer um forja `servico: true`.

---

## Parte G (seção 12.3)

**P1 - Como o frontend "lembra" de reenviar o token?**

O token é salvo em `localStorage` (`iceibank_token`) no login. A função central de
requisição `requisicao()` em `src/api.ts` lê o token do `localStorage` **a cada
chamada** e injeta o cabeçalho `Authorization: Bearer <token>` automaticamente em
todas as requisições (exceto o próprio login). Assim nenhum componente precisa se
preocupar com o cabeçalho manualmente - é um mecanismo centralizado por `api.ts`.
A agência de entrada (porta) também fica no `localStorage` (`iceibank_base_url`) para
persistir a escolha entre sessões.

**P2 - E se o token expirar no meio de uma operação?**

A API responde `401`; a `requisicao()` transforma em `ApiErro(401)`, e o `App.tsx`
detecta o status 401 no `tratarErro`: **limpa o token**, volta para a tela de login e
mostra uma mensagem **visível e específica** - "Sessão expirada ou token inválido. Faça
login novamente." - em vez de um erro genérico. O usuário sabe exatamente o que
aconteceu e o que fazer.

**P3 - Onde ficam o M, o V e o C no frontend?**

- **Model (M):** os tipos de domínio em `src/types.ts` (Conta, EventoHistorico) e o
  acesso aos dados encapsulado em `src/api.ts` (que conversa com a API e guarda/limpa
  o token). Parte do estado da aplicação (conta exibida, histórico, mensagem) também é
  "modelo" mantido no componente.
- **View (V):** as árvores JSX em `src/App.tsx` que renderizam as telas (login,
  operações, histórico), 100% de apresentação.
- **Controller (C):** os handlers de eventos (`onClick={...}`, `onSubmit={...}`) no
  `App.tsx`, que orquestram "o que fazer": chamar `api`, atualizar estado, exibir
  mensagem de erro/sucesso.
- De forma honesta, em um SPA pequeno com um componente principal o V e o C ficam
  **mais misturados** do que o padrão sugere (componentes React costumam unir
  renderização e comportamento), mas a separação M (tipos/API) vs. o restante está
  clara. Uma evolução para o padrão seria extrair hooks/contextos por domínio.

**Decisão de design - agência de entrada:** o cabeçalho tem um seletor com as 3
agências (`4021/4022/4023`). Escolhi porque cada agência é uma partição independente:
o frontend precisa de um "porta de entrada" configurável, já que a agência só opera
contas que são dela (`id % 3`). Uma operação numa conta de outra agência exige trocar
o seletor - mensagem informativa é mostrada quando isso acontece. Isto é exatamente o
que o roteiro pede (campo indicando qual agência é a porta de entrada).

---

## Notas de implementação

- **Formato de erro da API:** `{"erro": "..."}` - igual ao exemplo Node da disciplina
  (via `exception_handler` em `app.py`), para o frontend ler `corpo.erro` uniformemente.
- **Concorrência no relógio:** `threading.Lock` nas três operações do
  `RelogioLamport`. Com FastAPI/Uvicorn e requisições concorrentes, `contador` é
  estado compartilhado - mesmo em single-worker, o lock evita condição de corrida
  (equivalente ao `synchronized` do exemplo Java).
- **Contas em memória** (`app.state.contas`, um dict): proposital, como o roteiro -
  se o processo reiniciar, as contas somem.
- **Logs:** `agencia/data/eventos-<agencia>.jsonl`, fora do Git (`.gitignore`).
  Evidências vão em `evidencias/`, não na pasta `data/`.