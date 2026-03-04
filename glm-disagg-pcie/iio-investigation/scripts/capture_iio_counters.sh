#!/usr/bin/env bash
# Capture IIO/CHA perf stat counters on a remote node via a tmux session.
#
# The target node must have:
#   - A tmux session already running with SSH access
#   - sudo perf available
#
# Usage:
#   ./capture_iio_counters.sh <tmux_session> <event_spec> <duration_sec> <output_file>
#
# Example:
#   ./capture_iio_counters.sh node2 "$PERF_EVENTS_IIO" 50 /tmp/perf_read_2MB.txt

set -euo pipefail

TMUX_SESSION="${1:?Usage: $0 <tmux_session> <event_spec> <duration_sec> <output_file>}"
EVENT_SPEC="${2:?Missing event spec}"
DURATION="${3:?Missing duration}"
OUTPUT_FILE="${4:?Missing output file path}"

echo "[capture] Starting perf stat on tmux:${TMUX_SESSION} for ${DURATION}s -> ${OUTPUT_FILE}"

# Send the perf stat command to the tmux session.
# Uses -a (system-wide) to capture uncore events regardless of CPU affinity.
tmux send-keys -t "${TMUX_SESSION}" \
    "sudo perf stat -a -e \"${EVENT_SPEC}\" sleep ${DURATION} 2>&1 | tee ${OUTPUT_FILE}" Enter

echo "[capture] perf stat launched (will run for ${DURATION}s)"
