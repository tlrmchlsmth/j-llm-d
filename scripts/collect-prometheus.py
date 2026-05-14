#!/usr/bin/env python3
"""Collect Prometheus metrics for an EPLB benchmark run.

Reads DEPLOY_NAME and timestamps from config.env, queries Prometheus,
detects benchmark stages from nyann_concurrency, and writes prometheus.json.

Usage: python3 scripts/collect-prometheus.py <run-dir>
       python3 scripts/collect-prometheus.py benchmarks/eplb/pd-async-eplb
"""

from __future__ import annotations

import json
import os
import sys
import time
from pathlib import Path
from urllib.parse import quote, urlencode
from urllib.request import urlopen, Request
from urllib.error import URLError

PROM_URL = os.environ.get("PROM_URL", "http://localhost:9090/api/v1")
RATE_WIN = "5m"
RANGE_RATE_WIN = "10s"
RANGE_STEP = "15s"


# ---------------------------------------------------------------------------
# Config parsing
# ---------------------------------------------------------------------------

def parse_config(path: Path) -> dict[str, str]:
    config = {}
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if "=" in line:
            k, v = line.split("=", 1)
            config[k.strip()] = v.strip()
    return config


# ---------------------------------------------------------------------------
# Prometheus helpers
# ---------------------------------------------------------------------------

def prom_query(query: str, ts: int | float | None = None) -> dict:
    params = {"query": query}
    if ts is not None:
        params["time"] = str(ts)
    url = f"{PROM_URL}/query?{urlencode(params)}"
    try:
        with urlopen(Request(url), timeout=15) as r:
            return json.loads(r.read())
    except (URLError, OSError, json.JSONDecodeError):
        return {"status": "error", "error": "prometheus unreachable"}


def prom_query_range(query: str, start: int, end: int, step: str = RANGE_STEP) -> dict:
    params = {"query": query, "start": str(start), "end": str(end), "step": step}
    url = f"{PROM_URL}/query_range?{urlencode(params)}"
    try:
        with urlopen(Request(url), timeout=30) as r:
            return json.loads(r.read())
    except (URLError, OSError, json.JSONDecodeError):
        return {"status": "error", "error": "prometheus unreachable"}


def check_prometheus() -> bool:
    url = f"{PROM_URL}/query?query=up"
    try:
        with urlopen(Request(url), timeout=5) as r:
            return r.status == 200
    except (URLError, OSError) as e:
        print(f"  Probe failed: {url} → {e}", file=sys.stderr)
        return False


# ---------------------------------------------------------------------------
# PromQL builders
# ---------------------------------------------------------------------------

def hq(quantile: float, metric: str, pod_sel: str, rate_win: str = RATE_WIN) -> str:
    return f'histogram_quantile({quantile}, sum(rate({metric}{pod_sel}[{rate_win}])) by (le))'


def hq_by_rank(quantile: float, metric: str, pod_sel: str, rate_win: str = RATE_WIN) -> str:
    return (f'histogram_quantile({quantile}, '
            f'sum(rate({metric}{pod_sel}[{rate_win}])) by (le, pod, rank))')


def build_per_rank_range_defs(p: str, p_prefill: str | None = None) -> list[tuple[str, str]]:
    """Per-pod/rank range queries for load-vs-latency correlation.

    Returns time series grouped by (pod, rank) so values can be aligned
    to any expert-load dump step via its timestamp.

    *p_prefill* is the prefill-only pod selector for prefill-specific metrics.
    """
    defs = []
    for prefix, metric in [
        ("e2e", "vllm:e2e_request_latency_seconds_bucket"),
        ("decode_time", "vllm:request_decode_time_seconds_bucket"),
        ("itl", "vllm:inter_token_latency_seconds_bucket"),
    ]:
        for pct in ["0.5", "0.99"]:
            label = {"0.5": "p50", "0.99": "p99"}[pct]
            defs.append((f"per_rank_{prefix}_{label}_range",
                         hq_by_rank(float(pct), metric, p)))
    defs.append((
        "per_rank_gen_tokens_per_sec_range",
        f"sum(rate(vllm:generation_tokens_total{p}[{RANGE_RATE_WIN}])) by (pod, rank)",
    ))

    # Prefill per-rank metrics (keyed as per_rank_prefill_*_range to work
    # with plot_per_rank_comparison(metric="prefill_*"))
    pp = p_prefill or p
    defs.append((
        "per_rank_prefill_prompt_tokens_per_sec_range",
        f"sum(rate(vllm:prompt_tokens_total{pp}[{RANGE_RATE_WIN}])) by (pod, rank)",
    ))
    defs.append((
        "per_rank_prefill_gen_tokens_per_sec_range",
        f"sum(rate(vllm:generation_tokens_total{pp}[{RANGE_RATE_WIN}])) by (pod, rank)",
    ))
    defs.append((
        "per_rank_prefill_requests_running_range",
        f"vllm:num_requests_running{pp}",
    ))
    defs.append((
        "per_rank_prefill_requests_waiting_range",
        f"vllm:num_requests_waiting{pp}",
    ))
    defs.append((
        "per_rank_prefill_kv_cache_usage_range",
        f"vllm:kv_cache_usage_perc{pp}",
    ))
    for pct in ["0.5", "0.99"]:
        label = {"0.5": "p50", "0.99": "p99"}[pct]
        defs.append((
            f"per_rank_prefill_iteration_tokens_{label}_range",
            hq_by_rank(float(pct), "vllm:iteration_tokens_total_bucket", pp),
        ))
        defs.append((
            f"per_rank_prefill_time_{label}_range",
            hq_by_rank(float(pct), "vllm:request_prefill_time_seconds_bucket", pp),
        ))

    return defs


def build_instant_defs(p: str, rate_win: str = RATE_WIN,
                       p_decode: str | None = None,
                       p_prefill: str | None = None) -> list[tuple[str, str]]:
    """Return (key, promql) pairs for instant queries.

    *rate_win* controls the ``rate()`` window used for counters and
    histograms.  For per-stage queries, pass the actual stage duration
    (e.g. ``"300s"``) so the rate covers exactly the stage.

    *p_decode* is the decode-only pod selector (e.g. '{pod=~"...-decode-.*"}').
    Used for metrics that only make sense on decode pods (e.g. local compute).
    Falls back to *p* if not provided.

    *p_prefill* is the prefill-only pod selector. Falls back to *p*.
    """
    defs = []

    histograms = [
        ("ttft", "vllm:time_to_first_token_seconds_bucket"),
        ("itl", "vllm:inter_token_latency_seconds_bucket"),
        ("e2e", "vllm:e2e_request_latency_seconds_bucket"),
        ("queue", "vllm:request_queue_time_seconds_bucket"),
        ("prefill_time", "vllm:request_prefill_time_seconds_bucket"),
        ("decode_time", "vllm:request_decode_time_seconds_bucket"),
    ]
    for prefix, metric in histograms:
        for pct in ["0.5", "0.95", "0.99"]:
            label = {"0.5": "p50", "0.95": "p95", "0.99": "p99"}[pct]
            defs.append((f"{prefix}_{label}", hq(float(pct), metric, p, rate_win)))

    defs.extend([
        ("gen_tokens_per_sec", f"sum(rate(vllm:generation_tokens_total{p}[{rate_win}]))"),
        ("prompt_tokens_per_sec", f"sum(rate(vllm:prompt_tokens_total{p}[{rate_win}]))"),
        ("requests_running", f"sum(vllm:num_requests_running{p})"),
        ("requests_waiting", f"sum(vllm:num_requests_waiting{p})"),
        ("kv_cache_usage", f"avg(vllm:kv_cache_usage_perc{p})"),
        ("nixl_xfer_p50", hq(0.50, "vllm:nixl_xfer_time_seconds_bucket", p, rate_win)),
        ("nixl_xfer_p99", hq(0.99, "vllm:nixl_xfer_time_seconds_bucket", p, rate_win)),
    ])

    # -- Batch size per step (most valuable: shows actual tokens/step vs MAX_TOKENS cap)
    for pct in ["0.5", "0.99"]:
        label = {"0.5": "p50", "0.99": "p99"}[pct]
        defs.append((f"iteration_tokens_{label}",
                     hq(float(pct), "vllm:iteration_tokens_total_bucket", p, rate_win)))

    # -- Decode-only iteration tokens, requests running/waiting, KV cache
    pd = p_decode or p
    for pct in ["0.5", "0.99"]:
        label = {"0.5": "p50", "0.99": "p99"}[pct]
        defs.append((f"decode_iteration_tokens_{label}",
                     hq(float(pct), "vllm:iteration_tokens_total_bucket", pd, rate_win)))
    defs.extend([
        ("decode_requests_running", f"sum(vllm:num_requests_running{pd})"),
        ("decode_requests_waiting", f"sum(vllm:num_requests_waiting{pd})"),
        ("decode_kv_cache_usage", f"avg(vllm:kv_cache_usage_perc{pd})"),
        ("decode_gen_tokens_per_sec", f"sum(rate(vllm:generation_tokens_total{pd}[{rate_win}]))"),
    ])

    # -- NIXL KV transfer details
    for pct in ["0.5", "0.99"]:
        label = {"0.5": "p50", "0.99": "p99"}[pct]
        defs.append((f"nixl_bytes_{label}",
                     hq(float(pct), "vllm:nixl_bytes_transferred_bucket", p, rate_win)))
        defs.append((f"nixl_post_time_{label}",
                     hq(float(pct), "vllm:nixl_post_time_seconds_bucket", p, rate_win)))
        defs.append((f"nixl_descriptors_{label}",
                     hq(float(pct), "vllm:nixl_num_descriptors_bucket", p, rate_win)))
    defs.extend([
        ("nixl_failed_transfers_rate", f"sum(rate(vllm:nixl_num_failed_transfers_total{p}[{rate_win}]))"),
        ("nixl_failed_notifications_rate", f"sum(rate(vllm:nixl_num_failed_notifications_total{p}[{rate_win}]))"),
        ("nixl_kv_expired_rate", f"sum(rate(vllm:nixl_num_kv_expired_reqs_total{p}[{rate_win}]))"),
    ])

    # -- Preemptions
    defs.append(("preemptions_rate", f"sum(rate(vllm:num_preemptions_total{p}[{rate_win}]))"))

    # -- Waiting by reason (capacity vs deferred)
    # p is '{pod=~"..."}', inject extra label before closing brace
    p_base = p.rstrip("}")
    defs.extend([
        ("requests_waiting_capacity", f'sum(vllm:num_requests_waiting_by_reason{p_base},reason="capacity"' + '})'),
        ("requests_waiting_deferred", f'sum(vllm:num_requests_waiting_by_reason{p_base},reason="deferred"' + '})'),
    ])

    # -- Prefix cache efficiency
    defs.extend([
        ("prefix_cache_queries_rate", f"sum(rate(vllm:prefix_cache_queries_total{p}[{rate_win}]))"),
        ("prefix_cache_hits_rate", f"sum(rate(vllm:prefix_cache_hits_total{p}[{rate_win}]))"),
    ])

    # -- Prompt tokens by source on DECODE pods only
    # (prefill pods always show 100% local_compute, so aggregate is misleading)
    pd_base = pd.rstrip("}")
    for source in ["local_compute", "local_cache_hit", "external_kv_transfer"]:
        defs.append((
            f"decode_prompt_tokens_{source}_rate",
            f'sum(rate(vllm:prompt_tokens_by_source_total{pd_base},source="{source}"' + '}' + f'[{rate_win}]))',
        ))
    # Decode request success rate (for per-request normalization)
    defs.append((
        "decode_request_success_rate",
        f"sum(rate(vllm:request_success_total{pd}[{rate_win}]))",
    ))

    # -- Prefill KV computed (new tokens computed, excluding cache hits)
    for pct in ["0.5", "0.99"]:
        label = {"0.5": "p50", "0.99": "p99"}[pct]
        defs.append((f"prefill_kv_computed_{label}",
                     hq(float(pct), "vllm:request_prefill_kv_computed_tokens_bucket", p, rate_win)))

    # -- Prefill-pod-specific metrics (saturation / choking diagnostics)
    pp = p_prefill or p
    defs.extend([
        ("prefill_requests_running", f"sum(vllm:num_requests_running{pp})"),
        ("prefill_requests_waiting", f"sum(vllm:num_requests_waiting{pp})"),
        ("prefill_kv_cache_usage", f"avg(vllm:kv_cache_usage_perc{pp})"),
        ("prefill_gen_tokens_per_sec", f"sum(rate(vllm:generation_tokens_total{pp}[{rate_win}]))"),
        ("prefill_prompt_tokens_per_sec", f"sum(rate(vllm:prompt_tokens_total{pp}[{rate_win}]))"),
    ])
    for pct in ["0.5", "0.99"]:
        label = {"0.5": "p50", "0.99": "p99"}[pct]
        defs.append((f"prefill_iteration_tokens_{label}",
                     hq(float(pct), "vllm:iteration_tokens_total_bucket", pp, rate_win)))

    return defs


def build_range_defs(p: str, nyann_p: str) -> list[tuple[str, str]]:
    """Return (key, promql) pairs for range queries."""
    rw = RANGE_RATE_WIN
    return [
        ("gen_tokens_per_sec_range", f"sum(rate(vllm:generation_tokens_total{p}[{rw}]))"),
        ("prompt_tokens_per_sec_range", f"sum(rate(vllm:prompt_tokens_total{p}[{rw}]))"),
        ("ttft_p99_range", hq(0.99, "vllm:time_to_first_token_seconds_bucket", p, rw)),
        ("itl_p99_range", hq(0.99, "vllm:inter_token_latency_seconds_bucket", p, rw)),
        ("decode_time_p99_range", hq(0.99, "vllm:request_decode_time_seconds_bucket", p, rw)),
        ("prefill_time_p99_range", hq(0.99, "vllm:request_prefill_time_seconds_bucket", p, rw)),
        ("requests_running_range", f"sum(vllm:num_requests_running{p})"),
        ("requests_waiting_range", f"sum(vllm:num_requests_waiting{p})"),
        ("kv_cache_usage_range", f"avg(vllm:kv_cache_usage_perc{p})"),
        ("nyann_concurrency_range", f"avg(nyann_concurrency{nyann_p})"),
        ("nyann_stage_range", f"max(nyann_stage{nyann_p})"),
        # Batch size per step over time
        ("iteration_tokens_p99_range", hq(0.99, "vllm:iteration_tokens_total_bucket", p, rw)),
        # NIXL transfer throughput over time
        ("nixl_bytes_p99_range", hq(0.99, "vllm:nixl_bytes_transferred_bucket", p, rw)),
        ("nixl_xfer_time_p99_range", hq(0.99, "vllm:nixl_xfer_time_seconds_bucket", p, rw)),
        # Preemption rate over time
        ("preemptions_range", f"sum(rate(vllm:num_preemptions_total{p}[{rw}]))"),
    ]


# ---------------------------------------------------------------------------
# Stage detection
# ---------------------------------------------------------------------------

def _extract_values(result: dict) -> list[tuple[float, float]]:
    """Extract (timestamp, value) pairs from a range query result."""
    if result.get("status") != "success":
        return []
    results = result.get("data", {}).get("result", [])
    if not results:
        return []
    out = []
    for ts_str, val_str in results[0].get("values", []):
        try:
            out.append((float(ts_str), float(val_str)))
        except (ValueError, TypeError):
            continue
    return out


def _compute_expected_concurrencies(config: dict) -> dict[int, int] | None:
    """Compute stage_idx -> expected concurrency from sweep config.

    Returns None if sweep params are missing from config.
    """
    sweep_min = config.get("SWEEP_MIN")
    sweep_max = config.get("SWEEP_MAX")
    sweep_steps = config.get("SWEEP_STEPS")
    warmup_conc = config.get("WARMUP_CONCURRENCY")
    if not all([sweep_min, sweep_max, sweep_steps]):
        return None

    s_min, s_max, n_steps = int(sweep_min), int(sweep_max), int(sweep_steps)
    w_conc = int(warmup_conc) if warmup_conc else s_min

    mapping: dict[int, int] = {0: w_conc}
    for i in range(1, n_steps):
        mapping[i] = round(s_min + i * (s_max - s_min) / (n_steps - 1))
    mapping[n_steps - 1] = s_max
    return mapping


def detect_stages(
    stage_result: dict,
    concurrency_result: dict,
    config: dict,
) -> list[dict]:
    """Detect benchmark stages from nyann_stage and nyann_concurrency range data.

    Uses nyann_stage (monotonic step counter) for boundary detection.
    If sweep params (SWEEP_MIN/MAX/STEPS) are in config, assigns the exact
    expected concurrency to each stage. Otherwise falls back to the median
    observed concurrency.
    """
    stage_vals = _extract_values(stage_result)
    conc_vals = _extract_values(concurrency_result)
    if not stage_vals:
        return []

    unique_stages = sorted(set(int(v) for _, v in stage_vals))
    print(f"  Raw nyann_stage samples: {len(stage_vals)}, unique indices: {unique_stages}")

    # Group consecutive samples by nyann_stage index
    segments: list[tuple[int, float, float]] = []  # (stage_idx, start_ts, end_ts)
    prev_stage = None
    seg_start = None
    for ts, val in stage_vals:
        stage_idx = int(val)
        if stage_idx != prev_stage:
            if prev_stage is not None and seg_start is not None:
                segments.append((prev_stage, seg_start, ts))
            seg_start = ts
        prev_stage = stage_idx

    if prev_stage is not None and seg_start is not None:
        segments.append((prev_stage, seg_start, stage_vals[-1][0]))

    # Trim everything before the last warmup→sweep boundary.
    # nyann resets concurrency to near-zero between warmup and the first
    # sweep step.  We look for the last dip that is followed by a recovery
    # (not the final shutdown dip at the very end of the benchmark).
    WARMUP_DIP_THRESHOLD = 100
    last_dip_ts = None
    for i, (ts, conc) in enumerate(conc_vals):
        if conc < WARMUP_DIP_THRESHOLD:
            has_recovery = any(c >= WARMUP_DIP_THRESHOLD
                               for _, c in conc_vals[i + 1:])
            if has_recovery:
                last_dip_ts = ts
    if last_dip_ts is not None:
        # Find where concurrency first reaches SWEEP_MIN after the dip
        # to skip the warmup ramp-up.
        sweep_min = int(config.get("SWEEP_MIN", 0))
        trim_ts = last_dip_ts
        if sweep_min:
            for ts, conc in conc_vals:
                if ts > last_dip_ts and conc >= sweep_min:
                    trim_ts = ts
                    break
        before = len(segments)
        segments = [(idx, max(s, trim_ts), e)
                    for idx, s, e in segments if e > trim_ts]
        if before != len(segments) or segments:
            print(f"  Trimmed warmup/stale data: kept {len(segments)}/{before} segments "
                  f"(dip at {last_dip_ts:.0f}, sweep start at {trim_ts:.0f})")
    else:
        # Fallback: trim a fixed warmup duration from stage 0 when no
        # concurrency dip is detected (older benchmark runs).
        # Only trim if stage 0 is much longer than subsequent stages,
        # indicating it genuinely contains warmup ramp-up.
        warmup_dur = int(config.get("WARMUP_DURATION", 300))
        if len(segments) >= 2:
            s0_dur = segments[0][2] - segments[0][1]
            s1_dur = segments[1][2] - segments[1][1]
            if s0_dur > s1_dur + warmup_dur:
                s0 = segments[0]
                segments[0] = (s0[0], s0[1] + warmup_dur, s0[2])
                print(f"  Trimmed {warmup_dur}s warmup from stage 0 "
                      f"({s0_dur:.0f}s -> {s0_dur - warmup_dur:.0f}s)")

    # Deduplicate: merge consecutive segments with the same stage index
    if segments:
        merged: list[tuple[int, float, float]] = [segments[0]]
        for seg in segments[1:]:
            if seg[0] == merged[-1][0]:
                merged[-1] = (merged[-1][0], merged[-1][1], seg[2])
            elif seg[0] > merged[-1][0]:
                merged.append(seg)
        segments = merged

    stages = []
    stage_num = 0
    for stage_idx, start_ts, end_ts in segments:
        if end_ts - start_ts < 30:
            continue
        conc_samples = [int(c) for t, c in conc_vals
                        if start_ts <= t <= end_ts and c > 0]
        if conc_samples:
            concurrency = int(sorted(conc_samples)[len(conc_samples) // 2])
        else:
            concurrency = 0
        if concurrency == 0:
            continue
        stages.append(dict(
            stage=stage_num,
            concurrency=concurrency,
            start_time=start_ts,
            end_time=end_ts,
        ))
        stage_num += 1

    return stages


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <run-dir>", file=sys.stderr)
        sys.exit(1)

    run_dir = Path(sys.argv[1])
    config_path = run_dir / "config.env"
    if not config_path.exists():
        print(f"ERROR: {config_path} not found", file=sys.stderr)
        sys.exit(1)

    config = parse_config(config_path)
    deploy = config.get("DEPLOY_NAME", "")
    if not deploy:
        print("ERROR: DEPLOY_NAME not found in config.env", file=sys.stderr)
        sys.exit(1)

    if not check_prometheus():
        print(f"ERROR: Prometheus not reachable at {PROM_URL}", file=sys.stderr)
        print("  Run 'just prometheus' first to start the port-forward.", file=sys.stderr)
        sys.exit(1)
    print(f"Prometheus OK at {PROM_URL}")

    now = int(time.time())
    end_ts = int(config.get("PROM_END_TS", now))
    start_ts = int(config.get("PROM_START_TS", end_ts - 7200))
    duration = end_ts - start_ts

    print(f"Deploy: {deploy}")
    print(f"Window: {duration}s ({duration / 60:.0f}m)")

    p = '{pod=~"' + deploy + '-.*"}'
    p_decode = '{pod=~"' + deploy + '-decode-.*"}'
    p_prefill = '{pod=~"' + deploy + '-prefill-.*"}'
    deploy_user = config.get("DEPLOY_USER", deploy.split("-")[0])
    bench_dataset = config.get("BENCH_DATASET", config.get("DATASET", "sharegpt"))
    nyann_load_p = '{pod=~"' + deploy_user + '-' + bench_dataset + '-load-.*"}'

    combined: dict = {}
    ok = fail = 0

    def record(key: str, result: dict):
        nonlocal ok, fail
        combined[key] = result
        if result.get("status") == "success":
            ok += 1
        else:
            fail += 1

    # 1. Fetch nyann signals (wide window) for stage detection
    nyann_defs = [
        ("nyann_concurrency_range", f"avg(nyann_concurrency{nyann_load_p})"),
        ("nyann_stage_range", f"max(nyann_stage{nyann_load_p})"),
    ]
    print(f"Querying nyann signals for stage detection (window={duration}s)...")
    for key, query in nyann_defs:
        record(key, prom_query_range(query, start_ts, end_ts))

    # 2. Detect stages
    print("Detecting benchmark stages from nyann_stage + nyann_concurrency...")
    stages = detect_stages(
        combined.get("nyann_stage_range", {}),
        combined.get("nyann_concurrency_range", {}),
        config,
    )

    if stages:
        combined["_stages"] = stages
        bench_start = int(stages[0]["start_time"])
        bench_end = int(stages[-1]["end_time"])
        range_start = bench_start - 60
        range_end = bench_end + 60
        bench_dur = max(bench_end - bench_start, 60)
        bench_win = f"{bench_dur}s"
        print(f"Found {len(stages)} stage(s), narrowing range window to "
              f"{bench_end - bench_start}s + 120s margin:")
        for s in stages:
            dur = s["end_time"] - s["start_time"]
            print(f"  Stage {s['stage']}: concurrency={s['concurrency']}, duration={dur:.0f}s")
    else:
        range_start = start_ts
        range_end = end_ts
        bench_end = end_ts
        bench_win = RATE_WIN
        print("No benchmark stages detected (nyann_concurrency not found or empty)")

    # 3. All range queries (re-fetched with narrow window, overwrites wide nyann data)
    range_defs = build_range_defs(p, nyann_load_p)
    print(f"Querying {len(range_defs)} range metrics "
          f"(window={range_end - range_start}s)...")
    for key, query in range_defs:
        record(key, prom_query_range(query, range_start, range_end))

    # 4. Global instant queries covering the entire benchmark (post-warmup)
    global_defs = build_instant_defs(p, rate_win=bench_win, p_decode=p_decode, p_prefill=p_prefill)
    print(f"Querying {len(global_defs)} global instant metrics at time={bench_end} "
          f"(rate_win={bench_win})...")
    for key, query in global_defs:
        record(key, prom_query(query, ts=bench_end))

    # 5. Per-stage instant queries (rate window = stage duration)
    if stages:
        n_metrics = len(build_instant_defs(p, p_decode=p_decode, p_prefill=p_prefill))
        print(f"Querying per-stage instant metrics ({len(stages)} x {n_metrics} queries)...")
        for s in stages:
            stage_end = int(s["end_time"])
            stage_dur = max(int(s["end_time"] - s["start_time"]), 60)
            stage_win = f"{stage_dur}s"
            stage_defs = build_instant_defs(p, rate_win=stage_win, p_decode=p_decode, p_prefill=p_prefill)
            print(f"  Stage {s['stage']} (concurrency={s['concurrency']}, "
                  f"end={stage_end}, rate_win={stage_win})")
            for key, query in stage_defs:
                record(f"stage_{s['stage']}_{key}", prom_query(query, ts=stage_end))

    # 6. Per-rank range queries (scoped to benchmark window)
    per_rank_defs = build_per_rank_range_defs(p, p_prefill=p_prefill)
    print(f"Querying {len(per_rank_defs)} per-rank range metrics "
          f"(window={range_end - range_start}s)...")
    for key, query in per_rank_defs:
        record(key, prom_query_range(query, range_start, range_end))

    # Write output
    out_path = run_dir / "prometheus.json"
    with open(out_path, "w") as f:
        json.dump(combined, f, indent=2)

    size = out_path.stat().st_size
    print(f"Written to {out_path} ({size} bytes)")
    print(f"Results: {ok} success, {fail} failed")
    if stages:
        print(f"Stages: {len(stages)} (per-stage metrics stored as stage_<N>_<metric>)")


if __name__ == "__main__":
    main()
