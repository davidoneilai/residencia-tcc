# DAC — BFCL Multi-Turn, Qwen3.5-2B no iPhone 16 Pro

Rodadas: r1, r2, r3; entradas: 12. Tempos em s por entrada (média sobre entradas × rodadas).

| Condição | n | Acerto (por rodada) | Tempo | TTFT/passo | Prefill | Decode | Overhead | Tok. entrada | Tok. prefill | Tok. saída | Passos | Loops ≥3 | Teto 1024 | Pico MB |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| Reasoning fixo, sem cache | 12 | 4/12 | 380.2 | 27.09 | 265.1 | 63.0 | 1.3 | 66.3 mil | 66.33 mil | 1374 | 9.8 | 3 | 2 | 2160 |
| Reasoning + cache incremental (kv) | 36 | 5/12 · 5/12 · 5/12 | 64.9 | 2.33 | 12.3 | 46.8 | 5.2 | 51.1 mil | 3.08 mil | 1225 | 7.5 | 6 | 12 | 2099 |
| Política A original (kv) | 36 | 5/12 · 5/12 · 5/12 | 59.5 | 2.54 | 10.0 | 45.5 | 3.6 | 35.5 mil | 2.61 mil | 1113 | 5.5 | 2 | 12 | 2030 |
| DAC: kv + recuperação | 36 | 5/12 · 5/12 · 5/12 | 59.2 | 2.56 | 10.0 | 45.1 | 3.7 | 35.5 mil | 2.58 mil | 1120 | 5.4 | 0 | 12 | 2113 |
| DAC + seletiva (guardas de decode) | 36 | 5/12 · 5/12 · 5/12 | 54.3 | 2.32 | 9.4 | 40.6 | 3.9 | 38.4 mil | 2.38 mil | 1048 | 5.8 | 0 | 0 | 2113 |

## Pareado contra `reason-kv` (entrada × rodada)

| Condição | pares | certa só aqui | certa só na ref. | p (McNemar, por entrada × rodada) | Δ tempo (s) | IC95% | Δ tempo (%) |
|---|---|---|---|---|---|---|---|
| Reasoning fixo, sem cache | 12 | 0 | 1 | 1.00 | +303.3 | [+144.6; +508.6] | +394% |
| Política A original (kv) | 36 | 0 | 0 | 1.00 | -5.4 | [-12.7; +1.1] | -8% |
| DAC: kv + recuperação | 36 | 0 | 0 | 1.00 | -5.7 | [-13.3; +1.4] | -9% |
| DAC + seletiva (guardas de decode) | 36 | 0 | 0 | 1.00 | -10.6 | [-20.5; -0.7] | -16% |

## Mecanismos (soma sobre entradas × rodadas)

| Condição | Detecções (repetição/erro) | Recuperadas | Falharam → stop | Stops de A | Raciocínio fechado à força | Corte de chamada repetida | Caracteres de nota | KV reaproveitado (conv/turn/system/none) |
|---|---|---|---|---|---|---|---|---|
| Reasoning fixo, sem cache | 0/0 | 0 | 0 | 0 | 0 | 0 | 0 | 0/0/0/118 |
| Reasoning + cache incremental (kv) | 0/0 | 0 | 0 | 0 | 0 | 0 | 0 | 192/42/36/0 |
| Política A original (kv) | 0/0 | 0 | 0 | 6 | 0 | 0 | 0 | 114/45/33/0 |
| DAC: kv + recuperação | 3/3 | 3 | 3 | 0 | 0 | 0 | 2073 | 108/51/33/0 |
| DAC + seletiva (guardas de decode) | 6/3 | 6 | 3 | 0 | 15 | 0 | 3489 | 120/51/36/0 |

## Por entrada (acertos nas rodadas · tempo médio s)

| Entrada | Reasoning fixo, sem cache | Reasoning + cache incremental (kv) | Política A original (kv) | DAC: kv + recuperação | DAC + seletiva (guardas de decode) |
|---|---|---|---|---|---|
| 11 | 0/1 · 1306 (force_terminated) | 0/3 · 59 (empty_turn_model_response) | 0/3 · 58 (empty_turn_model_response) | 0/3 · 60 (empty_turn_model_response) | 0/3 · 34 (empty_turn_model_response) |
| 45 | 0/1 · 695 (force_terminated) | 0/3 · 102 (execution_response_mismatch) | 0/3 · 42 (execution_response_mismatch) | 0/3 · 44 (execution_response_mismatch) | 0/3 · 46 (execution_response_mismatch) |
| 46 | 0/1 · 570 (execution_response_mismatch) | 0/3 · 57 (instance_state_mismatch) | 0/3 · 24 (instance_state_mismatch) | 0/3 · 26 (instance_state_mismatch) | 0/3 · 28 (instance_state_mismatch) |
| 76 | 0/1 · 176 (empty_turn_model_response) | 0/3 · 110 (empty_turn_model_response) | 0/3 · 119 (empty_turn_model_response) | 0/3 · 106 (empty_turn_model_response) | 0/3 · 52 (instance_state_mismatch) |
| 91 | 1/1 · 163 | 3/3 · 37 | 3/3 · 37 | 3/3 · 38 | 3/3 · 36 |
| 124 | 1/1 · 238 | 3/3 · 62 | 3/3 · 54 | 3/3 · 47 | 3/3 · 53 |
| 155 | 0/1 · 108 (execution_response_mismatch) | 0/3 · 36 (execution_response_mismatch) | 0/3 · 41 (execution_response_mismatch) | 0/3 · 44 (execution_response_mismatch) | 0/3 · 37 (execution_response_mismatch) |
| 157 | 1/1 · 222 | 3/3 · 37 | 3/3 · 41 | 3/3 · 40 | 3/3 · 41 |
| 163 | 0/1 · 228 (instance_state_mismatch) | 3/3 · 60 | 3/3 · 67 | 3/3 · 60 | 3/3 · 61 |
| 169 | 0/1 · 354 (instance_state_mismatch) | 0/3 · 87 (instance_state_mismatch) | 0/3 · 99 (instance_state_mismatch) | 0/3 · 116 (instance_state_mismatch) | 0/3 · 83 (instance_state_mismatch) |
| 182 | 1/1 · 109 | 3/3 · 53 | 3/3 · 47 | 3/3 · 47 | 3/3 · 49 |
| 197 | 0/1 · 393 (instance_state_mismatch) | 0/3 · 79 (empty_turn_model_response) | 0/3 · 84 (empty_turn_model_response) | 0/3 · 82 (empty_turn_model_response) | 0/3 · 132 (instance_state_mismatch) |

## Modos de falha (entradas × rodadas)

| Condição | force_terminated | instance_state_mismatch | execution_response_mismatch | empty_turn_model_response | outros |
|---|---|---|---|---|---|
| Reasoning fixo, sem cache | 2 | 3 | 2 | 1 | 0 |
| Reasoning + cache incremental (kv) | 0 | 6 | 6 | 9 | 0 |
| Política A original (kv) | 0 | 6 | 6 | 9 | 0 |
| DAC: kv + recuperação | 0 | 6 | 6 | 9 | 0 |
| DAC + seletiva (guardas de decode) | 0 | 12 | 6 | 3 | 0 |

Térmica ao fim de cada passo (todas as condições): {'fair': 78, 'serious': 853, 'nominal': 48}.

## Consistência contra a referência (chamadas e argumentos; texto final = TEXT)

- Reasoning fixo, sem cache: 5 trajetórias idênticas; 38/122 passos iguais antes da divergência.
- Política A original (kv): 30 trajetórias idênticas; 192/270 passos iguais antes da divergência.
- DAC: kv + recuperação: 30 trajetórias idênticas; 186/270 passos iguais antes da divergência.
- DAC + seletiva (guardas de decode): 21 trajetórias idênticas; 144/285 passos iguais antes da divergência.
