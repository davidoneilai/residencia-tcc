# DAC — BFCL Multi-Turn, Qwen3.5-2B no iPhone 16 Pro

Rodadas: st1; entradas: 12. Tempos em s por entrada (média sobre entradas × rodadas).

| Condição | n | Acerto (por rodada) | Tempo | TTFT/passo | Prefill | Decode | Overhead | Tok. entrada | Tok. prefill | Tok. saída | Passos | Loops ≥3 | Teto 1024 | Pico MB |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| Runtime atual (Reasoning 512, kv) | 12 | 5/12 | 71.7 | 2.79 | 19.3 | 46.0 | 5.8 | 63.3 mil | 7.43 mil | 1520 | 9.0 | 3 | 0 | 1945 |
| + prefixo persistente | 12 | 5/12 | 64.9 | 1.96 | 11.9 | 46.7 | 5.7 | 63.3 mil | 3.44 mil | 1520 | 9.0 | 3 | 0 | 1944 |
| DAC + seletiva (guardas de decode) | 12 | 5/12 | 53.4 | 3.81 | 18.3 | 31.2 | 3.7 | 38.4 mil | 7.25 mil | 1048 | 5.8 | 0 | 0 | 1947 |
| DACS + prefixo persistente (pilha completa) | 12 | 5/12 | 46.4 | 2.48 | 10.4 | 31.8 | 3.9 | 38.4 mil | 3.20 mil | 1048 | 5.8 | 0 | 0 | 1946 |

## Pareado contra `rt-base-kv` (entrada × rodada)

| Condição | pares | certa só aqui | certa só na ref. | p (McNemar, por entrada × rodada) | Δ tempo (s) | IC95% | Δ tempo (%) |
|---|---|---|---|---|---|---|---|
| + prefixo persistente | 12 | 0 | 0 | 1.00 | -6.9 | [-15.6; +2.4] | -10% |
| DAC + seletiva (guardas de decode) | 12 | 0 | 0 | 1.00 | -18.3 | [-49.6; +1.5] | -26% |
| DACS + prefixo persistente (pilha completa) | 12 | 0 | 0 | 1.00 | -25.3 | [-56.9; -4.2] | -35% |

## Mecanismos (soma sobre entradas × rodadas)

| Condição | Detecções (repetição/erro) | Recuperadas | Falharam → stop | Stops de A | Raciocínio fechado à força | Corte de chamada repetida | Caracteres de nota | KV reaproveitado (conv/turn/system/none) |
|---|---|---|---|---|---|---|---|---|
| Runtime atual (Reasoning 512, kv) | 0/0 | 0 | 0 | 0 | 10 | 0 | 0 | 84/12/12/0 |
| + prefixo persistente | 0/0 | 0 | 0 | 0 | 10 | 0 | 0 | 84/12/12/0 |
| DAC + seletiva (guardas de decode) | 2/1 | 2 | 1 | 0 | 5 | 0 | 1163 | 40/17/12/0 |
| DACS + prefixo persistente (pilha completa) | 2/1 | 2 | 1 | 0 | 5 | 0 | 1163 | 40/17/12/0 |

## Por entrada (acertos nas rodadas · tempo médio s)

| Entrada | Runtime atual (Reasoning 512, kv) | + prefixo persistente | DAC + seletiva (guardas de decode) | DACS + prefixo persistente (pilha completa) |
|---|---|---|---|---|
| 11 | 0/1 · 37 (empty_turn_model_response) | 0/1 · 54 (empty_turn_model_response) | 0/1 · 34 (empty_turn_model_response) | 0/1 · 30 (empty_turn_model_response) |
| 45 | 0/1 · 86 (execution_response_mismatch) | 0/1 · 64 (execution_response_mismatch) | 0/1 · 42 (execution_response_mismatch) | 0/1 · 36 (execution_response_mismatch) |
| 46 | 0/1 · 45 (instance_state_mismatch) | 0/1 · 33 (instance_state_mismatch) | 0/1 · 26 (instance_state_mismatch) | 0/1 · 29 (instance_state_mismatch) |
| 76 | 0/1 · 45 (instance_state_mismatch) | 0/1 · 28 (instance_state_mismatch) | 0/1 · 60 (instance_state_mismatch) | 0/1 · 58 (instance_state_mismatch) |
| 91 | 1/1 · 35 | 1/1 · 47 | 1/1 · 35 | 1/1 · 26 |
| 124 | 1/1 · 44 | 1/1 · 45 | 1/1 · 45 | 1/1 · 42 |
| 155 | 0/1 · 44 (execution_response_mismatch) | 0/1 · 22 (execution_response_mismatch) | 0/1 · 47 (execution_response_mismatch) | 0/1 · 32 (execution_response_mismatch) |
| 157 | 1/1 · 42 | 1/1 · 36 | 1/1 · 42 | 1/1 · 51 |
| 163 | 1/1 · 69 | 1/1 · 38 | 1/1 · 69 | 1/1 · 38 |
| 169 | 0/1 · 77 (instance_state_mismatch) | 0/1 · 100 (instance_state_mismatch) | 0/1 · 81 (instance_state_mismatch) | 0/1 · 59 (instance_state_mismatch) |
| 182 | 1/1 · 42 | 1/1 · 30 | 1/1 · 41 | 1/1 · 41 |
| 197 | 0/1 · 293 (force_terminated) | 0/1 · 281 (force_terminated) | 0/1 · 119 (instance_state_mismatch) | 0/1 · 114 (instance_state_mismatch) |

## Modos de falha (entradas × rodadas)

| Condição | force_terminated | instance_state_mismatch | execution_response_mismatch | empty_turn_model_response | outros |
|---|---|---|---|---|---|
| Runtime atual (Reasoning 512, kv) | 1 | 3 | 2 | 1 | 0 |
| + prefixo persistente | 1 | 3 | 2 | 1 | 0 |
| DAC + seletiva (guardas de decode) | 0 | 4 | 2 | 1 | 0 |
| DACS + prefixo persistente (pilha completa) | 0 | 4 | 2 | 1 | 0 |

Térmica ao fim de cada passo (todas as condições): {'nominal': 109, 'fair': 71, 'serious': 174}.

## Consistência contra a referência (chamadas e argumentos; texto final = TEXT)

- + prefixo persistente: 12 trajetórias idênticas; 108/108 passos iguais antes da divergência.
- DAC + seletiva (guardas de decode): 9 trajetórias idênticas; 62/108 passos iguais antes da divergência.
- DACS + prefixo persistente (pilha completa): 9 trajetórias idênticas; 62/108 passos iguais antes da divergência.
