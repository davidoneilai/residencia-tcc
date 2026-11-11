# DAC — BFCL Multi-Turn, Qwen3.5-2B no iPhone 16 Pro

Rodadas: cache-diag; entradas: 4. Tempos em s por entrada (média sobre entradas × rodadas).

| Condição | n | Acerto (por rodada) | Tempo | TTFT/passo | Prefill | Decode | Overhead | Tok. entrada | Tok. prefill | Tok. saída | Passos | Loops ≥3 | Teto 1024 | Pico MB |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| Reasoning fixo, sem cache | 4 | 4/4 | 172.1 | 23.72 | 141.5 | 29.3 | 0.8 | 41.2 mil | 41.21 mil | 757 | 6.0 | 0 | 0 | 2160 |
| Reasoning, prefix cache antigo | 4 | 4/4 | 36.5 | 2.89 | 14.1 | 18.8 | 3.3 | 41.2 mil | 5.73 mil | 734 | 6.0 | 0 | 0 | 2144 |
| Reasoning + cache incremental (kv) | 4 | 4/4 | 36.9 | 2.15 | 9.1 | 23.7 | 3.8 | 41.3 mil | 2.87 mil | 814 | 6.0 | 0 | 0 | 2000 |

## Pareado contra `reason-off` (entrada × rodada)

| Condição | pares | certa só aqui | certa só na ref. | p (McNemar, por entrada × rodada) | Δ tempo (s) | IC95% | Δ tempo (%) |
|---|---|---|---|---|---|---|---|
| Reasoning, prefix cache antigo | 4 | 0 | 0 | 1.00 | -135.6 | [-180.1; -91.1] | -79% |
| Reasoning + cache incremental (kv) | 4 | 0 | 0 | 1.00 | -135.1 | [-177.6; -94.5] | -79% |

## Mecanismos (soma sobre entradas × rodadas)

| Condição | Detecções (repetição/erro) | Recuperadas | Falharam → stop | Stops de A | Raciocínio fechado à força | Corte de chamada repetida | Caracteres de nota | KV reaproveitado (conv/turn/system/none) |
|---|---|---|---|---|---|---|---|---|
| Reasoning fixo, sem cache | 0/0 | 0 | 0 | 0 | 0 | 0 | 0 | 0/0/0/24 |
| Reasoning, prefix cache antigo | 0/0 | 0 | 0 | 0 | 0 | 0 | 0 | 14/0/10/0 |
| Reasoning + cache incremental (kv) | 0/0 | 0 | 0 | 0 | 0 | 0 | 0 | 14/6/4/0 |

## Por entrada (acertos nas rodadas · tempo médio s)

| Entrada | Reasoning fixo, sem cache | Reasoning, prefix cache antigo | Reasoning + cache incremental (kv) |
|---|---|---|---|
| 91 | 1/1 · 123 | 1/1 · 38 | 1/1 · 32 |
| 124 | 1/1 · 235 | 1/1 · 47 | 1/1 · 31 |
| 157 | 1/1 · 200 | 1/1 · 27 | 1/1 · 52 |
| 182 | 1/1 · 131 | 1/1 · 34 | 1/1 · 33 |

## Modos de falha (entradas × rodadas)

| Condição | force_terminated | instance_state_mismatch | execution_response_mismatch | empty_turn_model_response | outros |
|---|---|---|---|---|---|
| Reasoning fixo, sem cache | 0 | 0 | 0 | 0 | 0 |
| Reasoning, prefix cache antigo | 0 | 0 | 0 | 0 | 0 |
| Reasoning + cache incremental (kv) | 0 | 0 | 0 | 0 | 0 |

Térmica ao fim de cada passo (todas as condições): {'fair': 32, 'serious': 37, 'nominal': 3}.

## Consistência contra a referência (chamadas e argumentos; texto final = TEXT)

- Reasoning, prefix cache antigo: 4 trajetórias idênticas; 24/24 passos iguais antes da divergência.
- Reasoning + cache incremental (kv): 3 trajetórias idênticas; 20/24 passos iguais antes da divergência.
