#!/usr/bin/env python3
"""
Correct KV transfer time measurements for decode-step polling artifacts.

At MC=1, the decode pod has no queued decode steps, so NIXL polling detects
transfer completion promptly. At higher MC, the polling loop is blocked by
decode steps, inflating the measured xfer_time.

Model:
  measured_xfer_time = actual_xfer_time + measurement_delay
  actual_xfer_time   = kv_size / true_network_throughput + post_time
  true_network_throughput = MC=1 rdma_throughput (constant per scenario)

Generates:
  - *-rdma_throughput_corrected.csv: corrected RDMA metrics + measurement_delay column
  - *-ttft_corrected.csv: corrected kv_xfer + adjusted residual (total_ttft preserved)
"""

import csv
import sys
from pathlib import Path


def read_csv(path):
    with open(path) as f:
        reader = csv.DictReader(f)
        return list(reader), reader.fieldnames


def write_csv(path, rows, fieldnames):
    with open(path, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)
    print(f"  Wrote {path}")


def get_scenarios(fieldnames, key_col):
    """Extract scenario prefixes from column names like 's1-avg_xfer_time_ms'."""
    prefixes = []
    for f in fieldnames:
        if f == key_col:
            continue
        prefix = f.rsplit("-", 1)[0]
        if prefix not in prefixes:
            prefixes.append(prefix)
    return sorted(set(prefixes))


def correct_rdma(rdma_path):
    rows, fieldnames = read_csv(rdma_path)
    scenarios = get_scenarios(fieldnames, "mc")

    mc1_row = next(r for r in rows if r["mc"] == "1")
    true_throughput = {}
    for s in scenarios:
        true_throughput[s] = float(mc1_row[f"{s}-rdma_throughput_Gbps"])

    new_fieldnames = list(fieldnames)
    for s in scenarios:
        delay_col = f"{s}-measurement_delay_ms"
        if delay_col not in new_fieldnames:
            idx = new_fieldnames.index(f"{s}-rdma_throughput_Gbps") + 1
            new_fieldnames.insert(idx, delay_col)

    corrected_rows = []
    for row in rows:
        new_row = dict(row)
        for s in scenarios:
            kv_size = float(row[f"{s}-avg_xfer_size_MB"])
            measured_xfer = float(row[f"{s}-avg_xfer_time_ms"])
            post_time = float(row[f"{s}-avg_post_time_ms"])

            corrected_eff = kv_size * 8.0 / true_throughput[s]
            corrected_xfer = corrected_eff + post_time
            delay = measured_xfer - corrected_xfer

            new_row[f"{s}-avg_xfer_time_ms"] = f"{corrected_xfer:.3f}"
            new_row[f"{s}-effective_xfer_time_ms"] = f"{corrected_eff:.3f}"
            new_row[f"{s}-rdma_throughput_Gbps"] = f"{true_throughput[s]:.2f}"
            new_row[f"{s}-measurement_delay_ms"] = f"{max(0, delay):.3f}"

        corrected_rows.append(new_row)

    out_path = rdma_path.replace("-rdma_throughput.csv", "-rdma_throughput_corrected.csv")
    write_csv(out_path, corrected_rows, new_fieldnames)
    return true_throughput, rows


def correct_ttft(ttft_path, true_throughput, rdma_rows):
    rows, fieldnames = read_csv(ttft_path)
    scenarios = get_scenarios(fieldnames, "mc")

    mc1_rdma = next(r for r in rdma_rows if r["mc"] == "1")

    new_fieldnames = list(fieldnames)
    for s in scenarios:
        delay_col = f"{s}-measurement_delay"
        if delay_col not in new_fieldnames:
            idx = new_fieldnames.index(f"{s}-residual") + 1
            new_fieldnames.insert(idx, delay_col)

    corrected_rows = []
    for row, rdma_row in zip(rows, rdma_rows):
        new_row = dict(row)
        for s in scenarios:
            total_ttft = float(row[f"{s}-total_ttft"])
            prefill_q = float(row[f"{s}-prefill_q"])
            prefill_time = float(row[f"{s}-prefill_time"])
            measured_kv_xfer = float(row[f"{s}-kv_xfer"])
            measured_residual = float(row[f"{s}-residual"])

            kv_size = float(rdma_row[f"{s}-avg_xfer_size_MB"])
            post_time = float(rdma_row[f"{s}-avg_post_time_ms"])

            corrected_eff_xfer = kv_size * 8.0 / true_throughput[s]
            corrected_kv_xfer = corrected_eff_xfer + post_time
            delay = measured_kv_xfer - corrected_kv_xfer
            corrected_residual = total_ttft - prefill_q - prefill_time - corrected_kv_xfer

            new_row[f"{s}-kv_xfer"] = f"{corrected_kv_xfer:.3f}"
            new_row[f"{s}-residual"] = f"{corrected_residual:.2f}"
            new_row[f"{s}-measurement_delay"] = f"{max(0, delay):.3f}"

        corrected_rows.append(new_row)

    out_path = ttft_path.replace("-ttft.csv", "-ttft_corrected.csv")
    write_csv(out_path, corrected_rows, new_fieldnames)


def process_dataset(base_dir, prefix):
    rdma_path = f"{base_dir}/{prefix}-rdma_throughput.csv"
    ttft_path = f"{base_dir}/{prefix}-ttft.csv"

    print(f"\nProcessing {prefix}:")
    true_throughput, rdma_rows = correct_rdma(rdma_path)

    print(f"  True RDMA throughput (from MC=1):")
    for s, t in sorted(true_throughput.items()):
        print(f"    {s}: {t:.2f} Gbps")

    correct_ttft(ttft_path, true_throughput, rdma_rows)


if __name__ == "__main__":
    base = Path(__file__).parent

    process_dataset(
        str(base / "isl4096_basic_mc_sweep"),
        "isl4096_basic_mc_sweep",
    )
    process_dataset(
        str(base / "isl4096_rails2_mc_sweep"),
        "isl4096_rails2_mc_sweep",
    )
