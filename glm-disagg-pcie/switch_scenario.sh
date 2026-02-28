#!/bin/bash

# Switch NIC scenario for P/D benchmarking without losing nodes.
# Sets UCX_NET_DEVICES on both prefill and decode deployments,
# triggering a Recreate rollout (old pod dies → new pod starts on same node).
#
# Usage: ./switch_scenario.sh <1|2|3>
#
# Scenarios (NIC pairs used for KV cache transfer):
#   1: mlx5_10, mlx5_11  (PCI 0c:00.1, 2a:00.1 — NUMA 0, pair 1)
#   2: mlx5_12, mlx5_13  (PCI 41:00.1, 58:00.1 — NUMA 0, pair 2)
#   3: mlx5_16, mlx5_17  (PCI bd:00.1, d5:00.1 — NUMA 1, pair 1)
#
# GPUs are always GPU 0 and GPU 1 (11:00.0, 2f:00.0) — unchanged across scenarios.

set -euo pipefail

if [ $# -lt 1 ]; then
    echo "Usage: $0 <1|2|3>"
    exit 1
fi

SCENARIO="$1"
NAMESPACE="raj-network-debug"

case "$SCENARIO" in
    1) NET_DEVICES="mlx5_10:1,mlx5_11:1" ;;
    2) NET_DEVICES="mlx5_12:1,mlx5_13:1" ;;
    3) NET_DEVICES="mlx5_16:1,mlx5_17:1" ;;
    *) echo "ERROR: Unknown scenario '$SCENARIO'. Use 1, 2, or 3."; exit 1 ;;
esac

echo "=============================================="
echo "Switching to Scenario $SCENARIO"
echo "  UCX_NET_DEVICES=$NET_DEVICES"
echo "=============================================="

DECODE_DEPLOY="ms-glm-disagg-llm-d-modelservice-decode"
PREFILL_DEPLOY="ms-glm-disagg-llm-d-modelservice-prefill"

# Record current nodes
DECODE_NODE=$(kubectl get pods -n "$NAMESPACE" -l llm-d.ai/role=decode \
    -o jsonpath='{.items[0].spec.nodeName}')
PREFILL_NODE=$(kubectl get pods -n "$NAMESPACE" -l llm-d.ai/role=prefill \
    -o jsonpath='{.items[0].spec.nodeName}')

echo ""
echo "Current nodes:"
echo "  Decode:  $DECODE_NODE"
echo "  Prefill: $PREFILL_NODE"

# Switch to Recreate strategy to avoid deadlock
# (RollingUpdate tries to start new pod first, but all 8 GPUs are held by old pod)
echo ""
echo "Patching deployment strategy to Recreate..."
kubectl patch deployment "$DECODE_DEPLOY" -n "$NAMESPACE" \
    -p '{"spec":{"strategy":{"type":"Recreate","rollingUpdate":null}}}' --type=strategic
kubectl patch deployment "$PREFILL_DEPLOY" -n "$NAMESPACE" \
    -p '{"spec":{"strategy":{"type":"Recreate","rollingUpdate":null}}}' --type=strategic

# Set UCX_NET_DEVICES on the vllm container (triggers rollout)
echo ""
echo "Setting UCX_NET_DEVICES=$NET_DEVICES on both deployments..."
kubectl set env deployment/"$DECODE_DEPLOY" -n "$NAMESPACE" -c vllm \
    UCX_NET_DEVICES="$NET_DEVICES"
kubectl set env deployment/"$PREFILL_DEPLOY" -n "$NAMESPACE" -c vllm \
    UCX_NET_DEVICES="$NET_DEVICES"

# Wait for rollout
echo ""
echo "Waiting for decode rollout..."
kubectl rollout status deployment/"$DECODE_DEPLOY" -n "$NAMESPACE" --timeout=900s

echo "Waiting for prefill rollout..."
kubectl rollout status deployment/"$PREFILL_DEPLOY" -n "$NAMESPACE" --timeout=900s

# Verify
echo ""
echo "=============================================="
echo "Verification"
echo "=============================================="

NEW_DECODE_POD=$(kubectl get pods -n "$NAMESPACE" -l llm-d.ai/role=decode \
    -o jsonpath='{.items[0].metadata.name}')
NEW_PREFILL_POD=$(kubectl get pods -n "$NAMESPACE" -l llm-d.ai/role=prefill \
    -o jsonpath='{.items[0].metadata.name}')
NEW_DECODE_NODE=$(kubectl get pod -n "$NAMESPACE" "$NEW_DECODE_POD" \
    -o jsonpath='{.spec.nodeName}')
NEW_PREFILL_NODE=$(kubectl get pod -n "$NAMESPACE" "$NEW_PREFILL_POD" \
    -o jsonpath='{.spec.nodeName}')

echo "Decode:  $NEW_DECODE_POD on $NEW_DECODE_NODE"
echo "Prefill: $NEW_PREFILL_POD on $NEW_PREFILL_NODE"

if [ "$DECODE_NODE" != "$NEW_DECODE_NODE" ] || [ "$PREFILL_NODE" != "$NEW_PREFILL_NODE" ]; then
    echo ""
    echo "WARNING: Pods landed on different nodes than before!"
    echo "  Decode:  $DECODE_NODE -> $NEW_DECODE_NODE"
    echo "  Prefill: $PREFILL_NODE -> $NEW_PREFILL_NODE"
fi

echo ""
echo "UCX_NET_DEVICES on decode:"
kubectl exec -n "$NAMESPACE" "$NEW_DECODE_POD" -c vllm -- env | grep UCX_NET_DEVICES || echo "  (not set)"
echo "UCX_NET_DEVICES on prefill:"
kubectl exec -n "$NAMESPACE" "$NEW_PREFILL_POD" -c vllm -- env | grep UCX_NET_DEVICES || echo "  (not set)"

echo ""
echo "Scenario $SCENARIO active. Pods ready for benchmarking."
