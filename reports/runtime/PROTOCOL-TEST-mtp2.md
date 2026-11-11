# TEST 2 da especulação MTP com prefixo aquecido — protocolo congelado (2026-11-11, antes de qualquer execução)

**Pergunta.** Somar à pilha a especulação MTP em pipeline com escalonador por custo reduz o tempo por tarefa sem
perder acerto nas 32 tarefas TEST?

**Origem.** DEV 2 ([PROTOCOL-mtp2.md](PROTOCOL-mtp2.md), [mtp-dev2.md](mtp-dev2.md)) passou com 48 pares:
−13,1%, IC95% [−8,4; −4,0] s, acerto 16 = 16. O [PROTOCOL-TEST-mtp.md](PROTOCOL-TEST-mtp.md) nunca rodou (o DEV 1
não passou) e é substituído por este.

**Fatia.** As 32 entradas TEST de `results/bfcl-mt/slice.json`. Elas já rodaram no TEST da pilha (2026-11-09/10),
mas nunca com a MTP.

**Ressalva.** O limiar e o vocabulário foram escolhidos em microbenchmarks sobre passos gravados de tarefas do TEST
(`results/runtime/decode1-requests.json`). Esses parâmetros só mexem no tempo, e o ganho foi plano entre 0,7 e 0,9.
Isso vai declarado em qualquer relato.

**Ambiente.** `bfcl-eval` 2026.3.23 `multi_turn_base`; iPhone 16 Pro, greedy, teto 1024 por passo. Build
`MLX_LM_MAIN` (`~/VSCODE/MobileLLMBench-lfm3`, mlx-swift-lm `ec4c966a`), `MobileLLMBench.debug.dylib` de 2026-11-10 23:37:09,
sha256 `29ffbc81f88d3876`. Qwen3.5-2B-4bit, cabeça MTP oficial `Qwen/Qwen3.5-2B`, conexão pelo cabo.

## Condições (congeladas)

| Condição | O que é |
|---|---|
| `dacs-persist-kv` | pilha (DAC + `think_budget` 512 + `repeat_guard` + prefixo persistente) |
| `dacs-persist-mtp-kv` | pilha + `MTPPipelineIterator` (`mtp_pipe` subset, `mtp_top` 16384, `mtp_gate` 0,9, contexto 256) |

## Execução

- **Aquecimento `tw0`** (não analisado): prefixos em disco apagados, depois cada entrada uma vez só com
  `dacs-persist-kv`.
- **Medição:** `tw1` e `tw2`, cada uma com 32 entradas × 2 condições na ordem girada do `run_eval.py`; são 64 pares.
- Reset dos KV em memória por execução e espera térmica do `cool()`.

## Critério de sucesso (`mtp_decide.py`, perda máxima 1)

1. **Tempo:** IC95% bootstrap (10 000 reamostras, seed 0) do Δ médio por par inteiro abaixo de zero.
2. **Acerto:** perda líquida ≤ 1 e, se positiva, McNemar exato com p ≥ 0,05.

## Hashes (sha256, 16 primeiros)

| Arquivo | sha256 |
|---|---|
| `analysis/bfcl_mt/bfcl.py` | `c51872e0783cb687` |
| `analysis/bfcl_mt/dac.py` | `b0cf2762d310cc9e` |
| `analysis/bfcl_mt/controller.py` | `c192f99fe2eb8745` |
| `analysis/bfcl_mt/analyze_dac.py` | `d96857993c07040f` |
| `analysis/runtime/run_eval.py` | `6944953c4704e13d` |
| `analysis/runtime/microbench.py` | `7bc50f1fc763c059` |
| `analysis/runtime/mtp_decide.py` | `5868d7ac3fb785f6` |
| `analysis/runtime/chains/test-mtp2.sh` | `b1307941878e7166` |
| `MobileLLMCore/MLXPhoneBackend.swift` | `88b935777d054f08` |
| `MobileLLMCore/MTPPipeline.swift` | `f5096850e51a245c` |
| `MobileLLMCore/MTPHead.swift` | `1961a39dc0331fe5` |
| `MobileLLMCore/ThinkBudget.swift` | `2d9b86c54dbf0cb5` |
| `MobileLLMCore/PrefixStore.swift` | `9d61e79541c6344f` |
| `MobileLLMBench/InferenceServer.swift` | `1bf1c1784098dd7a` |
| `results/bfcl-mt/slice.json` | `327b555bf26e97bf` |
