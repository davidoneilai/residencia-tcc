# Pilha em mais SLMs, build atual — protocolo (fixado em 2026-11-09, antes da execução)

**Pergunta.** A pilha (DAC + guardas + prefixo persistente) reduz o tempo sem perder acerto em outros SLMs, e quanto
ela ganha fria (catálogo nunca visto) e quente (catálogo já gravado), agora sem o despejo do `PrefixStore`
(limite 4 → 48, ver `PROTOCOL-sft.md`)?

**Build:** o mesmo do estudo SFT (mlx-swift-lm 3.31.4). O LFM3 fica para um build separado, depois.
**Fatia:** as 12 entradas DEV. **As 32 TEST não rodam.**

## Modelos e condições (estratégia = melhor fixa de cada modelo, a mesma que a DAC envolve)

| Modelo | Referência | Pilha |
|---|---|---|
| `lfm25` (LFM2.5-2.6B, sempre pensa) | `rt-base-kv` (Reasoning, think_budget 512) | `dacs-persist-kv` |
| `gemma4` (Gemma 4 E2B) | `nt-base-kv` (NoThink) | `nt-dacs-persist-kv` |
| `qwen35` (Qwen3.5-2B, de novo) | `rt-base-kv` | `dacs-persist-kv` |

Smoke 2026-11-09: LFM2.5 com think_budget 64 fecha o `</think>` à força e faz as 2 chamadas; Gemma 4 nothink faz as 2.

## Execução

- Antes de começar: prefixos do disco apagados (`/v1/debug/reset {"disk": true}`).
- Por modelo, rodada A (`<m>A`): referência + pilha (a pilha é fria: 1ª vez de cada catálogo). Rodada B (`<m>B`): só
  a pilha (quente). Ordem: LFM2.5, Gemma 4, Qwen3.5.
- Condições giram por entrada; espera térmica antes de cada execução; o runner espera o iPhone se a rede cair.

## Leitura pré-registrada

- Por modelo: Δ tempo pilha × referência, pareado por entrada (IC95% bootstrap), fria (A) e quente (B contra a
  referência de A); acerto pareado (McNemar). ±1–2/12 em acerto é ruído numérico possível.
- A pilha conta como "funciona no modelo" se o IC do Δ quente ficar abaixo de zero com acerto igual (±1).
- Qwen3.5: comparar o Δ quente com o −40% de `st2`+`st3` (que tinha ~metade das execuções quentes refazendo o prefixo).
