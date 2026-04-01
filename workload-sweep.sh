#!/usr/bin/env bash
# workload-sweep.sh — Sweep routing/concurrency/workload against a standing cluster
#
# Assumes the stack is already deployed (just start pd). No deployment,
# no scaling, no prefill config changes — just swap routing and run benchmarks.
#
# Usage:
#   ./workload-sweep.sh                          # defaults
#   STRATEGIES="pd pd-random" ./workload-sweep.sh
#   CONCURRENCIES="64 128 256 512" ./workload-sweep.sh
#   RESULTS_DIR=results/my-run ./workload-sweep.sh  # resume
#
# Workload overrides:
#   TURNS=5 ISL=10000 SUBSEQUENT_ISL=1000 OSL=1000 ./workload-sweep.sh
set -euo pipefail

# === Configuration ===
STRATEGIES=(${STRATEGIES:-pd pd-random})
CONCURRENCIES=(${CONCURRENCIES:-128 512})

# Workload
TURNS=${TURNS:-5}
ISL=${ISL:-10000}
SUBSEQUENT_ISL=${SUBSEQUENT_ISL:-1000}
OSL=${OSL:-1000}
DURATION=${DURATION:-300s}
WARMUP=${WARMUP:-180s}
NUM_WORKERS=${NUM_WORKERS:-8}
NYANN_TAG=${NYANN_TAG:-latest}

# Timeouts
BENCH_TIMEOUT=${BENCH_TIMEOUT:-5400}
EPP_SETTLE=${EPP_SETTLE:-30}

# Derived
NAMESPACE="vllm"
KN="kubectl -n $NAMESPACE"
NAME_PREFIX="${USER}"
DEPLOY_NAME="${NAME_PREFIX}-wide-ep"
LUSTRE="/mnt/lustre/${NAME_PREFIX}"
BASE_URL="http://${DEPLOY_NAME}-inference-gateway-istio.${NAMESPACE}.svc.cluster.local/v1"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
RESULTS_DIR="${RESULTS_DIR:-results/workload-sweep-${TIMESTAMP}}"

# Load .env
if [ -f .env ]; then
  set -a; source .env; set +a
fi
if [ -z "${NYANN_POKER_DIR:-}" ]; then
  echo "Error: NYANN_POKER_DIR is not set. Add it to .env or export it." >&2
  exit 1
fi

# === Helpers ===
log() { echo "[$(date +%H:%M:%S)] $*"; }
FAILURES=()

deploy_infpool() {
  local routing="$1"
  mkdir -p .tmp
  export DEPLOY_NAME OWNER="$NAME_PREFIX"
  envsubst '${DEPLOY_NAME} ${OWNER}' < "gb200/inferencepool-${routing}.values.yaml" > .tmp/inferencepool-values.yaml
  helm upgrade --install "${DEPLOY_NAME}-infpool" \
    oci://registry.k8s.io/gateway-api-inference-extension/charts/inferencepool \
    --version v1.3.0 \
    -f .tmp/inferencepool-values.yaml \
    -n "$NAMESPACE"
  $KN delete pod -l "inferencepool=${DEPLOY_NAME}-infpool-epp" --ignore-not-found=true
}

make_workload_json() {
  local concurrency="$1"
  cat <<EOF
{"load":{"concurrency":${concurrency},"duration":"${DURATION}"},"warmup":{"duration":"${WARMUP}","stagger":true},"workload":{"type":"corpus","corpus_path":"${LUSTRE}/corpus/sharegpt.txt","isl":${ISL},"subsequent_isl":${SUBSEQUENT_ISL},"osl":${OSL},"turns":${TURNS}}}
EOF
}

wait_for_benchmark() {
  local job_name="$1"
  local timeout="${2:-$BENCH_TIMEOUT}"
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
    [ $((elapsed % 120)) -eq 0 ] && log "  $job_name still running (${elapsed}s)"
  done
  log "ERROR: Benchmark $job_name timed out after ${timeout}s"
  return 1
}

collect_results() {
  local job_name="$1" tag="$2"
  local outdir="${RESULTS_DIR}/${tag}"
  mkdir -p "$outdir"
  $KN logs -l "app=${job_name}" -c nyann-poker --tail=-1 \
    > "${outdir}/logs.txt" 2>/dev/null || true
  (cd "$NYANN_POKER_DIR" && \
    just query-prometheus "$job_name" "$DEPLOY_NAME" "$NAMESPACE" \
      'http://localhost:9090' '' '' \
    > "${outdir}/metrics.txt" 2>/dev/null) || true
  log "Results saved to ${outdir}/"
}

# === Main ===

# Verify stack is running
decode_ready=$($KN get pods -l "leaderworkerset.sigs.k8s.io/name=${DEPLOY_NAME}-decode" \
  --no-headers 2>/dev/null | grep -c Running || true)
prefill_ready=$($KN get pods -l "leaderworkerset.sigs.k8s.io/name=${DEPLOY_NAME}-prefill" \
  --no-headers 2>/dev/null | grep -c Running || true)
if [ "$decode_ready" -eq 0 ] || [ "$prefill_ready" -eq 0 ]; then
  echo "Error: Stack not running (decode=$decode_ready, prefill=$prefill_ready). Deploy first with: just start pd" >&2
  exit 1
fi

log "=== Workload Sweep ==="
log "Stack:         decode=$decode_ready prefill=$prefill_ready pods running"
log "Strategies:    ${STRATEGIES[*]}"
log "Concurrencies: ${CONCURRENCIES[*]} (per worker, ×$NUM_WORKERS workers)"
log "Workload:      turns=$TURNS isl=$ISL subsequent_isl=$SUBSEQUENT_ISL osl=$OSL"
log "Timing:        duration=$DURATION warmup=$WARMUP"
log "Results:       $RESULTS_DIR"
echo ""

mkdir -p "$RESULTS_DIR"
exec > >(tee -a "${RESULTS_DIR}/sweep.log") 2>&1

cat > "${RESULTS_DIR}/config.json" <<EOF
{
  "timestamp": "$TIMESTAMP",
  "strategies": [$(printf '"%s",' "${STRATEGIES[@]}" | sed 's/,$//')],
  "concurrencies": [$(printf '%s,' "${CONCURRENCIES[@]}" | sed 's/,$//')],
  "turns": $TURNS,
  "isl": $ISL,
  "subsequent_isl": $SUBSEQUENT_ISL,
  "osl": $OSL,
  "duration": "$DURATION",
  "warmup": "$WARMUP",
  "num_workers": $NUM_WORKERS,
  "decode_pods": $decode_ready,
  "prefill_pods": $prefill_ready
}
EOF

for STRATEGY in "${STRATEGIES[@]}"; do
  log "--- Strategy: $STRATEGY ---"
  deploy_infpool "$STRATEGY"
  log "Waiting ${EPP_SETTLE}s for EPP to settle..."
  sleep "$EPP_SETTLE"

  for CONC in "${CONCURRENCIES[@]}"; do
    TAG="${STRATEGY}-c${CONC}"
    JOB_NAME="${NAME_PREFIX}-ws-${TAG}"

    if [ -s "${RESULTS_DIR}/${TAG}/logs.txt" ]; then
      log "Skip: $TAG (already completed)"
      continue
    fi

    log "Run: $TAG"
    $KN delete job -l "app=${JOB_NAME}" --ignore-not-found=true 2>/dev/null || true
    sleep 5

    CONFIG=$(make_workload_json "$CONC")
    log "  config: $CONFIG"
    (cd "$NYANN_POKER_DIR" && just deploy "$JOB_NAME" "$BASE_URL" "$CONFIG" \
      "$NUM_WORKERS" "$NAMESPACE" arm64 lustre "$NYANN_TAG")

    if wait_for_benchmark "$JOB_NAME"; then
      collect_results "$JOB_NAME" "$TAG"
    else
      FAILURES+=("$TAG")
      collect_results "$JOB_NAME" "$TAG"
    fi

    $KN delete job -l "app=${JOB_NAME}" --ignore-not-found=true 2>/dev/null || true
  done
done

log "=== Sweep complete ==="
log "Results in: $RESULTS_DIR/"
ls -1 "$RESULTS_DIR/"

if [ ${#FAILURES[@]} -gt 0 ]; then
  echo ""
  log "WARNING: ${#FAILURES[@]} run(s) failed:"
  for f in "${FAILURES[@]}"; do log "  - $f"; done
fi
