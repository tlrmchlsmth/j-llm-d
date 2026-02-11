#!/usr/bin/env python3
"""Collect pd-config benchmark results and generate CSV.

Reads results from kubectl logs of pd-config-bench Job pods. If pods have been
cleaned up, falls back to reading from hostPath /mnt/local/pd-config-results/
via transient reader pods.

Usage:
    python3 pd-config/collect.py [-n NAMESPACE] [-o OUTPUT_DIR]
    python3 pd-config/collect.py [-n NAMESPACE] --sheets "Spreadsheet Title"
"""

import argparse
import csv
import json
import math
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
    workload_type: str  # "prefill", "decode", or "aggregated"
    tp: int
    concurrency: int
    output_throughput: float  # Output token throughput (tok/s)
    total_throughput: float  # Total token throughput (tok/s)

    @property
    def raw_throughput(self) -> float:
        """Primary metric: output tok/s for decode/aggregated, total tok/s for prefill."""
        if self.workload_type in ("decode", "aggregated"):
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
    m = re.match(r"pd-config-(prefill|decode|agg)-tp(\d+)\.log", filename)
    if m:
        wt = m.group(1)
        if wt == "agg":
            wt = "aggregated"
        return wt, int(m.group(2))
    return None


def build_scaling_table(
    results: list[BenchResult],
    workload_type: str,
    isl: int,
    osl: int,
) -> list[list]:
    """Build the scaling table as a list of rows (for both CSV and Sheets)."""
    by_tp: dict[int, list[BenchResult]] = defaultdict(list)
    for r in results:
        by_tp[r.tp].append(r)

    for tp in by_tp:
        by_tp[tp].sort(key=lambda r: r.concurrency)

    max_cols = max(len(runs) for runs in by_tp.values())

    label = {"prefill": "Prefill", "decode": "Decode", "aggregated": "Aggregated"}.get(
        workload_type, workload_type.title()
    )
    rows = []
    rows.append(["", label, f"ISL: {isl}", f"OSL: {osl}"] + [""] * max_cols)
    rows.append([""] * (max_cols + 4))

    for tp in sorted(by_tp.keys()):
        runs = by_tp[tp]
        concurrencies = [r.concurrency for r in runs]
        throughputs = [int(round(r.raw_throughput)) for r in runs]
        tpsgs = [int(round(r.tpsg)) for r in runs]
        tpsus = [int(round(r.tpsu)) for r in runs]

        rows.append(["", "GPUs", "Concurrency"] + concurrencies)
        rows.append(["", "", f"TP={tp}"] + throughputs)
        rows.append(["", tp, "TPSG"] + tpsgs)
        rows.append(["", "", "TPSU"] + tpsus)
        rows.append([""] * (max_cols + 4))

    return rows


def build_pareto_data(results: list[BenchResult]) -> list[list]:
    """Build Pareto chart data in sparse layout for Google Sheets scatter chart.

    Each TP level gets its own block of rows. Column A = TPSU, and exactly one
    of the TP columns has the TPSG value (others blank). This lets the chart
    use column A as the shared X-axis while each series has independent points.
    """
    tp_values = sorted(set(r.tp for r in results))
    header = ["TPSU (tok/s/user)"] + [f"TP={tp} TPSG" for tp in tp_values]
    rows = [header]
    for tp in tp_values:
        tp_results = sorted(
            [r for r in results if r.tp == tp], key=lambda r: r.concurrency
        )
        col_idx = tp_values.index(tp)
        for r in tp_results:
            row = [int(round(r.tpsu))] + [""] * len(tp_values)
            row[col_idx + 1] = int(round(r.tpsg))
            rows.append(row)
    return rows


@dataclass
class DisaggPoint:
    """A disaggregated deployment point: decode + prefill GPU allocation."""
    tpsu: float        # T_d / C_d (user-facing throughput)
    tpsg: float        # T_d / (d_tp + p_gpus) (system GPU efficiency)
    d_tp: int           # decode tensor parallelism
    d_concurrency: int  # decode concurrency
    p_tp: int           # best prefill TP
    p_gpus: int         # prefill GPUs per decode replica
    total_gpus: int     # d_tp + p_gpus


def compute_disagg_points(
    prefill_results: list[BenchResult],
    decode_results: list[BenchResult],
    isl: int,
    osl: int,
) -> list[DisaggPoint]:
    """Compute disaggregated system metrics from isolated P/D sweep data.

    For each decode operating point, find the minimum prefill GPU cost
    to sustain the decode request rate. System TPSG accounts for both
    decode and prefill GPU allocation.
    """
    # Best prefill throughput for each P_tp (max across concurrencies)
    best_prefill: dict[int, float] = {}
    for r in prefill_results:
        if r.tp not in best_prefill or r.raw_throughput > best_prefill[r.tp]:
            best_prefill[r.tp] = r.raw_throughput

    if not best_prefill:
        return []

    points = []
    for r in decode_results:
        T_d = r.raw_throughput  # output tok/s
        request_rate = T_d / osl
        prefill_demand = request_rate * isl  # prefill tok/s needed

        # Find minimum prefill GPU cost across all P_tp options
        min_p_gpus = float("inf")
        best_p_tp = 0
        for p_tp, p_throughput in best_prefill.items():
            p_replicas = math.ceil(prefill_demand / p_throughput)
            p_gpus = p_replicas * p_tp
            if p_gpus < min_p_gpus:
                min_p_gpus = p_gpus
                best_p_tp = p_tp

        total_gpus = r.tp + int(min_p_gpus)
        system_tpsg = T_d / total_gpus
        system_tpsu = T_d / r.concurrency

        points.append(DisaggPoint(
            tpsu=system_tpsu,
            tpsg=system_tpsg,
            d_tp=r.tp,
            d_concurrency=r.concurrency,
            p_tp=best_p_tp,
            p_gpus=int(min_p_gpus),
            total_gpus=total_gpus,
        ))

    return points


def build_comparison_data(
    agg_results: list[BenchResult],
    disagg_points: list[DisaggPoint],
) -> list[list]:
    """Build comparison chart data in sparse layout for Google Sheets.

    Aggregated series by TP level + disaggregated series by decode TP level.
    """
    agg_tp_values = sorted(set(r.tp for r in agg_results))
    disagg_tp_values = sorted(set(p.d_tp for p in disagg_points))

    header = (
        ["TPSU (tok/s/user)"]
        + [f"Agg TP={tp}" for tp in agg_tp_values]
        + [f"Disagg D={tp}" for tp in disagg_tp_values]
    )
    num_agg = len(agg_tp_values)
    num_disagg = len(disagg_tp_values)
    total_cols = num_agg + num_disagg
    rows = [header]

    # Aggregated data
    for tp in agg_tp_values:
        tp_results = sorted(
            [r for r in agg_results if r.tp == tp], key=lambda r: r.concurrency
        )
        col_idx = agg_tp_values.index(tp)
        for r in tp_results:
            row = [int(round(r.tpsu))] + [""] * total_cols
            row[col_idx + 1] = int(round(r.tpsg))
            rows.append(row)

    # Disaggregated data
    for tp in disagg_tp_values:
        tp_points = sorted(
            [p for p in disagg_points if p.d_tp == tp], key=lambda p: p.d_concurrency
        )
        col_idx = num_agg + disagg_tp_values.index(tp)
        for p in tp_points:
            row = [int(round(p.tpsu))] + [""] * total_cols
            row[col_idx + 1] = int(round(p.tpsg))
            rows.append(row)

    return rows


def build_disagg_details(
    disagg_points: list[DisaggPoint],
    prefill_results: list[BenchResult],
    decode_results: list[BenchResult],
    isl: int,
    osl: int,
    sheet_start_row: int,
) -> list[list]:
    """Build details table with spreadsheet formulas showing GPU split derivation.

    All derived columns use formulas referencing constant cells so the math is
    visible and auditable in the spreadsheet.

    Args:
        sheet_start_row: 1-indexed row number where this block starts in the sheet.
    """
    # Best prefill throughput per TP
    best_prefill: dict[int, float] = {}
    for r in prefill_results:
        if r.tp not in best_prefill or r.raw_throughput > best_prefill[r.tp]:
            best_prefill[r.tp] = r.raw_throughput
    p_tp_values = sorted(best_prefill.keys())

    def col_letter(idx: int) -> str:
        return chr(ord("A") + idx)

    # Column layout:
    # A=D_TP  B=D_Concurrency  C=Decode_Output  D=Prefill_Demand
    # E..E+N-1=P_GPUs @TP=x   E+N=Best_P_GPUs  E+N+1=Total_GPUs
    # E+N+2=TPSU  E+N+3=TPSG
    pgpu_start = 4  # column E
    n_tp = len(p_tp_values)
    best_col = pgpu_start + n_tp
    total_col = best_col + 1
    tpsu_col = total_col + 1
    tpsg_col = tpsu_col + 1

    # Absolute sheet rows (1-indexed) for cell references
    const_row = sheet_start_row + 1
    cap_row = sheet_start_row + 2
    data_start_rel = 4  # relative row index within block

    # Row 0: Title
    title = ["Disaggregated GPU Split Derivation"]

    # Row 1: ISL / OSL constants (referenced by formulas)
    consts = ["ISL", isl, "OSL", osl]

    # Row 2: Prefill capacity values aligned under P_GPUs columns
    cap = ["", "", "", "Prefill Capacity (tok/s):"]
    for tp in p_tp_values:
        cap.append(int(round(best_prefill[tp])))

    # Row 3: Header
    header = (
        ["D_TP", "D_Concurrency", "Decode Output (tok/s)", "Prefill Demand (tok/s)"]
        + [f"P_GPUs @TP={tp}" for tp in p_tp_values]
        + ["Best P_GPUs", "Total GPUs", "TPSU (tok/s/user)", "TPSG (tok/s/GPU)"]
    )

    rows: list[list] = [title, consts, cap, header]

    # Data rows with formulas
    sorted_points = sorted(disagg_points, key=lambda p: (p.d_tp, p.d_concurrency))
    for i, p in enumerate(sorted_points):
        d_result = next(
            r for r in decode_results
            if r.tp == p.d_tp and r.concurrency == p.d_concurrency
        )
        R = sheet_start_row + data_start_rel + i  # absolute 1-indexed row

        row: list = [
            p.d_tp,                          # A: D_TP (value)
            p.d_concurrency,                 # B: D_Concurrency (value)
            round(d_result.raw_throughput, 1),  # C: Decode Output (value)
        ]

        # D: Prefill Demand = Decode_Output * ISL / OSL
        row.append(f"=C{R}*$B${const_row}/$D${const_row}")

        # P_GPUs @TP=N = CEILING(Prefill_Demand / Capacity_at_TP) * TP
        for j, tp in enumerate(p_tp_values):
            cap_cell = f"${col_letter(pgpu_start + j)}${cap_row}"
            row.append(f"=CEILING(D{R}/{cap_cell},1)*{tp}")

        # Best P_GPUs = MIN(all P_GPU columns)
        first = col_letter(pgpu_start)
        last = col_letter(pgpu_start + n_tp - 1)
        row.append(f"=MIN({first}{R}:{last}{R})")

        # Total GPUs = D_TP + Best P_GPUs
        row.append(f"=A{R}+{col_letter(best_col)}{R}")

        # TPSU = Decode Output / Concurrency
        row.append(f"=C{R}/B{R}")

        # TPSG = Decode Output / Total GPUs
        row.append(f"=C{R}/{col_letter(total_col)}{R}")

        rows.append(row)

    return rows


def extract_config(all_logs: dict[str, str]) -> dict[str, str]:
    """Extract experiment configuration from log contents."""
    config: dict[str, str] = {}
    for contents in all_logs.values():
        for line in contents.split("\n"):
            m = re.match(r"CONFIG:\s*(.+)", line)
            if m and "config_line" not in config:
                config["config_line"] = m.group(1)
                # Parse individual fields
                for field in re.findall(r"(\w+)=(\S+)", m.group(1)):
                    config[field[0]] = field[1]
            m = re.match(r"TARGET_DURATION:\s*(\S+)", line)
            if m and "target_duration" not in config:
                config["target_duration"] = m.group(1)
            m = re.match(r".*MIN_PROMPTS:\s*(\S+)", line)
            if m and "min_prompts" not in config:
                config["min_prompts"] = m.group(1)
            m = re.match(r"CONCURRENCY_LEVELS:\s*(.+)", line)
            if m:
                wt = config.get("workload", "")
                key = f"{wt}_concurrencies"
                if key not in config:
                    config[key] = m.group(1).strip()
    return config


def _fmt_bold(sheet_id: int, r0: int, r1: int,
              c0: int = 0, c1: int = 20) -> dict:
    """Helper: batchUpdate request to bold a cell range."""
    return {
        "repeatCell": {
            "range": {
                "sheetId": sheet_id,
                "startRowIndex": r0, "endRowIndex": r1,
                "startColumnIndex": c0, "endColumnIndex": c1,
            },
            "cell": {"userEnteredFormat": {"textFormat": {"bold": True}}},
            "fields": "userEnteredFormat.textFormat.bold",
        }
    }


def _fmt_center(sheet_id: int) -> dict:
    """Helper: batchUpdate request to center all cells in a sheet."""
    return {
        "repeatCell": {
            "range": {"sheetId": sheet_id},
            "cell": {"userEnteredFormat": {"horizontalAlignment": "CENTER"}},
            "fields": "userEnteredFormat.horizontalAlignment",
        }
    }


def _create_scatter_chart(
    sheet_id: int,
    title: str,
    start_row_idx: int,
    end_row_idx: int,
    num_series: int,
    anchor_row: int,
) -> dict:
    """Build an addChart batchUpdate request for a scatter chart."""
    series = []
    for i in range(num_series):
        series.append({
            "series": {
                "sourceRange": {
                    "sources": [{
                        "sheetId": sheet_id,
                        "startRowIndex": start_row_idx,
                        "endRowIndex": end_row_idx,
                        "startColumnIndex": i + 1,
                        "endColumnIndex": i + 2,
                    }]
                }
            },
            "targetAxis": "LEFT_AXIS",
        })
    return {
        "addChart": {
            "chart": {
                "spec": {
                    "title": title,
                    "basicChart": {
                        "chartType": "SCATTER",
                        "legendPosition": "BOTTOM_LEGEND",
                        "domains": [{
                            "domain": {
                                "sourceRange": {
                                    "sources": [{
                                        "sheetId": sheet_id,
                                        "startRowIndex": start_row_idx,
                                        "endRowIndex": end_row_idx,
                                        "startColumnIndex": 0,
                                        "endColumnIndex": 1,
                                    }]
                                }
                            }
                        }],
                        "series": series,
                        "axis": [
                            {
                                "position": "BOTTOM_AXIS",
                                "title": "Throughput per User (tok/s)",
                            },
                            {
                                "position": "LEFT_AXIS",
                                "title": "Throughput per GPU (tok/s)",
                            },
                        ],
                        "headerCount": 1,
                    },
                },
                "position": {
                    "overlayPosition": {
                        "anchorCell": {
                            "sheetId": sheet_id,
                            "rowIndex": anchor_row,
                            "columnIndex": 0,
                        },
                        "widthPixels": 800,
                        "heightPixels": 500,
                    }
                },
            }
        }
    }


def upload_to_sheets(
    all_results: list[BenchResult],
    isl_osl: dict[str, tuple[int, int]],
    spreadsheet_title: str,
    config: dict[str, str],
    disagg_points: list[DisaggPoint] | None = None,
) -> str:
    """Upload results to Google Sheets with Pareto charts. Returns spreadsheet URL."""
    try:
        import gspread
    except ImportError:
        print(
            "gspread is not installed. Run: uv pip install gspread google-auth-oauthlib",
            file=sys.stderr,
        )
        sys.exit(1)

    from pathlib import Path
    from datetime import datetime, timezone

    gc = gspread.oauth()

    sh = gc.create(spreadsheet_title)
    print(f"Created spreadsheet: {spreadsheet_title}")

    # --- Workload sheets (Prefill, Decode, Aggregated) ---
    for wt in ["prefill", "decode", "aggregated"]:
        wt_results = [r for r in all_results if r.workload_type == wt]
        if not wt_results:
            continue

        isl, osl = isl_osl.get(
            wt, (4096 if wt == "prefill" else 4096, 1 if wt == "prefill" else 256)
        )

        ws_title = wt.title()
        try:
            ws = sh.worksheet(ws_title)
            ws.clear()
        except gspread.exceptions.WorksheetNotFound:
            ws = sh.add_worksheet(title=ws_title, rows=100, cols=20)

        # Write scaling table
        table_rows = build_scaling_table(wt_results, wt, isl, osl)
        ws.update(range_name="A1", values=table_rows)

        # Formatting requests for this sheet
        num_tp = len(set(r.tp for r in wt_results))
        fmt_requests = [_fmt_center(ws.id), _fmt_bold(ws.id, 0, 1)]
        for tp_idx in range(num_tp):
            block_start = 2 + tp_idx * 5
            # Bold the label columns (B-C) for each TP block
            fmt_requests.append(_fmt_bold(ws.id, block_start, block_start + 4, 1, 3))

        # Pareto data + chart (decode only)
        if wt == "decode":
            pareto_start_row = len(table_rows) + 2
            pareto_rows = build_pareto_data(wt_results)
            ws.update(range_name=f"A{pareto_start_row}", values=pareto_rows)

            tp_values = sorted(set(r.tp for r in wt_results))
            num_data_rows = len(pareto_rows) - 1
            pareto_start_idx = pareto_start_row - 1
            pareto_end_idx = pareto_start_idx + len(pareto_rows)

            fmt_requests.append(
                _fmt_bold(ws.id, pareto_start_idx, pareto_start_idx + 1)
            )
            fmt_requests.append(_create_scatter_chart(
                ws.id,
                "Decode: GPU Efficiency vs User Throughput",
                pareto_start_idx, pareto_end_idx,
                len(tp_values),
                pareto_end_idx + 1,
            ))
            print(f"  {ws_title}: table ({len(table_rows)} rows) + "
                  f"Pareto chart ({num_data_rows} points, {len(tp_values)} series)")
        else:
            print(f"  {ws_title}: table ({len(table_rows)} rows)")

        sh.batch_update({"requests": fmt_requests})

    # --- Comparison sheet (aggregated vs disaggregated) ---
    agg_results = [r for r in all_results if r.workload_type == "aggregated"]
    if agg_results and disagg_points:
        comp_rows = build_comparison_data(agg_results, disagg_points)

        try:
            comp_ws = sh.worksheet("Comparison")
            comp_ws.clear()
        except gspread.exceptions.WorksheetNotFound:
            comp_ws = sh.add_worksheet(title="Comparison", rows=200, cols=20)

        # Disagg details table below chart data — shows GPU cost math
        prefill_results = [r for r in all_results if r.workload_type == "prefill"]
        decode_results = [r for r in all_results if r.workload_type == "decode"]
        d_isl = isl_osl.get("decode", (4096, 256))[0]
        d_osl = isl_osl.get("decode", (4096, 256))[1]
        detail_start_row = len(comp_rows) + 2  # 1-indexed
        detail_rows = build_disagg_details(
            disagg_points, prefill_results, decode_results, d_isl, d_osl,
            sheet_start_row=detail_start_row,
        )
        all_comp_rows = comp_rows + [[]] + detail_rows
        comp_ws.update(
            range_name="A1", values=all_comp_rows,
            value_input_option="USER_ENTERED",
        )

        comp_start_idx = 0
        comp_end_idx = len(comp_rows)
        num_series = len(comp_rows[0]) - 1  # all columns except TPSU
        detail_start_idx = detail_start_row - 1
        chart_anchor = detail_start_idx + len(detail_rows) + 1

        comp_fmt = [
            _fmt_center(comp_ws.id),
            _fmt_bold(comp_ws.id, 0, 1),  # chart data header
            _fmt_bold(comp_ws.id, detail_start_idx, detail_start_idx + 1),  # details title
            _fmt_bold(comp_ws.id, detail_start_idx + 3, detail_start_idx + 4),  # details header
            _create_scatter_chart(
                comp_ws.id,
                "Aggregated vs Disaggregated: GPU Efficiency",
                comp_start_idx, comp_end_idx,
                num_series,
                chart_anchor,
            ),
        ]
        sh.batch_update({"requests": comp_fmt})
        print(f"  Comparison: chart ({len(comp_rows)} rows, {num_series} series) + "
              f"details ({len(detail_rows)} rows)")

    # --- Config sheet ---
    try:
        cfg_ws = sh.worksheet("Config")
        cfg_ws.clear()
    except gspread.exceptions.WorksheetNotFound:
        cfg_ws = sh.add_worksheet(title="Config", rows=200, cols=5)

    tp_levels = sorted(set(r.tp for r in all_results))
    cfg_rows = [
        ["Experiment Configuration"],
        [],
        ["Model", config.get("model", "")],
        ["TP Levels", ", ".join(str(t) for t in tp_levels)],
        ["Target Duration", config.get("target_duration", "")],
        ["Min Prompts", config.get("min_prompts", "")],
        [],
    ]

    for wt in ["prefill", "decode", "aggregated"]:
        isl, osl = isl_osl.get(wt, ("", ""))
        if isl == "":
            continue
        concurrencies = config.get(f"{wt}_concurrencies", "")
        cfg_rows.append([f"{wt.title()} ISL / OSL", f"{isl} / {osl}"])
        cfg_rows.append([f"{wt.title()} Concurrencies", concurrencies])

    cfg_rows.append([])
    cfg_rows.append(["Timestamp", datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")])
    cfg_rows.append([])

    # Embed job.yaml
    yaml_path = Path(__file__).parent / "job.yaml"
    if yaml_path.exists():
        cfg_rows.append(["Job Template (job.yaml)"])
        yaml_header_row = len(cfg_rows) - 1
        for yaml_line in yaml_path.read_text().splitlines():
            cfg_rows.append([yaml_line])
    else:
        yaml_header_row = None

    cfg_ws.update(range_name="A1", values=cfg_rows)

    # Format config sheet
    cfg_fmt = [
        _fmt_bold(cfg_ws.id, 0, 1),  # title
        _fmt_bold(cfg_ws.id, 2, len(cfg_rows), 0, 1),  # bold column A (labels)
    ]
    if yaml_header_row is not None:
        cfg_fmt.append(_fmt_bold(cfg_ws.id, yaml_header_row, yaml_header_row + 1))
    sh.batch_update({"requests": cfg_fmt})
    print(f"  Config: {len(cfg_rows)} rows (includes job.yaml)")

    # Remove the default "Sheet1" if we created new sheets
    try:
        default_sheet = sh.worksheet("Sheet1")
        if len(sh.worksheets()) > 1:
            sh.del_worksheet(default_sheet)
    except gspread.exceptions.WorksheetNotFound:
        pass

    print(f"\nSpreadsheet URL: {sh.url}")
    return sh.url


def write_csv(
    results: list[BenchResult],
    workload_type: str,
    isl: int,
    osl: int,
    output_path: str,
) -> None:
    """Write results in spreadsheet format matching the reference CSVs."""
    rows = build_scaling_table(results, workload_type, isl, osl)
    with open(output_path, "w", newline="") as f:
        w = csv.writer(f)
        for row in rows:
            w.writerow(row)
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
    parser.add_argument(
        "--sheets", metavar="TITLE",
        help="Upload results to a Google Spreadsheet with Pareto charts",
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

    for wt in ["prefill", "decode", "aggregated"]:
        wt_results = [r for r in all_results if r.workload_type == wt]
        if not wt_results:
            continue
        isl, osl = isl_osl.get(
            wt, (4096 if wt == "prefill" else 4096, 1 if wt == "prefill" else 256)
        )
        output_path = f"{args.output_dir}/{wt}_scaling.csv"
        write_csv(wt_results, wt, isl, osl, output_path)

    # Compute disaggregated analytical model and comparison
    prefill_results = [r for r in all_results if r.workload_type == "prefill"]
    decode_results = [r for r in all_results if r.workload_type == "decode"]
    agg_results = [r for r in all_results if r.workload_type == "aggregated"]

    disagg_points = []
    if prefill_results and decode_results:
        isl = isl_osl.get("decode", (4096, 256))[0]
        osl = isl_osl.get("decode", (4096, 256))[1]
        disagg_points = compute_disagg_points(prefill_results, decode_results, isl, osl)
        if disagg_points:
            # Write comparison CSV
            comp_path = f"{args.output_dir}/comparison.csv"
            with open(comp_path, "w", newline="") as f:
                w = csv.writer(f)
                w.writerow([
                    "d_tp", "d_concurrency", "decode_throughput",
                    "p_tp", "p_gpus", "total_gpus", "tpsu", "tpsg",
                ])
                for p in sorted(disagg_points, key=lambda p: (p.d_tp, p.d_concurrency)):
                    d_result = next(
                        r for r in decode_results
                        if r.tp == p.d_tp and r.concurrency == p.d_concurrency
                    )
                    w.writerow([
                        p.d_tp, p.d_concurrency, int(round(d_result.raw_throughput)),
                        p.p_tp, p.p_gpus, p.total_gpus,
                        int(round(p.tpsu)), int(round(p.tpsg)),
                    ])
            print(f"Written: {comp_path}")

    print(f"\nTotal: {len(all_results)} benchmark results collected")

    # Upload to Google Sheets if requested
    if args.sheets:
        config = extract_config(all_logs)
        upload_to_sheets(
            all_results, isl_osl, args.sheets, config,
            disagg_points=disagg_points,
        )


if __name__ == "__main__":
    main()
