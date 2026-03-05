#!/usr/bin/env bash
# Wireline Cross-IIO Throughput Experiments
#
# Measures max RDMA READ cross-IIO wireline throughput using ib_read_bw with
# GPU memory. Tests both prefill-side (NIC reading from GPU) and decode-side
# (NIC writing to GPU) cross-IIO bottlenecks, with single and dual streams.
#
# Experiments:
#   1a: Prefill cross-IIO read, 1 stream   (prefill GPU0-mlx5_3, decode GPU0-mlx5_0)
#   1b: Prefill cross-IIO read, 2 streams  (+ prefill GPU1-mlx5_4, decode GPU1-mlx5_2)
#   2a: Decode cross-IIO write, 1 stream   (prefill GPU0-mlx5_0, decode GPU0-mlx5_3)
#   2b: Decode cross-IIO write, 2 streams  (+ prefill GPU1-mlx5_2, decode GPU1-mlx5_4)
#
# Each experiment is run at both 2MB and 16KB message sizes, sweeping num_qps.
# Decode-side NIC counters are profiled (best-effort) during each run.
#
# Usage:
#   ./run_wireline_cross_iio.sh [OUTPUT_DIR]
#
# Example:
#   ./run_wireline_cross_iio.sh ../results/wireline-cross-iio

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INVESTIGATION_DIR="$(cd "${SCRIPT_DIR}/../nixl-iio-investigation" && pwd)"
POLLER_SRC="${INVESTIGATION_DIR}/scripts/poll_nic_counters.cpp"
MULTI_NIC_SCRIPT="${MULTI_NIC_SCRIPT:-/home/rajjoshi/workspace/networking-debug-container/inter_node_tests/multi_nic_ib_write_bw/multi_nic_ib_write_bw.py}"

OUT_DIR="${1:-${SCRIPT_DIR}/../results/wireline-cross-iio}"
NAMESPACE="${NAMESPACE:-raj-network-debug}"

QP_SWEEP="1 2 4 8 16"
MSG_SIZES="2097152 16384"
DURATION=30
TX_DEPTH=512
TOS=41

mkdir -p "$OUT_DIR"

msg_size_label() {
    case "$1" in
        2097152) echo "2MB" ;;
        16384)   echo "16KB" ;;
        *)       echo "${1}B" ;;
    esac
}

# ============================================================
# 1. Discover pods
# ============================================================
echo "=============================================="
echo "Wireline Cross-IIO Throughput Experiments"
echo "=============================================="
echo ""
echo "Discovering prefill/decode pods..."

DECODE_POD=$(kubectl get pods -n "$NAMESPACE" -o name | grep "ms-glm-disagg.*decode" | head -1 | sed 's|pod/||')
PREFILL_POD=$(kubectl get pods -n "$NAMESPACE" -o name | grep "ms-glm-disagg.*prefill" | head -1 | sed 's|pod/||')

if [ -z "$DECODE_POD" ] || [ -z "$PREFILL_POD" ]; then
    echo "ERROR: Could not find decode/prefill pods in namespace $NAMESPACE"
    exit 1
fi

DECODE_NODE=$(kubectl get pod -n "$NAMESPACE" "$DECODE_POD" -o jsonpath='{.spec.nodeName}')
PREFILL_NODE=$(kubectl get pod -n "$NAMESPACE" "$PREFILL_POD" -o jsonpath='{.spec.nodeName}')

echo "  Decode:  $DECODE_POD on $DECODE_NODE"
echo "  Prefill: $PREFILL_POD on $PREFILL_NODE"

DECODE_DEBUG_POD="networking-debug-pod-${DECODE_NODE}"
PREFILL_DEBUG_POD="networking-debug-pod-${PREFILL_NODE}"

echo ""
echo "Debug pods:"
echo "  Decode:  $DECODE_DEBUG_POD"
echo "  Prefill: $PREFILL_DEBUG_POD"

for pod in "$DECODE_DEBUG_POD" "$PREFILL_DEBUG_POD"; do
    if ! kubectl get pod -n "$NAMESPACE" "$pod" &>/dev/null; then
        echo "ERROR: Debug pod $pod not found in namespace $NAMESPACE"
        exit 1
    fi
done
echo "  Both debug pods verified."

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
echo ""
echo "  Decode SSH alias: $DECODE_SSH"

# ============================================================
# 2. Deploy NIC poller (best-effort)
# ============================================================
PROFILING_ENABLED=true

deploy_poller() {
    echo ""
    echo "Deploying NIC counter poller into decode debug pod..."

    if [ ! -f "$POLLER_SRC" ]; then
        echo "  WARNING: Poller source not found at $POLLER_SRC"
        PROFILING_ENABLED=false
        return
    fi

    echo "  Compiling static binary on $DECODE_SSH..."
    scp -q "$POLLER_SRC" "${DECODE_SSH}:/tmp/poll_nic_counters.cpp" || { echo "  WARNING: scp failed"; PROFILING_ENABLED=false; return; }
    ssh "$DECODE_SSH" "g++ -O2 -static -o /tmp/poll_nic_counters_static /tmp/poll_nic_counters.cpp 2>&1 | grep -v warning || true" || { echo "  WARNING: compile failed"; PROFILING_ENABLED=false; return; }

    echo "  Copying binary into debug pod..."
    scp -q "${DECODE_SSH}:/tmp/poll_nic_counters_static" /tmp/poll_nic_counters_static || { echo "  WARNING: scp back failed"; PROFILING_ENABLED=false; return; }
    kubectl -n "$NAMESPACE" cp /tmp/poll_nic_counters_static "${DECODE_DEBUG_POD}:/tmp/poll_nic_counters" 2>/dev/null || { echo "  WARNING: kubectl cp failed"; PROFILING_ENABLED=false; return; }
    kubectl -n "$NAMESPACE" exec "$DECODE_DEBUG_POD" -- chmod +x /tmp/poll_nic_counters || { echo "  WARNING: chmod failed"; PROFILING_ENABLED=false; return; }

    echo "  Poller deployed successfully."
}

deploy_poller

if [ "$PROFILING_ENABLED" = true ]; then
    echo "  NIC profiling: ENABLED"
else
    echo "  NIC profiling: DISABLED (will continue without NIC counter traces)"
fi

# ============================================================
# 3. Poller management helpers
# ============================================================
start_pollers() {
    local nics=("$@")
    if [ "$PROFILING_ENABLED" != true ]; then return; fi

    kubectl -n "$NAMESPACE" exec "$DECODE_DEBUG_POD" -- \
        bash -c 'pkill -f poll_nic_counters 2>/dev/null || true' 2>/dev/null || true

    for nic in "${nics[@]}"; do
        kubectl -n "$NAMESPACE" exec "$DECODE_DEBUG_POD" -- \
            bash -c "nohup /tmp/poll_nic_counters ${nic} /tmp/nic_${nic}.tsv 0 > /tmp/poll_${nic}.log 2>&1 &" || true
    done
    sleep 2
}

stop_pollers() {
    if [ "$PROFILING_ENABLED" != true ]; then return; fi
    kubectl -n "$NAMESPACE" exec "$DECODE_DEBUG_POD" -- \
        bash -c 'pkill -SIGINT -f poll_nic_counters 2>/dev/null || true' 2>/dev/null || true
    sleep 5
}

collect_nic_traces() {
    local prefix="$1"
    shift
    local nics=("$@")
    if [ "$PROFILING_ENABLED" != true ]; then return; fi

    for nic in "${nics[@]}"; do
        kubectl -n "$NAMESPACE" cp "${DECODE_DEBUG_POD}:/tmp/nic_${nic}.tsv" "${OUT_DIR}/${prefix}-nic_${nic}.tsv" 2>/dev/null \
            || echo "  WARNING: Failed to collect NIC trace for $nic"
    done
}

# ============================================================
# 4. Experiment definitions
# ============================================================

# Each experiment: EXP_NAME  DECODE_NICS(src)  PREFILL_NICS(dst)  DECODE_GPUS  PREFILL_GPUS
# In ib_read_bw: src=client(decode), dst=server(prefill)

generate_config() {
    local exp_name="$1"
    local msg_size="$2"
    local num_qps="$3"
    local config_file="$4"

    local pairs=""

    case "$exp_name" in
        exp1a)
            pairs=$(cat <<'PAIRS'
            {
                "comment": "Prefill GPU0-mlx5_3 (cross-IIO) <- Decode GPU0-mlx5_0 (same-IIO)",
                "src_pod": "DECODE_DEBUG_POD",
                "src_hca": "mlx5_0",
                "src_gpu": "0",
                "src_gpu_type": "rocm",
                "dst_pod": "PREFILL_DEBUG_POD",
                "dst_hca": "mlx5_3",
                "dst_gpu": "0",
                "dst_gpu_type": "rocm"
            }
PAIRS
)
            ;;
        exp1b)
            pairs=$(cat <<'PAIRS'
            {
                "comment": "Prefill GPU0-mlx5_3 (cross-IIO) <- Decode GPU0-mlx5_0 (same-IIO)",
                "src_pod": "DECODE_DEBUG_POD",
                "src_hca": "mlx5_0",
                "src_gpu": "0",
                "src_gpu_type": "rocm",
                "dst_pod": "PREFILL_DEBUG_POD",
                "dst_hca": "mlx5_3",
                "dst_gpu": "0",
                "dst_gpu_type": "rocm"
            },
            {
                "comment": "Prefill GPU1-mlx5_4 (cross-IIO) <- Decode GPU1-mlx5_2 (same-IIO)",
                "src_pod": "DECODE_DEBUG_POD",
                "src_hca": "mlx5_2",
                "src_gpu": "1",
                "src_gpu_type": "rocm",
                "dst_pod": "PREFILL_DEBUG_POD",
                "dst_hca": "mlx5_4",
                "dst_gpu": "1",
                "dst_gpu_type": "rocm"
            }
PAIRS
)
            ;;
        exp2a)
            pairs=$(cat <<'PAIRS'
            {
                "comment": "Prefill GPU0-mlx5_0 (same-IIO) <- Decode GPU0-mlx5_3 (cross-IIO)",
                "src_pod": "DECODE_DEBUG_POD",
                "src_hca": "mlx5_3",
                "src_gpu": "0",
                "src_gpu_type": "rocm",
                "dst_pod": "PREFILL_DEBUG_POD",
                "dst_hca": "mlx5_0",
                "dst_gpu": "0",
                "dst_gpu_type": "rocm"
            }
PAIRS
)
            ;;
        exp2b)
            pairs=$(cat <<'PAIRS'
            {
                "comment": "Prefill GPU0-mlx5_0 (same-IIO) <- Decode GPU0-mlx5_3 (cross-IIO)",
                "src_pod": "DECODE_DEBUG_POD",
                "src_hca": "mlx5_3",
                "src_gpu": "0",
                "src_gpu_type": "rocm",
                "dst_pod": "PREFILL_DEBUG_POD",
                "dst_hca": "mlx5_0",
                "dst_gpu": "0",
                "dst_gpu_type": "rocm"
            },
            {
                "comment": "Prefill GPU1-mlx5_2 (same-IIO) <- Decode GPU1-mlx5_4 (cross-IIO)",
                "src_pod": "DECODE_DEBUG_POD",
                "src_hca": "mlx5_4",
                "src_gpu": "1",
                "src_gpu_type": "rocm",
                "dst_pod": "PREFILL_DEBUG_POD",
                "dst_hca": "mlx5_2",
                "dst_gpu": "1",
                "dst_gpu_type": "rocm"
            }
PAIRS
)
            ;;
    esac

    # Substitute pod names
    pairs="${pairs//DECODE_DEBUG_POD/$DECODE_DEBUG_POD}"
    pairs="${pairs//PREFILL_DEBUG_POD/$PREFILL_DEBUG_POD}"

    cat > "$config_file" <<EOF
{
    "namespace": "$NAMESPACE",
    "tos": $TOS,
    "rdma_op": "read",
    "msg_size": $msg_size,
    "num_qps": $num_qps,
    "tx_depth": $TX_DEPTH,
    "duration": $DURATION,
    "bi_directional": false,
    "use_hugepages": false,
    "test_pairs": [
$pairs
    ]
}
EOF
}

decode_nics_for_exp() {
    case "$1" in
        exp1a) echo "mlx5_0" ;;
        exp1b) echo "mlx5_0 mlx5_2" ;;
        exp2a) echo "mlx5_3" ;;
        exp2b) echo "mlx5_3 mlx5_4" ;;
    esac
}

exp_description() {
    case "$1" in
        exp1a) echo "Prefill cross-IIO read, 1 stream" ;;
        exp1b) echo "Prefill cross-IIO read, 2 streams" ;;
        exp2a) echo "Decode cross-IIO write, 1 stream" ;;
        exp2b) echo "Decode cross-IIO write, 2 streams" ;;
    esac
}

# ============================================================
# 5. Run all experiments
# ============================================================
EXPERIMENTS="exp1a exp1b exp2a exp2b"

echo ""
echo "=============================================="
echo "Running experiments"
echo "  Experiments: $EXPERIMENTS"
echo "  Message sizes: $(for s in $MSG_SIZES; do msg_size_label "$s"; echo -n " "; done)"
echo "  QP sweep: $QP_SWEEP"
echo "  TX depth: $TX_DEPTH"
echo "  Duration: ${DURATION}s per run"
echo "  Output: $OUT_DIR"
echo "=============================================="

for msg_size in $MSG_SIZES; do
    SIZE_LABEL=$(msg_size_label "$msg_size")

    for exp in $EXPERIMENTS; do
        DESC=$(exp_description "$exp")
        NICS_STR=$(decode_nics_for_exp "$exp")
        read -ra DECODE_NICS <<< "$NICS_STR"

        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "$exp ($SIZE_LABEL): $DESC"
        echo "  Decode NICs: ${DECODE_NICS[*]}"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

        for qp in $QP_SWEEP; do
            PREFIX="${exp}-${SIZE_LABEL}-qp${qp}"
            CONFIG_FILE="${OUT_DIR}/${PREFIX}-config.json"
            RESULT_FILE="${OUT_DIR}/${PREFIX}-results.json"

            echo ""
            echo "--- $PREFIX ---"

            generate_config "$exp" "$msg_size" "$qp" "$CONFIG_FILE"

            start_pollers "${DECODE_NICS[@]}"

            echo "  Running ib_read_bw (qp=$qp, msg=$SIZE_LABEL, tx_depth=$TX_DEPTH, dur=${DURATION}s)..."
            if uv run python3 "$MULTI_NIC_SCRIPT" --json "$CONFIG_FILE" > "$RESULT_FILE" 2>"${OUT_DIR}/${PREFIX}.log"; then
                BW=$(python3 -c "
import json, sys
d = json.load(open('$RESULT_FILE'))
s = d.get('summary', {})
print(f\"  Total: {s.get('total_avg_bw_gbps', 0):.1f} Gbps, Per-NIC: {s.get('per_nic_avg_bw_gbps', 0):.1f} Gbps\")
" 2>/dev/null || echo "  (could not parse results)")
                echo "$BW"
            else
                echo "  WARNING: ib_read_bw failed (see ${PREFIX}.log)"
            fi

            stop_pollers
            collect_nic_traces "$PREFIX" "${DECODE_NICS[@]}"

            sleep 5
        done
    done
done

# ============================================================
# 6. Summary table
# ============================================================
echo ""
echo "=============================================="
echo "Summary"
echo "=============================================="

python3 - "$OUT_DIR" <<'SUMMARY_SCRIPT'
import json, sys, os
from pathlib import Path

out_dir = Path(sys.argv[1])

rows = []
for f in sorted(out_dir.glob("*-results.json")):
    name = f.stem.replace("-results", "")
    parts = name.split("-")
    if len(parts) < 3:
        continue
    exp = parts[0]
    size = parts[1]
    qp = parts[2]
    try:
        d = json.load(open(f))
        s = d.get("summary", {})
        total = s.get("total_avg_bw_gbps", 0)
        per_nic = s.get("per_nic_avg_bw_gbps", 0)
        pairs = s.get("total_pairs", 0)
        rows.append((exp, size, qp, pairs, per_nic, total))
    except Exception:
        rows.append((exp, size, qp, 0, 0, 0))

if not rows:
    print("  No results found.")
    sys.exit(0)

print(f"{'Experiment':<8} {'Size':<6} {'QPs':<5} {'Pairs':<6} {'Per-NIC Gbps':>13} {'Total Gbps':>11}")
print("-" * 55)
for exp, size, qp, pairs, per_nic, total in rows:
    print(f"{exp:<8} {size:<6} {qp:<5} {pairs:<6} {per_nic:>13.1f} {total:>11.1f}")
SUMMARY_SCRIPT

echo ""
echo "=============================================="
echo "Done. Results in: $OUT_DIR"
echo "=============================================="
