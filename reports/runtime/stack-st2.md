# DAC — BFCL Multi-Turn, Qwen3.5-2B no iPhone 16 Pro

Rodadas: st2; entradas: 12. Tempos em s por entrada (média sobre entradas × rodadas).

| Condição | n | Acerto (por rodada) | Tempo | TTFT/passo | Prefill | Decode | Overhead | Tok. entrada | Tok. prefill | Tok. saída | Passos | Loops ≥3 | Teto 1024 | Pico MB |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| Runtime atual (Reasoning 512, kv) | 12 | 5/12 | 74.8 | 2.97 | 20.8 | 47.4 | 5.9 | 63.3 mil | 7.43 mil | 1520 | 9.0 | 3 | 0 | 1945 |
| + prefixo persistente | 12 | 5/12 | 62.2 | 1.88 | 11.3 | 44.7 | 5.6 | 63.3 mil | 3.65 mil | 1520 | 9.0 | 3 | 0 | 1945 |
| DAC + seletiva (guardas de decode) | 12 | 5/12 | 54.8 | 3.89 | 18.6 | 31.5 | 3.7 | 38.4 mil | 7.25 mil | 1048 | 5.8 | 0 | 0 | 1947 |
| DACS + prefixo persistente (pilha completa) | 12 | 5/12 | 44.1 | 2.48 | 10.6 | 29.4 | 3.7 | 38.4 mil | 3.54 mil | 1048 | 5.8 | 0 | 0 | 1946 |

## Pareado contra `rt-base-kv` (entrada × rodada)

| Condição | pares | certa só aqui | certa só na ref. | p (McNemar, por entrada × rodada) | Δ tempo (s) | IC95% | Δ tempo (%) |
|---|---|---|---|---|---|---|---|
| + prefixo persistente | 12 | 0 | 0 | 1.00 | -12.6 | [-19.6; -5.1] | -17% |
| DAC + seletiva (guardas de decode) | 12 | 0 | 0 | 1.00 | -20.0 | [-51.3; -0.1] | -27% |
| DACS + prefixo persistente (pilha completa) | 12 | 0 | 0 | 1.00 | -30.7 | [-62.2; -11.1] | -41% |

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
| 11 | 0/1 · 39 (empty_turn_model_response) | 0/1 · 34 (empty_turn_model_response) | 0/1 · 46 (empty_turn_model_response) | 0/1 · 20 (empty_turn_model_response) |
| 45 | 0/1 · 87 (execution_response_mismatch) | 0/1 · 70 (execution_response_mismatch) | 0/1 · 42 (execution_response_mismatch) | 0/1 · 59 (execution_response_mismatch) |
| 46 | 0/1 · 53 (instance_state_mismatch) | 0/1 · 33 (instance_state_mismatch) | 0/1 · 32 (instance_state_mismatch) | 0/1 · 26 (instance_state_mismatch) |
| 76 | 0/1 · 45 (instance_state_mismatch) | 0/1 · 51 (instance_state_mismatch) | 0/1 · 47 (instance_state_mismatch) | 0/1 · 30 (instance_state_mismatch) |
| 91 | 1/1 · 35 | 1/1 · 49 | 1/1 · 35 | 1/1 · 25 |
| 124 | 1/1 · 62 | 1/1 · 30 | 1/1 · 57 | 1/1 · 45 |
| 155 | 0/1 · 32 (execution_response_mismatch) | 0/1 · 27 (execution_response_mismatch) | 0/1 · 34 (execution_response_mismatch) | 0/1 · 41 (execution_response_mismatch) |
| 157 | 1/1 · 58 | 1/1 · 43 | 1/1 · 42 | 1/1 · 35 |
| 163 | 1/1 · 67 | 1/1 · 39 | 1/1 · 71 | 1/1 · 38 |
| 169 | 0/1 · 77 (instance_state_mismatch) | 0/1 · 56 (instance_state_mismatch) | 0/1 · 83 (instance_state_mismatch) | 0/1 · 78 (instance_state_mismatch) |
| 182 | 1/1 · 52 | 1/1 · 31 | 1/1 · 53 | 1/1 · 31 |
| 197 | 0/1 · 291 (force_terminated) | 0/1 · 283 (force_terminated) | 0/1 · 116 (instance_state_mismatch) | 0/1 · 101 (instance_state_mismatch) |

## Modos de falha (entradas × rodadas)

| Condição | force_terminated | instance_state_mismatch | execution_response_mismatch | empty_turn_model_response | outros |
|---|---|---|---|---|---|
| Runtime atual (Reasoning 512, kv) | 1 | 3 | 2 | 1 | 0 |
| + prefixo persistente | 1 | 3 | 2 | 1 | 0 |
| DAC + seletiva (guardas de decode) | 0 | 4 | 2 | 1 | 0 |
| DACS + prefixo persistente (pilha completa) | 0 | 4 | 2 | 1 | 0 |

Térmica ao fim de cada passo (todas as condições): {'fair': 58, 'serious': 192, 'nominal': 104}.

## Consistência contra a referência (chamadas e argumentos; texto final = TEXT)

- + prefixo persistente: 12 trajetórias idênticas; 108/108 passos iguais antes da divergência.
- DAC + seletiva (guardas de decode): 9 trajetórias idênticas; 62/108 passos iguais antes da divergência.
- DACS + prefixo persistente (pilha completa): 9 trajetórias idênticas; 62/108 passos iguais antes da divergência.
