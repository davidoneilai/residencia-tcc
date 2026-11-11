#!/bin/zsh
cd /Users/macbookpro/VSCODE/residencia-tcc
IDS=$(python3 -c "import json;print(','.join(json.load(open('results/bfcl-mt/slice.json'))['dev']))")
C=(rt-base-kv rt-persist-kv dacs-kv dacs-persist-kv)
echo "$(date +%T) apagando prefixo em disco"
curl -s -X POST -H 'content-type: application/json' -d '{"disk": true}' http://iPhone-de-David.local:8080/v1/debug/reset; echo
for r in 1 2 3; do
  o=$(( r - 1 ))
  order=(${C[@]:$o} ${C[@]:0:$o})
  echo "$(date +%T) rodada st$r: ${order[*]}"
  .bfcl-venv/bin/python analysis/runtime/run_eval.py st$r $IDS ${order[@]}
done
echo "$(date +%T) ALL DONE"
