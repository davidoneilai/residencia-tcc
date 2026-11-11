#!/bin/zsh
# DEV 2 da MTP (PROTOCOL-mtp2.md): aquecimento dos prefixos, depois 4 rodadas medidas.
cd /Users/macbookpro/VSCODE/residencia-tcc
export IPHONE_URL=${IPHONE_URL:-"http://127.0.0.1:18080"}
export OPENAI_BASE_URL=${OPENAI_BASE_URL:-"$IPHONE_URL/v1"}
IDS=$(python3 -c "import json;print(','.join(json.load(open('results/bfcl-mt/slice.json'))['dev']))")
P=.bfcl-venv/bin/python
echo "$(date +%T) apagando prefixos em disco"
curl -s -X POST -H 'content-type: application/json' -d '{"disk": true}' $IPHONE_URL/v1/debug/reset; echo
export BENCH_RUNS="mw0@qwen35:dacs-persist-kv,mw1@qwen35:dacs-persist-kv+dacs-persist-mtp-kv,mw2@qwen35:dacs-persist-kv+dacs-persist-mtp-kv,mw3@qwen35:dacs-persist-kv+dacs-persist-mtp-kv,mw4@qwen35:dacs-persist-kv+dacs-persist-mtp-kv"
BENCH_SLM=qwen35 $P analysis/runtime/run_eval.py mw0 $IDS dacs-persist-kv
for R in mw1 mw2 mw3 mw4; do
  BENCH_SLM=qwen35 $P analysis/runtime/run_eval.py $R $IDS dacs-persist-kv dacs-persist-mtp-kv
done
BENCH_SLM=qwen35 $P analysis/bfcl_mt/analyze_dac.py reports/runtime/mtp-dev2.md mw1 mw2 mw3 mw4 \
  --conds dacs-persist-kv,dacs-persist-mtp-kv --ref dacs-persist-kv
python3 analysis/runtime/mtp_decide.py reports/runtime/mtp-dev2.json dacs-persist-kv dacs-persist-mtp-kv \
  reports/runtime/mtp-dev2-decision.json
echo "$(date +%T) ALL DONE"
