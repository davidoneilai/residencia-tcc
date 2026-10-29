#!/usr/bin/env bash
# Copia a trajetória versionada para iOSWorld/results/ e chama judge_trajectories.py.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RUN_NAME="${RUN_NAME:-single-task-20261029-120427-clock-001}"
SRC="$ROOT/results/iosworld/qwen35-iphone16pro/$RUN_NAME"
IOSWORLD="${IOSWORLD:-$ROOT/../iOSWorld}"
VLLM_BASE_URL="${VLLM_BASE_URL:-http://127.0.0.1:8000/v1}"
EVAL_PROVIDER="${EVAL_PROVIDER:-vllm}"
EVAL_MODEL="${EVAL_MODEL:-qwen3.5-35B-a3}"

[[ -d "$SRC/01-clock-001" ]] || { echo "ERROR: missing $SRC" >&2; exit 2; }
[[ -f "$IOSWORLD/scripts/judge_trajectories.py" ]] || {
  echo "ERROR: iOSWorld not found at $IOSWORLD" >&2
  echo "  git clone https://github.com/ljang0/iOSWorld && export IOSWORLD=..." >&2
  exit 2
}

mkdir -p "$IOSWORLD/results"
rsync -a --delete "$SRC/" "$IOSWORLD/results/$RUN_NAME/"
cd "$IOSWORLD"
export EVAL_PROVIDER EVAL_MODEL VLLM_BASE_URL
exec python3 scripts/judge_trajectories.py --run-dir "results/$RUN_NAME" "$@"
