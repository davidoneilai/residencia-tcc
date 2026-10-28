# Adaptive routing v2

Roteador leve aprendido sobre a sessão on-device de 3 reps (Qwen3-1.7B-4bit, iPhone 16 Pro).
Features só do prompt + catálogo público de ferramentas. Oracle é teto retrospectivo, não um modelo executável.

## 1. Auditoria da sessão de 540

- Arquivo: `/Users/macbookpro/VSCODE/residencia-tcc/reports/adaptive-routing/on-device/variance-session.json` · finished=True · n=540.
- Células (política × tarefa) com sucesso misto entre reps: **0**.
- Prefixo KV cache: jobs 1–42 prefill 2426 ms vs resto 881 ms; flips de sucesso vs reps irmãs: **0**.

### 0.400 (full60) vs 0.383 (variance adaptive)

Não é efeito de “3 reps revelarem erros da heurística”. As decisões de rota são as mesmas (0 diffs).
full60: 0.400 em 60. Variance adaptive: 23/60 = 0.383.
3 tarefas mudaram de sucesso **entre sessões** (greedy não é estável bit-a-bit entre launches/builds):

| Tarefa | full60 | variance | rota |
| --- | --- | --- | --- |
| `apple_multi_009` | True | False | direct |
| `apple_amb_003` | True | False | direct |
| `apple_multi_004` | False | True | direct |

Correções do relatório de variância: adaptive vs direct é **23/60 vs 24/60** (não 3 tarefas);
sequential plan_act acerta 2 tarefas; oracle sequential seria 9/60 runs (3 tarefas), não 6/60.

### Térmica

| Estado | n | Sucesso | tok/s |
| --- | ---: | ---: | ---: |
| ready | 94 | 0.372 | 44.5 |
| proceed_hot | 446 | 0.372 | 33.9 |

Sucesso idêntico entre `ready` e `proceed_hot`; latência não. Comparações de latência entre políticas nesta sessão são válidas porque o shuffle mistura estados, mas o nível absoluto está dominado por `serious` (83% dos jobs).

### Falhas (runs, não tarefas)

| Política | grade | no_tool | execution | stop=length |
| --- | ---: | ---: | ---: | ---: |
| direct | 61 | 39 | 8 | 42 |
| plan_act | 51 | 48 | 21 | 63 |
| adaptive | 48 | 42 | 21 | 48 |

`stopReason=length` quase não gera sucesso. `plan_act` estoura mais (plano + ação).

## 2. Matriz usada no treino

- 60 tarefas, 3 reps agregadas (sucesso = maioria, latência = média).
- Direct 0.400, plan_act 0.333, oracle 0.500.
- Complementaridade: only_direct=10, only_plan=6, both=14, neither=30.
- Adaptive heurístico (on-device, 3 reps): sucesso 0.383, latência média 24209 ms.

Rótulos de treino: only_* peso 8, both (mais rápida) peso 1, neither → direct peso 0.25.
Limiar da logística ≥ 0.5 (plan_act só com evidência). Piso na validação: não perder sucesso vs melhor fixa (slack 0).

Learned escolhido na validação do hold-out: `logistic`.

## 3. Hold-out por família (desenvolvimento — não é generalização)

Split train/val/test = {'train': 25, 'val': 15, 'test': 20}. Famílias teste: `apple_amb_b0, apple_multi_b2, apple_seq_b0, apple_single_b2`.

| Método | Sucesso | IC 95% (tarefa) | Latência média (ms) | vs direct (pp, ms) | correct / SR-loss / lat-only |
| --- | ---: | ---: | ---: | ---: | ---: |
| fixed:direct | 0.300 | [0.100, 0.500] | 23149 | — | 14 / 2 / 4 |
| fixed:plan_act | 0.250 | [0.100, 0.450] | 27903 | -5.0 pp, +4753 ms | 6 / 3 / 11 |
| heuristic | 0.250 | [0.050, 0.450] | 25451 | -5.0 pp, +2302 ms | 10 / 3 / 7 |
| logistic | 0.300 | [0.100, 0.500] | 25320 | +0.0 pp, +2171 ms | 12 / 2 / 6 |
| decision_tree | 0.300 | [0.100, 0.500] | 23149 | +0.0 pp, +0 ms | 14 / 2 / 4 |
| oracle | 0.400 | [0.200, 0.600] | 19506 | — | 20 / 0 / 0 |

Este hold-out reusa as mesmas 60 tarefas (famílias diferentes). **Não reportar como generalização.**

## 4. Replay nas 60 (ajuste, não generalização)

| Método | Sucesso | IC 95% | Latência média (ms) | correct / SR-loss / lat-only |
| --- | ---: | ---: | ---: | ---: |
| fixed:direct | 0.400 | [0.283, 0.533] | 25291 | 38 / 6 / 16 |
| fixed:plan_act | 0.333 | [0.217, 0.450] | 29960 | 22 / 10 / 28 |
| heuristic | 0.383 | [0.267, 0.517] | 24495 | 36 / 7 / 17 |
| logistic | 0.433 | [0.317, 0.567] | 25017 | 37 / 4 / 19 |
| decision_tree | 0.400 | [0.283, 0.533] | 26547 | 33 / 6 / 21 |
| oracle | 0.500 | [0.383, 0.617] | 21002 | 60 / 0 / 0 |

Perdas de sucesso da logística no replay (in-sample):

| Tarefa | Escolheu | Oracle |
| --- | --- | --- |
| `apple_amb_005` | plan_act | direct |
| `apple_seq_009` | direct | plan_act |
| `apple_seq_017` | direct | plan_act |
| `apple_single_015` | direct | plan_act |

Replay inclui o treino: a logística **não** pode ser lida como generalização. Se o LOFO ficar abaixo de `direct`, as features não separam only_plan de only_direct em famílias novas.

## 5. Leave-one-family-out (estimativa dentro de residency-60)

| Método | Sucesso | Latência média (ms) |
| --- | ---: | ---: |
| fixed | 0.400 | 25291 |
| heuristic | 0.383 | 24495 |
| learned | 0.350 | 26089 |
| oracle | 0.500 | 21002 |

LOFO ainda está na população das 60. Famílias held-out do dataset de 150 não têm rótulo de política.

## 6. Generalização e 360 tarefas

Não há 360 tarefas únicas no harness. Há:

- 360 execuções no experimento cross-model original (3 modelos × 2 políticas × 60 tarefas).
- **150** tarefas Apple (`apple_full_150`): 40/40/50/20 por categoria.
- **60** medidas nesta sessão (`apple_residency_60` = IDs 001–015/020/010).
- **90** inéditas, famílias disjuntas: `90` IDs, 0 execuções Qwen.

Com 12 famílias e 16 complementary (only_*) no residency, o classificador é pequeno demais para cravar generalização.
Menor ampliação que desbloqueia teste em templates novos:

- Medir as 90 held-out × `{direct, plan_act}` × 1 rep = **180 jobs** (qualidade greedy é estável *dentro* da sessão).
- Depois, 90 × `adaptive` learned = 90 jobs de validação on-device.
- Preset no app: `heldout-90` (`LaunchAutomation`).

Não ajustar a heurística à mão nas 7 perdas. Os pesos exportados vão para `AdaptiveRouter.swift` via `export_swift_weights.py`.

## 7. Próximo passo on-device

Congelar: modelo Qwen3-1.7B-4bit, build Release, prefix KV cache, greedy, simulado.
Registrar `thermalBefore` / `thermalGate`. Não misturar jobs 1–42 da sessão antiga (sem cache) em tabelas de latência v2.

Artefatos neste diretório: `audit.json`, `qwen_learned.json`, `comparison.csv`, `task_policy_matrix.csv`.

