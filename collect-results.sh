#!/usr/bin/env bash
# Collect benchmark results into CSV.
# Usage: ./collect-results.sh [RESULTS_DIR]
#   ./collect-results.sh                              # all results
#   ./collect-results.sh results/workload-sweep-...   # specific run
#
# Requires: prometheus port-forward on localhost:9090

PROM="${PROMETHEUS_URL:-http://localhost:9090}"
DEPLOY_NAME="${USER}-wide-ep"
RESULTS_PATH="${1:-results/*}"

echo "run,start_time,end_time,requests,ok,errors,rps,input_tps,output_tps,ttft_p50_ms,ttft_p90_ms,ttft_p99_ms,ttft_min_ms,itl_p50_ms,itl_p90_ms,itl_p99_ms,e2e_p50_ms,e2e_p90_ms,e2e_p99_ms,prom_prefill_tps,prom_decode_tps,prom_cache_hit_rate"

for d in $RESULTS_PATH/*/logs.txt; do
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
start_t = int(stages[0]['start_time']) if stages else 0
end_t = int(stages[-1]['end_time']) if stages else 0
start = str(start_t)
end = str(end_t)
dur = f'{end_t - start_t}s'

# Query prometheus using increase() over the full benchmark duration
def prom_query(query):
    if not end_t:
        return '0'
    try:
        import urllib.request, urllib.parse
        url = '${PROM}/api/v1/query?' + urllib.parse.urlencode({
            'query': query,
            'time': end
        })
        resp = json.loads(urllib.request.urlopen(url, timeout=5).read())
        result = resp.get('data', {}).get('result', [])
        return result[0]['value'][1] if result else '0'
    except:
        return '0'

deploy = '${DEPLOY_NAME}'
# Total tokens over the run, divided by seconds for per-second rates
pf_tps = prom_query(f'sum(increase(vllm:prompt_tokens_total{{pod=~\"{deploy}-prefill.*\"}}[{dur}])) / {end_t - start_t}')
dec_tps = prom_query(f'sum(increase(vllm:generation_tokens_total{{pod=~\"{deploy}-decode.*\"}}[{dur}])) / {end_t - start_t}')
cache_hit = prom_query(f'sum(increase(vllm:prompt_tokens_cached_total{{pod=~\"{deploy}-prefill.*\"}}[{dur}])) / clamp_min(sum(increase(vllm:prompt_tokens_total{{pod=~\"{deploy}-prefill.*\"}}[{dur}])),1)')

secs = (end_t - start_t) or 1
input_tps = j.get('total_prompt_tokens', 0) / secs
print(f'$tag,{start},{end},{j[\"total_requests\"]},{j.get(\"successful_requests\",0)},{j.get(\"error_requests\",0)},{j.get(\"requests_per_second\",0)},{input_tps},{j.get(\"output_tokens_per_second\",0)},{ttft.get(\"p50\",0)},{ttft.get(\"p90\",0)},{ttft.get(\"p99\",0)},{ttft.get(\"min\",0)},{itl.get(\"p50\",0)},{itl.get(\"p90\",0)},{itl.get(\"p99\",0)},{e2e.get(\"p50\",0)},{e2e.get(\"p90\",0)},{e2e.get(\"p99\",0)},{pf_tps},{dec_tps},{cache_hit}')
" 2>/dev/null
done
