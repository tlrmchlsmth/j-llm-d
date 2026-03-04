#!/usr/bin/env bash
# Shared configuration for IIO investigation experiments.
# Source this file from other scripts: source "$(dirname "$0")/config.sh"

set -euo pipefail

# --- Node Configuration ---
# Responder node (serves data for RDMA READ / receives data for RDMA WRITE)
RESPONDER_IP="10.0.67.106"
RESPONDER_TMUX="node2"

# Requester node (initiates RDMA READ / sends data for RDMA WRITE)
REQUESTER_IP="10.0.74.185"
REQUESTER_TMUX="node7"

# Kubernetes
K8S_NAMESPACE="raj-network-debug"
RESPONDER_POD="test-nic-pcie-${RESPONDER_IP}"
REQUESTER_POD="test-nic-pcie-${REQUESTER_IP}"

# --- IIO Stack Mapping (Socket 1 / NUMA 1, both nodes identical) ---
# GPU 0 (8b:00.0) + mlx5_14 (86:00.1) => IIO5, root port bus 0x81
# GPU 1 (aa:00.0) + mlx5_15 (a5:00.1) => IIO11, root port bus 0xa0
# GPU 2 (c2:00.0) + mlx5_16 (bd:00.1) => IIO2, root port bus 0xb8
# GPU 3 (da:00.0) + mlx5_17 (d5:00.1) => IIO7, root port bus 0xd0
#
# Test pairs use GPU 0 with mlx5_16 and GPU 1 with mlx5_17 (cross-IIO).
# Data path: NIC (IIO2/IIO7) -> mesh -> GPU (IIO5/IIO11)
GPU_IIO=5       # IIO stack hosting GPU 0 (target of cross-IIO traffic)
NIC_IIO=2       # IIO stack hosting mlx5_16 (source of cross-IIO traffic)

# --- Perf Event Specifications ---
# Common options for all IIO events
IIO_OPTS="ch_mask=0xff,fc_mask=0x07"

# 6-event IIO set (no multiplexing with 6 events across 2 IIO units)
PERF_EVENTS_IIO=$(cat <<EOF
uncore_iio_${GPU_IIO}/event=0xd5,umask=0xff,${IIO_OPTS}/,\
uncore_iio_${GPU_IIO}/event=0xc2,umask=0x04,${IIO_OPTS}/,\
uncore_iio_${NIC_IIO}/event=0x86,umask=0x08,${IIO_OPTS}/,\
uncore_iio_${NIC_IIO}/event=0x8e,umask=0x20,${IIO_OPTS}/,\
uncore_iio_${GPU_IIO}/event=0xd0,umask=0x08,${IIO_OPTS}/,\
uncore_iio_${GPU_IIO}/event=0xd1,umask=0x08,${IIO_OPTS}/
EOF
)

# 12-event IIO+CHA set (will multiplex on some events)
PERF_EVENTS_IIO_CHA=$(cat <<EOF
uncore_cha/event=0x36,umask=0xC000FF04/,\
uncore_cha/event=0x35,umask=0xC000FF04/,\
uncore_cha/event=0x36,umask=0x4000/,\
uncore_cha/event=0x35,umask=0x4000/,\
uncore_cha/event=0x58,umask=0x3f/,\
uncore_iio_${GPU_IIO}/event=0xd5,umask=0xff,${IIO_OPTS}/,\
uncore_iio_${GPU_IIO}/event=0xc2,umask=0x04,${IIO_OPTS}/,\
uncore_iio_${GPU_IIO}/event=0xd0,umask=0x08,${IIO_OPTS}/,\
uncore_iio_${GPU_IIO}/event=0xd1,umask=0x08,${IIO_OPTS}/,\
uncore_iio_${GPU_IIO}/event=0x83,umask=0x80,${IIO_OPTS}/,\
uncore_iio_${NIC_IIO}/event=0x86,umask=0x08,${IIO_OPTS}/,\
uncore_iio_${NIC_IIO}/event=0x8e,umask=0x20,${IIO_OPTS}/
EOF
)

# --- Paths ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INVESTIGATION_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIGS_DIR="${INVESTIGATION_DIR}/configs"

# Path to the bandwidth test runner
BW_TEST_DIR="${INVESTIGATION_DIR}/../../networking-debug-container/inter_node_tests/multi_nic_ib_write_bw"
BW_TEST_RUNNER="${BW_TEST_DIR}/multi_nic_ib_write_bw.py"

# --- Timing ---
PERF_DURATION=50        # seconds for perf stat sleep
WORKLOAD_STARTUP=3      # seconds to wait after starting perf before launching workload
WORKLOAD_DURATION=30    # ib_read_bw / ib_write_bw --duration value (baked into JSON configs)
