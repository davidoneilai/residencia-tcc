# On-device adaptive pilot (iPhone 16 Pro)

## Setup
- Device: iPhone 16 Pro
- Trigger: `Documents/auto-run.json` → `{"run":"adaptive-pilot","taskLimit":8,"router":"heuristic"}`
- Mode: simulated tools; Qwen3-1.7B-4bit; strategy `adaptive`

## Pilot (8 tarefas, single_001–008)

| Métrica | Valor |
| --- | ---: |
| Sucesso | 7/8 = **0.875** |
| Latência total | 201 100 ms |
| Latência média | **25.1 s** |
| Overhead router (soma) | **2.5 ms** (~0.3 ms/tarefa) |

Escolhas: 7× `direct`, 1× `plan_act` (`sequential_or_contact` em `apple_single_008`).

## Full 60
Sessão iniciada após o piloto; resultados em `full60-session.json` quando `finished=true`.
