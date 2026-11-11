# DAC — BFCL Multi-Turn, Qwen3.5-2B no iPhone 16 Pro

Rodadas: tmA, tmB; entradas: 32. Tempos em s por entrada (média sobre entradas × rodadas).

| Condição | n | Acerto (por rodada) | Tempo | TTFT/passo | Prefill | Decode | Overhead | Tok. entrada | Tok. prefill | Tok. saída | Passos | Loops ≥3 | Teto 1024 | Pico MB |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| NoThink + kv | 32 | 9/32 | 62.5 | 4.01 | 37.2 | 17.0 | 7.5 | 68.1 mil | 6.35 mil | 387 | 11.2 | 7 | 0 | 3035 |
| NoThink: DAC + repeat_guard + prefixo persistente | 64 | 9/32 · 9/32 | 36.5 | 2.30 | 14.4 | 12.2 | 4.9 | 48.4 mil | 2.05 mil | 294 | 8.7 | 2 | 0 | 3035 |

## Pareado contra `nt-base-kv` (entrada × rodada)

| Condição | pares | certa só aqui | certa só na ref. | p (McNemar, por entrada × rodada) | Δ tempo (s) | IC95% | Δ tempo (%) |
|---|---|---|---|---|---|---|---|
| NoThink: DAC + repeat_guard + prefixo persistente | 32 | 0 | 0 | 1.00 | -12.7 | [-30.4; +11.1] | -20% |

## Mecanismos (soma sobre entradas × rodadas)

| Condição | Detecções (repetição/erro) | Recuperadas | Falharam → stop | Stops de A | Raciocínio fechado à força | Corte de chamada repetida | Caracteres de nota | KV reaproveitado (conv/turn/system/none) |
|---|---|---|---|---|---|---|---|---|
| NoThink + kv | 0/0 | 0 | 0 | 0 | 0 | 0 | 0 | 324/0/33/0 |
| NoThink: DAC + repeat_guard + prefixo persistente | 0/0 | 0 | 0 | 0 | 0 | 0 | 0 | 472/0/66/0 |

## Por entrada (acertos nas rodadas · tempo médio s)

| Entrada | NoThink + kv | NoThink: DAC + repeat_guard + prefixo persistente |
|---|---|---|
| 4 | 0/1 · 53 (instance_state_mismatch) | 0/2 · 39 (instance_state_mismatch) |
| 7 | 1/1 · 57 | 2/2 · 18 |
| 12 | 1/1 · 39 | 2/2 · 24 |
| 13 | 1/1 · 53 | 2/2 · 22 |
| 21 | 0/1 · 65 (execution_response_mismatch) | 0/2 · 30 (execution_response_mismatch) |
| 23 | 0/1 · 57 (instance_state_mismatch) | 0/2 · 37 (instance_state_mismatch) |
| 29 | 0/1 · 35 (instance_state_mismatch) | 0/2 · 13 (instance_state_mismatch) |
| 30 | 0/1 · 131 (instance_state_mismatch) | 0/2 · 41 (instance_state_mismatch) |
| 37 | 0/1 · 67 (instance_state_mismatch) | 0/2 · 49 (instance_state_mismatch) |
| 42 | 1/1 · 64 | 2/2 · 39 |
| 47 | 0/1 · 79 (execution_response_mismatch) | 0/2 · 34 (execution_response_mismatch) |
| 50 | 0/1 · 42 (instance_state_mismatch) | 0/2 · 28 (instance_state_mismatch) |
| 57 | 0/1 · 67 (execution_response_mismatch) | 0/2 · 37 (execution_response_mismatch) |
| 78 | 0/1 · 69 (execution_response_mismatch) | 0/2 · 45 (execution_response_mismatch) |
| 100 | 0/1 · 43 (instance_state_mismatch) | 0/2 · 177 (instance_state_mismatch) |
| 101 | 1/1 · 34 | 2/2 · 26 |
| 104 | 1/1 · 30 | 2/2 · 18 |
| 113 | 1/1 · 43 | 2/2 · 19 |
| 115 | 0/1 · 73 (force_terminated) | 0/2 · 49 (execution_response_mismatch) |
| 120 | 0/1 · 54 (force_terminated) | 0/2 · 30 (instance_state_mismatch) |
| 132 | 0/1 · 26 (empty_turn_model_response) | 0/2 · 10 (empty_turn_model_response) |
| 133 | 1/1 · 36 | 2/2 · 23 |
| 139 | 1/1 · 43 | 2/2 · 28 |
| 144 | 0/1 · 178 (execution_response_mismatch) | 0/2 · 36 (execution_response_mismatch) |
| 147 | 0/1 · 74 (force_terminated) | 0/2 · 28 (instance_state_mismatch) |
| 150 | 0/1 · 36 (instance_state_mismatch) | 0/2 · 24 (instance_state_mismatch) |
| 158 | 0/1 · 81 (force_terminated) | 0/2 · 33 (instance_state_mismatch) |
| 159 | 0/1 · 47 (instance_state_mismatch) | 0/2 · 27 (instance_state_mismatch) |
| 160 | 0/1 · 60 (instance_state_mismatch) | 0/2 · 45 (instance_state_mismatch) |
| 161 | 0/1 · 60 (execution_response_mismatch) | 0/2 · 42 (execution_response_mismatch) |
| 176 | 0/1 · 99 (force_terminated) | 0/2 · 46 (instance_state_mismatch) |
| 177 | 0/1 · 102 (instance_state_mismatch) | 0/2 · 50 (instance_state_mismatch) |

## Modos de falha (entradas × rodadas)

| Condição | force_terminated | instance_state_mismatch | execution_response_mismatch | empty_turn_model_response | outros |
|---|---|---|---|---|---|
| NoThink + kv | 5 | 11 | 6 | 1 | 0 |
| NoThink: DAC + repeat_guard + prefixo persistente | 0 | 30 | 14 | 2 | 0 |

Térmica ao fim de cada passo (todas as condições): {'fair': 887, 'nominal': 8}.

## Consistência contra a referência (chamadas e argumentos; texto final = TEXT)

- NoThink: DAC + repeat_guard + prefixo persistente: 20 trajetórias idênticas; 217/360 passos iguais antes da divergência.
