#!/usr/bin/env bash
# Run an end-to-end P-D benchmark while capturing IIO counters on both nodes.
#
# This script:
#   1. Discovers prefill/decode pods and resolves their host node IPs
#   2. Starts `perf stat` on both bare-metal nodes via SSH + tmux,
#      monitoring 16 IIO PMU events across 4 IIO units (GPU + NIC stacks)
#   3. Runs the benchmark via sweep_concurrency_with_kv_transfer_logs.sh
#   4. Waits for perf stat to complete and collects the output
#
# Prerequisites:
#   - SSH access to bare-metal nodes (node aliases in ~/.ssh/config)
#   - sudo perf stat on the nodes
#   - Disaggregated P-D deployment running in NAMESPACE
#   - Poker pod deployed for benchmark orchestration
#
# Usage: ./run_e2e_with_iio.sh <ISL> <output_dir> [MC] [NUM_PROMPTS] [OSL]
# Example: ./run_e2e_with_iio.sh 4096 results/e2e_s2r2_isl4096
#          ./run_e2e_with_iio.sh 4096 results/e2e_s2r2_isl4096_mc4 4 50
#          ./run_e2e_with_iio.sh 8192 results/e2e_s2r2_isl8192 1 30

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INVESTIGATION_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
SWEEP_SCRIPT="${INVESTIGATION_DIR}/../sweep_concurrency_with_kv_transfer_logs.sh"

ISL="${1:?Usage: $0 <ISL> <output_dir> [MC] [NUM_PROMPTS] [OSL]}"
OUT_DIR="${2:?Usage: $0 <ISL> <output_dir> [MC] [NUM_PROMPTS] [OSL]}"
MC="${3:-1}"
NUM_PROMPTS="${4:-50}"
OSL="${5:-256}"
NAMESPACE="${NAMESPACE:-raj-network-debug}"

mkdir -p "$OUT_DIR"

echo "=============================================="
echo "E2E Benchmark with IIO Perf Stat"
echo "  ISL=$ISL  OSL=$OSL  MC=$MC  N=$NUM_PROMPTS"
echo "  Output: $OUT_DIR"
echo "=============================================="

# --- Discover Nodes ---
echo ""
echo "Discovering prefill and decode pods..."
DECODE_POD=$(kubectl get pods -n "$NAMESPACE" -o name | grep "ms-glm-disagg.*decode" | head -1 | sed 's|pod/||')
PREFILL_POD=$(kubectl get pods -n "$NAMESPACE" -o name | grep "ms-glm-disagg.*prefill" | head -1 | sed 's|pod/||')

if [ -z "$DECODE_POD" ] || [ -z "$PREFILL_POD" ]; then
    echo "ERROR: Could not find disagg decode/prefill pods in namespace $NAMESPACE"
    exit 1
fi

DECODE_NODE=$(kubectl get pod -n "$NAMESPACE" "$DECODE_POD" -o jsonpath='{.spec.nodeName}')
PREFILL_NODE=$(kubectl get pod -n "$NAMESPACE" "$PREFILL_POD" -o jsonpath='{.spec.nodeName}')

echo "  Decode pod:    $DECODE_POD on $DECODE_NODE"
echo "  Prefill pod:   $PREFILL_POD on $PREFILL_NODE"

# --- Node IP to SSH alias mapping ---
# Override NODE_ALIAS_MAP env var to customize, format: "IP1:alias1 IP2:alias2 ..."
# Default mapping for the OCI bare-metal cluster used in this investigation.
node_alias() {
    local IP="$1"
    if [ -n "${NODE_ALIAS_MAP:-}" ]; then
        for entry in $NODE_ALIAS_MAP; do
            local MAP_IP="${entry%%:*}"
            local MAP_ALIAS="${entry#*:}"
            if [ "$IP" = "$MAP_IP" ]; then
                echo "$MAP_ALIAS"
                return 0
            fi
        done
        echo "unknown"; return 1
    fi
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
# Sapphire Rapids cross-IIO mapping (Socket 0, scenario 2r2):
#   GPU0 (11:00.0) on Stack 2 (PCIe0) = uncore_iio_5
#   GPU1 (2F:00.0) on Stack 6 (PCIe2) = uncore_iio_11
#   NIC mlx5_3 (VF 41:00.1) on Stack 9 (PCIe4) = uncore_iio_2
#   NIC mlx5_4 (VF 58:00.1) on Stack 4 (PCIe1) = uncore_iio_7
#
# Override IIO_GPU_UNITS / IIO_NIC_UNITS to change for different topologies.
# perf stat -a aggregates across both sockets, so these also capture
# Socket 1 GPUs on the same stack positions (GPU4-7).
IIO_GPU_UNITS="${IIO_GPU_UNITS:-5 11}"
IIO_NIC_UNITS="${IIO_NIC_UNITS:-2 7}"
IIO_OPTS="ch_mask=0xff,fc_mask=0x07"

# IIO PMU events:
#   0xd5/0xff = COMP_BUF_OCCUPANCY (cycle-weighted completion buffer occupancy)
#   0xc2/0x04 = COMP_BUF_INSERTS   (completion buffer insertions)
#   0xd0/0x08 = DATA_REQ_OF_CPU     (outbound cache lines)
#   0x86/0x08 = NUM_REQ_OF_CPU      (arbitration requests)
#   0x8e/0x20 = LOC_P2P             (local peer-to-peer transactions)
build_perf_events() {
    local EVENTS=""
    for unit in $IIO_GPU_UNITS; do
        EVENTS="${EVENTS}uncore_iio_${unit}/event=0xd5,umask=0xff,${IIO_OPTS}/,"
        EVENTS="${EVENTS}uncore_iio_${unit}/event=0xc2,umask=0x04,${IIO_OPTS}/,"
        EVENTS="${EVENTS}uncore_iio_${unit}/event=0xd0,umask=0x08,${IIO_OPTS}/,"
        EVENTS="${EVENTS}uncore_iio_${unit}/event=0x86,umask=0x08,${IIO_OPTS}/,"
    done
    for unit in $IIO_NIC_UNITS; do
        EVENTS="${EVENTS}uncore_iio_${unit}/event=0x86,umask=0x08,${IIO_OPTS}/,"
        EVENTS="${EVENTS}uncore_iio_${unit}/event=0x8e,umask=0x20,${IIO_OPTS}/,"
        EVENTS="${EVENTS}uncore_iio_${unit}/event=0xd5,umask=0xff,${IIO_OPTS}/,"
        EVENTS="${EVENTS}uncore_iio_${unit}/event=0xc2,umask=0x04,${IIO_OPTS}/,"
    done
    echo "${EVENTS%,}"
}

PERF_EVENTS=$(build_perf_events)

# --- Compute perf stat duration ---
# Estimate: calibration (~2min) + main run (~N*6s/prompt) + buffer
EST_BENCH_SEC=$(python3 -c "import math; print(math.ceil(20*6 + ${NUM_PROMPTS}*6 + 60))")
echo ""
echo "Estimated benchmark duration: ~${EST_BENCH_SEC}s"
echo "perf stat will run for ${EST_BENCH_SEC}s on both nodes"
echo "IIO GPU units: $IIO_GPU_UNITS"
echo "IIO NIC units: $IIO_NIC_UNITS"

# --- Start perf stat on both nodes ---
start_perf_stat() {
    local SSH_HOST="$1"
    local PERF_FILE="$2"
    local LABEL="$3"

    echo "Starting perf stat on $LABEL node ($SSH_HOST)..."
    ssh "$SSH_HOST" "tmux kill-session -t perf_e2e 2>/dev/null || true"
    ssh "$SSH_HOST" "tmux new-session -d -s perf_e2e"
    ssh "$SSH_HOST" "tmux send-keys -t perf_e2e 'sudo perf stat -a -e \"${PERF_EVENTS}\" sleep ${EST_BENCH_SEC} 2>&1 | tee ${PERF_FILE}' Enter"
}

echo ""
PREFILL_PERF_FILE="/tmp/perf_e2e_isl${ISL}_mc${MC}_prefill.txt"
DECODE_PERF_FILE="/tmp/perf_e2e_isl${ISL}_mc${MC}_decode.txt"
start_perf_stat "$PREFILL_SSH" "$PREFILL_PERF_FILE" "PREFILL"
start_perf_stat "$DECODE_SSH" "$DECODE_PERF_FILE" "DECODE"

echo "Waiting 3s for perf stat to initialize..."
sleep 3

# --- Run the benchmark ---
echo ""
echo "=========================================="
echo "Running benchmark: MC=$MC, ISL=$ISL, OSL=$OSL, N=$NUM_PROMPTS"
echo "=========================================="

ABSOLUTE_OUT_DIR="$(mkdir -p "$OUT_DIR" && cd "$OUT_DIR" && pwd)"
cd "$INVESTIGATION_DIR/.."
MAX_PROMPTS=$NUM_PROMPTS MIN_PROMPTS=$NUM_PROMPTS TARGET_DURATION=60 \
    bash "$SWEEP_SCRIPT" "$MC" "$ABSOLUTE_OUT_DIR" "$ISL" "$OSL" 2>&1

echo ""
echo "Benchmark complete. Waiting for perf stat to finish..."

# --- Wait for perf stat to complete ---
wait_for_perf_stat() {
    local SSH_HOST="$1"
    local LABEL="$2"
    for i in $(seq 1 60); do
        DONE=$(ssh "$SSH_HOST" "tmux capture-pane -t perf_e2e -p | tail -3 | grep -c 'seconds time elapsed' || true" 2>/dev/null)
        if [[ "$DONE" -ge 1 ]]; then
            return 0
        fi
        echo "  Waiting for $LABEL perf stat... (${i}/60)"
        sleep 10
    done
    echo "  WARNING: $LABEL perf stat may not have finished"
    return 1
}

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
scp "${PREFILL_SSH}:${PREFILL_PERF_FILE}" "$ABSOLUTE_OUT_DIR/perf_prefill_isl${ISL}.txt" 2>/dev/null || echo "WARNING: Failed to copy prefill perf output"
scp "${DECODE_SSH}:${DECODE_PERF_FILE}" "$ABSOLUTE_OUT_DIR/perf_decode_isl${ISL}.txt" 2>/dev/null || echo "WARNING: Failed to copy decode perf output"

echo ""
echo "=========================================="
echo "Results saved to: $ABSOLUTE_OUT_DIR"
echo "=========================================="
ls -lh "$ABSOLUTE_OUT_DIR"/ 2>/dev/null
