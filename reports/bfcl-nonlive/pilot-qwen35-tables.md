# pilot · qwen35 · 40 tarefas

Gerado por `analysis/bfcl_nonlive/pilot.py`. Latência em s, tokens por tarefa (média).

| Categoria | Estratégia | Acerto | IC95 | Lat. média | Lat. mediana | 1ª chamada (med.) | Entrada | Saída | Raciocínio | length |
|---|---|---|---|---|---|---|---|---|---|---|
| all | Direct | 28/40 (70%) | 55–82% | 13.3 | 8.2 | 5.2 (n=30) | 491 | 208 | 0 | 3 |
| all | Reasoning | 31/40 (78%) | 62–88% | 21.5 | 13.8 | 11.8 (n=33) | 489 | 354 | 221 | 5 |
| simple_python | Direct | 5/8 (62%) | 31–86% | 7.4 | 4.6 | 4.3 (n=6) | 381 | 122 | 0 | 0 |
| simple_python | Reasoning | 7/8 (88%) | 53–98% | 15.1 | 8.3 | 8.2 (n=7) | 379 | 240 | 189 | 1 |
| multiple | Direct | 6/8 (75%) | 41–93% | 11.6 | 7.4 | 6.1 (n=8) | 654 | 191 | 0 | 1 |
| multiple | Reasoning | 7/8 (88%) | 53–98% | 12.3 | 12.0 | 12.0 (n=8) | 652 | 196 | 132 | 0 |
| parallel | Direct | 5/8 (62%) | 31–86% | 21.1 | 12.9 | 4.6 (n=5) | 414 | 348 | 0 | 1 |
| parallel | Reasoning | 6/8 (75%) | 41–93% | 26.5 | 19.9 | 11.9 (n=6) | 412 | 452 | 263 | 2 |
| parallel_multiple | Direct | 7/8 (88%) | 53–98% | 12.1 | 12.7 | 5.6 (n=8) | 649 | 171 | 0 | 0 |
| parallel_multiple | Reasoning | 7/8 (88%) | 53–98% | 24.8 | 23.9 | 18.6 (n=8) | 647 | 418 | 248 | 0 |
| irrelevance | Direct | 5/8 (62%) | 31–86% | 14.1 | 5.6 | 4.2 (n=3) | 356 | 207 | 0 | 1 |
| irrelevance | Reasoning | 4/8 (50%) | 22–78% | 28.8 | 11.0 | 9.6 (n=4) | 354 | 465 | 272 | 2 |

| Categoria | ambas | só Direct | só Reasoning | nenhuma | oracle |
|---|---|---|---|---|---|
| all | 26 | 2 | 5 | 7 | 33 |
| simple_python | 5 | 0 | 2 | 1 | 7 |
| multiple | 5 | 1 | 2 | 0 | 8 |
| parallel | 5 | 0 | 1 | 2 | 6 |
| parallel_multiple | 7 | 0 | 0 | 1 | 7 |
| irrelevance | 4 | 1 | 0 | 3 | 5 |

McNemar exato (só D × só R): p = 0.453. Latência R − D pareada: +8.2 s (IC95 bootstrap +4.1 a +12.7).
Oracle: 33/40 (melhor fixa 31; ganho +2). Oracle de custo: 12.7 s, 5 tarefas em R.

| Regra (antes da geração) | Acerto | Lat. média | Tarefas → R |
|---|---|---|---|
| `n_params>=3→R` | 32 | 19.0 | 30 |
| `prompt_chars>=64→R` | 32 | 19.5 | 31 |
| `n_params>=2→R` | 31 | 20.1 | 39 |
| `always_R` | 31 | 21.5 | 40 |
| `n_params>=6→R` | 30 | 15.1 | 12 |
| `multi_cue→R` | 30 | 17.5 | 19 |
| `prompt_chars>=90→R` | 30 | 18.1 | 21 |
| `ast_router` | 30 | 18.6 | 26 |
| `prompt_chars>=265→D` | 30 | 18.7 | 29 |
| `functions>=2→D` | 30 | 18.8 | 24 |
| `functions>=2→R` | 29 | 16.0 | 16 |
| `prompt_chars>=265→R` | 29 | 16.1 | 11 |
| `prompt_chars>=90→D` | 29 | 16.7 | 19 |
| `multi_cue→D` | 29 | 17.3 | 21 |
| `n_params>=6→D` | 29 | 19.6 | 28 |
| `always_D` | 28 | 13.3 | 0 |
| `n_params>=2→D` | 28 | 14.7 | 1 |
| `prompt_chars>=64→D` | 27 | 15.3 | 9 |
| `n_params>=3→D` | 27 | 15.8 | 10 |

Leave-one-out (escolhe a regra que roteia sem a tarefa i): 32/40, 19.0 s; regras escolhidas: {'n_params>=3→R': 40}.
Custo da regra no Mac (Python, extração de features + decisão): 1.3 µs/tarefa.

| Critério | Resultado |
|---|---|
| C1_bidirectional | sim |
| C2_accuracy_headroom | sim |
| C3_latency_headroom | sim |
| C4_capturable_in_sample | sim |
| C4_capturable_loo | sim |
| **Prosseguir com Adaptive** | **sim** |

Portão da etapa 2: regra `n_params>=3→R` 32 acertos, 19.0 s × Reasoning 31, 21.5 s; LOO 32 → **passa**.
