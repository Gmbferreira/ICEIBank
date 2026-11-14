# RESPOSTAS - ICEIBank (Sprints 1, 2 e 3)

Aluno: Guilherme Martini Brina Ferreira
Matrícula/RA 1153221

> Este documento responde ao roteiro dos dois sprints. Onde a resposta mudou de
> forma relevante entre eles, marco o estado antigo como **[Sprint 1]** e o
> estado atual como **[Sprint 2]**, para ficar explícito o que a mensageria e o
> relógio vetorial resolveram.
>
> As respostas do **Sprint 3** ficam reunidas na seção "Sprint 3", no fim do
> documento: a numeração das partes recomeça no roteiro novo (há uma "Parte B"
> em cada sprint), então mantê-las juntas evita confusão.

## Resumo do que foi entregue (estado atual - Sprint 2)

- Serviço de agência em **Python + FastAPI** (arquitetura MVC: rotas/controllers,
  models, services), executado 3 vezes com `AGENCIA_ID=0|1|2` nas portas
  `4021/4022/4023` (OFFSET 21 = 4000 + 21).
- Partição de contas entre as 3 agências: `id_conta % 3`.
- CRUD de contas + depósito/saque, cada operação carimbada com **relógio vetorial**
  (`[n_0, n_1, n_2]`), com as três regras `evento_local()`, `ao_enviar()` e
  `ao_receber()`.
- **Transferência local** (débito e crédito no mesmo processo) e **entre agências
  por publish/subscribe no RabbitMQ**: a origem debita e publica com confirmação do
  broker; o destino credita a partir de um consumidor. Não há mais chamada HTTP
  entre agências, e portanto não há mais rota interna `creditar-remoto` nem token
  de serviço.
- **Dead-letter queue** por agência (`fila-agencia-<id>.falhas`): crédito recusado
  por regra de negócio ou erro inesperado vão para a fila de falhas em vez de ser
  perdidos. TTL de 7 dias, sem consumidor por escolha de projeto.
- Script `agencia/mesclar_logs.py` que mescla os logs das 3 agências em uma linha
  do tempo **causalmente consistente**: ordenação topológica pelo vetor, com os
  empates (eventos concorrentes) marcados explicitamente como ordem arbitrária.
  Aceita `--csv`.
- Autenticação JWT (PyJWT) protegendo todas as rotas de contas e transferências,
  com os três cenários de teste (sem token, token válido, token expirado).
- Frontend web **React + TypeScript + Tailwind (Vite)** consumindo a API autenticada,
  exibindo o vetor de cada evento no histórico.
- **Funcionalidade adicional**: histórico de transações por conta.

Evidências em `evidencias/sprint1/` e `evidencias/sprint2/` (prints reais
capturados no Windows, com `Get-Date` visível nos terminais).

## Resumo do Sprint 1 (histórico)

- Transferência entre agências por **chamada REST direta**, com token de serviço.
- **Relógio de Lamport** (contador inteiro) no lugar do vetor.
- Limitação conhecida implementada e registrada: falha de transferência entre
  agências não reverte o débito (registra `TRANSFERENCIA_FALHOU` no log e
  retorna 502) - dinheiro sai da origem e não chega ao destino.

### O que o Sprint 2 mudou em relação a isso

| | Sprint 1 | Sprint 2 |
|---|---|---|
| Transporte entre agências | HTTP direto, token de serviço | RabbitMQ publish/subscribe |
| Relógio | Lamport (inteiro) | vetorial (uma posição por agência) |
| Destino fora do ar | 502, débito perdido | 200 "publicada", crédito retido na fila durável |
| Destino volta depois | não há recuperação | o consumidor credita quando sobe |
| Crédito chega em conta inexistente | erro 404 e mensagem consumida | `CreditoRecusado` → DLQ, mensagem preservada |
| Linha do tempo | ordem total arbitrária | ordem causal + empates marcados |

---

## Funcionalidade adicional (seção 2.1) - Histórico de transações por conta

**O que faz:** o endpoint `GET /contas/{id}/historico` (autenticado) lê o arquivo
JSONL de eventos da própria agência, filtra os eventos que envolvem a conta
(`id`, `idOrigem`, `idDestino` ou `idConta` - cobre criação, depósito, saque,
débito, crédito local e crédito remoto) e os retorna **ordenados pelo relógio
vetorial**, do mais antigo para o mais recente. **[Sprint 1]** usava o timestamp
de Lamport; **[Sprint 2]** o histórico passou a ordenar pelo vetor, que é
comparável componente a componente.

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

Durante o teste no Linux, o histórico da conta 0 retornou, em ordem causal:
`CRIAR_CONTA(1) → DEPOSITO(3) → SAQUE(4) → TRANSFERENCIA_DEBITO(5) →
TRANSFERENCIA_DEBITO(7) → TRANSFERENCIA_CREDITO(8)` - mesma ordem das operações
executadas na API.

---

## Funcionalidade adicional (Sprint 2) - Relógio vetorial e linha do tempo causal

**O que faz:** cada evento recebe um vetor `[n_0, n_1, n_2]`, com uma posição por
agência, além da `horaParede` (ISO 8601 UTC) e do `tipo`/`detalhes`. O
`agencia/mesclar_logs.py` lê os três arquivos JSONL e produz **uma única linha do
tempo causalmente consistente**: uma ordem topológica que respeita causa e efeito,
na qual os pares de eventos que são **concorrentes** (nenhum causou o outro) são
listados à parte, marcados como ordem arbitrária.

**As três regras** (`agencia/src/services/relogio_vetorial.py`):

| Regra | Operação | Efeito no vetor |
|---|---|---|
| 1 | `evento_local()` | incrementa a posição da própria agência |
| 2 | `ao_enviar()` | carimba o vetor atual no payload da mensagem |
| 3 | `ao_receber(v)` | `fusão = max(local, v)` componente a componente, e só então incrementa a posição própria |

**Por que isso e não o Lamport.** A regra 3 é a diferença de fundo. O Lamport
inteiro faz `max(local, recebido) + 1`: o número incorpora "quanto trabalho eu já
fiz", mas **não diz quem** nem **de quem** o evento veio. No vetorial, o `max()` é
feito **independente em cada posição**, então o vetor carrega o conhecimento
causal de todas as agências de forma separada. É isso que permite a afirmação que
o Lamport não sustenta: `A causou B ⟺ vetor(A) < vetor(B)` em todos os componentes
- e, quando isso é falso, saber que os dois são concorrentes em vez de apenas
"diferentes".

**A prova no cenário de teste.** Em uma execução limpa (`testar.ps1 -Etapa timeline`)
com duas transferências encadeadas 0→1 e depois 1→2:

```
[3, 0, 0]  agencia-0  TRANSFERENCIA_PUBLICADA      <- contagem local da agencia 0
[3, 3, 0]  agencia-1  TRANSFERENCIA_CREDITO_REMOTO <- fundiu [3,0,0] e virou [3,3,0]
[3, 5, 0]  agencia-1  TRANSFERENCIA_PUBLICADA      <- contagem local da agencia 1
[3, 5, 1]  agencia-2  TRANSFERENCIA_CREDITO_REMOTO <- chegou na agencia 2 com o
                                                          componente da agencia 0 junto
```

O `[3,5,1]` na agência 2 é o ponto: o crédito carrega o componente `3` da agência 0
e o `5` da agência 1, porque a agência 1 **viu** o evento da agência 0 antes de
publicar. Um relógio de Lamport mostraria apenas `[8]` (ou o contador da própria
agência 2) e essa informação estaria perdida. É a cadeia causal 0→1→2 codificada
dentro do vetor.

**Concorrência aparece como empate, não como ordem.** Na mesma execução, as três
criações de conta saem com `[1,0,0]`, `[0,1,0]` e `[0,0,1]` - nenhum desses vetores
é menor que outro, então nenhum causou os outros. A linha do tempo os ordena por
`horaParede` como desempate, mas **rotula o par como arbitrário**, que é a
informação honesta: a ordem entre eles é escolha da ferramenta, não do sistema.

**Onde está no código:**
- `agencia/src/services/relogio_vetorial.py` → `RelogioVetorial` com as três regras
- `agencia/src/services/registro_eventos.py` → grava `timestampVetorial` + `horaParede`
- `agencia/mesclar_logs.py` → ordenação topológica, detecção de concorrência, `--csv`
- `agencia/testar.ps1 -Etapa timeline` → cenário que produz a cadeia acima
- Frontend (`frontend/src/App.tsx`) → coluna "Vetor" no histórico

**Evidência:** `evidencias/sprint2/linha-do-tempo-causal.png`

**Ressalva importante:** o relógio vetorial vive **na memória** e zera a cada
reinício da agência. Logs de execuções diferentes não são comparáveis entre si
(tudo recomeça do zero), então a linha do tempo só é válida para uma execução
única. O `mesclar_logs.py` detecta esse caso - vetores repetidos entre eventos
diferentes indicam mistura de execuções - e avisa em vez de gerar uma ordem
silenciosamente errada. Para eventos do Sprint 1, que gravavam apenas
`timestampLamport`, o script converte o contador para a posição da própria agência,
o que preserva a leitura de logs antigos mas não torna execuções distintas
comparáveis.

---

## Funcionalidade adicional (Sprint 2) - Dead-letter queue

O Publish/Subscribe resolve o problema do Sprint 1 (débito sem crédito quando a
agência de destino está fora do ar), mas cria um caso novo: e se a mensagem
chegar ao destino e ainda assim não puder ser aplicada? É exatamente o que
acontece no teste de resiliência — a agência 1 reinicia, as contas (em memória)
somem, e o crédito publicado pela agência 0 chega para uma conta que não existe
mais. Antes da DLQ, o consumidor confirmava (`basic_ack`) a mensagem e ela
desaparecia sem deixar rastro: dinheiro debitado na origem, nenhuma prova do que
foi perdido.

**Topologia.** Cada agência tem duas filas: a principal (`fila-agencia-<id>`) e
a de falhas (`fila-agencia-<id>.falhas`). A principal é declarada com dois
argumentos que a ligam à dead-letter exchange:

```
fila-agencia-<id>  --(x-dead-letter-exchange=iceibank.dlx,
                       x-dead-letter-routing-key=agencia.<id>.creditar.falha)-->  iceibank.dlx
iceibank.dlx (topic, durable)  --(agencia.<id>.creditar.falha)-->  fila-agencia-<id>.falhas
```

**Política de confirmação** (`src/services/mensageria.py`):

| Situação | Confirmação | Efeito |
|---|---|---|
| Crédito aplicado | `basic_ack` | mensagem consumida |
| Recusa de negócio (`CreditoRecusado`) | `basic_nack(requeue=False)` | vai para a DLQ |
| Erro inesperado | `basic_nack(requeue=False)` | vai para a DLQ |
| Agência cai no meio do tratamento | nenhuma | o broker devolve o `delivery_tag` à fila |

`requeue=False` é o que evita o laço de mensagem "venenosa": se a causa for
permanente (conta que não existe mais), reentregar a mesma mensagem para a mesma
agência ia repetir a falha indefinidamente. Perdemos a chance de reprocessamento
automático, mas ganhamos o registro do que falhou — que é o objetivo. Como o
sistema não tem como reentregar sozinho (o publicador não guarda o resultado),
quem reentrega é uma pessoa, olhando a DLQ.

A separação entre `CreditoRecusado` e erro inesperado não muda o destino (ambos
vão para a DLQ), mas muda o que aparece no log — dá para distinguir "não havia
conta" de "deu exception", que são problemas de naturezas diferentes.

**Por que a fila de falhas tem TTL de 7 dias.** Mensagens rejeitadas servem para
diagnóstico, não para reprocessamento automático. Sem expiração elas ficariam
ocupando disco indefinidamente; `x-message-ttl = 604800000` (7 dias) faz o
broker descartá-las sozinho depois de uma semana.

**Detalhe operacional que custou tempo:** o RabbitMQ só aceita re-declarar uma
fila existente se os argumentos forem idênticos. Ao acrescentar os argumentos de
dead-letter, o `queue_declare` das filas que já existiam respondia **406
PRECONDITION_FAILED** e o consumidor morria no startup. As filas do projeto
precisaram ser deletadas uma vez, para que a agência as recriasse já com a
DLX — de lá a necessidade de o script de evidência avisar o número de
consumidores por fila (`agencia/filas.py --alerta`), já que um processo antigo
conectado à mesma fila roubaria a mensagem e o crédito apareceria na agência
errada.

**Onde está no código:**
- `agencia/src/services/mensageria.py` → `EXCHANGE_DLX`, `nome_fila_falhas`,
  `argumentos_fila`, `CreditoRecusado` e a política de `ack`/`nack` no callback
- `agencia/src/app.py` → `processar_credito_remoto` levanta `CreditoRecusado`
  (um `return` silencioso faria o consumidor confirmar a mensagem)
- `agencia/filas.py` → listagem das DLQs e leitura do conteúdo (`--corpo`, que
  devolve cada mensagem à fila, sem consumir)

**Evidência:** `evidencias/sprint2/dlq.png`

Saída real do teste de resiliência: a agência 1 registra
`[Vetor [5, 1, 0]] CREDITO_REMOTO_FALHOU` com motivo `conta nao encontrada`, e a
mensagem aparece em `fila-agencia-1.falhas` com o corpo
`{"idConta": 1, "valor": 20.0, "vetorEnvio": [5, 0, 0], "origemAgencia": 0}`.

---

## Parte B (seção 6.4)

**[Sprint 1] P1 - Por que o relógio de Lamport usa `max(contador_local, timestampRecebido) + 1`
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

**[Sprint 1] P2 - Agência 0 no contador 10 recebe mensagem com timestamp 3. Novo valor?**

`max(10, 3) + 1 = 11`. A agência 0 fica em 11, não em 3 nem em 10. Isso mostra que
agências que processam muitos eventos (contador alto) **"puxam para cima"** as
agências mais lentas com quem trocam mensagens; o relógio de Lamport não mede
"tempo real", apenas a ordem de eventos **dentro de cada fluxo causal**. No meu
teste isso ficou visível: a `agencia-1`, que tinha feito apenas 1 evento (contador
em 1), ao receber o crédito remoto da `agencia-0` (que já estava em 5/6) saltou
direto para `Lamport 7` no `TRANSFERENCIA_CREDITO_REMOTO`.

**[Sprint 2] P3 - E no relógio vetorial, qual é a resposta equivalente?**

A mesma pergunta tem resposta análoga, com uma diferença que importa. O código
atual é `RelogioVetorial.ao_receber()`, e ele também não pode retroceder - mas
"retroceder" agora tem um sentido mais forte: **nenhuma das posições pode diminuir**.

Para o mesmo exemplo, agência 0 com `[10, 4, 2]` recebendo `[3, 7, 0]`:

```
max([10, 4, 2], [3, 7, 0]) = [10, 7, 2]     <- fusão componente a componente
[10, 7, 2] + 1 na posição 0      = [11, 7, 2]
```

A posição 0 vai a 11 (porque era 10 e o evento de recebimento tem de ser estritamente
maior que tudo que já influencei); a posição 1 vai de 4 para 7, **ganhando** o
conhecimento de que a agência 1 já tinha produzido 7 eventos quando enviou, mesmo
que eu não os tenha visto; a posição 2 fica em 2, porque o remetente ainda não sabia
de nada naquela agência.

A diferença que o vetor resolve e o Lamport não: no Lamport eu só saberia que o
contador final era 11, sem nenhuma pista de **qual agência** tinha adiantado o
relógio. No vetor,
a fusão é feita **por posição**, então eu consigo afirmar que vi os 7 eventos da
agência 1 e que nenhum evento da agência 2 me influenceou ainda. É essa granularidade
que depois permite dizer com precisão se `A` causou `B` ou se os dois são
concorrentes - assunto da Parte E.

---

## Parte D (seção 8.3)

**[Sprint 2] P1 - Por que transferência local não usa `ao_enviar()/ao_receber()`?**

As regras 2 e 3 do relógio vetorial existem **por causa da troca de mensagens
entre processos distintos**: `ao_enviar()` carimba o vetor antes de despachá-lo a
outro processo, e `ao_receber()` incorpora o vetor alheio ao chegar. Numa
transferência local, origem e destino estão **na mesma agência, no mesmo processo**:
não há mensagem atravessando a rede, e as duas operações (débito e crédito) são
eventos locais sincronizados no mesmo relógio (`evento_local()`). No código, o
crédito local usa apenas `evento_local()` e o comentário em
`src/controllers/transferencias.py` registra essa decisão.

O detalhe interessante é que agora existe uma **terceira** situação que o Sprint 1
não tinha: quando o destino é outra agência, `ao_enviar()` é chamada na origem e
`ao_receber()` no consumidor **do outro processo**, mas entre os dois há o broker.
O que a agência de origem carimba em `ao_enviar()` é o vetor no momento da
publicação, e é esse vetor (não um contador local qualquer) que viaja na mensagem -
por isso o crédito final na agência 2 carrega o componente da agência 0.

**[Sprint 1] P2 - Reproduza a falha conhecida. O saldo da origem foi revertido?**

Não. **[Sprint 1]** Derrubei a agência de destino (porta 4022) e tentei transferir
`0 → 1` o valor de 10: a resposta foi `HTTP 502` com "Falha ao contatar agência de
destino. Débito já aplicado - inconsistência conhecida", e o saldo da conta de origem
**caiu** (no teste, de 70 para 60), sem incremento na conta de destino (agência
estava fora do ar). O evento `TRANSFERENCIA_FALHOU` foi gravado no log JSONL da
agência de origem. Isso significa uma inconsistência: o dinheiro saiu da origem mas
não chegou ao destino - para um banco real isso viola a atomicidade esperada de uma
transferência (débito e crédito deveriam ser "tudo ou nada"). Era a limitação
**intencional** do Sprint 1, deixada de propósito para ser resolvida no Sprint 4.

**[Sprint 2] A mesma pergunta no estado atual: o saldo da origem foi revertido?**

Não, e agora a resposta completa é mais interessante do que um simples "não". Com o
publish/subscribe, derrubar a agência de destino muda o que a resposta significa:

| | Sprint 1 | Sprint 2 |
|---|---|---|
| Resposta | `502` - "falha ao contatar destino" | `200` - `{"status": "publicada"}` |
| Débito na origem | aplicado, e o dinheiro sumia | aplicado, e o dinheiro fica **retido na fila** |
| Destino volta depois | nada acontece | o consumidor credita e o saldo aparece |
| Evento no log | `TRANSFERENCIA_FALHOU` | `TRANSFERENCIA_PUBLICADA` |

Ou seja: **o débito continua não sendo revertido** - a resposta é essa - mas a
consequência mudou de categoria. No Sprint 1 o dinheiro ficava "no limbo" (saiu da
origem, não existia em lugar nenhum). No Sprint 2 ele está **garantido**: a mensagem
está em `fila-agencia-<id>`, que é durable e não tem TTL, e será creditada assim que
a agência voltar. É a diferença entre *perder* e *atrasar*.

O que **não** foi resolvido, e é importante ser honesto sobre isso: **atomicidade**.
Entre o débito na origem e o crédito no destino existe uma janela em que o dinheiro
já saiu de um lado e ainda não apareceu do outro. Se alguém consultar os saldos
nesse intervalo, vê uma inconsistência. Além disso, se o processo da agência de
origem reiniciar depois de publicar, o débito já foi aplicado e não há como
descobrir sozinho que o crédito está pendente. O publish/subscribe resolveu a
**perda** de mensagens; a atomicidade de visibilidade continua sendo problema do
Sprint 4, e as duas alternativas classical são as mesmas descritas em P3.

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

Não, e o motivo é que a informação de **concorrência** se perde. O Lamport garante
só a "ida" (causa ⟹ ordem), então ele sempre entrega uma **ordem total**. Quando
dois eventos têm timestamps **diferentes**, o Lamport não diz se a ordem é causal ou
apenas arbitrária - e é justamente aí que ele mente com convicção. No teste do
Sprint 1 isso apareceu: `[Lamport 1] agencia-0 CRIAR_CONTA` e `[Lamport 1]
agencia-1 CRIAR_CONTA` eram empates que denunciavam concorrência, mas
`[Lamport 7] agencia-0 TRANSFERENCIA_DEBITO` e `[Lamport 7] agencia-1
TRANSFERENCIA_CREDITO_REMOTO` tinham o mesmo valor sem qualquer relação - e o
mesmo Lamport conseguiria produzir `agencia-2 (7)` antes de `agencia-0 (7)`, que é
uma leitura impossível da história real. Comparei com `horaParede` e as ordens
coincidiam, mas hora de parede não é confiável entre máquinas diferentes (relógios
dessincronizados, latência, e o próprio tempo de execução).

**[Sprint 2] O que o vetor resolve na prática.** O relógio vetorial mantém um vetor
de contadores, um por agência, e a comparação passa a ser **componente a
componente**:

```
A causou B  ⟺  para todo i:  vetor_i(A) < vetor_i(B)
A e B concorrentes  ⟺  nenhum é menor que o outro em todos os componentes
```

No cenário de teste (`-Etapa timeline`), a linha do tempo sai assim:

```
  #  vetor           agencia     tipo
  1  [1, 0, 0]       agencia-0   CRIAR_CONTA                     <- concorrentes
  2  [0, 1, 0]       agencia-1   CRIAR_CONTA                        entre si
  3  [0, 0, 1]       agencia-2   CRIAR_CONTA
  ...
  7  [3, 3, 0]       agencia-1   TRANSFERENCIA_CREDITO_REMOTO    <- causa de 8
  8  [3, 4, 0]       agencia-1   TRANSFERENCIA_DEBITO            <- causa de 9
  9  [3, 5, 0]       agencia-1   TRANSFERENCIA_PUBLICADA
 10  [3, 5, 1]       agencia-2   TRANSFERENCIA_CREDITO_REMOTO    <- carrega o
                                                                     componente 0
```

Os eventos 7 a 10 formam uma cadeia causal e o vetor **explica** por quê: cada um é
estritamente maior que o anterior em algum componente. Já os eventos 1 a 3 são
mutuamente concorrentes (nenhum vetor é menor que o outro), então o `mesclar_logs.py`
os ordena por `horaParede` como desempate e **marca o par como arbitrário** - que é
a informação honesta, em vez de uma ordem total inventada. Com o Lamport, os
eventos 1 a 3 também saíam em alguma ordem, mas nada na saída dizia que essa ordem
não significava nada.

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

**[Sprint 1]** Qualquer pessoa poderia **forjar tokens válidos**: escolher qualquer
usuário, qualquer `exp` futura e, principalmente, o claim `servico: true` - que era o
que autorizava a chamada interna `creditar-remoto` entre agências. Um atacante com a
chave poderia operar qualquer conta e até **emitir créditos remotos**, movimentando
dinheiro entre agências a favor próprio, sem nunca passar pelo login. A assinatura
deixava de ser uma barreira.

**[Sprint 2]** O claim `servico: true` **deixou de existir**, junto com a rota
`creditar-remoto`. O impacto do vazamento mudou de natureza: hoje o atacante forja um
token de **usuário** comum e consegue operar contas da agência que o token endereça
(sacar, depositar, transferir), mas **não consegue mais forjar crédito remoto por
HTTP**, porque não há endpoint que aceite isso - o crédito só entra pelo consumidor
do RabbitMQ, e o publicador legitima a mensagem com as credenciais do broker, não
com o JWT. Ou seja: o vetor de ataque encolheu (perdeu-se a movimentação de dinheiro
entre agências via API forjada), e o que restou é o mesmo risco de autorização que
já está documentado em P1 (operar contas de terceiros). Em ambos os sprints vale a
mesma conclusão: o segredo vem de variável de ambiente (`JWT_SECRET`), não fica
fixo no código (deixo um valor default apenas para desenvolvimento), e deve ser
rotacionado se houver suspeita de vazamento.

**Decisão de design - formato das credenciais:** usuário + senha (JSON em
`POST /auth/login`), com um único usuário administrador definido por variáveis de
ambiente (`ADMIN_USUARIO`/`ADMIN_SENHA`, padrão `admin`/`icei123`). Escolhi esse modelo
por simplicidade: o sprint não pede cadastro/múltiplos usuários, e assim o login fica
testável de imediato. O token expira em 30 minutos (`JWT_EXP_MIN`), com `iat` e `exp` no
payload. Alternativa considerada (vincular login a número de conta) foi descartada porque
amarraria a autenticação à partição de contas.

**Decisão de design - [Sprint 1] chamada interna `creditar-remoto` (supersedida):**
a chamada agência-a-agência usava um **token de serviço** (`claim servico: true`),
assinado com a mesma chave, com **expiração curta (2 min)**, gerado pela própria
agência de origem na hora. A rota `creditar-remoto` exigia esse claim - tokens de
usuário eram rejeitados com 401 (testado). No Sprint 2 essa rota **não existe mais**,
porque não há chamada HTTP entre agências: o crédito chega pelo consumidor do
RabbitMQ. Com ela sumiram o token de serviço e o claim `servico: true`.

**Decisão de design - [Sprint 2] onde fica a fronteira de confiança agora.** Sem
HTTP entre agências, a autenticação da mensagem é responsabilidade do **broker**:
as agências se autenticam em `RABBITMQ_URL` (usuário/vhost do CloudAMQP) para
publicar e consumir, e o broker garante que só um processo com essas credenciais
publica em `iceibank.eventos`. Isso reposiciona o risco: não é mais "qualquer um
que forge um token interno", é "qualquer um que obtenha as credenciais do broker".
Três consequências que eu considerei:

1. **As agências passaram a ser mutually authenticated pelo broker**, o que é mais
   forte que o token de serviço em um aspecto (a credencial do broker pode ser
   revogada; um JWT forjado não) e mais fraco em outro (a credencial é de longo prazo,
   guardada em variável de ambiente, então exige mais cuidado de rotação).
2. **A autorização por agência é implícita na topologia**: cada agência consome
   apenas a sua fila, ligada por `agencia.<id>.creditar`, e publica na exchange de
   entrada. Não existe rota HTTP onde se possa pedir "crédito para a agência que não
   é a minha" - o que no Sprint 1 era barrado apenas pelo token.
3. **O `vetorEnvio` na mensagem não é autenticado pelo broker como conteúdo**: ele é
   carimbado pela origem e simplesmente confiado pela destino na fusão (regra 3). Isso é
   aceitável porque as três agências são o mesmo domínio de confiança, mas se algum
   dia existisse uma agência de outro domínio, o `vetorEnvio` passaria a precisar de
   assinatura própria - o broker garante quem **enviou**, não o **conteúdo** enviado.

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
  `RelogioVetorial`. Com FastAPI/Uvicorn e requisições concorrentes, o vetor é
  estado compartilhado entre a thread das requisições e a thread do consumidor do
  RabbitMQ - mesmo em single-worker, o lock evita condição de corrida na leitura,
  na fusão e na escrita (equivalente ao `synchronized` do exemplo Java).
- **O relógio zera no restart:** o vetor é estado em memória, então um reinício
  devolve todos os contadores a zero. Isso é coerente com as contas também estarem
  em memória, mas tem consequência prática: logs de execuções diferentes não podem
  ser comparados. O `mesclar_logs.py` avisa quando detecta isso.
- **Consumidor em thread daemon:** o consumo do RabbitMQ roda em thread separada da
  do Uvicorn, e o `stop_consuming()` no shutdown fecha a conexão para o processo não
  ficar preso. Sem `--reload`, que abriria um consumidor duplicado por fila.
- **Cuidados operacionais**: não usar `--reload`, e conferir `agencia/filas.py --alerta`
  antes de cada cenário - um processo de teste anterior ainda conectado consome a
  mensagem e o crédito aparece na agência errada.
- **Contas em memória** (`app.state.contas`, um dict): proposital, como o roteiro -
  se o processo reiniciar, as contas somem.
- **Logs:** `agencia/data/eventos-<agencia>.jsonl`, fora do Git (`.gitignore`).
  Evidências vão em `evidencias/`, não na pasta `data/`.
- **Escrita dos logs com `flush=True`:** os eventos precisam estar no arquivo antes
  que o processo possa morrer por falta de memória ou por um restart durante o
  teste; sem flush, os últimos eventos do cenário de resiliência sumiriam.

---

# Sprint 3 - Eleição de líder (Bully), app Flutter e offline-first

## [Sprint 3] Parte A (seção 5.5)

**Execução de referência.** As respostas abaixo usam a subida real das 3 agências
(`agencia\subir.ps1`, as três iniciadas no mesmo instante). Eventos de eleição
extraídos dos logs `agencia/data/eventos-agencia-*.jsonl`, em ordem de hora:

```
21:17:54.494 agencia-0 [1, 0, 0]   ELEICAO_INICIADA {'idAgencia': 0}
21:17:54.494 agencia-1 [0, 1, 0]   ELEICAO_INICIADA {'idAgencia': 1}
21:17:54.494 agencia-2 [0, 0, 1]   ELEICAO_INICIADA {'idAgencia': 2}
21:17:56.172 agencia-2 [0, 0, 2]   TORNOU_LIDER     {'idAgencia': 2}
21:17:56.461 agencia-1 [2, 3, 0]   ELEICAO_RECEBIDA {'de': 0, 'minhaId': 1}
21:17:56.749 agencia-2 [3, 0, 4]   ELEICAO_RECEBIDA {'de': 0, 'minhaId': 2}
21:17:56.751 agencia-2 [3, 0, 5]   ELEICAO_INICIADA {'idAgencia': 2}
21:17:56.999 agencia-2 [3, 0, 6]   TORNOU_LIDER     {'idAgencia': 2}
21:17:57.275 agencia-2 [3, 2, 8]   ELEICAO_RECEBIDA {'de': 1, 'minhaId': 2}
21:17:57.277 agencia-2 [3, 2, 9]   ELEICAO_INICIADA {'idAgencia': 2}
21:17:57.519 agencia-2 [3, 2, 10]  TORNOU_LIDER     {'idAgencia': 2}
21:17:58.071 agencia-1 [3, 4, 12]  LIDER_ANUNCIADO  {'liderId': 2, 'agencia': 1}
21:17:58.080 agencia-0 [4, 0, 7]   LIDER_ANUNCIADO  {'liderId': 2, 'agencia': 0}
21:17:58.082 agencia-0 [5, 2, 11]  LIDER_ANUNCIADO  {'liderId': 2, 'agencia': 0}
21:17:58.349 agencia-1 [3, 5, 13]  LIDER_ANUNCIADO  {'liderId': 2, 'agencia': 1}
21:17:58.352 agencia-1 [3, 6, 14]  LIDER_ANUNCIADO  {'liderId': 2, 'agencia': 1}
```

Resultado final (`testar.ps1 -Etapa lider`): as 3 agências no ar, todas com
`liderAtual = 2`.

**P1 - Por que o algoritmo de Bully sempre elege o processo de maior ID, e não o de
menor? O resultado seria diferente (mas ainda assim correto) se a regra fosse
invertida?**

"Maior ID" é uma **convenção**, não uma necessidade. O que o algoritmo precisa é de
um critério de desempate **total e conhecido por todos**: cada agência sabe o ID de
todas as outras (`config.AGENCIAS`), então, olhando só para quem está vivo, todas
chegam sozinhas à mesma conclusão sobre quem deve vencer. O nome "bully" (valentão)
vem justamente disso: o processo "mais forte" sempre toma a liderança dos menores.

Se a regra fosse invertida (vence o **menor** ID ativo), o algoritmo continuaria
correto, só que espelhado: a eleição seria enviada para os IDs menores, e quem não
ouvisse resposta de ninguém menor se declararia líder. Na nossa execução a líder
seria a agência 0 em vez da 2 - **resultado diferente, mas igualmente correto**,
porque continua havendo uma única líder com que todas concordam. O que quebraria o
algoritmo não é a direção da regra, e sim um critério que as agências pudessem
avaliar de forma diferente (por exemplo, "a que tiver menos carga agora", que muda
com o tempo e cada uma mede de um jeito). Em sistemas reais, o ID costuma codificar
uma prioridade (a máquina mais robusta recebe o maior ID), e o "maior vence" passa a
ter um significado prático.

**P2 - No passo 4 da tarefa, você deve ter visto mais de uma agência declarar
`TORNOU_LIDER` durante a subida, antes de convergir. Isso é um bug, ou um
comportamento esperado do algoritmo?**

É **comportamento esperado**. Na nossa execução, o que se repetiu não foram
agências diferentes se declarando líder, e sim a **mesma agência (2) se declarando
três vezes**. Pelo log acima:

1. As três agências subiram no mesmo milissegundo (`21:17:54.494`) e cada uma
   iniciou a própria eleição, como manda o `app.py` no startup.
2. A agência 2 não tem ninguém com ID maior: venceu sozinha
   (`TORNOU_LIDER [0, 0, 2]`).
3. Em seguida chegou a eleição que a agência 0 tinha mandado para ela
   (`ELEICAO_RECEBIDA de 0`). A regra 4 do Bully obriga quem recebe uma eleição a
   responder e iniciar a própria - então a 2 refez a eleição e se declarou de novo
   (`[3, 0, 6]`).
4. O mesmo aconteceu com a eleição da agência 1 (`ELEICAO_RECEBIDA de 1` ->
   `TORNOU_LIDER [3, 2, 10]`).

A agência 2 não sabe que "já é líder e todos sabem disso": cada eleição recebida
pode significar que alguém perdeu a líder de vista, então ela reafirma. Isso gera
anúncios repetidos (a agência 1 registrou 3 `LIDER_ANUNCIADO`, a agência 0
registrou 2 - um dos anúncios não foi registrado por ela, provavelmente por não ter
chegado dentro do timeout de 1 s), mas o conteúdo é sempre o mesmo, `liderId: 2`, e
a redundância até ajudou: mesmo com um anúncio a menos, a agência 0 convergiu.

As agências 0 e 1 **não** chegaram a se declarar líder nesta execução porque a 2 já
estava no ar quando elas perguntaram, e respondeu. Também se vê no log o efeito da
flag `eleicao_em_andamento`: a agência 1 recebeu a eleição da 0 (`21:17:56.461`)
enquanto a própria eleição ainda esperava resposta da 2, e por isso não abriu uma
segunda eleição em paralelo (não há `ELEICAO_INICIADA` dela logo depois).

Se as agências subissem em momentos diferentes (por exemplo, 0 e 1 primeiro e a 2
alguns segundos depois), veríamos o caso que o roteiro descreve: a agência 1 se
declararia líder, e a liderança mudaria de mãos quando a 2 subisse e iniciasse a
própria eleição. Isso também não seria bug: o Bully só garante que o resultado
**final** é o maior ID ativo; enquanto o conjunto de agências ativas ainda está
mudando, líderes provisórios são esperados. Seria bug se o sistema terminasse com
duas líderes diferentes, ou com uma líder que não fosse a de maior ID - o que não
aconteceu: o `testar.ps1 -Etapa lider` mostrou as três concordando com a 2.

**P3 - O endpoint `/bully/eleicao` não tem nenhuma autenticação. Qualquer processo
que descubra a URL de uma agência pode disparar uma eleição nela. Isso é um problema
de segurança real para este projeto? Por quê, ou por que não?**

**Neste projeto, hoje, o risco é baixo - mas a brecha é real e cresce no Sprint 4.**

Por que é baixo agora:

- As agências escutam só em `127.0.0.1` (o uvicorn mostra `Uvicorn running on
  http://127.0.0.1:4023`): de fora da máquina, ninguém alcança as rotas `/bully/*`.
  Quem consegue chamá-las já está dentro da máquina, onde poderia fazer coisa pior.
- Neste sprint a líder é **só informativa**: nenhuma operação bancária depende dela.
  Uma eleição forçada não move dinheiro nem altera saldo.
- Disparar uma eleição nem muda o resultado: ela sempre converge para o maior ID
  ativo. O efeito de um abuso de `/bully/eleicao` é tráfego extra (uma "tempestade"
  como a da subida a cada chamada), ou seja, um problema de negação de serviço, não
  de integridade.

Por que a brecha é real:

- O endpoint mais perigoso é o **`/bully/coordenador`**, que também não tem
  autenticação: `receber_coordenador` aceita qualquer `liderId` sem conferir nada.
  Um processo malicioso pode anunciar `liderId: 0` com as três agências vivas, e as
  agências passam a acreditar nisso - o heartbeat da Parte B só verifica se a líder
  **responde**, e a agência 0 responde, então a líder falsa se mantém.
- O campo `vetorEnvio` também é confiado sem validação: um vetor forjado como
  `[999, 999, 999]` é incorporado pelo `ao_receber` (fusão por `max`) e "infla" o
  relógio da agência para sempre, bagunçando a ordem causal dos logs.
- No **Sprint 4** a líder vai coordenar as transações distribuídas (2PC). Aí, quem
  conseguir eleger ou anunciar uma líder passa a decidir quem coordena commits de
  dinheiro - deixa de ser informativo.

Mitigações proporcionais ao projeto: manter as agências restritas a `127.0.0.1` /
rede interna; exigir um segredo compartilhado entre agências (um cabeçalho com token
de serviço, separado do JWT dos clientes) nas rotas `/bully/*`; e validar o conteúdo
das mensagens (rejeitar `liderId` que não esteja em `config.AGENCIAS` e vetores com
tamanho errado). Em produção, o padrão seria TLS mútuo (mTLS) entre os serviços.
Isso segue o mesmo raciocínio do domínio de confiança do consumidor do RabbitMQ
(Sprint 2): mensagens entre agências não carregam JWT porque vêm de dentro do
sistema, mas isso só é seguro enquanto o canal for de fato restrito às agências.

## [Sprint 3] Parte B (seção 6.4)

**Execução de referência.** Agências reiniciadas já com o heartbeat (intervalo de
3 s, timeout de 1 s) e com as URLs entre agências em `127.0.0.1` (ver "Notas do
Sprint 3"). Depois da convergência inicial para a agência 2, a janela da agência 2
foi fechada. Eventos do failover, extraídos dos `.jsonl`:

```
22:41:33.133 agencia-1 [4, 6, 14]   LIDER_ANUNCIADO     {'liderId': 2, 'agencia': 1}   <- estável
   ... janela da agência 2 fechada ...
22:42:35.724 agencia-1 [4, 7, 14]   LIDER_NAO_RESPONDEU {'liderAtual': 2, 'agencia': 1}
22:42:35.725 agencia-1 [4, 8, 14]   ELEICAO_INICIADA    {'idAgencia': 1}
22:42:36.721 agencia-0 [7, 2, 12]   LIDER_NAO_RESPONDEU {'liderAtual': 2, 'agencia': 0}
22:42:36.722 agencia-0 [8, 2, 12]   ELEICAO_INICIADA    {'idAgencia': 0}
22:42:37.011 agencia-1 [4, 10, 14]  TORNOU_LIDER        {'idAgencia': 1}
22:42:37.265 agencia-1 [9, 12, 14]  ELEICAO_RECEBIDA    {'de': 0, 'minhaId': 1}
22:42:37.266 agencia-1 [9, 13, 14]  ELEICAO_INICIADA    {'idAgencia': 1}
22:42:37.563 agencia-0 [11, 11, 14] LIDER_ANUNCIADO     {'liderId': 1, 'agencia': 0}
22:42:38.576 agencia-1 [9, 16, 14]  TORNOU_LIDER        {'idAgencia': 1}
22:42:38.864 agencia-0 [12, 17, 14] LIDER_ANUNCIADO     {'liderId': 1, 'agencia': 0}
```

Sem nenhuma intervenção manual, as duas agências restantes perceberam a queda,
elegeram a agência 1 (a de maior ID entre as vivas) e o `testar.ps1 -Etapa lider`
confirmou o consenso das duas na líder 1, com a 2 "fora do ar".

**P1 - O que aconteceria se o intervalo do heartbeat (`intervaloMs`) fosse muito
curto (ex.: 100ms)? E se fosse muito longo (ex.: 60 segundos)?**

O intervalo define o **tempo máximo para perceber a queda**. No pior caso, a líder
cai logo depois de uma verificação bem-sucedida, e a próxima só acontece um
intervalo depois - e ainda leva até o timeout (1 s) para concluir que ela não
respondeu. Com 3 s, isso dá no máximo uns 4 s de "cegueira", mais o tempo da
eleição. No log, as duas agências detectaram a queda com 1 s de diferença entre si
(`35.724` e `36.721`): cada uma tem o próprio ciclo de heartbeat, iniciado no
momento em que subiu, então elas não verificam em sincronia.

- **Muito curto (100 ms):** cada agência que não é líder faz 10 `GET /bully/lider`
  por segundo - com 3 agências, 20 requisições por segundo só de verificação, mais as
  linhas correspondentes no log de acesso de cada processo, sem nenhum ganho real
  (a líder não cai 10 vezes por segundo). Pior que o custo é a **sensibilidade**:
  com verificações tão frequentes, qualquer soluço momentâneo (uma pausa do processo,
  um pico de CPU, uma resposta mais lenta) vira "líder caiu" e dispara uma eleição
  desnecessária, que por sua vez gera a sua própria rajada de mensagens. O intervalo
  também ficaria menor que o timeout (1 s): no exemplo em Node, com `setInterval`,
  as verificações se acumulariam umas sobre as outras enquanto a anterior ainda
  espera resposta. Na minha implementação isso não ocorre, porque o loop
  (`_loop_heartbeat`) só agenda a próxima verificação depois que a atual termina -
  mas o intervalo efetivo passaria a ser ditado pelo timeout, não pelo parâmetro.
- **Muito longo (60 s):** a rede fica tranquila, mas o sistema pode passar **até um
  minuto** acreditando numa líder morta. Neste sprint isso só deixa o painel do app
  desatualizado; no Sprint 4, com a líder coordenando o 2PC, seria um minuto de
  transações entre agências paradas, esperando um coordenador que não existe mais.

O ponto de equilíbrio é um intervalo bem maior que a latência normal e que o
timeout (para não gerar falsos positivos), mas pequeno o bastante para que o tempo
de detecção seja aceitável para quem depende da líder. Os 3 s do roteiro ficam
nessa faixa para uma rede local.

**P2 - A agência que você derrubou e subiu de novo pode, dependendo do ID dela,
"tomar" a liderança de volta mesmo que a eleição atual estivesse funcionando bem.
Isso é desejável? Que problema prático isso pode causar em um sistema real?**

É exatamente o que o Bully faz por definição: ao subir, a agência 2 chama
`agendar_eleicao()` no startup (`app.py`), não encontra ninguém com ID maior, se
declara líder (`TORNOU_LIDER`) e anuncia isso às outras, que aceitam o anúncio sem
questionar (`receber_coordenador`). A liderança troca de mãos de novo (1 -> 2), mesmo
com a agência 1 liderando sem nenhum problema. Foi o que aconteceu ao religar a
agência 2 com `subir.ps1 -Agencias 2`, uns 6 minutos depois do failover:

```
22:49:13.216 agencia-2 [0, 0, 1]    ELEICAO_INICIADA {'idAgencia': 2}
22:49:13.576 agencia-2 [0, 0, 2]    TORNOU_LIDER     {'idAgencia': 2}
22:49:13.830 agencia-0 [13, 17, 14] LIDER_ANUNCIADO  {'liderId': 2, 'agencia': 0}
22:49:13.841 agencia-1 [9, 19, 14]  LIDER_ANUNCIADO  {'liderId': 2, 'agencia': 1}
```

Em menos de 1 s a agência 1 deixou de ser líder, sem ter falhado. O log também mostra
um efeito colateral do reinício: o relógio vetorial da agência 2 voltou a zero
(`[0, 0, 1]`), mas as outras já tinham visto a posição 2 chegar a 14. Pela fusão por
`max`, os novos eventos da agência 2 (posição 2 = 2, 3, 4...) ficam "escondidos"
atrás do 14 até ela ultrapassá-lo - o relógio não percebe que houve um processo novo.

**Na maioria dos casos isso não é desejável.** A troca não corrige nenhuma falha -
ela troca uma líder saudável por outra, só porque a nova tem ID maior. Problemas
práticos:

- **Troca no meio de uma operação.** No Sprint 4 a líder vai coordenar o 2PC. Se a
  troca acontecer depois que a líder antiga mandou o "prepare" e antes de mandar o
  "commit", as agências participantes ficam esperando uma decisão de um coordenador
  que deixou de ser líder, e a líder nova não sabe que aquela transação existe. O
  resultado é uma transação travada (ou, sem cuidado, decidida duas vezes).
- **Instabilidade em cascata.** Uma agência de ID alto que reinicia em loop (falha
  intermitente) provoca uma troca de liderança a cada vez que volta e outra a cada
  vez que cai - o sistema passa mais tempo trocando de líder do que trabalhando.
- **Custo de cada troca.** Cada eleição é uma rajada de mensagens e de eventos de
  log (no failover acima, a agência 1 chegou a se declarar líder duas vezes, uma para
  cada eleição iniciada).

Alternativas usadas na prática: ao subir, a agência **pergunta primeiro** se já existe
uma líder (`GET /bully/lider` em qualquer outra) e, se existir, entra como seguidora
em vez de iniciar uma eleição; ou o sistema usa **mandatos numerados** (como o
"term" do Raft), em que uma líder só é substituída quando falha, e não quando aparece
alguém "maior". A troca preemptiva só faz sentido quando o ID realmente representa
algo melhor (por exemplo, a máquina mais robusta), e mesmo assim de preferência num
momento sem operações em andamento.

**P3 - O `TIMEOUT_MS` de 1 segundo é usado tanto para detectar uma agência fora do ar
quanto para decidir se alguém respondeu a uma eleição. O que aconteceria se a rede
estivesse genuinamente lenta e isso ultrapassasse 1 segundo?**

O algoritmo **não consegue distinguir "lenta" de "morta"**: para ele, qualquer
resposta que demore mais de 1 s equivale a não ter resposta. Com uma líder viva,
porém lenta:

1. O heartbeat das outras agências estoura o timeout, registra
   `LIDER_NAO_RESPONDEU` e inicia uma eleição - um **falso positivo**.
2. A eleição envia `ELEICAO` para a líder lenta, que também não responde a tempo.
   Então uma agência de ID menor conclui que ninguém maior está vivo e se declara
   líder.
3. Mas a líder original continua achando que é a líder, porque ela **nunca
   verifica a si mesma** (`verificar_lider` retorna logo quando `lider_atual ==
   id_agencia`). Por um tempo há **duas agências se considerando líder** (o
   chamado *split-brain*).
4. A situação tende a se corrigir sozinha: a requisição de eleição que "estourou o
   timeout" do lado de quem enviou ainda chega à líder lenta, que a processa
   (`receber_eleicao`), refaz a própria eleição e se anuncia de novo. A liderança
   volta para ela - até o próximo atraso, que repete o ciclo. Numa rede
   persistentemente lenta, o resultado é uma liderança que fica oscilando.

Neste projeto vimos uma versão real disso. Na Parte A, com as URLs ainda em
`localhost`, a resolução do Windows tentava primeiro o IPv6 (`::1`), onde o uvicorn
não escuta, antes de cair no IPv4 - um atraso de quase 2 s, maior que o timeout. O
efeito apareceu nos logs: a agência 0 registrou só 2 dos 3 anúncios da líder, e o
`testar.ps1` (com `-TimeoutSec 2`) marcava agências vivas como fora do ar. Depois da
troca para `127.0.0.1`, na execução desta Parte B, as agências 0 e 1 registraram
os 3 anúncios cada uma, e nenhum `LIDER_NAO_RESPONDEU` apareceu enquanto as três
estavam no ar.

O que reduziria o problema: um timeout calibrado pela latência real da rede (e
configurável, em vez de fixo no código); exigir **várias falhas seguidas** antes de
declarar a líder morta, em vez de uma; e fazer a própria líder confirmar
periodicamente que ainda é reconhecida (ou usar mandatos numerados, como na P2),
para que uma líder "isolada" perceba que foi substituída.

## [Sprint 3] Parte C (seção 7.3)

**Execução de referência.** Saída de `python historico_lideranca.py` sobre os logs
das duas execuções feitas até aqui (a da Parte A e a da Parte B, com o failover e
a volta da agência 2). Horários em hora local:

```
=== Linha do tempo de lideres ===
A partir de 12/11 18:17:56.172: Agencia 2 e a lider   [lider inicial]
A partir de 12/11 18:17:56.999: Agencia 2 e a lider   [reafirmacao (ja era a lider)]
A partir de 12/11 18:17:57.519: Agencia 2 e a lider   [reafirmacao (ja era a lider)]
A partir de 12/11 19:41:31.572: Agencia 2 e a lider   [lider inicial]
A partir de 12/11 19:41:32.343: Agencia 2 e a lider   [reafirmacao (ja era a lider)]
A partir de 12/11 19:41:32.861: Agencia 2 e a lider   [reafirmacao (ja era a lider)]
A partir de 12/11 19:42:37.011: Agencia 1 e a lider   [TROCA 2 -> 1 (apos queda da lider 2)]
A partir de 12/11 19:42:38.576: Agencia 1 e a lider   [reafirmacao (ja era a lider)]
A partir de 12/11 19:49:13.576: Agencia 2 e a lider   [TROCA 1 -> 2 (agencia 2, de ID maior, voltou e tomou a lideranca)]

=== Resumo ===
Declaracoes de lideranca (TORNOU_LIDER): 9
  lider inicial (inicio de execucao):   2
  reafirmacoes (mesma agencia de novo):  5
  trocas efetivas de lider:              2
```

A linha do tempo reflete a sequência pedida: líder inicial (2) -> queda -> nova
líder (1) -> volta da 2, que retoma a liderança. O script do roteiro listaria as 9
linhas `TORNOU_LIDER` iguais umas às outras; a versão em Python classifica cada uma
(inicial, reafirmação ou troca), porque sem isso a pergunta abaixo não tem resposta
direta: 9 declarações não significam 9 trocas.

**P1 - Observando a saída do script, quantas vezes a liderança mudou de mãos durante
a "tempestade" de eleições da subida inicial (Parte A), antes de estabilizar? Isso
tem algum custo real para o sistema (rede, tempo), mesmo não afetando o resultado
final?**

**Nenhuma vez.** Nas duas subidas registradas (18:17 e 19:41), a agência 2 se
declarou líder três vezes - uma na própria eleição de startup e mais uma para cada
eleição que recebeu das agências 0 e 1 -, mas a liderança nunca saiu dela: são
**3 declarações, 0 trocas**. Isso aconteceu porque as três agências subiram ao mesmo
tempo pelo `subir.ps1`, e a 2 já estava no ar quando as menores perguntaram. Se as
agências subissem uma de cada vez, em ordem crescente de ID, aí sim a liderança
mudaria de mãos durante a subida (0 -> 1 -> 2).

**Mesmo sem trocas, a tempestade tem custo.** Contando os eventos da subida da
Parte B nos logs:

| | Na tempestade | Mínimo necessário |
|---|---|---|
| Eleições iniciadas (`ELEICAO_INICIADA`) | 5 (3 no startup + 2 repetidas pela agência 2) | 3 |
| Mensagens de eleição (`POST /bully/eleicao`) | 3 | 3 |
| Declarações (`TORNOU_LIDER`) | 3 | 1 |
| Anúncios de coordenador (`POST /bully/coordenador`) | 6 | 2 |
| Tempo até o último anúncio | ~2,2 s | - |

- **Rede:** 9 requisições HTTP para chegar a um resultado que 5 resolveriam - os 4
  anúncios extras dizem exatamente o que as agências já sabiam (`liderId: 2`). Com 3
  agências é pouco, mas o Bully troca, no pior caso, um número de mensagens que
  cresce com o **quadrado** do número de processos: cada agência pergunta a todas as
  maiores e cada reafirmação anuncia para todas as outras.
- **Tempo:** entre a subida (`19:41:30.951`) e o último anúncio (`19:41:33.133`)
  passaram ~2,2 s. Durante uma parte desse intervalo as agências 0 e 1 ainda não
  conheciam nenhuma líder (`liderAtual = null` até o primeiro anúncio chegar, ~0,9 s
  depois da subida). Neste sprint isso só significa um painel momentaneamente vazio;
  no Sprint 4, qualquer operação que precise da coordenadora teria de esperar a
  eleição terminar.
- **Tempo, no pior caso:** na Parte A, ainda com as URLs em `localhost`, a mesma
  tempestade levou ~3,9 s (`21:17:54.494` -> `21:17:58.352`) e um dos 6 anúncios não
  chegou - cada mensagem extra é mais uma chance de esbarrar no timeout.
- **Log e relógio:** cada mensagem gera eventos no `.jsonl` e avança o relógio
  vetorial (a agência 2 saiu da subida com a própria posição em 14, quase tudo
  só de eleições). Mais eventos significam logs maiores e mais ruído para quem lê a
  linha do tempo - foi justamente por isso que o script precisou classificar as
  declarações.

O resultado final não muda (o maior ID sempre vence), mas a tempestade mostra que o
Bully otimiza simplicidade e garantia de convergência, não economia de mensagens.
Uma forma simples de reduzir o custo seria a agência que já é líder responder a uma
eleição recebida apenas reenviando o anúncio para quem perguntou, em vez de refazer
a eleição inteira e anunciar para todas.

## [Sprint 3] Parte E (seção 9.6)

**Execução de referência.** `.\agencia\testar.ps1 -Etapa sincronizar` (conta 3 na
agência 0). Eventos registrados no `eventos-agencia-0.jsonl`:

```
13/11 11:51:51.427 agencia-0 [7, 2, 12] CRIAR_CONTA           {'id': 3, 'nomeAluno': 'Dani', 'saldoInicial': 100.0}
   ... app lê o saldo e guarda vetorAtual = [7, 2, 12] ...
13/11 11:51:51.500 agencia-0 [8, 2, 12] DEPOSITO              {'id': 3, 'valor': 50.0, 'novoSaldo': 150.0}
   ... app sincroniza SAQUE de 20 com vetorConhecido [7, 2, 12] -> HTTP 409
       (relacao ANTES, vetorAtual [8, 2, 12], contaAtual com saldo 150) ...
13/11 11:51:51.617 agencia-0 [9, 2, 12] SINCRONIZACAO_OFFLINE {'id': 3, 'tipo': 'SAQUE', 'valor': 20.0,
                                                              'novoSaldo': 130.0, 'vetorConhecido': [8, 2, 12]}
```

O 409 não gera evento (nada foi aplicado, o vetor não andou); o segundo envio, com
o `vetorAtual` devolvido no próprio 409, foi aceito e virou `[9, 2, 12]`.

**P1 - Por que a agência compara o vetor inteiro, e não só verifica se o saldo da
conta mudou? O que a comparação de vetores detecta que uma simples comparação de
saldo não detectaria?**

O saldo é um **resultado**; o vetor é o **histórico** que levou até ele. Comparar só
o saldo responde "o número é o mesmo?", e não "aconteceu alguma coisa desde que o
app olhou?" - e é a segunda pergunta que importa para decidir se é seguro aplicar
uma operação decidida com informação antiga. O que só o vetor detecta:

- **Mudanças que se anulam.** Se, enquanto o app está offline, entram um depósito de
  50 e um saque de 50, o saldo volta ao mesmo valor e a comparação de saldo diria
  "nada mudou". O vetor avançou duas vezes, e o conflito é detectado. Em sistemas
  distribuídos isso é o problema "ABA": o valor A virou B e voltou a A.
- **Mudanças vindas de outras agências.** Um crédito de transferência que chega pelo
  RabbitMQ passa pelo `ao_receber`, que funde o vetor da agência de origem. O vetor
  registra **de onde** veio a influência, não só que o número mudou.
- **A direção da diferença.** A comparação devolve `ANTES`, `DEPOIS` ou
  `CONCORRENTES`, e não só "diferente". `ANTES` (o caso do teste) é o normal: o app
  ficou para trás. `DEPOIS` significa que o app conhece um estado que a agência não
  tem mais - por exemplo, quando a agência reiniciou e o relógio voltou a zero.
  Comparando saldos, os dois casos seriam indistinguíveis.
- **Sem depender do valor que o app tinha.** Para comparar saldos, o app teria de
  mandar o saldo que viu e a agência teria de confiar nele. O vetor é um carimbo da
  própria agência: o app só devolve o que recebeu.

**P2 - Qualquer mudança no vetor da agência (mesmo em uma operação de outra conta) é
tratada como conflito. Explique por que essa simplificação existe e o que seria
necessário para tornar a detecção mais precisa, por conta.**

A simplificação existe porque **o relógio vetorial é da agência, não da conta**: há
uma única instância de `RelogioVetorial` por processo (`app.state.relogio`), e cada
posição conta eventos de uma agência inteira. A agência não tem como saber, olhando
só para `[7, 2, 12]` e `[8, 2, 12]`, se o evento que fez a posição 0 andar foi na
conta 3 ou em qualquer outra. Na dúvida, recusa - erra para o lado seguro.

O log de referência mostra que o problema é maior do que "operações de outras
contas": a conta 3 foi criada com o vetor `[7, 2, 12]`, ou seja, a agência 0 já
tinha avançado 6 vezes antes de qualquer operação bancária. Esses eventos são as
**mensagens do Bully** (eleições e anúncios de coordenador também passam por
`evento_local`, `ao_enviar` e `ao_receber`). Consequência prática: uma reeleição que
aconteça enquanto o app está offline - sem nenhum centavo mexido - também faz a
sincronização ser recusada. Numa agência com muitas contas e movimento, quase toda
operação offline daria conflito.

Para tornar a detecção precisa por conta:

1. **Uma versão por conta.** Guardar na própria `Conta` um contador (ou um vetor de
   versão, com uma posição por agência) que só avança quando **aquela conta** muda -
   inclusive pelos créditos remotos que chegam pelo RabbitMQ. O `GET /contas/{id}`
   devolveria essa versão, e o `/sincronizar` compararia só ela. Operações em outras
   contas e mensagens do Bully deixariam de causar conflito.
2. **Separar o relógio do consenso do relógio do banco**, se o vetor da agência
   continuar sendo usado: as mensagens de eleição não deveriam contar como eventos
   que invalidam operações bancárias.
3. **Identificar a "vida" do processo.** O relógio zera quando a agência reinicia, e
   os vetores se repetem entre execuções (no log, a conta 0 da execução das 21:49
   também foi criada em `[7, 2, 12]`, o mesmo vetor da conta 3 de manhã). Um vetor
   antigo guardado pelo app poderia, por coincidência, ser **igual** ao vetor atual
   de uma execução nova, e a operação seria aceita como se nada tivesse mudado. Um
   identificador de execução (gerado na subida) enviado junto com o vetor fecha essa
   brecha. Hoje ela é contida por outro motivo - as contas também somem no reinício,
   então a sincronização tende a cair em 404 - mas deixaria de ser se as contas
   passassem a ser persistentes.

**P3 - Quando a sincronização é recusada (409), a agência devolve o estado atual da
conta. O que o app deveria fazer com essa informação - descartar a operação pendente,
tentar de novo automaticamente, ou perguntar à pessoa usuária?**

**Depende do tipo de operação - e para saque, perguntar à pessoa usuária.** Esta é a
decisão de design que a Parte F implementa:

- **Descartar em silêncio: não.** É dinheiro. A pessoa registrou uma operação e viu
  um saldo provisório na tela; sumir com ela sem avisar é o pior resultado possível
  num app bancário.
- **Repetir automaticamente com o vetor novo: não para saque.** Reenviar com o
  `vetorAtual` do 409 sempre "funciona" (o teste da Parte E mostrou isso), mas é
  exatamente aplicar às cegas - só que com um passo a mais. Um saque é decidido com
  base no saldo que a pessoa viu; se o saldo mudou (no teste, de 100 para 150; poderia
  ter caído para 10), a decisão pode não fazer mais sentido.
- **Depósito é diferente.** Um depósito não depende do saldo anterior (somar 50 dá o
  mesmo efeito em qualquer ordem) e não pode falhar por saldo insuficiente. Para ele,
  uma nova tentativa automática com o `vetorAtual` devolvido é segura, e a tela só
  informa que ela aconteceu.

Comportamento planejado para o app, em caso de 409: a operação pendente fica marcada
como **"em conflito"** (não some da fila), o app substitui o saldo provisório pelo
`contaAtual.saldo` real devolvido pela agência, e mostra um aviso com as duas ações -
**"Aplicar mesmo assim"** (reenvia com o `vetorAtual` do 409) e **"Descartar"**. Assim
quem decide o que fazer com o dinheiro é a pessoa, com o saldo verdadeiro na frente.

Um detalhe que já foi preparado no backend para isso: a resposta de **sucesso** do
`/sincronizar` também devolve o `vetorAtual`. Se a fila tiver duas operações
offline, as duas foram guardadas com o mesmo vetor; depois que a primeira é aplicada,
o vetor avança por causa dela mesma, e a segunda daria um conflito "falso". Com o
vetor devolvido no sucesso, o app atualiza a próxima operação da fila antes de
enviá-la.

## [Sprint 3] Notas de implementação

- **Bully em asyncio, sem lock:** as rotas `/bully/*` são `async def` e as eleições e
  o heartbeat são tarefas asyncio no event loop do uvicorn. Assim `lider_atual` só é
  alterado por uma thread e dispensa o `threading.Lock` sugerido no roteiro para
  Python. O relógio vetorial, compartilhado com a thread do consumidor do RabbitMQ,
  continua com a lock própria.
- **A rota `/bully/eleicao` responde antes da eleição terminar:** a própria eleição
  da agência é disparada em segundo plano (`agendar_eleicao`). Se a rota esperasse,
  ela consultaria as agências maiores e a resposta passaria de 1 s, e quem perguntou
  acharia que esta agência caiu.
- **Heartbeat sem sobreposição:** diferente do `setInterval` do exemplo em Node, o
  loop só agenda a próxima verificação depois que a atual termina, e um erro numa
  verificação não encerra o heartbeat.
- **URLs entre agências em `127.0.0.1`:** ver P3 da Parte B. O frontend continua
  usando `localhost`, porque o navegador não tem o timeout curto do Bully.
- **Sincronização atômica (`RelogioVetorial.executar_se_atual`):** no exemplo em
  Node, comparar os vetores e depois aplicar a operação é seguro porque há uma única
  thread. Aqui as rotas `def` rodam numa pool de threads e o consumidor do RabbitMQ
  em outra; entre a comparação e a aplicação, outro depósito poderia avançar o vetor.
  A comparação, a operação e o incremento acontecem dentro da mesma lock do relógio,
  pela qual todo evento da agência passa. Validado com 200 sincronizações
  simultâneas usando o mesmo vetor: exatamente 1 foi aplicada.
- **409 montado sem `HTTPException`:** o tratador de erros do `app.py` embrulharia o
  corpo em `{"erro": {...}}`; o app precisa de `vetorAtual` e `contaAtual` no nível
  de cima do JSON.
- **`agencia/subir.ps1`:** abre uma janela por agência (logs separados para as
  evidências, e derrubar uma agência é fechar a janela). A URL do RabbitMQ fica em
  `agencia/.env`, fora do Git.
