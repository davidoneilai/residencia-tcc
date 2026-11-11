# DAC — BFCL Multi-Turn, Qwen3.5-2B no iPhone 16 Pro

Rodadas: st1, st2, st3; entradas: 12. Tempos em s por entrada (média sobre entradas × rodadas).

| Condição | n | Acerto (por rodada) | Tempo | TTFT/passo | Prefill | Decode | Overhead | Tok. entrada | Tok. prefill | Tok. saída | Passos | Loops ≥3 | Teto 1024 | Pico MB |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| Runtime atual (Reasoning 512, kv) | 36 | 5/12 · 5/12 · 5/12 | 74.6 | 2.97 | 20.9 | 47.3 | 5.9 | 63.3 mil | 7.43 mil | 1520 | 9.0 | 9 | 0 | 1945 |
| + prefixo persistente | 36 | 5/12 · 5/12 · 5/12 | 66.3 | 1.98 | 12.1 | 47.9 | 5.8 | 63.3 mil | 3.49 mil | 1520 | 9.0 | 9 | 0 | 1945 |
| DAC + seletiva (guardas de decode) | 36 | 5/12 · 5/12 · 5/12 | 56.3 | 4.00 | 19.2 | 32.7 | 3.8 | 38.4 mil | 7.25 mil | 1048 | 5.8 | 0 | 0 | 1947 |
| DACS + prefixo persistente (pilha completa) | 36 | 5/12 · 5/12 · 5/12 | 45.7 | 2.54 | 10.8 | 30.7 | 3.8 | 38.4 mil | 3.51 mil | 1048 | 5.8 | 0 | 0 | 1946 |

## Pareado contra `rt-base-kv` (entrada × rodada)

| Condição | pares | certa só aqui | certa só na ref. | p (McNemar, por entrada × rodada) | Δ tempo (s) | IC95% | Δ tempo (%) |
|---|---|---|---|---|---|---|---|
| + prefixo persistente | 36 | 0 | 0 | 1.00 | -8.3 | [-13.6; -2.3] | -11% |
| DAC + seletiva (guardas de decode) | 36 | 0 | 0 | 1.00 | -18.3 | [-35.5; -4.8] | -25% |
| DACS + prefixo persistente (pilha completa) | 36 | 0 | 0 | 1.00 | -28.9 | [-47.7; -14.0] | -39% |

## Mecanismos (soma sobre entradas × rodadas)

| Condição | Detecções (repetição/erro) | Recuperadas | Falharam → stop | Stops de A | Raciocínio fechado à força | Corte de chamada repetida | Caracteres de nota | KV reaproveitado (conv/turn/system/none) |
|---|---|---|---|---|---|---|---|---|
| Runtime atual (Reasoning 512, kv) | 0/0 | 0 | 0 | 0 | 30 | 0 | 0 | 252/36/36/0 |
| + prefixo persistente | 0/0 | 0 | 0 | 0 | 30 | 0 | 0 | 252/36/36/0 |
| DAC + seletiva (guardas de decode) | 6/3 | 6 | 3 | 0 | 15 | 0 | 3489 | 120/51/36/0 |
| DACS + prefixo persistente (pilha completa) | 6/3 | 6 | 3 | 0 | 15 | 0 | 3489 | 120/51/36/0 |

## Por entrada (acertos nas rodadas · tempo médio s)

| Entrada | Runtime atual (Reasoning 512, kv) | + prefixo persistente | DAC + seletiva (guardas de decode) | DACS + prefixo persistente (pilha completa) |
|---|---|---|---|---|
| 11 | 0/3 · 37 (empty_turn_model_response) | 0/3 · 37 (empty_turn_model_response) | 0/3 · 40 (empty_turn_model_response) | 0/3 · 33 (empty_turn_model_response) |
| 45 | 0/3 · 90 (execution_response_mismatch) | 0/3 · 69 (execution_response_mismatch) | 0/3 · 42 (execution_response_mismatch) | 0/3 · 46 (execution_response_mismatch) |
| 46 | 0/3 · 52 (instance_state_mismatch) | 0/3 · 37 (instance_state_mismatch) | 0/3 · 31 (instance_state_mismatch) | 0/3 · 24 (instance_state_mismatch) |
| 76 | 0/3 · 52 (instance_state_mismatch) | 0/3 · 47 (instance_state_mismatch) | 0/3 · 53 (instance_state_mismatch) | 0/3 · 39 (instance_state_mismatch) |
| 91 | 3/3 · 35 | 3/3 · 42 | 3/3 · 36 | 3/3 · 36 |
| 124 | 3/3 · 56 | 3/3 · 35 | 3/3 · 54 | 3/3 · 44 |
| 155 | 0/3 · 41 (execution_response_mismatch) | 0/3 · 33 (execution_response_mismatch) | 0/3 · 42 (execution_response_mismatch) | 0/3 · 35 (execution_response_mismatch) |
| 157 | 3/3 · 53 | 3/3 · 48 | 3/3 · 48 | 3/3 · 41 |
| 163 | 3/3 · 68 | 3/3 · 44 | 3/3 · 69 | 3/3 · 43 |
| 169 | 0/3 · 77 (instance_state_mismatch) | 0/3 · 73 (instance_state_mismatch) | 0/3 · 82 (instance_state_mismatch) | 0/3 · 72 (instance_state_mismatch) |
| 182 | 3/3 · 45 | 3/3 · 30 | 3/3 · 51 | 3/3 · 34 |
| 197 | 0/3 · 289 (force_terminated) | 0/3 · 300 (force_terminated) | 0/3 · 127 (instance_state_mismatch) | 0/3 · 102 (instance_state_mismatch) |

## Modos de falha (entradas × rodadas)

| Condição | force_terminated | instance_state_mismatch | execution_response_mismatch | empty_turn_model_response | outros |
|---|---|---|---|---|---|
| Runtime atual (Reasoning 512, kv) | 3 | 9 | 6 | 3 | 0 |
| + prefixo persistente | 3 | 9 | 6 | 3 | 0 |
| DAC + seletiva (guardas de decode) | 0 | 12 | 6 | 3 | 0 |
| DACS + prefixo persistente (pilha completa) | 0 | 12 | 6 | 3 | 0 |

Térmica ao fim de cada passo (todas as condições): {'nominal': 286, 'fair': 243, 'serious': 533}.

## Consistência contra a referência (chamadas e argumentos; texto final = TEXT)

- + prefixo persistente: 36 trajetórias idênticas; 324/324 passos iguais antes da divergência.
- DAC + seletiva (guardas de decode): 27 trajetórias idênticas; 186/324 passos iguais antes da divergência.
- DACS + prefixo persistente (pilha completa): 27 trajetórias idênticas; 186/324 passos iguais antes da divergência.
