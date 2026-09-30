#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
STRATEGY="${1:-direct}"
EXTRA=()
case "$STRATEGY" in
  direct|plan_act) EXTRA+=(--no-enable-prefix-caching) ;;
  prefix) EXTRA+=(--enable-prefix-caching) ;;
  speculative)
    EXTRA+=(--no-enable-prefix-caching)
    EXTRA+=(--speculative-config '{"method":"mtp","model":"google/gemma-4-E2B-it-assistant","num_speculative_tokens":2}')
    ;;
  *) echo "estrategia desconhecida: $STRATEGY" >&2; exit 1 ;;
esac
exec vllm serve google/gemma-4-E2B-it \
  --host 127.0.0.1 --port 8000 \
  --served-model-name gemma4_e2b \
  --tensor-parallel-size 1 \
  --max-model-len 8192 \
  --gpu-memory-utilization 0.90 \
  --enable-auto-tool-choice \
  --tool-call-parser gemma4 \
  "${EXTRA[@]}"
