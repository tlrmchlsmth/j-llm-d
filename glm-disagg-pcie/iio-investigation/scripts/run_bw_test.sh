#!/usr/bin/env bash
# Run a single ib_read_bw or ib_write_bw test using multi_nic_ib_write_bw.py.
#
# Usage:
#   ./run_bw_test.sh <config_json> [output_file]
#
# Example:
#   ./run_bw_test.sh ../configs/read_2MB.json /tmp/bw_read_2MB.txt

set -euo pipefail
source "$(dirname "$0")/config.sh"

CONFIG_JSON="${1:?Usage: $0 <config_json> [output_file]}"
OUTPUT_FILE="${2:-/dev/stdout}"

if [[ ! -f "${BW_TEST_RUNNER}" ]]; then
    echo "ERROR: Test runner not found at ${BW_TEST_RUNNER}"
    echo "Expected: networking-debug-container/inter_node_tests/multi_nic_ib_write_bw/multi_nic_ib_write_bw.py"
    exit 1
fi

if [[ ! -f "${CONFIG_JSON}" ]]; then
    echo "ERROR: Config file not found: ${CONFIG_JSON}"
    exit 1
fi

RDMA_OP=$(python3 -c "import json; print(json.load(open('${CONFIG_JSON}'))['rdma_op'])")
MSG_SIZE=$(python3 -c "import json; print(json.load(open('${CONFIG_JSON}'))['msg_size'])")
echo "[bw_test] Running ib_${RDMA_OP}_bw with msg_size=${MSG_SIZE} from ${CONFIG_JSON}"

cd "${BW_TEST_DIR}"
uv run python "${BW_TEST_RUNNER}" "${CONFIG_JSON}" 2>&1 | tee "${OUTPUT_FILE}"
