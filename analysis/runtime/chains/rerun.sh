#!/bin/zsh
cd /Users/macbookpro/VSCODE/residencia-tcc
echo "$(date +%T) priming"
.bfcl-venv/bin/python - <<'PY'
import json, sys
sys.path.insert(0, 'analysis/runtime')
import microbench as mb
items = json.load(open('results/runtime/decode1-requests.json'))
for i in (0, 8, 14):
    mb.post('/v1/debug/reset', {})
    r = mb.run(items[i]['req'], persist_prefix=True)
    print(i, r['prefix_source'], r['prefix_save_ms'], r['prefix_load_ms'], flush=True)
print('files', mb.post('/v1/debug/reset', {})['prefix_files'])
PY
echo "$(date +%T) eval"
.bfcl-venv/bin/python analysis/runtime/run_eval.py rt1 multi_turn_base_124,multi_turn_base_163,multi_turn_base_169
echo "$(date +%T) ALL DONE"
