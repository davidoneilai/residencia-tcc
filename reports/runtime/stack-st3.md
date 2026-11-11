# DAC — BFCL Multi-Turn, Qwen3.5-2B no iPhone 16 Pro

Rodadas: st3; entradas: 12. Tempos em s por entrada (média sobre entradas × rodadas).

| Condição | n | Acerto (por rodada) | Tempo | TTFT/passo | Prefill | Decode | Overhead | Tok. entrada | Tok. prefill | Tok. saída | Passos | Loops ≥3 | Teto 1024 | Pico MB |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| Runtime atual (Reasoning 512, kv) | 12 | 5/12 | 77.3 | 3.15 | 22.5 | 48.4 | 5.9 | 63.3 mil | 7.43 mil | 1520 | 9.0 | 3 | 0 | 1945 |
| + prefixo persistente | 12 | 5/12 | 71.8 | 2.11 | 13.1 | 52.3 | 6.0 | 63.3 mil | 3.38 mil | 1520 | 9.0 | 3 | 0 | 1945 |
| DAC + seletiva (guardas de decode) | 12 | 5/12 | 60.7 | 4.29 | 20.8 | 35.5 | 3.9 | 38.4 mil | 7.25 mil | 1048 | 5.8 | 0 | 0 | 1947 |
| DACS + prefixo persistente (pilha completa) | 12 | 5/12 | 46.6 | 2.66 | 11.5 | 30.9 | 3.8 | 38.4 mil | 3.81 mil | 1048 | 5.8 | 0 | 0 | 1946 |

## Pareado contra `rt-base-kv` (entrada × rodada)

| Condição | pares | certa só aqui | certa só na ref. | p (McNemar, por entrada × rodada) | Δ tempo (s) | IC95% | Δ tempo (%) |
|---|---|---|---|---|---|---|---|
| + prefixo persistente | 12 | 0 | 0 | 1.00 | -5.4 | [-15.5; +7.6] | -7% |
| DAC + seletiva (guardas de decode) | 12 | 0 | 0 | 1.00 | -16.5 | [-42.3; +1.8] | -21% |
| DACS + prefixo persistente (pilha completa) | 12 | 0 | 0 | 1.00 | -30.7 | [-64.6; -6.5] | -40% |

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
| 11 | 0/1 · 34 (empty_turn_model_response) | 0/1 · 24 (empty_turn_model_response) | 0/1 · 39 (empty_turn_model_response) | 0/1 · 48 (empty_turn_model_response) |
| 45 | 0/1 · 98 (execution_response_mismatch) | 0/1 · 71 (execution_response_mismatch) | 0/1 · 42 (execution_response_mismatch) | 0/1 · 42 (execution_response_mismatch) |
| 46 | 0/1 · 58 (instance_state_mismatch) | 0/1 · 45 (instance_state_mismatch) | 0/1 · 37 (instance_state_mismatch) | 0/1 · 16 (instance_state_mismatch) |
| 76 | 0/1 · 65 (instance_state_mismatch) | 0/1 · 61 (instance_state_mismatch) | 0/1 · 51 (instance_state_mismatch) | 0/1 · 29 (instance_state_mismatch) |
| 91 | 1/1 · 36 | 1/1 · 29 | 1/1 · 38 | 1/1 · 57 |
| 124 | 1/1 · 61 | 1/1 · 30 | 1/1 · 61 | 1/1 · 44 |
| 155 | 0/1 · 47 (execution_response_mismatch) | 0/1 · 50 (execution_response_mismatch) | 0/1 · 46 (execution_response_mismatch) | 0/1 · 33 (execution_response_mismatch) |
| 157 | 1/1 · 60 | 1/1 · 65 | 1/1 · 59 | 1/1 · 36 |
| 163 | 1/1 · 68 | 1/1 · 54 | 1/1 · 68 | 1/1 · 54 |
| 169 | 0/1 · 76 (instance_state_mismatch) | 0/1 · 64 (instance_state_mismatch) | 0/1 · 82 (instance_state_mismatch) | 0/1 · 80 (instance_state_mismatch) |
| 182 | 1/1 · 40 | 1/1 · 29 | 1/1 · 59 | 1/1 · 30 |
| 197 | 0/1 · 284 (force_terminated) | 0/1 · 338 (force_terminated) | 0/1 · 146 (instance_state_mismatch) | 0/1 · 91 (instance_state_mismatch) |

## Modos de falha (entradas × rodadas)

| Condição | force_terminated | instance_state_mismatch | execution_response_mismatch | empty_turn_model_response | outros |
|---|---|---|---|---|---|
| Runtime atual (Reasoning 512, kv) | 1 | 3 | 2 | 1 | 0 |
| + prefixo persistente | 1 | 3 | 2 | 1 | 0 |
| DAC + seletiva (guardas de decode) | 0 | 4 | 2 | 1 | 0 |
| DACS + prefixo persistente (pilha completa) | 0 | 4 | 2 | 1 | 0 |

Térmica ao fim de cada passo (todas as condições): {'nominal': 73, 'serious': 167, 'fair': 114}.

## Consistência contra a referência (chamadas e argumentos; texto final = TEXT)

- + prefixo persistente: 12 trajetórias idênticas; 108/108 passos iguais antes da divergência.
- DAC + seletiva (guardas de decode): 9 trajetórias idênticas; 62/108 passos iguais antes da divergência.
- DACS + prefixo persistente (pilha completa): 9 trajetórias idênticas; 62/108 passos iguais antes da divergência.
