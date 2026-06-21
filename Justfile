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

# Fetch model server pod names and IPs and cache them
# Auto-detects role: uses decode pods if they exist, otherwise prefill (agg mode)
# Scoped to current user via llm-d.ai/owner label
get-decode-pods:
  #!/usr/bin/env bash
  set -euo pipefail
  mkdir -p ./.tmp
  ROLE="decode"
  PODS=$({{KN}} get pods -l llm-d.ai/owner={{NAME_PREFIX}},llm-d.ai/role=decode -o json | jq -r '.items[] | "\(.metadata.name) \(.status.podIP)"')
  if [[ -z "$PODS" ]]; then
    ROLE="prefill"
    PODS=$({{KN}} get pods -l llm-d.ai/owner={{NAME_PREFIX}},llm-d.ai/role=prefill -o json | jq -r '.items[] | "\(.metadata.name) \(.status.podIP)"')
  fi
  echo "$PODS" > .tmp/decode_pods.txt
  echo "$ROLE" > .tmp/profile_role.txt
  echo "Model server pods ($ROLE):"
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

deploy_inferencepool ROUTING='load-aware' MODEL_DIR=GB200_DIR:
  #!/usr/bin/env bash
  set -euo pipefail
  mkdir -p ./.tmp
  export DEPLOY_NAME="{{DEPLOY_NAME}}"
  export OWNER="{{NAME_PREFIX}}"
  envsubst '${DEPLOY_NAME} ${OWNER}' < {{MODEL_DIR}}/inferencepool-{{ROUTING}}.values.yaml > .tmp/inferencepool-values.yaml
  helm upgrade --install {{DEPLOY_NAME}}-infpool \
    oci://registry.k8s.io/gateway-api-inference-extension/charts/inferencepool \
    --version v1.3.0 \
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
    echo "Waiting for infpool-ip service... ($i/30)"
    sleep 2
  done
  if [ -z "$INFPOOL_IP_SVC" ]; then
    echo "WARNING: infpool-ip service not found after 60s — skipping DestinationRule (envoy OOM fix)."
    echo "         Apply manually later with: just apply-infpool-dr"
  else
    export DEPLOY_NAME INFPOOL_IP_SVC
    envsubst '${DEPLOY_NAME} ${INFPOOL_IP_SVC}' < {{MODEL_DIR}}/infpool-backend-dr.yaml | {{KN}} apply -f -
  fi

# Apply the infpool-ip DestinationRule (envoy OOM fix) if it was skipped during deploy
apply-infpool-dr MODEL_DIR=GB200_DIR:
  #!/usr/bin/env bash
  set -euo pipefail
  INFPOOL_IP_SVC=$({{KN}} get svc -l istio.io/inferencepool-name={{DEPLOY_NAME}}-infpool -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  if [ -z "$INFPOOL_IP_SVC" ]; then
    echo "ERROR: infpool-ip service still not found. Is the Istio controller running?"
    exit 1
  fi
  export DEPLOY_NAME="{{DEPLOY_NAME}}" INFPOOL_IP_SVC
  envsubst '${DEPLOY_NAME} ${INFPOOL_IP_SVC}' < {{MODEL_DIR}}/infpool-backend-dr.yaml | {{KN}} apply -f -
  echo "DestinationRule applied for $INFPOOL_IP_SVC"

VLLM_DEV_VENV := "/mnt/lustre/" + NAME_PREFIX + "/vllm-venv"
VLLM_DEV_SRC := "/mnt/lustre/" + NAME_PREFIX + "/vllm-dev"
VLLM_DEV_REMOTE := "https://github.com/vllm-project/vllm.git"
VLLM_DEV_BRANCH := "main"
VLLM_BUILD_JOBS := "16"

VLLM_IMAGE := env("VLLM_IMAGE", "ghcr.io/tlrmchlsmth/llm-d-cuda-dev:2323091")
FORK_REPO := env("FORK_REPO", "")
FORK_BRANCH := env("FORK_BRANCH", "")

NEMOTRON_DIR := "nemotron"

start MODE='pd' ROUTING='load-aware' DEV='false' MODEL_DIR=GB200_DIR:
  #!/usr/bin/env bash
  set -euo pipefail
  export DEPLOY_NAME="{{DEPLOY_NAME}}"
  DEPLOY_TS=$(date +%Y%m%d-%H%M%S)

  # Generate wrapper kustomization with user-specific namePrefix
  printf 'apiVersion: kustomize.config.k8s.io/v1beta1\nkind: Kustomization\nnamePrefix: {{NAME_PREFIX}}-\nresources:\n  - overlays/{{MODE}}\n' \
    > {{MODEL_DIR}}/kustomization.yaml
  # Render kustomize, substitute placeholders, apply in one shot (no double rollout)
  DEV_VENV=""
  if [ "{{DEV}}" = "true" ]; then
    DEV_VENV="{{VLLM_DEV_VENV}}"
    echo "Dev mode: VLLM_DEV_VENV=$DEV_VENV"
  fi
  kubectl kustomize {{MODEL_DIR}} \
    | sed -e "s/DEPLOY_TS_PLACEHOLDER/$DEPLOY_TS/g" \
          -e "s/OWNER_PLACEHOLDER/{{NAME_PREFIX}}/g" \
          -e "s|VLLM_DEV_VENV_PLACEHOLDER|$DEV_VENV|g" \
          -e "s|LUSTRE_PREFIX_PLACEHOLDER|/mnt/lustre/{{NAME_PREFIX}}|g" \
          -e "s|VLLM_IMAGE_PLACEHOLDER|{{VLLM_IMAGE}}|g" \
          -e "s|FORK_REPO_PLACEHOLDER|{{FORK_REPO}}|g" \
          -e "s|FORK_BRANCH_PLACEHOLDER|{{FORK_BRANCH}}|g" \
    | {{KN}} apply -f -
  rm -f {{MODEL_DIR}}/kustomization.yaml

  envsubst '${DEPLOY_NAME}' < {{MODEL_DIR}}/gateway.yaml | {{KN}} apply -f -
  if [ "{{MODE}}" = "pd" ]; then
    just deploy_inferencepool pd {{MODEL_DIR}}
  elif [ "{{MODE}}" = "agg" ]; then
    if [ "{{ROUTING}}" = "load-aware" ]; then
      just deploy_inferencepool agg {{MODEL_DIR}}
    else
      just deploy_inferencepool agg-{{ROUTING}} {{MODEL_DIR}}
    fi
  else
    just deploy_inferencepool {{ROUTING}} {{MODEL_DIR}}
  fi
  envsubst '${DEPLOY_NAME}' < {{MODEL_DIR}}/httproute.yaml | {{KN}} apply -f -
  echo "Deployed $DEPLOY_TS"

# Start with custom P/D configuration: P(replicas,size)/D(replicas,size)
# Example: just start-pd 1 4 2 8 → P4/D16 (1×4 prefill workers, 2×8 decode workers)
start-pd PREFILL_REPLICAS PREFILL_SIZE DECODE_REPLICAS DECODE_SIZE ROUTING='load-aware' DEV='false' MODEL_DIR=NEMOTRON_DIR:
  #!/usr/bin/env bash
  set -euo pipefail
  export DEPLOY_NAME="{{DEPLOY_NAME}}"
  DEPLOY_TS=$(date +%Y%m%d-%H%M%S)

  TOTAL_PREFILL_WORKERS=$(({{PREFILL_REPLICAS}} * {{PREFILL_SIZE}}))
  TOTAL_DECODE_WORKERS=$(({{DECODE_REPLICAS}} * {{DECODE_SIZE}}))
  TOTAL_GPUS=$(((TOTAL_PREFILL_WORKERS + TOTAL_DECODE_WORKERS) * 4))

  echo "Deploying P${TOTAL_PREFILL_WORKERS}/D${TOTAL_DECODE_WORKERS} (${TOTAL_GPUS} GPUs total)"
  echo "  Prefill: {{PREFILL_REPLICAS}} replicas × {{PREFILL_SIZE}} workers = ${TOTAL_PREFILL_WORKERS} workers"
  echo "  Decode:  {{DECODE_REPLICAS}} replicas × {{DECODE_SIZE}} workers = ${TOTAL_DECODE_WORKERS} workers"

  # Generate wrapper kustomization with user-specific namePrefix
  printf 'apiVersion: kustomize.config.k8s.io/v1beta1\nkind: Kustomization\nnamePrefix: {{NAME_PREFIX}}-\nresources:\n  - overlays/pd-custom\n' \
    > {{MODEL_DIR}}/kustomization.yaml

  # Render kustomize and substitute all placeholders
  DEV_VENV=""
  if [ "{{DEV}}" = "true" ]; then
    DEV_VENV="{{VLLM_DEV_VENV}}"
    echo "Dev mode: VLLM_DEV_VENV=$DEV_VENV"
  fi

  kubectl kustomize {{MODEL_DIR}} \
    | sed -e "s/DEPLOY_TS_PLACEHOLDER/$DEPLOY_TS/g" \
          -e "s/OWNER_PLACEHOLDER/{{NAME_PREFIX}}/g" \
          -e "s|VLLM_DEV_VENV_PLACEHOLDER|$DEV_VENV|g" \
          -e "s|LUSTRE_PREFIX_PLACEHOLDER|/mnt/lustre/{{NAME_PREFIX}}|g" \
          -e "s|VLLM_IMAGE_PLACEHOLDER|{{VLLM_IMAGE}}|g" \
          -e "s|FORK_REPO_PLACEHOLDER|{{FORK_REPO}}|g" \
          -e "s|FORK_BRANCH_PLACEHOLDER|{{FORK_BRANCH}}|g" \
          -e "s/PREFILL_REPLICAS_PLACEHOLDER/{{PREFILL_REPLICAS}}/g" \
          -e "s/PREFILL_SIZE_PLACEHOLDER/{{PREFILL_SIZE}}/g" \
          -e "s/DECODE_REPLICAS_PLACEHOLDER/{{DECODE_REPLICAS}}/g" \
          -e "s/DECODE_SIZE_PLACEHOLDER/{{DECODE_SIZE}}/g" \
    | {{KN}} apply -f -
  rm -f {{MODEL_DIR}}/kustomization.yaml

  envsubst '${DEPLOY_NAME}' < {{MODEL_DIR}}/gateway.yaml | {{KN}} apply -f -
  just deploy_inferencepool pd {{MODEL_DIR}}
  envsubst '${DEPLOY_NAME}' < {{MODEL_DIR}}/httproute.yaml | {{KN}} apply -f -
  echo "Deployed P${TOTAL_PREFILL_WORKERS}/D${TOTAL_DECODE_WORKERS} at $DEPLOY_TS"

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
  wait
  {{KN}} delete sa {{DEPLOY_NAME}} --ignore-not-found=true

restart MODE='pd' ROUTING='load-aware' DEV='false' MODEL_DIR=GB200_DIR:
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
  just start {{MODE}} {{ROUTING}} {{DEV}} {{MODEL_DIR}}

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
  until {{KN}} exec {{POKER_NAME}} -- curl -sf --max-time 5 http://{{DEPLOY_NAME}}-inference-gateway-istio:80/v1/models 2>/dev/null | grep -q '"id"'
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

  # build in background
  MAX_JOBS={{JOBS}} nohup uv pip install --no-deps --no-build-isolation -e . \
    > /mnt/lustre/{{NAME_PREFIX}}/build.log 2>&1 &

  echo "Build started ({{REMOTE}} {{BRANCH}}, jobs={{JOBS}}), follow with: just dev-build-log"
  EOF

# Tail the dev build log
dev-build-log:
  {{KN}} exec {{DEV_POD_NAME}} -- tail -f /mnt/lustre/{{NAME_PREFIX}}/build.log

# Delete the dev pod
dev-stop:
  envsubst < {{DEV_DIR}}/dev-pod.yaml | {{KN}} delete -f - --ignore-not-found=true

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
  {{KN}} exec {{DEV_POD_NAME}} -- bash -c 'rm -rf /mnt/lustre/{{NAME_PREFIX}}/vllm_cache_extdp /mnt/lustre/{{NAME_PREFIX}}/flashinfer_cache_extdp && echo "Compile caches flushed"'

# Profile all model server pods, copy traces, and open in Finder
# Auto-detects role: uses decode pods (port 8200) if they exist, otherwise prefill (port 8000)
profile:
  #!/usr/bin/env bash
  set -euo pipefail

  # Auto-detect role and port (scoped to current user)
  PODS=$({{KN}} get pods -l llm-d.ai/owner={{NAME_PREFIX}},llm-d.ai/role=decode -o jsonpath='{range .items[*]}{.metadata.name}{" "}{end}')
  PORT=8200
  if [[ -z "$PODS" ]]; then
    PODS=$({{KN}} get pods -l llm-d.ai/owner={{NAME_PREFIX}},llm-d.ai/role=prefill -o jsonpath='{range .items[*]}{.metadata.name}{" "}{end}')
    PORT=8000
  fi
  if [[ -z "$PODS" ]]; then
    echo "No model server pods found for owner {{NAME_PREFIX}}"
    exit 1
  fi

  echo "Starting profile on all ranks (port $PORT)..."
  for POD in $PODS; do
    echo "  Starting $POD..."
    {{KN}} exec "$POD" -c vllm -- curl -s -m 30 -X POST http://localhost:$PORT/start_profile &
  done
  wait

  echo "Profiler running — capturing traces for 5 seconds..."
  sleep 5

  echo "Stopping profiler on all ranks..."
  for POD in $PODS; do
    echo "  Stopping $POD..."
    {{KN}} exec "$POD" -c vllm -- curl -s -m 120 -X POST http://localhost:$PORT/stop_profile &
  done
  wait

  echo "Copying traces..."
  just get-decode-pods
  # Determine trace dir before copy-traces runs
  N=0
  while [ -d "./traces/$N" ]; do
    N=$((N + 1))
  done
  just copy-traces

# Copy PyTorch traces from all decode pods to local ./traces/N directory
copy-traces:
  #!/usr/bin/env bash
  set -euo pipefail

  # Ensure we have fresh pod info
  if [ ! -f .tmp/decode_pods.txt ]; then
    just get-decode-pods
  fi

  # Find next available serial number
  N=0
  while [ -d "./traces/$N" ]; do
    N=$((N + 1))
  done

  TRACE_DIR="./traces/$N"
  mkdir -p "$TRACE_DIR"
  echo "Copying traces to $TRACE_DIR"

  # Copy traces from each pod
  while read -r POD_NAME POD_IP; do
    echo "Copying traces from $POD_NAME..."
    POD_DIR="$TRACE_DIR/$POD_NAME"
    mkdir -p "$POD_DIR"
    {{KN}} cp "$POD_NAME:/traces" "$POD_DIR" 2>&1 | grep -v "Removing leading" || true
  done < .tmp/decode_pods.txt

  echo "Traces copied to $TRACE_DIR"
  echo "Total size: $(du -sh $TRACE_DIR | cut -f1)"
  echo "Run 'just process-traces $N' to combine and fix for Perfetto"

# Delete /traces on all model server pods (prompts for confirmation)
clean-traces:
  #!/usr/bin/env bash
  set -euo pipefail
  just get-decode-pods
  echo ""
  echo "This will delete /traces on all pods listed above."
  read -p "Continue? [y/N] " confirm
  if [[ "$confirm" != [yY] ]]; then
    echo "Aborted."
    exit 0
  fi
  while read -r POD_NAME POD_IP; do
    echo "Deleting /traces on $POD_NAME..."
    {{KN}} exec "$POD_NAME" -c vllm -- rm -rf /traces
  done < .tmp/decode_pods.txt
  echo "Done."

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

# Launch constant-load benchmark + KV cache sampling in parallel
# DURATION is in seconds (no suffix). KV_INTERVAL supports fractional seconds.
calibrate CONCURRENCY ISL OSL DURATION='600' KV_INTERVAL='0.5':
  #!/usr/bin/env bash
  set -euo pipefail

  PROM_URL="http://prometheus-server.{{NAMESPACE}}.svc.cluster.local:80"

  just benchmark-constant {{CONCURRENCY}} {{DURATION}}s {{ISL}} {{OSL}}

  mkdir -p .tmp
  KV_LOG=".tmp/kv-samples-$(date +%Y%m%d-%H%M%S).csv"
  echo "timestamp,kv_util" > "$KV_LOG"

  echo "Sampling KV utilization every {{KV_INTERVAL}}s for {{DURATION}}s → $KV_LOG"

  # Sample in background (set +e so curl failures don't kill the loop)
  (
    set +e
    while true; do
      KV=$({{KN}} exec {{POKER_NAME}} -- curl -s --max-time 5 "$PROM_URL/api/v1/query" \
        --data-urlencode 'query=max(vllm:kv_cache_usage_perc{pod=~"{{DEPLOY_NAME}}-decode.*"})' \
        2>/dev/null | jq -r '.data.result[0].value[1] // empty' 2>/dev/null)
      if [ -n "$KV" ]; then
        echo "$(date +%s),$KV" >> "$KV_LOG"
      fi
      sleep {{KV_INTERVAL}}
    done
  ) &
  SAMPLE_PID=$!

  sleep {{DURATION}}
  kill $SAMPLE_PID 2>/dev/null
  wait $SAMPLE_PID 2>/dev/null || true

  MAX_KV=$(awk -F, 'NR>1 && $2+0 > max {max=$2+0} END{print max+0}' "$KV_LOG")
  SAMPLES=$(awk 'END{print NR-1}' "$KV_LOG")
  MAX_PCT=$(echo "scale=1; $MAX_KV * 100" | bc)
  MAX_C=$(echo "scale=0; {{CONCURRENCY}} * 0.90 / $MAX_KV" | bc 2>/dev/null || echo "0")

  echo ""
  echo "=== Calibration ==="
  echo "ISL={{ISL}} OSL={{OSL}} concurrency={{CONCURRENCY}} (${SAMPLES} samples)"
  echo "Peak KV utilization: ${MAX_PCT}%"
  echo "Estimated max concurrency at 90%% KV: ${MAX_C}"
  echo "Samples: $KV_LOG"

  if [ "$MAX_C" = "0" ] || [ "$MAX_C" = "N/A" ]; then
    echo "ERROR: Could not estimate max concurrency — skipping stairs"
    exit 1
  fi

  # Stop calibration load and wait for requests to drain
  just stop-nyann
  echo "Waiting 30s for requests to drain..."
  sleep 30

  SWEEP_MIN=$(echo "scale=0; $MAX_C / 10" | bc)
  SWEEP_MAX=$MAX_C

  echo ""
  echo "=== Starting stairs benchmark ==="
  echo "Sweep: ${SWEEP_MIN} → ${SWEEP_MAX} concurrency, 8 steps × 60s"

  just benchmark-stairs $SWEEP_MIN $SWEEP_MAX 8 60s {{ISL}} {{OSL}}

# Stop calibrate (benchmark + KV sampling)
stop-calibrate:
  just stop-nyann
  @echo "Stopped."

# Run KV cache calibration sweep across P/D configs
# Example: just sweep "1,2,1,4;1,4,1,8" 500 1500 256 60s
sweep CONFIGS ISL='500' OSL='1500' CALIB_CONCURRENCY='256' CALIB_DURATION='180s' OUTPUT='kv-sweep-results.csv' *ARGS='':
  cd kv-sweep && go run . --configs "{{CONFIGS}}" --isl {{ISL}} --osl {{OSL}} --calibration-concurrency {{CALIB_CONCURRENCY}} --calibration-duration {{CALIB_DURATION}} --output "{{OUTPUT}}" {{ARGS}}

NYANN_BENCH_DIR := env("NYANN_BENCH_DIR", "")
EVAL_BASE_URL := env("EVAL_BASE_URL", "")
LUSTRE_DATA := env("LUSTRE_DATA", "")
NYANN_IMAGE_TAG := env("NYANN_IMAGE_TAG", "")

# Wait for stack readiness, then launch nyann-bench load + eval jobs
benchmark-stairs SWEEP_MIN='1600' SWEEP_MAX='14400' STEPS='10' STEP_DURATION='300s' ISL='500' OSL='1500' EVAL_CONCURRENCY='16':
    #!/usr/bin/env bash
    set -euo pipefail
    if [ -z "{{NYANN_BENCH_DIR}}" ]; then
      echo "Error: NYANN_BENCH_DIR is not set. Add it to .env or export it." >&2
      exit 1
    fi
    STEP_DURATION="{{STEP_DURATION}}"
    STEP_SECS="${STEP_DURATION%s}"
    EVAL_DURATION="$(( {{STEPS}} * STEP_SECS ))s"
    cd "{{NYANN_BENCH_DIR}}"
    go run ./cmd/nyann-bench/ generate \
      --target "{{EVAL_BASE_URL}}" \
      --config '{"load":{"concurrency":128},"warmup":{"duration":"60s","stagger":true},"sweep":{"min":{{SWEEP_MIN}},"max":{{SWEEP_MAX}},"steps":{{STEPS}},"step_duration":"{{STEP_DURATION}}"},"workload":{"type":"corpus","corpus_path":"{{LUSTRE_DATA}}/corpus/sharegpt.txt","isl":{{ISL}},"osl":{{OSL}},"turns":1}}' \
      --workers auto \
      --kube --kube.name {{NAME_PREFIX}}-sharegpt-load --kube.volume lustre --kube.image {{NYANN_IMAGE_TAG}} --kube.namespace {{NAMESPACE}} &
    go run ./cmd/nyann-bench/ generate \
      --target "{{EVAL_BASE_URL}}" \
      --config "{\"load\":{\"concurrency\":{{EVAL_CONCURRENCY}},\"duration\":\"${EVAL_DURATION}\"},\"workload\":{\"type\":\"gsm8k\",\"gsm8k_path\":\"{{LUSTRE_DATA}}/gsm8k_test.jsonl\",\"gsm8k_train_path\":\"{{LUSTRE_DATA}}/gsm8k_train.jsonl\"}}" \
      --kube --kube.name {{NAME_PREFIX}}-nyann-eval --kube.volume lustre --kube.image {{NYANN_IMAGE_TAG}} --kube.namespace {{NAMESPACE}} &
    wait
    echo "nyann-bench jobs submitted. Use 'just nyann-logs {{NAME_PREFIX}}-sharegpt-load' or 'just nyann-logs {{NAME_PREFIX}}-nyann-eval' to follow."

benchmark-constant CONCURRENCY='14400' DURATION='600s' ISL='500' OSL='1500' EVAL_CONCURRENCY='16':
    #!/usr/bin/env bash
    set -euo pipefail
    if [ -z "{{NYANN_BENCH_DIR}}" ]; then
      echo "Error: NYANN_BENCH_DIR is not set. Add it to .env or export it." >&2
      exit 1
    fi
    cd "{{NYANN_BENCH_DIR}}"
    go run ./cmd/nyann-bench/ generate \
      --target "{{EVAL_BASE_URL}}" \
      --config '{"load":{"concurrency":{{CONCURRENCY}},"duration":"{{DURATION}}","rampup":"30s"},"warmup":{"duration":"60s","stagger":true},"workload":{"type":"corpus","corpus_path":"{{LUSTRE_DATA}}/corpus/sharegpt.txt","isl":{{ISL}},"osl":{{OSL}},"turns":1}}' \
      --workers auto \
      --kube --kube.name {{NAME_PREFIX}}-sharegpt-load --kube.volume lustre --kube.image {{NYANN_IMAGE_TAG}} --kube.namespace {{NAMESPACE}} &
    go run ./cmd/nyann-bench/ generate \
      --target "{{EVAL_BASE_URL}}" \
      --config '{"load":{"concurrency":{{EVAL_CONCURRENCY}},"duration":"{{DURATION}}"},"workload":{"type":"gsm8k","gsm8k_path":"{{LUSTRE_DATA}}/gsm8k_test.jsonl","gsm8k_train_path":"{{LUSTRE_DATA}}/gsm8k_train.jsonl"}}' \
      --kube --kube.name {{NAME_PREFIX}}-nyann-eval --kube.volume lustre --kube.image {{NYANN_IMAGE_TAG}} --kube.namespace {{NAMESPACE}} &
    wait
    echo "nyann-bench jobs submitted. Use 'just nyann-logs {{NAME_PREFIX}}-sharegpt-load' or 'just nyann-logs {{NAME_PREFIX}}-nyann-eval' to follow."

# Stop nyann-bench benchmark jobs
stop-nyann:
  {{KN}} delete job -l app={{NAME_PREFIX}}-sharegpt-load --ignore-not-found=true &
  {{KN}} delete job -l app={{NAME_PREFIX}}-poker-eval --ignore-not-found=true &
  wait

# Tail nyann-bench job logs
nyann-logs NAME:
  {{KN}} logs -l app={{NAME}} -c nyann-bench --tail=50 -f --max-log-requests=20

# Query Prometheus for per-stage benchmark metrics (requires port-forward: just prometheus)
query-prometheus CLIENT_JOB=(NAME_PREFIX + "-sharegpt-load") DEPLOYMENT=DEPLOY_NAME EVAL_JOB=(NAME_PREFIX + "-poker-eval") *ARGS='':
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

# Get KV cache utilization across decode pods
kv-util:
  #!/usr/bin/env bash
  set -euo pipefail
  just get-decode-pods > /dev/null
  printf "%-40s %8s %6s %6s %6s\n" "POD/ENGINE" "KV_UTIL" "RUN" "WAIT" "CAP"
  printf "%-40s %8s %6s %6s %6s\n" "----------" "-------" "---" "----" "---"
  while read -r POD_NAME POD_IP; do
    {{KN}} exec "$POD_NAME" -c vllm -- curl -s http://localhost:8200/metrics 2>/dev/null \
      | awk -F'[{} ]' '
        /^vllm:kv_cache_usage_perc/    { split($2,a,"\""); kv[a[2]] = $NF }
        /^vllm:num_requests_running\{/ { split($2,a,"\""); run[a[2]] = $NF }
        /^vllm:num_requests_waiting\{engine/ { split($2,a,"\""); wait[a[2]] = $NF }
        /^vllm:num_requests_waiting_by_reason.*reason="capacity"/ { split($2,a,"\""); cap[a[2]] = $NF }
        END {
          for (e in kv) {
            printf "%-40s %7.1f%% %6.0f %6.0f %6.0f\n", "'"$POD_NAME"'/e" e, kv[e]*100, run[e], wait[e], cap[e]
          }
        }' | sort
  done < .tmp/decode_pods.txt

# Get peak KV cache utilization across all decode engines
kv-max:
  #!/usr/bin/env bash
  set -euo pipefail
  curl -s 'http://localhost:9090/api/v1/query' \
    --data-urlencode 'query=max(vllm:kv_cache_usage_perc{pod=~"{{DEPLOY_NAME}}-decode.*"})' \
    | jq -r '.data.result[0].value[1] // "0"' \
    | awk '{printf "%.1f%%\n", $1*100}'


# === KV Cache Sweep ===

KV_SWEEP_IMAGE := "quay.io/tms/llm-d-cuda-dev:ef2c4f7"
KV_SWEEP_MODEL := "nvidia/DeepSeek-R1-0528-NVFP4-v2"
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
