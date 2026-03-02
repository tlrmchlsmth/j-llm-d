#!/bin/bash

# MC Sweep wrapped with NIC counter collection.
# Usage: NET_DEBUG_NS=<debug-ns> ./sweep_mc_with_nic_counters.sh <output_dir> [scenario] [isl] [mc_values...] [max_prompts]
# Example: NET_DEBUG_NS=raj-network-debug ./sweep_mc_with_nic_counters.sh results/mc_sweep_s3r2_isl8192 3r2 8192 3
#          NET_DEBUG_NS=raj-network-debug ./sweep_mc_with_nic_counters.sh results/s2r2_isl8192_mc3 2r2 8192 3 50
#
# If the last argument is a number and no other arg is a single MC value, it is treated as max_prompts (MIN_PROMPTS/MAX_PROMPTS).
# Runs sweep_mc.sh and bookends it with NIC counter snapshots so the final diff/summary covers the entire sweep.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../glm-disagg/nic_counter_utils.sh"

if [ $# -lt 1 ]; then
    echo "Usage: NET_DEBUG_NS=<debug-ns> $0 <output_dir> [scenario] [isl] [mc_values...] [max_prompts]"
    echo "Example: NET_DEBUG_NS=raj-network-debug $0 results/mc_sweep_s3r2_isl8192 3r2 8192 3"
    echo "         NET_DEBUG_NS=raj-network-debug $0 results/s2r2_isl8192_mc3 2r2 8192 3 50"
    exit 1
fi

# Optional max_prompts: if last arg is numeric and we have 5 args (output_dir, scenario, isl, mc, max_prompts), cap prompts
if [ $# -eq 5 ] && [ "$5" -eq "$5" ] 2>/dev/null; then
    export MIN_PROMPTS="$5"
    export MAX_PROMPTS="$5"
    SWEEP_ARGS=("$1" "$2" "$3" "$4")
else
    SWEEP_ARGS=("$@")
fi

NAMESPACE="raj-network-debug"

echo ""
echo "=============================================="
echo "Discovering model server pods in namespace: $NAMESPACE"
echo "=============================================="

ALL_PODS=$(kubectl get pods -n "$NAMESPACE" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')

pod_names=()

DISAGG_DECODE=$(echo "$ALL_PODS" | grep "^ms-glm-disagg-llm-d-modelservice-decode" || true)
DISAGG_PREFILL=$(echo "$ALL_PODS" | grep "^ms-glm-disagg-llm-d-modelservice-prefill" || true)
AGG_PODS=$(echo "$ALL_PODS" | grep "^ms-glm-agg-llm-d-modelservice" || true)

if [ -n "$DISAGG_DECODE" ]; then
    echo ""
    echo "Detected: glm-disagg"
    echo ""
    echo "Discovered Decode Pods:"
    while IFS= read -r pod_name; do
        [ -z "$pod_name" ] && continue
        pod_names+=("$pod_name")
        echo "  - $pod_name"
    done <<< "$DISAGG_DECODE"
    echo ""
    echo "Discovered Prefill Pods:"
    while IFS= read -r pod_name; do
        [ -z "$pod_name" ] && continue
        pod_names+=("$pod_name")
        echo "  - $pod_name"
    done <<< "$DISAGG_PREFILL"
elif [ -n "$AGG_PODS" ]; then
    echo ""
    echo "Detected: glm-agg"
    echo ""
    echo "Discovered Agg Pods:"
    while IFS= read -r pod_name; do
        [ -z "$pod_name" ] && continue
        pod_names+=("$pod_name")
        echo "  - $pod_name"
    done <<< "$AGG_PODS"
fi

if [ ${#pod_names[@]} -eq 0 ]; then
    echo "ERROR: No model server pods found in namespace $NAMESPACE"
    exit 1
fi

init_nic_counter_utils pod_names "$NAMESPACE" || exit 1

echo ""
echo "=============================================="
echo "Collecting NIC Counters BEFORE Sweep"
echo "=============================================="
collect_all_counters pod_names "before"
print_all_counters pod_names "before"

echo ""
echo "=============================================="
echo "Running sweep_mc.sh with args: ${SWEEP_ARGS[*]}"
[ -n "${MAX_PROMPTS:-}" ] && echo "  MIN_PROMPTS=$MIN_PROMPTS MAX_PROMPTS=$MAX_PROMPTS"
echo "=============================================="
echo ""

"$SCRIPT_DIR/sweep_mc.sh" "${SWEEP_ARGS[@]}"
SWEEP_EXIT=$?

echo ""
echo "=============================================="
echo "sweep_mc.sh finished (exit $SWEEP_EXIT)"
echo "=============================================="

echo ""
echo "=============================================="
echo "Collecting NIC Counters AFTER Sweep"
echo "=============================================="
collect_all_counters pod_names "after"
print_all_counters pod_names "after"

print_all_counter_diff pod_names
print_all_summaries pod_names
