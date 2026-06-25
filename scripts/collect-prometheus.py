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
from collections.abc import Callable
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path
from urllib.parse import urlencode
from urllib.request import urlopen, Request
from urllib.error import URLError

try:
    from tqdm import tqdm
except ImportError:
    def tqdm(it, **_kw):  # type: ignore[misc]
        return it

PROM_URL = os.environ.get("PROM_URL", "http://localhost:9090/api/v1")
MAX_WORKERS = int(os.environ.get("PROM_WORKERS", "16"))
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


def run_parallel(
    tasks: list[tuple[str, Callable[[], dict]]],
    workers: int = MAX_WORKERS,
) -> dict[str, dict]:
    """Execute query tasks in parallel with a tqdm progress bar.

    Each task is a (key, zero-arg-callable) tuple. The callable should return
    a Prometheus response dict. Exceptions are caught per-future so one bad
    task doesn't kill the batch.
    """
    results: dict[str, dict] = {}
    with ThreadPoolExecutor(max_workers=workers) as pool:
        futures = {pool.submit(fn): key for key, fn in tasks}
        for fut in tqdm(as_completed(futures), total=len(futures),
                        desc="Querying", unit="q"):
            key = futures[fut]
            try:
                results[key] = fut.result()
            except Exception:
                results[key] = {"status": "error", "error": "query task raised exception"}
    return results


# ---------------------------------------------------------------------------
# PromQL builders
# ---------------------------------------------------------------------------

def hq(quantile: float, metric: str, pod_sel: str, rate_win: str = RATE_WIN) -> str:
    return f'histogram_quantile({quantile}, sum(rate({metric}{pod_sel}[{rate_win}])) by (le))'


def hq_by_rank(quantile: float, metric: str, pod_sel: str, rate_win: str = RATE_WIN) -> str:
    return (f'histogram_quantile({quantile}, '
            f'sum(rate({metric}{pod_sel}[{rate_win}])) by (le, pod, rank))')


def build_per_rank_range_defs(p: str,
                              p_prefill: str | None = None,
                              p_decode: str | None = None) -> list[tuple[str, str]]:
    """Per-pod/rank range queries for load-vs-latency correlation.

    Returns time series grouped by (pod, rank) so values can be aligned
    to any expert-load dump step via its timestamp.

    *p_prefill* / *p_decode* are role-specific pod selectors for metrics
    that only make sense on one side of a P/D split.
    """
    rw = RANGE_RATE_WIN
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
        f"sum(rate(vllm:generation_tokens_total{p}[{rw}])) by (pod, rank)",
    ))

    # -- Prefill per-rank metrics
    pp = p_prefill or p
    defs.append((
        "per_rank_prefill_prompt_tokens_per_sec_range",
        f"sum(rate(vllm:prompt_tokens_total{pp}[{rw}])) by (pod, rank)",
    ))
    defs.append((
        "per_rank_prefill_gen_tokens_per_sec_range",
        f"sum(rate(vllm:generation_tokens_total{pp}[{rw}])) by (pod, rank)",
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

    # -- Decode per-rank metrics (mirrors prefill set above)
    pd = p_decode or p
    defs.append((
        "per_rank_decode_gen_tokens_per_sec_range",
        f"sum(rate(vllm:generation_tokens_total{pd}[{rw}])) by (pod, rank)",
    ))
    defs.append((
        "per_rank_decode_requests_running_range",
        f"vllm:num_requests_running{pd}",
    ))
    defs.append((
        "per_rank_decode_requests_waiting_range",
        f"vllm:num_requests_waiting{pd}",
    ))
    defs.append((
        "per_rank_decode_kv_cache_usage_range",
        f"vllm:kv_cache_usage_perc{pd}",
    ))
    for pct in ["0.5", "0.99"]:
        label = {"0.5": "p50", "0.99": "p99"}[pct]
        defs.append((
            f"per_rank_decode_iteration_tokens_{label}_range",
            hq_by_rank(float(pct), "vllm:iteration_tokens_total_bucket", pd),
        ))

    # -- DeepEP/MoE per-rank timing (decode) — aggregated across layers
    defs.extend([
        ("per_rank_decode_deepep_dispatch_duration_rate_range",
         f"sum(rate(vllm:deepep_dispatch_duration_seconds_sum{pd}[{rw}])) by (pod, rank)"),
        ("per_rank_decode_deepep_combine_duration_rate_range",
         f"sum(rate(vllm:deepep_combine_duration_seconds_sum{pd}[{rw}])) by (pod, rank)"),
        ("per_rank_decode_moe_expert_compute_duration_rate_range",
         f"sum(rate(vllm:moe_expert_compute_duration_seconds_sum{pd}[{rw}])) by (pod, rank)"),
    ])

    # -- DeepEP/MoE per-rank timing (prefill) — aggregated across layers
    defs.extend([
        ("per_rank_prefill_deepep_dispatch_duration_rate_range",
         f"sum(rate(vllm:deepep_dispatch_duration_seconds_sum{pp}[{rw}])) by (pod, rank)"),
        ("per_rank_prefill_deepep_combine_duration_rate_range",
         f"sum(rate(vllm:deepep_combine_duration_seconds_sum{pp}[{rw}])) by (pod, rank)"),
        ("per_rank_prefill_moe_expert_compute_duration_rate_range",
         f"sum(rate(vllm:moe_expert_compute_duration_seconds_sum{pp}[{rw}])) by (pod, rank)"),
    ])

    # -- DeepEP/MoE per-rank histogram_quantile p50/p99 (summed over layers)
    for role_sel, role_prefix in [(pd, "decode"), (pp, "prefill")]:
        for metric, prefix in [
            ("vllm:deepep_dispatch_duration_seconds_bucket", f"{role_prefix}_deepep_dispatch"),
            ("vllm:deepep_combine_duration_seconds_bucket", f"{role_prefix}_deepep_combine"),
            ("vllm:moe_expert_compute_duration_seconds_bucket", f"{role_prefix}_moe_expert_compute"),
        ]:
            for pct in ["0.5", "0.99"]:
                label = {"0.5": "p50", "0.99": "p99"}[pct]
                defs.append((
                    f"per_rank_{prefix}_{label}_range",
                    f"histogram_quantile({pct}, sum(rate({metric}{role_sel}[{rw}])) by (le, pod, rank))",
                ))

    # -- DeepEP/MoE per-rank-per-layer histogram_quantile p50/p99
    for role_sel, role_prefix in [(pd, "decode"), (pp, "prefill")]:
        for metric, prefix in [
            ("vllm:deepep_dispatch_duration_seconds_bucket", f"{role_prefix}_deepep_dispatch"),
            ("vllm:deepep_combine_duration_seconds_bucket", f"{role_prefix}_deepep_combine"),
            ("vllm:moe_expert_compute_duration_seconds_bucket", f"{role_prefix}_moe_expert_compute"),
        ]:
            for pct in ["0.5", "0.99"]:
                label = {"0.5": "p50", "0.99": "p99"}[pct]
                defs.append((
                    f"per_rank_{prefix}_{label}_per_layer_range",
                    f"histogram_quantile({pct}, sum(rate({metric}{role_sel}[{rw}])) by (le, layer, pod, rank))",
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

    # -- Decode-specific latency histograms
    for pct in ["0.5", "0.99"]:
        label = {"0.5": "p50", "0.99": "p99"}[pct]
        defs.append((f"decode_ttft_{label}",
                     hq(float(pct), "vllm:time_to_first_token_seconds_bucket", pd, rate_win)))
        defs.append((f"decode_prefill_time_{label}",
                     hq(float(pct), "vllm:request_prefill_time_seconds_bucket", pd, rate_win)))
        defs.append((f"decode_inference_time_{label}",
                     hq(float(pct), "vllm:request_inference_time_seconds_bucket", pd, rate_win)))

    # -- Prefill-specific latency histograms
    for pct in ["0.5", "0.99"]:
        label = {"0.5": "p50", "0.99": "p99"}[pct]
        defs.append((f"prefill_ttft_{label}",
                     hq(float(pct), "vllm:time_to_first_token_seconds_bucket", pp, rate_win)))
        defs.append((f"prefill_prefill_time_{label}",
                     hq(float(pct), "vllm:request_prefill_time_seconds_bucket", pp, rate_win)))
        defs.append((f"prefill_inference_time_{label}",
                     hq(float(pct), "vllm:request_inference_time_seconds_bucket", pp, rate_win)))

    # -- Inference time (time in RUNNING phase) — global
    for pct in ["0.5", "0.95", "0.99"]:
        label = {"0.5": "p50", "0.95": "p95", "0.99": "p99"}[pct]
        defs.append((f"inference_time_{label}",
                     hq(float(pct), "vllm:request_inference_time_seconds_bucket", p, rate_win)))

    # -- TPOT (mean time per output token per request) — global
    for pct in ["0.5", "0.95", "0.99"]:
        label = {"0.5": "p50", "0.95": "p95", "0.99": "p99"}[pct]
        defs.append((f"tpot_{label}",
                     hq(float(pct), "vllm:request_time_per_output_token_seconds_bucket", p, rate_win)))

    # -- External prefix cache efficiency (NIXL-side KV reuse on decode)
    defs.extend([
        ("external_prefix_cache_queries_rate",
         f"sum(rate(vllm:external_prefix_cache_queries_total{p}[{rate_win}]))"),
        ("external_prefix_cache_hits_rate",
         f"sum(rate(vllm:external_prefix_cache_hits_total{p}[{rate_win}]))"),
    ])

    # -- DeepEP dispatch/combine and MoE expert compute timing (global, summed across layers)
    defs.extend([
        ("deepep_dispatch_duration_rate",
         f"sum(rate(vllm:deepep_dispatch_duration_seconds_sum{p}[{rate_win}]))"),
        ("deepep_combine_duration_rate",
         f"sum(rate(vllm:deepep_combine_duration_seconds_sum{p}[{rate_win}]))"),
        ("moe_expert_compute_duration_rate",
         f"sum(rate(vllm:moe_expert_compute_duration_seconds_sum{p}[{rate_win}]))"),
    ])

    # -- DeepEP/MoE timing (decode-only, summed across layers)
    defs.extend([
        ("decode_deepep_dispatch_duration_rate",
         f"sum(rate(vllm:deepep_dispatch_duration_seconds_sum{pd}[{rate_win}]))"),
        ("decode_deepep_combine_duration_rate",
         f"sum(rate(vllm:deepep_combine_duration_seconds_sum{pd}[{rate_win}]))"),
        ("decode_moe_expert_compute_duration_rate",
         f"sum(rate(vllm:moe_expert_compute_duration_seconds_sum{pd}[{rate_win}]))"),
    ])

    # -- DeepEP/MoE timing (prefill-only, summed across layers)
    defs.extend([
        ("prefill_deepep_dispatch_duration_rate",
         f"sum(rate(vllm:deepep_dispatch_duration_seconds_sum{pp}[{rate_win}]))"),
        ("prefill_deepep_combine_duration_rate",
         f"sum(rate(vllm:deepep_combine_duration_seconds_sum{pp}[{rate_win}]))"),
        ("prefill_moe_expert_compute_duration_rate",
         f"sum(rate(vllm:moe_expert_compute_duration_seconds_sum{pp}[{rate_win}]))"),
    ])

    return defs


def build_range_defs(p: str, nyann_p: str,
                     p_decode: str | None = None,
                     p_prefill: str | None = None) -> list[tuple[str, str]]:
    """Return (key, promql) pairs for range queries.

    *p_decode* / *p_prefill* are role-specific pod selectors.  When provided,
    the function emits additional ``decode_*_range`` and ``prefill_*_range``
    series so that each side can be analyzed independently.
    """
    rw = RANGE_RATE_WIN
    defs = [
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
        ("iteration_tokens_p99_range", hq(0.99, "vllm:iteration_tokens_total_bucket", p, rw)),
        ("nixl_bytes_p99_range", hq(0.99, "vllm:nixl_bytes_transferred_bucket", p, rw)),
        ("nixl_xfer_time_p99_range", hq(0.99, "vllm:nixl_xfer_time_seconds_bucket", p, rw)),
        ("preemptions_range", f"sum(rate(vllm:num_preemptions_total{p}[{rw}]))"),
        # Additional shared range queries
        ("nixl_xfer_time_p50_range", hq(0.50, "vllm:nixl_xfer_time_seconds_bucket", p, rw)),
        ("nixl_post_time_p99_range", hq(0.99, "vllm:nixl_post_time_seconds_bucket", p, rw)),
        ("queue_time_p99_range", hq(0.99, "vllm:request_queue_time_seconds_bucket", p, rw)),
        ("inference_time_p99_range", hq(0.99, "vllm:request_inference_time_seconds_bucket", p, rw)),
        ("isl_p50_range", hq(0.50, "vllm:request_prompt_tokens_bucket", p, rw)),
        ("isl_p99_range", hq(0.99, "vllm:request_prompt_tokens_bucket", p, rw)),
        ("osl_p50_range", hq(0.50, "vllm:request_generation_tokens_bucket", p, rw)),
        ("osl_p99_range", hq(0.99, "vllm:request_generation_tokens_bucket", p, rw)),
    ]

    # -- Decode-specific range queries
    pd = p_decode or p
    pd_base = pd.rstrip("}")
    defs.extend([
        ("decode_gen_tokens_per_sec_range", f"sum(rate(vllm:generation_tokens_total{pd}[{rw}]))"),
        ("decode_prompt_tokens_per_sec_range", f"sum(rate(vllm:prompt_tokens_total{pd}[{rw}]))"),
        ("decode_requests_running_range", f"sum(vllm:num_requests_running{pd})"),
        ("decode_requests_waiting_range", f"sum(vllm:num_requests_waiting{pd})"),
        ("decode_kv_cache_usage_range", f"avg(vllm:kv_cache_usage_perc{pd})"),
        ("decode_iteration_tokens_p99_range", hq(0.99, "vllm:iteration_tokens_total_bucket", pd, rw)),
        ("decode_itl_p99_range", hq(0.99, "vllm:inter_token_latency_seconds_bucket", pd, rw)),
        ("decode_decode_time_p99_range", hq(0.99, "vllm:request_decode_time_seconds_bucket", pd, rw)),
        ("decode_osl_p50_range", hq(0.50, "vllm:request_generation_tokens_bucket", pd, rw)),
        ("decode_osl_p99_range", hq(0.99, "vllm:request_generation_tokens_bucket", pd, rw)),
    ])
    for source in ["local_compute", "local_cache_hit", "external_kv_transfer"]:
        defs.append((
            f"decode_prompt_tokens_{source}_rate_range",
            f'sum(rate(vllm:prompt_tokens_by_source_total{pd_base},source="{source}"' + '}' + f'[{rw}]))',
        ))

    # -- Prefill-specific range queries
    pp = p_prefill or p
    defs.extend([
        ("prefill_prompt_tokens_per_sec_range", f"sum(rate(vllm:prompt_tokens_total{pp}[{rw}]))"),
        ("prefill_gen_tokens_per_sec_range", f"sum(rate(vllm:generation_tokens_total{pp}[{rw}]))"),
        ("prefill_requests_running_range", f"sum(vllm:num_requests_running{pp})"),
        ("prefill_requests_waiting_range", f"sum(vllm:num_requests_waiting{pp})"),
        ("prefill_kv_cache_usage_range", f"avg(vllm:kv_cache_usage_perc{pp})"),
        ("prefill_iteration_tokens_p99_range", hq(0.99, "vllm:iteration_tokens_total_bucket", pp, rw)),
        ("prefill_prefill_time_p99_range", hq(0.99, "vllm:request_prefill_time_seconds_bucket", pp, rw)),
    ])

    # -- DeepEP/MoE timing range queries (global, summed across layers)
    defs.extend([
        ("deepep_dispatch_duration_rate_range",
         f"sum(rate(vllm:deepep_dispatch_duration_seconds_sum{p}[{rw}]))"),
        ("deepep_combine_duration_rate_range",
         f"sum(rate(vllm:deepep_combine_duration_seconds_sum{p}[{rw}]))"),
        ("moe_expert_compute_duration_rate_range",
         f"sum(rate(vllm:moe_expert_compute_duration_seconds_sum{p}[{rw}]))"),
    ])

    # -- DeepEP/MoE timing range queries (decode, summed across layers)
    defs.extend([
        ("decode_deepep_dispatch_duration_rate_range",
         f"sum(rate(vllm:deepep_dispatch_duration_seconds_sum{pd}[{rw}]))"),
        ("decode_deepep_combine_duration_rate_range",
         f"sum(rate(vllm:deepep_combine_duration_seconds_sum{pd}[{rw}]))"),
        ("decode_moe_expert_compute_duration_rate_range",
         f"sum(rate(vllm:moe_expert_compute_duration_seconds_sum{pd}[{rw}]))"),
    ])

    # -- DeepEP/MoE timing range queries (prefill, summed across layers)
    defs.extend([
        ("prefill_deepep_dispatch_duration_rate_range",
         f"sum(rate(vllm:deepep_dispatch_duration_seconds_sum{pp}[{rw}]))"),
        ("prefill_deepep_combine_duration_rate_range",
         f"sum(rate(vllm:deepep_combine_duration_seconds_sum{pp}[{rw}]))"),
        ("prefill_moe_expert_compute_duration_rate_range",
         f"sum(rate(vllm:moe_expert_compute_duration_seconds_sum{pp}[{rw}]))"),
    ])

    # -- DeepEP/MoE per-layer range queries (decode, one series per layer)
    for metric, prefix in [
        ("vllm:deepep_dispatch_duration_seconds_sum", "decode_deepep_dispatch"),
        ("vllm:deepep_combine_duration_seconds_sum", "decode_deepep_combine"),
        ("vllm:moe_expert_compute_duration_seconds_sum", "decode_moe_expert_compute"),
    ]:
        defs.append((
            f"{prefix}_per_layer_range",
            f"sum(rate({metric}{pd}[{rw}])) by (layer)",
        ))

    # -- DeepEP/MoE per-layer range queries (prefill, one series per layer)
    for metric, prefix in [
        ("vllm:deepep_dispatch_duration_seconds_sum", "prefill_deepep_dispatch"),
        ("vllm:deepep_combine_duration_seconds_sum", "prefill_deepep_combine"),
        ("vllm:moe_expert_compute_duration_seconds_sum", "prefill_moe_expert_compute"),
    ]:
        defs.append((
            f"{prefix}_per_layer_range",
            f"sum(rate({metric}{pp}[{rw}])) by (layer)",
        ))

    # -- DeepEP/MoE per-layer histogram_quantile p50/p99 (summed over ranks)
    for role_sel, role_prefix in [(pd, "decode"), (pp, "prefill")]:
        for metric, prefix in [
            ("vllm:deepep_dispatch_duration_seconds_bucket", f"{role_prefix}_deepep_dispatch"),
            ("vllm:deepep_combine_duration_seconds_bucket", f"{role_prefix}_deepep_combine"),
            ("vllm:moe_expert_compute_duration_seconds_bucket", f"{role_prefix}_moe_expert_compute"),
        ]:
            for pct in ["0.5", "0.99"]:
                label = {"0.5": "p50", "0.99": "p99"}[pct]
                defs.append((
                    f"{prefix}_{label}_per_layer_range",
                    f"histogram_quantile({pct}, sum(rate({metric}{role_sel}[{rw}])) by (le, layer))",
                ))

    return defs


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

    # Trim warmup: find the last time concurrency reaches SWEEP_MIN and
    # use that as the start of stage 0.  This handles both the warmup
    # ramp-up and any stale data from previous benchmark runs.
    sweep_min = int(config.get("SWEEP_MIN", 0))
    if sweep_min and conc_vals:
        # Walk backwards to find the last ramp-up to SWEEP_MIN — that's
        # where the final benchmark's stage 0 actually begins.
        sweep_start_ts = None
        for i in range(len(conc_vals) - 1, -1, -1):
            ts, conc = conc_vals[i]
            if conc >= sweep_min:
                # Check if the previous sample was below SWEEP_MIN (ramp-up crossing)
                if i == 0 or conc_vals[i - 1][1] < sweep_min:
                    sweep_start_ts = ts
                    break
        if sweep_start_ts is not None:
            before = len(segments)
            segments = [(idx, max(s, sweep_start_ts), e)
                        for idx, s, e in segments if e > sweep_start_ts]
            trimmed = before - len(segments)
            if trimmed or (segments and segments[0][1] == sweep_start_ts):
                print(f"  Trimmed warmup: stage 0 starts at {sweep_start_ts:.0f} "
                      f"(concurrency reaches {sweep_min})")

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
    # Prefer BENCH_LAUNCHED_AT over PROM_START_TS (pod creation) to avoid
    # picking up stale data from previous benchmark runs on the same pod.
    bench_launched = config.get("BENCH_LAUNCHED_AT")
    if bench_launched:
        from datetime import datetime, timezone
        try:
            start_ts = int(datetime.fromisoformat(bench_launched).timestamp())
            print(f"Using BENCH_LAUNCHED_AT ({bench_launched}) as query start")
        except ValueError:
            start_ts = int(config.get("PROM_START_TS", end_ts - 7200))
    else:
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

    # 1. Fetch nyann signals (wide window) for stage detection
    nyann_defs = [
        ("nyann_concurrency_range", f"avg(nyann_concurrency{nyann_load_p})"),
        ("nyann_stage_range", f"max(nyann_stage{nyann_load_p})"),
    ]
    print(f"Querying nyann signals for stage detection (window={duration}s)...")
    for key, query in nyann_defs:
        combined[key] = prom_query_range(query, start_ts, end_ts)

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

    # 3. Build all remaining queries into one parallel batch
    tasks: list[tuple[str, Callable[[], dict]]] = []

    # Range queries
    range_defs = build_range_defs(p, nyann_load_p,
                                  p_decode=p_decode, p_prefill=p_prefill)
    tasks.extend([
        (k, lambda q=v: prom_query_range(q, range_start, range_end))
        for k, v in range_defs
    ])

    # Global instant queries
    global_defs = build_instant_defs(p, rate_win=bench_win, p_decode=p_decode, p_prefill=p_prefill)
    tasks.extend([
        (k, lambda q=v: prom_query(q, ts=bench_end))
        for k, v in global_defs
    ])

    # Per-stage instant queries
    for s in stages:
        stage_end = int(s["end_time"])
        stage_dur = max(int(s["end_time"] - s["start_time"]), 60)
        stage_defs = build_instant_defs(
            p, rate_win=f"{stage_dur}s", p_decode=p_decode, p_prefill=p_prefill)
        tasks.extend([
            (f"stage_{s['stage']}_{k}", lambda q=v, t=stage_end: prom_query(q, ts=t))
            for k, v in stage_defs
        ])

    # Per-rank range queries
    per_rank_defs = build_per_rank_range_defs(p, p_prefill=p_prefill,
                                              p_decode=p_decode)
    tasks.extend([
        (k, lambda q=v: prom_query_range(q, range_start, range_end))
        for k, v in per_rank_defs
    ])

    # Execute all queries in parallel
    print(f"Querying {len(tasks)} metrics in parallel (workers={MAX_WORKERS})...")
    t0 = time.time()
    batch = run_parallel(tasks)
    elapsed = time.time() - t0
    combined.update(batch)

    ok = sum(1 for r in batch.values() if r.get("status") == "success")
    fail = len(batch) - ok
    print(f"Done in {elapsed:.1f}s ({ok} success, {fail} failed)")

    # Write output
    out_path = run_dir / "prometheus.json"
    with open(out_path, "w") as f:
        json.dump(combined, f, indent=2)

    size = out_path.stat().st_size
    print(f"Written to {out_path} ({size} bytes)")
    if stages:
        print(f"Stages: {len(stages)} (per-stage metrics stored as stage_<N>_<metric>)")


if __name__ == "__main__":
    main()
