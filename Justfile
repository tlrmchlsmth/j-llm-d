set dotenv-load
set dotenv-required

NAMESPACE := "tms-llm-d-wide-ep"
HF_TOKEN := "$HF_TOKEN"
GH_TOKEN := "$GH_TOKEN"

MODEL := "deepseek-ai/DeepSeek-R1-0528"

KN := "kubectl -n tms-llm-d-wide-ep"

EXAMPLE_DIR := "llm-d/guides/wide-ep-lws"

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

start-bench:
    {{KN}} apply -f benchmark-interactive-pod.yaml
  
poke:
  mkdir -p ./.tmp \
  && echo "MODEL := \"{{MODEL}}\"" > .tmp/Justfile.remote.tmp \
  && sed -e 's#__BASE_URL__#\"http://wide-ep-inference-gateway-istio.tms-llm-d-wide-ep.svc.cluster.local\"#g' Justfile.remote >> .tmp/Justfile.remote.tmp \
  && kubectl cp .tmp/Justfile.remote.tmp {{NAMESPACE}}/poker:/app/Justfile \
  && kubectl cp  ./run.sh {{NAMESPACE}}/poker:/app/run.sh \
  && {{KN}} exec -it poker -- /bin/zsh

run-bench NAME:
  mkdir -p ./.tmp \
  && echo $(date +%m%d%H%M) > .tmp/TIMESTAMP \
  && echo "{{NAME}}" > .tmp/NAME \
  && echo "MODEL := \"{{MODEL}}\"" > .tmp/Justfile.remote \
  && sed -e 's#__BASE_URL__#\"http://wide-ep-inference-gateway-istio.tms-llm-d-wide-ep.svc.cluster.local\"#g' Justfile.remote >> .tmp/Justfile.remote \
  && kubectl cp .tmp/TIMESTAMP {{NAMESPACE}}/benchmark-interactive:/app/TIMESTAMP \
  && kubectl cp .tmp/NAME {{NAMESPACE}}/benchmark-interactive:/app/NAME \
  && kubectl cp .tmp/Justfile.remote {{NAMESPACE}}/benchmark-interactive:/app/Justfile \
  && kubectl cp  ./run.sh {{NAMESPACE}}/benchmark-interactive:/app/run.sh \
  && kubectl cp  ./ms-wide-ep/values.yaml {{NAMESPACE}}/benchmark-interactive:/app/values.yaml \
  && {{KN}} exec benchmark-interactive -- bash /app/run.sh

cp-results:
  kubectl cp benchmark-interactive:/app/results/$(cat ./.tmp/TIMESTAMP) \
    results/$(cat ./.tmp/TIMESTAMP)

start:
  cd {{EXAMPLE_DIR}} \
  && {{KN}} apply -k ./manifests/modelserver/coreweave \
  && helm install deepseek-r1 \
      -n {{NAMESPACE}} \
      -f inferencepool.values.yaml \
      oci://us-central1-docker.pkg.dev/k8s-staging-images/gateway-api-inference-extension/charts/inferencepool --version v1.0.0 \
  && {{KN}} apply -k ./manifests/gateway/istio \
  && {{KN}} apply -f ./destinationRule.yaml


stop:
  cd {{EXAMPLE_DIR}} \
  && helm uninstall deepseek-r1 || true \
  && {{KN}} delete -k ./manifests/modelserver/coreweave || true \
  && {{KN}} delete -k ./manifests/gateway/istio || true

restart:
  just stop && just start

print-results DIR STR:
  grep "{{STR}}" {{DIR}}/*.log \
    | awk -F'[/_]' '{print $3, $0}' \
    | sort -n \
    | cut -d' ' -f2-

print-throughput DIR:
  just print-results {{DIR}} "Output token throughput"

print-tpot DIR:
  just print-results {{DIR}} "Median TPOT"
