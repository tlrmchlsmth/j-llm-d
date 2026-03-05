#!/usr/bin/env bash
# Profile NIC throughput at maximum fidelity during NIXL e2e or scatter_bench transfers.
#
# Deploys poll_nic_counters (no-sleep mode) on the decode bare-metal node,
# runs a short workload, collects timestamped NIC counter traces, and analyzes.
#
# Usage:
#   ./profile_nic_throughput.sh nixl   <output_dir> [NUM_PROMPTS] [ISL] [OSL]
#   ./profile_nic_throughput.sh scatter <output_dir>
#
# Examples:
#   ./profile_nic_throughput.sh nixl   results/nic_profile_nixl 5 4096 256
#   ./profile_nic_throughput.sh scatter results/nic_profile_scatter

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INVESTIGATION_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
POLLER_SRC="${SCRIPT_DIR}/poll_nic_counters.cpp"
ANALYZER="${SCRIPT_DIR}/analyze_nic_counters.py"
SWEEP_SCRIPT="${INVESTIGATION_DIR}/../sweep_concurrency_with_kv_transfer_logs.sh"

MODE="${1:?Usage: $0 <nixl|scatter> <output_dir> [args...]}"
OUT_DIR="${2:?Usage: $0 <nixl|scatter> <output_dir>}"
NAMESPACE="${NAMESPACE:-raj-network-debug}"

mkdir -p "$OUT_DIR"

# --- Discover pods and nodes ---
echo "=============================================="
echo "NIC Throughput Profiling - mode=$MODE"
echo "=============================================="

DECODE_POD=$(kubectl get pods -n "$NAMESPACE" -o name | grep "ms-glm-disagg.*decode" | head -1 | sed 's|pod/||')
PREFILL_POD=$(kubectl get pods -n "$NAMESPACE" -o name | grep "ms-glm-disagg.*prefill" | head -1 | sed 's|pod/||')

DECODE_NODE=$(kubectl get pod -n "$NAMESPACE" "$DECODE_POD" -o jsonpath='{.spec.nodeName}')
PREFILL_NODE=$(kubectl get pod -n "$NAMESPACE" "$PREFILL_POD" -o jsonpath='{.spec.nodeName}')

echo "  Decode:  $DECODE_POD on $DECODE_NODE"
echo "  Prefill: $PREFILL_POD on $PREFILL_NODE"

node_alias() {
    local IP="$1"
    case "$IP" in
        10.0.65.77)  echo "node0" ;;
        10.0.66.42)  echo "node1" ;;
        10.0.67.106) echo "node2" ;;
        10.0.69.254) echo "node3" ;;
        10.0.73.3)   echo "node4" ;;
        10.0.73.241) echo "node5" ;;
        10.0.73.254) echo "node6" ;;
        10.0.74.185) echo "node7" ;;
        10.0.78.230) echo "node8" ;;
        *) echo "unknown"; return 1 ;;
    esac
}

DECODE_SSH=$(node_alias "$DECODE_NODE")
PREFILL_SSH=$(node_alias "$PREFILL_NODE")
echo "  Decode SSH:  $DECODE_SSH"
echo "  Prefill SSH: $PREFILL_SSH"

# --- Discover host PF names for pod VFs ---
# Pod VFs (mlx5_12, mlx5_13) are on specific PCI buses.
# Find the host PF on the same PCI bus.
echo ""
echo "Discovering host PF names for pod VF devices..."

VF_PCI_1=$(kubectl exec -n "$NAMESPACE" "$DECODE_POD" -c vllm -- \
    bash -c 'readlink /sys/class/infiniband/mlx5_12/device | rev | cut -d/ -f1 | rev' 2>/dev/null)
VF_PCI_2=$(kubectl exec -n "$NAMESPACE" "$DECODE_POD" -c vllm -- \
    bash -c 'readlink /sys/class/infiniband/mlx5_13/device | rev | cut -d/ -f1 | rev' 2>/dev/null)

VF_BUS_1=$(echo "$VF_PCI_1" | cut -d: -f2)
VF_BUS_2=$(echo "$VF_PCI_2" | cut -d: -f2)

NIC_DEV_1=$(ssh "$DECODE_SSH" "for d in /sys/class/infiniband/mlx5_*; do dev=\$(basename \$d); pci=\$(readlink \$d/device | rev | cut -d/ -f1 | rev); bus=\$(echo \$pci | cut -d: -f2); func=\$(echo \$pci | grep -o '\\.[0-9]*$'); if [ \"\$bus\" = \"${VF_BUS_1}\" ] && [ \"\$func\" = \".0\" ]; then echo \$dev; break; fi; done")
NIC_DEV_2=$(ssh "$DECODE_SSH" "for d in /sys/class/infiniband/mlx5_*; do dev=\$(basename \$d); pci=\$(readlink \$d/device | rev | cut -d/ -f1 | rev); bus=\$(echo \$pci | cut -d: -f2); func=\$(echo \$pci | grep -o '\\.[0-9]*$'); if [ \"\$bus\" = \"${VF_BUS_2}\" ] && [ \"\$func\" = \".0\" ]; then echo \$dev; break; fi; done")

echo "  Pod mlx5_12 (PCI $VF_PCI_1) -> Host $NIC_DEV_1"
echo "  Pod mlx5_13 (PCI $VF_PCI_2) -> Host $NIC_DEV_2"

if [ -z "$NIC_DEV_1" ] || [ -z "$NIC_DEV_2" ]; then
    echo "ERROR: Could not discover host PF names. Aborting."
    exit 1
fi

# --- Deploy poller into decode pod (VF counters only accessible from inside) ---
echo ""
echo "Deploying NIC counter poller into decode pod..."
echo "  Compiling static binary on $DECODE_SSH..."
scp "$POLLER_SRC" "${DECODE_SSH}:/tmp/poll_nic_counters.cpp"
ssh "$DECODE_SSH" "g++ -O2 -static -o /tmp/poll_nic_counters_static /tmp/poll_nic_counters.cpp"
echo "  Copying static binary into decode pod..."
scp "${DECODE_SSH}:/tmp/poll_nic_counters_static" /tmp/poll_nic_counters_static
kubectl -n "$NAMESPACE" cp /tmp/poll_nic_counters_static "${DECODE_POD}:/tmp/poll_nic_counters" -c vllm
kubectl -n "$NAMESPACE" exec "$DECODE_POD" -c vllm -- chmod +x /tmp/poll_nic_counters
echo "  Deployed successfully."

# VF device names inside the pod
POD_NIC_1="mlx5_12"
POD_NIC_2="mlx5_13"

# --- Start pollers inside the pod ---
start_pollers() {
    echo "Starting NIC counter pollers inside decode pod (no-sleep max fidelity)..."

    # Kill any existing pollers
    kubectl -n "$NAMESPACE" exec "$DECODE_POD" -c vllm -- \
        bash -c 'pkill -f poll_nic_counters 2>/dev/null || true' 2>/dev/null || true

    # Start pollers in background inside the pod
    kubectl -n "$NAMESPACE" exec "$DECODE_POD" -c vllm -- \
        bash -c "nohup /tmp/poll_nic_counters ${POD_NIC_1} /tmp/nic_${POD_NIC_1}.tsv 0 > /tmp/poll1.log 2>&1 &"

    kubectl -n "$NAMESPACE" exec "$DECODE_POD" -c vllm -- \
        bash -c "nohup /tmp/poll_nic_counters ${POD_NIC_2} /tmp/nic_${POD_NIC_2}.tsv 0 > /tmp/poll2.log 2>&1 &"

    echo "  Pollers running. Waiting 2s for initialization..."
    sleep 2

    # Verify pollers are running
    kubectl -n "$NAMESPACE" exec "$DECODE_POD" -c vllm -- \
        bash -c 'ps aux | grep poll_nic | grep -v grep | wc -l' 2>/dev/null || true
}

stop_pollers() {
    echo "Stopping NIC counter pollers..."
    kubectl -n "$NAMESPACE" exec "$DECODE_POD" -c vllm -- \
        bash -c 'pkill -SIGINT -f poll_nic_counters 2>/dev/null || true'
    echo "  Waiting 10s for pollers to flush output..."
    sleep 10

    # Check poll logs for sample counts
    echo "  Poller 1 log:"
    kubectl -n "$NAMESPACE" exec "$DECODE_POD" -c vllm -- cat /tmp/poll1.log 2>/dev/null || true
    echo "  Poller 2 log:"
    kubectl -n "$NAMESPACE" exec "$DECODE_POD" -c vllm -- cat /tmp/poll2.log 2>/dev/null || true
}

collect_results() {
    echo "Collecting NIC counter traces from decode pod..."
    kubectl -n "$NAMESPACE" cp "${DECODE_POD}:/tmp/nic_${POD_NIC_1}.tsv" "$OUT_DIR/nic_decode_${POD_NIC_1}.tsv" -c vllm 2>/dev/null || echo "  WARNING: Failed to copy ${POD_NIC_1} trace"
    kubectl -n "$NAMESPACE" cp "${DECODE_POD}:/tmp/nic_${POD_NIC_2}.tsv" "$OUT_DIR/nic_decode_${POD_NIC_2}.tsv" -c vllm 2>/dev/null || echo "  WARNING: Failed to copy ${POD_NIC_2} trace"

    echo ""
    echo "Collected files:"
    ls -lh "$OUT_DIR"/nic_decode_*.tsv 2>/dev/null || true
}

# ========================================================
# MODE: NIXL e2e benchmark
# ========================================================
if [ "$MODE" = "nixl" ]; then
    NUM_PROMPTS="${3:-5}"
    ISL="${4:-4096}"
    OSL="${5:-256}"
    MC=1

    echo ""
    echo "NIXL benchmark: MC=$MC, ISL=$ISL, OSL=$OSL, N=$NUM_PROMPTS"
    echo ""

    start_pollers

    echo "=========================================="
    echo "Running NIXL e2e benchmark..."
    echo "=========================================="

    ABSOLUTE_OUT_DIR="$(cd "$OUT_DIR" && pwd)"
    cd "$INVESTIGATION_DIR/.."
    MAX_PROMPTS=$NUM_PROMPTS MIN_PROMPTS=$NUM_PROMPTS TARGET_DURATION=60 \
        bash "$SWEEP_SCRIPT" "$MC" "$ABSOLUTE_OUT_DIR" "$ISL" "$OSL" 2>&1 || true

    cd "$SCRIPT_DIR"

    stop_pollers
    collect_results

# ========================================================
# MODE: scatter_bench
# ========================================================
elif [ "$MODE" = "scatter" ]; then
    echo ""
    echo "scatter_bench profiling"
    echo "TODO: Trigger scatter_bench from networking-debug pod"
    echo "For now, start pollers and wait for manual scatter_bench run."
    echo ""

    start_pollers

    echo "=========================================="
    echo "Pollers running. Now run scatter_bench manually from the networking-debug pod."
    echo "Press Enter when scatter_bench is done..."
    echo "=========================================="
    read -r

    stop_pollers
    collect_results

else
    echo "ERROR: Unknown mode '$MODE'. Use 'nixl' or 'scatter'."
    exit 1
fi

# --- Analyze ---
echo ""
echo "=========================================="
echo "Analyzing NIC counter traces..."
echo "=========================================="
python3 "$ANALYZER" "$OUT_DIR" 2>&1 || echo "WARNING: Analysis failed"

echo ""
echo "=========================================="
echo "Done. Results in: $OUT_DIR"
echo "=========================================="
