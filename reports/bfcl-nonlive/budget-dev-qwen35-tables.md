# Estudo B · dev · 80 tarefas

Gerado por `analysis/bfcl_nonlive/budget.py`. Blocos curtos com resfriamento; latência em s.

| Categoria | Estratégia | Acerto | Lat. média | 1ª chamada (med.) | Saída | Raciocínio | length |
|---|---|---|---|---|---|---|---|
| all | Reasoning | 65/80 (81%) | 21.3 | 13.0 | 341 | 205 | 9 |
| all | Budget-128 | 62/80 (78%) | 21.0 | 15.9 | 244 | 108 | 4 |
| all | Budget-256 | 62/80 (78%) | 20.5 | 15.3 | 280 | 145 | 4 |
| all | Budget-512 | 64/80 (80%) | 25.0 | 18.2 | 314 | 172 | 5 |
| simple_python | Reasoning | 14/16 (88%) | 13.7 | 12.0 | 190 | 137 | 1 |
| simple_python | Budget-128 | 15/16 (94%) | 15.1 | 15.7 | 136 | 81 | 0 |
| simple_python | Budget-256 | 15/16 (94%) | 12.6 | 11.1 | 144 | 89 | 0 |
| simple_python | Budget-512 | 15/16 (94%) | 17.3 | 15.8 | 160 | 105 | 0 |
| multiple | Reasoning | 13/16 (81%) | 13.3 | 13.2 | 184 | 123 | 0 |
| multiple | Budget-128 | 13/16 (81%) | 18.1 | 16.9 | 166 | 110 | 0 |
| multiple | Budget-256 | 12/16 (75%) | 17.1 | 15.2 | 179 | 123 | 0 |
| multiple | Budget-512 | 12/16 (75%) | 19.9 | 19.6 | 179 | 123 | 0 |
| parallel | Reasoning | 12/16 (75%) | 20.1 | 12.2 | 344 | 195 | 2 |
| parallel | Budget-128 | 11/16 (69%) | 18.0 | 13.2 | 242 | 111 | 0 |
| parallel | Budget-256 | 12/16 (75%) | 20.9 | 14.9 | 266 | 140 | 0 |
| parallel | Budget-512 | 12/16 (75%) | 24.5 | 17.1 | 317 | 163 | 1 |
| parallel_multiple | Reasoning | 15/16 (94%) | 23.9 | 17.1 | 400 | 231 | 0 |
| parallel_multiple | Budget-128 | 15/16 (94%) | 24.3 | 18.4 | 286 | 127 | 0 |
| parallel_multiple | Budget-256 | 15/16 (94%) | 25.1 | 19.6 | 375 | 208 | 0 |
| parallel_multiple | Budget-512 | 15/16 (94%) | 31.1 | 24.1 | 398 | 231 | 0 |
| irrelevance | Reasoning | 11/16 (69%) | 35.5 | 12.4 | 589 | 338 | 6 |
| irrelevance | Budget-128 | 8/16 (50%) | 29.4 | 15.2 | 392 | 111 | 4 |
| irrelevance | Budget-256 | 8/16 (50%) | 26.8 | 15.0 | 434 | 165 | 4 |
| irrelevance | Budget-512 | 10/16 (62%) | 32.4 | 14.6 | 515 | 240 | 4 |

| Contra a Reasoning (pareado, IC95) | Acerto | Tokens de saída | Latência | Resgatadas | Perdidas | Teto atingido |
|---|---|---|---|---|---|---|
| Budget-128 | -3.8 pp (-10.0 a +2.5) | -96.6 (-145.3 a -54.5) | -0.3 s (-2.8 a +1.9) | 2 | 5 | 40 |
| Budget-256 | -3.8 pp (-8.8 a +1.2) | -61.4 (-102.1 a -26.1) | -0.8 s (-3.2 a +1.4) | 1 | 4 | 13 |
| Budget-512 | -1.2 pp (-5.0 a +2.5) | -27.4 (-50.0 a -8.8) | +3.8 s (+2.3 a +5.1) | 1 | 2 | 6 |

**determinism:** `{"reasoning_verdicts_equal_previous_dev": 80, "reasoning_tokens_equal_previous_dev": 80, "n": 80}`

**gate:** `{"rule": "menor b com acerto ≥ Reasoning − 1 e tokens ≤ 90 % da Reasoning", "reasoning": {"correct": 65, "tokens": 341.1}, "candidates": {"Budget-128": {"correct": 62, "tokens": 244.4875}, "Budget-256": {"correct": 62, "tokens": 279.7375}, "Budget-512": {"correct": 64, "tokens": 313.675}}, "passing": [], "chosen": null}`
