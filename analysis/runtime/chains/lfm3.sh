#!/bin/zsh
# LFM3 no build novo (PROTOCOL-lfm3.md): escolhe a estratégia no DEV, roda a pilha fria/quente e o Qwen3.5 de referência.
cd /Users/macbookpro/VSCODE/residencia-tcc
# Pelo cabo USB, via repasse local: o nome mDNS resolveu para IPv6 sem rota em 2026-11-10 e o cliente do BFCL
# (`httpcore2`) não aceita endereço com zona. Antes: `python3 analysis/runtime/iphone_proxy.py "fe80::…%en9" 8080 18080`.
export IPHONE_URL=${IPHONE_URL:-"http://127.0.0.1:18080"}
export OPENAI_BASE_URL=${OPENAI_BASE_URL:-"$IPHONE_URL/v1"}
IDS=$(python3 -c "import json;print(','.join(json.load(open('results/bfcl-mt/slice.json'))['dev']))")
P=.bfcl-venv/bin/python
echo "$(date +%T) apagando prefixos em disco"
curl -s -X POST -H 'content-type: application/json' -d '{"disk": true}' $IPHONE_URL/v1/debug/reset; echo
export BENCH_RUNS="lmR@lfm3:rt-base-kv+nt-base-kv"
BENCH_SLM=lfm3 $P analysis/runtime/run_eval.py lmR $IDS rt-base-kv nt-base-kv
BENCH_SLM=lfm3 $P analysis/bfcl_mt/analyze_dac.py reports/runtime/lfm3-lmR.md lmR --conds rt-base-kv,nt-base-kv --ref rt-base-kv
S=$(python3 - <<'PY'
import json
rows = json.load(open('reports/runtime/lfm3-lmR.json'))
stat = {}
for c, strategy in (("rt-base-kv", "direct"), ("nt-base-kv", "nothink")):
    xs = [r for r in rows if r["cond"] == c]
    stat[strategy] = {"cond": c, "ok": sum(r["ok"] for r in xs), "mean_s": sum(r["latency_s"] for r in xs) / len(xs), "n": len(xs)}
best = sorted(stat, key=lambda s: (-stat[s]["ok"], stat[s]["mean_s"]))[0]
json.dump({"chosen": best, "rule": "mais acerto; empate -> menor tempo médio", "lmR": stat},
          open('reports/runtime/lfm3-strategy.json', 'w'), indent=1, ensure_ascii=False)
print(best)
PY
)
echo "$(date +%T) estratégia escolhida: $S"
export DAC_FIXED_LFM3=$S
if [ "$S" = direct ]; then STACK=dacs-persist-kv; else STACK=nt-dacs-persist-kv; fi
export BENCH_RUNS="lmA@lfm3:$STACK,lmB@lfm3:$STACK,qnA@qwen35:rt-base-kv+dacs-persist-kv,qnB@qwen35:dacs-persist-kv"
BENCH_SLM=lfm3   $P analysis/runtime/run_eval.py lmA $IDS $STACK
BENCH_SLM=lfm3   $P analysis/runtime/run_eval.py lmB $IDS $STACK
BENCH_SLM=qwen35 $P analysis/runtime/run_eval.py qnA $IDS rt-base-kv dacs-persist-kv
BENCH_SLM=qwen35 $P analysis/runtime/run_eval.py qnB $IDS dacs-persist-kv
echo "$(date +%T) ALL DONE"
