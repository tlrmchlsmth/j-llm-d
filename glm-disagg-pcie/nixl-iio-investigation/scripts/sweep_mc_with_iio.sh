#!/usr/bin/env bash
# Sweep max-concurrency (MC) values while collecting IIO perf stat on each run.
#
# For each MC value, runs run_e2e_with_iio.sh which:
#   1. Starts perf stat IIO counters on both bare-metal nodes
#   2. Runs the benchmark at that MC level
#   3. Collects perf stat output + benchmark results + Prometheus metrics
#
# Usage: ./sweep_mc_with_iio.sh <output_dir> [ISL] [NUM_PROMPTS] [OSL] [MC_VALUES...]
# Example: ./sweep_mc_with_iio.sh results/mc_sweep_iio
#          ./sweep_mc_with_iio.sh results/mc_sweep_iio 4096 50 256 1 2 4 8
#          ./sweep_mc_with_iio.sh results/isl8192_mc_sweep 8192 30 256 1 2 4
#
# Output structure:
#   <output_dir>/mc<N>/
#     result_mc<N>.txt        - benchmark output
#     decode_mc<N>.log        - vLLM decode pod logs
#     prefill_mc<N>.log       - vLLM prefill pod logs
#     metrics_mc<N>.txt       - Prometheus metric deltas
#     perf_prefill_isl<I>.txt - IIO perf stat from prefill node
#     perf_decode_isl<I>.txt  - IIO perf stat from decode node

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_SCRIPT="${SCRIPT_DIR}/run_e2e_with_iio.sh"

if [ $# -lt 1 ]; then
    echo "Usage: $0 <output_dir> [ISL] [NUM_PROMPTS] [OSL] [MC_VALUES...]"
    echo ""
    echo "Defaults: ISL=4096  NUM_PROMPTS=50  OSL=256  MC_VALUES=1 2 4 8 16"
    echo ""
    echo "Example: $0 results/mc_sweep_iio"
    echo "         $0 results/mc_sweep_iio 4096 50 256 1 2 4 8"
    exit 1
fi

BASE_OUT_DIR="$1"
ISL="${2:-4096}"
NUM_PROMPTS="${3:-50}"
OSL="${4:-256}"

if [ $# -ge 5 ]; then
    MC_VALUES=("${@:5}")
else
    MC_VALUES=(1 2 4 8 16)
fi

echo "=============================================="
echo "MC Sweep with IIO Perf Stat"
echo "=============================================="
echo "  ISL:          $ISL"
echo "  OSL:          $OSL"
echo "  Num prompts:  $NUM_PROMPTS"
echo "  MC values:    ${MC_VALUES[*]}"
echo "  Output:       $BASE_OUT_DIR"
echo "=============================================="
echo ""

TOTAL=${#MC_VALUES[@]}
CURRENT=0
STARTED_AT=$(date +%s)

for MC in "${MC_VALUES[@]}"; do
    CURRENT=$((CURRENT + 1))
    RUN_DIR="${BASE_OUT_DIR}/mc${MC}"

    if [ -d "$RUN_DIR" ] && [ -f "$RUN_DIR/perf_prefill_isl${ISL}.txt" ]; then
        echo "[$CURRENT/$TOTAL] MC=$MC  SKIPPED (perf stat results exist in $RUN_DIR)"
        continue
    fi

    echo "=============================================="
    echo "[$CURRENT/$TOTAL] MC=$MC  ->  $RUN_DIR"
    echo "=============================================="

    bash "$RUN_SCRIPT" "$ISL" "$RUN_DIR" "$MC" "$NUM_PROMPTS" "$OSL"

    ELAPSED=$(( $(date +%s) - STARTED_AT ))
    echo ""
    echo "[$CURRENT/$TOTAL] MC=$MC complete. (elapsed: ${ELAPSED}s)"
    echo ""

    echo "Cooling down 10s before next MC value..."
    sleep 10
done

TOTAL_TIME=$(( $(date +%s) - STARTED_AT ))
echo "=============================================="
echo "MC Sweep with IIO Complete (total: ${TOTAL_TIME}s)"
echo "=============================================="
echo "Results in: $BASE_OUT_DIR"
ls -d "$BASE_OUT_DIR"/mc* 2>/dev/null || true

echo ""
echo "To analyze results:"
echo "  python3 ${SCRIPT_DIR}/analyze_e2e_iio.py $BASE_OUT_DIR"
