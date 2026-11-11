#!/bin/zsh
cd "$(dirname "$0")/../../.."
while pgrep -f "microbench.py draft" > /dev/null; do sleep 15; done
echo "$(date +%T) prefix bench" 
.bfcl-venv/bin/python analysis/runtime/microbench.py prefix results/runtime/decode1-requests.json results/runtime/prefix-cold-warm.jsonl 0,8,14
echo "$(date +%T) priming"
.bfcl-venv/bin/python - <<'PY'
import json, os, sys
sys.path.insert(0, 'analysis/runtime')
import microbench as mb
items = json.load(open(os.path.expandvars('results/runtime/decode1-requests.json')))
for i in (0, 8, 14):
    mb.post('/v1/debug/reset', {})
    r = mb.run(items[i]['req'], persist_prefix=True)
    print(i, r['prefix_source'], r['prefix_save_ms'], r['prefix_load_ms'], flush=True)
PY
echo "$(date +%T) eval"
.bfcl-venv/bin/python analysis/runtime/run_eval.py rt1 multi_turn_base_124,multi_turn_base_163,multi_turn_base_169
echo "$(date +%T) ALL DONE"
