#!/bin/zsh
# Uma sessão por modelo, em sequência; puxa cada session.json ao terminar.
#   [OUTDIR=results/slm-bfcl] run_sessions.sh <prefixo> '<json sem "agents">' agent1 agent2 ...
set -uo pipefail
cd "$(dirname $0)/../.."
PREFIX=$1; BASE=$2; shift 2
for AGENT in "$@"; do
  OUT=${OUTDIR:-results/slm-bfcl}/$PREFIX-$AGENT.json
  [[ -e $OUT ]] && { echo "$OUT já existe; não sobrescrevo"; continue; }
  CONFIG=$(python3 -c "import json,sys;d=json.loads(sys.argv[1]);d['agents']=[sys.argv[2]];print(json.dumps(d))" "$BASE" "$AGENT")
  analysis/slm_bfcl/device.sh run "$CONFIG" >/dev/null 2>&1 || { echo "$AGENT: launch falhou"; continue; }
  sleep 30
  while true; do
    analysis/slm_bfcl/device.sh pull $OUT >/dev/null 2>&1
    STATE=$(python3 -c "import json;s=json.load(open('$OUT'));a=s['jobs'][0]['agent'] if s['jobs'] else '';print(a, s['finished'], len(s['results']), len(s['jobs']))" 2>/dev/null)
    echo "$(date +%H:%M) $AGENT $STATE"
    [[ $STATE == "$AGENT True"* ]] && break
    sleep 60
  done
done
