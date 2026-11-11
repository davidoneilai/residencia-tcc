#!/bin/zsh
# Depois do TEST: análise no Mac, reinicia o iPhone, suspende o Mac (pedido do usuário em 2026-11-10).
cd /Users/macbookpro/VSCODE/residencia-tcc
export DEVELOPER_DIR=/Applications/Xcode_27.app/Contents/Developer _ZO_DOCTOR=0
until grep -q "ALL DONE" results/runtime/logs/test.log.txt || ! pgrep -f test-resume.sh >/dev/null; do sleep 60; done
echo "$(date '+%F %T') TEST terminou"
P=.bfcl-venv/bin/python; A=analysis/bfcl_mt/analyze_dac.py
BENCH_SLM=qwen35   $P $A reports/runtime/test-qwen35.md   tqA tqB --conds rt-base-kv,dacs-persist-kv --ref rt-base-kv
BENCH_SLM=minicpm5 $P $A reports/runtime/test-minicpm5.md tmA tmB --conds nt-base-kv,nt-dacs-persist-kv --ref nt-base-kv
BENCH_SLM=gemma4   $P $A reports/runtime/test-gemma4.md   tgA tgB --conds nt-base-kv,nt-dacs-persist-kv --ref nt-base-kv
for m in "qwen35 rt-base-kv dacs-persist-kv tqA tqB" "minicpm5 nt-base-kv nt-dacs-persist-kv tmA tmB" "gemma4 nt-base-kv nt-dacs-persist-kv tgA tgB"; do
  a=(${=m}); echo "== ${a[1]}"; python3 analysis/runtime/cold_warm.py reports/runtime/test-${a[1]}.json ${a[2]} ${a[3]} ${a[4]} ${a[5]}
done > reports/runtime/test-cold-warm.txt 2>&1
echo "$(date '+%F %T') análise gravada"
xcrun devicectl device reboot --device 00008140-000909890101801C --timeout 120
echo "$(date '+%F %T') iPhone reiniciado (rc=$?)"
sleep 20
pmset sleepnow
