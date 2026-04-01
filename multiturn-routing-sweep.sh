#!/usr/bin/env bash
# multiturn-routing-sweep.sh — Compare intelligent vs random routing
#
# Two phases with different prefill configs:
#   Phase 1: EP+DP8 (TP=1, size=2) with intelligent routing (pd)
#   Phase 2: TP2 (TP=2, size=1) with random routing (pd-random)
#
# Each phase sweeps over prefill replica counts and concurrency levels.
# Decode pods are deployed once and never restarted.
#
# Prerequisites:
#   - .env with HF_TOKEN, GH_TOKEN, KUBECONFIG, NYANN_POKER_DIR
#   - Monitoring stack running: just start-monitoring
#   - Prometheus port-forward running: just prometheus
#
# Usage:
#   ./multiturn-routing-sweep.sh
#   DRY_RUN=1 ./multiturn-routing-sweep.sh
#
# Resume a previous run (skips completed benchmarks):
#   RESULTS_DIR=results/multiturn-sweep-20260401-105957 ./multiturn-routing-sweep.sh
set -euo pipefail

# === Configuration ===
DRY_RUN=${DRY_RUN:-}

# Phase definitions: "LABEL ROUTING TP_SIZE LWS_SIZE GPUS_PER_POD REPLICAS..."
# Override via env vars. Set to empty string to skip a phase.
PHASE_1="${PHASE_1-ep8-pd      pd        1 2 4   1 2 3 4}"
PHASE_2="${PHASE_2-tp2-random  pd-random 2 1 2   4 8 12 16}"
PHASE_3="${PHASE_3-ep8-random  pd-random 1 2 4   1 2 3 4}"

CONCURRENCIES=(${CONCURRENCIES:-128 512})

# Workload knobs
TURNS=${TURNS:-5}
ISL=${ISL:-10000}
SUBSEQUENT_ISL=${SUBSEQUENT_ISL:-1000}
OSL=${OSL:-1000}
DURATION=${DURATION:-180s}
WARMUP=${WARMUP:-60s}
NUM_WORKERS=${NUM_WORKERS:-8}
NYANN_TAG=${NYANN_TAG:-latest}

# Timeouts
READY_TIMEOUT=${READY_TIMEOUT:-1200}    # 20 min for model servers to start
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
RESULTS_DIR="${RESULTS_DIR:-results/multiturn-sweep-${TIMESTAMP}}"
PREFILL_LWS="${DEPLOY_NAME}-prefill"


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

# Portable sed -i (macOS uses -i '', GNU uses -i)
sedi() { sed -i"$(sed --version 2>/dev/null | grep -q GNU && echo '' || echo ' ')" "$@"; }

# Replicate `just start pd` without requiring just.
# Takes optional prefill config overrides so we never modify committed files.
deploy_stack() {
  local tp_size="${1:-}" lws_size="${2:-}" gpus_per_pod="${3:-}" replicas="${4:-}"
  local deploy_ts
  deploy_ts=$(date +%Y%m%d-%H%M%S)

  # Work on a temp copy so committed files are never touched
  local tmpdir
  tmpdir=$(mktemp -d)
  cp -r gb200/* "$tmpdir/"

  # Apply prefill config overrides to the temp copy
  if [ -n "$tp_size" ]; then
    local pf="$tmpdir/base/prefill.yaml"
    sedi "s/^  replicas: .*/  replicas: ${replicas:-1}/" "$pf"
    sedi "s/^    size: .*/    size: $lws_size/" "$pf"
    sedi '/- name: TP_SIZE/{n;s/value: ".*"/value: "'"$tp_size"'"/;}' "$pf"
    sedi '/- name: GPUS_PER_POD/{n;s/value: ".*"/value: "'"$gpus_per_pod"'"/;}' "$pf"
    sedi 's/nvidia.com\/gpu: "[0-9]*"/nvidia.com\/gpu: "'"$gpus_per_pod"'"/g' "$pf"
    log "  Prefill config: TP=$tp_size LWS=$lws_size GPUs=$gpus_per_pod replicas=${replicas:-1}"
  fi

  printf 'apiVersion: kustomize.config.k8s.io/v1beta1\nkind: Kustomization\nnamePrefix: %s-\nresources:\n  - overlays/pd\n' \
    "$NAME_PREFIX" > "${tmpdir}/kustomization.yaml"

  kubectl kustomize "$tmpdir" \
    | sed -e "s/DEPLOY_TS_PLACEHOLDER/$deploy_ts/g" \
          -e "s/OWNER_PLACEHOLDER/${NAME_PREFIX}/g" \
          -e "s|VLLM_DEV_VENV_PLACEHOLDER||g" \
          -e "s|LUSTRE_PREFIX_PLACEHOLDER|/mnt/lustre/${NAME_PREFIX}|g" \
    | $KN apply -f -
  rm -rf "$tmpdir"

  export DEPLOY_NAME
  envsubst '${DEPLOY_NAME}' < "gb200/gateway.yaml" | $KN apply -f -
  envsubst '${DEPLOY_NAME}' < "gb200/httproute.yaml" | $KN apply -f -
}

# Replicate `just deploy_inferencepool` without requiring just
deploy_infpool() {
  local routing="$1"
  mkdir -p .tmp
  local owner="$NAME_PREFIX"
  export DEPLOY_NAME OWNER="$owner"
  envsubst '${DEPLOY_NAME} ${OWNER}' < "gb200/inferencepool-${routing}.values.yaml" > .tmp/inferencepool-values.yaml
  helm upgrade --install "${DEPLOY_NAME}-infpool" \
    oci://registry.k8s.io/gateway-api-inference-extension/charts/inferencepool \
    --version v1.3.0 \
    -f .tmp/inferencepool-values.yaml \
    -n "$NAMESPACE"
  # Restart EPP pod
  $KN delete pod -l "inferencepool=${DEPLOY_NAME}-infpool-epp" --ignore-not-found=true
}

# Replicate nyann_poker `just deploy` without requiring just in nyann_poker
deploy_benchmark() {
  local job_name="$1" base_url="$2" config="$3" num_workers="$4"
  (cd "$NYANN_POKER_DIR" && just deploy "$job_name" "$base_url" "$config" \
    "$num_workers" "$NAMESPACE" arm64 lustre "$NYANN_TAG")
}

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
  local lws_size="${2:-1}"
  local expected_pods=$((count * lws_size))
  log "Scaling prefill LWS to $count replicas ($expected_pods pods)"
  if [ -n "$DRY_RUN" ]; then
    log "  [dry-run] would run: $KN patch lws $PREFILL_LWS --type merge -p '{\"spec\":{\"replicas\":$count}}'"
  else
    $KN patch lws "$PREFILL_LWS" --type merge -p "{\"spec\":{\"replicas\":$count}}"
  fi
  wait_for_lws_ready "$PREFILL_LWS" "$expected_pods"
}

swap_routing() {
  local strategy="$1"
  log "Swapping routing to: $strategy"
  if [ -n "$DRY_RUN" ]; then
    log "  [dry-run] would run: deploy_infpool $strategy"
  else
    deploy_infpool "$strategy"
    log "Waiting ${EPP_SETTLE}s for EPP to settle..."
    sleep "$EPP_SETTLE"
  fi
}


launch_benchmark() {
  local job_name="$1"
  local config="$2"

  if [ -n "$DRY_RUN" ]; then
    log "  [dry-run] would launch: $job_name"
    log "  [dry-run] config: $config"
    return 0
  fi

  $KN delete job -l "app=${job_name}" --ignore-not-found=true 2>/dev/null || true
  sleep 5
  log "Launching benchmark: $job_name"
  log "  config: $config"
  deploy_benchmark "$job_name" "$BASE_URL" "$config" "$NUM_WORKERS"
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

# Run a single phase: deploy prefill config, sweep replicas + concurrency
run_phase() {
  local phase_str="$1"
  if [ -z "$phase_str" ]; then
    log "  (phase skipped — empty definition)"
    return 0
  fi
  read -r label routing tp_size lws_size gpus_per_pod rest <<< "$phase_str"
  local replicas=($(sort_ascending $rest))

  log "====== Phase: $label ======"
  log "  Routing:  $routing"
  log "  Prefill:  TP=$tp_size, LWS_SIZE=$lws_size, GPUs/pod=$gpus_per_pod"
  log "  Replicas: ${replicas[*]}"
  echo ""

  # Deploy stack with prefill config overrides (works on temp copy, never modifies committed files)
  if [ -n "$DRY_RUN" ]; then
    log "  [dry-run] would deploy stack with TP=$tp_size LWS=$lws_size GPUs=$gpus_per_pod replicas=${replicas[0]}"
  else
    deploy_stack "$tp_size" "$lws_size" "$gpus_per_pod" "${replicas[0]}"
  fi
  wait_for_lws_ready "${DEPLOY_NAME}-decode"
  wait_for_lws_ready "$PREFILL_LWS" "$((${replicas[0]} * lws_size))"

  swap_routing "$routing"

  local first_rep=true
  for REP in "${replicas[@]}"; do
    # Check if all runs for this replica count are done
    local all_done=true
    for C in "${CONCURRENCIES[@]}"; do
      [ -s "${RESULTS_DIR}/${label}-${REP}rep-c${C}/logs.txt" ] || { all_done=false; break; }
    done
    if [ "$all_done" = true ]; then
      log "--- Skip replicas=$REP ($label) — all runs completed ---"
      continue
    fi

    log "--- Replicas: $REP ($label) ---"

    if [ "$first_rep" = true ]; then
      first_rep=false
    else
      scale_prefill "$REP" "$lws_size"
    fi

    for CONC in "${CONCURRENCIES[@]}"; do
      TAG="${label}-${REP}rep-c${CONC}"
      JOB_NAME="${NAME_PREFIX}-mt-${TAG}"

      # Skip if results already exist (resume support)
      if [ -s "${RESULTS_DIR}/${TAG}/logs.txt" ]; then
        log "--- Skip: $TAG (already completed) ---"
        continue
      fi

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
}

# === Main ===

log "=== Multiturn Routing Sweep ==="
[ -n "$DRY_RUN" ] && log "*** DRY RUN — no cluster commands will execute ***"
[ -n "$PHASE_1" ] && log "Phase 1: $PHASE_1"
[ -n "$PHASE_2" ] && log "Phase 2: $PHASE_2"
[ -n "$PHASE_3" ] && log "Phase 3: $PHASE_3"
log "Concurrencies: ${CONCURRENCIES[*]} (per worker, ×$NUM_WORKERS workers)"
log "Workload:      turns=$TURNS isl=$ISL subsequent_isl=$SUBSEQUENT_ISL osl=$OSL"
log "Timing:        duration=$DURATION warmup=$WARMUP"
log "Results:       $RESULTS_DIR"
echo ""

mkdir -p "$RESULTS_DIR"
exec > >(tee -a "${RESULTS_DIR}/sweep.log") 2>&1

# Save experiment config
cat > "${RESULTS_DIR}/config.json" <<EOF
{
  "timestamp": "$TIMESTAMP",
  "phase_1": "${PHASE_1:-}",
  "phase_2": "${PHASE_2:-}",
  "phase_3": "${PHASE_3:-}",
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


run_phase "$PHASE_1"
run_phase "$PHASE_2"
run_phase "$PHASE_3"

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
