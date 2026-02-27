#!/usr/bin/env bash
set -euo pipefail

DIR="${1:-.}"

HEADER="qps"
HEADER="$HEADER,successful_requests,failed_requests,request_rate_rps,benchmark_duration_s"
HEADER="$HEADER,total_input_tokens,total_generated_tokens"
HEADER="$HEADER,request_throughput_rps,output_token_throughput_tps,peak_output_token_throughput_tps"
HEADER="$HEADER,peak_concurrent_requests,total_token_throughput_tps"
HEADER="$HEADER,mean_ttft_ms,median_ttft_ms,p99_ttft_ms"
HEADER="$HEADER,mean_tpot_ms,median_tpot_ms,p99_tpot_ms"
HEADER="$HEADER,mean_itl_ms,median_itl_ms,p99_itl_ms"
printf "%s\n" "$HEADER"

for f in "$DIR"/result_qps*.txt; do
    [ -f "$f" ] || continue
    qps=$(basename "$f" | sed 's/result_qps\([0-9]*\)\.txt/\1/')

    block=$(awk '/============ Serving Benchmark Result ============/{found=1} found' "$f")

    extract() { echo "$block" | grep "$1" | head -1 | awk -F: '{print $2}' | tr -d ' '; }

    vals=$(printf "%s" "$qps")
    vals="$vals,$(extract 'Successful requests')"
    vals="$vals,$(extract 'Failed requests')"
    vals="$vals,$(extract 'Request rate configured')"
    vals="$vals,$(extract 'Benchmark duration')"
    vals="$vals,$(extract 'Total input tokens')"
    vals="$vals,$(extract 'Total generated tokens')"
    vals="$vals,$(extract 'Request throughput')"
    vals="$vals,$(extract 'Output token throughput')"
    vals="$vals,$(extract 'Peak output token throughput')"
    vals="$vals,$(extract 'Peak concurrent requests')"
    vals="$vals,$(extract 'Total token throughput')"
    vals="$vals,$(extract 'Mean TTFT')"
    vals="$vals,$(extract 'Median TTFT')"
    vals="$vals,$(extract 'P99 TTFT')"
    vals="$vals,$(extract 'Mean TPOT')"
    vals="$vals,$(extract 'Median TPOT')"
    vals="$vals,$(extract 'P99 TPOT')"
    vals="$vals,$(extract 'Mean ITL')"
    vals="$vals,$(extract 'Median ITL')"
    vals="$vals,$(extract 'P99 ITL')"

    printf "%s\n" "$vals"
done | sort -t, -k1 -n
