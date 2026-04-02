#!/usr/bin/env bash
set -euo pipefail
# Collect benchmark results into CSV.
# Usage: ./collect-results.sh [RESULTS_DIR]
#   ./collect-results.sh                              # all results
#   ./collect-results.sh results/workload-sweep-...   # specific run
#
# Requires: prometheus port-forward on localhost:9090

PROM="${PROMETHEUS_URL:-http://localhost:9090}"
DEPLOY_NAME="${USER}-wide-ep"
RESULTS_PATH="${1:-results/*}"

exec python3 - "$PROM" "$DEPLOY_NAME" $RESULTS_PATH <<'PYEOF'
import json, sys, os, glob
from concurrent.futures import ThreadPoolExecutor, as_completed
from urllib.request import urlopen
from urllib.parse import urlencode

PROM = sys.argv[1]
DEPLOY = sys.argv[2]
run_dirs = sys.argv[3:]

HEADER = "run,start_time,end_time,requests,ok,errors,rps,client_input_tps,client_output_tps,server_prefill_tps,server_decode_tps,cache_hit_rate,prefill_running,prefill_waiting,decode_running,decode_waiting,ttft_p50_ms,ttft_p90_ms,ttft_p99_ms,ttft_min_ms,itl_p50_ms,itl_p90_ms,itl_p99_ms,e2e_p50_ms,e2e_p90_ms,e2e_p99_ms"

def prom_query(query, time):
    url = f'{PROM}/api/v1/query?' + urlencode({'query': query, 'time': time})
    resp = json.loads(urlopen(url, timeout=10).read())
    if resp.get('status') != 'success':
        raise RuntimeError(f'Prometheus query failed: {resp}')
    result = resp['data']['result']
    if not result:
        raise RuntimeError(f'No data for query: {query} at time={time}')
    return result[0]['value'][1]

def process_run(run_dir):
    logs = os.path.join(run_dir, 'logs.txt')
    if not os.path.isfile(logs) or os.path.getsize(logs) == 0:
        return None
    tag = os.path.basename(run_dir)

    text = open(logs).read()
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
        return None

    # Sum totals and rates across workers
    total_requests = sum(w['total_requests'] for w in workers)
    ok = sum(w.get('successful_requests', 0) for w in workers)
    errors = sum(w.get('error_requests', 0) for w in workers)
    rps = sum(w.get('requests_per_second', 0) for w in workers)
    total_prompt = sum(w.get('total_prompt_tokens', 0) for w in workers)
    output_tps = sum(w.get('output_tokens_per_second', 0) for w in workers)

    # Weighted average latency percentiles
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

    # Timestamps
    all_stages = []
    for w in workers:
        all_stages.extend(w.get('timestamps', {}).get('stages', []))
    start_t = int(min(s['start_time'] for s in all_stages)) if all_stages else 0
    end_t = int(max(s['end_time'] for s in all_stages)) if all_stages else 0
    secs = (end_t - start_t) or 1
    dur = f'{secs}s'

    # Prometheus queries (3 queries per run, all in this thread)
    pf_tps = prom_query(
        f'sum(increase(vllm:prompt_tokens_total{{pod=~"{DEPLOY}-prefill.*"}}[{dur}])) / {secs}',
        end_t)
    dec_tps = prom_query(
        f'sum(increase(vllm:generation_tokens_total{{pod=~"{DEPLOY}-decode.*"}}[{dur}])) / {secs}',
        end_t)
    cache_hit = prom_query(
        f'sum(increase(vllm:prompt_tokens_cached_total{{pod=~"{DEPLOY}-prefill.*"}}[{dur}])) / clamp_min(sum(increase(vllm:prompt_tokens_total{{pod=~"{DEPLOY}-prefill.*"}}[{dur}])),1)',
        end_t)
    # Gauge metrics: avg over the benchmark window
    pf_running = prom_query(
        f'avg_over_time(sum(vllm:num_requests_running{{pod=~"{DEPLOY}-prefill.*"}})[{dur}:10s])',
        end_t)
    pf_waiting = prom_query(
        f'avg_over_time(sum(vllm:num_requests_waiting{{pod=~"{DEPLOY}-prefill.*"}})[{dur}:10s])',
        end_t)
    dec_running = prom_query(
        f'avg_over_time(sum(vllm:num_requests_running{{pod=~"{DEPLOY}-decode.*"}})[{dur}:10s])',
        end_t)
    dec_waiting = prom_query(
        f'avg_over_time(sum(vllm:num_requests_waiting{{pod=~"{DEPLOY}-decode.*"}})[{dur}:10s])',
        end_t)

    client_input_tps = total_prompt / secs
    return f'{tag},{start_t},{end_t},{total_requests},{ok},{errors},{rps},{client_input_tps},{output_tps},{pf_tps},{dec_tps},{cache_hit},{pf_running},{pf_waiting},{dec_running},{dec_waiting},{ttft_p50},{ttft_p90},{ttft_p99},{ttft_min},{itl_p50},{itl_p90},{itl_p99},{e2e_p50},{e2e_p90},{e2e_p99}'

# Find all run directories
dirs = []
for d in run_dirs:
    for sub in sorted(glob.glob(os.path.join(d, '*'))):
        if os.path.isdir(sub):
            dirs.append(sub)

# Process all runs in parallel
print(HEADER)
results = {}
with ThreadPoolExecutor(max_workers=len(dirs) or 1) as pool:
    futures = {pool.submit(process_run, d): d for d in dirs}
    for f in as_completed(futures):
        d = futures[f]
        results[d] = f.result()  # raises on error

# Print in sorted order
for d in sorted(results):
    if results[d]:
        print(results[d])
PYEOF
