# DAC — BFCL Multi-Turn, Qwen3.5-2B no iPhone 16 Pro

Rodadas: sfms; entradas: 12. Tempos em s por entrada (média sobre entradas × rodadas).

| Condição | n | Acerto (por rodada) | Tempo | TTFT/passo | Prefill | Decode | Overhead | Tok. entrada | Tok. prefill | Tok. saída | Passos | Loops ≥3 | Teto 1024 | Pico MB |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| NoThink + kv | 12 | 3/12 | 91.9 | 3.62 | 40.4 | 38.5 | 11.0 | 97.5 mil | 7.23 mil | 576 | 14.2 | 4 | 0 | 3032 |
| NoThink: DAC + repeat_guard + prefixo persistente | 12 | 2/12 | 55.5 | 4.89 | 30.0 | 19.1 | 5.4 | 47.1 mil | 5.49 mil | 294 | 7.8 | 0 | 0 | 3131 |

## Pareado contra `nt-base-kv` (entrada × rodada)

| Condição | pares | certa só aqui | certa só na ref. | p (McNemar, por entrada × rodada) | Δ tempo (s) | IC95% | Δ tempo (%) |
|---|---|---|---|---|---|---|---|
| NoThink: DAC + repeat_guard + prefixo persistente | 12 | 0 | 1 | 1.00 | -36.5 | [-60.5; -14.9] | -40% |

## Mecanismos (soma sobre entradas × rodadas)

| Condição | Detecções (repetição/erro) | Recuperadas | Falharam → stop | Stops de A | Raciocínio fechado à força | Corte de chamada repetida | Caracteres de nota | KV reaproveitado (conv/turn/system/none) |
|---|---|---|---|---|---|---|---|---|
| NoThink + kv | 0/0 | 0 | 0 | 0 | 0 | 0 | 0 | 158/0/12/0 |
| NoThink: DAC + repeat_guard + prefixo persistente | 0/0 | 0 | 0 | 0 | 0 | 0 | 0 | 75/0/12/0 |

## Por entrada (acertos nas rodadas · tempo médio s)

| Entrada | NoThink + kv | NoThink: DAC + repeat_guard + prefixo persistente |
|---|---|---|
| 11 | 0/1 · 45 (instance_state_mismatch) | 0/1 · 56 (instance_state_mismatch) |
| 45 | 0/1 · 85 (force_terminated) | 0/1 · 48 (instance_state_mismatch) |
| 46 | 0/1 · 60 (execution_response_mismatch) | 0/1 · 26 (execution_response_mismatch) |
| 76 | 0/1 · 169 (force_terminated) | 0/1 · 65 (instance_state_mismatch) |
| 91 | 1/1 · 60 | 0/1 · 55 (instance_state_mismatch) |
| 124 | 0/1 · 124 (instance_state_mismatch) | 0/1 · 76 (instance_state_mismatch) |
| 155 | 0/1 · 66 (instance_state_mismatch) | 0/1 · 58 (instance_state_mismatch) |
| 157 | 0/1 · 67 (execution_response_mismatch) | 0/1 · 68 (execution_response_mismatch) |
| 163 | 0/1 · 137 (force_terminated) | 0/1 · 54 (instance_state_mismatch) |
| 169 | 1/1 · 75 | 1/1 · 77 |
| 182 | 1/1 · 42 | 1/1 · 20 |
| 197 | 0/1 · 172 (force_terminated) | 0/1 · 64 (instance_state_mismatch) |

## Modos de falha (entradas × rodadas)

| Condição | force_terminated | instance_state_mismatch | execution_response_mismatch | empty_turn_model_response | outros |
|---|---|---|---|---|---|
| NoThink + kv | 4 | 3 | 2 | 0 | 0 |
| NoThink: DAC + repeat_guard + prefixo persistente | 0 | 8 | 2 | 0 | 0 |

Térmica ao fim de cada passo (todas as condições): {'nominal': 17, 'fair': 205, 'serious': 35}.

## Consistência contra a referência (chamadas e argumentos; texto final = TEXT)

- NoThink: DAC + repeat_guard + prefixo persistente: 4 trajetórias idênticas; 58/170 passos iguais antes da divergência.
