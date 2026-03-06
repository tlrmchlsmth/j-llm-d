#!/usr/bin/env bash
# Master orchestration for NIXL Transfer Speed Isolation Experiments.
#
# Runs deployment configurations isolating IIO crossing overhead and
# UCX rails overhead, measuring per-NIC WR request rate and NIXL transfer
# throughput via NIC counters and vLLM logs.
#
# Usage:
#   ./run_isolation_experiments.sh [nixl-s1|..|nixl-s9|tp1|tp2|confound|all]
#
# Examples:
#   ./run_isolation_experiments.sh all          # Run all 6 early experiments (s1-s6)
#   ./run_isolation_experiments.sh tp1          # Run TP=1 group (s1, s2, s5)
#   ./run_isolation_experiments.sh tp2          # Run TP=2 group (s3, s4, s6)
#   ./run_isolation_experiments.sh confound     # Run confounding-factor experiments (s6-s9)
#   ./run_isolation_experiments.sh nixl-s7      # Run single experiment

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PCIE_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
RESULTS_BASE="${PCIE_DIR}/results/nixl_isolation"
SWITCH_SCRIPT="${PCIE_DIR}/switch_scenario.sh"
PROFILE_SCRIPT="${SCRIPT_DIR}/profile_nic_throughput.sh"
ANALYZER="${SCRIPT_DIR}/analyze_nic_counters.py"
RESULTS_TABLE="${RESULTS_BASE}/results_table.txt"

NAMESPACE="${NAMESPACE:-raj-network-debug}"
NUM_PROMPTS="${NUM_PROMPTS:-50}"
ISL="${ISL:-4096}"
OSL="${OSL:-256}"

# TP=1 experiments use GPU 0 only; TP=2 use GPU 0+1 (or 0+7 for cross-NUMA)
declare -A SCENARIO_TP=(
    [nixl-s1]=1  [nixl-s2]=1  [nixl-s5]=1
    [nixl-s3]=2  [nixl-s4]=2  [nixl-s6]=2
    [nixl-s7]=2  [nixl-s8]=2  [nixl-s9]=2
)
declare -A SCENARIO_PURPOSE=(
    [nixl-s1]="Baseline (1 GPU, same-IIO)"
    [nixl-s2]="Single IIO crossing"
    [nixl-s3]="Baseline (2 GPUs, same-IIO)"
    [nixl-s4]="Rails=2 (each GPU crosses to other's NIC)"
    [nixl-s5]="Rails + 1 IIO crossing (1 GPU)"
    [nixl-s6]="Cross-IIO + rails=2 (baseline for confounding)"
    [nixl-s7]="Remove cross-IIO on decode, keep rails=2"
    [nixl-s8]="Remove rails splitting, keep cross-IIO"
    [nixl-s9]="Remove both factors on decode"
)
declare -A SCENARIO_NICS=(
    [nixl-s1]="mlx5_10"
    [nixl-s2]="mlx5_12"
    [nixl-s3]="mlx5_10,mlx5_11"
    [nixl-s4]="mlx5_10,mlx5_11"
    [nixl-s5]="mlx5_10,mlx5_12"
    [nixl-s6]="mlx5_12,mlx5_13"
    [nixl-s7]="mlx5_10,mlx5_11"
    [nixl-s8]="mlx5_11,mlx5_16"
    [nixl-s9]="mlx5_10,mlx5_11"
)
declare -A SCENARIO_RAILS=(
    [nixl-s1]=1  [nixl-s2]=1  [nixl-s3]=1
    [nixl-s4]=2  [nixl-s5]=2  [nixl-s6]=2
    [nixl-s7]=2  [nixl-s8]=1  [nixl-s9]=1
)
declare -A SCENARIO_IIO=(
    [nixl-s1]="same"
    [nixl-s2]="cross"
    [nixl-s3]="same"
    [nixl-s4]="mixed"
    [nixl-s5]="mixed"
    [nixl-s6]="cross"
    [nixl-s7]="same(decode)/cross(prefill)"
    [nixl-s8]="cross"
    [nixl-s9]="same(decode)/cross(prefill)"
)

mkdir -p "$RESULTS_BASE"

# --- Results table management ---
init_results_table() {
    cat > "$RESULTS_TABLE" <<'EOF'
# NIXL Transfer Speed Isolation Experiments
# MC=1, ISL=4096, OSL=256, MIN_PROMPTS=50
#
# Per-NIC TX = RDMA READ request rate (decode side, outgoing MRd packets)
# Per-NIC RX = incoming KV data throughput (decode side, CplD)
# NIXL xfer = avg_xfer_time from vLLM decode logs, converted to throughput

| # | Scenario | Purpose                          | TP | NICs             | Rails | IIO   | Per-NIC TX (Gbps) | Per-NIC WR/s | Per-NIC RX (Gbps) | NIXL xfer (ms) | NIXL Gbps |
|---|----------|----------------------------------|----|------------------|-------|-------|--------------------|--------------|---------------------|----------------|-----------|
EOF
    echo "Results table initialized: $RESULTS_TABLE"
}

append_result_row() {
    local scenario="$1"
    local num="$2"
    local out_dir="$3"

    local tp="${SCENARIO_TP[$scenario]}"
    local purpose="${SCENARIO_PURPOSE[$scenario]}"
    local nics="${SCENARIO_NICS[$scenario]}"
    local rails="${SCENARIO_RAILS[$scenario]}"
    local iio="${SCENARIO_IIO[$scenario]}"

    # Extract NIXL metrics from decode log
    local decode_log="$out_dir/decode_mc1.log"
    local nixl_xfer_ms="N/A"
    local nixl_gbps="N/A"
    local nixl_mb="N/A"

    if [ -f "$decode_log" ]; then
        # Parse avg_xfer_time and avg_xfer_size from NIXL KV Transfer Metrics in result log
        local result_log="$out_dir/result_mc1.txt"
        if [ -f "$result_log" ]; then
            nixl_xfer_ms=$(grep "avg_xfer_time:" "$result_log" 2>/dev/null | tail -1 | grep -oE '[0-9]+\.[0-9]+' || echo "N/A")
            nixl_mb=$(grep "avg_mb_per_xfer:" "$result_log" 2>/dev/null | tail -1 | grep -oE '[0-9]+\.[0-9]+' || echo "N/A")
            if [ "$nixl_xfer_ms" != "N/A" ] && [ "$nixl_mb" != "N/A" ]; then
                nixl_gbps=$(python3 -c "print(f'{float(\"$nixl_mb\") / float(\"$nixl_xfer_ms\") * 1000 * 8 / 1000:.1f}')" 2>/dev/null || echo "N/A")
            fi
        fi
    fi

    # Extract NIC counter metrics from decode-side TSV files
    local per_nic_tx="N/A"
    local per_nic_wr="N/A"
    local per_nic_rx="N/A"

    # Find decode NIC TSV files
    local decode_tsvs=()
    for nic in ${nics//,/ }; do
        local tsv="$out_dir/nic_decode_${nic}.tsv"
        if [ -f "$tsv" ]; then
            decode_tsvs+=("$tsv")
        fi
    done

    if [ ${#decode_tsvs[@]} -gt 0 ]; then
        # Use python to compute avg per-NIC TX/RX rates across all bursts
        local nic_metrics
        nic_metrics=$(python3 -c "
import csv, sys

def load_tsv(path):
    samples = []
    with open(path) as f:
        reader = csv.reader(f, delimiter='\t')
        next(reader)
        for row in reader:
            if len(row) >= 3:
                samples.append((int(row[0]), int(row[1]), int(row[2])))
    return samples

def find_bursts(samples, rx_jump=2000000):
    bursts = []
    in_burst = False
    start = quiet_count = 0
    for i in range(1, len(samples)):
        rx_d = samples[i][2] - samples[i-1][2]
        if rx_d > rx_jump:
            if not in_burst:
                start = i - 1
                in_burst = True
            quiet_count = 0
        else:
            if in_burst:
                quiet_count += 1
                if quiet_count > 15:
                    bursts.append((start, i - quiet_count))
                    in_burst = False
                    quiet_count = 0
    if in_burst:
        bursts.append((start, len(samples) - 1))
    return bursts

all_tx_gbps = []
all_rx_gbps = []
all_wr_rate = []

for tsv_path in sys.argv[1:]:
    data = load_tsv(tsv_path)
    bursts = find_bursts(data)
    for s, e in bursts:
        dur_ms = (data[e][0] - data[s][0]) / 1e6
        if dur_ms < 50:
            continue
        tx_d = data[e][1] - data[s][1]
        rx_d = data[e][2] - data[s][2]
        if rx_d < 10_000_000:
            continue
        tx_gbps = tx_d * 8 / (dur_ms * 1e6)
        rx_gbps = rx_d * 8 / (dur_ms * 1e6)
        blocks = rx_d / 16384
        wr_rate = blocks / (dur_ms / 1000) if dur_ms > 0 else 0
        all_tx_gbps.append(tx_gbps)
        all_rx_gbps.append(rx_gbps)
        all_wr_rate.append(wr_rate)

n = len(all_tx_gbps)
if n > 0:
    avg_tx = sum(all_tx_gbps) / n
    avg_rx = sum(all_rx_gbps) / n
    avg_wr = sum(all_wr_rate) / n
    # Per-NIC average (divide by number of NIC files since each file = 1 NIC)
    num_nics = len(sys.argv[1:])
    print(f'{avg_tx:.3f} {avg_wr:.0f} {avg_rx:.1f}')
else:
    print('N/A N/A N/A')
" "${decode_tsvs[@]}" 2>/dev/null || echo "N/A N/A N/A")

        per_nic_tx=$(echo "$nic_metrics" | awk '{print $1}')
        per_nic_wr=$(echo "$nic_metrics" | awk '{print $2}')
        per_nic_rx=$(echo "$nic_metrics" | awk '{print $3}')
    fi

    printf "| %s | %-8s | %-32s | %s  | %-16s | %s     | %-5s | %-18s | %-12s | %-19s | %-14s | %-9s |\n" \
        "$num" "$scenario" "$purpose" "$tp" "$nics" "$rails" "$iio" \
        "$per_nic_tx" "$per_nic_wr" "$per_nic_rx" "$nixl_xfer_ms" "$nixl_gbps" \
        >> "$RESULTS_TABLE"

    echo ""
    echo "===== RESULT: $scenario ====="
    echo "  Purpose:       $purpose"
    echo "  TP=$tp  NICs=$nics  Rails=$rails  IIO=$iio"
    echo "  Per-NIC TX:    $per_nic_tx Gbps"
    echo "  Per-NIC WR/s:  $per_nic_wr"
    echo "  Per-NIC RX:    $per_nic_rx Gbps"
    echo "  NIXL xfer:     $nixl_xfer_ms ms"
    echo "  NIXL Gbps:     $nixl_gbps"
    echo "=========================="
}

print_results_table() {
    echo ""
    echo "=============================================="
    echo "RUNNING RESULTS TABLE"
    echo "=============================================="
    cat "$RESULTS_TABLE"
    echo ""
}

# --- Run a single experiment ---
run_experiment() {
    local scenario="$1"
    local num="$2"
    local out_dir="${RESULTS_BASE}/${scenario}"

    echo ""
    echo "############################################################"
    echo "# Experiment $num: $scenario"
    echo "# ${SCENARIO_PURPOSE[$scenario]}"
    echo "# TP=${SCENARIO_TP[$scenario]}  NICs=${SCENARIO_NICS[$scenario]}  Rails=${SCENARIO_RAILS[$scenario]}  IIO=${SCENARIO_IIO[$scenario]}"
    echo "############################################################"
    echo ""

    mkdir -p "$out_dir"

    echo "--- Switching to scenario $scenario ---"
    bash "$SWITCH_SCRIPT" "$scenario"

    echo ""
    echo "--- Waiting 30s for pods to stabilize after rollout ---"
    sleep 30

    echo ""
    echo "--- Running NIC-profiled NIXL benchmark ---"
    bash "$PROFILE_SCRIPT" nixl "$out_dir" "$NUM_PROMPTS" "$ISL" "$OSL"

    echo ""
    echo "--- Extracting results ---"
    append_result_row "$scenario" "$num" "$out_dir"
    print_results_table
}

# --- Deploy TP group ---
deploy_tp() {
    local tp="$1"

    echo ""
    echo "=============================================="
    echo "Deploying TP=$tp configuration"
    echo "=============================================="

    cd "$PCIE_DIR"
    if [ "$tp" = "1" ]; then
        MS_VALUES=ms/values-tp1.yaml just deploy
    else
        just deploy
    fi

    echo ""
    echo "Waiting for pods to be ready..."
    kubectl rollout status deployment/ms-glm-disagg-llm-d-modelservice-decode -n "$NAMESPACE" --timeout=900s
    kubectl rollout status deployment/ms-glm-disagg-llm-d-modelservice-prefill -n "$NAMESPACE" --timeout=900s

    echo ""
    echo "Pods ready. Waiting additional 60s for vLLM startup..."
    sleep 60
    cd "$SCRIPT_DIR"
}

# --- Main ---
TARGET="${1:-all}"

case "$TARGET" in
    all)
        init_results_table
        deploy_tp 1
        run_experiment nixl-s1 1
        run_experiment nixl-s2 2
        run_experiment nixl-s5 5
        deploy_tp 2
        run_experiment nixl-s3 3
        run_experiment nixl-s4 4
        run_experiment nixl-s6 6
        print_results_table
        ;;
    tp1)
        init_results_table
        deploy_tp 1
        run_experiment nixl-s1 1
        run_experiment nixl-s2 2
        run_experiment nixl-s5 5
        print_results_table
        ;;
    tp2)
        init_results_table
        deploy_tp 2
        run_experiment nixl-s3 3
        run_experiment nixl-s4 4
        run_experiment nixl-s6 6
        print_results_table
        ;;
    confound)
        init_results_table
        run_experiment nixl-s6 6
        run_experiment nixl-s7 7
        run_experiment nixl-s8 8
        run_experiment nixl-s9 9
        print_results_table
        ;;
    nixl-s[1-9])
        num="${TARGET##nixl-s}"
        if [ ! -f "$RESULTS_TABLE" ]; then
            init_results_table
        fi
        run_experiment "$TARGET" "$num"
        print_results_table
        ;;
    *)
        echo "Usage: $0 [all|tp1|tp2|confound|nixl-s1..nixl-s9]"
        exit 1
        ;;
esac

echo ""
echo "=============================================="
echo "All experiments complete."
echo "Results: $RESULTS_BASE"
echo "Table:   $RESULTS_TABLE"
echo "=============================================="
