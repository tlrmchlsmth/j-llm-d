#!/usr/bin/env python3
"""
Process ISL=8192 MC sweep results into CSV files matching the ISL=4096 format.
Extracts throughput, TTFT breakdown, ITL, and RDMA metrics from result_mc*.txt files.

Output: isl8192_mc_sweep/ directory with:
  - isl8192_mc_sweep-throughput.csv
  - isl8192_mc_sweep-ttft.csv
  - isl8192_mc_sweep-itl.csv
  - isl8192_mc_sweep-rdma_throughput.csv
"""

import csv
import os
import re
from pathlib import Path


def extract_metrics(result_file):
    with open(result_file) as f:
        text = f.read()

    m = {}
    bench_patterns = [
        (r"Request throughput \(req/s\):\s+([\d.]+)", "req_rps"),
        (r"Output token throughput \(tok/s\):\s+([\d.]+)", "output_tps"),
        (r"Total token throughput \(tok/s\):\s+([\d.]+)", "total_tps"),
        (r"Mean TTFT \(ms\):\s+([\d.]+)", "mean_ttft"),
        (r"Mean ITL \(ms\):\s+([\d.]+)", "mean_itl"),
        (r"Median ITL \(ms\):\s+([\d.]+)", "median_itl"),
        (r"P99 ITL \(ms\):\s+([\d.]+)", "p99_itl"),
    ]
    for pat, key in bench_patterns:
        match = re.findall(pat, text)
        m[key] = float(match[-1]) if match else None

    prom_pat = (
        r"System total.*?\n"
        r"\s*request_queue_time:\s+avg = ([\d.]+) s\s+\(count=\d+\)\s*\n"
        r"\s*request_prefill_time:\s+avg = ([\d.]+) s\s+\(count=\d+\)"
    )
    match = re.findall(prom_pat, text)
    if match:
        m["prefill_q_ms"] = float(match[-1][0]) * 1000
        m["prefill_time_ms"] = float(match[-1][1]) * 1000

    nixl_patterns = [
        (r"avg_xfer_time:\s+([\d.]+) ms", "xfer_time_ms"),
        (r"avg_post_time:\s+([\d.]+) ms", "post_time_ms"),
        (r"avg_mb_per_xfer:\s+([\d.]+) MB", "xfer_size_MB"),
    ]
    for pat, key in nixl_patterns:
        match = re.findall(pat, text)
        m[key] = float(match[-1]) if match else None

    return m


def process_scenario(base_dir, scenario_id):
    rails = "2" if "r2" in scenario_id else "1"
    sweep_dir = Path(base_dir) / f"isl8192_mc_sweep_scenario{scenario_id}"
    if not sweep_dir.is_dir():
        return {}

    results = {}
    for entry in sorted(sweep_dir.iterdir()):
        mc_match = re.search(r"_MC(\d+)$", entry.name)
        if not mc_match or not entry.is_dir():
            continue
        mc = int(mc_match.group(1))
        result_file = entry / f"result_mc{mc}.txt"
        if not result_file.exists():
            continue
        metrics = extract_metrics(str(result_file))
        if metrics.get("mean_ttft") is not None:
            results[mc] = metrics
    return results


def write_csvs(output_dir, prefix, scenarios, all_data):
    os.makedirs(output_dir, exist_ok=True)
    all_mcs = sorted(set(mc for data in all_data.values() for mc in data))
    labels = [f"s{s}" for s in scenarios]

    # Build fieldname lists matching ISL=4096 format
    tp_fields = ["mc"]
    ttft_fields = ["mc"]
    itl_fields = ["mc"]
    rdma_fields = ["mc"]
    for lbl in labels:
        tp_fields += [f"{lbl}-req_throughput_rps", f"{lbl}-output_tok_throughput_tps", f"{lbl}-total_tok_throughput_tps"]
        ttft_fields += [f"{lbl}-total_ttft", f"{lbl}-prefill_q", f"{lbl}-prefill_time", f"{lbl}-kv_xfer", f"{lbl}-residual"]
        itl_fields += [f"{lbl}-mean_itl_ms", f"{lbl}-median_itl_ms", f"{lbl}-p99_itl_ms"]
        rdma_fields += [f"{lbl}-avg_xfer_size_MB", f"{lbl}-avg_xfer_time_ms", f"{lbl}-avg_post_time_ms", f"{lbl}-kv_xfer_throughput_Gbps"]

    tp_rows, ttft_rows, itl_rows, rdma_rows = [], [], [], []

    for mc in all_mcs:
        tp_row = {"mc": mc}
        ttft_row = {"mc": mc}
        itl_row = {"mc": mc}
        rdma_row = {"mc": mc}

        for s, lbl in zip(scenarios, labels):
            m = all_data.get(s, {}).get(mc)
            if m is None:
                continue

            # Throughput
            for src, dst in [("req_rps", "req_throughput_rps"), ("output_tps", "output_tok_throughput_tps"), ("total_tps", "total_tok_throughput_tps")]:
                if m.get(src) is not None:
                    tp_row[f"{lbl}-{dst}"] = f"{m[src]:.2f}"

            # TTFT breakdown
            total_ttft = m.get("mean_ttft")
            pq = m.get("prefill_q_ms")
            pt = m.get("prefill_time_ms")
            xfer = m.get("xfer_time_ms")
            if all(v is not None for v in [total_ttft, pq, pt, xfer]):
                residual = total_ttft - pq - pt - xfer
                ttft_row[f"{lbl}-total_ttft"] = f"{total_ttft:.2f}"
                ttft_row[f"{lbl}-prefill_q"] = f"{pq:.2f}"
                ttft_row[f"{lbl}-prefill_time"] = f"{pt:.2f}"
                ttft_row[f"{lbl}-kv_xfer"] = f"{xfer:.3f}"
                ttft_row[f"{lbl}-residual"] = f"{residual:.2f}"

            # ITL
            for src, dst in [("mean_itl", "mean_itl_ms"), ("median_itl", "median_itl_ms"), ("p99_itl", "p99_itl_ms")]:
                if m.get(src) is not None:
                    itl_row[f"{lbl}-{dst}"] = f"{m[src]:.2f}"

            # RDMA throughput (using total xfer_time as denominator, matching ISL=4096)
            size = m.get("xfer_size_MB")
            xfer_t = m.get("xfer_time_ms")
            post_t = m.get("post_time_ms")
            if size is not None and xfer_t is not None and xfer_t > 0:
                kv_xfer_gbps = (size * 8.0) / xfer_t
                rdma_row[f"{lbl}-avg_xfer_size_MB"] = f"{size:.1f}"
                rdma_row[f"{lbl}-avg_xfer_time_ms"] = f"{xfer_t:.3f}"
                rdma_row[f"{lbl}-avg_post_time_ms"] = f"{post_t:.3f}" if post_t is not None else ""
                rdma_row[f"{lbl}-kv_xfer_throughput_Gbps"] = f"{kv_xfer_gbps:.2f}"

        tp_rows.append(tp_row)
        ttft_rows.append(ttft_row)
        itl_rows.append(itl_row)
        rdma_rows.append(rdma_row)

    def _write(path, rows, fields):
        with open(path, "w", newline="") as f:
            w = csv.DictWriter(f, fieldnames=fields, extrasaction="ignore")
            w.writeheader()
            w.writerows(rows)
        print(f"  Wrote {path} ({len(rows)} data rows)")

    _write(f"{output_dir}/{prefix}-throughput.csv", tp_rows, tp_fields)
    _write(f"{output_dir}/{prefix}-ttft.csv", ttft_rows, ttft_fields)
    _write(f"{output_dir}/{prefix}-itl.csv", itl_rows, itl_fields)
    _write(f"{output_dir}/{prefix}-rdma_throughput.csv", rdma_rows, rdma_fields)


if __name__ == "__main__":
    base = Path(__file__).parent.parent.parent / "results"
    output = Path(__file__).parent / "isl8192_mc_sweep"

    scenarios = ["1", "2r2", "3r2"]
    all_data = {}
    for s in scenarios:
        data = process_scenario(str(base), s)
        if data:
            all_data[s] = data
            print(f"Scenario {s}: MC values = {sorted(data.keys())}")
        else:
            print(f"Scenario {s}: no data found")

    write_csvs(str(output), "isl8192_mc_sweep", scenarios, all_data)
    print("\nDone.")
