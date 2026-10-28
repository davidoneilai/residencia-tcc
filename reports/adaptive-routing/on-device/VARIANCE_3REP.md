# Matriz de variância (3 repetições) — resultados on-device

Sessão `45A14101-E08C-4CE1-8A65-18A94A25A74B`, Qwen3-1.7B-4bit no iPhone 16 Pro (`iPhone17,1`, iOS 26.6.2). 540/540 concluídas (`finished: true`). Fonte: `variance-session.json`.

## Configuração

| | |
| --- | --- |
| Modelo | Qwen3-1.7B-4bit (MLX 3.31.4) |
| Estratégias | `direct`, `plan_act`, `adaptive` (heurística) |
| Tarefas | 60 Apple residency |
| Repetições | 3 (runIndex 1–3), seed `736194`, amostragem gulosa |
| Total | **540** avaliações, todas `countsTowardAnalysis` |
| Modo | simulado |
| Térmica | `requireCoolThermal: false` (segue em `serious`) |
| Parede | 2026-10-19 14:10 UTC → 2026-10-20 16:09 UTC (~26 h) |
| Inferência acumulada | 3.97 h |

## Resultado principal

| Política | n | Sucesso | Latência média (ms) | σ (ms) | Total (ms) | vs `direct` |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `direct` | 180 | **0.400** (72) | 25 291 | 16 074 | 4 552 307 | — |
| `plan_act` | 180 | 0.333 (60) | 29 960 | 13 132 | 5 392 805 | +18.5% lat, −6.7 pp |
| `adaptive` | 180 | 0.383 (69) | **24 209** | 13 732 | **4 357 558** | **−4.3% lat, −1.7 pp** |
| oracle (por tarefa) | 60×3 | **0.500** | 21 002 | — | 3 780 400 | −17.0% lat, +10.0 pp |

O roteador heurístico é a política **mais rápida** das três medidas. Não empata o `direct` em sucesso: **23/60 tarefas vs 24/60** (69 vs 72 runs, −1.7 pp). As 7 perdas listadas abaixo são vs o **oracle**, não vs `direct` (diante do `direct`, a heurística perde 2 only-direct e ganha 1 only-plan). Contra `plan_act`, ganha sucesso e corta 19.2% de latência. Overhead médio da decisão: **0.40 ms/tarefa**.

## Variância: qualidade determinística, latência térmica

Nas 180 células `(política × tarefa)`, as 3 reps **concordam 100%** no `taskSuccess` (67 sempre certo, 113 sempre errado, 0 misto). Com greedy + ferramentas simuladas, a qualidade é propriedade de `(tarefa, política)`, não de ruído de amostragem. Uma repetição basta para afirmar sucesso; as 3 servem para latência.

CV médio da latência intra-célula: **21.4%**. Fonte: térmica. 446/540 jobs rodaram em `proceed_hot` (`thermalBefore = serious`).

| Estado | n | Sucesso | Latência média | tok/s |
| --- | ---: | ---: | ---: | ---: |
| `ready` (nominal/fair) | 94 | 0.372 | 19 196 ms | 44.5 |
| `proceed_hot` (serious) | 446 | 0.372 | 28 023 ms | 33.9 |

Sucesso idêntico; throttle só alonga o decode (~24% menos tok/s). As 3 reps de cada política têm a mesma taxa de sucesso e latências médias dentro de ~1–1.5 s.

## Por categoria (180 runs = 3 reps)

| Categoria | n/pol | Direct SR | Direct ms | Plan SR | Plan ms | Adaptive SR | Adaptive ms | Escolha adaptive |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| single_tool | 45 | **0.733** | 20 419 | 0.667 | 34 544 | **0.733** | 23 001 | 27 direct / 18 plan |
| sequential | 60 | 0.050 | 27 210 | **0.100** | 25 402 | **0.000** | 23 360 | 9 direct / 51 plan |
| multi_tool | 45 | **0.267** | 37 124 | 0.200 | 34 247 | **0.267** | 35 117 | 24 direct / 21 plan |
| ambiguous | 30 | **0.800** | 11 009 | 0.500 | 25 769 | **0.800** | 11 354 | 30 direct |

Ambíguas e single-tool: adaptive empata o melhor fixo em sucesso. Sequential é o buraco: a heurística manda `sequential_or_contact → plan_act` (51/60). As **2** vitórias de `plan_act` (`seq_009`, `seq_017`) foram classificadas como `short_single → direct`, e a única vitória de `direct` (`seq_005`) foi mandada para `plan_act`. Resultado: adaptive **0/60** em sequential; o oracle pegaria **9/60** (3 tarefas × 3 reps).

## Roteador vs oracle

Complementaridade `direct`/`plan_act` (sucesso em ≥1 das 3 reps): only_direct=10, only_plan=6, both=14, neither=30. Teto A: **30/60 = 0.500**.

- Adaptive acerta a política do oracle em **36/60 (60%)**.
- 24 erros: 7 perdem sucesso, 17 só latência.
- Motivos da heurística (180 runs): `sequential_or_contact` 72, `short_single` 54, `default` 30, `long_multi_tool` 18, `ambiguous_prefer_direct` 6.

Sete perdas de sucesso (determinísticas, 3/3):

| Tarefa | Heurística | Oracle | Motivo |
| --- | --- | --- | --- |
| `apple_seq_005` | plan_act | direct | `sequential_or_contact` |
| `apple_seq_009` | direct | plan_act | `short_single` |
| `apple_seq_017` | direct | plan_act | `short_single` |
| `apple_amb_003` | direct | plan_act | `short_single` |
| `apple_multi_006` | direct | plan_act | `ambiguous_prefer_direct` |
| `apple_single_007` | direct | plan_act | `default` |
| `apple_single_014` | plan_act | direct | `sequential_or_contact` |

## Falhas e parada

| Política | grade | no_tool | execution | `stopReason=length` |
| --- | ---: | ---: | ---: | ---: |
| direct | 61 | 39 | 8 | 42 (SR 0.07) |
| plan_act | 51 | 48 | 21 | 63 (SR 0.19) |
| adaptive | 48 | 42 | 21 | 48 (SR 0.06) |

Estouro de `maxTokens` quase nunca acerta a tarefa. `plan_act` estoura mais (plano + ação).

## Prefill (Release + prefix KV cache)

Jobs 1–42 (antes do build Release/cache): prefill médio **2 426 ms**. Restante: **881 ms**. Depois da otimização, `direct` prefill 275 ms; `plan_act` 1 495 ms (dois prefills, plano e ação); adaptive no meio (866 ms), coerente com 50/50 de escolha.

A sessão `full60` anterior (1 rep, só adaptive) teve SR 0.400. Aqui adaptive ficou 0.383 **não** porque 3 reps “revelaram” a heurística: as rotas são idênticas (0 diffs). Três tarefas mudaram de sucesso *entre sessões* (`apple_amb_003`, `apple_multi_004`, `apple_multi_009`) apesar do greedy. Dentro desta sessão as 3 reps concordam 100%. Detalhe em `reports/adaptive-routing/v2/`.

## Leitura para o TCC

1. **A pergunta “o roteador reduz latência sem perder qualidade?”** neste dispositivo, com 3 reps: reduz 4.3% vs a melhor fixa (`direct`) e perde 1.7 pp de sucesso. O ganho de latência é real; o empate de qualidade da sessão de 1 rep **não se sustenta** quando o roteador erra as 7 tarefas acima.
2. **Oracle ainda vale 11.7 pp e 15% de latência.** O gargalo não é o overhead (0.40 ms) nem a variância de amostragem; é a heurística de cues, sobretudo sequential/contato.
3. **Variância de qualidade é zero** sob greedy+simulado. Relatar IC de sucesso por repetição seria cosmético; o IC útil é o de latência, dominado por térmica (`serious` em 83% dos jobs).
4. Rodar em `proceed_hot` não muda o veredito de qualidade. Muda o denominador de tok/s (~34 vs ~45). Qualquer comparação de latência on-device precisa declarar o estado térmico.

## Artefatos

- Sessão: `variance-session.json`
- Tabela agregada: `variance-3rep.variance.md` / `.json`
