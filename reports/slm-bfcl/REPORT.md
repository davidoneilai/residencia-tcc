# SLMs no iPhone 16 Pro: BFCL v4 AST

Um número por célula: acerto no checker oficial, 40 tarefas, greedy, iPhone 16 Pro quente e no cabo. Detalhe (ICs, falhas, tokens) em `tables-r1.md`.

## O que medimos

O BFCL AST pede **uma** resposta: o modelo emite a chamada de função certa, ou se recusa a chamar quando o pedido é irrelevante. Não há app, não há tool de verdade, não há segundo turno.

Por isso este estudo responde três perguntas, e só essas:

1. Qual SLM + política **fixa** acerta mais, e a que custo de tempo?
2. Dá para **acelerar** essa política sem perder acerto?
3. Uma política **adaptativa** (escolhe a fixa por tarefa) supera a melhor fixa?

Não responde se o modelo usa o Clock certo, nem se recupera de tool que mente. Isso é o iOSWorld.

## O que cada nome é

**Fixas** — a regra não muda no meio da tarefa:

| Nome | O que o iPhone faz |
|---|---|
| Direct | Pensa (thinking ligado), depois chama a função |
| NoThink | Não pensa; vai direto à chamada |
| Budget64 | Pensa no máximo 64 tokens, corta, responde |
| Plan+Act | Escreve um plano (128 tokens) e só então chama |
| Speculative | Direct, com um modelo menor tentando adivinhar os tokens |
| Prefix cache | Reusa o KV do prefixo comum. No AST **não existe** prefixo comum |

**Adaptativas** — escolhem uma das fixas:

| Nome | Como escolhe |
|---|---|
| Roteador AST | Olha o enunciado: pedido múltiplo → Direct; senão a política rápida |
| AdaptiveStep | Na 1ª (e única) rodada: enunciado “simples” → NoThink; senão Budget64 |
| ActionAware | Só faz sentido com tool executada. **Não rodamos** no AST |

## O que de fato rodou

| | Qwen3.5-2B | MiniCPM5-2B | LFM2.5-2.6B | Gemma 4 E2B |
|---|---|---|---|---|
| Direct, Budget64, Plan+Act | sim | sim | sim | sim |
| NoThink | sim | sim | **não** (o modelo sempre pensa) | sim |
| Roteador AST | sim | sim | sim | sim |
| AdaptiveStep | sim | sim | **não** (precisa de NoThink) | sim |
| Speculative | **não** (`MambaCache`) | sim, 30/10 | **não** (`MambaCache`) | **não** (drafter MTP) |
| Prefix cache | **não** — sem prefixo comum no AST | idem | idem | idem |
| ActionAware | **não** — AST não executa tool | idem | idem | idem |

Estudo principal: 22 células × 40 = **880** execuções (27–28/10). Speculative: +40 no MiniCPM5 (30/10), com Direct intercalado na mesma sessão.

## 1. Melhor política fixa de cada modelo

| Modelo | Melhor fixa | Acerto | Tempo médio |
|---|---|---|---|
| Qwen3.5-2B | Direct | **35/40 (88%)** | 21 s |
| MiniCPM5-2B | **NoThink** | **34/40 (85%)** | **7,5 s** |
| LFM2.5-2.6B | Direct | 33/40 (82%) | 16 s |
| Gemma 4 E2B | **NoThink** | 31/40 (78%) | 14 s |

A melhor aceleração **não é a mesma** nos quatro. MiniCPM5 e Gemma 4 acertam mais **sem** pensar. Qwen3.5 acerta mais **pensando**; desligar o thinking tira 8 tarefas (35 → 27).

No custo-benefício, MiniCPM5 + NoThink é o ponto: 1 tarefa a menos que o Qwen Direct, 2,8× mais rápido. Com n = 40, 1 tarefa não distingue os dois.

## 2. Acelerar ajuda? Depende do modelo

Comparado à Direct do mesmo modelo (pareado por tarefa):

| Modelo | NoThink | Budget64 | Plan+Act |
|---|---|---|---|
| MiniCPM5 | **+3 acertos, −35 s** | −2 acertos, −27 s | +2 acertos, **+6 s** (mais lento) |
| Gemma 4 | **+3 acertos, −24 s** | −3 acertos, −13 s | −3 acertos, +8 s |
| Qwen3.5 | **−8 acertos**, −3 s | −5 acertos, −5 s | −7 acertos, +9 s |
| LFM2.5 | n/a | −4 acertos, −4 s | **−13 acertos**, +23 s |

Plan+Act é a pior ideia deste recorte: mais lenta em todos, e só o MiniCPM5 não piora o acerto.

Speculative no MiniCPM5 (rascunho 1B, 68% dos tokens aceitos): 32/40 vs 31/40 do Direct **na mesma sessão**, +2,3 s (IC95% [−1,1; +5,4]). Não acelera. Não copia o Direct (7/40 textos iguais). Não compete com NoThink (34/40 em 7,5 s).

## 3. As adaptativas não ganharam. O AdaptiveStep no MiniCPM5 não é exceção.

| Modelo | Melhor fixa | AdaptiveStep | Roteador AST |
|---|---|---|---|
| MiniCPM5 | NoThink **34/40 · 7,5 s** | **34/40 · 8,7 s** | 31/40 · 30 s |
| Gemma 4 | NoThink **31/40 · 14 s** | **31/40 · 18 s** | 29/40 · 30 s |
| Qwen3.5 | Direct **35/40 · 21 s** | 27/40 · 17 s | 33/40 · 18 s |
| LFM2.5 | Direct **33/40 · 16 s** | n/a | 33/40 · **13 s** |

O AdaptiveStep no MiniCPM5 **empatou** com o NoThink em acerto. Não superou. Tarefa a tarefa, os 40 vereditos são **idênticos** aos do NoThink (Gemma 4 também, 40/40). No Qwen3.5, 38/40 vereditos idênticos ao NoThink — e o NoThink é a pior fixa dele.

Por quê: no AST só existe a rodada 0. O AdaptiveStep então faz:

- 35/40 tarefas → `fast` = **NoThink**
- 5/40 tarefas → `slow` = Budget64, porque o enunciado disparou um detector de “contato / sequência” escrito para o piloto Apple, não para o BFCL

Nos três modelos ele toma **as mesmas 35+5 decisões**, porque só olha o texto do pedido. No MiniCPM5, NoThink já era o ótimo: copiá-lo 35 vezes e gastar Budget64 em 5 não muda nenhum acerto e adiciona 1,2 s. No Qwen3.5, copiar NoThink 35 vezes **é** perder 20 pp.

O roteador AST é a única adaptativa que muda o tempo sem piorar o acerto: LFM2.5, 33/40 iguais ao Direct, **−2,8 s** (IC95% [−5,0; −1,0]). Ele manda 11 tarefas para Budget64. Nos outros modelos a mesma regra piora, porque a “rápida” (NoThink) não é a melhor.

**Conclusão desta pergunta:** no AST de turno único não há o que adaptar. A adaptativa boa neste recorte é uma constante por modelo (“NoThink, salvo no Qwen3.5 e no LFM”).

## 4. Como melhorar a adaptativa (não neste benchmark)

O teto, se um oráculo escolhesse a melhor fixa **depois** de ver o gabarito: +1 a +4 tarefas por modelo. Isso cabe no ruído de n = 40. Treinar um roteador no AST é prematuro.

O que o AdaptiveStep errou, e o que troca:

1. **O modo rápido não pode ser NoThink para todo mundo.** Tem de ser a melhor fixa daquele SLM (Direct no Qwen3.5 e no LFM; NoThink no MiniCPM5 e no Gemma 4). No MiniCPM5 isso já era verdade por coincidência; no Qwen3.5 era o oposto.
2. **Não escolher “slow” pelo enunciado de outro domínio.** Os 5 Budget64 vieram de pistas de contato/sequência do piloto Apple. No BFCL isso é ruído. No iOSWorld, o sinal tem de ser da trajetória: tool com warning, UI igual, mesma chamada duas vezes.
3. **Testar onde existe trajetória.** ActionAware e AdaptiveStep só podem ganhar com tool executada e vários turnos. Isso é o iOSWorld, não o AST.

A política A para o iOSWorld, congelada **antes** das tarefas de teste: parte da melhor fixa daquele modelo; só gasta Direct/Budget extra quando a própria trajetória pede. Uma A para os quatro SLMs, não uma A por modelo.

## Protocolo (curto)

- Amostra: 8 IDs × 5 categorias, seed 20261027, sem os 40 IDs de testes anteriores. `selection.json`.
- Turno único, template nativo, sem system prompt do harness, sem executar a função. Teto 1024 tokens.
- MiniCPM5 e LFM2.5: o Mac lê o formato nativo de tools (o pacote MLX não tem parser).
- Térmica `serious` em 880/880 e nas 80 do speculative. Latência = aparelho quente.
- Checker: `bfcl-eval` 2026.3.23. Sessões: `results/slm-bfcl/main-r1-*.json`, `spec-r1-minicpm5.json`.
- n = 40: diferenças < ~10 pp não se distinguem.

## Reprodutibilidade

`analysis/slm_bfcl/run_sessions.sh`, `device.sh`, `evaluate.py` → `main-r1-graded.jsonl`. Tabelas: `python3 analysis/slm_bfcl/analyze.py results/slm-bfcl/main-r1-graded.jsonl`.
