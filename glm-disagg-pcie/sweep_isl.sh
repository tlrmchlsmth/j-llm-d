#!/bin/bash

# ISL Sweep: runs the concurrency sweep at multiple ISL values (MC=1).
# Usage: ./sweep_isl.sh <output_dir> [scenario] [isl_values...]
# Example: ./sweep_isl.sh results/isl_sweep_scenario1
#          ./sweep_isl.sh results/isl_sweep_scenario2 2 128 4096 16384
#
# Defaults: SCENARIO=1  RAILS=1  MC=1  OSL=256  ISL_VALUES=128..16384
#
# For each ISL, calls sweep_concurrency_with_kv_transfer_logs.sh and writes
# results to <output_dir>/scenario<S>_rails<R>_ISL<I>_MC<M>/

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SWEEP_SCRIPT="$SCRIPT_DIR/sweep_concurrency_with_kv_transfer_logs.sh"

if [ $# -lt 1 ]; then
    echo "Usage: $0 <output_dir> [scenario] [isl_values...]"
    echo "Example: $0 results/isl_sweep_scenario1"
    echo "         $0 results/isl_sweep_scenario2 2 128 4096 16384"
    exit 1
fi

BASE_OUT_DIR="$1"
SCENARIO="${2:-1}"
RAILS=1
MC=1
OSL=256

if [ $# -ge 3 ]; then
    ISL_VALUES=("${@:3}")
else
    ISL_VALUES=(128 256 512 1024 2048 4096 8192 16384)
fi

echo "=============================================="
echo "ISL Sweep"
echo "=============================================="
echo "  Scenario: $SCENARIO"
echo "  Rails:    $RAILS"
echo "  MC:       $MC"
echo "  OSL:      $OSL"
echo "  ISL vals: ${ISL_VALUES[*]}"
echo "  Base dir: $BASE_OUT_DIR"
echo "=============================================="
echo ""

TOTAL=${#ISL_VALUES[@]}
CURRENT=0

for ISL in "${ISL_VALUES[@]}"; do
    CURRENT=$((CURRENT + 1))
    RUN_DIR="${BASE_OUT_DIR}/scenario${SCENARIO}_rails${RAILS}_ISL${ISL}_MC${MC}"

    echo "=============================================="
    echo "[$CURRENT/$TOTAL] ISL=$ISL  ->  $RUN_DIR"
    echo "=============================================="

    "$SWEEP_SCRIPT" "$MC" "$RUN_DIR" "$ISL" "$OSL"

    echo ""
    echo "[$CURRENT/$TOTAL] ISL=$ISL complete."
    echo ""
done

echo "=============================================="
echo "ISL Sweep Complete"
echo "=============================================="
echo "Results in: $BASE_OUT_DIR"
ls -d "$BASE_OUT_DIR"/scenario* 2>/dev/null || true
