# SFT no iPhone — protocolo (fixado em 2026-11-08, antes da execução)

**Pergunta.** Os LoRA de SFT agêntico do autor (`davidoneil/agent-sft-*-lora`) aplicados em runtime sobre a base MLX
4 bits sobem o acerto no BFCL Multi-Turn DEV, e a pilha (DAC + prefixo persistente) mantém a economia de tempo neles?

**Fatia:** as 12 entradas DEV de `results/bfcl-mt/slice.json`. **As 32 TEST não rodam.**
Harness, simulador e scorer: `bfcl-eval` 2026.3.23 `multi_turn_base`, sem alterações. iPhone 16 Pro, greedy, teto 1024.

## Modelos e condições

| Rodada | Modelo | Referência | Pilha |
|---|---|---|---|
| `sf1` | `qwen35_sft` (LoRA @d8ede2e, template da base, `.xmlFunction`) | `rt-base-kv` (Reasoning, think_budget 512) | `dacs-persist-kv` |
| `sfm` | `minicpm5` (base) | `nt-base-kv` (NoThink) | `nt-dacs-persist-kv` (DAC nothink + repeat_guard + prefixo) |
| `sfms` | `minicpm5_sft` (LoRA @9061295, template do treino) | `nt-base-kv` | `nt-dacs-persist-kv` |

Qwen3.5 base: as mesmas duas condições já medidas em `st1`–`st3` (2026-11-07), mesma fatia.

**Por que NoThink no MiniCPM5.** O `</think>` do MiniCPM5 não é um token só, então o think_budget não fecha o
raciocínio; no smoke de 2026-11-08 o SFT com thinking entrou em laço ("Wait, but…") e estourou o teto sem chamada.
NoThink é a melhor fixa do MiniCPM5 no estudo AST.

## Mudanças de runtime desde `st1`–`st3` (todas verificadas antes)

- `PrefixStore.maxFiles` 4 → 48: com 4, os 12 catálogos se despejavam e ~metade das execuções "quentes" com prefixo
  refez o prefixo (traces de `st2`/`st3`). Só afeta condições com prefixo persistente.
- Chave do prefixo inclui o adaptador (`Agent.model`): o KV com LoRA não pode ser lido pela base, nem o contrário.
- Recuperação de chamadas que o parser do stream deixou no texto (Qwen3.5 SFT emite a 2ª chamada sem `<tool_call>`).
  Nos 1062 passos do Qwen3.5 base em `st1`–`st3` isso nunca aconteceu: a base não muda.

## Execução

1 rodada por modelo (greedy é determinístico dentro do mesmo caminho de cache; o acerto não varia entre rodadas,
ver `reports/dac/PROTOCOL.md`). Condições giram por entrada. Prefixos do disco não são apagados: a 1ª execução com
prefixo de cada catálogo é fria e fica marcada no trace (`prefix_source`). Espera térmica antes de cada execução.

## Leitura pré-registrada

- Primária: acerto SFT × base por entrada (pareado, McNemar), na referência e na pilha.
- Secundária: Δ tempo pilha × referência dentro de cada modelo (IC95% bootstrap por entrada).
- ±1–2/12 em acerto é ruído numérico possível; um ganho de SFT só conta como sinal se aparecer nas duas condições.
