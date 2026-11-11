# DAC — BFCL Multi-Turn, Qwen3.5-2B no iPhone 16 Pro

Rodadas: gmA, gmB; entradas: 12. Tempos em s por entrada (média sobre entradas × rodadas).

| Condição | n | Acerto (por rodada) | Tempo | TTFT/passo | Prefill | Decode | Overhead | Tok. entrada | Tok. prefill | Tok. saída | Passos | Loops ≥3 | Teto 1024 | Pico MB |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| NoThink + kv | 12 | 1/12 | 30.6 | 3.18 | 9.9 | 17.5 | 2.1 | 15.9 mil | 4.29 mil | 303 | 3.8 | 0 | 0 | 3145 |
| NoThink: DAC + repeat_guard + prefixo persistente | 24 | 1/12 · 1/12 | 25.4 | 2.12 | 6.2 | 16.7 | 2.0 | 16.4 mil | 1.98 mil | 310 | 3.9 | 0 | 0 | 3149 |

## Pareado contra `nt-base-kv` (entrada × rodada)

| Condição | pares | certa só aqui | certa só na ref. | p (McNemar, por entrada × rodada) | Δ tempo (s) | IC95% | Δ tempo (%) |
|---|---|---|---|---|---|---|---|
| NoThink: DAC + repeat_guard + prefixo persistente | 12 | 0 | 0 | 1.00 | -1.8 | [-4.0; +0.2] | -6% |

## Mecanismos (soma sobre entradas × rodadas)

| Condição | Detecções (repetição/erro) | Recuperadas | Falharam → stop | Stops de A | Raciocínio fechado à força | Corte de chamada repetida | Caracteres de nota | KV reaproveitado (conv/turn/system/none) |
|---|---|---|---|---|---|---|---|---|
| NoThink + kv | 0/0 | 0 | 0 | 0 | 0 | 0 | 0 | 33/0/12/0 |
| NoThink: DAC + repeat_guard + prefixo persistente | 0/0 | 0 | 0 | 0 | 0 | 0 | 0 | 68/0/24/0 |

## Por entrada (acertos nas rodadas · tempo médio s)

| Entrada | NoThink + kv | NoThink: DAC + repeat_guard + prefixo persistente |
|---|---|---|
| 11 | 0/1 · 23 (execution_response_mismatch) | 0/2 · 13 (execution_response_mismatch) |
| 45 | 0/1 · 12 (instance_state_mismatch) | 0/2 · 9 (instance_state_mismatch) |
| 46 | 0/1 · 12 (instance_state_mismatch) | 0/2 · 7 (instance_state_mismatch) |
| 76 | 0/1 · 30 (instance_state_mismatch) | 0/2 · 23 (instance_state_mismatch) |
| 91 | 1/1 · 27 | 2/2 · 22 |
| 124 | 0/1 · 24 (instance_state_mismatch) | 0/2 · 21 (instance_state_mismatch) |
| 155 | 0/1 · 41 (empty_turn_model_response) | 0/2 · 41 (empty_turn_model_response) |
| 157 | 0/1 · 24 (empty_turn_model_response) | 0/2 · 20 (empty_turn_model_response) |
| 163 | 0/1 · 38 (empty_turn_model_response) | 0/2 · 32 (empty_turn_model_response) |
| 169 | 0/1 · 38 (empty_turn_model_response) | 0/2 · 33 (empty_turn_model_response) |
| 182 | 0/1 · 20 (empty_turn_model_response) | 0/2 · 13 (empty_turn_model_response) |
| 197 | 0/1 · 76 (instance_state_mismatch) | 0/2 · 70 (instance_state_mismatch) |

## Modos de falha (entradas × rodadas)

| Condição | force_terminated | instance_state_mismatch | execution_response_mismatch | empty_turn_model_response | outros |
|---|---|---|---|---|---|
| NoThink + kv | 0 | 5 | 1 | 5 | 0 |
| NoThink: DAC + repeat_guard + prefixo persistente | 0 | 10 | 2 | 10 | 0 |

Térmica ao fim de cada passo (todas as condições): {'fair': 137}.

## Consistência contra a referência (chamadas e argumentos; texto final = TEXT)

- NoThink: DAC + repeat_guard + prefixo persistente: 11 trajetórias idênticas; 43/47 passos iguais antes da divergência.
