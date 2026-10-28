# Adaptive routing v3 — held-out 90

Avaliação externa. O roteador logístico está congelado em `v3/frozen/qwen_learned.json` (treino nas 60 residency). Nenhuma label das 90 entrou em treino, limiar ou heurística.

## Congelamento

- Modelo: `mlx-community/Qwen3-1.7B-4bit` · MLX 3.31.4 · Release · greedy temperature 0 ArgMaxSampler.
- Logistic threshold=0.5 fallback=`direct`.
- SHA pesos: `5e4603f9a325e275`.
- Famílias held-out ∩ residency: vazia.
- 90 IDs: single 25, multi 25, seq 30, amb 10.
- Sessão matriz: `C97C0CA8-39C0-4FD9-B1B4-07F4583FC47A` · 180 jobs · 1 rep · interleaved.

Oracle é teto retrospectivo, não um modelo executável. As 90 não entraram em treino, limiar ou heurística.

## Método

iPhone 16 Pro (iPhone17,1), Qwen3-1.7B-4bit, build Release, prefix KV cache, greedy (temperature 0, ArgMaxSampler), ferramentas simuladas. 90 tarefas = `apple_full_150` − residency-60; overlap de famílias vazio. 1 repetição por (tarefa × política); Direct e Plan+Act intercalados no mesmo shuffle (`orderSeed` do residency). Controle: 4 tarefas × 2 políticas em outro launch. Router-check: 8 Adaptive com `router=logistic` congelado. Replay reconstrói heurística e logística a partir da matriz observada. Não há retreino nem ajuste de limiar nas 90.

## Políticas (capacidade, 90×1)

- Direct: sucesso 0.422 (38/90), média 20411 ms, p50 20525, p90 29262.
- Plan+Act: sucesso 0.333 (30/90), média 26744 ms, p50 24057, p90 33335.
- Oracle retrospectivo: 0.522 (47/90), média 19149 ms.
- Complementaridade: only_direct=17, only_plan=9, both=21, neither=43.

## Roteadores (replay congelado)

IC 95% = bootstrap por tarefa (4000, seed 736194). Tarefas são a unidade; famílias são o agrupamento de generalização.

| Método | Sucesso | IC 95% | Latência média (ms) | overhead (ms) | vs direct | correct / SR-loss / lat-only |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| fixed:direct | 0.422 | [0.322, 0.522] | 20411 | 0.03 | +0.0 pp, +0 ms | 62 / 9 / 19 |
| fixed:plan_act | 0.333 | [0.244, 0.433] | 26744 | 0.03 | -8.9 pp, +6333 ms | 28 / 17 / 45 |
| heuristic | 0.411 | [0.311, 0.511] | 22060 | 0.03 | -1.1 pp, +1649 ms | 49 / 10 / 31 |
| logistic | 0.411 | [0.311, 0.511] | 23040 | 0.03 | -1.1 pp, +2629 ms | 55 / 10 / 25 |
| oracle | 0.522 | [0.422, 0.633] | 19149 | 0.00 | — | 90 / 0 / 0 |

Por categoria (sucesso):

| Categoria | n | Direct | Plan | Heurística | Learned | Oracle |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| ambiguous | 10 | 0.900 | 0.500 | 0.700 | 0.600 | 0.900 |
| multi_tool | 25 | 0.360 | 0.120 | 0.400 | 0.320 | 0.400 |
| sequential | 30 | 0.133 | 0.133 | 0.133 | 0.133 | 0.233 |
| single_tool | 25 | 0.640 | 0.720 | 0.640 | 0.760 | 0.840 |

Por família (sucesso):

| Família | n | Direct | Plan | Heurística | Learned | Oracle |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `apple_amb_b2` | 5 | 0.800 | 0.600 | 0.600 | 0.600 | 0.800 |
| `apple_amb_b3` | 5 | 1.000 | 0.400 | 0.800 | 0.600 | 1.000 |
| `apple_multi_b3` | 5 | 0.600 | 0.000 | 0.600 | 0.600 | 0.600 |
| `apple_multi_b4` | 5 | 0.000 | 0.000 | 0.000 | 0.000 | 0.000 |
| `apple_multi_b5` | 5 | 0.200 | 0.000 | 0.200 | 0.000 | 0.200 |
| `apple_multi_b6` | 5 | 1.000 | 0.400 | 1.000 | 1.000 | 1.000 |
| `apple_multi_b7` | 5 | 0.000 | 0.200 | 0.200 | 0.000 | 0.200 |
| `apple_seq_b4` | 5 | 0.600 | 0.400 | 0.400 | 0.600 | 1.000 |
| `apple_seq_b5` | 5 | 0.200 | 0.400 | 0.400 | 0.200 | 0.400 |
| `apple_seq_b6` | 5 | 0.000 | 0.000 | 0.000 | 0.000 | 0.000 |
| `apple_seq_b7` | 5 | 0.000 | 0.000 | 0.000 | 0.000 | 0.000 |
| `apple_seq_b8` | 5 | 0.000 | 0.000 | 0.000 | 0.000 | 0.000 |
| `apple_seq_b9` | 5 | 0.000 | 0.000 | 0.000 | 0.000 | 0.000 |
| `apple_single_b3` | 5 | 0.200 | 0.600 | 0.200 | 0.600 | 0.800 |
| `apple_single_b4` | 5 | 0.800 | 0.400 | 0.800 | 0.800 | 0.800 |
| `apple_single_b5` | 5 | 0.800 | 0.800 | 0.800 | 0.800 | 0.800 |
| `apple_single_b6` | 5 | 0.800 | 0.800 | 0.800 | 0.800 | 0.800 |
| `apple_single_b7` | 5 | 0.600 | 1.000 | 0.600 | 0.800 | 1.000 |

Learned — perdas de sucesso:

| Tarefa | Família | Escolheu | Oracle |
| --- | --- | --- | --- |
| `apple_amb_013` | `apple_amb_b2` | plan_act | direct |
| `apple_amb_017` | `apple_amb_b3` | plan_act | direct |
| `apple_amb_018` | `apple_amb_b3` | plan_act | direct |
| `apple_multi_028` | `apple_multi_b5` | plan_act | direct |
| `apple_multi_038` | `apple_multi_b7` | direct | plan_act |
| `apple_seq_024` | `apple_seq_b4` | direct | plan_act |
| `apple_seq_025` | `apple_seq_b4` | direct | plan_act |
| `apple_seq_028` | `apple_seq_b5` | direct | plan_act |
| `apple_single_019` | `apple_single_b3` | plan_act | direct |
| `apple_single_037` | `apple_single_b7` | direct | plan_act |

## Controle entre launches

8 pares (tarefa, política) em duas sessões. Flips de sucesso: 1. Trajetórias diferentes: 2.
- `['plan_act', 'apple_amb_011', 1]`: control=False → heldout90=True

## Validação on-device do roteador

8 execuções Adaptive (logística congelada) vs a mesma política isolada na matriz. Escolhas iguais ao Python congelado: 8/8. Divergências de sucesso: 1. Trajetórias diferentes: 1. Overhead on-device médio: 0.49 ms.
- `apple_single_016` chose plan_act: adaptive=False isolated=True stop=length fail=no_tool
Replay da matriz é válido para a *escolha* da política. Sucesso da inferência greedy não é bit-estável entre launches (ver controle); um mismatch de sucesso com a mesma rota não invalida o roteador, desde que a política escolhida coincida.

## Térmica

`ready` concentra os primeiros jobs após load/resume; não é um experimento térmico aleatorizado. O shuffle mistura políticas, então rankings de sucesso entre Direct/Plan/roteadores não se explicam por gate. Latência absoluta está dominada por `proceed_hot`.

| Estado | n | Sucesso | tok/s | lat média (ms) |
| --- | ---: | ---: | ---: | ---: |
| ready | 9 | 0.667 | 44.0 | 38939 |
| proceed_hot | 171 | 0.363 | 35.9 | 22769 |

## Falhas

| Política | grade | no_tool | execution | stop=length |
| --- | ---: | ---: | ---: | ---: |
| direct | 20 | 32 | 0 | 38 |
| plan_act | 15 | 37 | 8 | 42 |

## Recomendação

Priorize uma terceira política de inferência. 43/90 tarefas falham nas duas políticas (teto oracle 0.522 vs melhor fixa 0.422). Sequential não se mexe: Direct, Plan+Act, heurística e learned ficam presos na mesma taxa. Learned 0.411 e heurística 0.411 não batem Direct 0.422 em famílias inéditas (9 only_plan, 10 perdas de sucesso no learned). Não retreine nas 90 — já foram o teste. Headroom de roteamento existe, mas o teto de 52% com este par de políticas é o gargalo; thinking budget, early-exit ou tool-calling distinto rendem mais do que o mesmo classificador com as features atuais.

Artefatos: `freeze.json`, `frozen/qwen_learned.json`, `heldout90-session.json`, `control-session.json`, `router-check-session.json`, `task_policy_matrix.csv`, `comparison.csv`, `summary.json`.

