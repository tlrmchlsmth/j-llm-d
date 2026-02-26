#!/usr/bin/env bash
# Check InfiniBand port health on all GPU nodes via kubectl debug.
# Runs checks in parallel, outputs a summary table, cleans up debug pods.
set -euo pipefail

NAMESPACE="${NAMESPACE:-vllm}"
NODES=$(kubectl get nodes -o json | jq -r '.items[] | select(.status.capacity["nvidia.com/gpu"] != null) | .metadata.name')
TMPDIR=$(mktemp -d)

cleanup() {
  rm -rf "$TMPDIR"
  kubectl -n "$NAMESPACE" delete pods --field-selector=status.phase==Succeeded -l 'kubernetes.io/metadata.name' --ignore-not-found=true 2>/dev/null | grep node-debugger || true
  kubectl -n "$NAMESPACE" delete pods --field-selector=status.phase==Failed -l 'kubernetes.io/metadata.name' --ignore-not-found=true 2>/dev/null | grep node-debugger || true
}
trap cleanup EXIT

NODE_COUNT=$(echo "$NODES" | wc -l | tr -d ' ')
echo "Checking IB ports on $NODE_COUNT GPU nodes..."

# Launch debug pods on all nodes in parallel
for NODE in $NODES; do
  kubectl debug "node/$NODE" -n "$NAMESPACE" -q --image=quay.io/tms/llm-d-cuda-dev:gb200_working-6a3214a31 -- sh -c '
    for dev in /host/sys/class/infiniband/mlx5_*; do
      name=$(basename $dev)
      link=$(cat $dev/ports/1/link_layer 2>/dev/null)
      state=$(cat $dev/ports/1/state 2>/dev/null)
      [ "$link" = "InfiniBand" ] && printf "%s %s\n" "$name" "$state"
    done
  ' &>/dev/null &
done
wait

# Collect results from pod logs
for NODE in $NODES; do
  POD=$(kubectl -n "$NAMESPACE" get pods -o name 2>/dev/null | grep "node-debugger-${NODE}" | head -1)
  if [ -n "$POD" ]; then
    kubectl -n "$NAMESPACE" logs "$POD" > "$TMPDIR/$NODE" 2>/dev/null || true
  fi
done

# Header
printf "%-16s  %-10s  %-10s  %-10s  %-10s\n" "NODE" "mlx5_0" "mlx5_1" "mlx5_3" "mlx5_4"
printf "%-16s  %-10s  %-10s  %-10s  %-10s\n" "────────────────" "──────────" "──────────" "──────────" "──────────"

# Parse results per node
for NODE in $(echo "$NODES" | sort); do
  [ -s "$TMPDIR/$NODE" ] || continue
  get() { grep "$1" "$TMPDIR/$NODE" 2>/dev/null | awk '{print $2, $3}' || echo "???"; }
  printf "%-16s  %-10s  %-10s  %-10s  %-10s\n" "$NODE" "$(get mlx5_0)" "$(get mlx5_1)" "$(get mlx5_3)" "$(get mlx5_4)"
done
