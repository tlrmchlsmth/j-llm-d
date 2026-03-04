#!/usr/bin/env python3
"""Analyze NIC counter TSV files from poll_nic_counters to extract per-transfer burst statistics."""

import sys
import csv
from pathlib import Path


def parse_tsv(filepath):
    """Parse a NIC counter TSV file. Returns list of (timestamp_ns, tx_bytes, rx_bytes)."""
    samples = []
    with open(filepath) as f:
        reader = csv.reader(f, delimiter='\t')
        header = next(reader)
        for row in reader:
            if len(row) < 3:
                continue
            ts = int(row[0])
            tx = int(row[1])
            rx = int(row[2])
            samples.append((ts, tx, rx))
    return samples


def detect_bursts(samples, counter_idx, min_bytes_per_burst=100_000_000, gap_threshold_ns=100_000_000):
    """Detect bursts of activity in a counter.
    
    counter_idx: 1 for tx, 2 for rx
    min_bytes_per_burst: minimum bytes delta to consider a real transfer (100 MB)
    gap_threshold_ns: max gap between samples in same burst (100ms)
    
    Returns list of dicts with burst stats.
    """
    if len(samples) < 2:
        return []

    # Find all intervals where counter is changing rapidly
    deltas = []
    for i in range(1, len(samples)):
        ts_prev, tx_prev, rx_prev = samples[i-1]
        ts_curr, tx_curr, rx_curr = samples[i]
        prev_val = (tx_prev, rx_prev)[counter_idx - 1]
        curr_val = (tx_curr, rx_curr)[counter_idx - 1]
        dt_ns = ts_curr - ts_prev
        d_bytes = curr_val - prev_val
        deltas.append((ts_prev, ts_curr, dt_ns, d_bytes, prev_val, curr_val))

    # Group consecutive active intervals into bursts
    bursts = []
    current_burst = None
    idle_ns = 0

    for ts_prev, ts_curr, dt_ns, d_bytes, prev_val, curr_val in deltas:
        if d_bytes > 0:
            if current_burst is None:
                current_burst = {
                    'start_ns': ts_prev,
                    'end_ns': ts_curr,
                    'start_val': prev_val,
                    'end_val': curr_val,
                    'total_bytes': d_bytes,
                    'active_samples': 1,
                }
            else:
                if (ts_prev - current_burst['end_ns']) > gap_threshold_ns:
                    # Too large a gap - finalize current burst
                    if current_burst['total_bytes'] >= min_bytes_per_burst:
                        bursts.append(current_burst)
                    current_burst = {
                        'start_ns': ts_prev,
                        'end_ns': ts_curr,
                        'start_val': prev_val,
                        'end_val': curr_val,
                        'total_bytes': d_bytes,
                        'active_samples': 1,
                    }
                else:
                    current_burst['end_ns'] = ts_curr
                    current_burst['end_val'] = curr_val
                    current_burst['total_bytes'] += d_bytes
                    current_burst['active_samples'] += 1
        else:
            # No change in counter
            if current_burst is not None:
                idle_ns += dt_ns
                if idle_ns > gap_threshold_ns:
                    if current_burst['total_bytes'] >= min_bytes_per_burst:
                        bursts.append(current_burst)
                    current_burst = None
                    idle_ns = 0
            continue

        idle_ns = 0

    # Don't forget last burst
    if current_burst is not None and current_burst['total_bytes'] >= min_bytes_per_burst:
        bursts.append(current_burst)

    return bursts


def analyze_file(filepath, label, counter_name="rx"):
    """Analyze a single NIC counter file."""
    samples = parse_tsv(filepath)
    if not samples:
        print(f"  {label}: No data")
        return None

    counter_idx = 2 if counter_name == "rx" else 1
    bursts = detect_bursts(samples, counter_idx)

    if not bursts:
        print(f"  {label}: {len(samples)} samples, no transfer bursts detected")
        return None

    print(f"\n{'='*70}")
    print(f"  {label}: {len(samples)} samples, {len(bursts)} transfer bursts detected")
    print(f"{'='*70}")

    durations_ms = []
    sizes_mb = []
    throughputs_gbps = []

    for i, b in enumerate(bursts):
        dur_ms = (b['end_ns'] - b['start_ns']) / 1e6
        size_mb = b['total_bytes'] / 1e6
        throughput_gbps = (b['total_bytes'] * 8) / ((b['end_ns'] - b['start_ns'])) if dur_ms > 0 else 0

        durations_ms.append(dur_ms)
        sizes_mb.append(size_mb)
        throughputs_gbps.append(throughput_gbps)

        if len(bursts) <= 20 or i < 5 or i >= len(bursts) - 3:
            print(f"    Burst {i+1:3d}: dur={dur_ms:8.3f} ms  size={size_mb:8.1f} MB  "
                  f"throughput={throughput_gbps:7.1f} Gbps  samples={b['active_samples']}")
        elif i == 5:
            print(f"    ... ({len(bursts) - 8} more bursts) ...")

    if durations_ms:
        avg_dur = sum(durations_ms) / len(durations_ms)
        avg_size = sum(sizes_mb) / len(sizes_mb)
        avg_tput = sum(throughputs_gbps) / len(throughputs_gbps)
        total_wire_time_s = sum(durations_ms) / 1000

        print(f"\n  Summary:")
        print(f"    Total bursts:       {len(bursts)}")
        print(f"    Avg duration:       {avg_dur:.3f} ms")
        print(f"    Avg size:           {avg_size:.1f} MB")
        print(f"    Avg throughput:     {avg_tput:.1f} Gbps")
        print(f"    Min throughput:     {min(throughputs_gbps):.1f} Gbps")
        print(f"    Max throughput:     {max(throughputs_gbps):.1f} Gbps")
        print(f"    Total wire time:    {total_wire_time_s:.3f} s")
        print(f"    Total data:         {sum(sizes_mb):.1f} MB")

    return {
        'bursts': bursts,
        'durations_ms': durations_ms,
        'sizes_mb': sizes_mb,
        'throughputs_gbps': throughputs_gbps,
    }


def main():
    if len(sys.argv) < 2:
        print("Usage: python analyze_nic_counters.py <results_dir>")
        print("Example: python analyze_nic_counters.py results/phase1_nic_profile_isl4096_vf")
        sys.exit(1)

    results_dir = Path(sys.argv[1])

    print("=" * 70)
    print("NIC Counter Analysis - Wire-Level KV Transfer Profiling")
    print("=" * 70)

    # Decode side: RX counters (receiving RDMA READ CplD data)
    for dev in ["mlx5_12", "mlx5_13"]:
        f = results_dir / f"nic_decode_{dev}.tsv"
        if f.exists():
            analyze_file(f, f"Decode {dev} (RX - incoming KV data)", "rx")

    # Prefill side: TX counters (sending RDMA READ CplD data)
    for dev in ["mlx5_12", "mlx5_13"]:
        f = results_dir / f"nic_prefill_{dev}.tsv"
        if f.exists():
            analyze_file(f, f"Prefill {dev} (TX - outgoing KV data)", "tx")

    # Also check prefill RX (RDMA READ requests, should be small)
    print(f"\n{'='*70}")
    print("Prefill RX (RDMA READ requests - should be small)")
    print("=" * 70)
    for dev in ["mlx5_12", "mlx5_13"]:
        f = results_dir / f"nic_prefill_{dev}.tsv"
        if f.exists():
            analyze_file(f, f"Prefill {dev} (RX - incoming MRd requests)", "rx")


if __name__ == "__main__":
    main()
