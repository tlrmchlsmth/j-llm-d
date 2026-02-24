set dotenv-load
set dotenv-required

NAMESPACE := "vllm"
HF_TOKEN := "$HF_TOKEN"
GH_TOKEN := "$GH_TOKEN"


KN := "kubectl -n " + NAMESPACE
NVIDIA_KUBECONFIG := "$NVIDIA_KUBECONFIG"
KN_FP4 := "kubectl --kubeconfig " + NVIDIA_KUBECONFIG + " -n " + NAMESPACE

EXAMPLE_DIR := "llm-d/guides/wide-ep-lws"
GATEWAY_DIR := "llm-d/guides/recipes/gateway"

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
  export BASE_URL="http://llm-d-inference-gateway-istio.{{NAMESPACE}}.svc.cluster.local"
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

deploy_inferencepool KUBECONFIG_ARG="":
  cd {{EXAMPLE_DIR}} && \
  helm install llm-d-infpool \
    {{KUBECONFIG_ARG}} \
    -n {{NAMESPACE}} \
    -f manifests/inferencepool.values.yaml \
    --set "provider.name=istio" \
    --set "inferenceExtension.monitoring.prometheus.enabled=true" \
    oci://registry.k8s.io/gateway-api-inference-extension/charts/inferencepool --version v1.2.0

start:
  cd {{EXAMPLE_DIR}} \
  && {{KN}} apply -k ./manifests/modelserver/coreweave \
  && just deploy_inferencepool \
  && {{KN}} apply -k ../../recipes/gateway/istio

stop:
  cd {{EXAMPLE_DIR}} \
  && helm uninstall llm-d-infpool -n {{NAMESPACE}} --ignore-not-found=true \
  && {{KN}} delete -k ./manifests/modelserver/coreweave --ignore-not-found=true \
  && {{KN}} delete -k ../../recipes/gateway/istio --ignore-not-found=true \
  && {{KN}} delete job parallel-guidellm --ignore-not-found=true

restart:
  just stop && just start

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
