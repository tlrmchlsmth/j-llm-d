#!/usr/bin/env python3
"""Detailed time-series analysis of NIC counter bursts.

Shows the throughput ramp-up, steady-state, and tail-off within individual
transfer bursts at microsecond resolution.
"""

import sys
import csv
from pathlib import Path


def parse_tsv(filepath):
    samples = []
    with open(filepath) as f:
        reader = csv.reader(f, delimiter='\t')
        next(reader)
        for row in reader:
            if len(row) < 3:
                continue
            samples.append((int(row[0]), int(row[1]), int(row[2])))
    return samples


def compute_instantaneous_throughput(samples, counter_idx, window_us=1000):
    """Compute throughput using a sliding window.
    
    counter_idx: 1=tx, 2=rx
    window_us: aggregation window in microseconds
    """
    if len(samples) < 2:
        return []

    window_ns = window_us * 1000
    results = []

    # Group samples into time windows
    base_ts = samples[0][0]
    i = 0
    while i < len(samples) - 1:
        win_start = samples[i][0]
        win_end = win_start + window_ns

        # Find all samples in this window
        j = i
        while j < len(samples) and samples[j][0] < win_end:
            j += 1

        if j > i and j < len(samples):
            val_start = samples[i][counter_idx]
            val_end = samples[j-1][counter_idx] if j-1 > i else val_start
            dt_ns = samples[j-1][0] - samples[i][0]

            if dt_ns > 0:
                # TSV values are already in bytes (C++ code ×4 from double words)
                d_bytes = val_end - val_start
                throughput_gbps = (d_bytes * 8) / dt_ns
                rel_time_ms = (win_start - base_ts) / 1e6
                results.append((rel_time_ms, throughput_gbps, d_bytes))

        i = max(j, i + 1)

    return results


def detect_bursts(samples, counter_idx, min_bytes=100_000_000, gap_ns=5_000_000):
    """Detect bursts with 5ms gap threshold for detailed analysis."""
    if len(samples) < 2:
        return []

    bursts = []
    current = None

    for i in range(1, len(samples)):
        prev_val = samples[i-1][counter_idx]
        curr_val = samples[i][counter_idx]
        d_bytes = curr_val - prev_val

        if d_bytes > 0:
            if current is None:
                current = {'start_idx': i-1, 'end_idx': i}
            elif (samples[i][0] - samples[current['end_idx']][0]) > gap_ns:
                # Finalize current burst
                total = samples[current['end_idx']][counter_idx] - samples[current['start_idx']][counter_idx]
                if total >= min_bytes:
                    bursts.append(current)
                current = {'start_idx': i-1, 'end_idx': i}
            else:
                current['end_idx'] = i
        else:
            if current is not None and (samples[i][0] - samples[current['end_idx']][0]) > gap_ns:
                total = samples[current['end_idx']][counter_idx] - samples[current['start_idx']][counter_idx]
                if total >= min_bytes:
                    bursts.append(current)
                current = None

    if current is not None:
        total = samples[current['end_idx']][counter_idx] - samples[current['start_idx']][counter_idx]
        if total >= min_bytes:
            bursts.append(current)

    return bursts


def analyze_burst_detail(samples, burst, counter_idx, burst_num, window_us=500):
    """Analyze a single burst's time-series throughput profile."""
    s = burst['start_idx']
    e = burst['end_idx']
    burst_samples = samples[s:e+1]

    total_bytes = burst_samples[-1][counter_idx] - burst_samples[0][counter_idx]
    dur_ms = (burst_samples[-1][0] - burst_samples[0][0]) / 1e6
    avg_gbps = (total_bytes * 8) / ((burst_samples[-1][0] - burst_samples[0][0])) if dur_ms > 0 else 0

    print(f"\n  Burst {burst_num}: {dur_ms:.1f} ms, {total_bytes/1e6:.1f} MB, avg {avg_gbps:.1f} Gbps, {len(burst_samples)} samples")

    ts = compute_instantaneous_throughput(burst_samples, counter_idx, window_us)
    if not ts:
        print("    No throughput windows computed")
        return None

    # Show time-series: first 10, every Nth in middle, last 10
    n = len(ts)
    show_indices = set()
    show_indices.update(range(min(10, n)))
    show_indices.update(range(max(0, n-10), n))
    step = max(1, n // 20)
    show_indices.update(range(0, n, step))
    show_indices = sorted(show_indices)

    print(f"    Time-series ({window_us}µs windows, {n} points):")
    print(f"    {'Time(ms)':>10} {'Tput(Gbps)':>12} {'Bytes(MB)':>10}")
    prev_idx = -1
    for idx in show_indices:
        if idx > prev_idx + 1 and prev_idx >= 0:
            print(f"    {'...':>10}")
        t, tput, b = ts[idx]
        print(f"    {t:10.2f} {tput:12.1f} {b/1e6:10.2f}")
        prev_idx = idx

    # Compute ramp-up, steady-state, tail stats
    throughputs = [t[1] for t in ts]
    if throughputs:
        peak = max(throughputs)
        threshold = peak * 0.8

        ramp_up_end = 0
        for i, tput in enumerate(throughputs):
            if tput >= threshold:
                ramp_up_end = i
                break

        tail_start = len(throughputs) - 1
        for i in range(len(throughputs) - 1, -1, -1):
            if throughputs[i] >= threshold:
                tail_start = i
                break

        ramp_up_ms = ts[ramp_up_end][0] - ts[0][0] if ramp_up_end > 0 else 0
        steady_ms = ts[tail_start][0] - ts[ramp_up_end][0] if tail_start > ramp_up_end else 0
        tail_ms = ts[-1][0] - ts[tail_start][0] if tail_start < len(ts) - 1 else 0

        steady_tputs = throughputs[ramp_up_end:tail_start+1]
        avg_steady = sum(steady_tputs) / len(steady_tputs) if steady_tputs else 0

        print(f"\n    Phase analysis (>{threshold:.0f} Gbps = 80% of peak {peak:.1f} Gbps):")
        print(f"      Ramp-up:      {ramp_up_ms:.1f} ms (to 80% of peak)")
        print(f"      Steady-state: {steady_ms:.1f} ms (avg {avg_steady:.1f} Gbps, {len(steady_tputs)} windows)")
        print(f"      Tail:         {tail_ms:.1f} ms")

    return ts


def main():
    if len(sys.argv) < 2:
        print("Usage: python analyze_nic_burst_detail.py <tsv_file> [burst_nums] [counter=rx|tx] [window_us]")
        print("Example: python analyze_nic_burst_detail.py results/nic_decode_mlx5_12.tsv 1,2,25 rx 500")
        sys.exit(1)

    filepath = Path(sys.argv[1])
    burst_nums = None
    if len(sys.argv) >= 3 and sys.argv[2] != "all":
        burst_nums = [int(x) for x in sys.argv[2].split(",")]
    counter_name = sys.argv[3] if len(sys.argv) >= 4 else "rx"
    window_us = int(sys.argv[4]) if len(sys.argv) >= 5 else 500

    counter_idx = 2 if counter_name == "rx" else 1

    print(f"Loading {filepath}...")
    samples = parse_tsv(filepath)
    print(f"  {len(samples)} samples loaded")
    if len(samples) < 2:
        print("  Not enough data")
        return

    ts_span_ms = (samples[-1][0] - samples[0][0]) / 1e6
    sample_interval_us = ts_span_ms * 1000 / len(samples)
    print(f"  Time span: {ts_span_ms:.1f} ms, avg interval: {sample_interval_us:.1f} µs/sample")

    bursts = detect_bursts(samples, counter_idx)
    print(f"  {len(bursts)} transfer bursts detected")

    if burst_nums is None:
        # Show first, middle, last
        burst_nums = [1]
        if len(bursts) > 2:
            burst_nums.append(len(bursts) // 2)
        if len(bursts) > 1:
            burst_nums.append(len(bursts))

    for bn in burst_nums:
        if bn < 1 or bn > len(bursts):
            print(f"\n  Burst {bn}: out of range (1-{len(bursts)})")
            continue
        analyze_burst_detail(samples, bursts[bn-1], counter_idx, bn, window_us)


if __name__ == "__main__":
    main()
