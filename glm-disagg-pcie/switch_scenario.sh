#!/bin/bash

# Switch NIC scenario for P/D benchmarking without losing nodes.
# Sets UCX_NET_DEVICES (and optionally UCX_MAX_RMA_RAILS, UCX_RC_MAX_RD_ATOMIC)
# on both prefill and decode deployments, triggering a Recreate rollout
# (old pod dies → new pod starts on same node).
#
# Usage: ./switch_scenario.sh <1|2|3|2r2|3r2>
#        UCX_RC_MAX_RD_ATOMIC=16 ./switch_scenario.sh 2r2
#
# Scenarios (NIC pairs used for KV cache transfer):
#   1:   mlx5_10, mlx5_11  (PCI 0c:00.1, 2a:00.1)  UCX_MAX_RMA_RAILS=1
#   2:   mlx5_12, mlx5_13  (PCI 41:00.1, 58:00.1)  UCX_MAX_RMA_RAILS=1
#   3:   mlx5_16, mlx5_17  (PCI bd:00.1, d5:00.1)  UCX_MAX_RMA_RAILS=1
#   2r2: mlx5_12, mlx5_13  (PCI 41:00.1, 58:00.1)  UCX_MAX_RMA_RAILS=2
#   3r2: mlx5_16, mlx5_17  (PCI bd:00.1, d5:00.1)  UCX_MAX_RMA_RAILS=2
#
# In scenarios 2r2/3r2, UCX_MAX_RMA_RAILS=2 forces each rank to use both
# NICs (2 RMA lanes), working around UCX's greedy per-endpoint device
# selection that otherwise assigns both ranks to the same NIC.
#
# GPUs are always GPU 0 and GPU 1 (11:00.0, 2f:00.0) — unchanged across scenarios.

set -euo pipefail

if [ $# -lt 1 ]; then
    echo "Usage: $0 <1|2|3|2r2|3r2>"
    exit 1
fi

SCENARIO="$1"
NAMESPACE="raj-network-debug"
RMA_RAILS="1"
RC_MAX_RD_ATOMIC="${UCX_RC_MAX_RD_ATOMIC:-}"

case "$SCENARIO" in
    1)   NET_DEVICES="mlx5_10:1,mlx5_11:1" ;;
    2)   NET_DEVICES="mlx5_12:1,mlx5_13:1" ;;
    3)   NET_DEVICES="mlx5_16:1,mlx5_17:1" ;;
    2r2) NET_DEVICES="mlx5_12:1,mlx5_13:1"; RMA_RAILS="2" ;;
    3r2) NET_DEVICES="mlx5_16:1,mlx5_17:1"; RMA_RAILS="2" ;;
    *)   echo "ERROR: Unknown scenario '$SCENARIO'. Use 1, 2, 3, 2r2, or 3r2."; exit 1 ;;
esac

echo "=============================================="
echo "Switching to Scenario $SCENARIO"
echo "  UCX_NET_DEVICES=$NET_DEVICES"
echo "  UCX_MAX_RMA_RAILS=$RMA_RAILS"
if [ -n "$RC_MAX_RD_ATOMIC" ]; then
    echo "  UCX_RC_MAX_RD_ATOMIC=$RC_MAX_RD_ATOMIC"
fi
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

# Set UCX env vars on the vllm container (triggers rollout)
echo ""
MRA_EXTRA=""
if [ -n "$RC_MAX_RD_ATOMIC" ]; then
    MRA_EXTRA="UCX_RC_MAX_RD_ATOMIC=$RC_MAX_RD_ATOMIC"
    echo "Setting UCX_NET_DEVICES=$NET_DEVICES UCX_MAX_RMA_RAILS=$RMA_RAILS UCX_RC_MAX_RD_ATOMIC=$RC_MAX_RD_ATOMIC on both deployments..."
else
    echo "Setting UCX_NET_DEVICES=$NET_DEVICES UCX_MAX_RMA_RAILS=$RMA_RAILS on both deployments..."
fi
kubectl set env deployment/"$DECODE_DEPLOY" -n "$NAMESPACE" -c vllm \
    UCX_NET_DEVICES="$NET_DEVICES" UCX_MAX_RMA_RAILS="$RMA_RAILS" $MRA_EXTRA
kubectl set env deployment/"$PREFILL_DEPLOY" -n "$NAMESPACE" -c vllm \
    UCX_NET_DEVICES="$NET_DEVICES" UCX_MAX_RMA_RAILS="$RMA_RAILS" $MRA_EXTRA

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
echo "UCX env on decode:"
kubectl exec -n "$NAMESPACE" "$NEW_DECODE_POD" -c vllm -- env | grep -E "UCX_(NET_DEVICES|MAX_RMA_RAILS|RC_MAX_RD_ATOMIC)" || echo "  (not set)"
echo "UCX env on prefill:"
kubectl exec -n "$NAMESPACE" "$NEW_PREFILL_POD" -c vllm -- env | grep -E "UCX_(NET_DEVICES|MAX_RMA_RAILS|RC_MAX_RD_ATOMIC)" || echo "  (not set)"

echo ""
echo "Scenario $SCENARIO active. Pods ready for benchmarking."
