#!/bin/bash

# Run MC sweeps across all PCIe topology scenarios.
# Switches NIC scenario, waits for pods to be ready, then runs the MC sweep.
#
# Usage: ./run_all_mc_sweeps.sh [scenarios...]
# Example: ./run_all_mc_sweeps.sh              # all 5 scenarios
#          ./run_all_mc_sweeps.sh 1 3           # just scenarios 1 and 3
#          ./run_all_mc_sweeps.sh 2r2 3r2       # just the 2-rail scenarios
#
# Results land in: results/mc_sweep_scenario<S>/

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SWITCH_SCRIPT="$SCRIPT_DIR/switch_scenario.sh"
SWEEP_MC_SCRIPT="$SCRIPT_DIR/sweep_mc.sh"
NAMESPACE="raj-network-debug"

if [ $# -ge 1 ]; then
    SCENARIOS=("$@")
else
    SCENARIOS=(1 2 3 2r2 3r2)
fi

MC_VALUES=(1 2 4 8 16)
RESULTS_BASE="$SCRIPT_DIR/results"

echo "=============================================="
echo "Multi-Scenario MC Sweep"
echo "=============================================="
echo "  Scenarios:  ${SCENARIOS[*]}"
echo "  MC values:  ${MC_VALUES[*]}"
echo "  ISL:        4096"
echo "  OSL:        256"
echo "  Results:    $RESULTS_BASE/mc_sweep_scenario<S>/"
echo "=============================================="
echo ""

TOTAL=${#SCENARIOS[@]}
CURRENT=0
OVERALL_START=$(date +%s)

for SCENARIO in "${SCENARIOS[@]}"; do
    CURRENT=$((CURRENT + 1))
    echo ""
    echo "######################################################"
    echo "# [$CURRENT/$TOTAL] Scenario $SCENARIO"
    echo "######################################################"
    echo ""

    # --- Switch NIC scenario ---
    echo "Switching to scenario $SCENARIO ..."
    "$SWITCH_SCRIPT" "$SCENARIO"

    # --- Wait for vLLM to be ready (health check via poker -> gateway) ---
    echo ""
    echo "Waiting for vLLM to become ready..."
    GATEWAY="infra-glm-disagg-inference-gateway-istio.${NAMESPACE}.svc.cluster.local"
    MAX_WAIT=600
    WAITED=0
    READY=false
    while [ "$WAITED" -lt "$MAX_WAIT" ]; do
        HTTP_CODE=$(kubectl exec -n "$NAMESPACE" poker -- \
            curl -s -o /dev/null -w '%{http_code}' \
            "http://${GATEWAY}/v1/models" 2>/dev/null) || HTTP_CODE="000"
        if [ "$HTTP_CODE" = "200" ]; then
            READY=true
            break
        fi
        echo "  Not ready yet (HTTP $HTTP_CODE). Waiting... (${WAITED}s / ${MAX_WAIT}s)"
        sleep 15
        WAITED=$((WAITED + 15))
    done

    if [ "$READY" = false ]; then
        echo "ERROR: vLLM did not become ready within ${MAX_WAIT}s for scenario $SCENARIO. Skipping."
        continue
    fi
    echo "  vLLM ready after ${WAITED}s."

    # --- Run MC sweep ---
    OUT_DIR="${RESULTS_BASE}/mc_sweep_scenario${SCENARIO}"
    echo ""
    echo "Starting MC sweep for scenario $SCENARIO -> $OUT_DIR"
    "$SWEEP_MC_SCRIPT" "$OUT_DIR" "$SCENARIO" "${MC_VALUES[@]}"

    ELAPSED=$(( $(date +%s) - OVERALL_START ))
    echo ""
    echo "[$CURRENT/$TOTAL] Scenario $SCENARIO complete. (total elapsed: ${ELAPSED}s)"
done

TOTAL_TIME=$(( $(date +%s) - OVERALL_START ))
echo ""
echo "######################################################"
echo "# All MC Sweeps Complete (total: ${TOTAL_TIME}s)"
echo "######################################################"
echo "Results:"
for SCENARIO in "${SCENARIOS[@]}"; do
    DIR="${RESULTS_BASE}/mc_sweep_scenario${SCENARIO}"
    if [ -d "$DIR" ]; then
        echo "  $DIR/"
        ls -d "$DIR"/scenario* 2>/dev/null | sed 's/^/    /'
    fi
done
