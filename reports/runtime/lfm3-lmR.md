# DAC — BFCL Multi-Turn, Qwen3.5-2B no iPhone 16 Pro

Rodadas: lmR; entradas: 12. Tempos em s por entrada (média sobre entradas × rodadas).

| Condição | n | Acerto (por rodada) | Tempo | TTFT/passo | Prefill | Decode | Overhead | Tok. entrada | Tok. prefill | Tok. saída | Passos | Loops ≥3 | Teto 1024 | Pico MB |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| Runtime atual (Reasoning 512, kv) | 12 | 6/12 | 89.5 | 3.15 | 21.6 | 62.6 | 4.9 | 51.5 mil | 6.45 mil | 2024 | 8.4 | 1 | 0 | 1556 |
| NoThink + kv | 12 | 5/12 | 48.9 | 2.24 | 22.2 | 20.1 | 5.9 | 80.9 mil | 6.73 mil | 693 | 12.6 | 5 | 0 | 1625 |

## Pareado contra `rt-base-kv` (entrada × rodada)

| Condição | pares | certa só aqui | certa só na ref. | p (McNemar, por entrada × rodada) | Δ tempo (s) | IC95% | Δ tempo (%) |
|---|---|---|---|---|---|---|---|
| NoThink + kv | 12 | 1 | 2 | 1.00 | -40.7 | [-67.7; -18.9] | -45% |

## Mecanismos (soma sobre entradas × rodadas)

| Condição | Detecções (repetição/erro) | Recuperadas | Falharam → stop | Stops de A | Raciocínio fechado à força | Corte de chamada repetida | Caracteres de nota | KV reaproveitado (conv/turn/system/none) |
|---|---|---|---|---|---|---|---|---|
| Runtime atual (Reasoning 512, kv) | 0/0 | 0 | 0 | 0 | 14 | 0 | 0 | 89/0/12/0 |
| NoThink + kv | 0/0 | 0 | 0 | 0 | 0 | 0 | 0 | 138/1/12/0 |

## Por entrada (acertos nas rodadas · tempo médio s)

| Entrada | Runtime atual (Reasoning 512, kv) | NoThink + kv |
|---|---|---|
| 11 | 0/1 · 77 (instance_state_mismatch) | 0/1 · 30 (force_terminated) |
| 45 | 0/1 · 91 (execution_response_mismatch) | 0/1 · 56 (execution_response_mismatch) |
| 46 | 0/1 · 159 (instance_state_mismatch) | 0/1 · 71 (instance_state_mismatch) |
| 76 | 0/1 · 99 (instance_state_mismatch) | 1/1 · 80 |
| 91 | 1/1 · 53 | 0/1 · 61 (instance_state_mismatch) |
| 124 | 1/1 · 52 | 1/1 · 37 |
| 155 | 0/1 · 36 (execution_response_mismatch) | 0/1 · 25 (execution_response_mismatch) |
| 157 | 1/1 · 66 | 1/1 · 44 |
| 163 | 1/1 · 102 | 1/1 · 30 |
| 169 | 1/1 · 70 | 0/1 · 53 (force_terminated) |
| 182 | 1/1 · 36 | 1/1 · 21 |
| 197 | 0/1 · 235 (instance_state_mismatch) | 0/1 · 78 (instance_state_mismatch) |

## Modos de falha (entradas × rodadas)

| Condição | force_terminated | instance_state_mismatch | execution_response_mismatch | empty_turn_model_response | outros |
|---|---|---|---|---|---|
| Runtime atual (Reasoning 512, kv) | 0 | 4 | 2 | 0 | 0 |
| NoThink + kv | 2 | 3 | 2 | 0 | 0 |

Térmica ao fim de cada passo (todas as condições): {'nominal': 24, 'fair': 225, 'serious': 3}.

## Consistência contra a referência (chamadas e argumentos; texto final = TEXT)

- NoThink + kv: 3 trajetórias idênticas; 23/160 passos iguais antes da divergência.
