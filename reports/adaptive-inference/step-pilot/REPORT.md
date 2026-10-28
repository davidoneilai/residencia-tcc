# AdaptiveStep — piloto Think Fast and Slow (sem treino)

Exploratório. 12 tarefas inéditas (`apple_step_pilot_12`), fora do held-out 90 e do residency-60.
Sessão `DC484191-AD4D-4407-9339-4D955839D7E9` · 48/48 · `finished: true`.
Qwen3-1.7B-4bit, iPhone 16 Pro, greedy, prefix KV, simulado, 1 rep.
Térmica: 41/48 em `proceed_hot` (`serious`); 7 em `ready`. Freeze v3 intocado.

## Limitações do backend (verificadas no código)

- `enable_thinking` é por chamada em `generate`; AdaptiveStep pode ligar/desligar thinking entre rodadas.
- O prefixo KV é chaveado por `thinking` (`qwen|<bool>|<catalog>`). Alternar reconstrói o prefixo estático uma vez por modo; o sufixo continua em cache.
- `budget_64` e o modo slow do AdaptiveStep usam `think()` (s1): um passe de raciocínio e outro de resposta. Isso aparece em `repeatedPrefillMs`.
- Erro de ferramenta que lança aborta o loop antes da próxima decisão (mesma limitação do P3).

## Resultados

| Política | Sucesso | Latência (s) | Tokens | length | no_tool | seq | overhead (ms) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| direct | 0.583 (7/12) | 27.6 | 551 | 4 | 4 | 0.250 | 0.02 |
| nothink | 0.750 (9/12) | 6.3 | 64 | 0 | 0 | 0.500 | 0.02 |
| budget_64 | 0.500 (6/12) | 18.7 | 315 | 0 | 0 | 0.250 | 0.03 |
| adaptive_step | 0.750 (9/12) | 13.9 | 152 | 0 | 0 | 0.500 | 0.52 |

Por categoria (sucesso): Direct 4/4 · 2/4 · 1/4; NoThink 3/4 · 4/4 · 2/4; Budget64 3/4 · 2/4 · 1/4; AdaptiveStep 4/4 · 3/4 · 2/4 (single / multi / sequential).

Melhor fixa por sucesso: **nothink** (0.750, 6.3 s).
AdaptiveStep empatou o sucesso (9/12) e foi **2,2× mais lento**. Não há benefício real sobre a melhor estratégia fixa.

Vs Direct, AdaptiveStep ganha: +16,7 pp, −50% latência, `length`/`no_tool` 4→0. Esse ganho é o de desligar thinking, não o de adaptar por etapa — NoThink já entrega o mesmo sucesso mais barato.

Complementaridade AdaptiveStep vs NoThink (1 tarefa cada): Adaptive acerta `step_single_001` (NoThink erra); NoThink acerta `step_multi_004` (Adaptive erra). Sequential: os dois 2/4, mesmos IDs (`seq_002`, `seq_003`). `seq_001` e `seq_004` falham nas quatro políticas.

A política rodou: sequential/multi começaram em `slow`, contato encontrado foi para `fast:unresolved_dependency`, single curto em `fast:short_single`. Depois de concluir a ferramenta, o loop ainda gasta as 4 rodadas em `fast:default` — isso infla latência e tokens frente ao NoThink.

Artefatos: `selection.json`, `step-pilot-session.json`, `summary.json`. Preset `adaptive-step-pilot`.

