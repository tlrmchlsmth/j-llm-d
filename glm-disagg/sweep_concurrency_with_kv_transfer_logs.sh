#!/bin/bash

# Concurrency Sweep with vLLM Log Collection (auto-detects agg vs disagg)
# Usage: ./sweep_concurrency_with_kv_transfer_logs.sh <max_concurrency> <output_dir> [ISL] [OSL]
# Example: ./sweep_concurrency_with_kv_transfer_logs.sh 32 results/1p1d_16
#          ./sweep_concurrency_with_kv_transfer_logs.sh 1 results/isl_sweep 2048 256
#
# Writes to <output_dir>/:
#   result_mc<N>.txt   - benchmark output (also printed to terminal)
#   decode_mc<N>.log   - vLLM logs from the decode (or agg) pod
#   prefill_mc<N>.log  - vLLM logs from the prefill pod (disagg only)
#   metrics_mc<N>.txt  - Prometheus metric deltas (prefill pods for disagg, agg pod for agg)
#
# Auto-discovers model server pods in the namespace, detects whether the
# deployment is aggregated (glm-agg) or disaggregated (glm-disagg), runs
# a calibration + benchmark via the poker pod's `just sweep` recipe, captures
# vLLM logs for the duration, then stops.

set -euo pipefail

if [ $# -lt 2 ]; then
    echo "Usage: $0 <max_concurrency> <output_dir>"
    echo "Example: $0 32 results/1p1d_16"
    exit 1
fi

MC="$1"
OUT_DIR="$2"
NAMESPACE="raj-network-debug"
BENCHMARK_TIMEOUT_SEC=900

DECODE_LOG="$OUT_DIR/decode_mc${MC}.log"
PREFILL_LOG="$OUT_DIR/prefill_mc${MC}.log"
RESULT_LOG="$OUT_DIR/result_mc${MC}.txt"
METRICS_LOG="$OUT_DIR/metrics_mc${MC}.txt"

mkdir -p "$OUT_DIR"
exec > >(tee "$RESULT_LOG") 2>&1

echo ""
echo "=============================================="
echo "Discovering model server pods in namespace: $NAMESPACE"
echo "=============================================="

ALL_PODS=$(kubectl get pods -n "$NAMESPACE" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')

AGG_POD=$(echo "$ALL_PODS" | grep "^ms-glm-agg-llm-d-modelservice" | head -1 || true)
DISAGG_DECODE=$(echo "$ALL_PODS" | grep "^ms-glm-disagg-llm-d-modelservice-decode" | head -1 || true)
DISAGG_PREFILL=$(echo "$ALL_PODS" | grep "^ms-glm-disagg-llm-d-modelservice-prefill" | head -1 || true)

if [ -n "$DISAGG_DECODE" ]; then
    TARGET="glm-disagg"
    DECODE_POD="$DISAGG_DECODE"
    PREFILL_POD="$DISAGG_PREFILL"
    if [ -z "$PREFILL_POD" ]; then
        echo "WARNING: Disagg decode pod found but no prefill pod"
    fi
elif [ -n "$AGG_POD" ]; then
    TARGET="glm-agg"
    DECODE_POD="$AGG_POD"
    PREFILL_POD=""
else
    echo "ERROR: No model server pods found in namespace $NAMESPACE"
    exit 1
fi

echo "  Detected:     $TARGET"
echo "  Decode pod:   $DECODE_POD"
echo "  Decode log:   $DECODE_LOG"
if [ -n "$PREFILL_POD" ]; then
    echo "  Prefill pod:  $PREFILL_POD"
    echo "  Prefill log:  $PREFILL_LOG"
fi

METRICS_IPS=""
METRICS_PORT=8000
if [ "$TARGET" = "glm-disagg" ] && [ -n "${PREFILL_POD:-}" ]; then
    METRICS_IPS=$(kubectl get pods -n "$NAMESPACE" \
        -l "llm-d.ai/guide=glm-disagg" \
        -o json | jq -r '
            .items[]
            | select(.metadata.name | test("prefill"))
            | .status.podIP' | tr '\n' ' ')
    echo "  Metrics from: prefill pods  IPs: $METRICS_IPS (port: $METRICS_PORT)"
elif [ "$TARGET" = "glm-agg" ]; then
    METRICS_IPS=$(kubectl get pod -n "$NAMESPACE" "$DECODE_POD" \
        -o jsonpath='{.status.podIP}')
    echo "  Metrics from: agg pod  IP: $METRICS_IPS (port: $METRICS_PORT)"
fi

DECODE_IPS=""
DECODE_METRICS_PORT=8200
if [ "$TARGET" = "glm-disagg" ]; then
    DECODE_IPS=$(kubectl get pods -n "$NAMESPACE" \
        -l "llm-d.ai/guide=glm-disagg" \
        -o json | jq -r '
            .items[]
            | select(.metadata.name | test("decode"))
            | .status.podIP' | tr '\n' ' ')
    echo "  NIXL from:    decode pods  IPs: $DECODE_IPS (port: $DECODE_METRICS_PORT)"
fi

# ============================================
# Prometheus metric helpers
# ============================================

# Scrape vLLM /metrics from each metric target pod individually (via poker).
# Output: one line per pod: "<ip> <queue_sum> <queue_count> <prefill_sum> <prefill_count>"
scrape_metrics_per_pod() {
    for IP in $METRICS_IPS; do
        local TMPFILE
        TMPFILE=$(mktemp)
        kubectl exec -n "$NAMESPACE" poker -- \
            curl -s "http://$IP:${METRICS_PORT}/metrics" \
            > "$TMPFILE" 2>/dev/null || true
        local QS QC PS PC
        QS=$(awk '/^vllm:request_queue_time_seconds_sum/   {s+=$2} END {printf "%.6f",s+0}' "$TMPFILE")
        QC=$(awk '/^vllm:request_queue_time_seconds_count/ {s+=$2} END {printf "%.0f",s+0}' "$TMPFILE")
        PS=$(awk '/^vllm:request_prefill_time_seconds_sum/   {s+=$2} END {printf "%.6f",s+0}' "$TMPFILE")
        PC=$(awk '/^vllm:request_prefill_time_seconds_count/ {s+=$2} END {printf "%.0f",s+0}' "$TMPFILE")
        rm -f "$TMPFILE"
        echo "$IP $QS $QC $PS $PC"
    done
}

# Scrape NIXL transfer metrics from each decode pod (via poker).
# Output per pod: "<ip> <xfer_sum> <xfer_count> <post_sum> <post_count> <bytes_sum> <bytes_count> <desc_sum> <desc_count>"
scrape_decode_nixl_per_pod() {
    for IP in $DECODE_IPS; do
        local TMPFILE
        TMPFILE=$(mktemp)
        kubectl exec -n "$NAMESPACE" poker -- \
            curl -s "http://$IP:${DECODE_METRICS_PORT}/metrics" \
            > "$TMPFILE" 2>/dev/null || true
        local XS XC POS POC BS BC DS DC
        XS=$(awk  '/^vllm:nixl_xfer_time_seconds_sum/    {s+=$2} END {printf "%.6f",s+0}' "$TMPFILE")
        XC=$(awk  '/^vllm:nixl_xfer_time_seconds_count/  {s+=$2} END {printf "%.0f",s+0}' "$TMPFILE")
        POS=$(awk '/^vllm:nixl_post_time_seconds_sum/    {s+=$2} END {printf "%.6f",s+0}' "$TMPFILE")
        POC=$(awk '/^vllm:nixl_post_time_seconds_count/  {s+=$2} END {printf "%.0f",s+0}' "$TMPFILE")
        BS=$(awk  '/^vllm:nixl_bytes_transferred_sum/    {s+=$2} END {printf "%.0f",s+0}' "$TMPFILE")
        BC=$(awk  '/^vllm:nixl_bytes_transferred_count/  {s+=$2} END {printf "%.0f",s+0}' "$TMPFILE")
        DS=$(awk  '/^vllm:nixl_num_descriptors_sum/      {s+=$2} END {printf "%.0f",s+0}' "$TMPFILE")
        DC=$(awk  '/^vllm:nixl_num_descriptors_count/    {s+=$2} END {printf "%.0f",s+0}' "$TMPFILE")
        rm -f "$TMPFILE"
        echo "$IP $XS $XC $POS $POC $BS $BC $DS $DC"
    done
}

# ============================================
# MAIN SCRIPT EXECUTION
# ============================================

LOG_PIDS=()

echo ""
echo "Starting decode pod log capture to $DECODE_LOG ..."
kubectl logs -n "$NAMESPACE" "$DECODE_POD" -c vllm --since=1s -f > "$DECODE_LOG" 2>&1 &
LOG_PIDS+=($!)

if [ -n "$PREFILL_POD" ]; then
    echo "Starting prefill pod log capture to $PREFILL_LOG ..."
    kubectl logs -n "$NAMESPACE" "$PREFILL_POD" -c vllm --since=1s -f > "$PREFILL_LOG" 2>&1 &
    LOG_PIDS+=($!)
fi

cleanup() {
    echo ""
    echo "Stopping log captures..."
    for pid in "${LOG_PIDS[@]}"; do
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    done
    echo "Decode log:  $DECODE_LOG ($(wc -l < "$DECODE_LOG") lines, $(du -h "$DECODE_LOG" | cut -f1))"
    if [ -n "$PREFILL_POD" ]; then
        echo "Prefill log: $PREFILL_LOG ($(wc -l < "$PREFILL_LOG") lines, $(du -h "$PREFILL_LOG" | cut -f1))"
    fi
}
trap cleanup EXIT

sleep 2

ISL="${3:-4096}"
OSL="${4:-256}"
TARGET_DURATION=120
MIN_PROMPTS=200

poker_exec() {
    kubectl exec -n "$NAMESPACE" poker -- /bin/zsh -c "cd /app && $1"
}

# Discover model and GPU count via poker pod
MODEL=$(poker_exec "just _model $TARGET" 2>/dev/null)
GPU_COUNT=$(poker_exec "just _gpu_count $TARGET" 2>/dev/null)

echo ""
echo "=============================================="
echo "Running Concurrency Sweep (timeout: ${BENCHMARK_TIMEOUT_SEC}s)"
echo "  Target: $TARGET | Max Concurrency: $MC"
echo "=============================================="

echo "SWEEP_START"
echo "CONFIG: target=$TARGET model=$MODEL isl=$ISL osl=$OSL gpu_count=$GPU_COUNT"
echo "TARGET_DURATION: ${TARGET_DURATION}s  MIN_PROMPTS: ${MIN_PROMPTS}"
echo "CONCURRENCY_LEVELS: $MC"
echo ""

# --- Step 1: Calibration run (estimate throughput to size main run) ---
CALIB_N=$((MC > 20 ? MC : 20))
echo "CALIBRATION: concurrency=$MC num_prompts=$CALIB_N"
CALIB_OUTPUT=$(timeout "$BENCHMARK_TIMEOUT_SEC" \
    kubectl exec -n "$NAMESPACE" poker -- /bin/zsh -c "cd /app && just benchmark $TARGET $MC $CALIB_N $ISL $OSL" 2>&1) || true
echo "$CALIB_OUTPUT"

THROUGHPUT=$(echo "$CALIB_OUTPUT" | grep -i "Total Token throughput" | grep -oE '[0-9]+\.[0-9]+' | tail -1)
TOKENS_PER_REQ=$((ISL + OSL))
if [ -n "${THROUGHPUT:-}" ]; then
    NP=$(python3 -c "import math; r=float('$THROUGHPUT')/$TOKENS_PER_REQ; print(max($MIN_PROMPTS, math.ceil(r * $TARGET_DURATION)))")
else
    NP=$MIN_PROMPTS
fi
# Compute a timeout with 50% buffer based on expected runtime
if [ -n "${THROUGHPUT:-}" ]; then
    BENCH_TIMEOUT=$(python3 -c "import math; rps=float('$THROUGHPUT')/$TOKENS_PER_REQ; t=math.ceil($NP/rps*1.5) if rps>0 else $BENCHMARK_TIMEOUT_SEC; print(max(300, t))")
else
    BENCH_TIMEOUT=$BENCHMARK_TIMEOUT_SEC
fi
echo "COMPUTED_NUM_PROMPTS: $NP (throughput=${THROUGHPUT:-n/a} tok/s, timeout=${BENCH_TIMEOUT}s)"

# --- Step 2: Snapshot Prometheus metrics (after calibration, before main run) ---
PRE_METRICS_FILE=$(mktemp)
POST_METRICS_FILE=$(mktemp)
PRE_NIXL_FILE=$(mktemp)
POST_NIXL_FILE=$(mktemp)

if [ -n "$METRICS_IPS" ]; then
    echo ""
    echo "=============================================="
    echo "Snapshotting Prometheus metrics (pre-benchmark)"
    echo "=============================================="
    scrape_metrics_per_pod > "$PRE_METRICS_FILE"
    while read -r IP QS QC PS PC; do
        echo "  $IP: queue(sum=$QS, count=$QC) prefill(sum=$PS, count=$PC)"
    done < "$PRE_METRICS_FILE"
fi

if [ -n "$DECODE_IPS" ]; then
    echo "  NIXL (decode pods):"
    scrape_decode_nixl_per_pod > "$PRE_NIXL_FILE"
    while read -r IP XS XC POS POC BS BC DS DC; do
        echo "  $IP: xfer(sum=$XS, count=$XC) post(sum=$POS, count=$POC) bytes(sum=$BS, count=$BC) desc(sum=$DS, count=$DC)"
    done < "$PRE_NIXL_FILE"
fi

# --- Step 3: Main benchmark run ---
echo ""
echo "BENCH_RUN: concurrency=$MC num_prompts=$NP timeout=${BENCH_TIMEOUT}s"
timeout "$BENCH_TIMEOUT" \
    kubectl exec -n "$NAMESPACE" poker -- /bin/zsh -c "cd /app && just benchmark $TARGET $MC $NP $ISL $OSL" 2>&1
BENCH_EXIT=$?
echo "BENCH_RUN_END: concurrency=$MC"

echo ""
if [ "$BENCH_EXIT" -eq 124 ]; then
    echo "=============================================="
    echo "Sweep did not finish within ${BENCH_TIMEOUT}s; killed."
    echo "=============================================="
else
    echo "=============================================="
    echo "Sweep Completed (exit $BENCH_EXIT)"
    echo "=============================================="
fi
echo "SWEEP_END"

# Snapshot Prometheus metrics after benchmark and compute deltas
if [ -n "$METRICS_IPS" ]; then
    echo ""
    echo "=============================================="
    echo "Snapshotting Prometheus metrics (post-benchmark)"
    echo "=============================================="
    scrape_metrics_per_pod > "$POST_METRICS_FILE"
    while read -r IP QS QC PS PC; do
        echo "  $IP: queue(sum=$QS, count=$QC) prefill(sum=$PS, count=$PC)"
    done < "$POST_METRICS_FILE"
fi

if [ -n "$DECODE_IPS" ]; then
    echo "  NIXL (decode pods):"
    scrape_decode_nixl_per_pod > "$POST_NIXL_FILE"
    while read -r IP XS XC POS POC BS BC DS DC; do
        echo "  $IP: xfer(sum=$XS, count=$XC) post(sum=$POS, count=$POC) bytes(sum=$BS, count=$BC) desc(sum=$DS, count=$DC)"
    done < "$POST_NIXL_FILE"
fi

if [ -n "$METRICS_IPS" ] || [ -n "$DECODE_IPS" ]; then
    echo ""
    echo "=============================================="
    echo "Prometheus Metrics Summary (concurrency=$MC)"
    echo "=============================================="
    python3 -c "
import os

# --- Prefill pod metrics (request queue + prefill time) ---
pre, post = {}, {}
for path, d in [('$PRE_METRICS_FILE', pre), ('$POST_METRICS_FILE', post)]:
    if not os.path.getsize(path):
        continue
    with open(path) as f:
        for line in f:
            parts = line.split()
            d[parts[0]] = tuple(float(x) for x in parts[1:])

total_dqs = total_dqc = total_dps = total_dpc = 0
if pre:
    print('Prefill Pod Metrics:')
    for ip in sorted(pre):
        p0, p1 = pre[ip], post[ip]
        dqs = p1[0]-p0[0]; dqc = int(p1[1]-p0[1])
        dps = p1[2]-p0[2]; dpc = int(p1[3]-p0[3])
        avg_q = dqs/dqc if dqc>0 else 0
        avg_p = dps/dpc if dpc>0 else 0
        print(f'  Pod {ip}:')
        print(f'    request_queue_time:   avg = {avg_q:.6f} s  (count={dqc})')
        print(f'    request_prefill_time: avg = {avg_p:.6f} s  (count={dpc})')
        total_dqs += dqs; total_dqc += dqc
        total_dps += dps; total_dpc += dpc
    avg_q = total_dqs/total_dqc if total_dqc>0 else 0
    avg_p = total_dps/total_dpc if total_dpc>0 else 0
    print(f'  System total ({len(pre)} prefill pods):')
    print(f'    request_queue_time:   avg = {avg_q:.6f} s  (count={total_dqc})')
    print(f'    request_prefill_time: avg = {avg_p:.6f} s  (count={total_dpc})')

# --- Decode pod metrics (NIXL KV transfer) ---
npre, npost = {}, {}
for path, d in [('$PRE_NIXL_FILE', npre), ('$POST_NIXL_FILE', npost)]:
    if not os.path.getsize(path):
        continue
    with open(path) as f:
        for line in f:
            parts = line.split()
            d[parts[0]] = tuple(float(x) for x in parts[1:])

t_xs = t_xc = t_pos = t_poc = t_bs = t_bc = t_ds = t_dc = 0
if npre:
    print()
    print('NIXL KV Transfer Metrics (decode pods):')
    for ip in sorted(npre):
        p0, p1 = npre[ip], npost[ip]
        dxs = p1[0]-p0[0]; dxc = int(p1[1]-p0[1])
        dpos = p1[2]-p0[2]; dpoc = int(p1[3]-p0[3])
        dbs = p1[4]-p0[4]; dbc = int(p1[5]-p0[5])
        dds = p1[6]-p0[6]; ddc = int(p1[7]-p0[7])
        avg_xfer = (dxs/dxc*1000) if dxc>0 else 0
        avg_post = (dpos/dpoc*1000) if dpoc>0 else 0
        avg_mb   = (dbs/dbc/1e6) if dbc>0 else 0
        avg_desc = (dds/ddc) if ddc>0 else 0
        print(f'  Decode {ip}:')
        print(f'    total_transfers:    {dxc}')
        print(f'    avg_xfer_time:      {avg_xfer:.3f} ms')
        print(f'    avg_post_time:      {avg_post:.3f} ms')
        print(f'    avg_mb_per_xfer:    {avg_mb:.1f} MB')
        print(f'    avg_descriptors:    {avg_desc:.0f}')
        t_xs+=dxs; t_xc+=dxc; t_pos+=dpos; t_poc+=dpoc
        t_bs+=dbs; t_bc+=dbc; t_ds+=dds; t_dc+=ddc
    if len(npre) > 1:
        avg_xfer = (t_xs/t_xc*1000) if t_xc>0 else 0
        avg_post = (t_pos/t_poc*1000) if t_poc>0 else 0
        avg_mb   = (t_bs/t_bc/1e6) if t_bc>0 else 0
        avg_desc = (t_ds/t_dc) if t_dc>0 else 0
        print(f'  System total ({len(npre)} decode pods):')
        print(f'    total_transfers:    {t_xc}')
        print(f'    avg_xfer_time:      {avg_xfer:.3f} ms')
        print(f'    avg_post_time:      {avg_post:.3f} ms')
        print(f'    avg_mb_per_xfer:    {avg_mb:.1f} MB')
        print(f'    avg_descriptors:    {avg_desc:.0f}')
" | tee "$METRICS_LOG"

    rm -f "$PRE_METRICS_FILE" "$POST_METRICS_FILE" "$PRE_NIXL_FILE" "$POST_NIXL_FILE"
fi
