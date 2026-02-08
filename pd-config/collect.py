#!/usr/bin/env python3
"""Collect pd-config benchmark results and generate CSV.

Reads results from kubectl logs of pd-config-bench Job pods. If pods have been
cleaned up, falls back to reading from hostPath /mnt/local/pd-config-results/
via transient reader pods.

Usage:
    python3 pd-config/collect.py [-n NAMESPACE] [-o OUTPUT_DIR]
"""

import argparse
import csv
import json
import re
import subprocess
import sys
import time
from collections import defaultdict
from dataclasses import dataclass

RESULTS_HOST_PATH = "/mnt/local/pd-config-results"
READER_IMAGE = "busybox:1.36"


@dataclass
class BenchResult:
    workload_type: str  # "prefill" or "decode"
    tp: int
    concurrency: int
    output_throughput: float  # Output token throughput (tok/s)
    total_throughput: float  # Total token throughput (tok/s)

    @property
    def raw_throughput(self) -> float:
        """Primary metric: output tok/s for decode, total tok/s for prefill."""
        if self.workload_type == "decode":
            return self.output_throughput
        return self.total_throughput

    @property
    def tpsg(self) -> float:
        """Throughput per GPU."""
        return self.raw_throughput / self.tp

    @property
    def tpsu(self) -> float:
        """Throughput per user (throughput / concurrency)."""
        return self.raw_throughput / self.concurrency


def parse_logs(log_text: str, workload_type: str, tp: int) -> list[BenchResult]:
    """Parse structured benchmark output."""
    results = []

    output_tp_re = re.compile(
        r"Output token throughput \(tok/s\):\s+([\d.]+)", re.IGNORECASE
    )
    total_tp_re = re.compile(
        r"Total Token throughput \(tok/s\):\s+([\d.]+)", re.IGNORECASE
    )
    bench_start_re = re.compile(r"BENCH_RUN: concurrency=(\d+)")
    bench_end_re = re.compile(r"BENCH_RUN_END: concurrency=(\d+)")

    current_concurrency = None
    current_output_tp = None
    current_total_tp = None

    for line in log_text.split("\n"):
        m = bench_start_re.search(line)
        if m:
            current_concurrency = int(m.group(1))
            current_output_tp = None
            current_total_tp = None
            continue

        if current_concurrency is None:
            continue

        m = output_tp_re.search(line)
        if m:
            current_output_tp = float(m.group(1))
            continue

        m = total_tp_re.search(line)
        if m:
            current_total_tp = float(m.group(1))
            continue

        m = bench_end_re.search(line)
        if m:
            if current_output_tp is not None and current_total_tp is not None:
                results.append(
                    BenchResult(
                        workload_type=workload_type,
                        tp=tp,
                        concurrency=current_concurrency,
                        output_throughput=current_output_tp,
                        total_throughput=current_total_tp,
                    )
                )
            else:
                print(
                    f"  WARNING: incomplete data for concurrency={current_concurrency}",
                    file=sys.stderr,
                )
            current_concurrency = None

    return results


def get_bench_pods(namespace: str) -> list[dict]:
    """Get all pd-config-bench pods with their labels."""
    cmd = [
        "kubectl", "-n", namespace, "get", "pods",
        "-l", "app=pd-config-bench",
        "-o", "json",
    ]
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        return []
    data = json.loads(result.stdout)
    return data.get("items", [])


def collect_from_pods(namespace: str) -> dict[str, str]:
    """Read logs from all pd-config-bench pods via kubectl logs.

    Returns dict of {job_name: log_contents}.
    """
    pods = get_bench_pods(namespace)
    logs = {}
    for pod in pods:
        labels = pod.get("metadata", {}).get("labels", {})
        job_name = labels.get("job-name", "")
        if not job_name:
            continue
        pod_name = pod["metadata"]["name"]
        phase = pod.get("status", {}).get("phase", "")
        if phase not in ("Succeeded", "Running"):
            print(f"  Skipping {pod_name} (phase={phase})")
            continue
        cmd = ["kubectl", "-n", namespace, "logs", pod_name]
        result = subprocess.run(cmd, capture_output=True, text=True)
        if result.returncode == 0 and result.stdout.strip():
            logs[f"{job_name}.log"] = result.stdout
    return logs


def get_result_nodes(namespace: str) -> set[str]:
    """Find all nodes that ran pd-config-bench pods (completed or running)."""
    pods = get_bench_pods(namespace)
    nodes = set()
    for pod in pods:
        node = pod.get("spec", {}).get("nodeName", "")
        if node:
            nodes.add(node)
    return nodes


def read_results_from_node(namespace: str, node: str) -> dict[str, str]:
    """Spawn a transient pod on a node to read all result files from hostPath.

    Returns dict of {filename: contents}.
    """
    pod_name = f"pd-config-reader-{node.replace('.', '-')[-20:]}"

    # Clean up any leftover reader pod
    subprocess.run(
        ["kubectl", "-n", namespace, "delete", "pod", pod_name,
         "--ignore-not-found=true"],
        capture_output=True, text=True,
    )

    cmd = [
        "kubectl", "-n", namespace, "run", pod_name,
        "--image", READER_IMAGE,
        "--restart=Never",
        "--overrides", json.dumps({
            "spec": {
                "nodeSelector": {"kubernetes.io/hostname": node},
                "containers": [{
                    "name": "reader",
                    "image": READER_IMAGE,
                    "command": ["sh", "-c",
                        f'for f in {RESULTS_HOST_PATH}/*.log; do '
                        'echo "===FILE:$(basename $f)==="; cat "$f"; '
                        'echo "===ENDFILE==="; done'
                    ],
                    "volumeMounts": [{"name": "results", "mountPath": RESULTS_HOST_PATH}],
                }],
                "volumes": [{
                    "name": "results",
                    "hostPath": {"path": RESULTS_HOST_PATH, "type": "DirectoryOrCreate"},
                }],
                "restartPolicy": "Never",
            },
        }),
    ]
    subprocess.run(cmd, capture_output=True, text=True)

    # Wait for pod to complete
    subprocess.run(
        ["kubectl", "-n", namespace, "wait", "--for=condition=Ready",
         f"pod/{pod_name}", "--timeout=30s"],
        capture_output=True, text=True,
    )
    for _ in range(30):
        check = subprocess.run(
            ["kubectl", "-n", namespace, "get", "pod", pod_name,
             "-o", "jsonpath={.status.phase}"],
            capture_output=True, text=True,
        )
        if check.stdout.strip() in ("Succeeded", "Failed"):
            break
        time.sleep(1)

    logs_result = subprocess.run(
        ["kubectl", "-n", namespace, "logs", pod_name],
        capture_output=True, text=True,
    )

    # Clean up
    subprocess.run(
        ["kubectl", "-n", namespace, "delete", "pod", pod_name,
         "--ignore-not-found=true"],
        capture_output=True, text=True,
    )

    # Parse the structured output into {filename: contents}
    files = {}
    current_file = None
    current_lines = []
    for line in logs_result.stdout.split("\n"):
        m = re.match(r"===FILE:(.+)===", line)
        if m:
            current_file = m.group(1)
            current_lines = []
            continue
        if line.strip() == "===ENDFILE===" and current_file:
            files[current_file] = "\n".join(current_lines)
            current_file = None
            current_lines = []
            continue
        if current_file is not None:
            current_lines.append(line)

    return files


def parse_job_name(filename: str) -> tuple[str, int] | None:
    """Extract workload_type and tp from a job name like pd-config-prefill-tp4.log."""
    m = re.match(r"pd-config-(prefill|decode)-tp(\d+)\.log", filename)
    if m:
        return m.group(1), int(m.group(2))
    return None


def write_csv(
    results: list[BenchResult],
    workload_type: str,
    isl: int,
    osl: int,
    output_path: str,
) -> None:
    """Write results in spreadsheet format matching the reference CSVs."""
    by_tp: dict[int, list[BenchResult]] = defaultdict(list)
    for r in results:
        by_tp[r.tp].append(r)

    for tp in by_tp:
        by_tp[tp].sort(key=lambda r: r.concurrency)

    max_cols = max(len(runs) for runs in by_tp.values())

    with open(output_path, "w", newline="") as f:
        w = csv.writer(f)

        label = "Prefill" if workload_type == "prefill" else "Decode"
        header = ["", label, f"ISL: {isl}", f"OSL: {osl}"] + [""] * max_cols
        w.writerow(header)
        w.writerow([""] * (max_cols + 4))

        for tp in sorted(by_tp.keys()):
            runs = by_tp[tp]
            concurrencies = [r.concurrency for r in runs]
            throughputs = [int(round(r.raw_throughput)) for r in runs]
            tpsgs = [int(round(r.tpsg)) for r in runs]
            tpsus = [int(round(r.tpsu)) for r in runs]

            w.writerow(["", "GPUs", "Concurrency"] + concurrencies)
            w.writerow(["", "", f"TP={tp}"] + throughputs)
            w.writerow(["", tp, "TPSG"] + tpsgs)
            w.writerow(["", "", "TPSU"] + tpsus)
            w.writerow([""] * (max_cols + 4))

    print(f"Written: {output_path}")


def main():
    parser = argparse.ArgumentParser(
        description="Collect pd-config benchmark results and generate CSV"
    )
    parser.add_argument(
        "--namespace", "-n", default="tms", help="Kubernetes namespace"
    )
    parser.add_argument(
        "--output-dir", "-o", default=".", help="Directory for output CSVs"
    )
    args = parser.parse_args()

    # Primary: collect from kubectl logs of existing pods
    print("Collecting results from pod logs...")
    all_logs = collect_from_pods(args.namespace)

    # Fallback: if no pods found, try hostPath reader pods
    if not all_logs:
        print("No pod logs available. Trying hostPath results...")
        nodes = get_result_nodes(args.namespace)
        if not nodes:
            print("No benchmark pods or hostPath results found.", file=sys.stderr)
            sys.exit(1)
        for node in sorted(nodes):
            print(f"  Reading from node {node}...")
            files = read_results_from_node(args.namespace, node)
            all_logs.update(files)

    if not all_logs:
        print("No benchmark results found.", file=sys.stderr)
        sys.exit(1)

    print(f"Found {len(all_logs)} result file(s)")

    # Parse all logs
    all_results: list[BenchResult] = []
    isl_osl: dict[str, tuple[int, int]] = {}

    for filename, contents in sorted(all_logs.items()):
        parsed = parse_job_name(filename)
        if not parsed:
            print(f"  Skipping {filename} (unrecognized name)")
            continue
        workload_type, tp = parsed
        results = parse_logs(contents, workload_type, tp)
        print(f"  {filename}: {len(results)} benchmark result(s)")
        all_results.extend(results)

        # Extract ISL/OSL from CONFIG line
        if workload_type not in isl_osl:
            m = re.search(r"CONFIG:.*isl=(\d+)\s+osl=(\d+)", contents)
            if m:
                isl_osl[workload_type] = (int(m.group(1)), int(m.group(2)))

    if not all_results:
        print("\nNo benchmark results parsed from logs", file=sys.stderr)
        sys.exit(1)

    for wt in ["prefill", "decode"]:
        wt_results = [r for r in all_results if r.workload_type == wt]
        if not wt_results:
            continue
        isl, osl = isl_osl.get(
            wt, (4096 if wt == "prefill" else 2, 1 if wt == "prefill" else 256)
        )
        output_path = f"{args.output_dir}/{wt}_scaling.csv"
        write_csv(wt_results, wt, isl, osl, output_path)

    print(f"\nTotal: {len(all_results)} benchmark results collected")


if __name__ == "__main__":
    main()
