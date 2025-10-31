set dotenv-load
set dotenv-required

NAMESPACE := "tms-llm-d-wide-ep"
HF_TOKEN := "$HF_TOKEN"
GH_TOKEN := "$GH_TOKEN"

MODEL := "deepseek-ai/DeepSeek-R1-0528"

KN := "kubectl -n tms-llm-d-wide-ep"

EXAMPLE_DIR := "llm-d/guides/wide-ep-lws"

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
                 | ( .resources.limits."nvidia.com/gpu" \
                     // .resources.requests."nvidia.com/gpu" \
                     // "0" ) | tonumber ] | add) \
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
    {{KN}} apply -f poker.yaml
  
poke:
  mkdir -p ./.tmp \
  && echo "MODEL := \"{{MODEL}}\"" > .tmp/Justfile.remote.tmp \
  && sed -e 's#__BASE_URL__#\"http://wide-ep-inference-gateway-istio.tms-llm-d-wide-ep.svc.cluster.local\"#g' Justfile.remote >> .tmp/Justfile.remote.tmp \
  && kubectl cp .tmp/Justfile.remote.tmp {{NAMESPACE}}/poker:/app/Justfile \
  && {{KN}} exec -it poker -- /bin/zsh


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
  cd {{EXAMPLE_DIR}} \
  helm install deepseek-r1 \
    -n {{NAMESPACE}} \
    -f inferencepool.values.yaml \
    --set "provider.name=istio" \
    --set "inferenceExtension.monitoring.prometheus.enable=true" \
    oci://us-central1-docker.pkg.dev/k8s-staging-images/gateway-api-inference-extension/charts/inferencepool --version v1.0.1

start:
  cd {{EXAMPLE_DIR}} \
  && {{KN}} apply -k ./manifests/modelserver/coreweave \
  && just deploy_inferencepool \
  && {{KN}} apply -k ./manifests/gateway/istio

stop:
  cd {{EXAMPLE_DIR}} \
  && helm uninstall deepseek-r1 --ignore-not-found=true \
  && {{KN}} delete -k ./manifests/modelserver/coreweave --ignore-not-found=true \
  && {{KN}} delete -k ./manifests/gateway/istio --ignore-not-found=true \
  && {{KN}} delete job parallel-guidellm --ignore-not-found=true

restart:
  just stop && just start
