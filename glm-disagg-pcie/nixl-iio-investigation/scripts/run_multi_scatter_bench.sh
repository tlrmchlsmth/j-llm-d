#!/usr/bin/env bash
# Run 4 concurrent scatter_bench instances to reproduce NIXL's TP=2, rails=2 topology.
#
# Creates the same cross-IIO traffic pattern as NIXL:
#   - 2 decode GPUs (GPU0, GPU1), each using 2 NICs (NIC_A=mlx5_3, NIC_B=mlx5_4)
#   - 2 prefill GPUs (GPU0, GPU1), each serving 2 NICs
#   - 4 concurrent cross-IIO flows on each node
#
# IIO stack mapping (Sapphire Rapids):
#   GPU0 (PCI 11:00) → IIO Stack 2
#   GPU1 (PCI 2F:00) → IIO Stack 6
#   NIC mlx5_3 (PCI 41:00) → IIO Stack 9
#   NIC mlx5_4 (PCI 58:00) → IIO Stack 4
#
# Usage: ./run_multi_scatter_bench.sh <decode_pod> <prefill_pod> <output_dir>
# Example: ./run_multi_scatter_bench.sh \
#   networking-debug-pod-10.0.69.254 \
#   networking-debug-pod-10.0.73.254 \
#   results/nic_profile_scatter_multi

set -euo pipefail

DECODE_POD="${1:?Usage: $0 <decode_pod> <prefill_pod> <output_dir>}"
PREFILL_POD="${2:?Usage: $0 <decode_pod> <prefill_pod> <output_dir>}"
OUT_DIR="${3:?Usage: $0 <decode_pod> <prefill_pod> <output_dir>}"
NAMESPACE="${NAMESPACE:-raj-network-debug}"
PREFILL_IP="${PREFILL_IP:-10.0.73.254}"
RERANDOMIZE="${RERANDOMIZE:-}"

mkdir -p "$OUT_DIR"

NIC_A="mlx5_3"
NIC_B="mlx5_4"
GID_INDEX=3
BLOCKS_PER_INSTANCE=20480
BLOCK_SIZE=16384
POOL_GB=2
TRANSFERS=5
BASE_PORT=19875
SQ_DEPTH=8192
SIGNAL_EVERY=512
MAX_RD_ATOMIC=16

echo "=============================================="
echo "Multi-instance scatter_bench (TP=2, rails=2)"
echo "=============================================="
echo "  Decode:  $DECODE_POD"
echo "  Prefill: $PREFILL_POD"
echo "  NICs:    $NIC_A, $NIC_B"
echo "  GPUs:    0, 1"
echo "  Blocks/instance: $BLOCKS_PER_INSTANCE x $BLOCK_SIZE = $((BLOCKS_PER_INSTANCE * BLOCK_SIZE / 1024 / 1024)) MB"
echo "  Transfers: $TRANSFERS"
echo "  Rerandomize: ${RERANDOMIZE:-no}"
echo ""

kexec() {
    local pod="$1"; shift
    kubectl -n "$NAMESPACE" exec "$pod" -- "$@"
}

# --- Clean up any old processes ---
echo "Cleaning up old processes..."
kexec "$DECODE_POD" bash -c 'pkill -f rdma_scatter_bench 2>/dev/null || true; pkill -f poll_nic_counters 2>/dev/null || true; rm -f /tmp/scatter_start_barrier' || true
kexec "$PREFILL_POD" bash -c 'pkill -f rdma_scatter_bench 2>/dev/null || true; rm -f /tmp/scatter_start_barrier' || true
sleep 2

# --- Instance definitions ---
# Format: GPU NIC PORT
INSTANCES=(
    "0 $NIC_A $((BASE_PORT))"
    "0 $NIC_B $((BASE_PORT + 1))"
    "1 $NIC_A $((BASE_PORT + 2))"
    "1 $NIC_B $((BASE_PORT + 3))"
)

# --- Start servers on prefill ---
echo "Starting ${#INSTANCES[@]} scatter_bench servers on prefill..."
for inst in "${INSTANCES[@]}"; do
    read -r gpu nic port <<< "$inst"
    echo "  Server: GPU$gpu via $nic on port $port"
    kexec "$PREFILL_POD" bash -c "nohup /tmp/rdma_scatter_bench server \
        --dev $nic --gid-index $GID_INDEX --gpu $gpu \
        --pool-gb $POOL_GB --num-blocks $BLOCKS_PER_INSTANCE --block-size $BLOCK_SIZE \
        --mode scattered --transfers $TRANSFERS --port $port \
        > /tmp/scatter_server_gpu${gpu}_${nic}_p${port}.log 2>&1 &"
done

echo "  Waiting 5s for servers to initialize..."
sleep 5

# --- Start NIC counter pollers on decode ---
echo ""
echo "Starting NIC counter pollers on decode pod..."
kexec "$DECODE_POD" bash -c "nohup /tmp/poll_nic_counters $NIC_A /tmp/nic_multi_${NIC_A}.tsv 0 > /tmp/poll_multi_1.log 2>&1 &"
kexec "$DECODE_POD" bash -c "nohup /tmp/poll_nic_counters $NIC_B /tmp/nic_multi_${NIC_B}.tsv 0 > /tmp/poll_multi_2.log 2>&1 &"
echo "  Pollers started. Waiting 2s..."
sleep 2

# --- Start all clients on decode with barrier ---
echo ""
echo "Starting ${#INSTANCES[@]} scatter_bench clients on decode (barrier-gated)..."
for inst in "${INSTANCES[@]}"; do
    read -r gpu nic port <<< "$inst"
    echo "  Client: GPU$gpu via $nic → $PREFILL_IP:$port"
    RERAND_FLAG=""
    if [ -n "$RERANDOMIZE" ]; then
        RERAND_FLAG="--rerandomize"
    fi
    kexec "$DECODE_POD" bash -c "nohup /tmp/rdma_scatter_bench client \
        --server-ip $PREFILL_IP --dev $nic --gid-index $GID_INDEX --gpu $gpu \
        --pool-gb $POOL_GB --num-blocks $BLOCKS_PER_INSTANCE --block-size $BLOCK_SIZE \
        --mode scattered --transfers $TRANSFERS --port $port \
        --sq-depth $SQ_DEPTH --signal-every $SIGNAL_EVERY --max-rd-atomic $MAX_RD_ATOMIC \
        --start-barrier /tmp/scatter_start_barrier $RERAND_FLAG \
        > /tmp/scatter_client_gpu${gpu}_${nic}_p${port}.log 2>&1 &"
done

echo "  All clients launched. Waiting 5s for QP setup and barrier readiness..."
sleep 5

# Verify all clients are waiting at barrier
WAITING=$(kexec "$DECODE_POD" bash -c 'pgrep -c rdma_scatter_bench 2>/dev/null' 2>/dev/null | tr -d '[:space:]' || echo "0")
echo "  $WAITING clients waiting at barrier."

echo "  Releasing barrier (touch /tmp/scatter_start_barrier)..."
kexec "$DECODE_POD" touch /tmp/scatter_start_barrier

echo "  Waiting for all clients to complete..."

# --- Wait for all clients to finish ---
for i in $(seq 1 60); do
    RUNNING=$(kexec "$DECODE_POD" bash -c 'pgrep -c rdma_scatter_bench 2>/dev/null' 2>/dev/null | tr -d '[:space:]' || echo "0")
    if [ "$RUNNING" = "0" ]; then
        echo "  All clients finished."
        break
    fi
    echo "  Still running ($RUNNING processes)... (${i}/60)"
    sleep 2
done

sleep 2

# --- Stop pollers ---
echo ""
echo "Stopping NIC counter pollers..."
kexec "$DECODE_POD" bash -c 'pkill -SIGINT -f poll_nic_counters 2>/dev/null; true'
echo "  Waiting 10s for pollers to flush..."
sleep 10

# --- Collect results ---
echo ""
echo "Collecting results..."

for inst in "${INSTANCES[@]}"; do
    read -r gpu nic port <<< "$inst"
    echo ""
    echo "=== Client GPU$gpu via $nic (port $port) ==="
    kexec "$DECODE_POD" cat /tmp/scatter_client_gpu${gpu}_${nic}_p${port}.log 2>/dev/null || echo "  (no log)"
done

echo ""
echo "=== Poller logs ==="
echo "  Poller $NIC_A:"
kexec "$DECODE_POD" cat /tmp/poll_multi_1.log 2>/dev/null || echo "  (no log)"
echo "  Poller $NIC_B:"
kexec "$DECODE_POD" cat /tmp/poll_multi_2.log 2>/dev/null || echo "  (no log)"

# Copy NIC counter data
kubectl -n "$NAMESPACE" cp "${DECODE_POD}:/tmp/nic_multi_${NIC_A}.tsv" "$OUT_DIR/nic_decode_${NIC_A}.tsv" -c "" 2>/dev/null || \
    kubectl -n "$NAMESPACE" cp "${DECODE_POD}:/tmp/nic_multi_${NIC_A}.tsv" "$OUT_DIR/nic_decode_${NIC_A}.tsv" 2>/dev/null || \
    echo "  WARNING: Failed to copy $NIC_A trace"
kubectl -n "$NAMESPACE" cp "${DECODE_POD}:/tmp/nic_multi_${NIC_B}.tsv" "$OUT_DIR/nic_decode_${NIC_B}.tsv" -c "" 2>/dev/null || \
    kubectl -n "$NAMESPACE" cp "${DECODE_POD}:/tmp/nic_multi_${NIC_B}.tsv" "$OUT_DIR/nic_decode_${NIC_B}.tsv" 2>/dev/null || \
    echo "  WARNING: Failed to copy $NIC_B trace"

echo ""
echo "Collected files:"
ls -lh "$OUT_DIR"/ 2>/dev/null || true

# --- Analyze ---
echo ""
echo "=============================================="
echo "NIC Counter Analysis"
echo "=============================================="
python3 "$(dirname "$0")/analyze_nic_counters.py" "$OUT_DIR" 2>&1 || echo "Analysis failed"

echo ""
echo "Done. Results in: $OUT_DIR"
