# DAC — BFCL Multi-Turn, Qwen3.5-2B no iPhone 16 Pro

Rodadas: sf1; entradas: 12. Tempos em s por entrada (média sobre entradas × rodadas).

| Condição | n | Acerto (por rodada) | Tempo | TTFT/passo | Prefill | Decode | Overhead | Tok. entrada | Tok. prefill | Tok. saída | Passos | Loops ≥3 | Teto 1024 | Pico MB |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| Runtime atual (Reasoning 512, kv) | 12 | 2/12 | 48.7 | 4.13 | 20.2 | 23.8 | 3.9 | 39.1 mil | 6.88 mil | 583 | 5.8 | 1 | 0 | 1853 |
| DACS + prefixo persistente (pilha completa) | 12 | 2/12 | 42.5 | 4.25 | 17.4 | 21.5 | 3.2 | 31.7 mil | 5.53 mil | 534 | 4.9 | 0 | 0 | 1853 |

## Pareado contra `rt-base-kv` (entrada × rodada)

| Condição | pares | certa só aqui | certa só na ref. | p (McNemar, por entrada × rodada) | Δ tempo (s) | IC95% | Δ tempo (%) |
|---|---|---|---|---|---|---|---|
| DACS + prefixo persistente (pilha completa) | 12 | 0 | 0 | 1.00 | -6.2 | [-17.4; +3.1] | -13% |

## Mecanismos (soma sobre entradas × rodadas)

| Condição | Detecções (repetição/erro) | Recuperadas | Falharam → stop | Stops de A | Raciocínio fechado à força | Corte de chamada repetida | Caracteres de nota | KV reaproveitado (conv/turn/system/none) |
|---|---|---|---|---|---|---|---|---|
| Runtime atual (Reasoning 512, kv) | 0/0 | 0 | 0 | 0 | 0 | 0 | 0 | 44/14/12/0 |
| DACS + prefixo persistente (pilha completa) | 0/1 | 0 | 1 | 0 | 0 | 0 | 331 | 31/15/12/0 |

## Por entrada (acertos nas rodadas · tempo médio s)

| Entrada | Runtime atual (Reasoning 512, kv) | DACS + prefixo persistente (pilha completa) |
|---|---|---|
| 11 | 0/1 · 30 (instance_state_mismatch) | 0/1 · 40 (instance_state_mismatch) |
| 45 | 0/1 · 96 (instance_state_mismatch) | 0/1 · 43 (instance_state_mismatch) |
| 46 | 0/1 · 19 (execution_response_mismatch) | 0/1 · 31 (execution_response_mismatch) |
| 76 | 0/1 · 36 (instance_state_mismatch) | 0/1 · 43 (instance_state_mismatch) |
| 91 | 0/1 · 32 (instance_state_mismatch) | 0/1 · 42 (instance_state_mismatch) |
| 124 | 0/1 · 43 (empty_turn_model_response) | 0/1 · 42 (empty_turn_model_response) |
| 155 | 0/1 · 52 (execution_response_mismatch) | 0/1 · 51 (execution_response_mismatch) |
| 157 | 1/1 · 57 | 1/1 · 56 |
| 163 | 0/1 · 65 (instance_state_mismatch) | 0/1 · 49 (instance_state_mismatch) |
| 169 | 0/1 · 66 (instance_state_mismatch) | 0/1 · 67 (instance_state_mismatch) |
| 182 | 1/1 · 28 | 1/1 · 17 |
| 197 | 0/1 · 60 (empty_turn_model_response) | 0/1 · 28 (empty_turn_model_response) |

## Modos de falha (entradas × rodadas)

| Condição | force_terminated | instance_state_mismatch | execution_response_mismatch | empty_turn_model_response | outros |
|---|---|---|---|---|---|
| Runtime atual (Reasoning 512, kv) | 0 | 6 | 2 | 2 | 0 |
| DACS + prefixo persistente (pilha completa) | 0 | 6 | 2 | 2 | 0 |

Térmica ao fim de cada passo (todas as condições): {'fair': 32, 'serious': 34, 'nominal': 62}.

## Consistência contra a referência (chamadas e argumentos; texto final = TEXT)

- DACS + prefixo persistente (pilha completa): 11 trajetórias idênticas; 56/70 passos iguais antes da divergência.
