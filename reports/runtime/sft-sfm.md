# DAC — BFCL Multi-Turn, Qwen3.5-2B no iPhone 16 Pro

Rodadas: sfm; entradas: 12. Tempos em s por entrada (média sobre entradas × rodadas).

| Condição | n | Acerto (por rodada) | Tempo | TTFT/passo | Prefill | Decode | Overhead | Tok. entrada | Tok. prefill | Tok. saída | Passos | Loops ≥3 | Teto 1024 | Pico MB |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| NoThink + kv | 12 | 5/12 | 54.7 | 3.76 | 31.0 | 15.8 | 6.3 | 65.8 mil | 6.86 mil | 389 | 9.9 | 0 | 0 | 3036 |
| NoThink: DAC + repeat_guard + prefixo persistente | 12 | 5/12 | 42.6 | 3.58 | 24.3 | 12.0 | 5.3 | 53.6 mil | 5.49 mil | 327 | 8.5 | 0 | 0 | 3046 |

## Pareado contra `nt-base-kv` (entrada × rodada)

| Condição | pares | certa só aqui | certa só na ref. | p (McNemar, por entrada × rodada) | Δ tempo (s) | IC95% | Δ tempo (%) |
|---|---|---|---|---|---|---|---|
| NoThink: DAC + repeat_guard + prefixo persistente | 12 | 0 | 0 | 1.00 | -12.2 | [-25.4; -1.4] | -22% |

## Mecanismos (soma sobre entradas × rodadas)

| Condição | Detecções (repetição/erro) | Recuperadas | Falharam → stop | Stops de A | Raciocínio fechado à força | Corte de chamada repetida | Caracteres de nota | KV reaproveitado (conv/turn/system/none) |
|---|---|---|---|---|---|---|---|---|
| NoThink + kv | 0/0 | 0 | 0 | 0 | 0 | 0 | 0 | 107/0/12/0 |
| NoThink: DAC + repeat_guard + prefixo persistente | 0/0 | 0 | 0 | 0 | 0 | 0 | 0 | 87/0/12/0 |

## Por entrada (acertos nas rodadas · tempo médio s)

| Entrada | NoThink + kv | NoThink: DAC + repeat_guard + prefixo persistente |
|---|---|---|
| 11 | 0/1 · 35 (instance_state_mismatch) | 0/1 · 42 (instance_state_mismatch) |
| 45 | 1/1 · 48 | 1/1 · 39 |
| 46 | 0/1 · 30 (instance_state_mismatch) | 0/1 · 35 (instance_state_mismatch) |
| 76 | 0/1 · 57 (instance_state_mismatch) | 0/1 · 44 (instance_state_mismatch) |
| 91 | 1/1 · 61 | 1/1 · 42 |
| 124 | 0/1 · 84 (instance_state_mismatch) | 0/1 · 61 (instance_state_mismatch) |
| 155 | 0/1 · 41 (instance_state_mismatch) | 0/1 · 40 (instance_state_mismatch) |
| 157 | 1/1 · 46 | 1/1 · 63 |
| 163 | 0/1 · 55 (instance_state_mismatch) | 0/1 · 26 (instance_state_mismatch) |
| 169 | 1/1 · 55 | 1/1 · 57 |
| 182 | 1/1 · 30 | 1/1 · 16 |
| 197 | 0/1 · 115 (force_terminated) | 0/1 · 46 (instance_state_mismatch) |

## Modos de falha (entradas × rodadas)

| Condição | force_terminated | instance_state_mismatch | execution_response_mismatch | empty_turn_model_response | outros |
|---|---|---|---|---|---|
| NoThink + kv | 1 | 6 | 0 | 0 | 0 |
| NoThink: DAC + repeat_guard + prefixo persistente | 0 | 7 | 0 | 0 | 0 |

Térmica ao fim de cada passo (todas as condições): {'nominal': 58, 'fair': 58, 'serious': 102}.

## Consistência contra a referência (chamadas e argumentos; texto final = TEXT)

- NoThink: DAC + repeat_guard + prefixo persistente: 6 trajetórias idênticas; 74/120 passos iguais antes da divergência.
