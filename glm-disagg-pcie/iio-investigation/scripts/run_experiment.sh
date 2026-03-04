#!/usr/bin/env bash
# Main orchestrator for the IIO investigation experiments.
#
# Runs all 4 experiment phases sequentially, capturing perf stat IIO/CHA
# counters on the appropriate node while bandwidth tests execute.
#
# Prerequisites:
#   - tmux sessions "node2" and "node7" are active with SSH to the physical nodes
#   - sudo perf is available on both nodes
#   - Kubernetes pods (test-nic-pcie-*) are deployed in the configured namespace
#   - uv and multi_nic_ib_write_bw.py are available on the operator host
#
# Usage:
#   ./run_experiment.sh [results_dir]
#
# If results_dir is not specified, creates a timestamped directory under
# iio-investigation/results/.

set -euo pipefail
source "$(dirname "$0")/config.sh"

CAPTURE="$(dirname "$0")/capture_iio_counters.sh"
BW_TEST="$(dirname "$0")/run_bw_test.sh"

RESULTS_DIR="${1:-${INVESTIGATION_DIR}/results/$(date +%Y%m%d_%H%M%S)}"
mkdir -p "${RESULTS_DIR}"

echo "============================================="
echo " IIO Investigation — Full Experiment Suite"
echo " Results: ${RESULTS_DIR}"
echo "============================================="
echo ""

wait_for_perf() {
    local session="$1"
    local duration="$2"
    local total_wait=$((duration + 5))
    echo "[wait] Waiting ${total_wait}s for perf stat on ${session} to complete..."
    sleep "${total_wait}"
}

run_phase() {
    local phase_name="$1"
    local perf_session="$2"
    local perf_events="$3"
    local config_json="$4"
    local perf_outfile="$5"
    local bw_outfile="$6"

    echo "---------------------------------------------"
    echo " Phase: ${phase_name}"
    echo "   perf on: ${perf_session}"
    echo "   workload: $(basename "${config_json}")"
    echo "---------------------------------------------"

    # 1. Start perf stat
    bash "${CAPTURE}" "${perf_session}" "${perf_events}" "${PERF_DURATION}" "${perf_outfile}"

    # 2. Wait for perf to initialize
    sleep "${WORKLOAD_STARTUP}"

    # 3. Launch bandwidth test (blocks until complete, ~37-47s total)
    bash "${BW_TEST}" "${config_json}" "${RESULTS_DIR}/${bw_outfile}"

    # 4. Wait for perf stat to finish
    wait_for_perf "${perf_session}" "${PERF_DURATION}"

    echo "[phase] ${phase_name} complete."
    echo ""
}

# =============================================
# Experiment 1: 2MB RDMA READ — Baseline
# perf on responder (node2), monitors GPU IIO5 + NIC IIO2
# =============================================
run_phase \
    "Exp1: 2MB RDMA READ (responder IIO)" \
    "${RESPONDER_TMUX}" \
    "${PERF_EVENTS_IIO}" \
    "${CONFIGS_DIR}/read_2MB.json" \
    "~/perf_exp1_read_2MB.txt" \
    "bw_exp1_read_2MB.txt"

# =============================================
# Experiment 2: 16KB RDMA READ — Small messages
# perf on responder (node2), monitors GPU IIO5 + NIC IIO2
# =============================================
run_phase \
    "Exp2: 16KB RDMA READ (responder IIO)" \
    "${RESPONDER_TMUX}" \
    "${PERF_EVENTS_IIO}" \
    "${CONFIGS_DIR}/read_16KB.json" \
    "~/perf_exp2_read_16KB.txt" \
    "bw_exp2_read_16KB.txt"

# =============================================
# Experiment 3a: 2MB RDMA READ — IIO + CHA mesh (12 events)
# perf on responder (node2), includes CHA TOR counters
# =============================================
run_phase \
    "Exp3a: 2MB RDMA READ (IIO + CHA mesh)" \
    "${RESPONDER_TMUX}" \
    "${PERF_EVENTS_IIO_CHA}" \
    "${CONFIGS_DIR}/read_2MB.json" \
    "~/perf_exp3a_read_2MB_cha.txt" \
    "bw_exp3a_read_2MB.txt"

# =============================================
# Experiment 3b: 16KB RDMA READ — IIO + CHA mesh (12 events)
# perf on responder (node2), includes CHA TOR counters
# =============================================
run_phase \
    "Exp3b: 16KB RDMA READ (IIO + CHA mesh)" \
    "${RESPONDER_TMUX}" \
    "${PERF_EVENTS_IIO_CHA}" \
    "${CONFIGS_DIR}/read_16KB.json" \
    "~/perf_exp3b_read_16KB_cha.txt" \
    "bw_exp3b_read_16KB.txt"

# =============================================
# Experiment 4a: 2MB RDMA WRITE — Receiver-side (posted)
# perf on receiver/responder (node2) — expects idle counters
# =============================================
run_phase \
    "Exp4a-1: 2MB RDMA WRITE (receiver IIO, expect idle)" \
    "${RESPONDER_TMUX}" \
    "${PERF_EVENTS_IIO}" \
    "${CONFIGS_DIR}/write_2MB.json" \
    "~/perf_exp4a1_write_2MB_receiver.txt" \
    "bw_exp4a1_write_2MB.txt"

# =============================================
# Experiment 4a: 16KB RDMA WRITE — Receiver-side (posted)
# perf on receiver/responder (node2) — expects idle counters
# =============================================
run_phase \
    "Exp4a-2: 16KB RDMA WRITE (receiver IIO, expect idle)" \
    "${RESPONDER_TMUX}" \
    "${PERF_EVENTS_IIO}" \
    "${CONFIGS_DIR}/write_16KB.json" \
    "~/perf_exp4a2_write_16KB_receiver.txt" \
    "bw_exp4a2_write_16KB.txt"

# =============================================
# Experiment 4b: 16KB RDMA WRITE — Sender-side (non-posted DMA reads)
# perf on sender/requester (node7) — expects high COMP_BUF activity
# =============================================
run_phase \
    "Exp4b-1: 16KB RDMA WRITE (sender IIO)" \
    "${REQUESTER_TMUX}" \
    "${PERF_EVENTS_IIO}" \
    "${CONFIGS_DIR}/write_16KB.json" \
    "~/perf_exp4b1_write_16KB_sender.txt" \
    "bw_exp4b1_write_16KB.txt"

# =============================================
# Experiment 4b: 16KB RDMA READ — Requester-side (posted writes to GPU)
# perf on requester (node7) — expects idle counters (control)
# =============================================
run_phase \
    "Exp4b-2: 16KB RDMA READ (requester IIO, expect idle)" \
    "${REQUESTER_TMUX}" \
    "${PERF_EVENTS_IIO}" \
    "${CONFIGS_DIR}/read_16KB.json" \
    "~/perf_exp4b2_read_16KB_requester.txt" \
    "bw_exp4b2_read_16KB.txt"

# =============================================
# Copy perf output files from remote nodes
# =============================================
echo "============================================="
echo " Collecting perf stat output files"
echo "============================================="

for f in perf_exp1_read_2MB.txt perf_exp2_read_16KB.txt \
         perf_exp3a_read_2MB_cha.txt perf_exp3b_read_16KB_cha.txt \
         perf_exp4a1_write_2MB_receiver.txt perf_exp4a2_write_16KB_receiver.txt; do
    echo "[collect] Copying ${f} from ${RESPONDER_TMUX}..."
    scp "${RESPONDER_TMUX}:~/${f}" "${RESULTS_DIR}/" 2>/dev/null || \
        echo "  WARNING: Failed to copy ${f} from ${RESPONDER_TMUX}"
done

for f in perf_exp4b1_write_16KB_sender.txt perf_exp4b2_read_16KB_requester.txt; do
    echo "[collect] Copying ${f} from ${REQUESTER_TMUX}..."
    scp "${REQUESTER_TMUX}:~/${f}" "${RESULTS_DIR}/" 2>/dev/null || \
        echo "  WARNING: Failed to copy ${f} from ${REQUESTER_TMUX}"
done

echo ""
echo "============================================="
echo " All experiments complete!"
echo " Results saved to: ${RESULTS_DIR}"
echo "============================================="
echo ""
echo "Files:"
ls -la "${RESULTS_DIR}/"
