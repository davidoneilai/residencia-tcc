#!/bin/zsh
cd /Users/macbookpro/VSCODE/residencia-tcc
IDS=$(python3 -c "import json;print(','.join(json.load(open('results/bfcl-mt/slice.json'))['test']))")
export BENCH_RUNS="tqA@qwen35:rt-base-kv+dacs-persist-kv,tqB@qwen35:dacs-persist-kv,tmA@minicpm5:nt-base-kv+nt-dacs-persist-kv,tmB@minicpm5:nt-dacs-persist-kv,tgA@gemma4:nt-base-kv+nt-dacs-persist-kv,tgB@gemma4:nt-dacs-persist-kv"
P=.bfcl-venv/bin/python
BENCH_SLM=qwen35   $P analysis/runtime/run_eval.py tqA $IDS rt-base-kv dacs-persist-kv
BENCH_SLM=qwen35   $P analysis/runtime/run_eval.py tqB $IDS dacs-persist-kv
BENCH_SLM=minicpm5 $P analysis/runtime/run_eval.py tmA $IDS nt-base-kv nt-dacs-persist-kv
BENCH_SLM=minicpm5 $P analysis/runtime/run_eval.py tmB $IDS nt-dacs-persist-kv
BENCH_SLM=gemma4   $P analysis/runtime/run_eval.py tgA $IDS nt-base-kv nt-dacs-persist-kv
BENCH_SLM=gemma4   $P analysis/runtime/run_eval.py tgB $IDS nt-dacs-persist-kv
echo "$(date +%T) ALL DONE"
