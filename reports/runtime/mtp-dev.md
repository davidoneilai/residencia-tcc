# DAC — BFCL Multi-Turn, Qwen3.5-2B no iPhone 16 Pro

Rodadas: mtA, mtB; entradas: 12. Tempos em s por entrada (média sobre entradas × rodadas).

| Condição | n | Acerto (por rodada) | Tempo | TTFT/passo | Prefill | Decode | Overhead | Tok. entrada | Tok. prefill | Tok. saída | Passos | Loops ≥3 | Teto 1024 | Pico MB |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| DACS + prefixo persistente (pilha completa) | 24 | 4/12 · 4/12 | 49.2 | 1.96 | 8.7 | 36.5 | 3.7 | 42.2 mil | 1.97 mil | 1140 | 6.5 | 0 | 2 | 2172 |
| Pilha + MTP em pipeline (escalonador por custo) | 24 | 4/12 · 4/12 | 44.4 | 2.19 | 11.6 | 29.2 | 3.2 | 45.5 mil | 2.56 mil | 1072 | 6.9 | 0 | 2 | 2229 |

## Pareado contra `dacs-persist-kv` (entrada × rodada)

| Condição | pares | certa só aqui | certa só na ref. | p (McNemar, por entrada × rodada) | Δ tempo (s) | IC95% | Δ tempo (%) |
|---|---|---|---|---|---|---|---|
| Pilha + MTP em pipeline (escalonador por custo) | 24 | 0 | 0 | 1.00 | -4.8 | [-10.6; +1.3] | -10% |

## Mecanismos (soma sobre entradas × rodadas)

| Condição | Detecções (repetição/erro) | Recuperadas | Falharam → stop | Stops de A | Raciocínio fechado à força | Corte de chamada repetida | Caracteres de nota | KV reaproveitado (conv/turn/system/none) |
|---|---|---|---|---|---|---|---|---|
| DACS + prefixo persistente (pilha completa) | 14/2 | 12 | 4 | 0 | 8 | 0 | 5390 | 84/44/24/0 |
| Pilha + MTP em pipeline (escalonador por custo) | 8/2 | 6 | 4 | 0 | 6 | 0 | 3718 | 100/38/24/0 |

## Por entrada (acertos nas rodadas · tempo médio s)

| Entrada | DACS + prefixo persistente (pilha completa) | Pilha + MTP em pipeline (escalonador por custo) |
|---|---|---|
| 11 | 0/2 · 35 (empty_turn_model_response) | 0/2 · 20 (empty_turn_model_response) |
| 45 | 0/2 · 46 (execution_response_mismatch) | 0/2 · 65 (execution_response_mismatch) |
| 46 | 0/2 · 27 (instance_state_mismatch) | 0/2 · 17 (instance_state_mismatch) |
| 76 | 0/2 · 34 (instance_state_mismatch) | 0/2 · 36 (instance_state_mismatch) |
| 91 | 2/2 · 40 | 2/2 · 28 |
| 124 | 2/2 · 38 | 2/2 · 44 |
| 155 | 0/2 · 37 (execution_response_mismatch) | 0/2 · 26 (execution_response_mismatch) |
| 157 | 2/2 · 33 | 2/2 · 45 |
| 163 | 0/2 · 97 (instance_state_mismatch) | 0/2 · 82 (instance_state_mismatch) |
| 169 | 0/2 · 67 (instance_state_mismatch) | 0/2 · 74 (instance_state_mismatch) |
| 182 | 2/2 · 46 | 2/2 · 27 |
| 197 | 0/2 · 91 (instance_state_mismatch) | 0/2 · 72 (instance_state_mismatch) |

## Modos de falha (entradas × rodadas)

| Condição | force_terminated | instance_state_mismatch | execution_response_mismatch | empty_turn_model_response | outros |
|---|---|---|---|---|---|
| DACS + prefixo persistente (pilha completa) | 0 | 10 | 4 | 2 | 0 |
| Pilha + MTP em pipeline (escalonador por custo) | 0 | 10 | 4 | 2 | 0 |

Térmica ao fim de cada passo (todas as condições): {'nominal': 5, 'fair': 309}.

## Consistência contra a referência (chamadas e argumentos; texto final = TEXT)

- Pilha + MTP em pipeline (escalonador por custo): 14 trajetórias idênticas; 110/170 passos iguais antes da divergência.
