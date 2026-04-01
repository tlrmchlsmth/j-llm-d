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

echo "run,start_time,end_time,requests,ok,errors,rps,output_tps,ttft_mean_ms,ttft_p50_ms,ttft_p90_ms,ttft_p99_ms,ttft_min_ms,ttft_max_ms,itl_mean_ms,itl_p50_ms,e2e_mean_ms,e2e_p50_ms,prom_prefill_tps,prom_decode_tps,prom_cache_hit_rate"

for d in results/*/*/logs.txt; do
  [ -s "$d" ] || continue
  tag=$(basename "$(dirname "$d")")

  python3 -c "
import json, sys, subprocess

text = open('$d').read()
# Find the last JSON block (the summary object)
idx = text.rfind('{')
j = None
while idx >= 0:
    try:
        j = json.loads(text[idx:])
        if 'total_requests' in j:
            break
        j = None
    except:
        pass
    idx = text.rfind('{', 0, idx)

if not j:
    sys.exit(0)

ttft = j.get('ttft_ms', {})
itl = j.get('itl_ms', {})
e2e = j.get('e2e_latency_ms', {})
ts = j.get('timestamps', {})
stages = ts.get('stages', [])
start = str(int(stages[0]['start_time'])) if stages else ''
end = str(int(stages[-1]['end_time'])) if stages else ''

# Query prometheus for server-side metrics
def prom_query(query, end_t):
    if not end_t:
        return '0'
    try:
        import urllib.request, urllib.parse
        url = '${PROM}/api/v1/query?' + urllib.parse.urlencode({
            'query': f'avg_over_time(({query})[180s:10s])',
            'time': end_t
        })
        resp = json.loads(urllib.request.urlopen(url, timeout=5).read())
        result = resp.get('data', {}).get('result', [])
        return result[0]['value'][1] if result else '0'
    except:
        return '0'

deploy = '${DEPLOY_NAME}'
pf_tps = prom_query(f'sum(rate(vllm:prompt_tokens_total{{pod=~\"{deploy}-prefill.*\"}}[30s]))', end)
dec_tps = prom_query(f'sum(rate(vllm:generation_tokens_total{{pod=~\"{deploy}-decode.*\"}}[30s]))', end)
cache_hit = prom_query(f'sum(rate(vllm:prompt_tokens_cached_total{{pod=~\"{deploy}-prefill.*\"}}[30s])) / clamp_min(sum(rate(vllm:prompt_tokens_total{{pod=~\"{deploy}-prefill.*\"}}[30s])),1)', end)

print(f'$tag,{start},{end},{j[\"total_requests\"]},{j.get(\"successful_requests\",0)},{j.get(\"error_requests\",0)},{j.get(\"requests_per_second\",0)},{j.get(\"output_tokens_per_second\",0)},{ttft.get(\"mean\",0)},{ttft.get(\"p50\",0)},{ttft.get(\"p90\",0)},{ttft.get(\"p99\",0)},{ttft.get(\"min\",0)},{ttft.get(\"max\",0)},{itl.get(\"mean\",0)},{itl.get(\"p50\",0)},{e2e.get(\"mean\",0)},{e2e.get(\"p50\",0)},{pf_tps},{dec_tps},{cache_hit}')
" 2>/dev/null
done
