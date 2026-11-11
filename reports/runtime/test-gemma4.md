# DAC — BFCL Multi-Turn, Qwen3.5-2B no iPhone 16 Pro

Rodadas: tgA, tgB; entradas: 32. Tempos em s por entrada (média sobre entradas × rodadas).

| Condição | n | Acerto (por rodada) | Tempo | TTFT/passo | Prefill | Decode | Overhead | Tok. entrada | Tok. prefill | Tok. saída | Passos | Loops ≥3 | Teto 1024 | Pico MB |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| NoThink + kv | 32 | 2/32 | 16.0 | 1.95 | 7.5 | 6.8 | 1.5 | 17.2 mil | 3.86 mil | 183 | 4.6 | 0 | 0 | 3208 |
| NoThink: DAC + repeat_guard + prefixo persistente | 64 | 2/32 · 2/32 | 12.3 | 1.19 | 4.0 | 6.6 | 1.5 | 17.2 mil | 1.23 mil | 181 | 4.7 | 2 | 0 | 3207 |

## Pareado contra `nt-base-kv` (entrada × rodada)

| Condição | pares | certa só aqui | certa só na ref. | p (McNemar, por entrada × rodada) | Δ tempo (s) | IC95% | Δ tempo (%) |
|---|---|---|---|---|---|---|---|
| NoThink: DAC + repeat_guard + prefixo persistente | 32 | 0 | 0 | 1.00 | -2.4 | [-3.2; -1.5] | -15% |

## Mecanismos (soma sobre entradas × rodadas)

| Condição | Detecções (repetição/erro) | Recuperadas | Falharam → stop | Stops de A | Raciocínio fechado à força | Corte de chamada repetida | Caracteres de nota | KV reaproveitado (conv/turn/system/none) |
|---|---|---|---|---|---|---|---|---|
| NoThink + kv | 0/0 | 0 | 0 | 0 | 0 | 0 | 0 | 115/0/32/0 |
| NoThink: DAC + repeat_guard + prefixo persistente | 0/0 | 0 | 0 | 0 | 0 | 0 | 0 | 230/0/64/0 |

## Por entrada (acertos nas rodadas · tempo médio s)

| Entrada | NoThink + kv | NoThink: DAC + repeat_guard + prefixo persistente |
|---|---|---|
| 4 | 0/1 · 16 (execution_response_mismatch) | 0/2 · 11 (execution_response_mismatch) |
| 7 | 1/1 · 12 | 2/2 · 7 |
| 12 | 0/1 · 12 (instance_state_mismatch) | 0/2 · 10 (instance_state_mismatch) |
| 13 | 0/1 · 15 (execution_response_mismatch) | 0/2 · 9 (execution_response_mismatch) |
| 21 | 0/1 · 17 (instance_state_mismatch) | 0/2 · 11 (instance_state_mismatch) |
| 23 | 0/1 · 12 (instance_state_mismatch) | 0/2 · 9 (instance_state_mismatch) |
| 29 | 0/1 · 8 (empty_turn_model_response) | 0/2 · 5 (empty_turn_model_response) |
| 30 | 0/1 · 11 (execution_response_mismatch) | 0/2 · 5 (execution_response_mismatch) |
| 37 | 0/1 · 17 (execution_response_mismatch) | 0/2 · 13 (execution_response_mismatch) |
| 42 | 0/1 · 21 (instance_state_mismatch) | 0/2 · 17 (instance_state_mismatch) |
| 47 | 0/1 · 25 (empty_turn_model_response) | 0/2 · 19 (empty_turn_model_response) |
| 50 | 0/1 · 9 (instance_state_mismatch) | 0/2 · 6 (instance_state_mismatch) |
| 57 | 0/1 · 9 (empty_turn_model_response) | 0/2 · 6 (empty_turn_model_response) |
| 78 | 0/1 · 18 (instance_state_mismatch) | 0/2 · 15 (instance_state_mismatch) |
| 100 | 0/1 · 12 (instance_state_mismatch) | 0/2 · 11 (instance_state_mismatch) |
| 101 | 0/1 · 21 (execution_response_mismatch) | 0/2 · 16 (execution_response_mismatch) |
| 104 | 0/1 · 9 (execution_response_mismatch) | 0/2 · 6 (execution_response_mismatch) |
| 113 | 0/1 · 14 (instance_state_mismatch) | 0/2 · 9 (instance_state_mismatch) |
| 115 | 0/1 · 11 (execution_response_mismatch) | 0/2 · 8 (execution_response_mismatch) |
| 120 | 0/1 · 5 (empty_turn_model_response) | 0/2 · 3 (empty_turn_model_response) |
| 132 | 0/1 · 11 (empty_turn_model_response) | 0/2 · 9 (empty_turn_model_response) |
| 133 | 0/1 · 7 (empty_turn_model_response) | 0/2 · 4 (empty_turn_model_response) |
| 139 | 1/1 · 8 | 2/2 · 6 |
| 144 | 0/1 · 14 (execution_response_mismatch) | 0/2 · 13 (execution_response_mismatch) |
| 147 | 0/1 · 12 (empty_turn_model_response) | 0/2 · 7 (empty_turn_model_response) |
| 150 | 0/1 · 22 (empty_turn_model_response) | 0/2 · 19 (empty_turn_model_response) |
| 158 | 0/1 · 30 (instance_state_mismatch) | 0/2 · 26 (instance_state_mismatch) |
| 159 | 0/1 · 38 (empty_turn_model_response) | 0/2 · 33 (empty_turn_model_response) |
| 160 | 0/1 · 21 (instance_state_mismatch) | 0/2 · 19 (instance_state_mismatch) |
| 161 | 0/1 · 23 (execution_response_mismatch) | 0/2 · 19 (execution_response_mismatch) |
| 176 | 0/1 · 17 (instance_state_mismatch) | 0/2 · 11 (instance_state_mismatch) |
| 177 | 0/1 · 34 (empty_turn_model_response) | 0/2 · 28 (empty_turn_model_response) |

## Modos de falha (entradas × rodadas)

| Condição | force_terminated | instance_state_mismatch | execution_response_mismatch | empty_turn_model_response | outros |
|---|---|---|---|---|---|
| NoThink + kv | 0 | 11 | 9 | 10 | 0 |
| NoThink: DAC + repeat_guard + prefixo persistente | 0 | 22 | 18 | 20 | 0 |

Térmica ao fim de cada passo (todas as condições): {'fair': 441}.

## Consistência contra a referência (chamadas e argumentos; texto final = TEXT)

- NoThink: DAC + repeat_guard + prefixo persistente: 30 trajetórias idênticas; 140/149 passos iguais antes da divergência.
