## Tabela principal (BFCL v4 AST, 40 tarefas, checker oficial)

| Modelo | Estratégia | Acurácia | Latência média (s) | Mediana (s) | Prefill (s) | Decode (s) | Tokens in/out | Pico mem (MB) | Falhas |
|---|---|---|---|---|---|---|---|---|---|
| LFM2.5-2.6B-MLX-4bit | direct | 33/40 (82%) | 16.2 | 13.2 | 2.8 | 13.4 | 264/249 | 2081 | invalid_arguments 5, called_on_irrelevance 2 |
| LFM2.5-2.6B-MLX-4bit | plan_act | 20/40 (50%) | 39.2 | 35.3 | 3.8 | 26.0 | 692/606 | 2085 | missing_call 19, format_error 1 |
| LFM2.5-2.6B-MLX-4bit | budget_64 | 29/40 (72%) | 12.4 | 11.6 | 2.8 | 5.9 | 264/136 | 2081 | invalid_arguments 4, wrong_function 3, called_on_irrelevance 3, format_error 1 |
| LFM2.5-2.6B-MLX-4bit | ast_router | 33/40 (82%) | 13.4 | 11.9 | 2.8 | 9.8 | 264/193 | 2081 | invalid_arguments 4, called_on_irrelevance 3 |
| MiniCPM5-2B-MLX | direct | 31/40 (78%) | 42.2 | 37.9 | 4.0 | 38.2 | 395/565 | 1764 | format_error 4, length 3, invalid_arguments 2 |
| MiniCPM5-2B-MLX | plan_act | 33/40 (82%) | 48.6 | 33.8 | 4.4 | 35.5 | 904/603 | 1768 | format_error 5, length 2 |
| MiniCPM5-2B-MLX | nothink | 34/40 (85%) | 7.5 | 6.0 | 4.0 | 3.5 | 397/65 | 1765 | invalid_arguments 4, wrong_function 1, called_on_irrelevance 1 |
| MiniCPM5-2B-MLX | budget_64 | 29/40 (72%) | 14.8 | 13.4 | 4.0 | 6.5 | 395/118 | 1776 | wrong_function 5, called_on_irrelevance 3, invalid_arguments 3 |
| MiniCPM5-2B-MLX | ast_router | 31/40 (78%) | 30.0 | 20.0 | 3.9 | 26.0 | 395/389 | 1764 | format_error 4, invalid_arguments 3, called_on_irrelevance 1, length 1 |
| MiniCPM5-2B-MLX | adaptive_step | 34/40 (85%) | 8.7 | 6.3 | 4.1 | 4.0 | 396/72 | 1765 | invalid_arguments 3, wrong_function 2, called_on_irrelevance 1 |
| Qwen3.5-2B-4bit | direct | 35/40 (88%) | 21.2 | 16.1 | 3.3 | 17.9 | 459/342 | 2478 | invalid_arguments 4, called_on_irrelevance 1 |
| Qwen3.5-2B-4bit | plan_act | 28/40 (70%) | 30.4 | 28.7 | 3.8 | 19.2 | 1033/454 | 2557 | invalid_arguments 4, missing_call 2, length 2, wrong_function 2, called_on_irrelevance 2 |
| Qwen3.5-2B-4bit | nothink | 27/40 (68%) | 17.7 | 9.9 | 3.2 | 14.5 | 461/291 | 2480 | length 4, missing_call 4, invalid_arguments 3, called_on_irrelevance 2 |
| Qwen3.5-2B-4bit | budget_64 | 30/40 (75%) | 15.9 | 13.5 | 3.3 | 8.5 | 459/196 | 2557 | invalid_arguments 4, called_on_irrelevance 3, wrong_function 3 |
| Qwen3.5-2B-4bit | ast_router | 33/40 (82%) | 18.5 | 14.3 | 3.4 | 15.0 | 459/289 | 2478 | invalid_arguments 4, called_on_irrelevance 2, length 1 |
| Qwen3.5-2B-4bit | adaptive_step | 27/40 (68%) | 17.1 | 10.3 | 3.3 | 13.2 | 460/264 | 2480 | missing_call 3, length 3, invalid_arguments 3, wrong_function 2, called_on_irrelevance 2 |
| gemma-4-e2b-it-4bit | direct | 28/40 (70%) | 37.9 | 37.3 | 1.7 | 26.3 | 245/437 | 3057 | invalid_arguments 10, missing_call 1, wrong_function 1 |
| gemma-4-e2b-it-4bit | plan_act | 25/40 (62%) | 45.4 | 41.7 | 3.0 | 25.2 | 623/532 | 3080 | invalid_arguments 13, length 1, called_on_irrelevance 1 |
| gemma-4-e2b-it-4bit | nothink | 31/40 (78%) | 13.6 | 11.0 | 1.7 | 5.1 | 243/92 | 3054 | invalid_arguments 7, wrong_function 1, called_on_irrelevance 1 |
| gemma-4-e2b-it-4bit | budget_64 | 25/40 (62%) | 24.7 | 25.2 | 1.8 | 10.4 | 245/188 | 3072 | invalid_arguments 9, wrong_function 3, called_on_irrelevance 2, missing_call 1 |
| gemma-4-e2b-it-4bit | ast_router | 29/40 (72%) | 29.7 | 27.5 | 1.8 | 20.5 | 245/355 | 3057 | invalid_arguments 9, called_on_irrelevance 1, wrong_function 1 |
| gemma-4-e2b-it-4bit | adaptive_step | 31/40 (78%) | 17.6 | 14.1 | 1.6 | 5.5 | 243/101 | 3054 | invalid_arguments 7, wrong_function 1, called_on_irrelevance 1 |

## Por categoria (acertos de 8)

| Modelo | Estratégia | simple_python | multiple | parallel | parallel_multiple | irrelevance |
|---|---|---|---|---|---|---|
| LFM2.5-2.6B-MLX-4bit | direct | 7 | 6 | 7 | 7 | 6 |
| LFM2.5-2.6B-MLX-4bit | plan_act | 4 | 2 | 2 | 4 | 8 |
| LFM2.5-2.6B-MLX-4bit | budget_64 | 8 | 7 | 5 | 4 | 5 |
| LFM2.5-2.6B-MLX-4bit | ast_router | 8 | 6 | 7 | 7 | 5 |
| MiniCPM5-2B-MLX | direct | 6 | 7 | 5 | 5 | 8 |
| MiniCPM5-2B-MLX | plan_act | 7 | 8 | 7 | 3 | 8 |
| MiniCPM5-2B-MLX | nothink | 7 | 7 | 6 | 7 | 7 |
| MiniCPM5-2B-MLX | budget_64 | 7 | 6 | 6 | 5 | 5 |
| MiniCPM5-2B-MLX | ast_router | 7 | 7 | 5 | 5 | 7 |
| MiniCPM5-2B-MLX | adaptive_step | 7 | 7 | 6 | 7 | 7 |
| Qwen3.5-2B-4bit | direct | 7 | 6 | 7 | 8 | 7 |
| Qwen3.5-2B-4bit | plan_act | 5 | 6 | 5 | 6 | 6 |
| Qwen3.5-2B-4bit | nothink | 6 | 4 | 5 | 6 | 6 |
| Qwen3.5-2B-4bit | budget_64 | 7 | 6 | 4 | 8 | 5 |
| Qwen3.5-2B-4bit | ast_router | 6 | 6 | 7 | 8 | 6 |
| Qwen3.5-2B-4bit | adaptive_step | 6 | 4 | 4 | 7 | 6 |
| gemma-4-e2b-it-4bit | direct | 6 | 5 | 6 | 3 | 8 |
| gemma-4-e2b-it-4bit | plan_act | 7 | 4 | 5 | 2 | 7 |
| gemma-4-e2b-it-4bit | nothink | 7 | 7 | 6 | 4 | 7 |
| gemma-4-e2b-it-4bit | budget_64 | 7 | 4 | 4 | 4 | 6 |
| gemma-4-e2b-it-4bit | ast_router | 8 | 5 | 6 | 3 | 7 |
| gemma-4-e2b-it-4bit | adaptive_step | 7 | 7 | 6 | 4 | 7 |

## Adaptativas × melhor fixa do mesmo modelo (pareado por tarefa; IC95% bootstrap)

| Modelo | Melhor fixa | Política | Δ acurácia (pp) | IC95% | Δ latência média (s) | IC95% | Decisões |
|---|---|---|---|---|---|---|---|
| LFM2.5-2.6B-MLX-4bit | direct | ast_router | +0.0 | [-7.5, +7.5] | -2.8 | [-5.0, -1.0] | {'budget_64': 11, 'direct': 29} |
| LFM2.5-2.6B-MLX-4bit | direct | plan_act | -32.5 | [-50.0, -12.5] | +23.0 | [+18.3, +27.7] |  |
| LFM2.5-2.6B-MLX-4bit | direct | budget_64 | -10.0 | [-22.5, +2.5] | -3.8 | [-5.9, -1.9] |  |
| MiniCPM5-2B-MLX | nothink | ast_router | -7.5 | [-17.5, +2.5] | +22.4 | [+15.1, +30.1] | {'nothink': 11, 'direct': 29} |
| MiniCPM5-2B-MLX | nothink | adaptive_step | +0.0 | [+0.0, +0.0] | +1.2 | [+0.3, +2.2] | {'nothink': 35, 'budget_64': 5} |
| MiniCPM5-2B-MLX | nothink | direct | -7.5 | [-20.0, +5.0] | +34.6 | [+26.8, +42.6] |  |
| MiniCPM5-2B-MLX | nothink | plan_act | -2.5 | [-17.5, +12.5] | +41.1 | [+33.1, +49.4] |  |
| MiniCPM5-2B-MLX | nothink | budget_64 | -12.5 | [-22.5, -2.5] | +7.3 | [+5.6, +8.6] |  |
| Qwen3.5-2B-4bit | direct | ast_router | -5.0 | [-12.5, +0.0] | -2.8 | [-7.1, +1.6] | {'nothink': 11, 'direct': 29} |
| Qwen3.5-2B-4bit | direct | adaptive_step | -20.0 | [-32.5, -7.5] | -4.1 | [-9.5, +1.7] | {'nothink': 35, 'budget_64': 5} |
| Qwen3.5-2B-4bit | direct | plan_act | -17.5 | [-32.5, -5.0] | +9.2 | [+5.0, +13.6] |  |
| Qwen3.5-2B-4bit | direct | nothink | -20.0 | [-32.5, -10.0] | -3.5 | [-9.1, +2.6] |  |
| Qwen3.5-2B-4bit | direct | budget_64 | -12.5 | [-22.5, -2.5] | -5.3 | [-8.9, -2.3] |  |
| gemma-4-e2b-it-4bit | nothink | ast_router | -5.0 | [-17.5, +7.5] | +16.0 | [+10.5, +21.4] | {'nothink': 11, 'direct': 29} |
| gemma-4-e2b-it-4bit | nothink | adaptive_step | +0.0 | [+0.0, +0.0] | +4.0 | [+1.0, +7.0] | {'nothink': 35, 'budget_64': 5} |
| gemma-4-e2b-it-4bit | nothink | direct | -7.5 | [-22.5, +7.5] | +24.3 | [+19.8, +28.9] |  |
| gemma-4-e2b-it-4bit | nothink | plan_act | -15.0 | [-27.5, -2.5] | +31.8 | [+27.3, +36.5] |  |
| gemma-4-e2b-it-4bit | nothink | budget_64 | -15.0 | [-27.5, -5.0] | +11.1 | [+6.8, +15.4] |  |

## Oracle retrospectivo (escolha por tarefa entre políticas avaliadas; limite superior)

| Modelo | Melhor fixa | Oracle fixas | Oracle fixas+adaptativas | Tarefas resolvidas só por ≠ melhor fixa | Oracle mais barato: latência média (s) vs melhor fixa |
|---|---|---|---|---|---|
| LFM2.5-2.6B-MLX-4bit | direct 33/40 | 37/40 | 37/40 | 4 | 14.2 vs 16.2 |
| MiniCPM5-2B-MLX | nothink 34/40 | 38/40 | 38/40 | 4 | 13.2 vs 7.5 |
| Qwen3.5-2B-4bit | direct 35/40 | 36/40 | 36/40 | 1 | 12.6 vs 21.2 |
| gemma-4-e2b-it-4bit | nothink 31/40 | 34/40 | 34/40 | 3 | 15.2 vs 13.6 |

## Complementaridade entre modelos (melhor fixa de cada)

União: 38/40 · interseção: 25/40 · nenhuma resolve: 2

- LFM2.5-2.6B-MLX-4bit: 33/40; exclusivas: []
- MiniCPM5-2B-MLX: 34/40; exclusivas: []
- Qwen3.5-2B-4bit: 35/40; exclusivas: []
- gemma-4-e2b-it-4bit: 31/40; exclusivas: ['simple_python_35']
