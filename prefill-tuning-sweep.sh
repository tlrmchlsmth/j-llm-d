#!/usr/bin/env bash
# prefill-tuning-sweep.sh — Find the optimal TP/DP config for a single prefiller
#
# Deploys ALL configs in parallel as independent agg stacks (each with its
# own gateway + InferencePool), benchmarks them simultaneously, and collects
# results. Much faster than sequential testing.
#
# Prerequisites:
#   - .env with HF_TOKEN, GH_TOKEN, KUBECONFIG, NYANN_POKER_DIR
#   - Monitoring stack running: just start-monitoring
#   - Prometheus port-forward running: just prometheus
#   - Enough GPU nodes for all configs simultaneously
#
# Usage:
#   ./prefill-tuning-sweep.sh
#   DRY_RUN=1 ./prefill-tuning-sweep.sh
set -euo pipefail

# === Configuration ===
DRY_RUN=${DRY_RUN:-}

# Each config: "NAME TP_SIZE LWS_SIZE"
#   TP_SIZE: tensor parallelism (GPUs per DP rank)
#   LWS_SIZE: pods per prefiller group (total GPUs = LWS_SIZE * 4)
#   DP derived: DP_SIZE_LOCAL = 4 / TP_SIZE, total DP = LWS_SIZE * DP_SIZE_LOCAL
CONFIGS=(
  "ep-dp4   1 1"   # TP=1 (EP+DP), DP=4 across 4 GPUs (1 pod)
  "ep-dp8   1 2"   # TP=1 (EP+DP), DP=8 across 8 GPUs (2 pods)
  "tp4      4 1"   # TP=4, DP=1 across 4 GPUs (1 pod)
  "tp2      2 1"   # TP=2, DP=2 across 4 GPUs (1 pod)
)

# Workload — single turn, measuring raw prefill TTFT
# All array vars are space-separated strings
CONCURRENCIES=(${CONCURRENCIES:-256 512 1024})
ISL=${ISL:-10000}
OSL=${OSL:-1}
DURATION=${DURATION:-300s}
WARMUP=${WARMUP:-120s}
NUM_WORKERS=${NUM_WORKERS:-8}
NYANN_TAG=${NYANN_TAG:-latest}

# Timeouts
READY_TIMEOUT=${READY_TIMEOUT:-900}
BENCH_TIMEOUT=${BENCH_TIMEOUT:-3600}

# Derived
NAMESPACE="vllm"
KN="kubectl -n $NAMESPACE"
NAME_PREFIX="${USER}"
LUSTRE="/mnt/lustre/${NAME_PREFIX}"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
RESULTS_DIR="results/prefill-tuning-${TIMESTAMP}"
GB200_DIR="$(cd gb200 && pwd)"

# Load .env (skip in dry-run)
if [ -z "$DRY_RUN" ]; then
  if [ -f .env ]; then
    set -a; source .env; set +a
  fi
  if [ -z "${NYANN_POKER_DIR:-}" ]; then
    echo "Error: NYANN_POKER_DIR is not set. Add it to .env or export it." >&2
    exit 1
  fi
else
  NYANN_POKER_DIR="${NYANN_POKER_DIR:-/dry-run/nyann_poker}"
fi

# === Logging ===
log() { echo "[$(date +%H:%M:%S)] $*"; }
FAILURES=()

# === Helper Functions ===

make_workload_json() {
  local concurrency="$1"
  cat <<EOF
{"load":{"concurrency":${concurrency},"duration":"${DURATION}"},"warmup":{"duration":"${WARMUP}","stagger":true},"workload":{"type":"corpus","corpus_path":"${LUSTRE}/corpus/sharegpt.txt","isl":${ISL},"osl":${OSL},"turns":1}}
EOF
}

# Returns the deploy name for a config
deploy_name_for() { echo "${NAME_PREFIX}-pt-${1}"; }

# Returns the LWS name for a config (kustomize adds namePrefix + "wide-ep-decode")
lws_name_for() { echo "${NAME_PREFIX}-pt-${1}-wide-ep-decode"; }

# Returns the gateway URL for a config
base_url_for() {
  local dn
  dn=$(deploy_name_for "$1")
  echo "http://${dn}-inference-gateway-istio.${NAMESPACE}.svc.cluster.local/v1"
}

wait_for_lws_ready() {
  local lws_name="$1"
  local timeout="${2:-$READY_TIMEOUT}"

  if [ -n "$DRY_RUN" ]; then
    log "  [dry-run] skip wait for $lws_name"
    return 0
  fi

  log "Waiting for LWS $lws_name (timeout: ${timeout}s)..."
  local elapsed=0
  while [ $elapsed -lt "$timeout" ]; do
    local total ready not_ready
    total=$($KN get pods -l "leaderworkerset.sigs.k8s.io/name=${lws_name}" --no-headers 2>/dev/null | wc -l | tr -d ' ')
    ready=$($KN get pods -l "leaderworkerset.sigs.k8s.io/name=${lws_name}" --no-headers 2>/dev/null | grep -c Running || true)

    if [ "$total" -gt 0 ] && [ "$total" -eq "$ready" ]; then
      not_ready=$($KN get pods -l "leaderworkerset.sigs.k8s.io/name=${lws_name}" \
        -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' 2>/dev/null \
        | grep -c False || true)
      if [ "$not_ready" -eq 0 ]; then
        log "$lws_name: all $total pods ready"
        return 0
      fi
    fi

    log "$lws_name: $ready/$total running (${elapsed}s elapsed)"
    sleep 30
    elapsed=$((elapsed + 30))
  done

  log "ERROR: $lws_name not ready after ${timeout}s"
  return 1
}

wait_for_benchmark() {
  local job_name="$1"
  local timeout="${2:-$BENCH_TIMEOUT}"

  if [ -n "$DRY_RUN" ]; then
    log "  [dry-run] skip wait for benchmark $job_name"
    return 0
  fi

  local elapsed=0
  while [ $elapsed -lt "$timeout" ]; do
    local complete failed
    complete=$($KN get job -l "app=${job_name}" \
      -o jsonpath='{.items[0].status.conditions[?(@.type=="Complete")].status}' 2>/dev/null || true)
    failed=$($KN get job -l "app=${job_name}" \
      -o jsonpath='{.items[0].status.conditions[?(@.type=="Failed")].status}' 2>/dev/null || true)

    if [ "$complete" = "True" ]; then
      log "Benchmark $job_name completed"
      return 0
    fi
    if [ "$failed" = "True" ]; then
      log "WARNING: Benchmark $job_name failed"
      return 1
    fi

    sleep 30
    elapsed=$((elapsed + 30))
    if [ $((elapsed % 120)) -eq 0 ]; then
      log "  $job_name still running (${elapsed}s)"
    fi
  done

  log "ERROR: Benchmark $job_name timed out after ${timeout}s"
  return 1
}

collect_results() {
  local job_name="$1"
  local tag="$2"
  local outdir="${RESULTS_DIR}/${tag}"
  mkdir -p "$outdir"

  if [ -n "$DRY_RUN" ]; then
    log "  [dry-run] would collect results for $job_name -> $outdir/"
    return 0
  fi

  $KN logs -l "app=${job_name}" -c nyann-poker --tail=-1 \
    > "${outdir}/logs.txt" 2>/dev/null || true

  (cd "$NYANN_POKER_DIR" && \
    just query-prometheus "$job_name" "$(deploy_name_for "$tag")" "$NAMESPACE" \
      'http://localhost:9090' '' '' \
    > "${outdir}/metrics.txt" 2>/dev/null) || true

  log "Results saved to ${outdir}/"
}

# === Deploy / Cleanup ===

deploy_config() {
  local cfg_name="$1" tp_size="$2" lws_size="$3"
  local deploy_name owner
  deploy_name=$(deploy_name_for "$cfg_name")
  owner="${NAME_PREFIX}-pt-${cfg_name}"

  log "Deploying $cfg_name (TP=$tp_size, LWS_SIZE=$lws_size) as $deploy_name ..."

  if [ -n "$DRY_RUN" ]; then
    log "  [dry-run] would deploy agg stack: $deploy_name"
    log "  [dry-run]   kustomize (namePrefix=$owner) | sed TP_SIZE=$tp_size, size=$lws_size | kubectl apply"
    log "  [dry-run]   helm install ${deploy_name}-infpool (owner=$owner)"
    log "  [dry-run]   gateway + httproute for $deploy_name"
    return 0
  fi

  # 1. Render kustomize with config-specific namePrefix
  #    Kustomize requires relative paths, so symlink the overlay into a temp dir
  local tmpdir
  tmpdir=$(mktemp -d)
  ln -s "$GB200_DIR/overlays" "$tmpdir/overlays"
  ln -s "$GB200_DIR/base" "$tmpdir/base"
  printf 'apiVersion: kustomize.config.k8s.io/v1beta1\nkind: Kustomization\nnamePrefix: %s-\nresources:\n  - overlays/agg\n' \
    "$owner" > "$tmpdir/kustomization.yaml"

  local deploy_ts
  deploy_ts=$(date +%Y%m%d-%H%M%S)

  # Render, substitute placeholders and config, fix ports for DP count
  local dp_local=$((4 / tp_size))
  local port_list
  port_list=$(seq -s ' ' 8000 $((8000 + dp_local - 1)))

  kubectl kustomize "$tmpdir" \
    | sed -e "s/DEPLOY_TS_PLACEHOLDER/$deploy_ts/g" \
          -e "s/OWNER_PLACEHOLDER/${owner}/g" \
          -e "s|VLLM_DEV_VENV_PLACEHOLDER||g" \
          -e "s|LUSTRE_PREFIX_PLACEHOLDER|/mnt/lustre/${NAME_PREFIX}|g" \
          -e '/- name: TP_SIZE/{n;s/value: ".*"/value: "'"$tp_size"'"/;}' \
          -e "s/^    size: .*/    size: $lws_size/" \
    | python3 -c "
import sys, yaml

dp_local = $dp_local
docs = list(yaml.safe_load_all(sys.stdin))
for doc in docs:
    if doc is None or doc.get('kind') != 'LeaderWorkerSet':
        continue
    spec = doc['spec']['leaderWorkerTemplate']['workerTemplate']['spec']

    # Keep only the first dp_local init containers (routing sidecars)
    if 'initContainers' in spec:
        spec['initContainers'] = spec['initContainers'][:dp_local]

    for c in spec.get('containers', []):
        if c.get('name') != 'vllm':
            continue
        # Fix containerPort list — keep only active ports for both ranges
        c['ports'] = [p for p in c.get('ports', [])
                      if p['containerPort'] < 8000 + dp_local
                      or (8200 <= p['containerPort'] < 8200 + dp_local)]
        # Fix readiness probe to only check active ports
        ports_bash = ' '.join(str(8000 + r) for r in range(dp_local))
        c['readinessProbe']['exec']['command'] = [
            '/bin/bash', '-c',
            'for port in $ports_bash; do\n  curl -sf http://localhost:\$port/v1/models | grep -q \'\"id\"\' || exit 1\ndone'.replace('\$ports_bash', ports_bash)
        ]

print('---\n'.join(yaml.dump(d, default_flow_style=False) for d in docs if d))
" \
    | $KN apply -f -
  rm -rf "$tmpdir"

  # 2. Deploy InferencePool via helm (only target active DP ports)
  mkdir -p .tmp
  DEPLOY_NAME="$deploy_name" OWNER="$owner" \
    envsubst '${DEPLOY_NAME} ${OWNER}' < gb200/inferencepool-agg.values.yaml \
    | python3 -c "
import sys, yaml
dp_local = $dp_local
doc = yaml.safe_load(sys.stdin)
doc['inferencePool']['targetPorts'] = [{'number': 8000 + i} for i in range(dp_local)]
yaml.dump(doc, sys.stdout, default_flow_style=False)
" > ".tmp/infpool-pt-${cfg_name}.yaml"

  helm upgrade --install "${deploy_name}-infpool" \
    oci://registry.k8s.io/gateway-api-inference-extension/charts/inferencepool \
    --version v1.3.0 \
    -f ".tmp/infpool-pt-${cfg_name}.yaml" \
    -n "$NAMESPACE"

  # 3. Deploy gateway + httproute
  DEPLOY_NAME="$deploy_name" envsubst '${DEPLOY_NAME}' < gb200/gateway.yaml | $KN apply -f -
  DEPLOY_NAME="$deploy_name" envsubst '${DEPLOY_NAME}' < gb200/httproute.yaml | $KN apply -f -

  log "Deployed $cfg_name as $deploy_name"
}

cleanup_config() {
  local cfg_name="$1"
  local deploy_name owner lws_name
  deploy_name=$(deploy_name_for "$cfg_name")
  owner="${NAME_PREFIX}-pt-${cfg_name}"
  lws_name=$(lws_name_for "$cfg_name")

  log "Cleaning up $cfg_name ..."

  if [ -n "$DRY_RUN" ]; then
    log "  [dry-run] would delete: $lws_name, ${deploy_name}-infpool, gateway, httproute"
    return 0
  fi

  $KN delete lws "$lws_name" --ignore-not-found=true &
  helm uninstall "${deploy_name}-infpool" -n "$NAMESPACE" 2>/dev/null || true &
  $KN delete httproute "${deploy_name}-route" --ignore-not-found=true &
  $KN delete gateway "${deploy_name}-inference-gateway" --ignore-not-found=true &
  $KN delete service "${deploy_name}-inference-gateway-istio" --ignore-not-found=true &
  $KN delete configmap "${deploy_name}-gateway-options" --ignore-not-found=true &
  $KN delete destinationrule "${deploy_name}-infpool-backend" --ignore-not-found=true &
  $KN delete sa "${owner}-wide-ep" --ignore-not-found=true &
  wait
}

# === Main ===

log "=== Prefill Tuning Sweep (parallel) ==="
[ -n "$DRY_RUN" ] && log "*** DRY RUN — no cluster commands will execute ***"
log "Configs:       ${#CONFIGS[@]} configs"
for c in "${CONFIGS[@]}"; do log "  $c"; done
log "Concurrencies: ${CONCURRENCIES[*]} (per worker, ×$NUM_WORKERS workers)"
log "Workload:      isl=$ISL osl=$OSL (pure prefill) duration=$DURATION"
log "Results:       $RESULTS_DIR"
echo ""

mkdir -p "$RESULTS_DIR"
exec > >(tee -a "${RESULTS_DIR}/sweep.log") 2>&1

# Save experiment config
cat > "${RESULTS_DIR}/config.json" <<EOF
{
  "timestamp": "$TIMESTAMP",
  "configs": [$(for c in "${CONFIGS[@]}"; do read -r n t l <<< "$c"; printf '{"name":"%s","tp":%s,"lws":%s},' "$n" "$t" "$l"; done | sed 's/,$//')],
  "concurrencies": [$(printf '%s,' "${CONCURRENCIES[@]}" | sed 's/,$//')],
  "isl": $ISL,
  "osl": $OSL,
  "duration": "$DURATION",
  "warmup": "$WARMUP",
  "num_workers": $NUM_WORKERS
}
EOF

# Cleanup on exit
cleanup_all() {
  log "Cleaning up all configs..."
  for config_str in "${CONFIGS[@]}"; do
    read -r cfg_name _ _ <<< "$config_str"
    cleanup_config "$cfg_name" &
  done
  wait
  log "Cleanup complete"
}
if [ -z "$DRY_RUN" ]; then
  trap cleanup_all EXIT
fi

# --- Phase 1: Deploy all configs in parallel ---
log "=== Phase 1: Deploying ${#CONFIGS[@]} configs in parallel ==="
for config_str in "${CONFIGS[@]}"; do
  read -r cfg_name tp_size lws_size <<< "$config_str"
  deploy_config "$cfg_name" "$tp_size" "$lws_size" &
done
wait
log "All configs deployed"

# --- Phase 2: Wait for all pods ready ---
log "=== Phase 2: Waiting for all pods ==="
for config_str in "${CONFIGS[@]}"; do
  read -r cfg_name _ _ <<< "$config_str"
  wait_for_lws_ready "$(lws_name_for "$cfg_name")" &
done
wait
log "All configs ready"

# --- Phase 3: Benchmark each concurrency level ---
# Run all configs at the same concurrency in parallel, then move to next level.
# This prevents cross-concurrency load interference.
for CONC in "${CONCURRENCIES[@]}"; do
  log "=== Phase 3: Benchmarks at concurrency=$CONC ==="

  # Launch all configs in parallel
  for config_str in "${CONFIGS[@]}"; do
    read -r cfg_name _ _ <<< "$config_str"
    deploy_name=$(deploy_name_for "$cfg_name")
    base_url=$(base_url_for "$cfg_name")
    job_name="${NAME_PREFIX}-pt-${cfg_name}-c${CONC}"
    config_json=$(make_workload_json "$CONC")

    if [ -n "$DRY_RUN" ]; then
      log "  [dry-run] would launch: $job_name -> $base_url"
      log "  [dry-run] config: $config_json"
    else
      $KN delete job -l "app=${job_name}" --ignore-not-found=true 2>/dev/null || true
      sleep 2
      log "Launching $job_name"
      (cd "$NYANN_POKER_DIR" && just deploy "$job_name" "$base_url" "$config_json" \
        "$NUM_WORKERS" "$NAMESPACE" arm64 lustre "$NYANN_TAG")
    fi
  done

  # Wait for all to complete
  for config_str in "${CONFIGS[@]}"; do
    read -r cfg_name _ _ <<< "$config_str"
    job_name="${NAME_PREFIX}-pt-${cfg_name}-c${CONC}"
    tag="${cfg_name}-c${CONC}"

    if wait_for_benchmark "$job_name"; then
      collect_results "$job_name" "$tag"
    else
      FAILURES+=("$tag")
      collect_results "$job_name" "$tag"
    fi

    if [ -z "$DRY_RUN" ]; then
      $KN delete job -l "app=${job_name}" --ignore-not-found=true 2>/dev/null || true
    fi
  done
done

log "=== Sweep complete ==="
log "Results in: $RESULTS_DIR/"
ls -1 "$RESULTS_DIR/"

if [ ${#FAILURES[@]} -gt 0 ]; then
  echo ""
  log "WARNING: ${#FAILURES[@]} run(s) failed or timed out:"
  for f in "${FAILURES[@]}"; do
    log "  - $f"
  done
fi
