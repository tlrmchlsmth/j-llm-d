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


def build_instant_defs(p: str) -> list[tuple[str, str]]:
    """Return (key, promql) pairs for instant queries."""
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
            defs.append((f"{prefix}_{label}", hq(float(pct), metric, p)))

    defs.extend([
        ("gen_tokens_per_sec", f"sum(rate(vllm:generation_tokens_total{p}[{RATE_WIN}]))"),
        ("prompt_tokens_per_sec", f"sum(rate(vllm:prompt_tokens_total{p}[{RATE_WIN}]))"),
        ("requests_running", f"sum(vllm:num_requests_running{p})"),
        ("requests_waiting", f"sum(vllm:num_requests_waiting{p})"),
        ("kv_cache_usage", f"avg(vllm:kv_cache_usage_perc{p})"),
        ("nixl_xfer_p99", hq(0.99, "vllm:nixl_xfer_time_seconds_bucket", p)),
    ])
    return defs


def build_range_defs(p: str, nyann_p: str) -> list[tuple[str, str]]:
    """Return (key, promql) pairs for range queries."""
    return [
        ("gen_tokens_per_sec_range", f"sum(rate(vllm:generation_tokens_total{p}[5m]))"),
        ("prompt_tokens_per_sec_range", f"sum(rate(vllm:prompt_tokens_total{p}[5m]))"),
        ("ttft_p99_range", hq(0.99, "vllm:time_to_first_token_seconds_bucket", p, "5m")),
        ("itl_p99_range", hq(0.99, "vllm:inter_token_latency_seconds_bucket", p, "5m")),
        ("decode_time_p99_range", hq(0.99, "vllm:request_decode_time_seconds_bucket", p, "5m")),
        ("prefill_time_p99_range", hq(0.99, "vllm:request_prefill_time_seconds_bucket", p, "5m")),
        ("requests_running_range", f"sum(vllm:num_requests_running{p})"),
        ("kv_cache_usage_range", f"avg(vllm:kv_cache_usage_perc{p})"),
        ("nyann_concurrency_range", f"avg(nyann_concurrency{nyann_p})"),
        ("nyann_stage_range", f"max(nyann_stage{nyann_p})"),
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

    expected = _compute_expected_concurrencies(config)

    # Group consecutive samples by stage index
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

    # If stage index resets (new run started), keep only the last run
    last_run_start = 0
    for i in range(1, len(segments)):
        if segments[i][0] <= segments[i - 1][0]:
            last_run_start = i
    segments = segments[last_run_start:]

    stages = []
    for stage_idx, start_ts, end_ts in segments:
        if expected and stage_idx in expected:
            concurrency = expected[stage_idx]
        else:
            conc_samples = [c for t, c in conc_vals
                           if start_ts <= t <= end_ts and c > 0]
            concurrency = (int(sorted(conc_samples)[len(conc_samples) // 2])
                           if conc_samples else 0)
        if concurrency == 0:
            continue
        stages.append(dict(
            stage=stage_idx,
            concurrency=concurrency,
            start_time=start_ts,
            end_time=end_ts,
        ))

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
    deploy_user = config.get("DEPLOY_USER", deploy.split("-")[0])
    nyann_load_p = '{pod=~"' + deploy_user + '-sharegpt-load-.*"}'
    instant_defs = build_instant_defs(p)
    range_defs = build_range_defs(p, nyann_load_p)

    combined: dict = {}
    ok = fail = 0

    def record(key: str, result: dict):
        nonlocal ok, fail
        combined[key] = result
        if result.get("status") == "success":
            ok += 1
        else:
            fail += 1

    # 1. Range queries
    print(f"Querying {len(range_defs)} range metrics...")
    for key, query in range_defs:
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
        bench_end = int(stages[-1]["end_time"])
        print(f"Found {len(stages)} stage(s):")
        for s in stages:
            dur = s["end_time"] - s["start_time"]
            print(f"  Stage {s['stage']}: concurrency={s['concurrency']}, duration={dur:.0f}s")
    else:
        bench_end = end_ts
        print("No benchmark stages detected (nyann_concurrency not found or empty)")

    # 3. Global instant queries at end of benchmark
    print(f"Querying {len(instant_defs)} global instant metrics at time={bench_end}...")
    for key, query in instant_defs:
        record(key, prom_query(query, ts=bench_end))

    # 4. Per-stage instant queries
    if stages:
        print(f"Querying per-stage instant metrics ({len(stages)} x {len(instant_defs)} queries)...")
        for s in stages:
            stage_end = int(s["end_time"])
            print(f"  Stage {s['stage']} (concurrency={s['concurrency']}, end={stage_end})")
            for key, query in instant_defs:
                record(f"stage_{s['stage']}_{key}", prom_query(query, ts=stage_end))

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
