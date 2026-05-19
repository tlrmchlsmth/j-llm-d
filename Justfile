set dotenv-load
set dotenv-required

NAMESPACE := "vllm"
HF_TOKEN := "$HF_TOKEN"
GH_TOKEN := "$GH_TOKEN"

KN := "kubectl -n " + NAMESPACE

NAME_PREFIX := env("USER", "dev")
DEPLOY_NAME := NAME_PREFIX + "-wide-ep"
POKER_NAME := NAME_PREFIX + "-poker"
DEV_POD_NAME := NAME_PREFIX + "-vllm-dev"

GB200_DIR := "gb200"
DEV_DIR := "dev"
MONITORING_DIR := "monitoring"

default:
  just --list

@print-gpus:
  kubectl get pods -A -o json | jq -r ' \
    .items \
    | map(select(.status.phase=="Running")) \
    | map({ \
        ns: .metadata.namespace, \
        pod: .metadata.name, \
        node: .spec.nodeName, \
        gpus: ([ .spec.containers[]? \
                 | ( (.resources.limits."nvidia.com/gpu" \
                      // .resources.requests."nvidia.com/gpu" \
                      // "0" | tonumber) \
                   + (.resources.limits."amd.com/gpu" \
                      // .resources.requests."amd.com/gpu" \
                      // "0" | tonumber) ) ] | add) \
      }) \
    | map(select(.gpus>0 and .node != null)) \
    | sort_by(.node, .ns, .pod) \
    | group_by(.node) \
    | .[] as $grp \
    | "== Node: \($grp[0].node) ==", \
      "NAMESPACE\tPOD\tGPUs", \
      ( $grp[] | "\(.ns)\t\(.pod)\t\(.gpus)" ), \
      "" \
  ' | column -t -s $'\t' \
  | awk 'NR==1{print; next} /^== /{print ""; print; next} {print}'


# Print table of nodes on Coreweave. Quiet recipe since the command is messy
@cks-nodes:
  kubectl get nodes -o=custom-columns="NAME:metadata.name,IP:status.addresses[?(@.type=='InternalIP')].address,TYPE:metadata.labels['node\.coreweave\.cloud\/type'],LINK:metadata.labels['ethernet\.coreweave\.cloud/speed'],READY:status.conditions[?(@.type=='Ready')].status,CORDON:spec.unschedulable,TAINT:spec.taints[?(@.key=='qos.coreweave.cloud/interruptable')].effect,RELIABILITY:metadata.labels['node\.coreweave\.cloud\/reliability'],LG:metadata.labels['ib\.coreweave\.cloud\/leafgroup'],VERSION:metadata.labels['node\.coreweave\.cloud\/version'],IB:metadata.labels['ib\.coreweave\.cloud\/speed'],STATE:metadata.labels['node\.coreweave\.cloud\/state'],RESERVED:metadata.labels['node\.coreweave\.cloud\/reserved']"

# Check InfiniBand port health on all GPU (arm64) nodes
check-ib:
  ./scripts/check-ib.sh

create-secrets:
  kubectl create secret generic hf-secret --from-literal=HF_TOKEN={{HF_TOKEN}} -n {{NAMESPACE}} \
  && kubectl create secret generic gh-token-secret --from-literal=GH_TOKEN={{GH_TOKEN}} -n {{NAMESPACE}}

start-poker:
    POKER_NAME={{POKER_NAME}} envsubst '${POKER_NAME}' < poker/poker.yaml | {{KN}} apply -f -

# Fetch decode pod names and IPs and cache them
get-decode-pods:
  #!/usr/bin/env bash
  set -euo pipefail
  mkdir -p ./.tmp
  echo "Fetching decode pod information..."
  {{KN}} get pods -l llm-d.ai/owner={{NAME_PREFIX}},llm-d.ai/role=decode -o json | jq -r '.items[] | "\(.metadata.name) \(.status.podIP)"' > .tmp/decode_pods.txt
  echo "Decode pods:"
  cat .tmp/decode_pods.txt

poke:
  #!/usr/bin/env bash
  set -euo pipefail
  mkdir -p ./.tmp

  # Export variables for envsubst
  export BASE_URL="http://{{DEPLOY_NAME}}-inference-gateway-istio.{{NAMESPACE}}.svc.cluster.local"
  export NAMESPACE="{{NAMESPACE}}"

  envsubst '${BASE_URL} ${NAMESPACE}' < Justfile.remote > .tmp/Justfile.remote.tmp
  kubectl cp .tmp/Justfile.remote.tmp {{NAMESPACE}}/{{POKER_NAME}}:/app/Justfile
  {{KN}} exec -it {{POKER_NAME}} -- /bin/zsh


parallel-guidellm CONCURRENT_PER_WORKER='4000' REQUESTS_PER_WORKER='4000' INPUT_LEN='128' OUTPUT_LEN='1000' N_WORKERS='4':
  {{KN}} delete job parallel-guidellm --ignore-not-found=true \
  && env \
    N_WORKERS={{N_WORKERS}} \
    MAX_CONCURRENCY={{CONCURRENT_PER_WORKER}} \
    NUM_REQUESTS={{REQUESTS_PER_WORKER}} \
    INPUT_LEN={{INPUT_LEN}} \
    OUTPUT_LEN={{OUTPUT_LEN}} \
    DEPLOY_NAME="{{DEPLOY_NAME}}" \
    NAMESPACE="{{NAMESPACE}}" \
    OUTPUT_PATH="parallel-guidellm-$(date +%Y%m%d-%H%M%S)" \
    envsubst '${N_WORKERS} ${MAX_CONCURRENCY} ${NUM_REQUESTS} ${INPUT_LEN} ${OUTPUT_LEN} ${OUTPUT_PATH} ${DEPLOY_NAME} ${NAMESPACE}' \
      < parallel-guidellm.yaml | {{KN}} apply -f -

# Run inference-perf benchmark (kubernetes-sigs/inference-perf)
# Uses concurrent load type: each worker maintains WORKER_MAX_CONCURRENCY in-flight requests
inference-perf NUM_REQUESTS='25000' INPUT_LEN='500' OUTPUT_LEN='1500' NUM_WORKERS='2' WORKER_MAX_CONCURRENCY='2048' WARMUP_CONCURRENCY='64' WARMUP_REQUESTS='256':
  #!/usr/bin/env bash
  set -euo pipefail
  INPUT_MEAN={{INPUT_LEN}}
  OUTPUT_MEAN={{OUTPUT_LEN}}
  export NUM_REQUESTS={{NUM_REQUESTS}}
  export NUM_WORKERS={{NUM_WORKERS}}
  export WORKER_MAX_CONCURRENCY={{WORKER_MAX_CONCURRENCY}}
  export CONCURRENCY=$((NUM_WORKERS * WORKER_MAX_CONCURRENCY))
  export WARMUP_CONCURRENCY={{WARMUP_CONCURRENCY}}
  export WARMUP_REQUESTS={{WARMUP_REQUESTS}}
  export DEPLOY_NAME="{{DEPLOY_NAME}}"
  export INPUT_MEAN INPUT_MIN=$((INPUT_MEAN - INPUT_MEAN/5)) INPUT_MAX=$((INPUT_MEAN + INPUT_MEAN/5)) INPUT_STD=$((INPUT_MEAN/10))
  export OUTPUT_MEAN OUTPUT_MIN=$((OUTPUT_MEAN - OUTPUT_MEAN/5)) OUTPUT_MAX=$((OUTPUT_MEAN + OUTPUT_MEAN/5)) OUTPUT_STD=$((OUTPUT_MEAN/10))
  {{KN}} delete job inference-perf --ignore-not-found=true
  {{KN}} delete configmap inference-perf-config --ignore-not-found=true
  envsubst '${DEPLOY_NAME} ${NUM_REQUESTS} ${NUM_WORKERS} ${WORKER_MAX_CONCURRENCY} ${CONCURRENCY} ${WARMUP_CONCURRENCY} ${WARMUP_REQUESTS} ${INPUT_MEAN} ${INPUT_MIN} ${INPUT_MAX} ${INPUT_STD} ${OUTPUT_MEAN} ${OUTPUT_MIN} ${OUTPUT_MAX} ${OUTPUT_STD}' \
    < inference-perf-job.yaml | {{KN}} apply -f -
  echo "inference-perf job submitted (concurrent, workers=${NUM_WORKERS} concurrency=${CONCURRENCY} warmup=${WARMUP_CONCURRENCY}x${WARMUP_REQUESTS} requests=${NUM_REQUESTS} input=${INPUT_MEAN} output=${OUTPUT_MEAN})"
  echo "  kubectl -n {{NAMESPACE}} logs -f job/inference-perf"

# Get inference-perf results
inference-perf-logs:
  {{KN}} logs -f job/inference-perf

deploy_inferencepool ROUTING='load-aware':
  #!/usr/bin/env bash
  set -euo pipefail
  mkdir -p ./.tmp
  export DEPLOY_NAME="{{DEPLOY_NAME}}"
  export OWNER="{{NAME_PREFIX}}"
  envsubst '${DEPLOY_NAME} ${OWNER}' < {{GB200_DIR}}/inferencepool-{{ROUTING}}.values.yaml > .tmp/inferencepool-values.yaml
  helm upgrade --install {{DEPLOY_NAME}}-infpool \
    oci://registry.k8s.io/gateway-api-inference-extension/charts/inferencepool \
    --version v1.5.0 \
    -f .tmp/inferencepool-values.yaml \
    -n {{NAMESPACE}}
  # Restart EPP pod to pick up config changes (it reads config at startup)
  {{KN}} delete pod -l inferencepool={{DEPLOY_NAME}}-infpool-epp --ignore-not-found=true
  # Apply DestinationRule for the backend infpool-ip service (prevents envoy OOM
  # from stale connection accumulation). The service name has a dynamic hash suffix
  # so we discover it via label. Wait for the Istio controller to create it.
  INFPOOL_IP_SVC=""
  for i in $(seq 1 30); do
    INFPOOL_IP_SVC=$({{KN}} get svc -l istio.io/inferencepool-name={{DEPLOY_NAME}}-infpool -o jsonpath='{.items[0].metadata.name}' 2>/dev/null) && [ -n "$INFPOOL_IP_SVC" ] && break
    sleep 2
  done
  if [ -z "$INFPOOL_IP_SVC" ]; then
    echo "WARNING: infpool-ip service not found after 60s — skipping DestinationRule (envoy OOM fix)."
    echo "         Apply manually later with: just apply-infpool-dr"
  else
    export DEPLOY_NAME INFPOOL_IP_SVC
    envsubst '${DEPLOY_NAME} ${INFPOOL_IP_SVC}' < {{GB200_DIR}}/infpool-backend-dr.yaml | {{KN}} apply -f -
  fi

# Apply the infpool-ip DestinationRule (envoy OOM fix) if it was skipped during deploy
apply-infpool-dr:
  #!/usr/bin/env bash
  set -euo pipefail
  INFPOOL_IP_SVC=$({{KN}} get svc -l istio.io/inferencepool-name={{DEPLOY_NAME}}-infpool -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  if [ -z "$INFPOOL_IP_SVC" ]; then
    echo "ERROR: infpool-ip service still not found. Is the Istio controller running?"
    exit 1
  fi
  export DEPLOY_NAME="{{DEPLOY_NAME}}" INFPOOL_IP_SVC
  envsubst '${DEPLOY_NAME} ${INFPOOL_IP_SVC}' < {{GB200_DIR}}/infpool-backend-dr.yaml | {{KN}} apply -f -
  echo "DestinationRule applied for $INFPOOL_IP_SVC"

VLLM_DEV_VENV := "/mnt/lustre/" + NAME_PREFIX + "/vllm-venv"
VLLM_DEV_SRC := "/mnt/lustre/" + NAME_PREFIX + "/vllm-dev"
VLLM_DEV_REMOTE := "https://github.com/vllm-project/vllm.git"
VLLM_DEV_BRANCH := "main"
VLLM_BUILD_JOBS := "16"

VLLM_IMAGE := env("VLLM_IMAGE", "quay.io/tms/vllm-deepseekv4-custom-deepep:latest")
FORK_REPO := env("FORK_REPO", "")
FORK_BRANCH := env("FORK_BRANCH", "")

start MODE='pd' ROUTING='load-aware' DEV='false':
  #!/usr/bin/env bash
  set -euo pipefail
  export DEPLOY_NAME="{{DEPLOY_NAME}}"
  DEPLOY_TS=$(date +%Y%m%d-%H%M%S)

  # Generate wrapper kustomization with user-specific namePrefix
  printf 'apiVersion: kustomize.config.k8s.io/v1beta1\nkind: Kustomization\nnamePrefix: {{NAME_PREFIX}}-\nresources:\n  - overlays/{{MODE}}\n' \
    > {{GB200_DIR}}/kustomization.yaml
  # Render kustomize, substitute placeholders, apply in one shot (no double rollout)
  DEV_VENV=""
  if [ "{{DEV}}" = "true" ]; then
    DEV_VENV="{{VLLM_DEV_VENV}}"
    echo "Dev mode: VLLM_DEV_VENV=$DEV_VENV"
  fi
  kubectl kustomize {{GB200_DIR}} \
    | sed -e "s/DEPLOY_TS_PLACEHOLDER/$DEPLOY_TS/g" \
          -e "s/OWNER_PLACEHOLDER/{{NAME_PREFIX}}/g" \
          -e "s|VLLM_DEV_VENV_PLACEHOLDER|$DEV_VENV|g" \
          -e "s|LUSTRE_PREFIX_PLACEHOLDER|/mnt/lustre/{{NAME_PREFIX}}|g" \
          -e "s|VLLM_IMAGE_PLACEHOLDER|{{VLLM_IMAGE}}|g" \
          -e "s|FORK_REPO_PLACEHOLDER|{{FORK_REPO}}|g" \
          -e "s|FORK_BRANCH_PLACEHOLDER|{{FORK_BRANCH}}|g" \
    | {{KN}} apply -f -
  rm -f {{GB200_DIR}}/kustomization.yaml

  envsubst '${DEPLOY_NAME}' < {{GB200_DIR}}/gateway.yaml | {{KN}} apply -f -
  if [ "{{MODE}}" = "pd" ]; then
    just deploy_inferencepool pd
  elif [ "{{MODE}}" = "agg" ]; then
    if [ "{{ROUTING}}" = "load-aware" ]; then
      just deploy_inferencepool agg
    else
      just deploy_inferencepool agg-{{ROUTING}}
    fi
  else
    just deploy_inferencepool {{ROUTING}}
  fi
  envsubst '${DEPLOY_NAME}' < {{GB200_DIR}}/httproute.yaml | {{KN}} apply -f -
  echo "Deployed $DEPLOY_TS"

stop NOW='false':
  #!/usr/bin/env bash
  set -euo pipefail
  FORCE=""
  if [ "{{NOW}}" = "true" ]; then
    FORCE="--grace-period=0 --force"
  fi
  # Kill everything in parallel
  {{KN}} delete lws {{DEPLOY_NAME}}-decode --ignore-not-found=true $FORCE &
  {{KN}} delete lws {{DEPLOY_NAME}}-prefill --ignore-not-found=true $FORCE &
  helm uninstall {{DEPLOY_NAME}}-infpool -n {{NAMESPACE}} 2>/dev/null || true &
  {{KN}} delete httproute {{DEPLOY_NAME}}-route --ignore-not-found=true &
  {{KN}} delete gateway {{DEPLOY_NAME}}-inference-gateway --ignore-not-found=true &
  {{KN}} delete service {{DEPLOY_NAME}}-inference-gateway-istio --ignore-not-found=true &
  {{KN}} delete configmap {{DEPLOY_NAME}}-gateway-options --ignore-not-found=true &
  {{KN}} delete destinationrule {{DEPLOY_NAME}}-infpool-backend --ignore-not-found=true &
  {{KN}} delete job parallel-guidellm --ignore-not-found=true $FORCE &
  {{KN}} delete job inference-perf --ignore-not-found=true $FORCE &
  {{KN}} delete configmap inference-perf-config --ignore-not-found=true &
  {{KN}} delete jobset -l app={{NAME_PREFIX}}-sharegpt-load --ignore-not-found=true $FORCE &
  {{KN}} delete jobset -l app={{NAME_PREFIX}}-nyann-eval --ignore-not-found=true $FORCE &
  {{KN}} delete jobset -l app={{NAME_PREFIX}}-eval-gsm8k --ignore-not-found=true $FORCE &
  {{KN}} delete jobset -l app={{NAME_PREFIX}}-eval-gpqa --ignore-not-found=true $FORCE &
  wait
  {{KN}} delete sa {{DEPLOY_NAME}} --ignore-not-found=true

restart MODE='pd' ROUTING='load-aware' DEV='false':
  #!/usr/bin/env bash
  set -euo pipefail
  # Force-delete LWS to kill pods immediately, then re-apply the full stack.
  # Non-LWS resources (gateway, httproute, infpool) are updated in place by start.
  # Delete LWS and orphaned pods
  {{KN}} delete lws {{DEPLOY_NAME}}-decode --ignore-not-found=true --grace-period=0 --force &
  {{KN}} delete lws {{DEPLOY_NAME}}-prefill --ignore-not-found=true --grace-period=0 --force &
  {{KN}} delete pod -l leaderworkerset.sigs.k8s.io/name={{DEPLOY_NAME}}-decode --ignore-not-found=true --grace-period=0 --force &
  {{KN}} delete pod -l leaderworkerset.sigs.k8s.io/name={{DEPLOY_NAME}}-prefill --ignore-not-found=true --grace-period=0 --force &
  wait
  # Wait for everything to be fully gone
  {{KN}} wait --for=delete pod -l leaderworkerset.sigs.k8s.io/name={{DEPLOY_NAME}}-decode --timeout=60s 2>/dev/null || true
  {{KN}} wait --for=delete pod -l leaderworkerset.sigs.k8s.io/name={{DEPLOY_NAME}}-prefill --timeout=60s 2>/dev/null || true
  just start {{MODE}} {{ROUTING}} {{DEV}}

# Wait for the full stack to be ready (pods + gateway serving)
ready:
  #!/usr/bin/env bash
  set -euo pipefail
  {{KN}} wait --for=condition=Ready pod -l llm-d.ai/role=decode,llm-d.ai/owner={{NAME_PREFIX}} --timeout=1200s &
  ({{KN}} wait --for=condition=Ready pod -l llm-d.ai/role=prefill,llm-d.ai/owner={{NAME_PREFIX}} --timeout=1200s 2>/dev/null || true) &
  {{KN}} wait --for=condition=Ready pod -l inferencepool={{DEPLOY_NAME}}-infpool-epp --timeout=120s &
  echo "Waiting for decode, prefill, and EPP pods..."
  wait
  echo "Checking gateway..."
  until {{KN}} exec deploy/{{DEPLOY_NAME}}-infpool-epp -- curl -sf --max-time 5 http://{{DEPLOY_NAME}}-inference-gateway-istio:80/v1/models 2>/dev/null | grep -q '"id"'
  do
    sleep 2
  done
  echo "Ready."

# Show persisted logs from Lustre (survives LWS pod recreation)
# Usage: just logs decode, just logs prefill, just logs decode -f (follow latest)
logs ROLE='decode' *ARGS='':
  #!/usr/bin/env bash
  set -euo pipefail
  LOG_DIR="/mnt/lustre/{{NAME_PREFIX}}/logs/{{ROLE}}"
  if [[ "{{ARGS}}" == *"-f"* ]]; then
    # Follow the latest log file
    LATEST=$({{KN}} exec {{DEV_POD_NAME}} -- bash -c "ls -t $LOG_DIR/*.log 2>/dev/null | head -1")
    if [ -z "$LATEST" ]; then
      echo "No logs found in $LOG_DIR"
      exit 1
    fi
    echo "Following $LATEST"
    {{KN}} exec {{DEV_POD_NAME}} -- tail -f "$LATEST"
  else
    # List recent log files with size and last line
    {{KN}} exec {{DEV_POD_NAME}} -- bash -c "
      ls -lt $LOG_DIR/*.log 2>/dev/null | head -20 || echo 'No logs found in $LOG_DIR'
    "
  fi

# Clean up old persisted logs from Lustre
logs-clean ROLE='decode' KEEP='5':
  #!/usr/bin/env bash
  set -euo pipefail
  LOG_DIR="/mnt/lustre/{{NAME_PREFIX}}/logs/{{ROLE}}"
  {{KN}} exec {{DEV_POD_NAME}} -- bash -c "
    cd $LOG_DIR 2>/dev/null || { echo 'No logs directory'; exit 0; }
    FILES=(\$(ls -t *.log 2>/dev/null))
    if [ \${#FILES[@]} -le {{KEEP}} ]; then
      echo 'Nothing to clean ({{KEEP}} or fewer logs)'
      exit 0
    fi
    echo \"Removing \$((\${#FILES[@]} - {{KEEP}})) old logs (keeping {{KEEP}})...\"
    for f in \"\${FILES[@]:{{KEEP}}}\"; do
      echo \"  rm \$f\"
      rm \"\$f\"
    done
  "

# === Dev Environment ===

# Note: tmp command, don't commit
update-dev-env:
  kubectl exec tms-vllm-dev -- bash -c "cd /mnt/lustre/tms/vllm-dev && git fetch tms && git reset --hard tms/cutedsl-moe-nvfp4 && find . -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null"

# Deploy the persistent dev pod (CPU-only, for editing/compiling vLLM on Lustre)
dev-start:
  envsubst < {{DEV_DIR}}/dev-pod.yaml | {{KN}} apply -f -
  {{KN}} wait --for=condition=Ready pod/{{DEV_POD_NAME}} --timeout=300s

# Exec into the dev pod
dev:
  {{KN}} exec -it {{DEV_POD_NAME}} -- /bin/zsh

# Build vLLM from source on Lustre (runs in background, survives disconnects)
dev-build REMOTE=VLLM_DEV_REMOTE BRANCH=VLLM_DEV_BRANCH JOBS=VLLM_BUILD_JOBS:
  #!/usr/bin/env bash
  set -euo pipefail
  {{KN}} exec -i {{DEV_POD_NAME}} -- bash <<'EOF'
  set -euo pipefail

  # ensure venv python points to /usr/bin/python3.12 (works in both dev and runtime images)
  VENV_PYTHON="{{VLLM_DEV_VENV}}/bin/python"
  if [ "$(readlink "$VENV_PYTHON")" != "/usr/bin/python3.12" ]; then
    echo "Repointing venv python: $(readlink "$VENV_PYTHON") -> /usr/bin/python3.12"
    ln -sf /usr/bin/python3.12 "$VENV_PYTHON"
  fi

  source {{VLLM_DEV_VENV}}/bin/activate
  cd {{VLLM_DEV_SRC}}

  # fetch and reset to requested branch
  git remote set-url origin {{REMOTE}}
  git fetch origin
  git checkout {{BRANCH}}
  git reset --hard origin/{{BRANCH}}

  # Flush stale JIT/compile caches (AOT graphs, flashinfer kernels, FA cute DSL)
  for d in vllm_cache_extdp flashinfer_cache_extdp fa_cute_dsl_cache; do
    [ -d "/mnt/lustre/{{NAME_PREFIX}}/$d" ] && mv "/mnt/lustre/{{NAME_PREFIX}}/$d" "/mnt/lustre/{{NAME_PREFIX}}/${d}.old.$(date +%s)" && echo "Flushed $d"
  done

  # Find the merge-base with upstream main for precompiled C++ extensions
  git remote add upstream https://github.com/vllm-project/vllm.git 2>/dev/null || true
  git fetch upstream main --no-tags 2>/dev/null
  PRECOMPILED_COMMIT=$(git merge-base HEAD upstream/main 2>/dev/null || git rev-parse HEAD)
  echo "Precompiled wheel commit: ${PRECOMPILED_COMMIT:0:12}"

  # build in background
  VLLM_USE_PRECOMPILED=1 \
  VLLM_PRECOMPILED_WHEEL_COMMIT=$PRECOMPILED_COMMIT \
  MAX_JOBS={{JOBS}} \
  nohup uv pip install --no-build-isolation -e . \
    > /mnt/lustre/{{NAME_PREFIX}}/build.log 2>&1 &

  echo "Build started ({{REMOTE}} {{BRANCH}}, jobs={{JOBS}}), follow with: just dev-build-log"
  EOF

# Tail the dev build log
dev-build-log:
  {{KN}} exec {{DEV_POD_NAME}} -- tail -f /mnt/lustre/{{NAME_PREFIX}}/build.log

# Delete the dev pod
dev-stop:
  envsubst < {{DEV_DIR}}/dev-pod.yaml | {{KN}} delete -f - --ignore-not-found=true

# Show the root cause of the most recent pod crash from Lustre logs
# Usage: just crashlog          (checks both decode and prefill)
#        just crashlog decode   (checks decode only)
#        just crashlog prefill  (checks prefill only)
crashlog ROLE='':
  #!/usr/bin/env bash
  set -euo pipefail
  ROLES="${1:-decode prefill}"
  {{KN}} exec {{DEV_POD_NAME}} -- bash -c '
  for role in '"$ROLES"'; do
    LUSTRE="/mnt/lustre/{{NAME_PREFIX}}/logs/$role"
    [ -d "$LUSTRE" ] || continue
    LOGS=($(ls -t "$LUSTRE"/{{DEPLOY_NAME}}-${role}-0_*.log 2>/dev/null))
    [ ${#LOGS[@]} -lt 2 ] && continue

    # Log churn = crashloop indicator
    RECENT=$(ls -t "$LUSTRE"/{{DEPLOY_NAME}}-${role}-0_*.log | head -5 | wc -l)
    LATEST_SIZE=$(wc -c < "${LOGS[0]}")
    echo "=== $role: ${RECENT} recent logs, latest ${LATEST_SIZE} bytes ==="

    # Find the crash log (2nd+ most recent with content)
    for i in 1 2 3 4; do
      F="${LOGS[$i]:-}"
      [ -z "$F" ] && break
      SIZE=$(wc -c < "$F" 2>/dev/null || echo 0)
      if [ "$SIZE" -gt 5000 ]; then
        echo "Crash log: $(basename $F) ($SIZE bytes)"
        ERRORS=$(grep "Worker failed\|RuntimeError:\|CUDA error:\|AssertionError\|ValueError:\|TypeError:\|illegal\|not implemented" "$F" \
          | grep -v "Traceback\|File\|^^^^\|resource_tracker\|DeprecationWarning\|Failed core proc" \
          | sort -u)
        if [ -n "$ERRORS" ]; then
          echo "$ERRORS" | head -5
        else
          echo "  (no obvious errors found)"
          echo "  tail:"
          tail -5 "$F"
        fi
        echo ""
        break
      fi
    done
  done
  '


# Download model weights to local NVMe on all GPU nodes (apply, wait, cleanup)
cache-model:
  #!/usr/bin/env bash
  set -euo pipefail
  {{KN}} delete daemonset model-cache --ignore-not-found=true
  {{KN}} apply -f {{GB200_DIR}}/model-cache-ds.yaml
  echo "Waiting for all nodes to finish downloading..."
  {{KN}} rollout status daemonset/model-cache --timeout=30m
  echo "All nodes cached. Cleaning up DaemonSet..."
  {{KN}} delete daemonset model-cache

# Flush vLLM/FlashInfer compile caches on Lustre (run after image or config changes)
flush-cache:
  {{KN}} exec {{DEV_POD_NAME}} -- bash -c 'rm -rf /mnt/lustre/{{NAME_PREFIX}}/vllm_cache_extdp /mnt/lustre/{{NAME_PREFIX}}/flashinfer_cache_extdp /mnt/lustre/{{NAME_PREFIX}}/fa_cute_dsl_cache && echo "Compile caches flushed"'

# Nsys profile: trigger cuda profiler on leader pod, flush sessions, copy from Lustre
profile:
  #!/usr/bin/env bash
  set -euo pipefail

  LEADER="{{DEPLOY_NAME}}-decode-0"
  LEADER_IP=$({{KN}} get pod "$LEADER" -o jsonpath='{.status.podIP}')
  LUSTRE_TRACE_DIR="/mnt/lustre/{{NAME_PREFIX}}/traces/nsys"
  DP_SIZE_LOCAL=4
  PORTS="8200 8201 8202 8203"

  echo "Starting nsys profile on $LEADER ($LEADER_IP)..."
  {{KN}} exec {{DEV_POD_NAME}} -- bash -c "
    for PORT in $PORTS; do
      curl -s -X POST http://$LEADER_IP:\$PORT/start_profile &
    done
    wait
  "
  echo "Profiling triggered (delay_iters + max_iters iterations)..."

  # Wait for iterations to complete (decode iters are ~ms each)
  sleep 5

  # Clear old traces, then flush all nsys sessions in parallel (pods will restart)
  {{KN}} exec {{DEV_POD_NAME}} -- rm -f "$LUSTRE_TRACE_DIR"/*.nsys-rep 2>/dev/null || true
  echo "Flushing nsys traces (pods will restart)..."
  {{KN}} exec "$LEADER" -c vllm -- bash -c "
    for R in \$(seq 0 $((DP_SIZE_LOCAL - 1))); do
      nsys shutdown --session=rank_\$R &
    done
    wait
  " || true

  echo "Copying traces from Lustre..."
  just copy-traces

# Copy nsys traces from Lustre to local ./traces/nsys/ directory
copy-traces:
  #!/usr/bin/env bash
  set -euo pipefail

  LUSTRE_TRACE_DIR="/mnt/lustre/{{NAME_PREFIX}}/traces/nsys"
  LOCAL_DIR="./traces/nsys"
  mkdir -p "$LOCAL_DIR"

  echo "Listing traces on Lustre..."
  {{KN}} exec {{DEV_POD_NAME}} -- ls -lh "$LUSTRE_TRACE_DIR" 2>/dev/null || { echo "No traces found on Lustre at $LUSTRE_TRACE_DIR"; exit 1; }

  echo "Copying to $LOCAL_DIR..."
  {{KN}} cp "{{DEV_POD_NAME}}:$LUSTRE_TRACE_DIR/" "$LOCAL_DIR/" 2>/dev/null || true

  echo "Local traces:"
  ls -lh "$LOCAL_DIR"/*.nsys-rep 2>/dev/null || echo "  No .nsys-rep files found"

# Combine per-rank traces and fix Perfetto overlaps
process-traces N='':
  #!/usr/bin/env bash
  set -euo pipefail
  N="{{N}}"
  if [ -z "$N" ]; then
    N=$(ls -d ./traces/[0-9]* 2>/dev/null | sort -t/ -k3 -n | tail -1 | xargs basename 2>/dev/null)
    if [ -z "$N" ]; then
      echo "No trace directories found in ./traces/"
      exit 1
    fi
  fi
  echo "Processing traces/$N ..."
  python3 profiling/process_traces.py "traces/$N"

NYANN_BENCH_DIR := env("NYANN_BENCH_DIR", "")

# Launch staircase load sweep + background eval
benchmark-stairs:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ -z "{{NYANN_BENCH_DIR}}" ]; then
      echo "Error: NYANN_BENCH_DIR is not set. Add it to .env or export it." >&2
      exit 1
    fi
    cd "{{NYANN_BENCH_DIR}}"
    go run ./cmd/nyann-bench/ generate \
      --target "{{EVAL_BASE_URL}}" \
      --config '{"load":{"concurrency":128},"warmup":{"duration":"60s","stagger":true},"sweep":{"min":1600,"max":14400,"steps":10,"step_duration":"300s"},"workload":{"type":"corpus","corpus_path":"{{LUSTRE_DATA}}/corpus/sharegpt.txt","isl":500,"osl":1500,"turns":1}}' \
      --workers 8 \
      --kube --kube.name {{NAME_PREFIX}}-sharegpt-load --kube.volume lustre --kube.image pr-53 --kube.namespace {{NAMESPACE}} &
    go run ./cmd/nyann-bench/ generate \
      --target "{{EVAL_BASE_URL}}" \
      --config '{"load":{"concurrency":64,"duration":"3600s"},"workload":{"type":"gsm8k","gsm8k_path":"{{LUSTRE_DATA}}/gsm8k_test.jsonl","gsm8k_train_path":"{{LUSTRE_DATA}}/gsm8k_train.jsonl"}}' \
      --kube --kube.name {{NAME_PREFIX}}-nyann-eval --kube.volume lustre --kube.image {{NYANN_IMAGE_TAG}} --kube.namespace {{NAMESPACE}} &
    wait
    echo "nyann-bench jobs submitted. Use 'just nyann-logs {{NAME_PREFIX}}-sharegpt-load' or 'just nyann-logs {{NAME_PREFIX}}-nyann-eval' to follow."

# Launch constant-concurrency load + background eval
benchmark-constant:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ -z "{{NYANN_BENCH_DIR}}" ]; then
      echo "Error: NYANN_BENCH_DIR is not set. Add it to .env or export it." >&2
      exit 1
    fi
    cd "{{NYANN_BENCH_DIR}}"
    go run ./cmd/nyann-bench/ generate \
      --target "{{EVAL_BASE_URL}}" \
      --config '{"load":{"concurrency":14400,"duration":"600s","rampup":"30s"},"warmup":{"duration":"60s","stagger":true},"workload":{"type":"corpus","corpus_path":"{{LUSTRE_DATA}}/corpus/sharegpt.txt","isl":500,"osl":1500,"turns":1}}' \
      --workers 8 \
      --kube --kube.name {{NAME_PREFIX}}-sharegpt-load --kube.volume lustre --kube.image pr-53 --kube.namespace {{NAMESPACE}} &
    go run ./cmd/nyann-bench/ generate \
      --target "{{EVAL_BASE_URL}}" \
      --config '{"load":{"concurrency":64,"duration":"180s"},"workload":{"type":"gsm8k","gsm8k_path":"{{LUSTRE_DATA}}/gsm8k_test.jsonl","gsm8k_train_path":"{{LUSTRE_DATA}}/gsm8k_train.jsonl"}}' \
      --kube --kube.name {{NAME_PREFIX}}-nyann-eval --kube.volume lustre --kube.image {{NYANN_IMAGE_TAG}} --kube.namespace {{NAMESPACE}} &
    wait
    echo "nyann-bench jobs submitted. Use 'just nyann-logs {{NAME_PREFIX}}-sharegpt-load' or 'just nyann-logs {{NAME_PREFIX}}-nyann-eval' to follow."

LUSTRE_DATA := "/mnt/lustre/" + NAME_PREFIX
EVAL_BASE_URL := "http://" + DEPLOY_NAME + "-inference-gateway-istio." + NAMESPACE + ".svc.cluster.local/v1"

NYANN_IMAGE_TAG := env("NYANN_IMAGE_TAG", "latest")

# Run GSM8K eval (1319 math problems, ~30 min)
eval-gsm8k CONCURRENCY='64':
    cd {{NYANN_BENCH_DIR}} && NYANN_NAME_PREFIX={{NAME_PREFIX}} go run ./cmd/nyann-bench/ eval gsm8k \
      --target "{{EVAL_BASE_URL}}" \
      --gsm8k-path {{LUSTRE_DATA}}/gsm8k_test.jsonl \
      --gsm8k-train-path {{LUSTRE_DATA}}/gsm8k_train.jsonl \
      --concurrency {{CONCURRENCY}} \
      --timeout 2h \
      --kube --kube.volume lustre --kube.image {{NYANN_IMAGE_TAG}} --kube.namespace {{NAMESPACE}}

# Run GPQA Diamond eval (198 grad-level science questions)
eval-gpqa CONCURRENCY='64':
    cd {{NYANN_BENCH_DIR}} && NYANN_NAME_PREFIX={{NAME_PREFIX}} go run ./cmd/nyann-bench/ eval gpqa \
      --target "{{EVAL_BASE_URL}}" \
      --gpqa-path {{LUSTRE_DATA}}/gpqa_diamond.jsonl \
      --concurrency {{CONCURRENCY}} \
      --timeout 2h \
      --kube --kube.volume lustre --kube.image {{NYANN_IMAGE_TAG}} --kube.namespace {{NAMESPACE}}

# Run both evals in parallel
eval: (eval-gsm8k) (eval-gpqa)

# Prep GPQA dataset on Lustre (if missing or empty)
prep-gpqa:
    #!/usr/bin/env bash
    set -euo pipefail
    cd "{{NYANN_BENCH_DIR}}"
    just prep-gpqa "{{LUSTRE_DATA}}" {{NAMESPACE}}

# Stop nyann-bench benchmark jobs
stop-nyann:
  {{KN}} delete jobset -l app={{NAME_PREFIX}}-sharegpt-load --ignore-not-found=true &
  {{KN}} delete jobset -l app={{NAME_PREFIX}}-nyann-eval --ignore-not-found=true &
  {{KN}} delete jobset -l app={{NAME_PREFIX}}-eval-gsm8k --ignore-not-found=true &
  {{KN}} delete jobset -l app={{NAME_PREFIX}}-eval-gpqa --ignore-not-found=true &
  wait

# Tail nyann-bench job logs
nyann-logs NAME:
  {{KN}} logs -l app={{NAME}} -c nyann-bench --tail=50 -f --max-log-requests=20

# Query Prometheus for per-stage benchmark metrics (requires port-forward: just prometheus)
query-prometheus CLIENT_JOB=(NAME_PREFIX + "-sharegpt-load") DEPLOYMENT=DEPLOY_NAME EVAL_JOB=(NAME_PREFIX + "-nyann-eval") *ARGS='':
  #!/usr/bin/env bash
  set -euo pipefail
  if [ -z "{{NYANN_BENCH_DIR}}" ]; then
    echo "Error: NYANN_BENCH_DIR is not set. Add it to .env or export it." >&2
    exit 1
  fi
  cd "{{NYANN_BENCH_DIR}}"
  just query-prometheus {{CLIENT_JOB}} {{DEPLOYMENT}} {{NAMESPACE}} '' {{EVAL_JOB}} {{ARGS}}

# === Monitoring ===

# Install Prometheus and Grafana (namespace-scoped, no cluster permissions needed)
start-monitoring:
  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update && helm repo add grafana https://grafana.github.io/helm-charts --force-update && helm repo update && kubectl apply -f {{MONITORING_DIR}}/prometheus-rbac.yaml && kubectl apply -f {{MONITORING_DIR}}/grafana-rbac.yaml && helm upgrade --install prometheus prometheus-community/prometheus -n {{NAMESPACE}} -f {{MONITORING_DIR}}/prometheus-values.yaml --set rbac.create=false --set serviceAccounts.server.create=false && helm upgrade --install grafana grafana/grafana -n {{NAMESPACE}} -f {{MONITORING_DIR}}/grafana-values.yaml --set rbac.create=false

# Uninstall monitoring stack
stop-monitoring:
  helm uninstall prometheus -n {{NAMESPACE}} --ignore-not-found && helm uninstall grafana -n {{NAMESPACE}} --ignore-not-found && kubectl delete -f {{MONITORING_DIR}}/prometheus-rbac.yaml --ignore-not-found && kubectl delete -f {{MONITORING_DIR}}/grafana-rbac.yaml --ignore-not-found

# Port-forward Grafana to localhost:3000 (background)
grafana:
  kubectl port-forward -n {{NAMESPACE}} svc/grafana 3000:80 > /dev/null 2>&1 &

# Port-forward Prometheus to localhost:9090 (background)
prometheus:
  kubectl port-forward -n {{NAMESPACE}} svc/prometheus-server 9090:80 > /dev/null 2>&1 &

# Load Grafana dashboards
load-dashboards:
  #!/usr/bin/env bash
  set -euo pipefail
  for f in "{{MONITORING_DIR}}"/*.json; do
    [ -f "$f" ] || continue
    NAME=$(basename "$f" .json)
    echo "Creating ConfigMap for dashboard: $NAME"
    {{KN}} create configmap "grafana-dashboard-$NAME" --from-file="$NAME.json=$f" --dry-run=client -o yaml | \
      {{KN}} label -f - --local -o yaml grafana_dashboard=1 | \
      {{KN}} apply -f -
  done
  echo "Dashboards loaded. Grafana will auto-discover them within 30 seconds."

# === KV Cache Sweep ===

KV_SWEEP_IMAGE := "quay.io/tms/llm-d-cuda-dev:ef2c4f7"
KV_SWEEP_MODEL := "deepseek-ai/DeepSeek-V4-Pro"
KV_SWEEP_PRIORITY := "low-priority"
KV_SWEEP_GPU_MEM_UTIL := "0.75"
KV_SWEEP_MAX_TOKENS := "1024"

# (internal) Render KV sweep Job YAML for a single DP size
_kv-sweep-job-yaml DP_SIZE:
  #!/usr/bin/env bash
  echo "---"
  env \
    JOB_NAME="{{NAME_PREFIX}}-kv-sweep-dp{{DP_SIZE}}" \
    MODEL="{{KV_SWEEP_MODEL}}" \
    VLLM_IMAGE="{{KV_SWEEP_IMAGE}}" \
    DP_SIZE={{DP_SIZE}} \
    GPU_MEM_UTIL={{KV_SWEEP_GPU_MEM_UTIL}} \
    MAX_TOKENS={{KV_SWEEP_MAX_TOKENS}} \
    LUSTRE_PREFIX="/mnt/lustre/{{NAME_PREFIX}}" \
    PRIORITY_CLASS="{{KV_SWEEP_PRIORITY}}" \
    envsubst '${JOB_NAME} ${MODEL} ${VLLM_IMAGE} ${DP_SIZE} ${GPU_MEM_UTIL} ${MAX_TOKENS} ${LUSTRE_PREFIX} ${PRIORITY_CLASS}' \
      < kv-sweep-job.yaml

# Sweep KV cache capacity across DP sizes (DP=1,2,4 on 4 GPUs with pure EP)
kv-sweep DP_SIZES='1 2 4':
  #!/usr/bin/env bash
  set -euo pipefail
  YAML=""
  for DP in {{DP_SIZES}}; do
    YAML+="$(just _kv-sweep-job-yaml $DP)"$'\n'
  done
  echo "$YAML" | {{KN}} replace --force -f -
  echo "KV sweep jobs launched for DP sizes: {{DP_SIZES}}"

# Show status of KV sweep jobs
kv-sweep-status:
  {{KN}} get jobs -l app=kv-sweep -o wide

# Collect KV cache results from sweep job logs
kv-sweep-collect:
  #!/usr/bin/env bash
  set -euo pipefail
  for job in $({{KN}} get jobs -l app=kv-sweep -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
    RESULT=$({{KN}} logs "job/$job" 2>/dev/null | grep '^KV_RESULT:' || true)
    if [ -n "$RESULT" ]; then
      echo "$RESULT"
    else
      echo "# $job: pending ({{KN}} logs job/$job)"
    fi
  done

# Clean up KV sweep jobs
kv-sweep-clean:
  {{KN}} delete jobs -l app=kv-sweep --ignore-not-found=true
