#!/bin/bash

# Switch NIC scenario for P/D benchmarking without losing nodes.
# Sets UCX_NET_DEVICES (and optionally UCX_MAX_RMA_RAILS, UCX_RC_MAX_RD_ATOMIC)
# on both prefill and decode deployments, triggering a Recreate rollout
# (old pod dies → new pod starts on same node).
#
# Usage: ./switch_scenario.sh <1|2|3|2r2|3r2|nixl-s1..nixl-s8>
#        UCX_RC_MAX_RD_ATOMIC=16 ./switch_scenario.sh 2r2
#
# Scenarios (NIC pairs used for KV cache transfer):
#   1:   mlx5_10, mlx5_11  (PCI 0c:00.1, 2a:00.1)  UCX_MAX_RMA_RAILS=1
#   2:   mlx5_12, mlx5_13  (PCI 41:00.1, 58:00.1)  UCX_MAX_RMA_RAILS=1
#   3:   mlx5_16, mlx5_17  (PCI bd:00.1, d5:00.1)  UCX_MAX_RMA_RAILS=1
#   2r2: mlx5_12, mlx5_13  (PCI 41:00.1, 58:00.1)  UCX_MAX_RMA_RAILS=2
#   3r2: mlx5_16, mlx5_17  (PCI bd:00.1, d5:00.1)  UCX_MAX_RMA_RAILS=2
#
# NIXL isolation experiments (require matching TP deploy):
#   nixl-s1: mlx5_10             rails=1  (TP=1, same-IIO baseline)
#   nixl-s2: mlx5_12             rails=1  (TP=1, cross-IIO)
#   nixl-s3: mlx5_10, mlx5_11   rails=1  (TP=2, same-IIO baseline)
#   nixl-s4: mlx5_10, mlx5_11   rails=2  (TP=2, mixed-IIO -- each GPU crosses to other's NIC)
#   nixl-s5: mlx5_10, mlx5_12   rails=2  (TP=1, mixed IIO, rails overhead)
#   nixl-s6: mlx5_12, mlx5_13   rails=2  (TP=2, cross-IIO, rails overhead)
#   nixl-s7: ASYMMETRIC -- decode=mlx5_10,mlx5_11 (same-IIO) / prefill=mlx5_12,mlx5_13 (cross-IIO)
#            rails=2  (TP=2, proves request-side bottleneck is decode-side IIO latency)
#   nixl-s8: CUDA_VISIBLE_DEVICES=0,3, mlx5_11,mlx5_12, rails=1
#            (TP=2 on non-adjacent GPUs, cross-IIO, no rails splitting)
#            GPU0(IIO0)→mlx5_11(IIO1), GPU3(IIO3)→mlx5_12(IIO2)
#
# In scenarios 2r2/3r2, UCX_MAX_RMA_RAILS=2 forces each rank to use both
# NICs (2 RMA lanes), working around UCX's greedy per-endpoint device
# selection that otherwise assigns both ranks to the same NIC.
#
# GPUs are GPU 0 and GPU 1 (11:00.0, 2f:00.0) by default.
# nixl-s8 overrides to GPU 0 and GPU 3 (11:00.0, 5d:00.0) via CUDA_VISIBLE_DEVICES.

set -euo pipefail

if [ $# -lt 1 ]; then
    echo "Usage: $0 <1|2|3|2r2|3r2|nixl-s1..nixl-s8>"
    exit 1
fi

SCENARIO="$1"
NAMESPACE="raj-network-debug"
RMA_RAILS="1"
RC_MAX_RD_ATOMIC="${UCX_RC_MAX_RD_ATOMIC:-}"
NET_DEVICES=""
DECODE_NET_DEVICES=""
PREFILL_NET_DEVICES=""
CUDA_VIS_DEVICES=""

case "$SCENARIO" in
    1)   NET_DEVICES="mlx5_10:1,mlx5_11:1" ;;
    2)   NET_DEVICES="mlx5_12:1,mlx5_13:1" ;;
    3)   NET_DEVICES="mlx5_16:1,mlx5_17:1" ;;
    2r2) NET_DEVICES="mlx5_12:1,mlx5_13:1"; RMA_RAILS="2" ;;
    3r2) NET_DEVICES="mlx5_16:1,mlx5_17:1"; RMA_RAILS="2" ;;
    nixl-s1) NET_DEVICES="mlx5_10:1";           RMA_RAILS="1" ;;
    nixl-s2) NET_DEVICES="mlx5_12:1";           RMA_RAILS="1" ;;
    nixl-s3) NET_DEVICES="mlx5_10:1,mlx5_11:1"; RMA_RAILS="1" ;;
    nixl-s4) NET_DEVICES="mlx5_10:1,mlx5_11:1"; RMA_RAILS="2" ;;
    nixl-s5) NET_DEVICES="mlx5_10:1,mlx5_12:1"; RMA_RAILS="2" ;;
    nixl-s6) NET_DEVICES="mlx5_12:1,mlx5_13:1"; RMA_RAILS="2" ;;
    nixl-s7) DECODE_NET_DEVICES="mlx5_10:1,mlx5_11:1"
             PREFILL_NET_DEVICES="mlx5_12:1,mlx5_13:1"
             RMA_RAILS="2" ;;
    nixl-s8) NET_DEVICES="mlx5_11:1,mlx5_12:1"
             RMA_RAILS="1"
             CUDA_VIS_DEVICES="0,3" ;;
    *)   echo "ERROR: Unknown scenario '$SCENARIO'. Use 1, 2, 3, 2r2, 3r2, or nixl-s1..nixl-s8."; exit 1 ;;
esac

# For asymmetric scenarios, resolve per-deployment NET_DEVICES.
# Symmetric scenarios set NET_DEVICES; asymmetric ones set DECODE/PREFILL_NET_DEVICES directly.
DECODE_NET_DEVICES="${DECODE_NET_DEVICES:-$NET_DEVICES}"
PREFILL_NET_DEVICES="${PREFILL_NET_DEVICES:-$NET_DEVICES}"

echo "=============================================="
echo "Switching to Scenario $SCENARIO"
if [ "$DECODE_NET_DEVICES" = "$PREFILL_NET_DEVICES" ]; then
    echo "  UCX_NET_DEVICES=$DECODE_NET_DEVICES (both)"
else
    echo "  Decode  UCX_NET_DEVICES=$DECODE_NET_DEVICES"
    echo "  Prefill UCX_NET_DEVICES=$PREFILL_NET_DEVICES"
fi
echo "  UCX_MAX_RMA_RAILS=$RMA_RAILS"
if [ -n "$RC_MAX_RD_ATOMIC" ]; then
    echo "  UCX_RC_MAX_RD_ATOMIC=$RC_MAX_RD_ATOMIC"
fi
if [ -n "$CUDA_VIS_DEVICES" ]; then
    echo "  CUDA_VISIBLE_DEVICES=$CUDA_VIS_DEVICES"
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
fi
CUDA_EXTRA=""
if [ -n "$CUDA_VIS_DEVICES" ]; then
    CUDA_EXTRA="CUDA_VISIBLE_DEVICES=$CUDA_VIS_DEVICES"
else
    CUDA_EXTRA="CUDA_VISIBLE_DEVICES-"
fi
echo "Setting UCX env on decode (NET_DEVICES=$DECODE_NET_DEVICES) and prefill (NET_DEVICES=$PREFILL_NET_DEVICES)..."
kubectl set env deployment/"$DECODE_DEPLOY" -n "$NAMESPACE" -c vllm \
    UCX_NET_DEVICES="$DECODE_NET_DEVICES" UCX_MAX_RMA_RAILS="$RMA_RAILS" $MRA_EXTRA $CUDA_EXTRA
kubectl set env deployment/"$PREFILL_DEPLOY" -n "$NAMESPACE" -c vllm \
    UCX_NET_DEVICES="$PREFILL_NET_DEVICES" UCX_MAX_RMA_RAILS="$RMA_RAILS" $MRA_EXTRA $CUDA_EXTRA

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
kubectl exec -n "$NAMESPACE" "$NEW_DECODE_POD" -c vllm -- env | grep -E "UCX_(NET_DEVICES|MAX_RMA_RAILS|RC_MAX_RD_ATOMIC)|CUDA_VISIBLE" || echo "  (not set)"
echo "UCX env on prefill:"
kubectl exec -n "$NAMESPACE" "$NEW_PREFILL_POD" -c vllm -- env | grep -E "UCX_(NET_DEVICES|MAX_RMA_RAILS|RC_MAX_RD_ATOMIC)|CUDA_VISIBLE" || echo "  (not set)"

echo ""
echo "Scenario $SCENARIO active. Pods ready for benchmarking."
