# DAC — BFCL Multi-Turn, Qwen3.5-2B no iPhone 16 Pro

Rodadas: mw1, mw2, mw3, mw4; entradas: 12. Tempos em s por entrada (média sobre entradas × rodadas).

| Condição | n | Acerto (por rodada) | Tempo | TTFT/passo | Prefill | Decode | Overhead | Tok. entrada | Tok. prefill | Tok. saída | Passos | Loops ≥3 | Teto 1024 | Pico MB |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| DACS + prefixo persistente (pilha completa) | 48 | 4/12 · 4/12 · 4/12 · 4/12 | 47.3 | 1.55 | 6.3 | 37.1 | 3.6 | 42.2 mil | 0.99 mil | 1140 | 6.5 | 0 | 4 | 2172 |
| Pilha + MTP em pipeline (escalonador por custo) | 48 | 4/12 · 4/12 · 4/12 · 4/12 | 41.1 | 1.58 | 7.2 | 30.0 | 3.4 | 45.5 mil | 1.09 mil | 1072 | 6.9 | 0 | 4 | 2229 |

## Pareado contra `dacs-persist-kv` (entrada × rodada)

| Condição | pares | certa só aqui | certa só na ref. | p (McNemar, por entrada × rodada) | Δ tempo (s) | IC95% | Δ tempo (%) |
|---|---|---|---|---|---|---|---|
| Pilha + MTP em pipeline (escalonador por custo) | 48 | 0 | 0 | 1.00 | -6.2 | [-8.4; -3.9] | -13% |

## Mecanismos (soma sobre entradas × rodadas)

| Condição | Detecções (repetição/erro) | Recuperadas | Falharam → stop | Stops de A | Raciocínio fechado à força | Corte de chamada repetida | Caracteres de nota | KV reaproveitado (conv/turn/system/none) |
|---|---|---|---|---|---|---|---|---|
| DACS + prefixo persistente (pilha completa) | 28/4 | 24 | 8 | 0 | 16 | 0 | 10780 | 168/88/48/0 |
| Pilha + MTP em pipeline (escalonador por custo) | 16/4 | 12 | 8 | 0 | 12 | 0 | 7436 | 200/76/48/0 |

## Por entrada (acertos nas rodadas · tempo médio s)

| Entrada | DACS + prefixo persistente (pilha completa) | Pilha + MTP em pipeline (escalonador por custo) |
|---|---|---|
| 11 | 0/4 · 32 (empty_turn_model_response) | 0/4 · 20 (empty_turn_model_response) |
| 45 | 0/4 · 47 (execution_response_mismatch) | 0/4 · 57 (execution_response_mismatch) |
| 46 | 0/4 · 20 (instance_state_mismatch) | 0/4 · 17 (instance_state_mismatch) |
| 76 | 0/4 · 34 (instance_state_mismatch) | 0/4 · 25 (instance_state_mismatch) |
| 91 | 4/4 · 31 | 4/4 · 29 |
| 124 | 4/4 · 38 | 4/4 · 35 |
| 155 | 0/4 · 31 (execution_response_mismatch) | 0/4 · 26 (execution_response_mismatch) |
| 157 | 4/4 · 34 | 4/4 · 33 |
| 163 | 0/4 · 99 (instance_state_mismatch) | 0/4 · 84 (instance_state_mismatch) |
| 169 | 0/4 · 64 (instance_state_mismatch) | 0/4 · 65 (instance_state_mismatch) |
| 182 | 4/4 · 44 | 4/4 · 27 |
| 197 | 0/4 · 93 (instance_state_mismatch) | 0/4 · 75 (instance_state_mismatch) |

## Modos de falha (entradas × rodadas)

| Condição | force_terminated | instance_state_mismatch | execution_response_mismatch | empty_turn_model_response | outros |
|---|---|---|---|---|---|
| DACS + prefixo persistente (pilha completa) | 0 | 20 | 8 | 4 | 0 |
| Pilha + MTP em pipeline (escalonador por custo) | 0 | 20 | 8 | 4 | 0 |

Térmica ao fim de cada passo (todas as condições): {'nominal': 628}.

## Consistência contra a referência (chamadas e argumentos; texto final = TEXT)

- Pilha + MTP em pipeline (escalonador por custo): 28 trajetórias idênticas; 220/340 passos iguais antes da divergência.
