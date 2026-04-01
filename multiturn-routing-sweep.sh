#!/usr/bin/env bash
# multiturn-routing-sweep.sh — Sweep (routing x prefill_replicas x concurrency)
#
# Deploys a P/D stack once, then scales prefill replicas in-place and
# hot-swaps routing strategies between runs. Decode pods are never restarted.
#
# Prerequisites:
#   - .env with HF_TOKEN, GH_TOKEN, KUBECONFIG, NYANN_POKER_DIR
#   - Monitoring stack running: just start-monitoring
#   - Prometheus port-forward running: just prometheus
#   - Routing config files: gb200/inferencepool-{STRATEGY}.values.yaml
#     Each must have matchLabels with llm-d.ai/deployment: pd
#
# Usage:
#   ./multiturn-routing-sweep.sh
#   REPLICAS="1 2 4" STRATEGIES="pd pd-random" CONCURRENCIES="64 128 256" \
#     ./multiturn-routing-sweep.sh
#
# Dry run (no cluster needed, validates sweep logic):
#   DRY_RUN=1 ./multiturn-routing-sweep.sh
set -euo pipefail

# === Configuration (override via env) ===
# All array vars are space-separated strings, e.g. REPLICAS="1 2 4"
DRY_RUN=${DRY_RUN:-}
REPLICAS=(${REPLICAS:-1 2 5})
STRATEGIES=(${STRATEGIES:-pd pd-random})
CONCURRENCIES=(${CONCURRENCIES:-256 512 1024})

# Workload knobs
TURNS=${TURNS:-5}
ISL=${ISL:-5000}
SUBSEQUENT_ISL=${SUBSEQUENT_ISL:-1000}
OSL=${OSL:-1000}
DURATION=${DURATION:-600s}
WARMUP=${WARMUP:-120s}
NUM_WORKERS=${NUM_WORKERS:-8}
NYANN_TAG=${NYANN_TAG:-latest}

# Timeouts
READY_TIMEOUT=${READY_TIMEOUT:-900}    # 15 min for model servers to start
BENCH_TIMEOUT=${BENCH_TIMEOUT:-5400}   # 90 min for benchmark to complete
EPP_SETTLE=${EPP_SETTLE:-30}           # seconds to wait after routing swap

# Derived (mirrors Justfile)
NAMESPACE="vllm"
KN="kubectl -n $NAMESPACE"
NAME_PREFIX="${USER}"
DEPLOY_NAME="${NAME_PREFIX}-wide-ep"
LUSTRE="/mnt/lustre/${NAME_PREFIX}"
BASE_URL="http://${DEPLOY_NAME}-inference-gateway-istio.${NAMESPACE}.svc.cluster.local/v1"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
RESULTS_DIR="results/multiturn-sweep-${TIMESTAMP}"
PREFILL_LWS="${DEPLOY_NAME}-prefill"

# Load .env for NYANN_POKER_DIR (skip in dry-run)
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

# Track failed runs for summary
FAILURES=()

# === Functions ===

sort_ascending() {
  printf '%s\n' "$@" | sort -n
}

make_workload_json() {
  local concurrency="$1"
  cat <<EOF
{"load":{"concurrency":${concurrency},"duration":"${DURATION}"},"warmup":{"duration":"${WARMUP}","stagger":true},"workload":{"type":"corpus","corpus_path":"${LUSTRE}/corpus/sharegpt.txt","isl":${ISL},"subsequent_isl":${SUBSEQUENT_ISL},"osl":${OSL},"turns":${TURNS}}}
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

scale_prefill() {
  local count="$1"
  log "Scaling prefill LWS to $count replicas"
  if [ -n "$DRY_RUN" ]; then
    log "  [dry-run] would run: $KN patch lws $PREFILL_LWS --type merge -p '{\"spec\":{\"replicas\":$count}}'"
  else
    $KN patch lws "$PREFILL_LWS" --type merge -p "{\"spec\":{\"replicas\":$count}}"
  fi
  wait_for_lws_ready "$PREFILL_LWS" "$count"
}

swap_routing() {
  local strategy="$1"
  log "Swapping routing to: $strategy"
  if [ -n "$DRY_RUN" ]; then
    log "  [dry-run] would run: just deploy_inferencepool $strategy"
  else
    just deploy_inferencepool "$strategy"
    log "Waiting ${EPP_SETTLE}s for EPP to settle..."
    sleep "$EPP_SETTLE"
  fi
}

launch_benchmark() {
  local job_name="$1"
  local config="$2"

  if [ -n "$DRY_RUN" ]; then
    log "  [dry-run] would delete previous job: $job_name"
    log "  [dry-run] would run: cd $NYANN_POKER_DIR && just deploy $job_name $BASE_URL '<config>' $NUM_WORKERS $NAMESPACE arm64 lustre $NYANN_TAG"
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
    log "  [dry-run] would collect logs and prometheus metrics for $job_name -> $outdir/"
    return 0
  fi

  $KN logs -l "app=${job_name}" -c nyann-poker --tail=-1 \
    > "${outdir}/logs.txt" 2>/dev/null || true

  # Query Prometheus (requires port-forward: just prometheus)
  (cd "$NYANN_POKER_DIR" && \
    just query-prometheus "$job_name" "$DEPLOY_NAME" "$NAMESPACE" \
      'http://localhost:9090' '' '' \
    > "${outdir}/metrics.txt" 2>/dev/null) || true

  log "Results saved to ${outdir}/"
}

# === Main ===

# Sort replicas ascending so we only ever scale up (new pods load model once)
REPLICAS=($(sort_ascending "${REPLICAS[@]}"))

log "=== Multiturn Routing Sweep ==="
[ -n "$DRY_RUN" ] && log "*** DRY RUN — no cluster commands will execute ***"
log "Replicas:      ${REPLICAS[*]} (ascending)"
log "Strategies:    ${STRATEGIES[*]}"
log "Concurrencies: ${CONCURRENCIES[*]}"
log "Workload:      turns=$TURNS isl=$ISL subsequent_isl=$SUBSEQUENT_ISL osl=$OSL"
log "Timing:        duration=$DURATION warmup=$WARMUP"
log "Results:       $RESULTS_DIR"
echo ""

mkdir -p "$RESULTS_DIR"

# Tee all output to a log file so it survives terminal disconnects
exec > >(tee -a "${RESULTS_DIR}/sweep.log") 2>&1

# Save experiment config
cat > "${RESULTS_DIR}/config.json" <<EOF
{
  "timestamp": "$TIMESTAMP",
  "replicas": [$(printf '%s,' "${REPLICAS[@]}" | sed 's/,$//')],
  "strategies": [$(printf '"%s",' "${STRATEGIES[@]}" | sed 's/,$//')],
  "concurrencies": [$(printf '%s,' "${CONCURRENCIES[@]}" | sed 's/,$//')],
  "turns": $TURNS,
  "isl": $ISL,
  "subsequent_isl": $SUBSEQUENT_ISL,
  "osl": $OSL,
  "duration": "$DURATION",
  "warmup": "$WARMUP",
  "num_workers": $NUM_WORKERS
}
EOF

# Deploy stack once with the smallest replica count.
# NOTE: sed -i '' is macOS syntax; GNU sed uses sed -i'' (no space).
if [ -z "$DRY_RUN" ]; then
  sed -i '' "s/^  replicas: .*/  replicas: ${REPLICAS[0]}/" gb200/base/prefill.yaml
  trap 'git checkout gb200/base/prefill.yaml 2>/dev/null; log "Restored prefill.yaml"' EXIT

  log "Deploying stack (initial prefill replicas: ${REPLICAS[0]})..."
  just start pd
else
  log "[dry-run] would patch prefill.yaml to ${REPLICAS[0]} replicas and run: just start pd"
fi
wait_for_lws_ready "${DEPLOY_NAME}-decode"
wait_for_lws_ready "$PREFILL_LWS" "${REPLICAS[0]}"
log "Stack ready"
echo ""

FIRST_REP=true
for REP in "${REPLICAS[@]}"; do
  log "====== Prefill replicas: $REP ======"

  if [ "$FIRST_REP" = true ]; then
    FIRST_REP=false
  else
    scale_prefill "$REP"
  fi

  for STRAT in "${STRATEGIES[@]}"; do
    swap_routing "$STRAT"

    for CONC in "${CONCURRENCIES[@]}"; do
      TAG="${STRAT}-${REP}rep-c${CONC}"
      JOB_NAME="${NAME_PREFIX}-mt-${TAG}"
      log "--- Run: $TAG ---"

      CONFIG=$(make_workload_json "$CONC")
      launch_benchmark "$JOB_NAME" "$CONFIG"

      if wait_for_benchmark "$JOB_NAME"; then
        collect_results "$JOB_NAME" "$TAG"
      else
        FAILURES+=("$TAG")
        collect_results "$JOB_NAME" "$TAG"  # still grab logs on failure
      fi

      if [ -z "$DRY_RUN" ]; then
        $KN delete job -l "app=${JOB_NAME}" --ignore-not-found=true 2>/dev/null || true
      fi
    done
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

# Optionally tear down (uncomment if desired)
# just stop
