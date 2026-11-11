#!/bin/zsh
cd /Users/macbookpro/VSCODE/residencia-tcc
IDS=$(python3 -c "import json;print(','.join(json.load(open('results/bfcl-mt/slice.json'))['dev']))")
export BENCH_RUNS="lfA@lfm25:rt-base-kv+dacs-persist-kv,lfB@lfm25:dacs-persist-kv,gmA@gemma4:nt-base-kv+nt-dacs-persist-kv,gmB@gemma4:nt-dacs-persist-kv,qpA@qwen35:rt-base-kv+dacs-persist-kv,qpB@qwen35:dacs-persist-kv"
echo "$(date +%T) apagando prefixos em disco"
curl -s -X POST -H 'content-type: application/json' -d '{"disk": true}' http://iPhone-de-David.local:8080/v1/debug/reset; echo
P=.bfcl-venv/bin/python
BENCH_SLM=lfm25  $P analysis/runtime/run_eval.py lfA $IDS rt-base-kv dacs-persist-kv
BENCH_SLM=lfm25  $P analysis/runtime/run_eval.py lfB $IDS dacs-persist-kv
BENCH_SLM=gemma4 $P analysis/runtime/run_eval.py gmA $IDS nt-base-kv nt-dacs-persist-kv
BENCH_SLM=gemma4 $P analysis/runtime/run_eval.py gmB $IDS nt-dacs-persist-kv
BENCH_SLM=qwen35 $P analysis/runtime/run_eval.py qpA $IDS rt-base-kv dacs-persist-kv
BENCH_SLM=qwen35 $P analysis/runtime/run_eval.py qpB $IDS dacs-persist-kv
echo "$(date +%T) ALL DONE"
