#!/usr/bin/env bash
# Collect all benchmark results into CSV. Pipe to pbcopy for clipboard.
# Usage: ./collect-results.sh | pbcopy
#
# Includes client-side metrics from nyann_poker logs AND server-side
# metrics from Prometheus (queried retroactively using benchmark timestamps).
#
# Requires: prometheus port-forward on localhost:9090

PROM="${PROMETHEUS_URL:-http://localhost:9090}"
DEPLOY_NAME="${USER}-wide-ep"

# Query a prometheus metric, averaged over a time range
prom_query() {
  local query="$1" start="$2" end="$3"
  curl -s --fail "${PROM}/api/v1/query" \
    --data-urlencode "query=avg_over_time(($query)[${end}s:10s] @ $end)" \
    --data-urlencode "time=$end" 2>/dev/null \
    | python3 -c "import sys,json; r=json.load(sys.stdin); print(r['data']['result'][0]['value'][1] if r['data']['result'] else '0')" 2>/dev/null || echo "0"
}

# Extract start_time, end_time from logs
get_timestamps() {
  python3 -c "
import json
for line in open('$1'):
    line = line.strip().rstrip(',')
    if not line.startswith('{'): continue
    try:
        j = json.loads(line)
    except: continue
    stages = j.get('stages', [])
    if stages:
        print(f'{stages[0][\"start_time\"]},{stages[-1][\"end_time\"]}')
        break
" 2>/dev/null
}

echo "run,requests,ok,errors,throughput_rps,output_tps,ttft_mean_ms,ttft_p50_ms,ttft_p90_ms,ttft_p99_ms,ttft_min_ms,ttft_max_ms,itl_mean_ms,itl_p50_ms,e2e_mean_ms,e2e_p50_ms,prom_prefill_tps,prom_decode_tps,prom_prefill_cache_hit_rate"

for d in results/*/*/logs.txt; do
  [ -s "$d" ] || continue
  tag=$(basename "$(dirname "$d")")

  # Client-side metrics from nyann_poker
  client_row=$(python3 -c "
import json
for line in open('$d'):
    line = line.strip().rstrip(',')
    if not line.startswith('{'): continue
    try:
        j = json.loads(line)
    except: continue
    if 'total_requests' not in j: continue
    t = j
    ttft = t.get('ttft_ms', {})
    itl = t.get('itl_ms', {})
    e2e = t.get('e2e_latency_ms', {})
    print(f'{t[\"total_requests\"]},{t[\"ok_requests\"]},{t[\"error_requests\"]},{t.get(\"throughput_rps\",0)},{t.get(\"output_tps\",0)},{ttft.get(\"mean\",0)},{ttft.get(\"p50\",0)},{ttft.get(\"p90\",0)},{ttft.get(\"p99\",0)},{ttft.get(\"min\",0)},{ttft.get(\"max\",0)},{itl.get(\"mean\",0)},{itl.get(\"p50\",0)},{e2e.get(\"mean\",0)},{e2e.get(\"p50\",0)}')
    break
" 2>/dev/null)

  [ -z "$client_row" ] && continue

  # Server-side metrics from Prometheus
  timestamps=$(get_timestamps "$d")
  if [ -n "$timestamps" ]; then
    IFS=',' read -r start_t end_t <<< "$timestamps"
    start_int=${start_t%.*}
    end_int=${end_t%.*}

    prefill_tps=$(prom_query "sum(rate(vllm:prompt_tokens_total{pod=~\"${DEPLOY_NAME}-prefill.*\"}[30s]))" "$start_int" "$end_int")
    decode_tps=$(prom_query "sum(rate(vllm:generation_tokens_total{pod=~\"${DEPLOY_NAME}-decode.*\"}[30s]))" "$start_int" "$end_int")
    cache_hit=$(prom_query "sum(rate(vllm:prefix_cache_hit_tokens_total{pod=~\"${DEPLOY_NAME}-prefill.*\"}[30s])) / clamp_min(sum(rate(vllm:prompt_tokens_total{pod=~\"${DEPLOY_NAME}-prefill.*\"}[30s])),1)" "$start_int" "$end_int")
  else
    prefill_tps=0
    decode_tps=0
    cache_hit=0
  fi

  echo "$tag,$client_row,$prefill_tps,$decode_tps,$cache_hit"
done
