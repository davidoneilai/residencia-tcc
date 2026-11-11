#!/bin/zsh
# TEST congelado 2 da MTP (PROTOCOL-TEST-mtp2.md): aquecimento tw0, depois tw1 e tw2 medidas (32 TEST × 2 condições).
cd /Users/macbookpro/VSCODE/residencia-tcc
export IPHONE_URL=${IPHONE_URL:-"http://127.0.0.1:18080"}
export OPENAI_BASE_URL=${OPENAI_BASE_URL:-"$IPHONE_URL/v1"}
IDS=$(python3 -c "import json;print(','.join(json.load(open('results/bfcl-mt/slice.json'))['test']))")
P=.bfcl-venv/bin/python
echo "$(date +%T) apagando prefixos em disco"
curl -s -X POST -H 'content-type: application/json' -d '{"disk": true}' $IPHONE_URL/v1/debug/reset; echo
export BENCH_RUNS="tw0@qwen35:dacs-persist-kv,tw1@qwen35:dacs-persist-kv+dacs-persist-mtp-kv,tw2@qwen35:dacs-persist-kv+dacs-persist-mtp-kv"
BENCH_SLM=qwen35 $P analysis/runtime/run_eval.py tw0 $IDS dacs-persist-kv
for R in tw1 tw2; do
  BENCH_SLM=qwen35 $P analysis/runtime/run_eval.py $R $IDS dacs-persist-kv dacs-persist-mtp-kv
done
BENCH_SLM=qwen35 $P analysis/bfcl_mt/analyze_dac.py reports/runtime/test-mtp2.md tw1 tw2 \
  --conds dacs-persist-kv,dacs-persist-mtp-kv --ref dacs-persist-kv
python3 analysis/runtime/mtp_decide.py reports/runtime/test-mtp2.json dacs-persist-kv dacs-persist-mtp-kv \
  reports/runtime/test-mtp2-decision.json
echo "$(date +%T) ALL DONE"
