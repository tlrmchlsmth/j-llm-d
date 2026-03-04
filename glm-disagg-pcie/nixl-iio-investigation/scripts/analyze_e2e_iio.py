#!/usr/bin/env python3
"""Analyze end-to-end NIXL IIO measurement results.

Parses perf stat output + benchmark metrics to compute duty-cycle-corrected
IIO rates during active transfers and compares with ib_read_bw baseline.
"""

import re
import sys
from pathlib import Path


# --- IIO Event Names ---
EVENT_NAMES = {
    "0xd5,umask=0xff": "COMP_BUF_OCC",
    "0xc2,umask=0x04": "COMP_BUF_INS",
    "0xd0,umask=0x08": "OUTBOUND_CL",
    "0x86,umask=0x08": "ARB_REQ",
    "0x8e,umask=0x20": "LOC_P2P",
}

IIO_NAMES = {
    "5": "IIO5 (GPU0+4, Stack2/PCIe0)",
    "11": "IIO11 (GPU1+5, Stack6/PCIe2)",
    "2": "IIO2 (NIC_mlx5_3+GPU2+6, Stack9/PCIe4)",
    "7": "IIO7 (NIC_mlx5_4+GPU3+7, Stack4/PCIe1)",
}


def parse_perf_stat(filepath):
    """Parse perf stat output file. Returns dict of (iio_unit, event_name) -> count."""
    counters = {}
    elapsed_s = None
    with open(filepath) as f:
        for line in f:
            line = line.strip()
            # Parse counter lines: "   1234567   uncore_iio_5/event=0xd5,umask=0xff,.../
            m = re.match(r'(\d+)\s+uncore_iio_(\d+)/event=(0x[0-9a-f]+),umask=(0x[0-9a-f]+)', line)
            if m:
                count = int(m.group(1))
                iio_unit = m.group(2)
                event_key = f"{m.group(3)},{f'umask={m.group(4)}'}"
                event_name = EVENT_NAMES.get(event_key, event_key)
                counters[(iio_unit, event_name)] = count
            # Parse elapsed time
            m = re.match(r'([\d.]+)\s+seconds time elapsed', line)
            if m:
                elapsed_s = float(m.group(1))
    return counters, elapsed_s


def parse_metrics(filepath):
    """Parse the benchmark metrics summary (metrics_mc1.txt).
    Returns dict with NIXL metrics.
    """
    metrics = {}
    with open(filepath) as f:
        for line in f:
            line = line.strip()
            if "total_transfers:" in line:
                metrics['n_transfers'] = int(line.split()[-1])
            elif "avg_xfer_time:" in line:
                metrics['avg_xfer_time_ms'] = float(line.split()[-2])
            elif "avg_post_time:" in line:
                metrics['avg_post_time_ms'] = float(line.split()[-2])
            elif "avg_mb_per_xfer:" in line:
                metrics['avg_mb_per_xfer'] = float(line.split()[-2])
            elif "avg_descriptors:" in line:
                metrics['avg_descriptors'] = int(line.split()[-1])
    return metrics


def analyze_experiment(results_dir, isl, wire_duration_ms=None):
    """Analyze a single experiment's results."""
    results_dir = Path(results_dir)

    print(f"\n{'='*80}")
    print(f"  E2E NIXL IIO Analysis: ISL={isl}")
    print(f"  Results: {results_dir}")
    print(f"{'='*80}")

    # Parse metrics
    metrics_file = results_dir / "metrics_mc1.txt"
    metrics = parse_metrics(metrics_file) if metrics_file.exists() else {}

    if metrics:
        n = metrics['n_transfers']
        avg_xfer = metrics['avg_xfer_time_ms']
        avg_post = metrics['avg_post_time_ms']
        avg_mb = metrics['avg_mb_per_xfer']
        avg_desc = metrics['avg_descriptors']

        print(f"\n  NIXL Metrics (from Prometheus):")
        print(f"    Transfers:       {n}")
        print(f"    Avg xfer time:   {avg_xfer:.1f} ms")
        print(f"    Avg post time:   {avg_post:.1f} ms")
        print(f"    Avg size:        {avg_mb:.1f} MB")
        print(f"    Avg descriptors: {avg_desc}")

        # Compute active time estimates
        t_sw = n * (avg_xfer - avg_post) / 1000  # software-level active time
        if wire_duration_ms:
            n_total = n + (n * 20 // 50)  # estimate total including calibration
            t_wire = n_total * wire_duration_ms / 1000
            print(f"\n  Active Transfer Time Estimates:")
            print(f"    T_sw  (N * (xfer-post)):  {t_sw:.2f} s  (main run only, {n} transfers)")
            print(f"    T_wire (from NIC counters): {t_wire:.2f} s  (~{n_total} total transfers)")
        else:
            t_wire = None
            print(f"\n  Active Transfer Time:")
            print(f"    T_sw  (N * (xfer-post)):  {t_sw:.2f} s  (main run only, {n} transfers)")

    # Parse perf stat
    for role, node_label in [("prefill", "PREFILL (responder)"), ("decode", "DECODE (requester)")]:
        perf_file = results_dir / f"perf_{role}_isl{isl}.txt"
        if not perf_file.exists():
            print(f"\n  {node_label}: perf stat file not found")
            continue

        counters, elapsed_s = parse_perf_stat(perf_file)

        print(f"\n  {node_label} IIO Counters (perf stat, {elapsed_s:.0f}s elapsed):")
        print(f"  {'IIO Unit':<45} {'Event':<15} {'Total':>15} {'Raw /s':>12} {'DC-corr /s':>12}")
        print(f"  {'-'*45} {'-'*15} {'-'*15} {'-'*12} {'-'*12}")

        for (iio_unit, event_name), count in sorted(counters.items()):
            iio_label = IIO_NAMES.get(iio_unit, f"IIO{iio_unit}")
            raw_rate = count / elapsed_s if elapsed_s else 0

            # Duty-cycle corrected rate
            if metrics and t_wire:
                dc_rate = count / t_wire
                dc_str = f"{dc_rate/1e6:>10.1f} M"
            elif metrics:
                dc_rate = count / t_sw if t_sw > 0 else 0
                dc_str = f"{dc_rate/1e6:>10.1f} M"
            else:
                dc_str = "N/A"

            print(f"  {iio_label:<45} {event_name:<15} {count:>15,} {raw_rate/1e6:>10.1f} M {dc_str}")

        # Compute COMP_BUF residence time for GPU stacks
        for iio_unit in ["5", "11"]:
            occ = counters.get((iio_unit, "COMP_BUF_OCC"), 0)
            ins = counters.get((iio_unit, "COMP_BUF_INS"), 0)
            if ins > 0:
                residence = occ / ins
                residence_us = residence / 1000  # assuming ~1 GHz IIO clock
                print(f"\n    IIO{iio_unit} COMP_BUF residence: {residence:.0f} cycles "
                      f"(~{residence_us:.2f} us @ 1 GHz)")

        # Also for NIC stacks
        for iio_unit in ["2", "7"]:
            occ = counters.get((iio_unit, "COMP_BUF_OCC"), 0)
            ins = counters.get((iio_unit, "COMP_BUF_INS"), 0)
            if ins > 0:
                residence = occ / ins
                residence_us = residence / 1000
                print(f"    IIO{iio_unit} COMP_BUF residence: {residence:.0f} cycles "
                      f"(~{residence_us:.2f} us @ 1 GHz)")

    # Per-NIC throughput from NIC counter data
    if metrics:
        tput_per_nic = (avg_mb * 8) / avg_xfer  # Gbps
        tput_total = tput_per_nic * 2  # 2 NICs
        print(f"\n  Effective NIXL Throughput:")
        print(f"    Per NIC:   {tput_per_nic:.1f} Gbps  ({avg_mb:.0f} MB / {avg_xfer:.0f} ms)")
        print(f"    Total:     {tput_total:.1f} Gbps  (2 NICs)")


def print_baseline_comparison():
    """Print ib_read_bw baseline rates from prior investigation."""
    print(f"\n{'='*80}")
    print(f"  ib_read_bw Baseline (from prior IIO investigation, per GPU stack)")
    print(f"{'='*80}")
    print(f"  {'Metric':<30} {'2MB msgs':>12} {'16KB msgs':>12}")
    print(f"  {'-'*30} {'-'*12} {'-'*12}")
    print(f"  {'COMP_BUF_INS/s':<30} {'496 M':>12} {'287 M':>12}")
    print(f"  {'COMP_BUF residence (cycles)':<30} {'1,631':>12} {'2,479':>12}")
    print(f"  {'Throughput per NIC (Gbps)':<30} {'~254':>12} {'~148':>12}")
    print(f"  {'COMP_BUF residence (us)':<30} {'~1.6':>12} {'~2.5':>12}")
    print()
    print(f"  Note: Baseline was measured with 2 flows (1 per GPU stack) on Socket 1.")
    print(f"  NIXL uses 2 NICs shared by 8 GPUs (both sockets), with 40,960-81,920")
    print(f"  scattered 16KB descriptors per transfer vs ib_read_bw's contiguous buffer.")


def main():
    base = Path("/home/rajjoshi/workspace/j-llm-d-blog/glm-disagg-pcie/nixl-iio-investigation/results")

    print("=" * 80)
    print("  End-to-End NIXL IIO Measurement Analysis")
    print("  Model: Llama-3.3-70B-Instruct-FP8, TP=16, Scenario 2r2")
    print("  2 NICs (mlx5_3/VF, mlx5_4/VF) shared by 8 GPUs, UCX_MAX_RMA_RAILS=2")
    print("=" * 80)

    # Wire duration from Phase 1 NIC profiling
    wire_4096_ms = 200.3  # from analyze_nic_counters.py
    wire_8192_ms = None    # not measured yet

    # ISL=4096
    analyze_experiment(base / "e2e_s2r2_isl4096", 4096, wire_duration_ms=wire_4096_ms)

    # ISL=8192
    analyze_experiment(base / "e2e_s2r2_isl8192", 8192, wire_duration_ms=wire_8192_ms)

    # Baseline comparison
    print_baseline_comparison()

    # Summary
    print(f"\n{'='*80}")
    print(f"  SUMMARY: NIXL vs ib_read_bw IIO Rate Comparison (Prefill GPU Stacks)")
    print(f"{'='*80}")
    print(f"  {'Workload':<35} {'COMP_BUF_INS/s':>15} {'Residence':>12} {'Tput/NIC':>10}")
    print(f"  {'-'*35} {'-'*15} {'-'*12} {'-'*10}")
    print(f"  {'ib_read_bw 2MB':<35} {'496 M':>15} {'1,631 cy':>12} {'254 Gbps':>10}")
    print(f"  {'ib_read_bw 16KB':<35} {'287 M':>15} {'2,479 cy':>12} {'148 Gbps':>10}")

    # Compute NIXL rates from ISL=4096
    f4096 = base / "e2e_s2r2_isl4096"
    if (f4096 / "perf_prefill_isl4096.txt").exists():
        c, _ = parse_perf_stat(f4096 / "perf_prefill_isl4096.txt")
        n_total_4096 = 70  # 20 calib + 50 main
        t_wire_4096 = n_total_4096 * wire_4096_ms / 1000
        ins5 = c.get(("5", "COMP_BUF_INS"), 0)
        occ5 = c.get(("5", "COMP_BUF_OCC"), 0)
        ins11 = c.get(("11", "COMP_BUF_INS"), 0)
        avg_ins = (ins5 + ins11) / 2 / t_wire_4096
        avg_res = (occ5/ins5 + c.get(("11", "COMP_BUF_OCC"), 0)/ins11) / 2
        print(f"  {'NIXL ISL=4096 (DC-corrected)':<35} {avg_ins/1e6:>13.0f} M {avg_res:>10,.0f} cy {'27 Gbps':>10}")

    # ISL=8192
    f8192 = base / "e2e_s2r2_isl8192"
    if (f8192 / "perf_prefill_isl8192.txt").exists():
        c, _ = parse_perf_stat(f8192 / "perf_prefill_isl8192.txt")
        m8192 = parse_metrics(f8192 / "metrics_mc1.txt")
        n8192 = m8192['n_transfers']
        t_sw_8192 = n8192 * (m8192['avg_xfer_time_ms'] - m8192['avg_post_time_ms']) / 1000
        # Estimate total transfers (main + calib)
        n_total_8192 = 50  # 20 calib + 30 main
        t_sw_total = n_total_8192 * (m8192['avg_xfer_time_ms'] - m8192['avg_post_time_ms']) / 1000
        ins5 = c.get(("5", "COMP_BUF_INS"), 0)
        occ5 = c.get(("5", "COMP_BUF_OCC"), 0)
        ins11 = c.get(("11", "COMP_BUF_INS"), 0)
        avg_ins = (ins5 + ins11) / 2 / t_sw_total
        avg_res = (occ5/ins5 + c.get(("11", "COMP_BUF_OCC"), 0)/ins11) / 2
        tput = (m8192['avg_mb_per_xfer'] * 8) / m8192['avg_xfer_time_ms']
        print(f"  {'NIXL ISL=8192 (T_sw corrected)':<35} {avg_ins/1e6:>13.0f} M {avg_res:>10,.0f} cy {tput:>8.0f} Gbps")

    print()


if __name__ == "__main__":
    main()
