#!/bin/bash

# Prefill-Decode (PD) Test with NIC Counter Tracking
# Usage: NET_DEBUG_NS=<debug-ns> ./test_nic_counters-pd.sh <namespace>
# Example: NET_DEBUG_NS=kube-system ./test_nic_counters-pd.sh llm-d
#
# This script automatically discovers nodes running modelservice decode and
# prefill pods in the given namespace. It matches pod names like:
#   ms-glm-agg-llm-d-modelservice-decode-<hash>-<id>
#   ms-glm-disagg-llm-d-modelservice-decode-<hash>-<id>
#   ms-glm-disagg-llm-d-modelservice-prefill-<hash>-<id>
#
# NIC counters are per-node, so when multiple pods share a node we only collect
# counters once per unique node. The script discovers all pods, resolves their
# nodes, then builds a deduplicated (one-pod-per-node) list for counter ops.
#
# Tracks RX counters for priorities 0, 1, and 5, plus ECN and PFC pause counters.
#
# Required environment variables:
#   NET_DEBUG_NS - Namespace where networking-debug-pods are deployed

# Source the shared NIC counter utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/nic_counter_utils.sh"

if [ $# -lt 1 ]; then
    echo "Usage: NET_DEBUG_NS=<debug-ns> $0 <namespace>"
    echo "Example: NET_DEBUG_NS=kube-system $0 llm-d"
    exit 1
fi

NAMESPACE=$1

echo ""
echo "=============================================="
echo "Discovering PD (Prefill-Decode) Pods in namespace: $NAMESPACE"
echo "=============================================="

# Regex to match modelservice decode/prefill pods
# e.g. ms-glm-agg-llm-d-modelservice-decode-67699787d5-t4hvg
#      ms-glm-disagg-llm-d-modelservice-prefill-59c6f4c8d-8s6r7
DECODE_REGEX="^ms-glm-.*-llm-d-modelservice-decode-"
PREFILL_REGEX="^ms-glm-.*-llm-d-modelservice-prefill-"

# Find all decode and prefill pods
all_pod_names=()

echo ""
echo "Discovered Decode Pods:"
while IFS= read -r pod_name; do
    [ -z "$pod_name" ] && continue
    all_pod_names+=("$pod_name")
    echo "  - $pod_name"
done < <(kubectl get pods -n "$NAMESPACE" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | grep -E "$DECODE_REGEX")

echo ""
echo "Discovered Prefill Pods:"
while IFS= read -r pod_name; do
    [ -z "$pod_name" ] && continue
    all_pod_names+=("$pod_name")
    echo "  - $pod_name"
done < <(kubectl get pods -n "$NAMESPACE" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | grep -E "$PREFILL_REGEX")

if [ ${#all_pod_names[@]} -eq 0 ]; then
    echo "ERROR: No modelservice decode or prefill pods found in namespace $NAMESPACE"
    exit 1
fi

# ============================================
# Resolve pod -> node mapping and deduplicate
# NIC counters are per-node, so we only need one representative pod per node.
# ============================================
echo ""
echo "=============================================="
echo "Resolving Pod-to-Node Mapping"
echo "=============================================="

declare -A node_to_pod    # associative array: node -> first pod seen on that node
declare -a all_pod_nodes  # parallel array to all_pod_names with node for each pod

for pod in "${all_pod_names[@]}"; do
    node=$(kubectl get pod -n "$NAMESPACE" "$pod" -o jsonpath='{.spec.nodeName}' 2>/dev/null)
    if [ -z "$node" ]; then
        echo "  [ERROR] Could not find node for pod: $pod"
        exit 1
    fi
    all_pod_nodes+=("$node")
    echo "  $pod -> $node"

    # Keep the first pod we see for each node
    if [ -z "${node_to_pod[$node]+_}" ]; then
        node_to_pod[$node]="$pod"
    fi
done

# Build the deduplicated pod list (one representative pod per unique node)
unique_node_pods=()

echo ""
echo "=============================================="
echo "Unique Nodes for Counter Collection (${#node_to_pod[@]} nodes from ${#all_pod_names[@]} pods)"
echo "=============================================="
for node in "${!node_to_pod[@]}"; do
    rep_pod="${node_to_pod[$node]}"
    unique_node_pods+=("$rep_pod")
    # List all pods sharing this node
    colocated=""
    for idx in "${!all_pod_names[@]}"; do
        if [ "${all_pod_nodes[$idx]}" == "$node" ]; then
            colocated+="${all_pod_names[$idx]}, "
        fi
    done
    colocated="${colocated%, }"  # trim trailing comma
    echo "  Node: $node"
    echo "    Representative pod: $rep_pod"
    echo "    All pods on node:   $colocated"
done

echo ""
echo "Counter collection will use ${#unique_node_pods[@]} representative pod(s), one per unique node."

# Initialize NIC counter utils with deduplicated pod list
init_nic_counter_utils unique_node_pods "$NAMESPACE" || exit 1

# ============================================
# MAIN SCRIPT EXECUTION
# ============================================

# Collect and print BEFORE counters
collect_all_counters unique_node_pods "before"
# print_all_counters unique_node_pods "before"

# --- Placeholder: sleep instead of running the benchmark ---
echo ""
echo "=============================================="
echo "Sleeping for 10 seconds (placeholder for benchmark)"
echo "=============================================="
echo ""
sleep 10

# --- Poker benchmark (commented out) ---
# BENCHMARK_TIMEOUT_SEC=900  # 15 minutes
# echo ""
# echo "=============================================="
# echo "Running Benchmark Test via Poker Pod (timeout: ${BENCHMARK_TIMEOUT_SEC}s)"
# echo "=============================================="
# echo ""
# echo "Running: just benchmark 4096 4096 256 128"
# echo ""
#
# timeout "$BENCHMARK_TIMEOUT_SEC" kubectl exec -n "$NAMESPACE" poker -- /bin/zsh -c "cd /app && just benchmark 4096 4096 256 128" 2>&1
# BENCH_EXIT=$?
#
# echo ""
# if [ "$BENCH_EXIT" -eq 124 ]; then
#     echo "=============================================="
#     echo "Benchmark did not finish within ${BENCHMARK_TIMEOUT_SEC}s; killed. Proceeding with counter collection."
#     echo "=============================================="
# else
#     echo "=============================================="
#     echo "Benchmark Test Completed (exit $BENCH_EXIT)"
#     echo "=============================================="
# fi
# echo ""

# Collect and print AFTER counters
collect_all_counters unique_node_pods "after"
# print_all_counters unique_node_pods "after"

# Print counter differences
print_all_counter_diff unique_node_pods

# Print summaries
print_all_summaries unique_node_pods
# print_final_notes
