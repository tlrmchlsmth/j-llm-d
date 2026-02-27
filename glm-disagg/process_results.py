#!/usr/bin/env python3
"""
Process benchmark results from two configurations into comparison CSVs.

Usage:
    python process_results.py <dir_a> <dir_b> <output_dir>

Supports both QPS sweep (result_qpsN.txt) and concurrency sweep (result_mcN.txt).
Auto-detects sweep type from filenames. Both input dirs must use the same sweep type.

Produces:
    comparison_throughput.csv
    comparison_ttft.csv
    comparison_itl.csv
"""

import argparse
import os
import re
import csv
import sys


def detect_sweep_type(directory):
    """Return 'qps' or 'mc' based on result filenames in directory."""
    files = os.listdir(directory)
    qps_files = [f for f in files if re.match(r"result_qps\d+\.txt", f)]
    mc_files = [f for f in files if re.match(r"result_mc\d+\.txt", f)]
    if qps_files and not mc_files:
        return "qps"
    elif mc_files and not qps_files:
        return "mc"
    else:
        raise ValueError(
            f"Cannot determine sweep type for {directory}: "
            f"found {len(qps_files)} qps files and {len(mc_files)} mc files"
        )


def get_sweep_values(directory, sweep_type):
    """Return sorted list of integer sweep values from result filenames."""
    values = []
    for f in os.listdir(directory):
        m = re.match(rf"result_{sweep_type}(\d+)\.txt", f)
        if m:
            values.append(int(m.group(1)))
    return sorted(values)


def parse_bench_results(content):
    """Extract metrics from the last 'Serving Benchmark Result' block."""
    blocks = list(
        re.finditer(
            r"={10,} Serving Benchmark Result ={10,}\n(.*?)={50,}",
            content,
            re.DOTALL,
        )
    )
    if not blocks:
        return {}

    block = blocks[-1].group(1)
    data = {}
    patterns = {
        "request_throughput": r"Request throughput \(req/s\):\s+([\d.]+)",
        "output_tok_throughput": r"Output token throughput \(tok/s\):\s+([\d.]+)",
        "total_tok_throughput": r"Total token throughput \(tok/s\):\s+([\d.]+)",
        "mean_ttft_ms": r"Mean TTFT \(ms\):\s+([\d.]+)",
        "median_ttft_ms": r"Median TTFT \(ms\):\s+([\d.]+)",
        "p99_ttft_ms": r"P99 TTFT \(ms\):\s+([\d.]+)",
        "mean_itl_ms": r"Mean ITL \(ms\):\s+([\d.]+)",
        "median_itl_ms": r"Median ITL \(ms\):\s+([\d.]+)",
        "p99_itl_ms": r"P99 ITL \(ms\):\s+([\d.]+)",
    }
    for key, pattern in patterns.items():
        m = re.search(pattern, block)
        if m:
            data[key] = float(m.group(1))
    return data


def parse_prometheus_metrics(content):
    """Extract system-wide queue_time and prefill_time averages (in seconds)."""
    data = {}

    # QPS format: "System total (N prefill pods):" or "System total (N pods):"
    system_block = re.search(
        r"System total \(\d+ (?:prefill )?pods?\):\s*\n"
        r"\s*request_queue_time:\s+avg = ([\d.]+) s.*\n"
        r"\s*request_prefill_time:\s+avg = ([\d.]+) s",
        content,
    )
    if system_block:
        data["mean_queuing_s"] = float(system_block.group(1))
        data["mean_prefill_s"] = float(system_block.group(2))
        return data

    # Concurrency format: "PROMETHEUS_METRICS: concurrency=N"
    prom_block = re.search(
        r"PROMETHEUS_METRICS:.*\n"
        r"\s*request_queue_time:\s+avg = ([\d.]+) s.*\n"
        r"\s*request_prefill_time:\s+avg = ([\d.]+) s",
        content,
    )
    if prom_block:
        data["mean_queuing_s"] = float(prom_block.group(1))
        data["mean_prefill_s"] = float(prom_block.group(2))
        return data

    return data


def parse_nixl_metrics(content):
    """Extract NIXL KV transfer metrics, averaging across decode pods if multiple."""
    data = {}
    nixl_section = re.search(
        r"NIXL KV Transfer Metrics \(decode pods\):(.*?)(?:\n\n|\nStopping)",
        content,
        re.DOTALL,
    )
    if not nixl_section:
        return data

    section = nixl_section.group(1)
    pods = list(
        re.finditer(
            r"Decode [\d.]+:\s*\n"
            r"\s*total_transfers:\s+(\d+)\s*\n"
            r"\s*avg_xfer_time:\s+([\d.]+)\s+ms\s*\n"
            r"\s*avg_post_time:\s+([\d.]+)\s+ms\s*\n"
            r"\s*avg_mb_per_xfer:\s+([\d.]+)\s+MB\s*\n"
            r"\s*avg_descriptors:\s+(\d+)",
            section,
        )
    )
    if not pods:
        return data

    if len(pods) == 1:
        p = pods[0]
        data["avg_xfer_time_ms"] = float(p.group(2))
        data["avg_post_time_ms"] = float(p.group(3))
        data["avg_mb_per_xfer"] = float(p.group(4))
        data["avg_descriptors_per_xfer"] = int(p.group(5))
    else:
        # Weighted average by total_transfers
        total = 0
        w_xfer = 0.0
        w_post = 0.0
        w_mb = 0.0
        w_desc = 0
        for p in pods:
            n = int(p.group(1))
            total += n
            w_xfer += n * float(p.group(2))
            w_post += n * float(p.group(3))
            w_mb += n * float(p.group(4))
            w_desc += n * int(p.group(5))
        if total > 0:
            data["avg_xfer_time_ms"] = round(w_xfer / total, 3)
            data["avg_post_time_ms"] = round(w_post / total, 3)
            data["avg_mb_per_xfer"] = round(w_mb / total, 1)
            data["avg_descriptors_per_xfer"] = round(w_desc / total)

    return data


def parse_result_file(filepath):
    """Parse a single result file and return all extracted metrics."""
    with open(filepath) as f:
        content = f.read()

    data = parse_bench_results(content)
    data.update(parse_prometheus_metrics(content))
    data.update(parse_nixl_metrics(content))
    return data


def s_to_ms(val):
    """Convert seconds to milliseconds, returning None if val is None."""
    return val * 1000 if val is not None else None


def fmt(val, decimals=2):
    """Format a float to the given number of decimal places."""
    if val is None:
        return ""
    return f"{val:.{decimals}f}"


def main():
    parser = argparse.ArgumentParser(
        description="Process benchmark results into comparison CSVs"
    )
    parser.add_argument("dir_a", help="First results directory")
    parser.add_argument("dir_b", help="Second results directory")
    parser.add_argument("output_dir", help="Output directory for CSV files")
    args = parser.parse_args()

    sweep_a = detect_sweep_type(args.dir_a)
    sweep_b = detect_sweep_type(args.dir_b)
    if sweep_a != sweep_b:
        print(
            f"Error: sweep type mismatch: {args.dir_a} is '{sweep_a}', "
            f"{args.dir_b} is '{sweep_b}'",
            file=sys.stderr,
        )
        sys.exit(1)
    sweep_type = sweep_a

    label_a = os.path.basename(os.path.normpath(args.dir_a))
    label_b = os.path.basename(os.path.normpath(args.dir_b))

    values_a = set(get_sweep_values(args.dir_a, sweep_type))
    values_b = set(get_sweep_values(args.dir_b, sweep_type))
    common = sorted(values_a & values_b)
    if not common:
        print("Error: no common sweep values between directories", file=sys.stderr)
        sys.exit(1)

    results_a = {}
    results_b = {}
    for v in common:
        fname = f"result_{sweep_type}{v}.txt"
        ra = parse_result_file(os.path.join(args.dir_a, fname))
        rb = parse_result_file(os.path.join(args.dir_b, fname))
        if ra and rb:
            results_a[v] = ra
            results_b[v] = rb

    valid = sorted(v for v in common if v in results_a and v in results_b)
    if not valid:
        print("Error: no valid result pairs found", file=sys.stderr)
        sys.exit(1)

    # Detect which config is disagg (has NIXL metrics)
    has_nixl_a = any("avg_xfer_time_ms" in results_a[v] for v in valid)
    has_nixl_b = any("avg_xfer_time_ms" in results_b[v] for v in valid)
    disagg_results = None
    disagg_label = None
    if has_nixl_b:
        disagg_results = results_b
        disagg_label = label_b
    elif has_nixl_a:
        disagg_results = results_a
        disagg_label = label_a

    os.makedirs(args.output_dir, exist_ok=True)

    # --- comparison_throughput.csv ---
    tp_header = [
        sweep_type,
        f"{label_a}_req_throughput_rps",
        f"{label_b}_req_throughput_rps",
        f"{label_a}_output_tok_throughput_tps",
        f"{label_b}_output_tok_throughput_tps",
        f"{label_a}_total_tok_throughput_tps",
        f"{label_b}_total_tok_throughput_tps",
    ]
    tp_rows = []
    for v in valid:
        a, b = results_a[v], results_b[v]
        tp_rows.append([
            v,
            fmt(a.get("request_throughput")),
            fmt(b.get("request_throughput")),
            fmt(a.get("output_tok_throughput")),
            fmt(b.get("output_tok_throughput")),
            fmt(a.get("total_tok_throughput")),
            fmt(b.get("total_tok_throughput")),
        ])
    write_csv(os.path.join(args.output_dir, "comparison_throughput.csv"), tp_header, tp_rows)

    # --- comparison_ttft.csv ---
    ttft_header = [
        sweep_type,
        f"{label_a}_mean_ttft_ms",
        f"{label_a}_mean_queuing_ms",
        f"{label_a}_mean_prefill_ms",
        f"{label_b}_mean_ttft_ms",
        f"{label_b}_mean_queuing_ms",
        f"{label_b}_mean_prefill_ms",
        f"{label_a}_median_ttft_ms",
        f"{label_b}_median_ttft_ms",
        f"{label_a}_p99_ttft_ms",
        f"{label_b}_p99_ttft_ms",
    ]
    if disagg_label:
        ttft_header.extend([
            "avg_xfer_time_ms",
            "avg_post_time_ms",
            "avg_mb_per_xfer",
            "avg_descriptors_per_xfer",
        ])

    ttft_rows = []
    for v in valid:
        a, b = results_a[v], results_b[v]
        row = [
            v,
            fmt(a.get("mean_ttft_ms")),
            fmt(s_to_ms(a.get("mean_queuing_s"))),
            fmt(s_to_ms(a.get("mean_prefill_s"))),
            fmt(b.get("mean_ttft_ms")),
            fmt(s_to_ms(b.get("mean_queuing_s"))),
            fmt(s_to_ms(b.get("mean_prefill_s"))),
            fmt(a.get("median_ttft_ms")),
            fmt(b.get("median_ttft_ms")),
            fmt(a.get("p99_ttft_ms")),
            fmt(b.get("p99_ttft_ms")),
        ]
        if disagg_label:
            d = disagg_results[v]
            row.extend([
                fmt(d.get("avg_xfer_time_ms"), 3),
                fmt(d.get("avg_post_time_ms"), 3),
                fmt(d.get("avg_mb_per_xfer"), 1),
                fmt(d.get("avg_descriptors_per_xfer"), 0) if d.get("avg_descriptors_per_xfer") is not None else "",
            ])
        ttft_rows.append(row)
    write_csv(os.path.join(args.output_dir, "comparison_ttft.csv"), ttft_header, ttft_rows)

    # --- comparison_itl.csv ---
    itl_header = [
        sweep_type,
        f"{label_a}_mean_itl_ms",
        f"{label_b}_mean_itl_ms",
        f"{label_a}_median_itl_ms",
        f"{label_b}_median_itl_ms",
        f"{label_a}_p99_itl_ms",
        f"{label_b}_p99_itl_ms",
    ]
    itl_rows = []
    for v in valid:
        a, b = results_a[v], results_b[v]
        itl_rows.append([
            v,
            fmt(a.get("mean_itl_ms")),
            fmt(b.get("mean_itl_ms")),
            fmt(a.get("median_itl_ms")),
            fmt(b.get("median_itl_ms")),
            fmt(a.get("p99_itl_ms")),
            fmt(b.get("p99_itl_ms")),
        ])
    write_csv(os.path.join(args.output_dir, "comparison_itl.csv"), itl_header, itl_rows)

    print(f"Wrote {len(valid)} rows to {args.output_dir}/")
    print(f"  comparison_throughput.csv")
    print(f"  comparison_ttft.csv")
    print(f"  comparison_itl.csv")


def write_csv(path, header, rows):
    with open(path, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(header)
        w.writerows(rows)


if __name__ == "__main__":
    main()
