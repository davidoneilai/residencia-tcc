# DAC — BFCL Multi-Turn, Qwen3.5-2B no iPhone 16 Pro

Rodadas: st2, st3; entradas: 12. Tempos em s por entrada (média sobre entradas × rodadas).

| Condição | n | Acerto (por rodada) | Tempo | TTFT/passo | Prefill | Decode | Overhead | Tok. entrada | Tok. prefill | Tok. saída | Passos | Loops ≥3 | Teto 1024 | Pico MB |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| Runtime atual (Reasoning 512, kv) | 24 | 5/12 · 5/12 | 76.1 | 3.06 | 21.6 | 47.9 | 5.9 | 63.3 mil | 7.43 mil | 1520 | 9.0 | 6 | 0 | 1945 |
| + prefixo persistente | 24 | 5/12 · 5/12 | 67.0 | 2.00 | 12.2 | 48.5 | 5.8 | 63.3 mil | 3.51 mil | 1520 | 9.0 | 6 | 0 | 1945 |
| DAC + seletiva (guardas de decode) | 24 | 5/12 · 5/12 | 57.8 | 4.09 | 19.7 | 33.5 | 3.8 | 38.4 mil | 7.25 mil | 1048 | 5.8 | 0 | 0 | 1947 |
| DACS + prefixo persistente (pilha completa) | 24 | 5/12 · 5/12 | 45.3 | 2.57 | 11.0 | 30.2 | 3.8 | 38.4 mil | 3.67 mil | 1048 | 5.8 | 0 | 0 | 1946 |

## Pareado contra `rt-base-kv` (entrada × rodada)

| Condição | pares | certa só aqui | certa só na ref. | p (McNemar, por entrada × rodada) | Δ tempo (s) | IC95% | Δ tempo (%) |
|---|---|---|---|---|---|---|---|
| + prefixo persistente | 24 | 0 | 0 | 1.00 | -9.0 | [-15.4; -1.4] | -12% |
| DAC + seletiva (guardas de decode) | 24 | 0 | 0 | 1.00 | -18.3 | [-38.4; -2.8] | -24% |
| DACS + prefixo persistente (pilha completa) | 24 | 0 | 0 | 1.00 | -30.7 | [-53.6; -13.3] | -40% |

## Mecanismos (soma sobre entradas × rodadas)

| Condição | Detecções (repetição/erro) | Recuperadas | Falharam → stop | Stops de A | Raciocínio fechado à força | Corte de chamada repetida | Caracteres de nota | KV reaproveitado (conv/turn/system/none) |
|---|---|---|---|---|---|---|---|---|
| Runtime atual (Reasoning 512, kv) | 0/0 | 0 | 0 | 0 | 20 | 0 | 0 | 168/24/24/0 |
| + prefixo persistente | 0/0 | 0 | 0 | 0 | 20 | 0 | 0 | 168/24/24/0 |
| DAC + seletiva (guardas de decode) | 4/2 | 4 | 2 | 0 | 10 | 0 | 2326 | 80/34/24/0 |
| DACS + prefixo persistente (pilha completa) | 4/2 | 4 | 2 | 0 | 10 | 0 | 2326 | 80/34/24/0 |

## Por entrada (acertos nas rodadas · tempo médio s)

| Entrada | Runtime atual (Reasoning 512, kv) | + prefixo persistente | DAC + seletiva (guardas de decode) | DACS + prefixo persistente (pilha completa) |
|---|---|---|---|---|
| 11 | 0/2 · 37 (empty_turn_model_response) | 0/2 · 29 (empty_turn_model_response) | 0/2 · 43 (empty_turn_model_response) | 0/2 · 34 (empty_turn_model_response) |
| 45 | 0/2 · 92 (execution_response_mismatch) | 0/2 · 71 (execution_response_mismatch) | 0/2 · 42 (execution_response_mismatch) | 0/2 · 50 (execution_response_mismatch) |
| 46 | 0/2 · 56 (instance_state_mismatch) | 0/2 · 39 (instance_state_mismatch) | 0/2 · 34 (instance_state_mismatch) | 0/2 · 21 (instance_state_mismatch) |
| 76 | 0/2 · 55 (instance_state_mismatch) | 0/2 · 56 (instance_state_mismatch) | 0/2 · 49 (instance_state_mismatch) | 0/2 · 29 (instance_state_mismatch) |
| 91 | 2/2 · 36 | 2/2 · 39 | 2/2 · 36 | 2/2 · 41 |
| 124 | 2/2 · 62 | 2/2 · 30 | 2/2 · 59 | 2/2 · 44 |
| 155 | 0/2 · 39 (execution_response_mismatch) | 0/2 · 38 (execution_response_mismatch) | 0/2 · 40 (execution_response_mismatch) | 0/2 · 37 (execution_response_mismatch) |
| 157 | 2/2 · 59 | 2/2 · 54 | 2/2 · 51 | 2/2 · 36 |
| 163 | 2/2 · 67 | 2/2 · 47 | 2/2 · 69 | 2/2 · 46 |
| 169 | 0/2 · 77 (instance_state_mismatch) | 0/2 · 60 (instance_state_mismatch) | 0/2 · 82 (instance_state_mismatch) | 0/2 · 79 (instance_state_mismatch) |
| 182 | 2/2 · 46 | 2/2 · 30 | 2/2 · 56 | 2/2 · 30 |
| 197 | 0/2 · 288 (force_terminated) | 0/2 · 310 (force_terminated) | 0/2 · 131 (instance_state_mismatch) | 0/2 · 96 (instance_state_mismatch) |

## Modos de falha (entradas × rodadas)

| Condição | force_terminated | instance_state_mismatch | execution_response_mismatch | empty_turn_model_response | outros |
|---|---|---|---|---|---|
| Runtime atual (Reasoning 512, kv) | 2 | 6 | 4 | 2 | 0 |
| + prefixo persistente | 2 | 6 | 4 | 2 | 0 |
| DAC + seletiva (guardas de decode) | 0 | 8 | 4 | 2 | 0 |
| DACS + prefixo persistente (pilha completa) | 0 | 8 | 4 | 2 | 0 |

Térmica ao fim de cada passo (todas as condições): {'fair': 172, 'serious': 359, 'nominal': 177}.

## Consistência contra a referência (chamadas e argumentos; texto final = TEXT)

- + prefixo persistente: 24 trajetórias idênticas; 216/216 passos iguais antes da divergência.
- DAC + seletiva (guardas de decode): 18 trajetórias idênticas; 124/216 passos iguais antes da divergência.
- DACS + prefixo persistente (pilha completa): 18 trajetórias idênticas; 124/216 passos iguais antes da divergência.
