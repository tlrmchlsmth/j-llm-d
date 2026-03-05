#!/usr/bin/env bash
set -euo pipefail

RESULTS_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_DIR="/home/rajjoshi/workspace/networking-debug-container/inter_node_tests/multi_nic_ib_write_bw"

PREFILL_NODE="networking-debug-pod-10.0.67.106"
DECODE_NODE="networking-debug-pod-10.0.69.254"

NAMESPACE="raj-network-debug"
QP_SWEEP=(1 2 4 8 16)
MSG_SIZES=("2MB:2097152" "16KB:16384")
TX_DEPTH=512
DURATION=30

generate_config() {
    local rdma_op=$1 msg_size=$2 num_qps=$3 outfile=$4

    if [[ "$rdma_op" == "read" ]]; then
        # Pull: decode (src/client) reads from prefill (dst/server)
        local src_pod="$DECODE_NODE" dst_pod="$PREFILL_NODE"
    else
        # Push: prefill (src/client) writes to decode (dst/server)
        local src_pod="$PREFILL_NODE" dst_pod="$DECODE_NODE"
    fi

    cat > "$outfile" <<JSONEOF
{
    "namespace": "$NAMESPACE",
    "tos": 41,
    "rdma_op": "$rdma_op",
    "msg_size": $msg_size,
    "num_qps": $num_qps,
    "tx_depth": $TX_DEPTH,
    "duration": $DURATION,
    "bi_directional": false,
    "use_hugepages": false,
    "test_pairs": [
        {
            "comment": "GPU0-mlx5_3 (cross-IIO) on both sides",
            "src_pod": "$src_pod",
            "src_hca": "mlx5_3",
            "src_gpu": "0",
            "src_gpu_type": "rocm",
            "dst_pod": "$dst_pod",
            "dst_hca": "mlx5_3",
            "dst_gpu": "0",
            "dst_gpu_type": "rocm"
        },
        {
            "comment": "GPU1-mlx5_4 (cross-IIO) on both sides",
            "src_pod": "$src_pod",
            "src_hca": "mlx5_4",
            "src_gpu": "1",
            "src_gpu_type": "rocm",
            "dst_pod": "$dst_pod",
            "dst_hca": "mlx5_4",
            "dst_gpu": "1",
            "dst_gpu_type": "rocm"
        }
    ]
}
JSONEOF
}

run_experiment() {
    local label=$1 rdma_op=$2 msg_label=$3 msg_bytes=$4 num_qps=$5

    local prefix="${label}-${msg_label}-qp${num_qps}"
    local config_file="${RESULTS_DIR}/${prefix}-config.json"
    local results_file="${RESULTS_DIR}/${prefix}-results.json"
    local log_file="${RESULTS_DIR}/${prefix}.log"

    echo ">>> Running $prefix ($rdma_op, msg=$msg_label, qps=$num_qps)"

    generate_config "$rdma_op" "$msg_bytes" "$num_qps" "$config_file"

    cd "$SCRIPT_DIR"
    uv run python multi_nic_ib_write_bw.py "$config_file" \
        1>"$results_file" 2>"$log_file"
    cat "$log_file"

    echo "<<< Done $prefix"
    echo ""
    sleep 3
}

echo "============================================"
echo "  Wire-line cross-IIO BOTH SIDES: Pull vs Push"
echo "  Prefill node: $PREFILL_NODE"
echo "  Decode node:  $DECODE_NODE"
echo "  GPU-NIC pairs: GPU0-mlx5_3, GPU1-mlx5_4 (cross-IIO on both)"
echo "============================================"
echo ""

for msg_entry in "${MSG_SIZES[@]}"; do
    msg_label="${msg_entry%%:*}"
    msg_bytes="${msg_entry##*:}"

    echo "===== Message size: $msg_label ====="

    for qps in "${QP_SWEEP[@]}"; do
        run_experiment "pull" "read" "$msg_label" "$msg_bytes" "$qps"
    done

    for qps in "${QP_SWEEP[@]}"; do
        run_experiment "push" "write" "$msg_label" "$msg_bytes" "$qps"
    done
done

echo ""
echo "============================================"
echo "  ALL EXPERIMENTS COMPLETE"
echo "============================================"
echo ""

echo "=== Summary (per-NIC Gbps at peak QP=16) ==="
for msg_entry in "${MSG_SIZES[@]}"; do
    msg_label="${msg_entry%%:*}"
    echo "--- $msg_label ---"
    for label in pull push; do
        f="${RESULTS_DIR}/${label}-${msg_label}-qp16-results.json"
        if [[ -f "$f" ]]; then
            python3 -c "
import json
d = json.load(open('$f'))
per_nic = d['summary']['per_nic_avg_bw_gbps']
total = d['summary']['total_avg_bw_gbps']
print(f'  $label: per_nic={per_nic:.1f} Gbps  total={total:.1f} Gbps')
"
        fi
    done
done
