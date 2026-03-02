#!/usr/bin/env bash
set -euo pipefail

# Cleanup script for gb200-fp4-decode-bench deployment
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KC="--kubeconfig $HOME/nvidia_kubeconfig.yaml"
NS="vllm"
KUBECTL_CMD="kubectl $KC -n $NS"

echo "Cleaning up GB200 FP4 decode-bench deployment..."

# Delete InferencePool
echo "1. Deleting InferencePool..."
helm uninstall wide-ep-llm-d-infpool -n "$NS" 2>/dev/null || echo "  InferencePool not found"

# Delete base resources
echo "2. Deleting base resources..."
$KUBECTL_CMD delete -k "$SCRIPT_DIR" --ignore-not-found=true

# Clean up any remaining inference-perf jobs
echo "3. Cleaning up benchmark jobs..."
$KUBECTL_CMD delete job inference-perf --ignore-not-found=true
$KUBECTL_CMD delete configmap inference-perf-config --ignore-not-found=true

echo ""
echo "Cleanup complete!"
