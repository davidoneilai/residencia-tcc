# TEST da especulação MTP em pipeline — protocolo congelado (2026-11-11, antes de qualquer execução TEST)

**Pergunta.** Somar a especulação MTP em pipeline com escalonador por custo à pilha reduz o tempo por tarefa sem perder
acerto, em tarefas nunca usadas para escolher nada?

**Só roda se o DEV passar** ([PROTOCOL-mtp.md](PROTOCOL-mtp.md), H1 e H2, decisão automática por
`analysis/runtime/mtp_decide.py` em `reports/runtime/mtp-dev-decision.json`).

**Fatia.** As 32 entradas TEST de `results/bfcl-mt/slice.json` (seed 20261104). Elas já rodaram no TEST da pilha
(2026-11-09/10), mas nunca com a MTP e nunca para escolher nada da MTP.

**Ressalva.** O limiar do escalonador e o vocabulário foram escolhidos em microbenchmarks sobre passos gravados de
tarefas do TEST (`results/runtime/decode1-requests.json`). Esses parâmetros só mexem no tempo, e o ganho foi plano entre
0,7 e 0,9. Mesmo assim, o TEST de tempo não é totalmente independente; isso vai declarado em qualquer relato.

**Ambiente.** `bfcl-eval` 2026.3.23 `multi_turn_base` sem alterações; iPhone 16 Pro, greedy, teto 1024 por passo.
Build `MLX_LM_MAIN` (`~/VSCODE/MobileLLMBench-lfm3`, mlx-swift-lm `ec4c966a`) compilado em 2026-11-10 23:37:09 (data do `MobileLLMBench.debug.dylib`), binário
sha256 `29ffbc81f88d3876`. Qwen3.5-2B-4bit; cabeça MTP oficial `Qwen/Qwen3.5-2B` (`mtp.*`) em
`Documents/mtp/qwen35/`. Conexão pelo cabo (`iphone_proxy.py`).

## Condições (congeladas)

| Condição | O que é |
|---|---|
| `dacs-persist-kv` | pilha (DAC + `think_budget` 512 + `repeat_guard` + prefixo persistente) |
| `dacs-persist-mtp-kv` | pilha + `MTPPipelineIterator` (`mtp_pipe` subset, `mtp_top` 16384, `mtp_gate` 0,9) |

## Execução

- Prefixos em disco apagados no início.
- Rodadas `tzA` e `tzB`, cada uma com 32 entradas × 2 condições, na ordem girada do `run_eval.py`.
- Reset dos KV em memória por execução e espera térmica do `cool()`.

## Critério de sucesso (`mtp_decide.py`, pares = mesma rodada e entrada, 64 pares)

1. **Tempo:** Δ médio por par (MTP − pilha), com IC95% bootstrap (10 000 reamostras, seed 0) **inteiro abaixo de
   zero**.
2. **Acerto:** perda líquida de no máximo 1 par e, se houver perda líquida, McNemar exato com p ≥ 0,05.

Análise descritiva: `analyze_dac.py` em `reports/runtime/test-mtp.md` e o tempo de decode por passo.

## Hashes (sha256, 16 primeiros)

| Arquivo | sha256 |
|---|---|
| `analysis/bfcl_mt/bfcl.py` | `c51872e0783cb687` |
| `analysis/bfcl_mt/dac.py` | `b0cf2762d310cc9e` |
| `analysis/bfcl_mt/controller.py` | `c192f99fe2eb8745` |
| `analysis/runtime/run_eval.py` | `6944953c4704e13d` |
| `analysis/runtime/microbench.py` | `7bc50f1fc763c059` |
| `analysis/runtime/mtp_decide.py` | `5868d7ac3fb785f6` |
| `analysis/runtime/chains/test-mtp.sh` | `5cb8c8042ec28ddf` |
| `MobileLLMCore/MLXPhoneBackend.swift` | `88b935777d054f08` |
| `MobileLLMCore/MTPPipeline.swift` | `f5096850e51a245c` |
| `MobileLLMCore/MTPHead.swift` | `1961a39dc0331fe5` |
| `MobileLLMCore/ThinkBudget.swift` | `2d9b86c54dbf0cb5` |
| `MobileLLMCore/PrefixStore.swift` | `9d61e79541c6344f` |
| `MobileLLMBench/InferenceServer.swift` | `1bf1c1784098dd7a` |
| `results/bfcl-mt/slice.json` | `327b555bf26e97bf` |
