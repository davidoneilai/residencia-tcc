#!/bin/zsh
# Estudo B: sessões curtas no iPhone com pausa de resfriamento entre elas (sessão longa teve throttling 32 → 13 tok/s).
#   IPHONE_UDID=… run_blocks.sh <prefixo> <blocos.json> '<strategies json>' [pausa_s=600]
# <blocos.json>: {"blocks": [[ids…], …]}, gerado antes (make_blocks.py). Cada bloco é uma sessão
# results/bfcl-nonlive/<prefixo>-b<k>-qwen35.json. Bloco terminado é pulado; bloco pela metade é retomado com resume.
set -uo pipefail
cd "$(dirname $0)/../.."
PREFIX=$1; BLOCKS=$2; STRATEGIES=$3; PAUSE=${4:-600}
DEVICE=analysis/slm_bfcl/device.sh
N=$(python3 -c "import json,sys;print(len(json.load(open(sys.argv[1]))['blocks']))" $BLOCKS)
state() { python3 -c "import json,sys;s=json.load(open(sys.argv[1]));print(s['finished'], len(s['results']), len(s['jobs']), s['config'].get('taskSetId'))" $1 2>/dev/null; }
for (( k=1; k<=N; k++ )); do
  OUT=results/bfcl-nonlive/$PREFIX-b$k-qwen35.json
  SET=bfcl_v4_nonlive_${PREFIX}_b$k
  [[ -f $OUT && $(state $OUT) == True* ]] && { echo "$(date +%H:%M) bloco $k já terminado"; continue; }
  if [[ -f $OUT ]]; then
    echo "$(date +%H:%M) bloco $k pela metade ($(state $OUT)); resume"
    $DEVICE run '{"run":"resume"}' >/dev/null 2>&1 || { echo "bloco $k: resume falhou"; exit 1; }
  else
    IDS=$(python3 -c "import json,sys;print(json.dumps(json.load(open(sys.argv[1]))['blocks'][int(sys.argv[2])-1]))" $BLOCKS $k)
    CONFIG="{\"run\":\"bfcl-ast\",\"agents\":[\"qwen35\"],\"strategies\":$STRATEGIES,\"taskIDs\":$IDS,\"repetitions\":1,\"seed\":\"20261105\",\"taskSetId\":\"$SET\"}"
    $DEVICE run "$CONFIG" >/dev/null 2>&1 || { echo "bloco $k: launch falhou"; exit 1; }
    echo "$(date +%H:%M) bloco $k/$N lançado"
  fi
  sleep 30
  while true; do
    $DEVICE pull $OUT.tmp >/dev/null 2>&1
    S=$(state $OUT.tmp)
    if [[ $S == *" $SET" ]]; then mv $OUT.tmp $OUT; fi   # só aceita a sessão deste bloco
    echo "$(date +%H:%M) bloco $k: $S"
    [[ $S == True*" $SET" ]] && break
    sleep 60
  done
  (( k < N )) && { echo "$(date +%H:%M) pausa de ${PAUSE}s para resfriar"; sleep $PAUSE; }
done
echo "== fim $(date +%H:%M)"
