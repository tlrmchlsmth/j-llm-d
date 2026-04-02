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

echo "run,start_time,end_time,requests,ok,errors,rps,client_input_tps,client_output_tps,server_prefill_tps,server_decode_tps,cache_hit_rate,ttft_p50_ms,ttft_p90_ms,ttft_p99_ms,ttft_min_ms,itl_p50_ms,itl_p90_ms,itl_p99_ms,e2e_p50_ms,e2e_p90_ms,e2e_p99_ms"

for d in $RESULTS_PATH/*/logs.txt; do
  [ -s "$d" ] || continue
  tag=$(basename "$(dirname "$d")")

  python3 -c "
import json, sys

text = open('$d').read()
# Find ALL JSON summary blocks (one per worker)
decoder = json.JSONDecoder()
workers = []
idx = 0
while True:
    idx = text.find('{', idx)
    if idx < 0:
        break
    try:
        j, end = decoder.raw_decode(text, idx)
        if 'total_requests' in j:
            workers.append(j)
        idx = end
    except:
        idx += 1

if not workers:
    sys.exit(0)

n = len(workers)

# Sum totals and rates across workers
total_requests = sum(w['total_requests'] for w in workers)
ok = sum(w.get('successful_requests', 0) for w in workers)
errors = sum(w.get('error_requests', 0) for w in workers)
rps = sum(w.get('requests_per_second', 0) for w in workers)
total_prompt = sum(w.get('total_prompt_tokens', 0) for w in workers)
total_output = sum(w.get('total_output_tokens', 0) for w in workers)
output_tps = sum(w.get('output_tokens_per_second', 0) for w in workers)

# Average latency percentiles across workers (weighted by request count)
def wavg(key, sub):
    vals = [(w.get(key, {}).get(sub, 0), w['total_requests']) for w in workers]
    total_w = sum(v[1] for v in vals)
    return sum(v[0] * v[1] for v in vals) / total_w if total_w else 0

ttft_p50 = wavg('ttft_ms', 'p50')
ttft_p90 = wavg('ttft_ms', 'p90')
ttft_p99 = wavg('ttft_ms', 'p99')
ttft_min = min(w.get('ttft_ms', {}).get('min', 0) for w in workers)
itl_p50 = wavg('itl_ms', 'p50')
itl_p90 = wavg('itl_ms', 'p90')
itl_p99 = wavg('itl_ms', 'p99')
e2e_p50 = wavg('e2e_latency_ms', 'p50')
e2e_p90 = wavg('e2e_latency_ms', 'p90')
e2e_p99 = wavg('e2e_latency_ms', 'p99')

# Timestamps: use earliest start, latest end across workers
all_stages = []
for w in workers:
    all_stages.extend(w.get('timestamps', {}).get('stages', []))
start_t = int(min(s['start_time'] for s in all_stages)) if all_stages else 0
end_t = int(max(s['end_time'] for s in all_stages)) if all_stages else 0
start = str(start_t)
end = str(end_t)
secs = (end_t - start_t) or 1
dur = f'{secs}s'

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

client_input_tps = total_prompt / secs
print(f'$tag,{start},{end},{total_requests},{ok},{errors},{rps},{client_input_tps},{output_tps},{pf_tps},{dec_tps},{cache_hit},{ttft_p50},{ttft_p90},{ttft_p99},{ttft_min},{itl_p50},{itl_p90},{itl_p99},{e2e_p50},{e2e_p90},{e2e_p99}')
" 2>/dev/null
done
