# dev · qwen35 · 80 tarefas

Gerado por `analysis/bfcl_nonlive/pilot.py`. Latência em s, tokens por tarefa (média).

| Categoria | Estratégia | Acerto | IC95 | Lat. média | Lat. mediana | 1ª chamada (med.) | Entrada | Saída | Raciocínio | length |
|---|---|---|---|---|---|---|---|---|---|---|
| all | Direct | 54/80 (68%) | 57–77% | 12.8 | 8.0 | 4.7 (n=55) | 476 | 228 | 0 | 7 |
| all | Reasoning | 65/80 (81%) | 71–88% | 18.7 | 12.2 | 10.9 (n=66) | 474 | 341 | 205 | 9 |
| simple_python | Direct | 11/16 (69%) | 44–86% | 8.0 | 4.3 | 3.9 (n=13) | 377 | 149 | 0 | 1 |
| simple_python | Reasoning | 14/16 (88%) | 64–97% | 11.5 | 8.1 | 7.9 (n=15) | 375 | 190 | 137 | 1 |
| multiple | Direct | 9/16 (56%) | 33–77% | 9.1 | 6.2 | 5.3 (n=13) | 625 | 150 | 0 | 1 |
| multiple | Reasoning | 13/16 (81%) | 57–93% | 10.5 | 10.3 | 10.2 (n=16) | 623 | 184 | 123 | 0 |
| parallel | Direct | 10/16 (62%) | 39–82% | 18.9 | 10.3 | 4.6 (n=10) | 401 | 348 | 0 | 2 |
| parallel | Reasoning | 12/16 (75%) | 51–90% | 19.4 | 14.7 | 11.5 (n=14) | 399 | 344 | 195 | 2 |
| parallel_multiple | Direct | 13/16 (81%) | 57–93% | 12.5 | 11.6 | 5.0 (n=14) | 613 | 208 | 0 | 0 |
| parallel_multiple | Reasoning | 15/16 (94%) | 72–99% | 22.0 | 21.0 | 15.7 (n=16) | 611 | 400 | 231 | 0 |
| irrelevance | Direct | 11/16 (69%) | 44–86% | 15.3 | 7.1 | 4.2 (n=5) | 364 | 288 | 0 | 3 |
| irrelevance | Reasoning | 11/16 (69%) | 44–86% | 30.0 | 22.0 | 10.2 (n=5) | 362 | 589 | 338 | 6 |

| Categoria | ambas | só Direct | só Reasoning | nenhuma | oracle |
|---|---|---|---|---|---|
| all | 51 | 3 | 14 | 12 | 68 |
| simple_python | 11 | 0 | 3 | 2 | 14 |
| multiple | 8 | 1 | 5 | 2 | 14 |
| parallel | 9 | 1 | 3 | 3 | 13 |
| parallel_multiple | 13 | 0 | 2 | 1 | 15 |
| irrelevance | 10 | 1 | 1 | 4 | 12 |

McNemar exato (só D × só R): p = 0.013. Latência R − D pareada: +5.9 s (IC95 bootstrap +2.9 a +9.1).
Oracle: 68/80 (melhor fixa 65; ganho +3). Oracle de custo: 12.1 s, 14 tarefas em R.

| Regra (antes da geração) | Acerto | Lat. média | Tarefas → R |
|---|---|---|---|
| `prompt_chars>=64→R` | 65 | 16.1 | 62 |
| `always_R` | 65 | 18.7 | 80 |
| `n_params>=3→R` | 64 | 17.8 | 63 |
| `ast_router` | 62 | 16.0 | 55 |
| `prompt_chars>=100→R` | 61 | 14.4 | 41 |
| `prompt_chars>=211→D` | 61 | 16.6 | 59 |
| `n_params>=6→R` | 60 | 14.4 | 25 |
| `functions>=2→R` | 60 | 14.9 | 32 |
| `multi_cue→R` | 60 | 15.3 | 43 |
| `multi_cue→D` | 59 | 16.1 | 37 |
| `functions>=2→D` | 59 | 16.5 | 48 |
| `n_params>=6→D` | 59 | 17.0 | 55 |
| `prompt_chars>=211→R` | 58 | 14.9 | 21 |
| `prompt_chars>=100→D` | 58 | 17.1 | 39 |
| `n_params>=3→D` | 55 | 13.6 | 17 |
| `always_D` | 54 | 12.8 | 0 |
| `prompt_chars>=64→D` | 54 | 15.3 | 18 |

Leave-one-out (escolhe a regra que roteia sem a tarefa i): 65/80, 15.9 s; regras escolhidas: {'prompt_chars>=64→R': 60, 'prompt_chars>=68→R': 20}.
Custo da regra no Mac (Python, extração de features + decisão): 1.2 µs/tarefa.

| Critério | Resultado |
|---|---|
| C1_bidirectional | sim |
| C2_accuracy_headroom | sim |
| C3_latency_headroom | sim |
| C4_capturable_in_sample | não |
| C4_capturable_loo | não |
| **Prosseguir com Adaptive** | **não** |

Portão da etapa 2: regra `prompt_chars>=64→R` 65 acertos, 16.1 s × Reasoning 65, 18.7 s; LOO 65 → **passa**.
