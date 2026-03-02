#!/bin/bash

# GLM-Disagg Benchmark with NIC Counter Tracking
# Usage: NET_DEBUG_NS=<debug-ns> ./single_query_with_nic_counters.sh <max_concurrent> [num_prompts] [ISL] [OSL]
# Example: NET_DEBUG_NS=raj-network-debug ./single_query_with_nic_counters.sh 1
#          NET_DEBUG_NS=raj-network-debug ./single_query_with_nic_counters.sh 3 100
#          NET_DEBUG_NS=raj-network-debug ./single_query_with_nic_counters.sh 3 100 4096 256
#
# Automatically discovers ms-glm-disagg-llm-d-modelservice-{decode,prefill} pods.
# Tracks RX counters for priorities 0, 1, and 5, plus ECN and PFC pause counters.
#
# Required environment variables:
#   NET_DEBUG_NS - Namespace where networking-debug-pods are deployed

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/nic_counter_utils.sh"

if [ $# -lt 1 ]; then
    echo "Usage: NET_DEBUG_NS=<debug-ns> $0 <max_concurrent> [num_prompts] [ISL] [OSL]"
    echo "Example: NET_DEBUG_NS=raj-network-debug $0 3 100"
    exit 1
fi

MC="$1"
NUM_PROMPTS="${2:-1}"
ISL="${3:-4096}"
OSL="${4:-256}"
NAMESPACE="raj-network-debug"

echo ""
echo "=============================================="
echo "Discovering model server pods in namespace: $NAMESPACE"
echo "=============================================="

ALL_PODS=$(kubectl get pods -n "$NAMESPACE" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')

pod_names=()
TARGET=""

# Try disagg first, then agg
DISAGG_DECODE=$(echo "$ALL_PODS" | grep "^ms-glm-disagg-llm-d-modelservice-decode" || true)
DISAGG_PREFILL=$(echo "$ALL_PODS" | grep "^ms-glm-disagg-llm-d-modelservice-prefill" || true)
AGG_PODS=$(echo "$ALL_PODS" | grep "^ms-glm-agg-llm-d-modelservice" || true)

if [ -n "$DISAGG_DECODE" ]; then
    TARGET="glm-disagg"
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
    TARGET="glm-agg"
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

# Initialize NIC counter utils (discovers nodes and networking-debug-pods)
init_nic_counter_utils pod_names "$NAMESPACE" || exit 1

# ============================================
# MAIN SCRIPT EXECUTION
# ============================================

# Collect and print BEFORE counters
collect_all_counters pod_names "before"
print_all_counters pod_names "before"

# Run the sweep via the poker pod
BENCHMARK_TIMEOUT_SEC=900
echo ""
echo "=============================================="
echo "Running Sweep via Poker Pod (timeout: ${BENCHMARK_TIMEOUT_SEC}s)"
echo "=============================================="
echo ""
echo "Running: ${NUM_PROMPTS} prompts, MC=${MC}, ISL=${ISL}, OSL=${OSL} via poker pod"
echo ""

GATEWAY_URL="http://infra-${TARGET}-inference-gateway-istio.${NAMESPACE}.svc.cluster.local"

timeout "$BENCHMARK_TIMEOUT_SEC" kubectl exec -n "$NAMESPACE" poker -- /bin/bash -c '
GATEWAY_URL="'"$GATEWAY_URL"'"
MODEL=$(curl -s "$GATEWAY_URL/v1/models" | jq -r ".data[0].id")
echo "Gateway: $GATEWAY_URL"
echo "Model:   $MODEL"

echo ""
echo "Sending '"$NUM_PROMPTS"' prompts: ISL='"$ISL"' OSL='"$OSL"' MC='"$MC"'"
vllm bench serve \
    --base-url "$GATEWAY_URL" \
    --model "$MODEL" \
    --dataset-name random \
    --random-input-len '"$ISL"' \
    --random-output-len '"$OSL"' \
    --num-prompts '"$NUM_PROMPTS"' \
    --max-concurrency '"$MC"' \
    --request-rate inf \
    --ignore-eos \
    --seed $(date +%M%H%M%S)
' 2>&1
BENCH_EXIT=$?

echo ""
if [ "$BENCH_EXIT" -eq 124 ]; then
    echo "=============================================="
    echo "Sweep did not finish within ${BENCHMARK_TIMEOUT_SEC}s; killed. Proceeding with counter collection."
    echo "=============================================="
else
    echo "=============================================="
    echo "Sweep Completed (exit $BENCH_EXIT)"
    echo "=============================================="
fi
echo ""

# Collect and print AFTER counters
collect_all_counters pod_names "after"
print_all_counters pod_names "after"

# Print counter differences
print_all_counter_diff pod_names

# Print summaries
print_all_summaries pod_names
