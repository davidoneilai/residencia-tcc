# Piloto BFCL v4 Non-Live: critério de decisão (pré-registrado)

Escrito em 2026-11-05, com o piloto já rodando no iPhone e **antes** de qualquer resultado dele.
Só o smoke de 2 tarefas (`results/bfcl-nonlive/smoke-qwen35.json`) foi visto, para validar o pipeline.

## Configurações

| Nome no estudo | Estratégia no app | O que faz |
|---|---|---|
| **Direct** | `nothink` | Thinking desligado (`enable_thinking=false`), teto de 1024 tokens |
| **Reasoning** | `direct` | Thinking completo do modelo, mesmo teto de 1024 tokens |
| **Adaptive** | a definir no DEV | Regra leve, antes da geração, que escolhe Direct ou Reasoning |

Reasoning é o maior orçamento de raciocínio já implementado. No estudo SLM × AST, Budget64 e Plan+Act
ficaram abaixo dele em acerto no Qwen3.5. Os nomes do app não mudam: o mapeamento acima vale para todo o relatório.

## Piloto

- Qwen3.5-2B-4bit (MLX), iPhone 16 Pro, greedy, 1 repetição, ordem embaralhada (seed `20261105`).
- 40 tarefas `pilot` de `selection.json` (8 × simple_python, multiple, parallel, parallel_multiple, irrelevance).
- Scorer: `ast_checker` oficial do `bfcl-eval` 2026.3.23. Em irrelevance, acerto é não chamar função, como no runner oficial.

## Critérios (D = Direct, R = Reasoning)

- **C1, complementaridade nos dois sentidos:** pelo menos 2 tarefas em que só D acerta **e** pelo menos 2 em que só R acerta.
- **C2, folga de acerto:** acerto do oracle por tarefa (D ou R) menos o da melhor fixa ≥ 2 tarefas (5 pp).
- **C3, folga de latência:** o oracle de custo (D quando D acerta, senão R) tem o acerto do oracle e
  latência média ≥ 20 % menor que a de R.
- **C4, capturável por regra leve:** dentro da família fixa abaixo, a melhor regra no piloto recupera
  ≥ 50 % do ganho do oracle sobre a melhor fixa em acerto, **ou** fica a no máximo 1 tarefa do acerto de R
  com latência ≥ 20 % menor. Reporto o valor no próprio piloto (otimista) e em leave-one-out.

Família de regras (todas usam só o pedido e os schemas, antes de gerar):

1. Fixas: sempre D; sempre R.
2. `ASTRouter` existente: funções ≥ 2 ou pista de pedido múltiplo → R; senão D.
3. Funções ≥ 2 → R (e o inverso).
4. Pista de pedido múltiplo (`ASTRouter.multiCues`) → R (e o inverso).
5. Tamanho do pedido (caracteres) ≥ t → R (e o inverso), com t nos quantis do piloto.
6. Total de parâmetros nos schemas ≥ t → R (e o inverso), com t nos quantis do piloto.

## Decisão

- **Prosseguir com Adaptive:** (C2 ou C3) **e** C4.
- **Não prosseguir:** caso contrário. Se C2 ou C3 valem e C4 falha, o relatório diz que existe
  complementaridade, mas que ela não é previsível por características leves da tarefa.

### Emenda (2026-11-05, ainda sem resultado do piloto)

Testando o script no smoke, "sempre Direct" passava no C4 sempre que a Direct empatava com a Reasoning.
Isso é uma fixa, não uma Adaptive. Por isso:

- **C3** exige também acerto de R > acerto de D. Se D acerta tanto quanto R, D domina e não há o que adaptar.
- **C4** só conta regras que mandam pelo menos uma tarefa para cada estratégia. A variante de latência
  exige também acerto > D. O leave-one-out escolhe dentro da mesma família restrita.

Com n = 40, diferenças menores que ~10 pp não se distinguem. O piloto decide se vale gastar o TESTE (160),
não se a Adaptive é melhor.

## Etapa 2: DEV de 80 e congelamento (escrito em 2026-11-05, com o `dev_prior` rodando e sem resultado dele)

DEV = `pilot` (40) + `dev_prior` (40), ambos executados com o mesmo build (Direct e Reasoning, Qwen3.5-2B).
Os dados antigos de `results/slm-bfcl/main-r1` **não** entram: o loader do Qwen3.5 era outro.

- Mesma família de regras do piloto; os limiares são os quantis 25/50/75 % das 80 tarefas.
- Só contam regras que mandam pelo menos uma tarefa para cada estratégia. Escolha: maior acerto; empate → menor latência média.
- **Portão.** A regra escolhida precisa ter acerto ≥ melhor fixa **e** (acerto > melhor fixa **ou**
  latência média ≥ 10 % menor que a da melhor fixa em acerto). Além disso, o leave-one-out nas 80
  precisa ficar a no máximo 1 tarefa da melhor fixa.
- Se o portão falhar: não rodo o TESTE. Conclusão: a escolha antes da geração não compensa no Non-Live.
- Se passar: a regra é escrita no app (estratégia própria), conferida contra o Python nas 240 tarefas e congelada
  antes de qualquer execução no TESTE.

## Etapa 3: TESTE (160), hipóteses fixadas agora

Direct, Reasoning e Adaptive (executada no iPhone, não simulada), mesma sessão, ordem embaralhada (seed `20261105`).

- **H1, não inferioridade:** acerto(Adaptive) − acerto(Reasoning) > −5 pp, pelo limite inferior do IC95 bootstrap pareado.
- **H2, latência:** latência média(Adaptive) < latência média(Reasoning), com o IC95 bootstrap pareado da diferença abaixo de 0.
- Secundárias, descritivas: Adaptive × Direct; resultados por categoria; 1ª chamada; tokens; custo da decisão.

---

# Estudo B: orçamento de raciocínio (escrito em 2026-11-05, antes de qualquer execução com teto no Non-Live)

Pergunta: dá para manter o acerto da Reasoning gastando menos, cortando o raciocínio longo?
Motivação, só com dados do DEV:
- a mediana do raciocínio é 124 tokens e o p90 é 367;
- as 13 tarefas acima de 256 tokens custam 45 s em média;
- 5 execuções pensam até o teto de 1024.

## Configurações

| Nome | Estratégia no app | O que faz |
|---|---|---|
| Reasoning | `direct` | Thinking completo, teto total de 1024 tokens (âncora) |
| Budget-b | `budget_<b>` | Pensa até b tokens. Se não fechou, o app fecha `</think>` e força a resposta (s1) |

- b ∈ {128, 256, 512}. Os tokens de resposta ficam limitados a 1024 − pensados, o mesmo teto total da Reasoning.
- 64 fica de fora: 71 das 80 tarefas do DEV passam disso.

## Métrica de custo

- **Primária:** tokens de saída por tarefa. São determinísticos (greedy) e não dependem da térmica.
- **Secundária:** latência, medida em blocos curtos com pausa de resfriamento.

Lição do TESTE: uma sessão longa teve throttling de 32 → 13 tok/s.

## DEV (80 = pilot + dev_prior)

- 80 tarefas × {Reasoning, Budget-128, Budget-256, Budget-512}, em 4 blocos de 20 tarefas.
- Cada bloco é uma sessão (80 execuções, ordem embaralhada, seed `20261105`), com 10 min de pausa entre blocos.
- **Escolha de b\*:** o menor b com acerto ≥ acerto da Reasoning − 1 (no mesmo DEV) **e** tokens médios ≤ 90 % dos da Reasoning.
- Se nenhum b passar, **não rodo o TESTE-2**. O relatório diz que o orçamento fixo não economiza sem perder acerto.

## TESTE-2 (160 tarefas novas, congeladas agora em `selection-test2.json`)

- 160 × {Reasoning, Budget-b\*}, em 4 blocos de 40 tarefas (80 execuções cada), com 10 min de pausa entre blocos.
- **H1, não inferioridade:** acerto(b\*) − acerto(Reasoning) > −5 pp, pelo limite inferior do IC95 bootstrap pareado.
- **H2, custo:** tokens(b\*) − tokens(Reasoning) < 0, pelo limite superior do IC95 bootstrap pareado.
- **H3, secundária:** latência(b\*) − latência(Reasoning) < 0, pelo mesmo critério.
- Descritivas: por categoria; tarefas resgatadas (Reasoning errou e b\* acertou) e perdidas; irrelevance em separado.
