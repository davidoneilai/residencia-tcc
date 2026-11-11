# Análise offline

## Runtime no iPhone (estudo principal, `reports/runtime/`)

Rodam no Mac; só `run_eval.py`, `microbench.py` e as cadeias falam com o iPhone.

| Script | O que faz |
|---|---|
| `runtime/run_eval.py` | Uma rodada BFCL Multi-Turn no iPhone: entradas × condições, ordem girada, espera térmica, retomada, progresso na aba Ao vivo |
| `bfcl_mt/bfcl.py` | Registra no `bfcl-eval` cada condição (`rt-base-kv`, `dacs-persist-kv`, `nt-*`…) por modelo; `generate` e `evaluate` |
| `bfcl_mt/dac.py` | Política DAC (nota + tentativa extra na 2ª repetição/erro) e o trace por passo |
| `bfcl_mt/analyze_dac.py` | Tabelas por condição, pareado com McNemar e IC bootstrap; grava `<saída>.json` por execução (`BENCH_SLM=<modelo>`) |
| `runtime/cold_warm.py` | Pilha fria (rodada A) e quente (rodada B) contra a referência da rodada A |
| `runtime/figures.py` | Figura do TEST (`reports/runtime/figures/test-latency.{png,svg}`) |
| `runtime/microbench.py` | Microbenchmarks: custo por passada, rascunho da gramática, prefixo frio/quente |
| `runtime/lora_check.py` | Confere a aplicação do LoRA (runtime × fundido pelo PEFT, 4 bits × bf16) no Mac |
| `runtime/chains/` | Scripts que encadearam as rodadas no iPhone ([README](runtime/chains/README.md)) |

## App (protocolo 2, estudos anteriores)

Lê o JSON exportado pelo app, inclusive o array antigo sem os campos do protocolo 2.

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install pandas matplotlib
python analyze.py --check
python analyze.py --input ../results/iphone16pro_qwen_thinking_2026-10-08.json --out ../results/analysis-out
```

Roteamento adaptativo (oracle + heurística + learned) sobre a sessão cross-model:

```bash
python adaptive_routing/run_experiment.py --check
python adaptive_routing/run_experiment.py --input ../results/cross-model-2026-10-13.json --out ../reports/adaptive-routing
```

Ver `adaptive_routing/README.md` e `reports/adaptive-routing/REPORT.md`.

Relatório semanal da residência (a partir da raiz do repositório; não relança o iPhone):

```bash
python3 analysis/weekly/generate.py 2026-W44
python3 analysis/weekly/generate.py --check
```

Saída em `reports/weekly/YYYY-WXX/`.

Gera `summary.csv`, `failure_analysis.csv`, `pareto.png`, `pareto.svg`, `accuracy_by_category.png`, `latency_by_strategy.png` e `report.md`.

A taxa de sucesso usa só tentativas que rodaram. Timeout térmico e cancelamento ficam em `not_run`. A latência é `totalLatencyMs`. No JSON antigo, sem esse campo, a conta é `totalMs - modelLoadMs`. Cold-start e warm-start ficam em colunas separadas. Se as estratégias não avaliaram os mesmos IDs, o gráfico de Pareto não traça fronteira. Com uma repetição, o relatório marca a análise como exploratória.
