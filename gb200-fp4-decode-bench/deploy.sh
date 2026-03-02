#!/usr/bin/env bash
set -euo pipefail

# Deployment script for gb200-fp4-decode-bench full stack
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KC="--kubeconfig $HOME/nvidia_kubeconfig.yaml"
NS="vllm"
KUBECTL_CMD="kubectl $KC -n $NS"
ROUTING="${1:-load-aware}"

echo "Deploying GB200 FP4 decode-bench full stack with $ROUTING routing..."

# Deploy base resources (decode pods, gateway, httproute, serviceaccount)
echo "1. Deploying base resources..."
$KUBECTL_CMD apply -k "$SCRIPT_DIR"

# Deploy InferencePool with specified routing
echo "2. Deploying InferencePool with $ROUTING routing..."
KUBECONFIG="$HOME/nvidia_kubeconfig.yaml" helm upgrade --install wide-ep-llm-d-infpool \
  oci://registry.k8s.io/gateway-api-inference-extension/charts/inferencepool \
  --version v1.2.0 \
  -f "$SCRIPT_DIR/inferencepool-$ROUTING.values.yaml" \
  -n "$NS"

echo ""
echo "Deployment complete!"
echo ""
echo "Gateway URL: http://wide-ep-llm-d-inference-gateway-istio.$NS.svc.cluster.local"
echo ""
echo "To run inference-perf benchmark:"
echo "  cd /Users/ecrncevi/j-llm-d"
echo "  just inference-perf 524288 1 1500 8 2048"
