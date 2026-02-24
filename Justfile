set dotenv-load
set dotenv-required

NAMESPACE := "vllm"
HF_TOKEN := "$HF_TOKEN"
GH_TOKEN := "$GH_TOKEN"

KN := "kubectl -n " + NAMESPACE
NVIDIA_KUBECONFIG := "$NVIDIA_KUBECONFIG"
KN_FP4 := "kubectl --kubeconfig " + NVIDIA_KUBECONFIG + " -n " + NAMESPACE

GB200_DIR := "gb200-pure-decode"
EXAMPLE_DIR := "llm-d/guides/wide-ep-lws"
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

create-secrets:
  kubectl create secret generic hf-secret --from-literal=HF_TOKEN={{HF_TOKEN}} -n {{NAMESPACE}} \
  && kubectl create secret generic gh-token-secret --from-literal=GH_TOKEN={{GH_TOKEN}} -n {{NAMESPACE}}

start-poker:
  #!/usr/bin/env bash
  export POKER_IMAGE="{{env_var('POKER_IMAGE')}}"
  export POKER_TAG="{{env_var('POKER_TAG')}}"

  # Use nvidia kubeconfig if available, otherwise default
  if [[ -n "${NVIDIA_KUBECONFIG:-}" ]]; then
    KUBECTL_CMD="kubectl --kubeconfig {{NVIDIA_KUBECONFIG}} -n {{NAMESPACE}}"
  else
    KUBECTL_CMD="{{KN}}"
  fi

  envsubst '${POKER_IMAGE} ${POKER_TAG}' < poker/poker.yaml | $KUBECTL_CMD apply -f -

# Fetch decode pod names and IPs and cache them
get-decode-pods:
  #!/usr/bin/env bash
  set -euo pipefail
  mkdir -p ./.tmp
  echo "Fetching decode pod information..."
  {{KN}} get pods -o json | jq -r '.items[] | select(.metadata.name | contains("decode")) | "\(.metadata.name) \(.status.podIP)"' > .tmp/decode_pods.txt
  echo "Decode pods:"
  cat .tmp/decode_pods.txt

poke:
  #!/usr/bin/env bash
  set -euo pipefail
  mkdir -p ./.tmp

  # Use nvidia kubeconfig if available, otherwise default
  if [[ -n "${NVIDIA_KUBECONFIG:-}" ]]; then
    KUBECTL_CMD="kubectl --kubeconfig {{NVIDIA_KUBECONFIG}} -n {{NAMESPACE}}"
  else
    KUBECTL_CMD="{{KN}}"
  fi

  # Fetch configs locally and save to files
  echo "Fetching deployment configs locally..."
  cat llm-d/guides/wide-ep-lws/manifests/modelserver/gb200_dsv31_fp4/decode.yaml 2>/dev/null > .tmp/decode_config.yaml || echo "decode config not found" > .tmp/decode_config.yaml
  cat llm-d/guides/wide-ep-lws/manifests/modelserver/gb200_dsv31_fp4/prefill.yaml 2>/dev/null > .tmp/prefill_config.yaml || echo "prefill config not found" > .tmp/prefill_config.yaml

  # Export variables for envsubst
  export BASE_URL="http://wide-ep-gb200-inference-gateway-istio.{{NAMESPACE}}.svc.cluster.local"
  export NAMESPACE="{{NAMESPACE}}"
  export GRAFANA_URL="http://grafana.vllm.svc.cluster.local"

  envsubst '${BASE_URL} ${NAMESPACE} ${GRAFANA_URL}' < Justfile.remote > .tmp/Justfile.remote.tmp
  $KUBECTL_CMD cp .tmp/Justfile.remote.tmp poker:/app/Justfile
  $KUBECTL_CMD cp annotate.sh poker:/app/annotate.sh
  $KUBECTL_CMD cp .tmp/decode_config.yaml poker:/app/decode_config.yaml
  $KUBECTL_CMD cp .tmp/prefill_config.yaml poker:/app/prefill_config.yaml
  $KUBECTL_CMD exec -it poker -- chmod +x /app/annotate.sh
  $KUBECTL_CMD exec -it poker -- /bin/zsh


# Wait for poker + model serving pods to be ready, then run `just eval` from poker
auto-eval:
  #!/usr/bin/env bash
  set -euo pipefail
  mkdir -p ./.tmp

  if [[ -n "${NVIDIA_KUBECONFIG:-}" ]]; then
    KUBECTL_CMD="kubectl --kubeconfig {{NVIDIA_KUBECONFIG}} -n {{NAMESPACE}}"
  else
    KUBECTL_CMD="{{KN}}"
  fi

  echo "Waiting for poker pod..."
  until $KUBECTL_CMD get pod poker &>/dev/null; do sleep 5; done
  $KUBECTL_CMD wait --for=condition=Ready pod/poker --timeout=300s
  echo "Poker pod is ready."

  echo "Waiting for decode pods..."
  until $KUBECTL_CMD get pods -l llm-d.ai/role=decode --no-headers 2>/dev/null | grep -q .; do sleep 10; done
  $KUBECTL_CMD wait --for=condition=Ready pods -l llm-d.ai/role=decode --timeout=1800s
  echo "Decode pods are ready."

  echo "Waiting for prefill pods..."
  until $KUBECTL_CMD get pods -l llm-d.ai/role=prefill --no-headers 2>/dev/null | grep -q .; do sleep 10; done
  $KUBECTL_CMD wait --for=condition=Ready pods -l llm-d.ai/role=prefill --timeout=1800s
  echo "Prefill pods are ready."

  # Set up poker pod (same as poke)
  echo "Fetching deployment configs locally..."
  cat llm-d/guides/wide-ep-lws/manifests/modelserver/gb200_dsv31_fp4/decode.yaml 2>/dev/null > .tmp/decode_config.yaml || echo "decode config not found" > .tmp/decode_config.yaml
  cat llm-d/guides/wide-ep-lws/manifests/modelserver/gb200_dsv31_fp4/prefill.yaml 2>/dev/null > .tmp/prefill_config.yaml || echo "prefill config not found" > .tmp/prefill_config.yaml

  export BASE_URL="http://llm-d-inference-gateway-istio.{{NAMESPACE}}.svc.cluster.local"
  export NAMESPACE="{{NAMESPACE}}"
  export GRAFANA_URL="http://grafana.vllm.svc.cluster.local"

  envsubst '${BASE_URL} ${NAMESPACE} ${GRAFANA_URL}' < Justfile.remote > .tmp/Justfile.remote.tmp
  $KUBECTL_CMD cp .tmp/Justfile.remote.tmp poker:/app/Justfile
  $KUBECTL_CMD cp annotate.sh poker:/app/annotate.sh
  $KUBECTL_CMD cp .tmp/decode_config.yaml poker:/app/decode_config.yaml
  $KUBECTL_CMD cp .tmp/prefill_config.yaml poker:/app/prefill_config.yaml
  $KUBECTL_CMD exec poker -- chmod +x /app/annotate.sh

  echo "All pods ready. Running eval..."
  $KUBECTL_CMD exec poker -- just eval

parallel-guidellm RR CONCURRENT_PER_WORKER REQUESTS_PER_WORKER INPUT_LEN OUTPUT_LEN N_WORKERS:
  #!/usr/bin/env bash
  set -euo pipefail
  if [[ -n "${NVIDIA_KUBECONFIG:-}" ]]; then
    KUBECTL_CMD="kubectl --kubeconfig {{NVIDIA_KUBECONFIG}} -n {{NAMESPACE}}"
  else
    KUBECTL_CMD="{{KN}}"
  fi
  $KUBECTL_CMD delete job parallel-guidellm --ignore-not-found=true
  env \
    N_WORKERS={{N_WORKERS}} \
    MAX_CONCURRENCY={{CONCURRENT_PER_WORKER}} \
    NUM_REQUESTS={{REQUESTS_PER_WORKER}} \
    RATE={{RR}} \
    INPUT_LEN={{INPUT_LEN}} \
    OUTPUT_LEN={{OUTPUT_LEN}} \
    BASE_URL="http://llm-d-inference-gateway-istio.vllm.svc.cluster.local" \
    OUTPUT_PATH="parallel-guidellm-$(date +%Y%m%d-%H%M%S)" \
    POKER_IMAGE="{{env_var('POKER_IMAGE')}}" \
    POKER_TAG="{{env_var('POKER_TAG')}}" \
    envsubst '${N_WORKERS} ${MAX_CONCURRENCY} ${NUM_REQUESTS} ${RATE} ${INPUT_LEN} ${OUTPUT_LEN} ${BASE_URL} ${OUTPUT_PATH} ${POKER_IMAGE} ${POKER_TAG}' \
      < parallel-guidellm.yaml | $KUBECTL_CMD apply -f -

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
  export INPUT_MEAN INPUT_MIN=$((INPUT_MEAN - INPUT_MEAN/5)) INPUT_MAX=$((INPUT_MEAN + INPUT_MEAN/5)) INPUT_STD=$((INPUT_MEAN/10))
  export OUTPUT_MEAN OUTPUT_MIN=$((OUTPUT_MEAN - OUTPUT_MEAN/5)) OUTPUT_MAX=$((OUTPUT_MEAN + OUTPUT_MEAN/5)) OUTPUT_STD=$((OUTPUT_MEAN/10))
  {{KN}} delete job inference-perf --ignore-not-found=true
  {{KN}} delete configmap inference-perf-config --ignore-not-found=true
  envsubst '${NUM_REQUESTS} ${NUM_WORKERS} ${WORKER_MAX_CONCURRENCY} ${CONCURRENCY} ${WARMUP_CONCURRENCY} ${WARMUP_REQUESTS} ${INPUT_MEAN} ${INPUT_MIN} ${INPUT_MAX} ${INPUT_STD} ${OUTPUT_MEAN} ${OUTPUT_MIN} ${OUTPUT_MAX} ${OUTPUT_STD}' \
    < inference-perf-job.yaml | {{KN}} apply -f -
  echo "inference-perf job submitted (concurrent, workers=${NUM_WORKERS} concurrency=${CONCURRENCY} warmup=${WARMUP_CONCURRENCY}x${WARMUP_REQUESTS} requests=${NUM_REQUESTS} input=${INPUT_MEAN} output=${OUTPUT_MEAN})"
  echo "  kubectl -n {{NAMESPACE}} logs -f job/inference-perf"

# Get inference-perf results
inference-perf-logs:
  {{KN}} logs -f job/inference-perf

deploy_inferencepool ROUTING='load-aware':
  helm upgrade --install wide-ep-gb200-infpool \
    oci://registry.k8s.io/gateway-api-inference-extension/charts/inferencepool \
    --version v1.2.0 \
    -f {{GB200_DIR}}/inferencepool-{{ROUTING}}.values.yaml \
    -n {{NAMESPACE}}

VLLM_DEV_VENV := "/mnt/lustre/tms/vllm-venv"

start ROUTING='load-aware' DEV='false':
  #!/usr/bin/env bash
  set -euo pipefail
  {{KN}} apply -k {{GB200_DIR}}
  {{KN}} apply -f {{GB200_DIR}}/gateway.yaml
  just deploy_inferencepool {{ROUTING}}
  {{KN}} apply -f {{GB200_DIR}}/httproute.yaml
  if [ "{{DEV}}" = "true" ]; then
    echo "Patching decode-bench for dev mode (VLLM_DEV_VENV={{VLLM_DEV_VENV}})..."
    {{KN}} patch lws wide-ep-gb200-decode-bench --type=json \
      -p '[{"op":"replace","path":"/spec/leaderWorkerTemplate/workerTemplate/spec/containers/0/env/0","value":{"name":"VLLM_DEV_VENV","value":"{{VLLM_DEV_VENV}}"}}]'
  fi

stop:
  helm uninstall wide-ep-gb200-infpool -n {{NAMESPACE}} 2>/dev/null || true \
  && {{KN}} delete -f {{GB200_DIR}}/httproute.yaml --ignore-not-found=true \
  && {{KN}} delete -f {{GB200_DIR}}/gateway.yaml --ignore-not-found=true \
  && {{KN}} delete -k {{GB200_DIR}} --ignore-not-found=true \
  && {{KN}} delete job parallel-guidellm --ignore-not-found=true \
  && {{KN}} delete job inference-perf --ignore-not-found=true \
  && {{KN}} delete configmap inference-perf-config --ignore-not-found=true

restart ROUTING='load-aware' DEV='false':
  just stop && just start {{ROUTING}} {{DEV}}

# === Dev Environment ===

# Deploy the persistent dev pod (CPU-only, for editing/compiling vLLM on Lustre)
dev-start:
  {{KN}} apply -f {{DEV_DIR}}/dev-pod.yaml

# Exec into the dev pod
dev:
  {{KN}} exec -it vllm-dev -- /bin/bash

# Build vLLM from source on Lustre (runs in background, survives disconnects)
dev-build:
  {{KN}} exec vllm-dev -- bash -c 'source {{VLLM_DEV_VENV}}/bin/activate && cd /mnt/lustre/tms/vllm-dev && nohup uv pip install --no-deps --no-build-isolation -e . > /mnt/lustre/tms/build.log 2>&1 & echo "Build started (PID $$!), follow with: just dev-build-log"'

# Tail the dev build log
dev-build-log:
  {{KN}} exec vllm-dev -- tail -f /mnt/lustre/tms/build.log

# Delete the dev pod
dev-stop:
  {{KN}} delete -f {{DEV_DIR}}/dev-pod.yaml --ignore-not-found=true

# Flush vLLM/FlashInfer compile caches on Lustre (run after image or config changes)
flush-cache:
  {{KN}} exec vllm-dev -- bash -c 'rm -rf /mnt/lustre/tms/vllm_cache_extdp /mnt/lustre/tms/flashinfer_cache_extdp && echo "Compile caches flushed"'

start-fp4:
  cd {{EXAMPLE_DIR}} && {{KN_FP4}} apply -k ./manifests/modelserver/gb200_dsv31_fp4

stop-fp4:
  cd {{EXAMPLE_DIR}} && {{KN_FP4}} delete -k ./manifests/modelserver/gb200_dsv31_fp4 --ignore-not-found=true

restart-fp4:
  just stop-fp4 && just start-fp4

# Copy PyTorch traces from all decode pods to local ./traces/N directory
copy-traces:
  #!/usr/bin/env bash
  set -euo pipefail

  # Ensure we have fresh pod info
  if [ ! -f .tmp/decode_pods.txt ]; then
    echo "Pod info not cached, fetching..."
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
    {{KN}} cp "$POD_NAME:/traces" "$POD_DIR" 2>/dev/null || echo "  No traces found in $POD_NAME or copy failed"
  done < .tmp/decode_pods.txt

  echo "Traces copied to $TRACE_DIR"
  if [ -d "$TRACE_DIR" ]; then
    echo "Total size: $(du -sh $TRACE_DIR | cut -f1)"
  fi
  echo "Run 'just process-traces $N' to combine and fix for Perfetto"

# Combine per-rank traces and fix Perfetto overlaps
process-traces N='':
  #!/usr/bin/env bash
  set -euo pipefail
  if [ -z "{{N}}" ]; then
    # Find the latest trace directory
    N=$(ls -d ./traces/[0-9]* 2>/dev/null | sort -t/ -k3 -n | tail -1 | xargs basename)
    if [ -z "$N" ]; then
      echo "No trace directories found in ./traces/"
      exit 1
    fi
  fi
  echo "Processing traces/$N ..."
  python3 profiling/process_traces.py "traces/$N"

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

# Load llm-d Grafana dashboards
load-dashboards:
  #!/usr/bin/env bash
  set -euo pipefail
  for DASHBOARD_DIR in "llm-d/docs/monitoring/grafana/dashboards" "{{MONITORING_DIR}}"; do
    for f in "$DASHBOARD_DIR"/*.json; do
      [ -f "$f" ] || continue
      NAME=$(basename "$f" .json)
      echo "Creating ConfigMap for dashboard: $NAME"
      {{KN}} create configmap "grafana-dashboard-$NAME" --from-file="$NAME.json=$f" --dry-run=client -o yaml | \
        {{KN}} label -f - --local -o yaml grafana_dashboard=1 | \
        {{KN}} apply -f -
    done
  done
  echo "Dashboards loaded. Grafana will auto-discover them within 30 seconds."
