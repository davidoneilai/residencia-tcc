# Cadeias de execução no iPhone

Scripts que encadearam as rodadas dos estudos de runtime (`reports/runtime/`). Cada `run_eval.py` roda uma rodada:
entradas × condições, com a ordem girada, espera térmica e retomada (pula execuções já gravadas em
`results/bfcl-mt/dac/<rodada>/`).

Rodar a partir da raiz do repositório, com o app `MobileLLMBench` aberto no iPhone, na mesma rede do Mac
(`iPhone-de-David.local:8080`), e com o Mac de tampa aberta:

```bash
nohup caffeinate -dims analysis/runtime/chains/<script>.sh > results/runtime/logs/<script>.log.txt 2>&1 &
```

| Script | Estudo | Rodadas |
|---|---|---|
| `overnight.sh` | microbenchmark de prefixo frio/quente + 1ª tentativa de `rt1` | `results/runtime/prefix-cold-warm.jsonl` |
| `rerun.sh` | `rt1`: prefixo persistente e rascunho da gramática em 3 tarefas DEV | `rt1` |
| `stack.sh` | 2×2 prefixo × DACS no Qwen3.5, DEV × 3 rodadas (apaga os prefixos antes) | `st1`–`st3` |
| `sft.sh` | LoRA de SFT: Qwen3.5 SFT, MiniCPM5 base e SFT, DEV | `sf1`, `sfm`, `sfms` |
| `smoke_sft.py` | smoke de 2 chamadas pelo servidor do iPhone (`python3 smoke_sft.py qwen35:direct …`) | — |
| `models.sh` | pilha em LFM2.5, Gemma 4 e Qwen3.5, DEV, fria (A) e quente (B) | `lfA/B`, `gmA/B`, `qpA/B` |
| `test.sh` | **TEST final** (32 tarefas), protocolo `reports/runtime/PROTOCOL-TEST.md` | `tqA/B`, `tmA/B`, `tgA/B` |
| `test-resume.sh` | o mesmo, sem apagar os prefixos (retomada depois da queda de 2026-11-09) | idem |
| `after-test.sh` | espera o `test.sh` terminar, grava a análise, reinicia o iPhone e suspende o Mac | — |

`BENCH_RUNS` (formato `rodada@modelo:cond+cond,…`) faz a aba Ao vivo contar a cadeia inteira e prever o término.
Os logs das execuções originais estão em `results/runtime/logs/`.
