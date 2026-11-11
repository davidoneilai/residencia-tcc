#!/bin/zsh
# Estudo DAC no iPhone (Qwen3.5-2B): uma rodada = cada entrada × cada condição, intercaladas por entrada.
#   analysis/bfcl_mt/run_dac.sh <rodada> <rep> <dev|id,id,...> <cond> [cond ...]
#   ex.: run_dac.sh r1 0 dev reason-off reason-kv a-kv dac-kv dacs-kv
# Resultados em results/bfcl-mt/dac/<rodada>/ (BFCL_MT_ROOT). Ordem balanceada: na entrada i, as condições giram
# (i + rep) posições, então cada condição passa por todas as posições ao longo das entradas e das repetições.
# Espera a térmica do iPhone sair de serious/critical (até MAX_COOL s) e registra a espera: antes de cada entrada
# (COOL=entry, padrão) ou de cada execução (COOL=run). A rotação equilibra a posição térmica das condições.
# Retoma: o bfcl pula IDs que já têm resultado; erro de inferência é refeito (até 3 tentativas).
set -uo pipefail
cd "${0:A:h}/../.."
RUN=${1:?rodada}; REP=${2:?rep}; WHICH=${3:?"dev ou lista de IDs"}; shift 3
CONDS=($@); (( $#CONDS )) || { print "faltam condições"; exit 1; }
SLM=${SLM:-qwen35}
MAX_COOL=${MAX_COOL:-900}
COOL=${COOL:-entry}
URL=${OPENAI_BASE_URL:-http://iPhone-de-David.local:8080/v1}
PY=.bfcl-venv/bin/python
export BFCL_MT_ROOT=results/bfcl-mt/dac/$RUN
mkdir -p $BFCL_MT_ROOT
LOG=$BFCL_MT_ROOT/run.log
LOCK=results/bfcl-mt/.run-slice.lock
mkdir $LOCK 2>/dev/null || { print "já há um run rodando ($LOCK); saio"; exit 1; }
trap 'rmdir $LOCK' EXIT

if [[ $WHICH == dev || $WHICH == test ]]; then
  IDS=($($PY -c "import json;print(' '.join(json.load(open('results/bfcl-mt/slice.json'))['$WHICH']))"))
else
  IDS=(${(s:,:)WHICH})
fi

health() { curl -s -m 10 ${URL%/v1}/health; }

wait_server() {
  local waited=0
  until health >/dev/null; do
    (( waited % 300 == 0 )) && print -- "$(date +%T) WAIT iPhone não responde; abra o app e confira o cabo" | tee -a $LOG
    sleep 15; (( waited += 15 ))
  done
}

cool() {
  local waited=0 state
  while state=$(health | $PY -c "import json,sys;print(json.load(sys.stdin).get('thermal','?'))" 2>/dev/null); \
        [[ $state == serious || $state == critical ]] && (( waited < MAX_COOL )); do
    (( waited == 0 )) && print -- "$(date +%T) COOL thermal=$state, esperando esfriar (até ${MAX_COOL}s)" | tee -a $LOG
    sleep 30; (( waited += 30 ))
  done
  print -- "$(date +%T) thermal=$state cooled=${waited}s" | tee -a $LOG
}

has_result() {
  $PY -c "import json,sys;p='$BFCL_MT_ROOT/result/iphone-$SLM-dac-$1/multi_turn/BFCL_v4_multi_turn_base_result.json'
try: rows=[json.loads(l) for l in open(p) if l.strip()]
except FileNotFoundError: rows=[]
sys.exit(0 if any(r['id']=='$2' and 'latency' in r for r in rows) else 1)"
}

wait_server
print -- "== $RUN rep=$REP $SLM [$CONDS] ${#IDS} entradas $(date +%T)" | tee -a $LOG
curl -s -m 900 $URL/chat/completions -H 'Content-Type: application/json' \
  -d "{\"model\":\"$SLM:direct\",\"max_tokens\":16,\"messages\":[{\"role\":\"user\",\"content\":\"Hi\"}]}" >/dev/null
n=${#CONDS}; i=0
for id in $IDS; do
  print -r -- "{\"multi_turn_base\": [\"$id\"]}" > $BFCL_MT_ROOT/test_case_ids_to_generate.json
  shift_by=$(( (i + REP) % n )); order=(${CONDS[$((shift_by + 1)),-1]} ${CONDS[1,$shift_by]})
  [[ $COOL == entry ]] && { wait_server; cool; }
  for c in $order; do
    for attempt in 1 2 3; do
      has_result $c $id && break
      $PY analysis/bfcl_mt/prune_errors.py iphone-$SLM-dac-$c $id >/dev/null 2>&1
      wait_server; [[ $COOL == run || $attempt -gt 1 ]] && cool
      print -- "$(date +%T) $c $id (tentativa $attempt)" | tee -a $LOG
      $PY analysis/bfcl_mt/bfcl.py generate --model iphone-$SLM-dac-$c --run-ids >> $LOG 2>&1
    done
    has_result $c $id || print -- "FAILED $c $id (3 tentativas)" | tee -a $LOG
  done
  (( i += 1 ))
done
for c in $CONDS; do
  $PY analysis/bfcl_mt/bfcl.py evaluate --model iphone-$SLM-dac-$c --test-category multi_turn_base --partial-eval >> $LOG 2>&1
done
print -- "== done $(date +%T)" | tee -a $LOG
