# DAC — BFCL Multi-Turn, Qwen3.5-2B no iPhone 16 Pro

Rodadas: qpA, qpB; entradas: 12. Tempos em s por entrada (média sobre entradas × rodadas).

| Condição | n | Acerto (por rodada) | Tempo | TTFT/passo | Prefill | Decode | Overhead | Tok. entrada | Tok. prefill | Tok. saída | Passos | Loops ≥3 | Teto 1024 | Pico MB |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| Runtime atual (Reasoning 512, kv) | 12 | 5/12 | 95.1 | 3.93 | 28.0 | 59.0 | 7.4 | 63.3 mil | 7.43 mil | 1520 | 9.0 | 3 | 0 | 1945 |
| DACS + prefixo persistente (pilha completa) | 24 | 5/12 · 5/12 | 63.2 | 3.24 | 14.0 | 44.2 | 4.6 | 38.4 mil | 3.50 mil | 1048 | 5.8 | 0 | 0 | 1946 |

## Pareado contra `rt-base-kv` (entrada × rodada)

| Condição | pares | certa só aqui | certa só na ref. | p (McNemar, por entrada × rodada) | Δ tempo (s) | IC95% | Δ tempo (%) |
|---|---|---|---|---|---|---|---|
| DACS + prefixo persistente (pilha completa) | 12 | 0 | 0 | 1.00 | -23.0 | [-48.3; -5.8] | -24% |

## Mecanismos (soma sobre entradas × rodadas)

| Condição | Detecções (repetição/erro) | Recuperadas | Falharam → stop | Stops de A | Raciocínio fechado à força | Corte de chamada repetida | Caracteres de nota | KV reaproveitado (conv/turn/system/none) |
|---|---|---|---|---|---|---|---|---|
| Runtime atual (Reasoning 512, kv) | 0/0 | 0 | 0 | 0 | 10 | 0 | 0 | 84/12/12/0 |
| DACS + prefixo persistente (pilha completa) | 4/2 | 4 | 2 | 0 | 10 | 0 | 2326 | 80/34/24/0 |

## Por entrada (acertos nas rodadas · tempo médio s)

| Entrada | Runtime atual (Reasoning 512, kv) | DACS + prefixo persistente (pilha completa) |
|---|---|---|
| 11 | 0/1 · 53 (empty_turn_model_response) | 0/2 · 41 (empty_turn_model_response) |
| 45 | 0/1 · 121 (execution_response_mismatch) | 0/2 · 54 (execution_response_mismatch) |
| 46 | 0/1 · 66 (instance_state_mismatch) | 0/2 · 29 (instance_state_mismatch) |
| 76 | 0/1 · 76 (instance_state_mismatch) | 0/2 · 56 (instance_state_mismatch) |
| 91 | 1/1 · 57 | 2/2 · 46 |
| 124 | 1/1 · 71 | 2/2 · 58 |
| 155 | 0/1 · 55 (execution_response_mismatch) | 0/2 · 45 (execution_response_mismatch) |
| 157 | 1/1 · 80 | 2/2 · 51 |
| 163 | 1/1 · 84 | 2/2 · 70 |
| 169 | 0/1 · 115 (instance_state_mismatch) | 0/2 · 104 (instance_state_mismatch) |
| 182 | 1/1 · 66 | 2/2 · 53 |
| 197 | 0/1 · 298 (force_terminated) | 0/2 · 151 (instance_state_mismatch) |

## Modos de falha (entradas × rodadas)

| Condição | force_terminated | instance_state_mismatch | execution_response_mismatch | empty_turn_model_response | outros |
|---|---|---|---|---|---|
| Runtime atual (Reasoning 512, kv) | 1 | 3 | 2 | 1 | 0 |
| DACS + prefixo persistente (pilha completa) | 0 | 8 | 4 | 2 | 0 |

Térmica ao fim de cada passo (todas as condições): {'fair': 246}.

## Consistência contra a referência (chamadas e argumentos; texto final = TEXT)

- DACS + prefixo persistente (pilha completa): 9 trajetórias idênticas; 62/108 passos iguais antes da divergência.
