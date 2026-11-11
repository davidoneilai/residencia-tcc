# TESTE · qwen35 · 160 tarefas

Gerado por `analysis/bfcl_nonlive/test.py`. Latência em s; tokens por tarefa (média).

| Categoria | Estratégia | Acerto | IC95 | Lat. média | Lat. mediana | 1ª chamada (med.) | Entrada | Saída | Raciocínio | length |
|---|---|---|---|---|---|---|---|---|---|---|
| all | Direct | 108/160 (68%) | 60–74% | 23.4 | 15.2 | 9.4 (n=107) | 488 | 223 | 0 | 9 |
| all | Reasoning | 129/160 (81%) | 74–86% | 25.9 | 20.7 | 18.9 (n=140) | 486 | 305 | 193 | 6 |
| all | Adaptive | 130/160 (81%) | 74–87% | 27.6 | 21.8 | 18.4 (n=135) | 486 | 293 | 147 | 7 |
| simple_python | Direct | 25/32 (78%) | 61–89% | 11.8 | 9.6 | 7.8 (n=29) | 374 | 80 | 0 | 0 |
| simple_python | Reasoning | 29/32 (91%) | 76–97% | 16.2 | 15.9 | 15.8 (n=32) | 372 | 141 | 83 | 0 |
| simple_python | Adaptive | 29/32 (91%) | 76–97% | 14.2 | 11.5 | 11.4 (n=32) | 372 | 134 | 76 | 0 |
| multiple | Direct | 28/32 (88%) | 72–95% | 16.7 | 8.9 | 8.3 (n=29) | 619 | 109 | 0 | 1 |
| multiple | Reasoning | 31/32 (97%) | 84–99% | 21.1 | 18.6 | 18.5 (n=32) | 617 | 164 | 106 | 0 |
| multiple | Adaptive | 29/32 (91%) | 76–97% | 23.0 | 16.4 | 15.8 (n=30) | 617 | 178 | 80 | 1 |
| parallel | Direct | 14/32 (44%) | 28–61% | 27.5 | 22.0 | 12.0 (n=16) | 418 | 356 | 0 | 2 |
| parallel | Reasoning | 29/32 (91%) | 76–97% | 28.6 | 25.3 | 19.9 (n=31) | 416 | 366 | 210 | 1 |
| parallel | Adaptive | 29/32 (91%) | 76–97% | 31.0 | 30.6 | 23.0 (n=31) | 416 | 366 | 210 | 1 |
| parallel_multiple | Direct | 17/32 (53%) | 36–69% | 28.2 | 20.8 | 13.9 (n=25) | 662 | 266 | 0 | 2 |
| parallel_multiple | Reasoning | 22/32 (69%) | 51–82% | 35.3 | 34.6 | 27.6 (n=31) | 660 | 461 | 291 | 1 |
| parallel_multiple | Adaptive | 22/32 (69%) | 51–82% | 41.3 | 35.5 | 29.3 (n=31) | 660 | 461 | 291 | 1 |
| irrelevance | Direct | 24/32 (75%) | 58–87% | 32.8 | 16.3 | 4.8 (n=8) | 366 | 307 | 0 | 4 |
| irrelevance | Reasoning | 18/32 (56%) | 39–72% | 28.1 | 20.5 | 21.8 (n=14) | 364 | 394 | 274 | 4 |
| irrelevance | Adaptive | 21/32 (66%) | 48–80% | 28.3 | 19.6 | 13.9 (n=11) | 365 | 324 | 77 | 4 |

| Comparação pareada | Acerto | Latência |
|---|---|---|
| Adaptive − Reasoning | +0.6 pp (IC95 -2.5 a +3.8) | +1.7 s (IC95 -1.6 a +5.1) |
| Adaptive − Direct | +13.8 pp (IC95 +6.9 a +20.6) | +4.2 s (IC95 -0.6 a +8.3) |
| Reasoning − Direct | +13.1 pp (IC95 +5.6 a +21.2) | +2.5 s (IC95 -1.8 a +6.4) |

- **H1** (não inferioridade, margem −5 pp): **passa**.
- **H2** (Adaptive mais rápida que Reasoning): **não passa**.
- 1ª chamada, Adaptive − Reasoning: +0.6 s (IC95 -2.3 a +3.6).
- Tokens de saída, Adaptive − Reasoning (independe da térmica): -13 (IC95 -35 a +11).
- Decode médio (tok/s), para checar que o throttling pesou igual: Direct 23.5, Reasoning 19.6, Adaptive 19.5.
- Rotas: 121 → Reasoning, 39 → Direct; divergências com `FROZEN_POLICY.json`: 0.
- Complementaridade D × R: 96 ambas, 12 só Direct, 33 só Reasoning, 19 nenhuma; oracle 141/160; McNemar p = 0.002.
- Adaptive executada × simulada (rota aplicada às fixas): 160/160 vereditos e 160/160 contagens de tokens iguais; simulada 130 acertos, 27.0 s.
- Custo da decisão no iPhone: mediana 0.0062 ms, máximo 0.0372 ms (n = 160).
