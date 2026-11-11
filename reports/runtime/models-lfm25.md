# DAC — BFCL Multi-Turn, Qwen3.5-2B no iPhone 16 Pro

Rodadas: lfA, lfB; entradas: 12. Tempos em s por entrada (média sobre entradas × rodadas).

| Condição | n | Acerto (por rodada) | Tempo | TTFT/passo | Prefill | Decode | Overhead | Tok. entrada | Tok. prefill | Tok. saída | Passos | Loops ≥3 | Teto 1024 | Pico MB |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| Runtime atual (Reasoning 512, kv) | 12 | 2/12 | 283.5 | 4.38 | 40.4 | 234.1 | 6.4 | 70.2 mil | 6.89 mil | 4533 | 10.7 | 2 | 2 | 2529 |
| DACS + prefixo persistente (pilha completa) | 24 | 1/12 · 1/12 | 155.4 | 6.35 | 38.7 | 110.7 | 4.2 | 43.3 mil | 6.63 mil | 2183 | 7.5 | 0 | 0 | 2361 |

## Pareado contra `rt-base-kv` (entrada × rodada)

| Condição | pares | certa só aqui | certa só na ref. | p (McNemar, por entrada × rodada) | Δ tempo (s) | IC95% | Δ tempo (%) |
|---|---|---|---|---|---|---|---|
| DACS + prefixo persistente (pilha completa) | 12 | 0 | 1 | 1.00 | -131.3 | [-226.0; -44.2] | -46% |

## Mecanismos (soma sobre entradas × rodadas)

| Condição | Detecções (repetição/erro) | Recuperadas | Falharam → stop | Stops de A | Raciocínio fechado à força | Corte de chamada repetida | Caracteres de nota | KV reaproveitado (conv/turn/system/none) |
|---|---|---|---|---|---|---|---|---|
| Runtime atual (Reasoning 512, kv) | 0/0 | 0 | 0 | 0 | 54 | 0 | 0 | 116/0/12/0 |
| DACS + prefixo persistente (pilha completa) | 16/6 | 4 | 18 | 0 | 26 | 0 | 8790 | 138/0/24/0 |

## Por entrada (acertos nas rodadas · tempo médio s)

| Entrada | Runtime atual (Reasoning 512, kv) | DACS + prefixo persistente (pilha completa) |
|---|---|---|
| 11 | 0/1 · 87 (instance_state_mismatch) | 0/2 · 99 (instance_state_mismatch) |
| 45 | 0/1 · 169 (execution_response_mismatch) | 0/2 · 174 (execution_response_mismatch) |
| 46 | 1/1 · 294 | 0/2 · 133 (instance_state_mismatch) |
| 76 | 0/1 · 495 (instance_state_mismatch) | 0/2 · 123 (instance_state_mismatch) |
| 91 | 0/1 · 108 (instance_state_mismatch) | 0/2 · 104 (instance_state_mismatch) |
| 124 | 0/1 · 601 (instance_state_mismatch) | 0/2 · 253 (instance_state_mismatch) |
| 155 | 0/1 · 459 (execution_response_mismatch) | 0/2 · 130 (execution_response_mismatch) |
| 157 | 0/1 · 152 (execution_response_mismatch) | 0/2 · 161 (execution_response_mismatch) |
| 163 | 0/1 · 147 (instance_state_mismatch) | 0/2 · 130 (instance_state_mismatch) |
| 169 | 0/1 · 225 (execution_response_mismatch) | 0/2 · 245 (execution_response_mismatch) |
| 182 | 1/1 · 72 | 2/2 · 67 |
| 197 | 0/1 · 594 (instance_state_mismatch) | 0/2 · 246 (instance_state_mismatch) |

## Modos de falha (entradas × rodadas)

| Condição | force_terminated | instance_state_mismatch | execution_response_mismatch | empty_turn_model_response | outros |
|---|---|---|---|---|---|
| Runtime atual (Reasoning 512, kv) | 0 | 6 | 4 | 0 | 0 |
| DACS + prefixo persistente (pilha completa) | 0 | 14 | 8 | 0 | 0 |

Térmica ao fim de cada passo (todas as condições): {'fair': 287, 'serious': 3}.

## Consistência contra a referência (chamadas e argumentos; texto final = TEXT)

- DACS + prefixo persistente (pilha completa): 5 trajetórias idênticas; 57/130 passos iguais antes da divergência.
