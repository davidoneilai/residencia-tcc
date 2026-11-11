# Pilha completa no iPhone — protocolo (fixado em 2026-11-07, antes da execução)

**Pergunta.** O prefixo persistente (lado do prefill) e a DACS (lado do decode) se somam? Quanto da economia do
prefixo sobrevive quando o catálogo de ferramentas ainda não foi visto (frio) e quando se repete (quente)?

**Modelo e ambiente.** Igual ao estudo DAC (`reports/dac/PROTOCOL.md`): Qwen3.5-2B-4bit no iPhone 16 Pro,
`InferenceServer`, greedy, teto 1024, `bfcl-eval` 2026.3.23 `multi_turn_base` sem alterações.
**Fatia:** as 12 entradas DEV de `results/bfcl-mt/slice.json`. **As 32 TEST não rodam.**

## Condições (2 × 2)

| Chave | Prefixo persistente | DACS (recuperação + think_budget 512 + repeat_guard) |
|---|---|---|
| `rt-base-kv` | não | não (só think_budget 512) |
| `rt-persist-kv` | sim | não |
| `dacs-kv` | não | sim |
| `dacs-persist-kv` | sim | sim |

## Execução

- 3 rodadas (`st1`, `st2`, `st3`) × 12 entradas × 4 condições (`analysis/runtime/run_eval.py`). As condições giram
  por entrada dentro da rodada e a ordem base gira uma posição por rodada.
- Antes de `st1` o prefixo persistido em disco é apagado (`/v1/debug/reset {"disk": true}`): em `st1` a primeira
  execução de cada catálogo paga a construção e a gravação (frio); `st2`/`st3` medem o uso repetido (quente).
  A origem do prefixo de cada passo fica no trace (`prefix_source`).
- Antes de cada execução: KV em memória apagado e espera térmica (`cool()`, até 10 min).
- Mac com `caffeinate -dims`, tampa aberta, cabo; iPhone com Auto-Lock em Nunca.

## Leitura pré-registrada

- Primária: Δ tempo por entrada de `rt-persist-kv` e `dacs-persist-kv` contra `rt-base-kv`, pareado por
  entrada × rodada, IC95% bootstrap; em separado para `st1` (frio) e `st2`+`st3` (quente).
- Acerto: McNemar pareado; ±1–2/12 é ruído numérico (caminhos de cache diferentes, ver PROTOCOL do DAC).
- Aditividade: Δ(pilha) contra Δ(prefixo) + Δ(DACS).
- Se o ganho quente do prefixo for ≥ 20% com IC abaixo de zero e acerto igual, a pilha é congelada para o TEST.
