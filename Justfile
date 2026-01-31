set dotenv-load
set dotenv-required

NAMESPACE := "vllm"
HF_TOKEN := "$HF_TOKEN"
GH_TOKEN := "$GH_TOKEN"


KN := "kubectl -n " + NAMESPACE

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
    {{KN}} apply -f poker/poker.yaml

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
  just get-decode-pods
  mkdir -p ./.tmp

  # Export variables for envsubst
  export BASE_URL="http://llm-d-inference-gateway-istio.{{NAMESPACE}}.svc.cluster.local"
  export DECODE_POD_IPS=$(cat .tmp/decode_pods.txt | awk '{print $2}' | tr '\n' ' ')

  echo "Injecting decode pod IPs into Justfile: $DECODE_POD_IPS"

  envsubst '${BASE_URL} ${DECODE_POD_IPS}' < Justfile.remote > .tmp/Justfile.remote.tmp
  kubectl cp .tmp/Justfile.remote.tmp {{NAMESPACE}}/poker:/app/Justfile
  {{KN}} exec -it poker -- /bin/zsh


parallel-guidellm CONCURRENT_PER_WORKER='4000' REQUESTS_PER_WORKER='4000' INPUT_LEN='128' OUTPUT_LEN='1000' N_WORKERS='4':
  {{KN}} delete job parallel-guidellm --ignore-not-found=true \
  && env \
    N_WORKERS={{N_WORKERS}} \
    MAX_CONCURRENCY={{CONCURRENT_PER_WORKER}} \
    NUM_REQUESTS={{REQUESTS_PER_WORKER}} \
    INPUT_LEN={{INPUT_LEN}} \
    OUTPUT_LEN={{OUTPUT_LEN}} \
    OUTPUT_PATH="parallel-guidellm-$(date +%Y%m%d-%H%M%S)" \
    envsubst '${N_WORKERS} ${MAX_CONCURRENCY} ${NUM_REQUESTS} ${INPUT_LEN} ${OUTPUT_LEN} ${OUTPUT_PATH}' \
      < parallel-guidellm.yaml | kubectl apply -f -

deploy_inferencepool:
  cd {{EXAMPLE_DIR}} && \
  helm install llm-d-infpool \
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
