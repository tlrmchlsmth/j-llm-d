#!/bin/bash

# MC Sweep: runs the benchmark at multiple max-concurrency values (fixed OSL).
# Usage: ./sweep_mc.sh <output_dir> [scenario] [isl] [mc_values...]
# Example: ./sweep_mc.sh results/mc_sweep_scenario1
#          ./sweep_mc.sh results/mc_sweep_scenario2r2 2r2
#          ./sweep_mc.sh results/isl8192_mc_sweep_s1 1 8192 1 2 3 4 6 8
#
# Defaults: SCENARIO=1  ISL=4096  OSL=256  MC_VALUES=1..16,20,24,32
#
# Skips MC values whose output directory already exists (safe to re-run).
# For each MC, calls sweep_concurrency_with_kv_transfer_logs.sh and writes
# results to <output_dir>/scenario<S>_rails<R>_ISL<I>_MC<M>/

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SWEEP_SCRIPT="$SCRIPT_DIR/../glm-disagg/sweep_concurrency_with_kv_transfer_logs.sh"

if [ $# -lt 1 ]; then
    echo "Usage: $0 <output_dir> [scenario] [isl] [mc_values...]"
    echo "Example: $0 results/mc_sweep_scenario1"
    echo "         $0 results/mc_sweep_scenario2r2 2r2"
    echo "         $0 results/isl8192_mc_sweep_s1 1 8192 1 2 3 4 6 8"
    exit 1
fi

BASE_OUT_DIR="$1"
SCENARIO="${2:-1}"
case "$SCENARIO" in
    *r2) RAILS=2 ;;
    *)   RAILS=1 ;;
esac
ISL="${3:-4096}"
OSL=256

if [ $# -ge 4 ]; then
    MC_VALUES=("${@:4}")
else
    MC_VALUES=(1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 20 24 32)
fi

echo "=============================================="
echo "MC Sweep"
echo "=============================================="
echo "  Scenario:  $SCENARIO"
echo "  Rails:     $RAILS"
echo "  ISL:       $ISL"
echo "  OSL:       $OSL"
echo "  MC vals:   ${MC_VALUES[*]}"
echo "  Base dir:  $BASE_OUT_DIR"
echo "=============================================="
echo ""

TOTAL=${#MC_VALUES[@]}
CURRENT=0
STARTED_AT=$(date +%s)

for MC in "${MC_VALUES[@]}"; do
    CURRENT=$((CURRENT + 1))
    RUN_DIR="${BASE_OUT_DIR}/scenario${SCENARIO}_rails${RAILS}_ISL${ISL}_MC${MC}"

    if [ -d "$RUN_DIR" ] && [ -f "$RUN_DIR/result_mc${MC}.txt" ]; then
        echo "[$CURRENT/$TOTAL] MC=$MC  SKIPPED (results exist in $RUN_DIR)"
        continue
    fi

    echo "=============================================="
    echo "[$CURRENT/$TOTAL] MC=$MC  ->  $RUN_DIR"
    echo "=============================================="

    "$SWEEP_SCRIPT" "$MC" "$RUN_DIR" "$ISL" "$OSL"

    ELAPSED=$(( $(date +%s) - STARTED_AT ))
    echo ""
    echo "[$CURRENT/$TOTAL] MC=$MC complete. (elapsed: ${ELAPSED}s)"
    echo ""
done

TOTAL_TIME=$(( $(date +%s) - STARTED_AT ))
echo "=============================================="
echo "MC Sweep Complete (total: ${TOTAL_TIME}s)"
echo "=============================================="
echo "Results in: $BASE_OUT_DIR"
ls -d "$BASE_OUT_DIR"/scenario* 2>/dev/null || true
