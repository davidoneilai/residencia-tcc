# DAC — BFCL Multi-Turn, Qwen3.5-2B no iPhone 16 Pro

Rodadas: qnA, qnB; entradas: 12. Tempos em s por entrada (média sobre entradas × rodadas).

| Condição | n | Acerto (por rodada) | Tempo | TTFT/passo | Prefill | Decode | Overhead | Tok. entrada | Tok. prefill | Tok. saída | Passos | Loops ≥3 | Teto 1024 | Pico MB |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| Runtime atual (Reasoning 512, kv) | 12 | 4/12 | 92.2 | 3.00 | 27.7 | 54.8 | 8.8 | 83.9 mil | 7.48 mil | 1569 | 12.2 | 4 | 0 | 1994 |
| DACS + prefixo persistente (pilha completa) | 24 | 4/12 · 4/12 | 56.9 | 2.83 | 13.6 | 38.6 | 4.3 | 42.2 mil | 3.43 mil | 1140 | 6.5 | 0 | 2 | 2056 |

## Pareado contra `rt-base-kv` (entrada × rodada)

| Condição | pares | certa só aqui | certa só na ref. | p (McNemar, por entrada × rodada) | Δ tempo (s) | IC95% | Δ tempo (%) |
|---|---|---|---|---|---|---|---|
| DACS + prefixo persistente (pilha completa) | 12 | 0 | 0 | 1.00 | -27.1 | [-49.3; -7.5] | -29% |

## Mecanismos (soma sobre entradas × rodadas)

| Condição | Detecções (repetição/erro) | Recuperadas | Falharam → stop | Stops de A | Raciocínio fechado à força | Corte de chamada repetida | Caracteres de nota | KV reaproveitado (conv/turn/system/none) |
|---|---|---|---|---|---|---|---|---|
| Runtime atual (Reasoning 512, kv) | 0/0 | 0 | 0 | 0 | 4 | 0 | 0 | 125/9/12/0 |
| DACS + prefixo persistente (pilha completa) | 14/2 | 12 | 4 | 0 | 8 | 0 | 5390 | 84/44/24/0 |

## Por entrada (acertos nas rodadas · tempo médio s)

| Entrada | Runtime atual (Reasoning 512, kv) | DACS + prefixo persistente (pilha completa) |
|---|---|---|
| 11 | 0/1 · 113 (force_terminated) | 0/2 · 49 (empty_turn_model_response) |
| 45 | 0/1 · 118 (force_terminated) | 0/2 · 65 (execution_response_mismatch) |
| 46 | 0/1 · 92 (execution_response_mismatch) | 0/2 · 29 (instance_state_mismatch) |
| 76 | 0/1 · 63 (instance_state_mismatch) | 0/2 · 50 (instance_state_mismatch) |
| 91 | 1/1 · 56 | 2/2 · 45 |
| 124 | 1/1 · 57 | 2/2 · 49 |
| 155 | 0/1 · 43 (execution_response_mismatch) | 0/2 · 38 (execution_response_mismatch) |
| 157 | 1/1 · 56 | 2/2 · 46 |
| 163 | 0/1 · 181 (force_terminated) | 0/2 · 100 (instance_state_mismatch) |
| 169 | 0/1 · 67 (instance_state_mismatch) | 0/2 · 74 (instance_state_mismatch) |
| 182 | 1/1 · 62 | 2/2 · 44 |
| 197 | 0/1 · 198 (force_terminated) | 0/2 · 93 (instance_state_mismatch) |

## Modos de falha (entradas × rodadas)

| Condição | force_terminated | instance_state_mismatch | execution_response_mismatch | empty_turn_model_response | outros |
|---|---|---|---|---|---|
| Runtime atual (Reasoning 512, kv) | 4 | 2 | 2 | 0 | 0 |
| DACS + prefixo persistente (pilha completa) | 0 | 10 | 4 | 2 | 0 |

Térmica ao fim de cada passo (todas as condições): {'fair': 298}.

## Consistência contra a referência (chamadas e argumentos; texto final = TEXT)

- DACS + prefixo persistente (pilha completa): 5 trajetórias idênticas; 53/147 passos iguais antes da divergência.
