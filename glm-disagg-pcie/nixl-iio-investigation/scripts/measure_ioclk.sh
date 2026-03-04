#!/usr/bin/env bash
# Measure the IIO clock frequency on Intel Sapphire Rapids.
#
# Background:
#   IIO PMU has two counter types:
#   1. Free-running counters (ioclk, bw_in/out) - fixed reference clock ~45 MHz
#   2. Programmable counters (COMP_BUF_OCC, COMP_BUF_INS, etc.) - use uncore mesh clock
#
#   The uncore/mesh clock is dynamic: ~1.6 GHz idle, ~2.4 GHz under PCIe load.
#   This means COMP_BUF_OCCUPANCY / COMP_BUF_INSERTS residence times must be
#   converted using the uncore frequency, NOT the ioclk rate.
#
# Prerequisites:
#   - SSH access to bare-metal node (root or sudo for perf/pcm)
#   - Intel PCM installed (https://github.com/intel/pcm)
#   - ib_read_bw test running to generate PCIe load (or any sustained PCIe workload)
#
# Usage:
#   1. SSH into the node
#   2. Start an ib_read_bw workload (e.g., via multi_nic_ib_write_bw.py)
#   3. Run this script while the workload is active
#
# The script runs three phases:
#   Phase 1: ioclk free-running counter (all IIO units) - identifies active stacks
#   Phase 2: Uncore frequency via PCM (idle baseline)
#   Phase 3: Uncore frequency via PCM (under PCIe load)

set -euo pipefail

DURATION="${1:-45}"
NODE="${2:-localhost}"

echo "=============================================="
echo "IIO Clock Frequency Measurement"
echo "Node: $NODE, Duration: ${DURATION}s per phase"
echo "=============================================="

run_on_node() {
    if [ "$NODE" = "localhost" ]; then
        eval "$@"
    else
        ssh "$NODE" "$@"
    fi
}

echo ""
echo "=== Phase 1: ioclk free-running counters (all IIO units) ==="
echo "This measures the fixed reference clock rate per IIO unit."
echo "Active stacks (with PCIe traffic) show ~697 MHz; idle stacks ~45 MHz."
echo ""

IOCLK_EVENTS=""
for i in $(seq 0 11); do
    IOCLK_EVENTS="${IOCLK_EVENTS}uncore_iio_free_running_${i}/ioclk/,"
    IOCLK_EVENTS="${IOCLK_EVENTS}uncore_iio_free_running_${i}/bw_out_port0/,"
done
IOCLK_EVENTS="${IOCLK_EVENTS%,}"

echo "Running: sudo perf stat -a -e <ioclk + bw_out_port0 for IIO 0-11> sleep ${DURATION}"
echo "(start your ib_read_bw workload now if not already running)"
echo ""

run_on_node "sudo perf stat -a -e '${IOCLK_EVENTS}' sleep ${DURATION}" 2>&1 | tee /tmp/ioclk_phase1.txt

echo ""
echo "=== Phase 2: Uncore/mesh frequency (idle baseline) ==="
echo "Stop all PCIe workloads, then measure idle uncore frequency."
echo ""

read -p "Press Enter when PCIe workloads are stopped (idle)..."
echo "Running: sudo pcm -r -- sleep 10"

run_on_node "sudo pcm -r -- sleep 10" 2>&1 | tee /tmp/ioclk_phase2_idle.txt

echo ""
echo "=== Phase 3: Uncore/mesh frequency (under PCIe load) ==="
echo "Start your ib_read_bw workload, then measure loaded uncore frequency."
echo ""

read -p "Press Enter when PCIe workload is running..."
echo "Running: sudo pcm -r -- sleep 10"

run_on_node "sudo pcm -r -- sleep 10" 2>&1 | tee /tmp/ioclk_phase3_load.txt

echo ""
echo "=============================================="
echo "Analysis"
echo "=============================================="
echo ""
echo "Look for these values in the PCM output:"
echo "  - UncFREQ (GHz) under 'idle' vs 'load' conditions"
echo "  - Expected: ~1.6 GHz idle, ~2.4 GHz under PCIe load"
echo ""
echo "To convert IIO counter cycles to time:"
echo "  residence_us = occupancy_cycles / inserts / (uncore_freq_ghz * 1000)"
echo ""
echo "Example: 2,479 cycles / 2.4 GHz = 1.03 us"
echo ""
echo "Results saved to:"
echo "  /tmp/ioclk_phase1.txt  (free-running ioclk per IIO unit)"
echo "  /tmp/ioclk_phase2_idle.txt  (PCM idle uncore frequency)"
echo "  /tmp/ioclk_phase3_load.txt  (PCM loaded uncore frequency)"
