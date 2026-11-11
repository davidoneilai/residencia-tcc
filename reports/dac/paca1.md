# DAC — BFCL Multi-Turn, Qwen3.5-2B no iPhone 16 Pro

Rodadas: paca1; entradas: 4. Tempos em s por entrada (média sobre entradas × rodadas).

| Condição | n | Acerto (por rodada) | Tempo | TTFT/passo | Prefill | Decode | Overhead | Tok. entrada | Tok. prefill | Tok. saída | Passos | Loops ≥3 | Teto 1024 | Pico MB |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| PACA (orçamento por progresso) | 4 | 1/4 | 59.8 | 2.19 | 12.0 | 42.3 | 4.9 | 52.3 mil | 3.34 mil | 1276 | 8.0 | 0 | 0 | 2093 |
| DAC + seletiva (guardas de decode) | 4 | 2/4 | 69.7 | 2.22 | 11.4 | 53.2 | 4.7 | 49.3 mil | 2.98 mil | 1632 | 7.2 | 0 | 0 | 1947 |
| Reasoning + kv, orçamento fixo 512 | 4 | 2/4 | 120.1 | 2.23 | 16.5 | 95.9 | 6.9 | 77.0 mil | 3.61 mil | 2731 | 10.5 | 1 | 0 | 1897 |
| DAC seletiva, orçamento fixo 256 | 4 | 2/4 | 60.6 | 1.89 | 9.6 | 45.4 | 5.1 | 52.3 mil | 1.68 mil | 1329 | 8.0 | 0 | 0 | 2093 |
| DAC seletiva, orçamento fixo 128 | 4 | 1/4 | 53.2 | 1.93 | 9.1 | 39.2 | 4.4 | 46.7 mil | 1.59 mil | 1149 | 7.0 | 0 | 0 | 2088 |

## Pareado contra `dacs-kv` (entrada × rodada)

| Condição | pares | certa só aqui | certa só na ref. | p (McNemar, por entrada × rodada) | Δ tempo (s) | IC95% | Δ tempo (%) |
|---|---|---|---|---|---|---|---|
| PACA (orçamento por progresso) | 4 | 0 | 1 | 1.00 | -9.9 | [-30.8; +5.1] | -14% |
| Reasoning + kv, orçamento fixo 512 | 4 | 0 | 0 | 1.00 | +50.4 | [+3.1; +133.3] | +72% |
| DAC seletiva, orçamento fixo 256 | 4 | 0 | 0 | 1.00 | -9.1 | [-30.3; +6.5] | -13% |
| DAC seletiva, orçamento fixo 128 | 4 | 0 | 1 | 1.00 | -16.5 | [-43.7; +2.3] | -24% |

## Mecanismos (soma sobre entradas × rodadas)

| Condição | Detecções (repetição/erro) | Recuperadas | Falharam → stop | Stops de A | Raciocínio fechado à força | Corte de chamada repetida | Caracteres de nota | KV reaproveitado (conv/turn/system/none) |
|---|---|---|---|---|---|---|---|---|
| PACA (orçamento por progresso) | 0/0 | 0 | 0 | 0 | 5 | 1 | 0 | 20/7/4/0 |
| DAC + seletiva (guardas de decode) | 1/0 | 1 | 0 | 0 | 3 | 0 | 472 | 18/7/4/0 |
| Reasoning + kv, orçamento fixo 512 | 0/0 | 0 | 0 | 0 | 8 | 0 | 0 | 34/4/4/0 |
| DAC seletiva, orçamento fixo 256 | 1/0 | 0 | 1 | 0 | 4 | 1 | 441 | 20/7/4/0 |
| DAC seletiva, orçamento fixo 128 | 0/0 | 0 | 0 | 0 | 6 | 0 | 0 | 18/6/4/0 |

## Por entrada (acertos nas rodadas · tempo médio s)

| Entrada | PACA (orçamento por progresso) | DAC + seletiva (guardas de decode) | Reasoning + kv, orçamento fixo 512 | DAC seletiva, orçamento fixo 256 | DAC seletiva, orçamento fixo 128 |
|---|---|---|---|---|---|
| 124 | 1/1 · 44 | 1/1 · 36 | 1/1 · 42 | 1/1 · 42 | 1/1 · 42 |
| 163 | 0/1 · 57 (instance_state_mismatch) | 1/1 · 55 | 1/1 · 55 | 1/1 · 61 | 0/1 · 50 (instance_state_mismatch) |
| 169 | 0/1 · 68 (instance_state_mismatch) | 0/1 · 76 (instance_state_mismatch) | 0/1 · 96 (instance_state_mismatch) | 0/1 · 69 (instance_state_mismatch) | 0/1 · 65 (instance_state_mismatch) |
| 197 | 0/1 · 70 (instance_state_mismatch) | 0/1 · 112 (instance_state_mismatch) | 0/1 · 288 (force_terminated) | 0/1 · 70 (instance_state_mismatch) | 0/1 · 56 (instance_state_mismatch) |

## Modos de falha (entradas × rodadas)

| Condição | force_terminated | instance_state_mismatch | execution_response_mismatch | empty_turn_model_response | outros |
|---|---|---|---|---|---|
| PACA (orçamento por progresso) | 0 | 3 | 0 | 0 | 0 |
| DAC + seletiva (guardas de decode) | 0 | 2 | 0 | 0 | 0 |
| Reasoning + kv, orçamento fixo 512 | 1 | 1 | 0 | 0 | 0 |
| DAC seletiva, orçamento fixo 256 | 0 | 2 | 0 | 0 | 0 |
| DAC seletiva, orçamento fixo 128 | 0 | 3 | 0 | 0 | 0 |

Térmica ao fim de cada passo (todas as condições): {'nominal': 10, 'fair': 101, 'serious': 50}.

## Consistência contra a referência (chamadas e argumentos; texto final = TEXT)

- PACA (orçamento por progresso): 1 trajetórias idênticas; 8/32 passos iguais antes da divergência.
- Reasoning + kv, orçamento fixo 512: 3 trajetórias idênticas; 24/42 passos iguais antes da divergência.
- DAC seletiva, orçamento fixo 256: 1 trajetórias idênticas; 8/32 passos iguais antes da divergência.
- DAC seletiva, orçamento fixo 128: 1 trajetórias idênticas; 8/30 passos iguais antes da divergência.
