#!/usr/bin/env bash
# Profile NIC throughput at maximum fidelity during NIXL e2e transfers.
#
# Auto-discovers active NICs from UCX_NET_DEVICES on the pods.
# Polls NIC counters on BOTH decode and prefill pods.
# Supports 1-NIC and 2-NIC configurations.
#
# Usage:
#   ./profile_nic_throughput.sh nixl <output_dir> [NUM_PROMPTS] [ISL] [OSL]
#
# Examples:
#   ./profile_nic_throughput.sh nixl results/nixl_isolation/nixl-s1 50 4096 256

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INVESTIGATION_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
POLLER_SRC="${SCRIPT_DIR}/poll_nic_counters.cpp"
ANALYZER="${SCRIPT_DIR}/analyze_nic_counters.py"
SWEEP_SCRIPT="${INVESTIGATION_DIR}/../sweep_concurrency_with_kv_transfer_logs.sh"

MODE="${1:?Usage: $0 <nixl|scatter> <output_dir> [NUM_PROMPTS] [ISL] [OSL]}"
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

# --- Auto-discover active NICs from UCX_NET_DEVICES (per pod) ---
echo ""
echo "Discovering active NICs from UCX_NET_DEVICES..."

parse_nics() {
    local ucx_net_devices="$1"
    local -n _out_array=$2
    IFS=',' read -ra specs <<< "$ucx_net_devices"
    _out_array=()
    for spec in "${specs[@]}"; do
        _out_array+=("${spec%%:*}")
    done
}

DECODE_UCX_NET=$(kubectl exec -n "$NAMESPACE" "$DECODE_POD" -c vllm -- \
    bash -c 'echo $UCX_NET_DEVICES' 2>/dev/null || echo "")
PREFILL_UCX_NET=$(kubectl exec -n "$NAMESPACE" "$PREFILL_POD" -c vllm -- \
    bash -c 'echo $UCX_NET_DEVICES' 2>/dev/null || echo "")

if [ -z "$DECODE_UCX_NET" ]; then
    echo "ERROR: UCX_NET_DEVICES not set on decode pod. Cannot determine NICs."
    exit 1
fi
if [ -z "$PREFILL_UCX_NET" ]; then
    echo "ERROR: UCX_NET_DEVICES not set on prefill pod. Cannot determine NICs."
    exit 1
fi

parse_nics "$DECODE_UCX_NET" DECODE_NICS
parse_nics "$PREFILL_UCX_NET" PREFILL_NICS

echo "  Decode  UCX_NET_DEVICES=$DECODE_UCX_NET  -> NICs: ${DECODE_NICS[*]}"
echo "  Prefill UCX_NET_DEVICES=$PREFILL_UCX_NET -> NICs: ${PREFILL_NICS[*]}"

get_nics_for_pod() {
    local label="$1"
    if [ "$label" = "decode" ]; then
        echo "${DECODE_NICS[@]}"
    else
        echo "${PREFILL_NICS[@]}"
    fi
}

# --- Deploy poller binary into both pods ---
deploy_poller() {
    local pod="$1"
    local node_ssh="$2"
    local label="$3"

    echo "  Deploying poller into $label pod ($pod)..."
    echo "    Compiling static binary on $node_ssh..."
    scp -q "$POLLER_SRC" "${node_ssh}:/tmp/poll_nic_counters.cpp"
    ssh "$node_ssh" "g++ -O2 -static -o /tmp/poll_nic_counters_static /tmp/poll_nic_counters.cpp 2>&1 | grep -v warning || true"
    echo "    Copying static binary into pod..."
    scp -q "${node_ssh}:/tmp/poll_nic_counters_static" /tmp/poll_nic_counters_static
    kubectl -n "$NAMESPACE" cp /tmp/poll_nic_counters_static "${pod}:/tmp/poll_nic_counters" -c vllm 2>/dev/null
    kubectl -n "$NAMESPACE" exec "$pod" -c vllm -- chmod +x /tmp/poll_nic_counters
    echo "    Done."
}

echo ""
echo "Deploying NIC counter pollers..."
deploy_poller "$DECODE_POD" "$DECODE_SSH" "decode"
deploy_poller "$PREFILL_POD" "$PREFILL_SSH" "prefill"

# --- Poller management ---
start_pollers() {
    echo ""
    echo "Starting NIC counter pollers (no-sleep max fidelity)..."

    for pod_label in decode prefill; do
        if [ "$pod_label" = "decode" ]; then
            pod="$DECODE_POD"
        else
            pod="$PREFILL_POD"
        fi

        kubectl -n "$NAMESPACE" exec "$pod" -c vllm -- \
            bash -c 'pkill -f poll_nic_counters 2>/dev/null || true' 2>/dev/null || true

        local nics
        read -ra nics <<< "$(get_nics_for_pod "$pod_label")"
        for nic in "${nics[@]}"; do
            kubectl -n "$NAMESPACE" exec "$pod" -c vllm -- \
                bash -c "nohup /tmp/poll_nic_counters ${nic} /tmp/nic_${nic}.tsv 0 > /tmp/poll_${nic}.log 2>&1 &"
            echo "  Started poller: ${pod_label}/${nic}"
        done
    done

    echo "  Waiting 2s for initialization..."
    sleep 2
}

stop_pollers() {
    echo ""
    echo "Stopping NIC counter pollers..."
    for pod_label in decode prefill; do
        if [ "$pod_label" = "decode" ]; then
            pod="$DECODE_POD"
        else
            pod="$PREFILL_POD"
        fi
        kubectl -n "$NAMESPACE" exec "$pod" -c vllm -- \
            bash -c 'pkill -SIGINT -f poll_nic_counters 2>/dev/null || true' 2>/dev/null || true
    done
    echo "  Waiting 10s for pollers to flush output..."
    sleep 10

    for pod_label in decode prefill; do
        if [ "$pod_label" = "decode" ]; then
            pod="$DECODE_POD"
        else
            pod="$PREFILL_POD"
        fi
        local nics
        read -ra nics <<< "$(get_nics_for_pod "$pod_label")"
        for nic in "${nics[@]}"; do
            echo "  ${pod_label}/${nic} poller log:"
            kubectl -n "$NAMESPACE" exec "$pod" -c vllm -- cat /tmp/poll_${nic}.log 2>/dev/null || echo "    (no log)"
        done
    done
}

collect_results() {
    echo ""
    echo "Collecting NIC counter traces..."
    for pod_label in decode prefill; do
        if [ "$pod_label" = "decode" ]; then
            pod="$DECODE_POD"
        else
            pod="$PREFILL_POD"
        fi
        local nics
        read -ra nics <<< "$(get_nics_for_pod "$pod_label")"
        for nic in "${nics[@]}"; do
            local dst="$OUT_DIR/nic_${pod_label}_${nic}.tsv"
            kubectl -n "$NAMESPACE" cp "${pod}:/tmp/nic_${nic}.tsv" "$dst" -c vllm 2>/dev/null \
                || echo "  WARNING: Failed to copy ${pod_label}/${nic} trace"
        done
    done

    echo ""
    echo "Collected files:"
    ls -lh "$OUT_DIR"/nic_*.tsv 2>/dev/null || echo "  (none)"
}

# ========================================================
# MODE: NIXL e2e benchmark
# ========================================================
if [ "$MODE" = "nixl" ]; then
    NUM_PROMPTS="${3:-50}"
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
# MODE: scatter_bench (manual)
# ========================================================
elif [ "$MODE" = "scatter" ]; then
    echo ""
    echo "scatter_bench profiling"
    start_pollers

    echo "=========================================="
    echo "Pollers running. Now run scatter_bench manually."
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
