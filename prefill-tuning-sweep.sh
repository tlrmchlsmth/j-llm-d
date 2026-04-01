#!/usr/bin/env bash
# prefill-tuning-sweep.sh — Find the optimal TP/DP config for a single prefiller
#
# Deploys a single prefiller with different TP/DP configurations and
# benchmarks TTFT to find the fastest prefill config.
#
# Prerequisites:
#   - .env with HF_TOKEN, GH_TOKEN, KUBECONFIG, NYANN_POKER_DIR
#   - Monitoring stack running: just start-monitoring
#   - Prometheus port-forward running: just prometheus
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
#   DP is derived: DP_SIZE_LOCAL = 4 / TP_SIZE, total DP = LWS_SIZE * DP_SIZE_LOCAL
CONFIGS=(
  "tp2-dp4  2 2"   # TP=2, DP=4 across 8 GPUs (2 pods)
  "tp4-dp2  4 2"   # TP=4, DP=2 across 8 GPUs (2 pods)
  "tp8-dp1  8 2"   # TP=8, DP=1 across 8 GPUs (2 pods)
  "dp4      1 1"   # TP=1, DP=4 across 4 GPUs (1 pod)
  "dp8      1 2"   # TP=1, DP=8 across 8 GPUs (2 pods)
)

# Workload — single turn, measuring raw prefill TTFT
# All array vars are space-separated strings
CONCURRENCIES=(${CONCURRENCIES:-256 512 1024})
ISL=${ISL:-10000}
OSL=${OSL:-2000}
DURATION=${DURATION:-300s}
WARMUP=${WARMUP:-120s}
NUM_WORKERS=${NUM_WORKERS:-8}
NYANN_TAG=${NYANN_TAG:-latest}

# Timeouts
READY_TIMEOUT=${READY_TIMEOUT:-900}
BENCH_TIMEOUT=${BENCH_TIMEOUT:-3600}
EPP_SETTLE=${EPP_SETTLE:-30}

# Derived
NAMESPACE="vllm"
KN="kubectl -n $NAMESPACE"
NAME_PREFIX="${USER}"
DEPLOY_NAME="${NAME_PREFIX}-wide-ep"
LUSTRE="/mnt/lustre/${NAME_PREFIX}"
BASE_URL="http://${DEPLOY_NAME}-inference-gateway-istio.${NAMESPACE}.svc.cluster.local/v1"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
RESULTS_DIR="results/prefill-tuning-${TIMESTAMP}"
PREFILL_LWS="${DEPLOY_NAME}-prefill"
PREFILL_YAML="gb200/base/prefill.yaml"

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

# === Functions ===

make_workload_json() {
  local concurrency="$1"
  cat <<EOF
{"load":{"concurrency":${concurrency},"duration":"${DURATION}"},"warmup":{"duration":"${WARMUP}","stagger":true},"workload":{"type":"corpus","corpus_path":"${LUSTRE}/corpus/sharegpt.txt","isl":${ISL},"osl":${OSL},"turns":1}}
EOF
}

wait_for_lws_ready() {
  local lws_name="$1"
  local expected_pods="${2:-}"
  local timeout="${3:-$READY_TIMEOUT}"

  if [ -n "$DRY_RUN" ]; then
    log "  [dry-run] skip wait for $lws_name (expected: ${expected_pods:-any})"
    return 0
  fi

  log "Waiting for LWS $lws_name to be ready (timeout: ${timeout}s)..."
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
        if [ -n "$expected_pods" ] && [ "$total" -ne "$expected_pods" ]; then
          log "$lws_name: $total pods ready but expected $expected_pods, waiting..."
        else
          log "$lws_name: all $total pods ready"
          return 0
        fi
      fi
    fi

    log "$lws_name: $ready/$total running (${elapsed}s elapsed)"
    sleep 30
    elapsed=$((elapsed + 30))
  done

  log "ERROR: $lws_name not ready after ${timeout}s"
  return 1
}

launch_benchmark() {
  local job_name="$1"
  local config="$2"

  if [ -n "$DRY_RUN" ]; then
    log "  [dry-run] would run benchmark: $job_name"
    log "  [dry-run] config: $config"
    return 0
  fi

  $KN delete job -l "app=${job_name}" --ignore-not-found=true 2>/dev/null || true
  sleep 5

  log "Launching benchmark: $job_name"
  log "  config: $config"
  (cd "$NYANN_POKER_DIR" && just deploy "$job_name" "$BASE_URL" "$config" \
    "$NUM_WORKERS" "$NAMESPACE" arm64 lustre "$NYANN_TAG")
}

wait_for_benchmark() {
  local job_name="$1"
  local timeout="${2:-$BENCH_TIMEOUT}"

  if [ -n "$DRY_RUN" ]; then
    log "  [dry-run] skip wait for benchmark $job_name"
    return 0
  fi

  log "Waiting for benchmark $job_name (timeout: ${timeout}s)..."
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
    just query-prometheus "$job_name" "$DEPLOY_NAME" "$NAMESPACE" \
      'http://localhost:9090' '' '' \
    > "${outdir}/metrics.txt" 2>/dev/null) || true

  log "Results saved to ${outdir}/"
}

patch_prefill_config() {
  local tp_size="$1"
  local lws_size="$2"
  local dp_local=$((4 / tp_size))

  log "Patching prefill: TP_SIZE=$tp_size, LWS size=$lws_size (DP_LOCAL=$dp_local)"

  if [ -n "$DRY_RUN" ]; then
    log "  [dry-run] would patch $PREFILL_YAML"
    return 0
  fi

  # NOTE: sed -i '' is macOS syntax; GNU sed uses sed -i''
  # Set replicas=1 (single prefiller for tuning)
  sed -i '' "s/^  replicas: .*/  replicas: 1/" "$PREFILL_YAML"
  # Set LWS worker size
  sed -i '' "s/^    size: .*/    size: $lws_size/" "$PREFILL_YAML"
  # Set TP_SIZE env var (appears as value: "N" after the TP_SIZE name)
  sed -i '' '/- name: TP_SIZE/{n;s/value: ".*"/value: "'"$tp_size"'"/;}' "$PREFILL_YAML"
}

# === Main ===

log "=== Prefill Tuning Sweep ==="
[ -n "$DRY_RUN" ] && log "*** DRY RUN — no cluster commands will execute ***"
log "Configs:       ${CONFIGS[*]}"
log "Concurrencies: ${CONCURRENCIES[*]} (per worker, ×$NUM_WORKERS workers)"
log "Workload:      isl=$ISL osl=$OSL turns=1 (single-turn prefill test)"
log "Results:       $RESULTS_DIR"
echo ""

mkdir -p "$RESULTS_DIR"

# Tee all output to log file
exec > >(tee -a "${RESULTS_DIR}/sweep.log") 2>&1

# Save experiment config
cat > "${RESULTS_DIR}/config.json" <<EOF
{
  "timestamp": "$TIMESTAMP",
  "configs": [$(printf '"%s",' "${CONFIGS[@]}" | sed 's/,$//')],
  "concurrencies": [$(printf '%s,' "${CONCURRENCIES[@]}" | sed 's/,$//')],
  "isl": $ISL,
  "osl": $OSL,
  "duration": "$DURATION",
  "warmup": "$WARMUP",
  "num_workers": $NUM_WORKERS
}
EOF

# Restore prefill.yaml on exit
if [ -z "$DRY_RUN" ]; then
  trap 'git checkout "$PREFILL_YAML" 2>/dev/null; log "Restored $PREFILL_YAML"' EXIT
fi

for CONFIG_STR in "${CONFIGS[@]}"; do
  read -r CFG_NAME TP_SIZE LWS_SIZE <<< "$CONFIG_STR"
  log "====== Config: $CFG_NAME (TP=$TP_SIZE, LWS_SIZE=$LWS_SIZE) ======"

  patch_prefill_config "$TP_SIZE" "$LWS_SIZE"

  # Redeploy — decode is unchanged so kubectl apply is a no-op for it,
  # only the prefill LWS restarts with the new config.
  if [ -n "$DRY_RUN" ]; then
    log "  [dry-run] would run: just start pd"
  else
    just start pd
  fi
  wait_for_lws_ready "${DEPLOY_NAME}-decode"
  wait_for_lws_ready "$PREFILL_LWS" 1  # 1 replica

  for CONC in "${CONCURRENCIES[@]}"; do
    TAG="${CFG_NAME}-c${CONC}"
    JOB_NAME="${NAME_PREFIX}-pt-${TAG}"
    log "--- Run: $TAG ---"

    CONFIG=$(make_workload_json "$CONC")
    launch_benchmark "$JOB_NAME" "$CONFIG"

    if wait_for_benchmark "$JOB_NAME"; then
      collect_results "$JOB_NAME" "$TAG"
    else
      FAILURES+=("$TAG")
      collect_results "$JOB_NAME" "$TAG"
    fi

    if [ -z "$DRY_RUN" ]; then
      $KN delete job -l "app=${JOB_NAME}" --ignore-not-found=true 2>/dev/null || true
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
