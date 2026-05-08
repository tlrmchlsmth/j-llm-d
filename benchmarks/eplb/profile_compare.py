"""Compare PyTorch profiler traces between baseline and EPLB bookkeeping runs.

Usage:
    python profile_compare.py [--pod POD_INDEX] [--rank LOCAL_RANK]

Reads gzipped Chrome trace JSON from traces/baseline/ and traces/eplb_bookkeeping/.
Produces a side-by-side comparison of per-iteration GPU time and kernel breakdown.
"""

from __future__ import annotations

import argparse
import gzip
import json
import os
import re
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np


TRACES_ROOT = Path(__file__).resolve().parent.parent.parent / "traces"

KERNEL_CATEGORIES = [
    ("attention",   re.compile(r"fmha|flash_?attn|flash_?infer.*attn", re.I)),
    ("dispatch",    re.compile(r"deep_ep.*dispatch", re.I)),
    ("combine",     re.compile(r"deep_ep.*combine", re.I)),
    ("expert_gemm", re.compile(r"flashinfer.*gemm|cutlass.*gemm|grouped_gemm", re.I)),
    ("moe_gate",    re.compile(r"grouped_topk|topk_topp", re.I)),
    ("fp4_quant",   re.compile(r"cvt_fp16_to_fp4|fp4_quant", re.I)),
    ("eplb",        re.compile(r"eplb", re.I)),
    ("rmsnorm",     re.compile(r"rsqrt|rms_?norm", re.I)),
    ("kv_cache",    re.compile(r"concat_and_cache|slot_mapping", re.I)),
    ("nvjet_gemm",  re.compile(r"nvjet_sm", re.I)),
    ("silu_mul",    re.compile(r"silu", re.I)),
]


def classify_kernel(name: str) -> str:
    for cat, pat in KERNEL_CATEGORIES:
        if pat.search(name):
            return cat
    return "other"


@dataclass
class IterationInfo:
    name: str
    ts: float
    dur_us: float
    kernels: list[dict] = field(default_factory=list)


def load_trace(path: Path) -> dict:
    with gzip.open(path, "rt") as f:
        return json.load(f)


def find_trace_file(profile_dir: Path, pod_name: str, dp_rank: int) -> Path | None:
    pod_dir = profile_dir / pod_name
    if not pod_dir.exists():
        return None
    prefix = f"dp{dp_rank}_"
    for f in pod_dir.iterdir():
        if f.name.startswith(prefix) and f.name.endswith(".json.gz"):
            return f
    return None


def list_pods(profile_dir: Path) -> list[str]:
    if not profile_dir.exists():
        return []
    return sorted(
        d.name for d in profile_dir.iterdir()
        if d.is_dir() and not d.name.startswith(".")
    )


def extract_iterations(events: list[dict]) -> list[IterationInfo]:
    gpu_annots = sorted(
        (e for e in events
         if e.get("cat") == "gpu_user_annotation"
         and e.get("ph") == "X"
         and "execute_context" in e.get("name", "")),
        key=lambda e: e["ts"],
    )
    kernels = sorted(
        (e for e in events if e.get("cat") == "kernel" and e.get("ph") == "X"),
        key=lambda e: e["ts"],
    )

    iterations: list[IterationInfo] = []
    for ann in gpu_annots:
        t0 = ann["ts"]
        t1 = t0 + ann["dur"]
        it_kernels = [
            k for k in kernels
            if k["ts"] >= t0 and k["ts"] + k.get("dur", 0) <= t1 + 100
        ]
        iterations.append(IterationInfo(
            name=ann["name"], ts=t0, dur_us=ann["dur"], kernels=it_kernels,
        ))
    return iterations


def kernel_breakdown(iterations: list[IterationInfo]) -> dict[str, dict]:
    """Aggregate kernel time by category across all iterations."""
    cat_dur: dict[str, list[float]] = {}
    cat_count: dict[str, int] = {}
    for it in iterations:
        per_it: dict[str, float] = {}
        for k in it.kernels:
            cat = classify_kernel(k["name"])
            per_it[cat] = per_it.get(cat, 0) + k.get("dur", 0)
            cat_count[cat] = cat_count.get(cat, 0) + 1
        for cat, dur in per_it.items():
            cat_dur.setdefault(cat, []).append(dur)

    out = {}
    for cat in sorted(cat_dur.keys(), key=lambda c: -np.mean(cat_dur[c])):
        vals = cat_dur[cat]
        out[cat] = {
            "mean_us": np.mean(vals),
            "std_us": np.std(vals),
            "total_us": np.sum(vals),
            "calls": cat_count.get(cat, 0),
            "per_iter": cat_count.get(cat, 0) / max(len(iterations), 1),
        }
    return out


def kernel_topN(iterations: list[IterationInfo], n: int = 15) -> list[dict]:
    """Top-N kernels by total GPU time."""
    totals: dict[str, float] = {}
    counts: dict[str, int] = {}
    for it in iterations:
        for k in it.kernels:
            short = k["name"][:100]
            totals[short] = totals.get(short, 0) + k.get("dur", 0)
            counts[short] = counts.get(short, 0) + 1
    ranked = sorted(totals.items(), key=lambda x: -x[1])[:n]
    return [{"name": n, "total_us": t, "count": counts[n],
             "avg_us": t / counts[n], "category": classify_kernel(n)}
            for n, t in ranked]


def fmt_us(v: float) -> str:
    if v > 1_000_000:
        return f"{v/1_000_000:.2f}s"
    if v > 1000:
        return f"{v/1000:.2f}ms"
    return f"{v:.1f}us"


def print_comparison(label_a: str, label_b: str,
                     iters_a: list[IterationInfo],
                     iters_b: list[IterationInfo]):
    durs_a = np.array([it.dur_us for it in iters_a])
    durs_b = np.array([it.dur_us for it in iters_b])

    print("=" * 80)
    print(f"Per-Iteration GPU Duration (gpu_user_annotation)")
    print("=" * 80)
    print(f"{'':30s} {'Baseline':>14s} {'EPLB':>14s} {'Delta':>14s}")
    print(f"{'Iterations':30s} {len(iters_a):14d} {len(iters_b):14d}")
    print(f"{'Mean':30s} {fmt_us(durs_a.mean()):>14s} {fmt_us(durs_b.mean()):>14s} {fmt_us(durs_b.mean() - durs_a.mean()):>14s}")
    print(f"{'Std':30s} {fmt_us(durs_a.std()):>14s} {fmt_us(durs_b.std()):>14s}")
    print(f"{'Min':30s} {fmt_us(durs_a.min()):>14s} {fmt_us(durs_b.min()):>14s}")
    print(f"{'Max':30s} {fmt_us(durs_a.max()):>14s} {fmt_us(durs_b.max()):>14s}")
    print(f"{'P50':30s} {fmt_us(np.median(durs_a)):>14s} {fmt_us(np.median(durs_b)):>14s}")
    print()

    bd_a = kernel_breakdown(iters_a)
    bd_b = kernel_breakdown(iters_b)
    all_cats = sorted(set(bd_a) | set(bd_b),
                      key=lambda c: -max(bd_a.get(c, {}).get("mean_us", 0),
                                         bd_b.get(c, {}).get("mean_us", 0)))

    print("=" * 80)
    print("Kernel Category Breakdown (mean per iteration)")
    print("=" * 80)
    print(f"{'Category':16s} {'Baseline':>12s} {'EPLB':>12s} {'Delta':>12s} {'Calls/it':>10s} {'Calls/it':>10s}")
    print(f"{'':16s} {'':>12s} {'':>12s} {'':>12s} {'(base)':>10s} {'(eplb)':>10s}")
    print("-" * 80)
    total_a = total_b = 0
    for cat in all_cats:
        a = bd_a.get(cat, {}).get("mean_us", 0)
        b = bd_b.get(cat, {}).get("mean_us", 0)
        ca = bd_a.get(cat, {}).get("per_iter", 0)
        cb = bd_b.get(cat, {}).get("per_iter", 0)
        delta = b - a
        sign = "+" if delta > 0 else ""
        print(f"{cat:16s} {fmt_us(a):>12s} {fmt_us(b):>12s} {sign}{fmt_us(delta):>11s} {ca:>10.0f} {cb:>10.0f}")
        total_a += a
        total_b += b
    print("-" * 80)
    print(f"{'TOTAL':16s} {fmt_us(total_a):>12s} {fmt_us(total_b):>12s} {'+' if total_b > total_a else ''}{fmt_us(total_b - total_a):>11s}")
    print()

    print("=" * 80)
    print("Top 15 Kernels by GPU Time")
    print("=" * 80)
    top_a = kernel_topN(iters_a)
    top_b = kernel_topN(iters_b)

    for label, top in [(label_a, top_a), (label_b, top_b)]:
        print(f"\n--- {label} ---")
        print(f"{'#':>3s} {'Total':>10s} {'Count':>6s} {'Avg':>10s} {'Category':>14s}  Name")
        for i, k in enumerate(top, 1):
            print(f"{i:3d} {fmt_us(k['total_us']):>10s} {k['count']:>6d} "
                  f"{fmt_us(k['avg_us']):>10s} {k['category']:>14s}  {k['name'][:72]}")
    print()

    only_eplb = set()
    only_base = set()
    names_a = set()
    names_b = set()
    for it in iters_a:
        for k in it.kernels:
            names_a.add(k["name"][:100])
    for it in iters_b:
        for k in it.kernels:
            names_b.add(k["name"][:100])
    only_eplb = names_b - names_a
    only_base = names_a - names_b
    if only_eplb:
        print("=" * 80)
        print(f"Kernels ONLY in EPLB ({len(only_eplb)}):")
        print("=" * 80)
        for n in sorted(only_eplb):
            print(f"  [{classify_kernel(n):14s}] {n[:90]}")
    if only_base:
        print(f"\nKernels ONLY in baseline ({len(only_base)}):")
        for n in sorted(only_base):
            print(f"  [{classify_kernel(n):14s}] {n[:90]}")
    print()


def main():
    parser = argparse.ArgumentParser(description="Compare baseline vs EPLB traces")
    parser.add_argument("--pod", type=int, default=0, help="Pod index (0-7)")
    parser.add_argument("--rank", type=int, default=None,
                        help="Local DP rank (0-3). If omitted, compares all 4.")
    parser.add_argument("--baseline-dir", default="baseline",
                        help="Baseline trace subdirectory name")
    parser.add_argument("--eplb-dir", default="eplb_bookkeeping",
                        help="EPLB trace subdirectory name")
    args = parser.parse_args()

    base_dir = TRACES_ROOT / args.baseline_dir
    eplb_dir = TRACES_ROOT / args.eplb_dir

    base_pods = list_pods(base_dir)
    eplb_pods = list_pods(eplb_dir)
    if not base_pods:
        print(f"No pods found in {base_dir}"); return
    if not eplb_pods:
        print(f"No pods found in {eplb_dir}"); return

    pod_a = base_pods[args.pod] if args.pod < len(base_pods) else base_pods[0]
    pod_b = eplb_pods[args.pod] if args.pod < len(eplb_pods) else eplb_pods[0]
    print(f"Comparing: {args.baseline_dir}/{pod_a}  vs  {args.eplb_dir}/{pod_b}")
    print()

    ranks = [args.rank] if args.rank is not None else list(range(4))

    for r in ranks:
        fa = find_trace_file(base_dir, pod_a, r)
        fb = find_trace_file(eplb_dir, pod_b, r)
        if fa is None:
            print(f"  dp{r}: baseline trace not found, skipping"); continue
        if fb is None:
            print(f"  dp{r}: EPLB trace not found, skipping"); continue

        print(f"{'#' * 80}")
        print(f"# dp{r} / EP rank {args.pod * 4 + r}")
        print(f"{'#' * 80}")
        print(f"  baseline: {fa.name}")
        print(f"  eplb:     {fb.name}")
        print()

        data_a = load_trace(fa)
        data_b = load_trace(fb)
        iters_a = extract_iterations(data_a["traceEvents"])
        iters_b = extract_iterations(data_b["traceEvents"])

        print_comparison("Baseline", "EPLB", iters_a, iters_b)


if __name__ == "__main__":
    main()
