# DAC — BFCL Multi-Turn, Qwen3.5-2B no iPhone 16 Pro

Rodadas: tqA, tqB; entradas: 32. Tempos em s por entrada (média sobre entradas × rodadas).

| Condição | n | Acerto (por rodada) | Tempo | TTFT/passo | Prefill | Decode | Overhead | Tok. entrada | Tok. prefill | Tok. saída | Passos | Loops ≥3 | Teto 1024 | Pico MB |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| Runtime atual (Reasoning 512, kv) | 32 | 8/32 | 83.0 | 3.16 | 26.4 | 47.9 | 8.0 | 69.0 mil | 6.92 mil | 1220 | 10.9 | 8 | 1 | 2052 |
| DACS + prefixo persistente (pilha completa) | 64 | 7/32 · 7/32 | 55.1 | 2.22 | 11.6 | 38.0 | 5.0 | 44.8 mil | 2.57 mil | 1046 | 7.9 | 5 | 2 | 2070 |

## Pareado contra `rt-base-kv` (entrada × rodada)

| Condição | pares | certa só aqui | certa só na ref. | p (McNemar, por entrada × rodada) | Δ tempo (s) | IC95% | Δ tempo (%) |
|---|---|---|---|---|---|---|---|
| DACS + prefixo persistente (pilha completa) | 32 | 1 | 2 | 1.00 | -20.8 | [-34.3; -10.0] | -25% |

## Mecanismos (soma sobre entradas × rodadas)

| Condição | Detecções (repetição/erro) | Recuperadas | Falharam → stop | Stops de A | Raciocínio fechado à força | Corte de chamada repetida | Caracteres de nota | KV reaproveitado (conv/turn/system/none) |
|---|---|---|---|---|---|---|---|---|
| Runtime atual (Reasoning 512, kv) | 0/0 | 0 | 0 | 0 | 5 | 0 | 0 | 277/36/35/0 |
| DACS + prefixo persistente (pilha completa) | 28/8 | 12 | 24 | 0 | 10 | 0 | 12206 | 280/126/74/0 |

## Por entrada (acertos nas rodadas · tempo médio s)

| Entrada | Runtime atual (Reasoning 512, kv) | DACS + prefixo persistente (pilha completa) |
|---|---|---|
| 4 | 0/1 · 90 (force_terminated) | 0/2 · 52 (instance_state_mismatch) |
| 7 | 0/1 · 96 (force_terminated) | 0/2 · 54 (instance_state_mismatch) |
| 12 | 0/1 · 65 (force_terminated) | 2/2 · 41 |
| 13 | 0/1 · 78 (force_terminated) | 0/2 · 27 (execution_response_mismatch) |
| 21 | 0/1 · 95 (force_terminated) | 0/2 · 53 (instance_state_mismatch) |
| 23 | 1/1 · 57 | 0/2 · 81 (instance_state_mismatch) |
| 29 | 0/1 · 41 (execution_response_mismatch) | 0/2 · 25 (execution_response_mismatch) |
| 30 | 0/1 · 111 (force_terminated) | 0/2 · 37 (execution_response_mismatch) |
| 37 | 0/1 · 106 (instance_state_mismatch) | 0/2 · 92 (instance_state_mismatch) |
| 42 | 0/1 · 92 (force_terminated) | 0/2 · 63 (instance_state_mismatch) |
| 47 | 0/1 · 52 (execution_response_mismatch) | 0/2 · 38 (execution_response_mismatch) |
| 50 | 0/1 · 45 (empty_turn_model_response) | 0/2 · 29 (empty_turn_model_response) |
| 57 | 1/1 · 73 | 2/2 · 54 |
| 78 | 0/1 · 56 (execution_response_mismatch) | 0/2 · 36 (execution_response_mismatch) |
| 100 | 0/1 · 51 (instance_state_mismatch) | 0/2 · 37 (instance_state_mismatch) |
| 101 | 1/1 · 60 | 2/2 · 46 |
| 104 | 0/1 · 50 (execution_response_mismatch) | 0/2 · 27 (execution_response_mismatch) |
| 113 | 1/1 · 47 | 2/2 · 31 |
| 115 | 1/1 · 65 | 2/2 · 55 |
| 120 | 0/1 · 73 (instance_state_mismatch) | 0/2 · 54 (instance_state_mismatch) |
| 132 | 0/1 · 86 (instance_state_mismatch) | 0/2 · 64 (instance_state_mismatch) |
| 133 | 0/1 · 54 (execution_response_mismatch) | 0/2 · 41 (execution_response_mismatch) |
| 139 | 1/1 · 48 | 2/2 · 34 |
| 144 | 0/1 · 54 (execution_response_mismatch) | 0/2 · 38 (execution_response_mismatch) |
| 147 | 0/1 · 59 (instance_state_mismatch) | 0/2 · 41 (instance_state_mismatch) |
| 150 | 0/1 · 66 (instance_state_mismatch) | 0/2 · 61 (instance_state_mismatch) |
| 158 | 1/1 · 105 | 2/2 · 97 |
| 159 | 0/1 · 270 (instance_state_mismatch) | 0/2 · 88 (instance_state_mismatch) |
| 160 | 0/1 · 97 (instance_state_mismatch) | 0/2 · 90 (instance_state_mismatch) |
| 161 | 1/1 · 179 | 0/2 · 115 (instance_state_mismatch) |
| 176 | 0/1 · 115 (instance_state_mismatch) | 0/2 · 65 (instance_state_mismatch) |
| 177 | 0/1 · 119 (instance_state_mismatch) | 0/2 · 97 (instance_state_mismatch) |

## Modos de falha (entradas × rodadas)

| Condição | force_terminated | instance_state_mismatch | execution_response_mismatch | empty_turn_model_response | outros |
|---|---|---|---|---|---|
| Runtime atual (Reasoning 512, kv) | 7 | 10 | 6 | 1 | 0 |
| DACS + prefixo persistente (pilha completa) | 0 | 32 | 16 | 2 | 0 |

Térmica ao fim de cada passo (todas as condições): {'nominal': 27, 'fair': 797, 'serious': 4}.

## Consistência contra a referência (chamadas e argumentos; texto final = TEXT)

- DACS + prefixo persistente (pilha completa): 20 trajetórias idênticas; 186/351 passos iguais antes da divergência.
