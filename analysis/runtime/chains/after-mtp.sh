#!/bin/zsh
# Noite de 2026-11-11 (pedido do usuário): espera o DEV da MTP, aplica o critério do PROTOCOL-mtp.md; se passar, roda
# o TEST congelado (PROTOCOL-TEST-mtp.md) e o analisa; no fim reinicia o iPhone e suspende o Mac.
cd /Users/macbookpro/VSCODE/residencia-tcc
export DEVELOPER_DIR=/Applications/Xcode_27.app/Contents/Developer _ZO_DOCTOR=0
P=.bfcl-venv/bin/python; A=analysis/bfcl_mt/analyze_dac.py; D=analysis/runtime/mtp_decide.py
until grep -q "ALL DONE" results/runtime/mtp-dev-chain.log || ! pgrep -f "chains/mtp.sh" >/dev/null; do sleep 60; done
echo "$(date '+%F %T') DEV terminou"
[ -f reports/runtime/mtp-dev.json ] || BENCH_SLM=qwen35 $P $A reports/runtime/mtp-dev.md mtA mtB \
  --conds dacs-persist-kv,dacs-persist-mtp-kv --ref dacs-persist-kv
if python3 $D reports/runtime/mtp-dev.json dacs-persist-kv dacs-persist-mtp-kv reports/runtime/mtp-dev-decision.json; then
  echo "$(date '+%F %T') DEV passou: TEST"
  shasum -a 256 $(sed -n 's/^| `\([^`]*\)` | `[0-9a-f]*` |$/\1/p' reports/runtime/PROTOCOL-TEST-mtp.md) \
    | cut -c1-16 > results/runtime/test-mtp-hashes-at-start.txt
  caffeinate -dims zsh analysis/runtime/chains/test-mtp.sh > results/runtime/test-mtp-chain.log 2>&1
  BENCH_SLM=qwen35 $P $A reports/runtime/test-mtp.md tzA tzB --conds dacs-persist-kv,dacs-persist-mtp-kv \
    --ref dacs-persist-kv
  python3 $D reports/runtime/test-mtp.json dacs-persist-kv dacs-persist-mtp-kv reports/runtime/test-mtp-decision.json
  echo "$(date '+%F %T') TEST analisado (rc=$?)"
else
  echo "$(date '+%F %T') DEV não passou: TEST não roda"
fi
xcrun devicectl device reboot --device 00008140-000909890101801C --timeout 120
echo "$(date '+%F %T') iPhone reiniciado (rc=$?)"
sleep 20
pmset sleepnow
