#!/bin/zsh
cd /Users/macbookpro/VSCODE/residencia-tcc
IDS=$(python3 -c "import json;print(','.join(json.load(open('results/bfcl-mt/slice.json'))['dev']))")
export BENCH_RUNS="sf1@qwen35_sft:rt-base-kv+dacs-persist-kv,sfm@minicpm5:nt-base-kv+nt-dacs-persist-kv,sfms@minicpm5_sft:nt-base-kv+nt-dacs-persist-kv"
BENCH_SLM=qwen35_sft .bfcl-venv/bin/python analysis/runtime/run_eval.py sf1 $IDS rt-base-kv dacs-persist-kv
BENCH_SLM=minicpm5 .bfcl-venv/bin/python analysis/runtime/run_eval.py sfm $IDS nt-base-kv nt-dacs-persist-kv
BENCH_SLM=minicpm5_sft .bfcl-venv/bin/python analysis/runtime/run_eval.py sfms $IDS nt-base-kv nt-dacs-persist-kv
echo "$(date +%T) ALL DONE"
