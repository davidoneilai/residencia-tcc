# Roteamento adaptativo de inferência — relatório experimental

## Pergunta

Um roteador leve, usando só características da solicitação, consegue reduzir a latência total de tarefas agênticas em LLMs mobile mantendo qualidade comparável à melhor política fixa?

## Dados

- Fonte: `results/cross-model-2026-10-13.json` (sessão completa, protocolo 2.0).
- 360 execuções = 3 modelos × 2 estratégias (`direct`, `plan_act`) × 60 tarefas Apple residency (`apple_residency_60`).
- Modo simulado; 1 repetição por condição — análise exploratória quanto à variância.
- Políticas de thinking (`nothink`, budgets, `early_exit`) só existem no Qwen e não foram medidas neste conjunto de 60; o legado de 13 tarefas não entra no teste principal para não misturar populações.

## Metodologia

1. **Oracle (Experimento A):** para cada tarefa, escolhe a política correta de menor latência. Limite superior idealizado.
2. **Split:** famílias de template (`apple_{cat}_b{k}`, grupos de 5 IDs) vão inteiras para train/val/test — sem vazamento entre variantes do mesmo molde.
3. **Baseline fixa:** melhor política no *train* (sucesso, depois latência).
4. **Heurística:** regras sobre cues sequenciais, ambiguidade e tamanho.
5. **Aprendido:** regressão logística ou árvore rasa (prof. ≤ 3), escolhida na validação; rótulo = escolha do oracle no train.
6. **Features:** só texto da solicitação + catálogo de cues de ferramentas (sem expected answers, grades ou latências futuras).
7. Overhead do roteador somado à latência final.

## Resultados no teste (generalização)

### qwen

- Tarefas: 60; split {'train': 25, 'val': 15, 'test': 20}; fixed escolhida no train: `direct`; learned: `logistic`.
- Overhead médio de features: 0.0116 ms.
- Famílias teste: `apple_amb_b0, apple_multi_b2, apple_seq_b0, apple_single_b2`.

#### Hold-out (teste)

| Método | Sucesso | Latência total (ms) | Latência média (ms) | Overhead router (ms) |
| --- | ---: | ---: | ---: | ---: |
| fixed:direct | 0.300 | 776312 | 38816 | 0.516 |
| heuristic | 0.300 | 764540 | 38227 | 0.508 |
| logistic | 0.350 | 694532 | 34727 | 0.526 |
| oracle | 0.350 | 572806 | 28640 | 0.232 |

#### Leave-one-family-out (mais estável, n=60)

| Método | Sucesso | Latência total (ms) | Latência média (ms) |
| --- | ---: | ---: | ---: |
| fixed | 0.400 | 3902748 | 65046 |
| heuristic | 0.400 | 2182836 | 36381 |
| learned | 0.417 | 2114814 | 35247 |
| oracle | 0.483 | 1807454 | 30124 |

Oracle no conjunto completo (limite A): sucesso 0.483, latência total 1807454 ms. Economia potencial vs fixed `direct`: 2095293 ms (53.7%).

No Qwen (LOFO), heurística corta latência em 44.1% com sucesso igual (0.400). Learned: 0.417 sucesso, 45.8% menos latência.

Complementaridade `direct`/`plan_act`: only_direct=9, only_plan=5, both=15, neither=31.

Por categoria no teste (roteador aprendido):

| Categoria | n | Sucesso | Latência média (ms) |
| --- | ---: | ---: | ---: |
| ambiguous | 5 | 0.800 | 19977 |
| multi_tool | 5 | 0.000 | 56133 |
| sequential | 5 | 0.000 | 33194 |
| single_tool | 5 | 0.600 | 29603 |

### gemma

- Tarefas: 60; split {'train': 25, 'val': 15, 'test': 20}; fixed escolhida no train: `direct`; learned: `logistic`.
- Overhead médio de features: 0.0111 ms.
- Famílias teste: `apple_amb_b0, apple_multi_b2, apple_seq_b0, apple_single_b2`.

#### Hold-out (teste)

| Método | Sucesso | Latência total (ms) | Latência média (ms) | Overhead router (ms) |
| --- | ---: | ---: | ---: | ---: |
| fixed:direct | 0.500 | 183886 | 9194 | 0.520 |
| heuristic | 0.500 | 183886 | 9194 | 0.497 |
| logistic | 0.500 | 183886 | 9194 | 0.563 |
| oracle | 0.500 | 183678 | 9184 | 0.221 |

#### Leave-one-family-out (mais estável, n=60)

| Método | Sucesso | Latência total (ms) | Latência média (ms) |
| --- | ---: | ---: | ---: |
| fixed | 0.633 | 604802 | 10080 |
| heuristic | 0.633 | 604802 | 10080 |
| learned | 0.600 | 630108 | 10502 |
| oracle | 0.667 | 612997 | 10217 |

Oracle no conjunto completo (limite A): sucesso 0.667, latência total 612997 ms. Economia potencial vs fixed `direct`: -8196 ms (-1.4%).

Complementaridade `direct`/`plan_act`: only_direct=10, only_plan=2, both=28, neither=20.

Por categoria no teste (roteador aprendido):

| Categoria | n | Sucesso | Latência média (ms) |
| --- | ---: | ---: | ---: |
| ambiguous | 5 | 0.600 | 6057 |
| multi_tool | 5 | 0.000 | 10031 |
| sequential | 5 | 1.000 | 12436 |
| single_tool | 5 | 0.400 | 8254 |

### apple

- Tarefas: 60; split {'train': 25, 'val': 15, 'test': 20}; fixed escolhida no train: `direct`; learned: `logistic`.
- Overhead médio de features: 0.0110 ms.
- Famílias teste: `apple_amb_b0, apple_multi_b2, apple_seq_b0, apple_single_b2`.

#### Hold-out (teste)

| Método | Sucesso | Latência total (ms) | Latência média (ms) | Overhead router (ms) |
| --- | ---: | ---: | ---: | ---: |
| fixed:direct | 0.700 | 104961 | 5248 | 0.515 |
| heuristic | 0.700 | 104961 | 5248 | 0.549 |
| logistic | 0.600 | 112309 | 5615 | 0.523 |
| oracle | 0.700 | 101680 | 5084 | 0.220 |

#### Leave-one-family-out (mais estável, n=60)

| Método | Sucesso | Latência total (ms) | Latência média (ms) |
| --- | ---: | ---: | ---: |
| fixed | 0.817 | 306678 | 5111 |
| heuristic | 0.817 | 306677 | 5111 |
| learned | 0.733 | 329666 | 5494 |
| oracle | 0.817 | 301226 | 5020 |

Oracle no conjunto completo (limite A): sucesso 0.817, latência total 301226 ms. Economia potencial vs fixed `direct`: 5450 ms (1.8%).

Complementaridade `direct`/`plan_act`: only_direct=27, only_plan=0, both=22, neither=11.

Por categoria no teste (roteador aprendido):

| Categoria | n | Sucesso | Latência média (ms) |
| --- | ---: | ---: | ---: |
| ambiguous | 5 | 0.600 | 4486 |
| multi_tool | 5 | 0.200 | 6540 |
| sequential | 5 | 1.000 | 4931 |
| single_tool | 5 | 0.600 | 6504 |

## Resposta à pergunta principal

**Sim, no Qwen (LOFO):** o roteador `learned` manteve sucesso 0.417 vs 0.400 da política fixa e reduziu latência total de 3902748 para 2114814 ms (oracle 1807454 ms). Hold-out: fixed=0.3.

## Limitações

- Uma execução por condição: não estima variância entre runs.
- Router offline sobre logs: não reexecuta o LLM; mede overhead de decisão localmente.
- Apple/Gemma têm pouca complementaridade; o ganho potencial concentra-se no Qwen.
- Experimento C (roteamento mid-trajectory) não implementado para preservar o foco A/B.
- Avaliação principal é *replay* offline dos logs; a latência do LLM não foi remedida.
- iPhone indisponível nesta sessão para instalar o binário; app compila (`BUILD SUCCEEDED`) com preset Adaptativo e `AdaptiveRouter.selfCheck` no boot.

## Próximo experimento

1. Instalar o app e rodar preset **Adaptativo** (60 tarefas Qwen) em modo simulado; comparar `routerDecisionMs` e sucesso com o replay.
2. Repetir 3× `direct`/`plan_act` no Qwen com pausa térmica para estimar variância.
3. Treinar no Apple full 150 se o LOFO continuar positivo.
4. Só então Experimento C (reavaliação entre tool calls).
