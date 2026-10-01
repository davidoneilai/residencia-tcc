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
    EXTRA+=(--speculative-config '{"method":"ngram","num_speculative_tokens":5,"prompt_lookup_max":4,"prompt_lookup_min":2}')
    ;;
  eagle3)
    EXTRA+=(--no-enable-prefix-caching)
    EXTRA+=(--speculative-config '{"method":"eagle3","model":"AngelSlim/Qwen3-1.7B_eagle3","num_speculative_tokens":2}')
    ;;
  *) echo "estrategia desconhecida: $STRATEGY" >&2; exit 1 ;;
esac
exec vllm serve Qwen/Qwen3-1.7B \
  --host 127.0.0.1 --port 8000 \
  --served-model-name qwen3_1.7b \
  --tensor-parallel-size 1 \
  --max-model-len 8192 \
  --gpu-memory-utilization 0.90 \
  --enable-auto-tool-choice \
  --tool-call-parser hermes \
  "${EXTRA[@]}"
