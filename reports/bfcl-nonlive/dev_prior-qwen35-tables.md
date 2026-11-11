# dev_prior · qwen35 · 40 tarefas

Gerado por `analysis/bfcl_nonlive/pilot.py`. Latência em s, tokens por tarefa (média).

| Categoria | Estratégia | Acerto | IC95 | Lat. média | Lat. mediana | 1ª chamada (med.) | Entrada | Saída | Raciocínio | length |
|---|---|---|---|---|---|---|---|---|---|---|
| all | Direct | 26/40 (65%) | 50–78% | 12.2 | 8.0 | 4.5 (n=25) | 461 | 249 | 0 | 4 |
| all | Reasoning | 34/40 (85%) | 71–93% | 15.9 | 11.2 | 8.8 (n=33) | 459 | 328 | 189 | 4 |
| simple_python | Direct | 6/8 (75%) | 41–93% | 8.5 | 3.9 | 3.9 (n=7) | 373 | 175 | 0 | 1 |
| simple_python | Reasoning | 7/8 (88%) | 53–98% | 7.9 | 8.0 | 7.9 (n=8) | 371 | 139 | 85 | 0 |
| multiple | Direct | 3/8 (38%) | 14–69% | 6.7 | 4.8 | 4.1 (n=5) | 596 | 109 | 0 | 0 |
| multiple | Reasoning | 6/8 (75%) | 41–93% | 8.8 | 8.5 | 8.5 (n=8) | 594 | 171 | 114 | 0 |
| parallel | Direct | 5/8 (62%) | 31–86% | 16.6 | 10.3 | 4.5 (n=5) | 387 | 347 | 0 | 1 |
| parallel | Reasoning | 6/8 (75%) | 41–93% | 12.4 | 12.8 | 10.5 (n=8) | 385 | 237 | 127 | 0 |
| parallel_multiple | Direct | 6/8 (75%) | 41–93% | 13.0 | 10.2 | 4.6 (n=6) | 577 | 246 | 0 | 0 |
| parallel_multiple | Reasoning | 8/8 (100%) | 68–100% | 19.1 | 18.4 | 14.1 (n=8) | 575 | 381 | 213 | 0 |
| irrelevance | Direct | 6/8 (75%) | 41–93% | 16.4 | 9.8 | 4.3 (n=2) | 371 | 368 | 0 | 2 |
| irrelevance | Reasoning | 7/8 (88%) | 53–98% | 31.2 | 34.2 | 12.0 (n=1) | 369 | 713 | 404 | 4 |

| Categoria | ambas | só Direct | só Reasoning | nenhuma | oracle |
|---|---|---|---|---|---|
| all | 25 | 1 | 9 | 5 | 35 |
| simple_python | 6 | 0 | 1 | 1 | 7 |
| multiple | 3 | 0 | 3 | 2 | 6 |
| parallel | 4 | 1 | 2 | 1 | 7 |
| parallel_multiple | 6 | 0 | 2 | 0 | 8 |
| irrelevance | 6 | 0 | 1 | 1 | 7 |

McNemar exato (só D × só R): p = 0.021. Latência R − D pareada: +3.6 s (IC95 bootstrap -0.9 a +8.3).
Oracle: 35/40 (melhor fixa 34; ganho +1). Oracle de custo: 11.5 s, 9 tarefas em R.

| Regra (antes da geração) | Acerto | Lat. média | Tarefas → R |
|---|---|---|---|
| `always_R` | 34 | 15.9 | 40 |
| `prompt_chars>=64→R` | 33 | 12.8 | 31 |
| `ast_router` | 32 | 13.5 | 29 |
| `n_params>=3→R` | 32 | 16.6 | 33 |
| `prompt_chars>=101→R` | 31 | 11.7 | 21 |
| `functions>=2→R` | 31 | 13.9 | 16 |
| `prompt_chars>=203→R` | 30 | 13.1 | 11 |
| `multi_cue→R` | 30 | 13.2 | 24 |
| `n_params>=6→R` | 30 | 13.7 | 13 |
| `n_params>=6→D` | 30 | 14.4 | 27 |
| `multi_cue→D` | 30 | 14.9 | 16 |
| `prompt_chars>=203→D` | 30 | 15.0 | 29 |
| `functions>=2→D` | 29 | 14.2 | 24 |
| `prompt_chars>=101→D` | 29 | 16.4 | 19 |
| `n_params>=3→D` | 28 | 11.5 | 7 |
| `prompt_chars>=64→D` | 27 | 15.3 | 9 |
| `always_D` | 26 | 12.2 | 0 |

Leave-one-out (escolhe a regra que roteia sem a tarefa i): 32/40, 13.5 s; regras escolhidas: {'ast_router': 1, 'prompt_chars>=64→R': 29, 'prompt_chars>=68→R': 10}.
Custo da regra no Mac (Python, extração de features + decisão): 1.2 µs/tarefa.

| Critério | Resultado |
|---|---|
| C1_bidirectional | não |
| C2_accuracy_headroom | não |
| C3_latency_headroom | sim |
| C4_capturable_in_sample | não |
| C4_capturable_loo | não |
| **Prosseguir com Adaptive** | **não** |

Portão da etapa 2: regra `prompt_chars>=64→R` 33 acertos, 12.8 s × Reasoning 34, 15.9 s; LOO 32 → **não passa**.
