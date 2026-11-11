#!/bin/zsh
# TEST congelado da especulação MTP em pipeline (PROTOCOL-TEST-mtp.md): 32 TEST × {pilha, pilha + MTP} × 2 rodadas.
cd /Users/macbookpro/VSCODE/residencia-tcc
export IPHONE_URL=${IPHONE_URL:-"http://127.0.0.1:18080"}
export OPENAI_BASE_URL=${OPENAI_BASE_URL:-"$IPHONE_URL/v1"}
IDS=$(python3 -c "import json;print(','.join(json.load(open('results/bfcl-mt/slice.json'))['test']))")
P=.bfcl-venv/bin/python
echo "$(date +%T) apagando prefixos em disco"
curl -s -X POST -H 'content-type: application/json' -d '{"disk": true}' $IPHONE_URL/v1/debug/reset; echo
export BENCH_RUNS="tzA,tzB"
for R in tzA tzB; do
  BENCH_SLM=qwen35 $P analysis/runtime/run_eval.py $R $IDS dacs-persist-kv dacs-persist-mtp-kv
done
echo "$(date +%T) ALL DONE"
