# DAC — BFCL Multi-Turn, Qwen3.5-2B no iPhone 16 Pro

Rodadas: rt1; entradas: 3. Tempos em s por entrada (média sobre entradas × rodadas).

| Condição | n | Acerto (por rodada) | Tempo | TTFT/passo | Prefill | Decode | Overhead | Tok. entrada | Tok. prefill | Tok. saída | Passos | Loops ≥3 | Teto 1024 | Pico MB |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| Runtime atual (Reasoning 512, kv) | 3 | 2/3 | 78.3 | 4.26 | 24.5 | 47.9 | 5.3 | 46.1 mil | 7.52 mil | 1284 | 7.0 | 0 | 0 | 1897 |
| + prefixo persistente | 3 | 2/3 | 55.3 | 1.69 | 7.7 | 43.1 | 4.1 | 46.1 mil | 1.63 mil | 1284 | 7.0 | 0 | 0 | 1896 |
| + rascunho da gramática | 3 | 2/3 | 74.7 | 4.16 | 24.6 | 45.1 | 4.5 | 46.1 mil | 7.52 mil | 1284 | 7.0 | 0 | 0 | 1897 |
| + prefixo persistente + rascunho | 3 | 2/3 | 58.7 | 1.84 | 8.7 | 45.2 | 4.2 | 46.1 mil | 1.63 mil | 1284 | 7.0 | 0 | 0 | 1896 |

## Pareado contra `rt-base-kv` (entrada × rodada)

| Condição | pares | certa só aqui | certa só na ref. | p (McNemar, por entrada × rodada) | Δ tempo (s) | IC95% | Δ tempo (%) |
|---|---|---|---|---|---|---|---|
| + prefixo persistente | 3 | 0 | 0 | 1.00 | -22.9 | [-26.3; -17.7] | -29% |
| + rascunho da gramática | 3 | 0 | 0 | 1.00 | -3.6 | [-8.5; -0.6] | -5% |
| + prefixo persistente + rascunho | 3 | 0 | 0 | 1.00 | -19.6 | [-23.2; -17.0] | -25% |

## Mecanismos (soma sobre entradas × rodadas)

| Condição | Detecções (repetição/erro) | Recuperadas | Falharam → stop | Stops de A | Raciocínio fechado à força | Corte de chamada repetida | Caracteres de nota | KV reaproveitado (conv/turn/system/none) |
|---|---|---|---|---|---|---|---|---|
| Runtime atual (Reasoning 512, kv) | 0/0 | 0 | 0 | 0 | 1 | 0 | 0 | 14/4/3/0 |
| + prefixo persistente | 0/0 | 0 | 0 | 0 | 1 | 0 | 0 | 14/4/3/0 |
| + rascunho da gramática | 0/0 | 0 | 0 | 0 | 1 | 0 | 0 | 14/4/3/0 |
| + prefixo persistente + rascunho | 0/0 | 0 | 0 | 0 | 1 | 0 | 0 | 14/4/3/0 |

## Por entrada (acertos nas rodadas · tempo médio s)

| Entrada | Runtime atual (Reasoning 512, kv) | + prefixo persistente | + rascunho da gramática | + prefixo persistente + rascunho |
|---|---|---|---|---|
| 124 | 1/1 · 56 | 1/1 · 30 | 1/1 · 54 | 1/1 · 39 |
| 163 | 1/1 · 78 | 1/1 · 53 | 1/1 · 70 | 1/1 · 60 |
| 169 | 0/1 · 101 (instance_state_mismatch) | 0/1 · 83 (instance_state_mismatch) | 0/1 · 100 (instance_state_mismatch) | 0/1 · 77 (instance_state_mismatch) |

## Modos de falha (entradas × rodadas)

| Condição | force_terminated | instance_state_mismatch | execution_response_mismatch | empty_turn_model_response | outros |
|---|---|---|---|---|---|
| Runtime atual (Reasoning 512, kv) | 0 | 1 | 0 | 0 | 0 |
| + prefixo persistente | 0 | 1 | 0 | 0 | 0 |
| + rascunho da gramática | 0 | 1 | 0 | 0 | 0 |
| + prefixo persistente + rascunho | 0 | 1 | 0 | 0 | 0 |

Térmica ao fim de cada passo (todas as condições): {'fair': 71, 'serious': 5, 'nominal': 8}.

## Consistência contra a referência (chamadas e argumentos; texto final = TEXT)

- + prefixo persistente: 3 trajetórias idênticas; 21/21 passos iguais antes da divergência.
- + rascunho da gramática: 3 trajetórias idênticas; 21/21 passos iguais antes da divergência.
- + prefixo persistente + rascunho: 3 trajetórias idênticas; 21/21 passos iguais antes da divergência.
