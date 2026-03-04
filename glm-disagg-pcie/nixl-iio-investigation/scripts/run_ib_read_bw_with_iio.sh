#!/usr/bin/env bash
# Run ib_read_bw tests while capturing IIO perf stat on the source node.
#
# This script:
#   1. Resolves the source pod's host node IP for SSH access
#   2. Starts perf stat on the source node monitoring IIO PMU events
#   3. Runs the ib_read_bw test via multi_nic_ib_write_bw.py
#   4. Collects perf stat output alongside the ib_read_bw results
#
# Prerequisites:
#   - SSH access to bare-metal nodes (node aliases in ~/.ssh/config)
#   - sudo perf stat on the nodes
#   - multi_nic_ib_write_bw.py and its test pods deployed
#   - Python packages: rich (for multi_nic_ib_write_bw.py)
#
# Usage: ./run_ib_read_bw_with_iio.sh <config_json> <output_dir> [DURATION_BUFFER_SEC]
# Example:
#   ./run_ib_read_bw_with_iio.sh configs/ib_read_bw/vf-cross-iio-gpu-2MB.json results/ib_read_bw_iio
#   ./run_ib_read_bw_with_iio.sh configs/ib_read_bw/vf-cross-iio-gpu-16KB.json results/ib_read_bw_iio

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MULTI_NIC_SCRIPT="${MULTI_NIC_SCRIPT:-/home/rajjoshi/workspace/networking-debug-container/inter_node_tests/multi_nic_ib_write_bw/multi_nic_ib_write_bw.py}"

CONFIG_JSON="${1:?Usage: $0 <config_json> <output_dir> [DURATION_BUFFER_SEC]}"
OUT_DIR="${2:?Usage: $0 <config_json> <output_dir> [DURATION_BUFFER_SEC]}"
DURATION_BUFFER="${3:-30}"
NAMESPACE="${NAMESPACE:-raj-network-debug}"

if [ ! -f "$CONFIG_JSON" ]; then
    echo "ERROR: Config file not found: $CONFIG_JSON"
    exit 1
fi

CONFIG_NAME=$(basename "$CONFIG_JSON" .json)
mkdir -p "$OUT_DIR"

echo "=============================================="
echo "ib_read_bw with IIO Perf Stat"
echo "  Config: $CONFIG_JSON"
echo "  Output: $OUT_DIR"
echo "=============================================="

# --- Extract test parameters from config ---
DURATION=$(python3 -c "import json; print(json.load(open('$CONFIG_JSON')).get('duration', 30))")
SRC_POD=$(python3 -c "import json; print(json.load(open('$CONFIG_JSON'))['test_pairs'][0]['src_pod'])")

echo "  Test duration: ${DURATION}s"
echo "  Source pod:    $SRC_POD"

# --- Resolve source pod's host node ---
SRC_NODE=$(kubectl get pod -n "$NAMESPACE" "$SRC_POD" -o jsonpath='{.spec.nodeName}')
echo "  Source node:   $SRC_NODE"

# Node IP to SSH alias mapping (same as run_e2e_with_iio.sh)
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

SRC_SSH=$(node_alias "$SRC_NODE")
echo "  Source SSH:    $SRC_SSH ($SRC_NODE)"

# --- IIO Event Configuration ---
# Override IIO_UNITS to monitor specific IIO stacks for your topology.
# Default: all 4 PCIe IIO stacks on Socket 0 (stacks 5, 11, 2, 7).
#
# To find the correct units for your topology:
#   1. Run pcm-iio while ib_read_bw is active
#   2. Look for stacks with non-zero bandwidth
#   3. Map pcm-iio Stack labels to uncore_iio_N PMU indices
IIO_UNITS="${IIO_UNITS:-5 11 2 7}"
IIO_OPTS="ch_mask=0xff,fc_mask=0x07"

build_perf_events() {
    local EVENTS=""
    for unit in $IIO_UNITS; do
        EVENTS="${EVENTS}uncore_iio_${unit}/event=0xd5,umask=0xff,${IIO_OPTS}/,"
        EVENTS="${EVENTS}uncore_iio_${unit}/event=0xc2,umask=0x04,${IIO_OPTS}/,"
        EVENTS="${EVENTS}uncore_iio_${unit}/event=0xd0,umask=0x08,${IIO_OPTS}/,"
        EVENTS="${EVENTS}uncore_iio_${unit}/event=0x86,umask=0x08,${IIO_OPTS}/,"
    done
    echo "${EVENTS%,}"
}

PERF_EVENTS=$(build_perf_events)
PERF_DURATION=$((DURATION + DURATION_BUFFER))

echo ""
echo "IIO units monitored: $IIO_UNITS"
echo "perf stat duration:  ${PERF_DURATION}s (test=${DURATION}s + buffer=${DURATION_BUFFER}s)"

# --- Start perf stat on source node ---
PERF_FILE="/tmp/perf_ib_read_bw_${CONFIG_NAME}.txt"

echo ""
echo "Starting perf stat on source node ($SRC_SSH)..."
ssh "$SRC_SSH" "tmux kill-session -t perf_ib 2>/dev/null || true"
ssh "$SRC_SSH" "tmux new-session -d -s perf_ib"
ssh "$SRC_SSH" "tmux send-keys -t perf_ib 'sudo perf stat -a -e \"${PERF_EVENTS}\" sleep ${PERF_DURATION} 2>&1 | tee ${PERF_FILE}' Enter"

echo "Waiting 2s for perf stat to initialize..."
sleep 2

# --- Run ib_read_bw ---
echo ""
echo "=========================================="
echo "Running ib_read_bw: $CONFIG_NAME"
echo "=========================================="

uv run python3 "$MULTI_NIC_SCRIPT" --json "$CONFIG_JSON" \
    > "$OUT_DIR/${CONFIG_NAME}-results.json" \
    2> >(tee "$OUT_DIR/${CONFIG_NAME}.log" >&2)
IB_EXIT=$?

echo ""
echo "ib_read_bw exit code: $IB_EXIT"
if [ -s "$OUT_DIR/${CONFIG_NAME}-results.json" ]; then
    python3 -c "
import json, sys
d = json.load(open('$OUT_DIR/${CONFIG_NAME}-results.json'))
s = d.get('summary', {})
print(f\"  Total BW:    {s.get('total_avg_bw_gbps', 0):.1f} Gbps\")
print(f\"  Per NIC BW:  {s.get('per_nic_avg_bw_gbps', 0):.1f} Gbps\")
print(f\"  Pairs:       {s.get('total_pairs', 0)} ({s.get('successful', 0)} ok, {s.get('failed', 0)} failed)\")
" 2>/dev/null || true
fi

echo ""
echo "ib_read_bw complete. Waiting for perf stat to finish..."

# --- Wait for perf stat ---
for i in $(seq 1 30); do
    DONE=$(ssh "$SRC_SSH" "tmux capture-pane -t perf_ib -p | tail -3 | grep -c 'seconds time elapsed' || true" 2>/dev/null)
    if [[ "$DONE" -ge 1 ]]; then
        echo "perf stat complete."
        break
    fi
    echo "  Waiting for perf stat... (${i}/30)"
    sleep 5
done

# --- Collect perf stat output ---
echo ""
echo "Collecting perf stat output..."
scp "${SRC_SSH}:${PERF_FILE}" "$OUT_DIR/perf_${CONFIG_NAME}.txt" 2>/dev/null || echo "WARNING: Failed to copy perf output"

echo ""
echo "=========================================="
echo "Results saved to: $OUT_DIR"
echo "=========================================="
ls -lh "$OUT_DIR"/ 2>/dev/null
