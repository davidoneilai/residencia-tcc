#!/bin/zsh
# DEV da especulação MTP em pipeline (PROTOCOL-mtp.md): pilha vs pilha + MTP, 2 repetições, build MLX_LM_MAIN.
cd /Users/macbookpro/VSCODE/residencia-tcc
export IPHONE_URL=${IPHONE_URL:-"http://127.0.0.1:18080"}
export OPENAI_BASE_URL=${OPENAI_BASE_URL:-"$IPHONE_URL/v1"}
IDS=$(python3 -c "import json;print(','.join(json.load(open('results/bfcl-mt/slice.json'))['dev']))")
P=.bfcl-venv/bin/python
echo "$(date +%T) apagando prefixos em disco"
curl -s -X POST -H 'content-type: application/json' -d '{"disk": true}' $IPHONE_URL/v1/debug/reset; echo
export BENCH_RUNS="mtA,mtB"
for R in mtA mtB; do
  BENCH_SLM=qwen35 $P analysis/runtime/run_eval.py $R $IDS dacs-persist-kv dacs-persist-mtp-kv
done
BENCH_SLM=qwen35 $P analysis/bfcl_mt/analyze_dac.py reports/runtime/mtp-dev.md mtA mtB \
  --conds dacs-persist-kv,dacs-persist-mtp-kv --ref dacs-persist-kv
echo "$(date +%T) ALL DONE"
