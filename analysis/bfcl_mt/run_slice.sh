#!/bin/zsh
# BFCL Multi-Turn no iPhone, fatia congelada (slice.json), todas as condições com KV incremental.
#   analysis/bfcl_mt/run_slice.sh dev [slm ...]
# Por SLM: um aquecimento (carga + kernels), depois entrada a entrada, as condições intercaladas
# (mesmo estado térmico). Retoma: o bfcl pula IDs que já têm resultado; erro de inferência é refeito.
# Se o iPhone some (rede USB/.local, app fechado), espera ele voltar em vez de queimar as entradas.
set -uo pipefail
cd "${0:A:h}/../.."
SLICE=${1:?"dev ou test"}; shift
SLMS=($@); (( $#SLMS )) || SLMS=(qwen35 minicpm5 gemma4 lfm25)
URL=${OPENAI_BASE_URL:-http://iPhone-de-David.local:8080/v1}
PY=.bfcl-venv/bin/python
LOG=results/bfcl-mt/run-$SLICE.log

typeset -A CONDITIONS=(
  qwen35   "direct nothink adaptive"
  minicpm5 "nothink direct adaptive"
  gemma4   "nothink direct adaptive"
  lfm25    "direct adaptive"
)
LOCK=results/bfcl-mt/.run-slice.lock
mkdir $LOCK 2>/dev/null || { print "já há um run_slice rodando ($LOCK); saio"; exit 1; }
trap 'rmdir $LOCK' EXIT

wait_server() {
  local waited=0
  until curl -s -m 10 ${URL%/v1}/health >/dev/null; do
    (( waited % 300 == 0 )) && print -- "$(date +%T) WAIT iPhone não responde; abra o app e confira o cabo" | tee -a $LOG
    sleep 15; (( waited += 15 ))
  done
}

# Verdadeiro se o ID tem resultado de verdade (não um erro de inferência).
has_result() {
  $PY -c "import json,sys;p='results/bfcl-mt/result/iphone-$1-prefix/multi_turn/BFCL_v4_multi_turn_base_result.json'
try: rows=[json.loads(l) for l in open(p) if l.strip()]
except FileNotFoundError: rows=[]
sys.exit(0 if any(r['id']=='$2' and 'latency' in r for r in rows) else 1)"
}

# Progresso na aba "Ao vivo" do app; falha aqui não para o bench.
progress() {
  local done=$(analysis/bfcl_mt/status.sh $SLICE | command grep -oE '[0-9]+/[0-9]+' | head -1)
  curl -s -m 5 $URL/progress -H 'Content-Type: application/json' \
    -d "{\"done\":${done%/*},\"total\":${done#*/},\"label\":\"$SLICE · $1\"}" >/dev/null || true
}

IDS=($($PY -c "import json;print(' '.join(json.load(open('results/bfcl-mt/slice.json'))['$SLICE']))"))

for slm in $SLMS; do
  wait_server
  print -- "== $slm warmup $(date +%T)" | tee -a $LOG
  curl -s -m 900 $URL/chat/completions -H 'Content-Type: application/json' \
    -d "{\"model\":\"$slm:direct\",\"max_tokens\":16,\"messages\":[{\"role\":\"user\",\"content\":\"Hi\"}]}" >/dev/null
  for id in $IDS; do
    print -r -- "{\"multi_turn_base\": [\"$id\"]}" > results/bfcl-mt/test_case_ids_to_generate.json
    for c in ${=CONDITIONS[$slm]}; do
      for attempt in 1 2 3; do
        has_result $slm-$c $id && break
        $PY analysis/bfcl_mt/prune_errors.py iphone-$slm-$c-prefix $id >/dev/null
        wait_server
        print -- "$(date +%T) $slm $c $id" | tee -a $LOG
        progress "$slm $c $id (tentativa $attempt)"
        $PY analysis/bfcl_mt/bfcl.py generate --model iphone-$slm-$c-prefix --run-ids >> $LOG 2>&1
      done
      has_result $slm-$c $id || print -- "FAILED $slm $c $id (3 tentativas)" | tee -a $LOG
    done
  done
done
print -- "== done $(date +%T)" | tee -a $LOG
progress "fim $(date +%T)"
