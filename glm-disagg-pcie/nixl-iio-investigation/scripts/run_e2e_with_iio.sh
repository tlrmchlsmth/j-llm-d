#!/usr/bin/env bash
# Run an end-to-end P-D benchmark while capturing IIO counters on both nodes.
#
# Usage: ./run_e2e_with_iio.sh <ISL> <output_dir> [NUM_PROMPTS]
# Example: ./run_e2e_with_iio.sh 4096 results/e2e_s2r2_isl4096
#          ./run_e2e_with_iio.sh 8192 results/e2e_s2r2_isl8192 30

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INVESTIGATION_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
SWEEP_SCRIPT="${INVESTIGATION_DIR}/../sweep_concurrency_with_kv_transfer_logs.sh"

ISL="${1:?Usage: $0 <ISL> <output_dir> [NUM_PROMPTS]}"
OUT_DIR="${2:?Usage: $0 <ISL> <output_dir> [NUM_PROMPTS]}"
NUM_PROMPTS="${3:-50}"
OSL=256
MC=1
NAMESPACE="raj-network-debug"

mkdir -p "$OUT_DIR"

# --- Discover Nodes ---
echo "Discovering prefill and decode node IPs..."
DECODE_POD=$(kubectl get pods -n "$NAMESPACE" -o name | grep "ms-glm-disagg.*decode" | head -1 | sed 's|pod/||')
PREFILL_POD=$(kubectl get pods -n "$NAMESPACE" -o name | grep "ms-glm-disagg.*prefill" | head -1 | sed 's|pod/||')

DECODE_NODE=$(kubectl get pod -n "$NAMESPACE" "$DECODE_POD" -o jsonpath='{.spec.nodeName}')
PREFILL_NODE=$(kubectl get pod -n "$NAMESPACE" "$PREFILL_POD" -o jsonpath='{.spec.nodeName}')

echo "  Decode pod:    $DECODE_POD on node $DECODE_NODE"
echo "  Prefill pod:   $PREFILL_POD on node $PREFILL_NODE"

# Map node IPs to SSH aliases (from ~/.ssh/config)
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
echo "  Decode SSH:    $DECODE_SSH ($DECODE_NODE)"
echo "  Prefill SSH:   $PREFILL_SSH ($PREFILL_NODE)"

# --- IIO Event Configuration ---
# Scenario 2r2 cross-IIO mapping (Socket 0):
#   NIC mlx5_3 (VF 41:00.1) on Stack 9 (PCIe4) = uncore_iio_2
#   NIC mlx5_4 (VF 58:00.1) on Stack 4 (PCIe1) = uncore_iio_7
#   GPU0 (11:00.0) on Stack 2 (PCIe0) = uncore_iio_5
#   GPU1 (2F:00.0) on Stack 6 (PCIe2) = uncore_iio_11
#
# perf stat -a aggregates across both sockets, so these also capture
# Socket 1 GPUs on the same stack positions (GPU4-7).
IIO_OPTS="ch_mask=0xff,fc_mask=0x07"

# 16 events across 4 IIO units (4 per unit, no multiplexing)
PERF_EVENTS=$(cat <<EOF
uncore_iio_5/event=0xd5,umask=0xff,${IIO_OPTS}/,\
uncore_iio_5/event=0xc2,umask=0x04,${IIO_OPTS}/,\
uncore_iio_5/event=0xd0,umask=0x08,${IIO_OPTS}/,\
uncore_iio_5/event=0x86,umask=0x08,${IIO_OPTS}/,\
uncore_iio_11/event=0xd5,umask=0xff,${IIO_OPTS}/,\
uncore_iio_11/event=0xc2,umask=0x04,${IIO_OPTS}/,\
uncore_iio_11/event=0xd0,umask=0x08,${IIO_OPTS}/,\
uncore_iio_11/event=0x86,umask=0x08,${IIO_OPTS}/,\
uncore_iio_2/event=0x86,umask=0x08,${IIO_OPTS}/,\
uncore_iio_2/event=0x8e,umask=0x20,${IIO_OPTS}/,\
uncore_iio_2/event=0xd5,umask=0xff,${IIO_OPTS}/,\
uncore_iio_2/event=0xc2,umask=0x04,${IIO_OPTS}/,\
uncore_iio_7/event=0x86,umask=0x08,${IIO_OPTS}/,\
uncore_iio_7/event=0x8e,umask=0x20,${IIO_OPTS}/,\
uncore_iio_7/event=0xd5,umask=0xff,${IIO_OPTS}/,\
uncore_iio_7/event=0xc2,umask=0x04,${IIO_OPTS}/
EOF
)

# --- Compute perf stat duration ---
# Estimate: calibration (~2min) + main run (~N*5.7s/prompt) + buffer
EST_BENCH_SEC=$(python3 -c "import math; print(math.ceil(20*6 + ${NUM_PROMPTS}*6 + 60))")
echo ""
echo "Estimated benchmark duration: ~${EST_BENCH_SEC}s"
echo "perf stat will run for ${EST_BENCH_SEC}s on both nodes"

# --- Start perf stat on both nodes ---
echo ""
echo "Starting perf stat on PREFILL node ($PREFILL_SSH)..."
PREFILL_PERF_FILE="/tmp/perf_e2e_isl${ISL}_prefill.txt"
ssh "$PREFILL_SSH" "tmux new-session -d -s perf_e2e 2>/dev/null || true"
ssh "$PREFILL_SSH" "tmux send-keys -t perf_e2e 'sudo perf stat -a -e \"${PERF_EVENTS}\" sleep ${EST_BENCH_SEC} 2>&1 | tee ${PREFILL_PERF_FILE}' Enter"

echo "Starting perf stat on DECODE node ($DECODE_SSH)..."
DECODE_PERF_FILE="/tmp/perf_e2e_isl${ISL}_decode.txt"
ssh "$DECODE_SSH" "tmux new-session -d -s perf_e2e 2>/dev/null || true"
ssh "$DECODE_SSH" "tmux send-keys -t perf_e2e 'sudo perf stat -a -e \"${PERF_EVENTS}\" sleep ${EST_BENCH_SEC} 2>&1 | tee ${DECODE_PERF_FILE}' Enter"

echo "Waiting 3s for perf stat to initialize..."
sleep 3

# --- Run the benchmark ---
echo ""
echo "=========================================="
echo "Running benchmark: MC=$MC, ISL=$ISL, OSL=$OSL, N=$NUM_PROMPTS"
echo "=========================================="

ABSOLUTE_OUT_DIR="$(cd "$OUT_DIR" && pwd)"
cd "$INVESTIGATION_DIR/.."
MAX_PROMPTS=$NUM_PROMPTS MIN_PROMPTS=$NUM_PROMPTS TARGET_DURATION=60 \
    bash "$SWEEP_SCRIPT" "$MC" "$ABSOLUTE_OUT_DIR" "$ISL" "$OSL" 2>&1

echo ""
echo "Benchmark complete. Waiting for perf stat to finish..."

# Wait for perf stat to complete (it runs for EST_BENCH_SEC)
# Check if it's still running, wait if needed
for i in $(seq 1 60); do
    PREFILL_DONE=$(ssh "$PREFILL_SSH" "tmux capture-pane -t perf_e2e -p | tail -3 | grep -c 'seconds time elapsed' || true" 2>/dev/null)
    DECODE_DONE=$(ssh "$DECODE_SSH" "tmux capture-pane -t perf_e2e -p | tail -3 | grep -c 'seconds time elapsed' || true" 2>/dev/null)
    if [[ "$PREFILL_DONE" -ge 1 && "$DECODE_DONE" -ge 1 ]]; then
        echo "Both perf stat runs complete."
        break
    fi
    echo "  Waiting for perf stat... (${i}/60)"
    sleep 10
done

# --- Collect perf stat output ---
echo ""
echo "Collecting perf stat output..."
scp "${PREFILL_SSH}:${PREFILL_PERF_FILE}" "$OUT_DIR/perf_prefill_isl${ISL}.txt" 2>/dev/null || echo "WARNING: Failed to copy prefill perf output"
scp "${DECODE_SSH}:${DECODE_PERF_FILE}" "$OUT_DIR/perf_decode_isl${ISL}.txt" 2>/dev/null || echo "WARNING: Failed to copy decode perf output"

echo ""
echo "=========================================="
echo "Results saved to: $OUT_DIR"
echo "=========================================="
ls -lh "$OUT_DIR"/ 2>/dev/null
