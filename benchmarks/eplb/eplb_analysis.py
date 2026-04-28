"""EPLB benchmark analysis utilities.

Loaders for collected run data (config, Prometheus metrics, expert load dumps)
and visualization functions for comparing EPLB configurations.

Usage:
    from eplb_analysis import load_run, load_expert_data, RunData
    run = load_run("pd-async-eplb")
    expert = load_expert_data(run)
"""

from __future__ import annotations

import json
import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Literal

import matplotlib.pyplot as plt
import numpy as np
import pandas as pd

plt.rcParams.update({"figure.dpi": 120, "figure.facecolor": "white"})

RESULTS_DIR = Path(__file__).parent

LoadType = Literal["window", "latest"]
LOAD_TYPE_KEY: dict[LoadType, str] = {
    "window": "window_expert_load",
    "latest": "latest_expert_load",
}

# ---------------------------------------------------------------------------
# Data structures
# ---------------------------------------------------------------------------


@dataclass
class RunConfig:
    """Parsed config.env for a benchmark run."""

    name: str
    raw: dict[str, str]

    @property
    def mode(self) -> str:
        return self.raw.get("MODE", "unknown")

    @property
    def eplb_enabled(self) -> bool:
        return self.raw.get("DECODE_EPLB_ENABLED", "").lower() == "true"

    @property
    def eplb_async(self) -> bool:
        return self.raw.get("DECODE_EPLB_USE_ASYNC", "").lower() == "true"

    @property
    def prefill_eplb_enabled(self) -> bool:
        val = self.raw.get("PREFILL_EPLB_ENABLED", "")
        return "true" in val.lower()

    @property
    def eplb_mode(self) -> str:
        if not self.eplb_enabled:
            return "off"
        return "async" if self.eplb_async else "sync"

    @property
    def eplb_scope(self) -> str:
        """Where EPLB is enabled: 'decode+prefill', 'decode', 'prefill', or 'none'."""
        d = self.eplb_enabled
        p = self.prefill_eplb_enabled
        if d and p:
            return "decode+prefill"
        if d:
            return "decode"
        if p:
            return "prefill"
        return "none"

    @property
    def decode_a2a_backend(self) -> str:
        return self.raw.get("DECODE_A2A_BACKEND", "unknown")

    @property
    def step_interval(self) -> int:
        return int(self.raw.get("DECODE_EPLB_STEP_INTERVAL", "3000"))

    @property
    def num_redundant(self) -> int:
        return int(self.raw.get("DECODE_EPLB_NUM_REDUNDANT_EXPERTS", "32"))

    @property
    def lws_size(self) -> int:
        return int(self.raw.get("DECODE_LWS_SIZE", "4"))

    @property
    def decode_replicas(self) -> int | None:
        v = self.raw.get("DECODE_LWS_REPLICAS")
        return int(v) if v else None

    @property
    def decode_group_size(self) -> int | None:
        v = self.raw.get("DECODE_LWS_GROUP_SIZE")
        return int(v) if v else None

    @property
    def prefill_replicas(self) -> int | None:
        v = self.raw.get("PREFILL_LWS_REPLICAS")
        return int(v) if v else None

    @property
    def prefill_group_size(self) -> int | None:
        v = self.raw.get("PREFILL_LWS_GROUP_SIZE")
        return int(v) if v else None

    @property
    def decode_pods(self) -> int | None:
        """Total decode pods (replicas * group_size)."""
        r, g = self.decode_replicas, self.decode_group_size
        return r * g if r is not None and g is not None else None

    @property
    def prefill_pods(self) -> int | None:
        """Total prefill pods (replicas * group_size)."""
        r, g = self.prefill_replicas, self.prefill_group_size
        return r * g if r is not None and g is not None else None

    @property
    def model(self) -> str:
        return self.raw.get("MODEL", "unknown")

    @property
    def dataset(self) -> str:
        return self.raw.get("DATASET", "sharegpt")

    @property
    def sweep_min(self) -> int | None:
        v = self.raw.get("SWEEP_MIN")
        return int(v) if v else None

    @property
    def sweep_max(self) -> int | None:
        v = self.raw.get("SWEEP_MAX")
        return int(v) if v else None

    @property
    def sweep_steps(self) -> int | None:
        v = self.raw.get("SWEEP_STEPS")
        return int(v) if v else None

    @property
    def warmup_concurrency(self) -> int | None:
        v = self.raw.get("WARMUP_CONCURRENCY")
        return int(v) if v else None

    @property
    def prom_start_ts(self) -> int | None:
        v = self.raw.get("PROM_START_TS")
        return int(v) if v else None

    @property
    def prom_end_ts(self) -> int | None:
        v = self.raw.get("PROM_END_TS")
        return int(v) if v else None

    @property
    def prom_duration_s(self) -> int | None:
        v = self.raw.get("PROM_DURATION_S")
        return int(v) if v else None

    @property
    def model_short(self) -> str:
        """Short model name (last path component)."""
        m = self.model
        return m.rsplit("/", 1)[-1] if "/" in m else m

    @property
    def topology_str(self) -> str:
        """Human-readable topology: 'D=4 P=2' or 'D=4'."""
        parts = []
        dp = self.decode_pods
        if dp is not None:
            parts.append(f"D={dp}")
        pp = self.prefill_pods
        if pp is not None:
            parts.append(f"P={pp}")
        return " ".join(parts) if parts else "?"

    @property
    def label(self) -> str:
        """Short human-readable label for plots."""
        return f"{self.mode}/{self.eplb_mode}"

    @property
    def decode_log_balancedness(self) -> bool:
        return self.raw.get("DECODE_EPLB_LOG_BALANCEDNESS", "").lower() == "true"

    @property
    def prefill_log_balancedness(self) -> bool:
        return self.raw.get("PREFILL_EPLB_LOG_BALANCEDNESS", "").lower() == "true"

    @property
    def label_long(self) -> str:
        """Detailed label including EPLB scope and topology."""
        eplb_part = f"eplb={self.eplb_mode}"
        if self.eplb_enabled or self.prefill_eplb_enabled:
            eplb_part += f"({self.eplb_scope})"
            log_bal_off = []
            if self.eplb_enabled and not self.decode_log_balancedness:
                log_bal_off.append("decode")
            if self.prefill_eplb_enabled and not self.prefill_log_balancedness:
                log_bal_off.append("prefill")
            if log_bal_off:
                eplb_part += f" log_bal=off({'+'.join(log_bal_off)})"
        return f"{self.mode} | {eplb_part} | {self.topology_str}"

    def __repr__(self) -> str:
        parts = [
            f"mode={self.mode}",
            f"eplb={self.eplb_mode}",
            f"dataset={self.dataset}",
            f"redundant={self.num_redundant}",
            f"interval={self.step_interval}",
            f"lws={self.lws_size}",
        ]
        if self.decode_pods is not None:
            parts.append(f"decode={self.decode_replicas}x{self.decode_group_size}")
        if self.prefill_pods is not None:
            parts.append(f"prefill={self.prefill_replicas}x{self.prefill_group_size}")
        return f"RunConfig({self.name!r}, {', '.join(parts)})"


@dataclass
class PrometheusData:
    """Parsed prometheus.json with helper accessors."""

    raw: dict

    def instant(self, key: str) -> float | None:
        """Extract scalar value from an instant query result."""
        entry = self.raw.get(key, {})
        if entry.get("status") != "success":
            return None
        results = entry.get("data", {}).get("result", [])
        if not results:
            return None
        val = results[0].get("value", [None, None])
        try:
            return float(val[1])
        except (TypeError, ValueError, IndexError):
            return None

    def range_series(self, key: str) -> pd.DataFrame | None:
        """Extract time series from a range query result as a DataFrame."""
        entry = self.raw.get(key, {})
        if entry.get("status") != "success":
            return None
        results = entry.get("data", {}).get("result", [])
        if not results:
            return None
        values = results[0].get("values", [])
        if not values:
            return None
        ts = [float(v[0]) for v in values]
        vals = [float(v[1]) if v[1] != "NaN" else np.nan for v in values]
        df = pd.DataFrame({"timestamp": ts, "value": vals})
        df["time_min"] = (df["timestamp"] - df["timestamp"].iloc[0]) / 60
        return df

    @property
    def stages(self) -> list[dict] | None:
        """Stage metadata derived from nyann_concurrency Prometheus metric.

        Each entry has: stage (int), concurrency (int), start_time, end_time (epoch).
        """
        meta = self.raw.get("_stages")
        return meta if isinstance(meta, list) else None

    @property
    def n_stages(self) -> int:
        s = self.stages
        return len(s) if s else 0

    def stage_instant(self, stage: int, key: str) -> float | None:
        """Extract scalar value for a per-stage instant query."""
        return self.instant(f"stage_{stage}_{key}")

    def summary_dict(self) -> dict[str, float | None]:
        """Return all global instant metrics as a flat dict."""
        out = {}
        for key in self.raw:
            if key.endswith("_range") or key.startswith("stage_") or key.startswith("_"):
                continue
            out[key] = self.instant(key)
        return out

    def stage_summary_dict(self, stage: int) -> dict[str, float | None]:
        """Return instant metrics for one stage as a flat dict."""
        prefix = f"stage_{stage}_"
        out = {}
        for key in self.raw:
            if key.startswith(prefix):
                metric = key[len(prefix):]
                out[metric] = self.instant(key)
        return out

    def diagnose(self) -> pd.DataFrame:
        """Show status/result count/value for every key -- useful for debugging empty tables."""
        rows = []
        for key in sorted(self.raw):
            if key.startswith("_"):
                continue
            entry = self.raw[key]
            if not isinstance(entry, dict):
                continue
            status = entry.get("status", "missing")
            results = entry.get("data", {}).get("result", [])
            n_results = len(results)
            val = self.instant(key) if not key.endswith("_range") else None
            range_pts = None
            range_active = None
            if key.endswith("_range") and results:
                values = results[0].get("values", [])
                range_pts = len(values)
                non_nan = [v for _, v in values if v != "NaN" and float(v) != 0]
                range_active = len(non_nan)
            raw_val = None
            if results and "value" in results[0]:
                raw_val = results[0]["value"][1] if len(results[0]["value"]) > 1 else None
            rows.append({
                "key": key,
                "status": status,
                "n_results": n_results,
                "raw_value": raw_val,
                "parsed": val,
                "range_pts": range_pts,
                "range_active": range_active,
            })
        return pd.DataFrame(rows).set_index("key")


@dataclass
class ExpertLoadData:
    """Parsed expert load dump with derived fields (adapted from vllm notebook)."""

    model: str
    world_size: int
    num_layers: int
    num_physical: int
    num_logical: int
    num_redundant: int
    experts_per_rank: int
    window_size: int
    data: dict
    load_key: str

    def snapshot(self, idx: int = -1):
        snap = self.data["snapshots"][idx]
        return (
            snap,
            np.array(snap[self.load_key]),
            np.array(snap["physical_to_logical_map"]),
        )

    @property
    def num_snapshots(self) -> int:
        return len(self.data["snapshots"])

    @property
    def steps(self) -> list[int]:
        return [s["step"] for s in self.data["snapshots"]]

    def balancedness_series(self) -> pd.DataFrame:
        """Compute per-snapshot balancedness (mean and worst layer)."""
        rows = []
        for snap in self.data["snapshots"]:
            load = np.array(snap[self.load_key])
            rank_load = load.reshape(
                self.num_layers, self.world_size, self.experts_per_rank
            ).sum(axis=2)
            mean_load = rank_load.mean(axis=1)
            max_load = rank_load.max(axis=1)
            bal = np.where(max_load > 0, mean_load / max_load, 0.0)
            rows.append({
                "step": snap["step"],
                "mean_balancedness": bal.mean(),
                "worst_balancedness": bal.min(),
                "worst_layer": int(bal.argmin()),
            })
        return pd.DataFrame(rows)


@dataclass
class RunData:
    """All data for a single benchmark run."""

    name: str
    path: Path
    config: RunConfig
    prometheus: PrometheusData | None = None
    expert_loads: dict[str, ExpertLoadData] = field(default_factory=dict)


# ---------------------------------------------------------------------------
# Loaders
# ---------------------------------------------------------------------------


def parse_config_env(path: Path) -> dict[str, str]:
    """Parse a config.env file into a dict (ignores comments and blank lines)."""
    result = {}
    text = path.read_text()
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if "=" in line:
            key, _, value = line.partition("=")
            result[key.strip()] = value.strip()
    return result


def load_run(name: str, results_dir: Path | str | None = None) -> RunData:
    """Load all collected data for a benchmark run.

    Args:
        name: Run directory name (e.g. "pd-async-eplb").
        results_dir: Override for the results root (default: benchmarks/eplb/).
    """
    base = Path(results_dir) if results_dir else RESULTS_DIR
    run_dir = base / name
    if not run_dir.exists():
        raise FileNotFoundError(f"Run directory not found: {run_dir}")

    config_path = run_dir / "config.env"
    config_raw = parse_config_env(config_path) if config_path.exists() else {}
    config = RunConfig(name=name, raw=config_raw)

    prom = None
    prom_path = run_dir / "prometheus.json"
    if prom_path.exists():
        with open(prom_path) as f:
            prom = PrometheusData(raw=json.load(f))

    expert_loads = {}
    expert_dir = run_dir / "expert-load"
    if expert_dir.exists():
        found_subdirs = False
        for role in ("decode", "prefill"):
            role_dir = expert_dir / role
            if role_dir.exists():
                found_subdirs = True
                for p in sorted(role_dir.glob("*_expert_load.json")):
                    with open(p) as f:
                        data = json.load(f)
                    expert_loads[f"{role}/{p.stem}"] = _parse_expert_load(data)
        if not found_subdirs:
            for p in sorted(expert_dir.glob("*_expert_load.json")):
                with open(p) as f:
                    data = json.load(f)
                expert_loads[p.stem] = _parse_expert_load(data)

    return RunData(
        name=name,
        path=run_dir,
        config=config,
        prometheus=prom,
        expert_loads=expert_loads,
    )


def _parse_expert_load(
    data: dict,
    load_type: LoadType = "window",
    world_size: int | None = None,
) -> ExpertLoadData:
    ws = world_size if world_size is not None else data["world_size"]
    num_physical = data["num_physical_experts"]
    return ExpertLoadData(
        model=data.get("model_name", "unknown"),
        world_size=ws,
        num_layers=data["num_moe_layers"],
        num_physical=num_physical,
        num_logical=data["num_logical_experts"],
        num_redundant=data["num_redundant_experts"],
        experts_per_rank=num_physical // ws,
        window_size=data["window_size"],
        data=data,
        load_key=LOAD_TYPE_KEY[load_type],
    )


def list_runs(results_dir: Path | str | None = None) -> list[str]:
    """List available run directories."""
    base = Path(results_dir) if results_dir else RESULTS_DIR
    return sorted(
        d.name
        for d in base.iterdir()
        if d.is_dir() and (d / "config.env").exists()
    )


def load_all_runs(
    results_dir: Path | str | None = None,
) -> dict[str, RunData]:
    """Load all runs from the results directory."""
    names = list_runs(results_dir)
    return {name: load_run(name, results_dir) for name in names}


# ---------------------------------------------------------------------------
# Comparison tables
# ---------------------------------------------------------------------------


def metrics_comparison_table(
    runs: dict[str, RunData],
) -> pd.DataFrame:
    """Build a comparison DataFrame of key Prometheus metrics across runs.

    Latencies are converted to milliseconds for readability.
    """
    rows = []
    latency_keys = {
        "ttft_p50", "ttft_p95", "ttft_p99",
        "itl_p50", "itl_p95", "itl_p99",
        "e2e_p50", "e2e_p95", "e2e_p99",
        "queue_p50", "queue_p95", "queue_p99",
        "prefill_time_p50", "prefill_time_p95", "prefill_time_p99",
        "decode_time_p50", "decode_time_p95", "decode_time_p99",
        "nixl_xfer_p99",
    }
    for name, run in runs.items():
        row: dict = {
            "run": name,
            "mode": run.config.mode,
            "eplb": run.config.eplb_mode,
            "dataset": run.config.dataset,
            "redundant": run.config.num_redundant,
            "interval": run.config.step_interval,
            "lws_size": run.config.lws_size,
            "decode_pods": run.config.decode_pods,
            "prefill_pods": run.config.prefill_pods,
            "prom_duration_m": (run.config.prom_duration_s or 0) / 60,
        }
        if run.prometheus:
            for k, v in run.prometheus.summary_dict().items():
                if v is not None and k in latency_keys:
                    row[f"{k}_ms"] = v * 1000
                elif v is not None:
                    row[k] = v
        rows.append(row)
    return pd.DataFrame(rows).set_index("run")


def stage_metrics_table(
    run: RunData,
) -> pd.DataFrame | None:
    """Build a DataFrame of per-stage Prometheus metrics for a single run.

    Returns None if no stage data is available.
    Latencies are converted to milliseconds for readability.
    """
    if run.prometheus is None or run.prometheus.n_stages == 0:
        return None

    latency_keys = {
        "ttft_p50", "ttft_p95", "ttft_p99",
        "itl_p50", "itl_p95", "itl_p99",
        "e2e_p50", "e2e_p95", "e2e_p99",
        "queue_p50", "queue_p95", "queue_p99",
        "prefill_time_p50", "prefill_time_p95", "prefill_time_p99",
        "decode_time_p50", "decode_time_p95", "decode_time_p99",
    }
    rows = []
    for stage_meta in run.prometheus.stages:
        idx = stage_meta["stage"]
        row: dict = {
            "stage": idx,
            "concurrency": stage_meta["concurrency"],
        }
        for k, v in run.prometheus.stage_summary_dict(idx).items():
            if v is not None and k in latency_keys:
                row[f"{k}_ms"] = v * 1000
            elif v is not None:
                row[k] = v
        rows.append(row)
    return pd.DataFrame(rows).set_index("stage")


def balancedness_comparison_table(
    runs: dict[str, RunData],
) -> pd.DataFrame:
    """Build a comparison DataFrame of expert load balancedness across runs."""
    rows = []
    for name, run in runs.items():
        for model_key, expert in run.expert_loads.items():
            bal = expert.balancedness_series()
            if bal.empty:
                continue
            rows.append({
                "run": name,
                "eplb": run.config.eplb_mode,
                "model": expert.model,
                "snapshots": expert.num_snapshots,
                "final_mean_bal": bal["mean_balancedness"].iloc[-1],
                "final_worst_bal": bal["worst_balancedness"].iloc[-1],
                "avg_mean_bal": bal["mean_balancedness"].mean(),
                "avg_worst_bal": bal["worst_balancedness"].mean(),
            })
    return pd.DataFrame(rows).set_index("run")


# ---------------------------------------------------------------------------
# Plotting: per-run expert load analysis (adapted from vllm notebook)
# ---------------------------------------------------------------------------


def plot_expert_load_heatmap(
    d: ExpertLoadData,
    snapshot_idx: int = -1,
    title_suffix: str = "",
    ax: plt.Axes | None = None,
):
    """Expert load heatmap with rank boundaries."""
    snap, load, _ = d.snapshot(snapshot_idx)
    own_fig = ax is None
    if own_fig:
        fig, ax = plt.subplots(
            figsize=(max(14, d.num_physical * 0.06), max(6, d.num_layers * 0.12))
        )
    else:
        fig = ax.figure

    im = ax.imshow(load, aspect="auto", interpolation="nearest", cmap="YlOrRd")
    ax.set_xlabel("Physical Expert")
    ax.set_ylabel("Layer")
    ax.set_title(f"Expert Load Heatmap (step {snap['step']}){title_suffix}")

    for r in range(1, d.world_size):
        ax.axvline(
            x=r * d.experts_per_rank - 0.5,
            color="blue", linewidth=0.8, linestyle="--", alpha=0.6,
        )

    rank_centers = [
        (r * d.experts_per_rank + (r + 1) * d.experts_per_rank) / 2 - 0.5
        for r in range(d.world_size)
    ]
    ax2 = ax.secondary_xaxis("top")
    ax2.set_xticks(rank_centers)
    ax2.set_xticklabels([f"R{r}" for r in range(d.world_size)], fontsize=8)
    ax2.set_xlabel("Rank")

    fig.colorbar(im, ax=ax, label="Tokens routed", shrink=0.8)
    if own_fig:
        plt.tight_layout()


def plot_rank_balance(
    d: ExpertLoadData,
    snapshot_idx: int = -1,
    title_suffix: str = "",
):
    """Per-rank load balance heatmap + per-layer balancedness bar chart."""
    snap, load, _ = d.snapshot(snapshot_idx)
    rank_load = load.reshape(d.num_layers, d.world_size, d.experts_per_rank).sum(axis=2)

    fig, axes = plt.subplots(1, 2, figsize=(16, max(5, d.num_layers * 0.1)))
    fig.suptitle(
        f"{d.model}  |  EP={d.world_size}  |  step {snap['step']}{title_suffix}",
        fontsize=9, y=1.02,
    )

    im = axes[0].imshow(rank_load, aspect="auto", interpolation="nearest", cmap="YlOrRd")
    axes[0].set_xlabel("Rank")
    axes[0].set_ylabel("Layer")
    axes[0].set_title("Total Load per Rank per Layer")
    fig.colorbar(im, ax=axes[0], label="Tokens", shrink=0.8)

    mean_load = rank_load.mean(axis=1)
    max_load = rank_load.max(axis=1)
    balancedness = np.where(max_load > 0, mean_load / max_load, 0.0)
    layers = np.arange(d.num_layers)
    axes[1].barh(layers, balancedness, color="steelblue")
    axes[1].set_xlabel("Balancedness (mean / max)")
    axes[1].set_ylabel("Layer")
    axes[1].set_title("Per-Layer Balancedness Ratio")
    axes[1].set_xlim(0, 1.05)
    axes[1].axvline(x=1.0, color="green", linestyle="--", alpha=0.5, label="Perfect")
    axes[1].invert_yaxis()
    axes[1].legend()
    plt.tight_layout()

    print(
        f"Overall balancedness: {balancedness.mean():.4f}  "
        f"(min layer: {balancedness.min():.4f} @ layer {balancedness.argmin()})"
    )


def plot_expert_popularity(
    d: ExpertLoadData,
    snapshot_idx: int = -1,
    title_suffix: str = "",
):
    """Physical expert popularity bar chart (summed across layers)."""
    snap, load, _ = d.snapshot(snapshot_idx)
    total_per_expert = load.sum(axis=0)

    fig, ax = plt.subplots(figsize=(max(12, d.num_physical * 0.05), 4))
    colors = [
        plt.cm.tab20(r / d.world_size)
        for r in range(d.world_size)
        for _ in range(d.experts_per_rank)
    ]
    ax.bar(
        np.arange(d.num_physical), total_per_expert,
        color=colors, width=1.0, edgecolor="none",
    )
    ax.set_xlabel("Physical Expert")
    ax.set_ylabel("Total Tokens (across layers)")
    ax.set_title(f"Physical Expert Popularity (step {snap['step']}){title_suffix}")

    for r in range(1, d.world_size):
        ax.axvline(
            x=r * d.experts_per_rank - 0.5,
            color="black", linewidth=0.5, linestyle="--", alpha=0.4,
        )
    ax.set_xlim(-0.5, d.num_physical - 0.5)
    plt.tight_layout()

    print(
        f"Expert load: mean={total_per_expert.mean():.0f}, "
        f"std={total_per_expert.std():.0f}, "
        f"max/mean={total_per_expert.max() / total_per_expert.mean():.2f}x"
    )


def plot_balancedness_over_time(
    d: ExpertLoadData,
    title_suffix: str = "",
    ax: plt.Axes | None = None,
):
    """Balancedness trend across all snapshots."""
    bal = d.balancedness_series()
    own_fig = ax is None
    if own_fig:
        fig, ax = plt.subplots(figsize=(10, 4))

    ax.plot(bal["step"], bal["mean_balancedness"], marker="o", markersize=3,
            label="Mean (across layers)")
    ax.plot(bal["step"], bal["worst_balancedness"], marker="s", markersize=3,
            label="Worst layer")
    ax.set_xlabel("Step")
    ax.set_ylabel("Balancedness")
    ax.set_title(f"Balancedness Over Time{title_suffix}")
    ax.set_ylim(0, 1.05)
    ax.axhline(y=1.0, color="green", linestyle="--", alpha=0.4)
    ax.legend()
    ax.grid(alpha=0.3)
    if own_fig:
        plt.tight_layout()


def plot_expert_load_all(
    d: ExpertLoadData,
    snapshot_idx: int = -1,
    title_suffix: str = "",
):
    """Run all four expert load visualizations."""
    plot_expert_load_heatmap(d, snapshot_idx, title_suffix)
    plot_rank_balance(d, snapshot_idx, title_suffix)
    plot_expert_popularity(d, snapshot_idx, title_suffix)
    plot_balancedness_over_time(d, title_suffix)


# ---------------------------------------------------------------------------
# Plotting: cross-run comparisons
# ---------------------------------------------------------------------------


def plot_latency_comparison(
    runs: dict[str, RunData],
    metric: str = "itl_p99",
    title: str | None = None,
):
    """Per-stage latency bar chart across runs.

    Shows one group of bars per concurrency stage, with one bar per run.
    This makes it easy to see at which concurrency each configuration starts
    to degrade.

    Args:
        metric: Prometheus instant metric key (e.g. "itl_p99", "ttft_p99").
        title: Plot title (auto-generated from metric if None).
    """
    if title is None:
        title = f"{metric} by Concurrency Stage"

    run_stages: dict[str, list[tuple[int, float]]] = {}
    all_concurrencies: set[int] = set()

    for name, run in runs.items():
        if run.prometheus is None or run.prometheus.n_stages == 0:
            continue
        points = []
        for stage_meta in run.prometheus.stages:
            idx = stage_meta["stage"]
            conc = stage_meta["concurrency"]
            val = run.prometheus.stage_instant(idx, metric)
            if val is not None:
                points.append((conc, val * 1000))
                all_concurrencies.add(conc)
        if points:
            run_stages[name] = points

    if not run_stages:
        print(f"No per-stage data for {metric}")
        return

    concurrencies = sorted(all_concurrencies)
    conc_to_idx = {c: i for i, c in enumerate(concurrencies)}

    n_runs = len(run_stages)
    x = np.arange(len(concurrencies))
    width = 0.8 / max(n_runs, 1)

    fig, ax = plt.subplots(figsize=(max(10, len(concurrencies) * 1.2), 5))
    for i, (name, points) in enumerate(run_stages.items()):
        vals = [0.0] * len(concurrencies)
        for conc, v in points:
            vals[conc_to_idx[conc]] = v
        run_label = runs[name].config.label if name in runs else name
        ax.bar(x + i * width, vals, width, label=run_label)

    ax.set_ylabel("Latency (ms)")
    ax.set_xlabel("Concurrency")
    ax.set_title(title)
    ax.set_xticks(x + width * (n_runs - 1) / 2)
    ax.set_xticklabels(concurrencies, rotation=45, ha="right")
    ax.legend()
    ax.grid(axis="y", alpha=0.3)
    plt.tight_layout()


def plot_throughput_comparison(
    runs: dict[str, RunData],
    title: str = "Throughput Comparison",
):
    """Bar chart comparing output token throughput across runs."""
    labels = []
    gen_tps = []
    prompt_tps = []
    for name, run in runs.items():
        labels.append(name)
        gen = run.prometheus.instant("gen_tokens_per_sec") if run.prometheus else None
        prompt = run.prometheus.instant("prompt_tokens_per_sec") if run.prometheus else None
        gen_tps.append(gen or 0)
        prompt_tps.append(prompt or 0)

    x = np.arange(len(labels))
    width = 0.35
    fig, ax = plt.subplots(figsize=(max(8, len(labels) * 1.5), 5))
    ax.bar(x - width / 2, gen_tps, width, label="Output tok/s", color="steelblue")
    ax.bar(x + width / 2, prompt_tps, width, label="Prompt tok/s", color="coral")
    ax.set_ylabel("Tokens / sec")
    ax.set_title(title)
    ax.set_xticks(x)
    ax.set_xticklabels(labels, rotation=30, ha="right")
    ax.legend()
    ax.grid(axis="y", alpha=0.3)
    plt.tight_layout()


def plot_throughput_timeseries(
    runs: dict[str, RunData],
    metric_key: str = "gen_tokens_per_sec_range",
    title: str = "Output Throughput Over Time",
):
    """Overlay time series of a range metric across runs."""
    fig, ax = plt.subplots(figsize=(12, 5))
    for name, run in runs.items():
        if run.prometheus is None:
            continue
        df = run.prometheus.range_series(metric_key)
        if df is not None:
            ax.plot(df["time_min"], df["value"], label=name, alpha=0.8)

    ax.set_xlabel("Time (min)")
    ax.set_ylabel("Tokens / sec")
    ax.set_title(title)
    ax.legend()
    ax.grid(alpha=0.3)
    plt.tight_layout()


def plot_kv_cache_usage(
    runs: dict[str, RunData],
    title: str = "KV Cache Usage Over Time",
):
    """Overlay KV cache usage time series across runs."""
    fig, ax = plt.subplots(figsize=(12, 5))
    for name, run in runs.items():
        if run.prometheus is None:
            continue
        df = run.prometheus.range_series("kv_cache_usage_range")
        if df is not None:
            ax.plot(df["time_min"], df["value"] * 100, label=name, alpha=0.8)

    ax.set_xlabel("Time (min)")
    ax.set_ylabel("KV Cache Usage (%)")
    ax.set_title(title)
    ax.set_ylim(0, 105)
    ax.legend()
    ax.grid(alpha=0.3)
    plt.tight_layout()


def plot_balancedness_comparison(
    runs: dict[str, RunData],
    title: str = "Balancedness Comparison",
):
    """Overlay balancedness over time for all runs that have expert load data."""
    fig, axes = plt.subplots(1, 2, figsize=(14, 5))
    fig.suptitle(title, fontsize=11)

    for name, run in runs.items():
        for _model_key, expert in run.expert_loads.items():
            bal = expert.balancedness_series()
            if bal.empty:
                continue
            axes[0].plot(bal["step"], bal["mean_balancedness"],
                         marker="o", markersize=2, label=name, alpha=0.8)
            axes[1].plot(bal["step"], bal["worst_balancedness"],
                         marker="s", markersize=2, label=name, alpha=0.8)

    for ax, ylabel, sub_title in [
        (axes[0], "Mean Balancedness", "Mean (across layers)"),
        (axes[1], "Worst Balancedness", "Worst layer"),
    ]:
        ax.set_xlabel("Step")
        ax.set_ylabel(ylabel)
        ax.set_title(sub_title)
        ax.set_ylim(0, 1.05)
        ax.axhline(y=1.0, color="green", linestyle="--", alpha=0.4)
        ax.legend(fontsize=8)
        ax.grid(alpha=0.3)
    plt.tight_layout()


def plot_latency_timeseries(
    runs: dict[str, RunData],
    metric_key: str = "ttft_p99_range",
    title: str = "TTFT P99 Over Time",
):
    """Overlay latency time series across runs."""
    fig, ax = plt.subplots(figsize=(12, 5))
    for name, run in runs.items():
        if run.prometheus is None:
            continue
        df = run.prometheus.range_series(metric_key)
        if df is not None:
            ax.plot(df["time_min"], df["value"] * 1000, label=name, alpha=0.8)

    ax.set_xlabel("Time (min)")
    ax.set_ylabel("Latency (ms)")
    ax.set_title(title)
    ax.legend()
    ax.grid(alpha=0.3)
    plt.tight_layout()


def plot_phase_time_comparison(
    runs: dict[str, RunData],
    percentile: str = "p99",
    title: str | None = None,
):
    """Grouped bar chart comparing prefill/decode/queue phase times across runs.

    Shows where request latency is spent: prefill compute, decode compute,
    and queue time. EPLB primarily affects decode_time.
    """
    if title is None:
        title = f"Request Phase Breakdown ({percentile})"

    labels = []
    prefill_ms = []
    decode_ms = []
    queue_ms = []
    for name, run in runs.items():
        labels.append(name)
        if run.prometheus is None:
            prefill_ms.append(0)
            decode_ms.append(0)
            queue_ms.append(0)
            continue
        pf = run.prometheus.instant(f"prefill_time_{percentile}")
        dc = run.prometheus.instant(f"decode_time_{percentile}")
        qu = run.prometheus.instant(f"queue_{percentile}")
        prefill_ms.append(pf * 1000 if pf is not None else 0)
        decode_ms.append(dc * 1000 if dc is not None else 0)
        queue_ms.append(qu * 1000 if qu is not None else 0)

    x = np.arange(len(labels))
    width = 0.25
    fig, ax = plt.subplots(figsize=(max(8, len(labels) * 2), 5))
    ax.bar(x - width, prefill_ms, width, label="Prefill", color="coral")
    ax.bar(x, decode_ms, width, label="Decode", color="steelblue")
    ax.bar(x + width, queue_ms, width, label="Queue", color="gray", alpha=0.7)

    ax.set_ylabel("Latency (ms)")
    ax.set_title(title)
    ax.set_xticks(x)
    ax.set_xticklabels(labels, rotation=30, ha="right")
    ax.legend()
    ax.grid(axis="y", alpha=0.3)
    plt.tight_layout()


def plot_phase_time_timeseries(
    runs: dict[str, RunData],
    title: str = "Decode vs Prefill Time P99 Over Time",
):
    """Overlay decode and prefill phase time P99 series across runs."""
    fig, axes = plt.subplots(1, 2, figsize=(14, 5))
    fig.suptitle(title, fontsize=11)

    for name, run in runs.items():
        if run.prometheus is None:
            continue
        df_dec = run.prometheus.range_series("decode_time_p99_range")
        if df_dec is not None:
            axes[0].plot(df_dec["time_min"], df_dec["value"] * 1000,
                         label=name, alpha=0.8)
        df_pf = run.prometheus.range_series("prefill_time_p99_range")
        if df_pf is not None:
            axes[1].plot(df_pf["time_min"], df_pf["value"] * 1000,
                         label=name, alpha=0.8)

    for ax, sub_title in [(axes[0], "Decode P99"), (axes[1], "Prefill P99")]:
        ax.set_xlabel("Time (min)")
        ax.set_ylabel("Latency (ms)")
        ax.set_title(sub_title)
        ax.legend(fontsize=8)
        ax.grid(alpha=0.3)
    plt.tight_layout()


def plot_pareto_frontier(
    runs: dict[str, RunData],
    gpus_per_pod: int = 4,
    title: str | None = None,
):
    """Plot throughput-per-GPU vs per-user output speed across concurrency stages.

    Each run produces a curve from its per-stage metrics. Points on the upper-right
    are optimal — you can't improve throughput without sacrificing interactivity or
    vice versa.

    The subtitle shows model, topology, and EPLB configuration details.

    Args:
        gpus_per_pod: GPUs per pod (default 4 for GB200).
    """
    fig, ax = plt.subplots(figsize=(12, 7))
    markers = ["o", "s", "D", "^", "v", "P", "X", "*"]

    subtitle_parts: list[str] = []

    for i, (name, run) in enumerate(runs.items()):
        if run.prometheus is None or run.prometheus.n_stages == 0:
            continue

        total_gpus = 0
        dp, pp = run.config.decode_pods, run.config.prefill_pods
        if dp is not None:
            total_gpus += dp * gpus_per_pod
        if pp is not None:
            total_gpus += pp * gpus_per_pod
        if total_gpus == 0:
            total_gpus = 1

        x_vals = []  # per-user TPS (interactivity)
        y_vals = []  # system TPS per GPU (throughput efficiency)
        concurrencies = []

        for stage_meta in run.prometheus.stages:
            idx = stage_meta["stage"]
            conc = stage_meta["concurrency"]
            gen_tps = run.prometheus.stage_instant(idx, "gen_tokens_per_sec")
            itl = run.prometheus.stage_instant(idx, "itl_p50")

            if gen_tps is None or gen_tps <= 0:
                continue

            per_user_tps = 1.0 / itl if itl and itl > 0 else gen_tps / max(conc, 1)
            tps_per_gpu = gen_tps / total_gpus

            x_vals.append(per_user_tps)
            y_vals.append(tps_per_gpu)
            concurrencies.append(conc)

        if not x_vals:
            continue

        marker = markers[i % len(markers)]
        ax.plot(x_vals, y_vals, marker=marker, markersize=7, linewidth=1.5,
                label=run.config.label_long, alpha=0.85)

        for x, y, c in zip(x_vals, y_vals, concurrencies):
            ax.annotate(str(c), (x, y), textcoords="offset points",
                        xytext=(5, 5), fontsize=7, alpha=0.7)

        if not subtitle_parts:
            subtitle_parts.append(run.config.model_short)
            subtitle_parts.append(f"{total_gpus} GPUs")

    ax.set_xlabel("Per-User Output Speed (tokens/s)")
    ax.set_ylabel("System Throughput per GPU (tokens/s)")
    main_title = title or "Throughput vs Interactivity (Pareto Frontier)"
    subtitle = "  |  ".join(subtitle_parts) if subtitle_parts else ""
    if subtitle:
        ax.set_title(f"{main_title}\n{subtitle}", fontsize=11)
    else:
        ax.set_title(main_title)
    ax.legend(loc="best", fontsize=9)
    ax.grid(alpha=0.3)
    plt.tight_layout()
