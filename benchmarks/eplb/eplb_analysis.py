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
from datetime import datetime, timezone
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
    def prefill_num_redundant(self) -> int:
        return int(self.raw.get("PREFILL_EPLB_NUM_REDUNDANT_EXPERTS",
                                self.raw.get("DECODE_EPLB_NUM_REDUNDANT_EXPERTS", "32")))

    @property
    def redundant_str(self) -> str:
        """Short string for redundant experts, prefill first.

        Only shows RE for roles where EPLB is enabled.
        Examples: 'RE=P32/D32', 'RE=D32', 'RE=P64'.
        """
        parts = []
        if self.prefill_eplb_enabled:
            parts.append(f"P{self.prefill_num_redundant}")
        if self.eplb_enabled:
            parts.append(f"D{self.num_redundant}")
        if not parts:
            return ""
        return f"RE={'/'.join(parts)}"

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
    def fork(self) -> str:
        """Fork repo + branch, e.g. 'neuralmagic/vllm@imarkov/eplb_study'."""
        repo = self.raw.get("FORK_REPO", "")
        branch = self.raw.get("FORK_BRANCH", "")
        if repo:
            short = repo.rstrip("/").rsplit("/", 2)
            repo_name = "/".join(short[-2:]) if len(short) >= 2 else repo
            return f"{repo_name}@{branch}" if branch else repo_name
        return branch

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
    def n_workers(self) -> int:
        return int(self.raw.get("N_WORKERS", "8"))

    @property
    def isl(self) -> int:
        return int(self.raw.get("ISL", "500"))

    @property
    def osl(self) -> int:
        return int(self.raw.get("OSL", "1500"))

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
        pp = self.prefill_pods
        if pp is not None:
            parts.append(f"P={pp}")
        dp = self.decode_pods
        if dp is not None:
            parts.append(f"D={dp}")
        return " ".join(parts) if parts else "?"

    @property
    def label(self) -> str:
        """Short human-readable label for plots."""
        base = f"{self.mode}/{self.eplb_mode}"
        if self.eplb_enabled or self.prefill_eplb_enabled:
            base += f" {self.redundant_str}"
        cs = self.communicator_str
        if cs:
            base += f" {cs}"
        rs = self.routing_simulation_str
        if rs:
            base += f" {rs}"
        return base

    @property
    def decode_routing_simulation(self) -> str:
        return self.raw.get("DECODE_VLLM_MOE_ROUTING_SIMULATION_STRATEGY", "")

    @property
    def prefill_routing_simulation(self) -> str:
        return self.raw.get("PREFILL_VLLM_MOE_ROUTING_SIMULATION_STRATEGY", "")

    @property
    def routing_simulation_str(self) -> str:
        """Short string for routing simulation: 'rs:uniform' or 'rs:uniform/none' if they differ."""
        d = self.decode_routing_simulation
        p = self.prefill_routing_simulation
        if not d and not p:
            return ""
        d_short = d.replace("uniform_random", "uniform") if d else "none"
        p_short = p.replace("uniform_random", "uniform") if p else "none"
        if d_short == p_short:
            return f"rs:{d_short}"
        return f"rs:{p_short}/{d_short}"

    @property
    def communicator(self) -> str:
        """Backward-compatible alias for decode_communicator."""
        return self.decode_communicator

    @property
    def decode_communicator(self) -> str:
        return self.raw.get("DECODE_EPLB_COMMUNICATOR", "nixl")

    @property
    def prefill_communicator(self) -> str:
        return self.raw.get("PREFILL_EPLB_COMMUNICATOR", "nixl")

    @property
    def communicator_str(self) -> str:
        """Short string for communicator — only shown if non-default (nixl)."""
        d = self.decode_communicator
        p = self.prefill_communicator
        d_non = d != "nixl"
        p_non = p != "nixl"
        if not d_non and not p_non:
            return ""
        if d == p:
            return f"[{d}]"
        parts = []
        if p_non:
            parts.append(f"P:{p}")
        if d_non:
            parts.append(f"D:{d}")
        return f"[{'/'.join(parts)}]"

    @property
    def decode_log_balancedness(self) -> bool:
        return self.raw.get("DECODE_EPLB_LOG_BALANCEDNESS", "").lower() == "true"

    @property
    def prefill_log_balancedness(self) -> bool:
        return self.raw.get("PREFILL_EPLB_LOG_BALANCEDNESS", "").lower() == "true"

    @property
    def log_balancedness_interval(self) -> int:
        return int(self.raw.get("EPLB_LOG_BALANCEDNESS_INTERVAL",
                                self.raw.get("DECODE_EPLB_LOG_BALANCEDNESS_INTERVAL", "0")))

    @property
    def label_long(self) -> str:
        """Detailed label including EPLB scope and topology.

        Note: ``RunData.label_long`` overrides this with runtime checks
        (stats collection / no log balance suffixes).  This version is
        based on config alone.
        """
        eplb_part = f"eplb={self.eplb_mode}"
        if self.eplb_enabled or self.prefill_eplb_enabled:
            eplb_part += f"({self.eplb_scope}) {self.redundant_str}"
        cs = self.communicator_str
        comm_part = f" | {cs}" if cs else ""
        rs_part = ""
        rs = self.routing_simulation_str
        if rs:
            rs_part = f" | {rs}"
        return f"{self.mode} | {eplb_part} | {self.topology_str}{comm_part}{rs_part}"

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

    def get_stages(self) -> list[dict]:
        """Return stages as a list (empty if none)."""
        return self.stages or []

    @property
    def n_stages(self) -> int:
        s = self.stages
        return len(s) if s else 0

    def stage_instant(self, stage: int, key: str) -> float | None:
        """Extract scalar value for a per-stage instant query."""
        return self.instant(f"stage_{stage}_{key}")

    def stage_range_stats(
        self, range_key: str,
    ) -> list[dict[str, float]] | None:
        """Compute mean/min/max of a range metric within each stage window.

        Returns a list of dicts (one per stage) with keys:
        ``mean``, ``min``, ``max``, ``median``, ``count``.
        Returns *None* if the range series or stages are unavailable.
        """
        df = self.range_series(range_key)
        if df is None:
            return None
        stage_list = self.get_stages()
        if not stage_list:
            return None
        out = []
        for s in stage_list:
            mask = (df["timestamp"] >= s["start_time"]) & (
                df["timestamp"] <= s["end_time"]
            )
            window = df.loc[mask, "value"].dropna()
            if window.empty:
                out.append({
                    "mean": np.nan, "min": np.nan, "max": np.nan,
                    "median": np.nan, "count": 0,
                })
            else:
                out.append({
                    "mean": float(window.mean()),
                    "min": float(window.min()),
                    "max": float(window.max()),
                    "median": float(window.median()),
                    "count": len(window),
                })
        return out

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

    def per_rank_table(
        self,
        at: float | None = None,
        prefix: str = "per_rank_",
    ) -> pd.DataFrame:
        """Build a DataFrame of per-pod/rank metrics at a given timestamp.

        Parses multi-series range query results that have ``pod`` and
        ``rank`` labels.  For each metric, the value closest to *at* is
        picked.  If *at* is ``None``, the last data point is used.

        Returns a DataFrame indexed by ``(pod, rank)`` with one column
        per metric (e.g. ``e2e_p99_range``, ``gen_tokens_per_sec_range``).
        """
        rows: dict[tuple[str, str], dict] = {}
        for key in self.raw:
            if not key.startswith(prefix):
                continue
            metric = key[len(prefix):]
            entry = self.raw[key]
            if entry.get("status") != "success":
                continue
            for series in entry.get("data", {}).get("result", []):
                labels = series.get("metric", {})
                pod = labels.get("pod", "")
                rank = labels.get("rank", "")
                values = series.get("values", [])
                if not values:
                    val = series.get("value", [None, None])
                    try:
                        v = float(val[1])
                    except (TypeError, ValueError, IndexError):
                        v = np.nan
                else:
                    if at is None:
                        _, raw = values[-1]
                    else:
                        _, raw = min(values, key=lambda vv: abs(float(vv[0]) - at))
                    try:
                        v = float(raw)
                    except (TypeError, ValueError):
                        v = np.nan
                rows.setdefault((pod, rank), {})[metric] = v
        if not rows:
            return pd.DataFrame()
        df = pd.DataFrame.from_dict(rows, orient="index")
        df.index = pd.MultiIndex.from_tuples(df.index, names=["pod", "rank"])
        return df.sort_index()

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

    def _dedup_indices(self) -> list[int]:
        """Return indices of the first snapshot for each unique step, sorted by step.

        When multiple DP ranks dump to the same file, each step appears
        multiple times with different data.  We keep the first occurrence
        (one consistent rank) and sort by step for clean ascending plots.
        """
        snaps = self.data["snapshots"]
        if not snaps:
            return []
        first_by_step: dict[int, int] = {}
        for i, snap in enumerate(snaps):
            if snap["step"] not in first_by_step:
                first_by_step[snap["step"]] = i
        return sorted(first_by_step.values(), key=lambda i: snaps[i]["step"])

    def dedup_snapshots(self) -> list[dict]:
        """One snapshot per step (first occurrence), sorted by step."""
        indices = self._dedup_indices()
        snaps = self.data["snapshots"]
        return [snaps[i] for i in indices]

    def closest_snapshot_idx(self, step: int) -> int:
        """Return the index of the snapshot whose step is closest to *step*.

        Only considers deduplicated snapshots.
        """
        indices = self._dedup_indices()
        snaps = self.data["snapshots"]
        best = min(indices, key=lambda i: abs(snaps[i]["step"] - step))
        return best

    def rank_total_load(self, step: int | None = None) -> np.ndarray:
        """Total load per EP rank at a given step (or last deduped snapshot).

        Returns a 1-D array of shape ``(world_size,)`` where each element is
        the total expert load (summed across layers and experts_per_rank) for
        that EP rank.  Useful for correlating with per-rank latency.
        """
        if step is not None:
            idx = self.closest_snapshot_idx(step)
        else:
            indices = self._dedup_indices()
            idx = indices[-1] if indices else -1
        _, load, _ = self.snapshot(idx)
        rank_load = load.reshape(
            self.num_layers, self.world_size, self.experts_per_rank
        ).sum(axis=2)
        return rank_load.sum(axis=0)

    def balancedness_series(self) -> pd.DataFrame:
        """Compute per-snapshot balancedness (mean and worst layer).

        Two flavours of "balancedness" are reported:

        * **vllm_balancedness** – matches the formula used by vLLM's
          ``eplb_state.py`` log line::

              sum_r(mean_l(rank_load[l,r])) / sum_r(max_l(rank_load[l,r]))

          This is a single global scalar that compares the average
          rank-load (averaged across layers) to the worst-case
          rank-load (max across layers).

        * **mean_balancedness** / **worst_balancedness** – per-layer
          balance ratio ``mean_r / max_r`` averaged (or min'd) across
          layers.  Useful for identifying individual imbalanced layers
          but can differ significantly from the vLLM metric.
        """
        rows = []
        for snap in self.dedup_snapshots():
            load = np.array(snap[self.load_key])
            rank_load = load.reshape(
                self.num_layers, self.world_size, self.experts_per_rank
            ).sum(axis=2)

            # Per-layer balancedness (existing metric)
            mean_load = rank_load.mean(axis=1)
            max_load = rank_load.max(axis=1)
            bal = np.where(max_load > 0, mean_load / max_load, 0.0)

            # vLLM-matching global balancedness (eplb_state.py formula):
            # avg_tokens = rank_load.mean(dim=0).sum(dim=0)
            # max_tokens = rank_load.max(dim=0).values.sum(dim=0)
            # vLLM logs this from expert_load_pass (latest, not window),
            # so we compute both variants.
            avg_tokens = rank_load.mean(axis=0).sum()
            max_tokens = rank_load.max(axis=0).sum()
            vllm_bal = avg_tokens / max_tokens if max_tokens > 0 else 0.0

            latest_load = np.array(snap.get("latest_expert_load", []))
            if latest_load.size > 0:
                latest_rank = latest_load.reshape(
                    self.num_layers, self.world_size, self.experts_per_rank
                ).sum(axis=2)
                avg_t = latest_rank.mean(axis=0).sum()
                max_t = latest_rank.max(axis=0).sum()
                vllm_bal_latest = avg_t / max_t if max_t > 0 else 0.0
            else:
                vllm_bal_latest = vllm_bal

            rows.append({
                "step": snap["step"],
                "vllm_balancedness": vllm_bal_latest,
                "vllm_balancedness_window": vllm_bal,
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
    step_timestamps: dict[str, list[tuple[int, float]]] = field(default_factory=dict)
    """Per-role lists of ``(step, epoch)`` pairs parsed from EPLB logs."""

    def _eplb_actually_ran(self, role: str = "decode") -> bool | None:
        """Check if EPLB rebalanced at least once based on expert load dumps.

        Returns None if no dump data is available for *role*.
        """
        for key, expert in self.expert_loads.items():
            if key.startswith(f"{role}/") or (role in key):
                max_step = max(expert.steps) if expert.steps else 0
                return max_step >= self.config.step_interval
        return None

    def _effectively_off(self, role: str) -> bool:
        """EPLB enabled but never rebalanced — either step_interval is huge or
        the benchmark didn't run long enough."""
        enabled = (self.config.eplb_enabled if role == "decode"
                   else self.config.prefill_eplb_enabled)
        if not enabled:
            return False
        if self.config.step_interval > 10000:
            ran = self._eplb_actually_ran(role)
            if ran is None:
                return True
            return not ran
        return self._eplb_actually_ran(role) is False

    @property
    def _decode_stats_only(self) -> bool:
        return self._effectively_off("decode")

    @property
    def _prefill_stats_only(self) -> bool:
        return self._effectively_off("prefill")

    @property
    def effective_eplb_mode(self) -> str:
        """Like ``config.eplb_mode`` but returns ``"off"`` when no rebalance happened."""
        if self._decode_stats_only:
            return "off"
        return self.config.eplb_mode

    def _log_bal_effectively_off(self, role: str) -> bool:
        """True if log_balancedness interval is too large to have ever fired."""
        interval = self.config.log_balancedness_interval
        if interval == 0:
            return False
        for key, expert in self.expert_loads.items():
            if key.startswith(f"{role}/") or (role in key):
                max_step = max(expert.steps) if expert.steps else 0
                return interval > max_step and interval > 10000
        return interval > 10000

    @property
    def _notes_suffix(self) -> str:
        if self.config.eplb_mode == "off":
            return ""
        notes = []
        if self._decode_stats_only or self._prefill_stats_only:
            notes.append("stats collection")
        if self.config.eplb_enabled and self._log_bal_effectively_off("decode"):
            notes.append("no log balance")
        if not notes:
            return ""
        return f" ({', '.join(notes)})"

    @property
    def _effective_scope(self) -> str:
        """Scope string that omits roles where EPLB is effectively off."""
        d = self.config.eplb_enabled and not self._decode_stats_only
        p = self.config.prefill_eplb_enabled and not self._prefill_stats_only
        if d and p:
            return "decode+prefill"
        if d:
            return "decode"
        if p:
            return "prefill"
        return ""

    @property
    def label(self) -> str:
        """Short label — shows eplb=off when no rebalance happened."""
        base = f"{self.config.mode}/{self.effective_eplb_mode}"
        if self.config.eplb_enabled or self.config.prefill_eplb_enabled:
            base += f" {self.config.redundant_str}"
        if self._effective_scope:
            base += f" SI={self.config.step_interval}"
        cs = self.config.communicator_str
        if cs:
            base += f" {cs}"
        rs = self.config.routing_simulation_str
        if rs:
            base += f" {rs}"
        return base + self._notes_suffix

    @property
    def label_long(self) -> str:
        """Detailed label — shows eplb=off when no rebalance happened."""
        c = self.config
        eplb_part = f"eplb={self.effective_eplb_mode}"
        scope = self._effective_scope
        if scope:
            eplb_part += f"({scope}) {c.redundant_str}"
        elif c.eplb_enabled or c.prefill_eplb_enabled:
            eplb_part += f" {c.redundant_str}"
        cs = c.communicator_str
        comm_part = f" | {cs}" if cs else ""
        rs_part = ""
        rs = c.routing_simulation_str
        if rs:
            rs_part = f" | {rs}"
        base = f"{c.mode} | {eplb_part} | {c.topology_str}{comm_part}{rs_part}"
        return base + self._notes_suffix

    def benchmark_max_step(self, role: str = "decode") -> int | None:
        """Auto-detect the last EPLB step that falls within the benchmark window.

        Uses the Prometheus stage timestamps and the ``(step, epoch)`` pairs
        parsed from EPLB logs.  When multiple pod restarts produced overlapping
        step numbers, only pairs whose timestamp falls within the Prometheus
        benchmark window (first stage start … last stage end) are considered.

        Returns ``None`` if either data source is missing.
        """
        if self.prometheus is None or not self.prometheus.stages:
            return None
        pairs = self.step_timestamps.get(role)
        if not pairs:
            return None
        bench_start = self.prometheus.stages[0]["start_time"]
        bench_end = self.prometheus.stages[-1]["end_time"]
        # Allow a margin before the first stage for warmup EPLB steps
        window_start = bench_start - 600
        within = [
            (step, ts) for step, ts in pairs
            if window_start <= ts <= bench_end
        ]
        if not within:
            return None
        within.sort(key=lambda x: x[1])
        return within[-1][0]


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


_EPLB_STEP_RE = re.compile(
    r"INFO\s+(\d{2}-\d{2}\s+\d{2}:\d{2}:\d{2})\s+.*EPLB step:\s+(\d+)\s+for model"
)


def _parse_eplb_log_steps(log_dir: Path, year: int | None = None) -> list[tuple[int, float]]:
    """Extract ``(step, epoch)`` pairs from EPLB log files in *log_dir*.

    Parses lines like::

        (Worker_DP0_EP0 pid=1078) INFO 04-29 21:02:14 [...] EPLB step: 63000 ...

    Multiple log files may exist from pod restarts with overlapping step
    numbers.  All entries are returned (unsorted, with duplicates) so that
    the caller can filter by the relevant time window.
    """
    if year is None:
        year = datetime.now(timezone.utc).year

    pairs: list[tuple[int, float]] = []
    for log_file in sorted(log_dir.glob("*.log")):
        for line in log_file.open():
            m = _EPLB_STEP_RE.search(line)
            if m is None:
                continue
            ts_str, step_str = m.group(1), m.group(2)
            dt = datetime.strptime(f"{year}-{ts_str}", "%Y-%m-%d %H:%M:%S").replace(
                tzinfo=timezone.utc
            )
            pairs.append((int(step_str), dt.timestamp()))
    return pairs


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
        def _try_load(p: Path, key: str) -> None:
            try:
                if p.suffix == ".jsonl":
                    data = _load_jsonl_expert_dump(p)
                else:
                    with open(p) as f:
                        data = json.load(f)
                expert_loads[key] = _parse_expert_load(data)
            except (json.JSONDecodeError, ValueError) as e:
                import warnings
                warnings.warn(f"Skipping corrupt expert load dump {p.name}: {e}")

        found_subdirs = False
        for role in ("decode", "prefill"):
            role_dir = expert_dir / role
            if role_dir.exists():
                found_subdirs = True
                for p in sorted(role_dir.glob("*_expert_load.json*")):
                    _try_load(p, f"{role}/{p.stem}")
        if not found_subdirs:
            for p in sorted(expert_dir.glob("*_expert_load.json*")):
                _try_load(p, p.stem)

    step_timestamps: dict[str, list[tuple[int, float]]] = {}
    log_dir = run_dir / "eplb-logs"
    if log_dir.exists():
        for role in ("decode", "prefill"):
            role_log_dir = log_dir / role
            has_logs = role_log_dir.is_dir() and any(role_log_dir.glob("*.log"))
            target = role_log_dir if has_logs else log_dir
            pairs = _parse_eplb_log_steps(target)
            if pairs:
                step_timestamps[role] = pairs
                if target is log_dir:
                    break

    return RunData(
        name=name,
        path=run_dir,
        config=config,
        prometheus=prom,
        expert_loads=expert_loads,
        step_timestamps=step_timestamps,
    )


def _load_jsonl_expert_dump(path: Path) -> dict:
    """Load a JSONL expert-load dump into the legacy dict format.

    The JSONL format (written by vLLM's ``eplb_state.py``) has one JSON
    record per line.  Each record contains both per-model metadata
    (``model_name``, ``world_size``, …) and per-snapshot data (``step``,
    ``window_expert_load``, …).  We reassemble these into the legacy
    single-JSON structure with a ``"snapshots"`` list so that the rest of
    the analysis code works unchanged.
    """
    _METADATA_KEYS = {
        "model_name", "world_size", "num_moe_layers",
        "num_physical_experts", "num_logical_experts",
        "num_redundant_experts", "window_size",
    }
    _SNAPSHOT_KEYS = {
        "step", "window_expert_load", "latest_expert_load",
        "physical_to_logical_map",
    }

    metadata: dict | None = None
    snapshots: list[dict] = []

    with open(path) as f:
        for lineno, line in enumerate(f, 1):
            line = line.strip()
            if not line:
                continue
            record = json.loads(line)
            if metadata is None:
                metadata = {k: record[k] for k in _METADATA_KEYS if k in record}
            snapshots.append({k: record[k] for k in _SNAPSHOT_KEYS if k in record})

    if metadata is None:
        raise ValueError(f"Empty JSONL expert load dump: {path}")

    metadata["snapshots"] = snapshots
    return metadata


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


def load_config(name: str, results_dir: Path | str | None = None) -> RunConfig:
    """Load only the config.env for a run (cheap — no Prometheus/dumps)."""
    base = Path(results_dir) if results_dir else RESULTS_DIR
    config_path = base / name / "config.env"
    raw = parse_config_env(config_path) if config_path.exists() else {}
    return RunConfig(name=name, raw=raw)


def load_all_configs(
    results_dir: Path | str | None = None,
) -> dict[str, RunConfig]:
    """Load configs for all runs (cheap — no Prometheus/dumps)."""
    return {name: load_config(name, results_dir) for name in list_runs(results_dir)}


def load_runs(
    names: list[str] | dict[str, RunConfig],
    results_dir: Path | str | None = None,
) -> dict[str, RunData]:
    """Load full RunData for the given runs.

    Accepts either a list of names or a dict from ``filter_runs``.
    """
    if isinstance(names, dict):
        names = list(names.keys())
    return {name: load_run(name, results_dir) for name in names}


def load_all_runs(
    results_dir: Path | str | None = None,
) -> dict[str, RunData]:
    """Load all runs from the results directory (expensive)."""
    names = list_runs(results_dir)
    return {name: load_run(name, results_dir) for name in names}


def _match_config(
    name: str,
    c: RunConfig,
    *,
    mode: str | None = None,
    eplb: bool | None = None,
    eplb_mode: str | None = None,
    eplb_scope: str | None = None,
    model: str | None = None,
    dataset: str | None = None,
    decode_pods: int | None = None,
    prefill_pods: int | None = None,
    topology: str | None = None,
    routing_simulation: str | None = None,
    name_contains: str | None = None,
    name_excludes: str | None = None,
    fork: str | None = None,
) -> bool:
    """Return True if config passes all filters."""
    if mode is not None and c.mode != mode:
        return False
    if eplb is not None and c.eplb_enabled != eplb:
        return False
    if eplb_mode is not None and c.eplb_mode != eplb_mode:
        return False
    if eplb_scope is not None and c.eplb_scope != eplb_scope:
        return False
    if model is not None and model.lower() not in c.model.lower():
        return False
    if dataset is not None and c.dataset != dataset:
        return False
    if decode_pods is not None and c.decode_pods != decode_pods:
        return False
    if prefill_pods is not None and c.prefill_pods != prefill_pods:
        return False
    if topology is not None and topology not in c.topology_str:
        return False
    if routing_simulation is not None and routing_simulation not in c.routing_simulation_str:
        return False
    if name_contains is not None and name_contains not in name:
        return False
    if name_excludes is not None and name_excludes in name:
        return False
    if fork is not None and fork.lower() not in c.fork.lower():
        return False
    return True


def filter_runs(
    runs: dict[str, RunData] | dict[str, RunConfig] | list[str] | None = None,
    *,
    results_dir: Path | str | None = None,
    mode: str | None = None,
    eplb: bool | None = None,
    eplb_mode: str | None = None,
    eplb_scope: str | None = None,
    model: str | None = None,
    dataset: str | None = None,
    decode_pods: int | None = None,
    prefill_pods: int | None = None,
    topology: str | None = None,
    routing_simulation: str | None = None,
    name_contains: str | None = None,
    name_excludes: str | None = None,
    fork: str | None = None,
    custom: callable | None = None,
) -> dict[str, RunConfig]:
    """Filter runs by config properties.  Returns ``{name: RunConfig}``.

    *runs* can be:
    - ``None`` — auto-discovers all runs via ``list_runs()``
    - a list of run names
    - a ``dict[str, RunConfig]`` (from a previous ``filter_runs`` call)
    - a ``dict[str, RunData]`` (from ``load_runs`` / ``load_all_runs``)

    The result is always ``dict[str, RunConfig]`` — cheap to produce.
    Pass it to ``load_runs()`` to get the full data.

    All filters are AND-ed.  ``None`` means "don't filter on this field".

    Args:
        results_dir: Override for the results root directory.
        mode: ``"pd"`` or ``"decode-bench"``.
        eplb: Whether decode EPLB is enabled.
        eplb_mode: ``"sync"``, ``"async"``, or ``"off"``.
        eplb_scope: ``"decode"``, ``"prefill"``, ``"decode+prefill"``, ``"none"``.
        model: Substring match on model name (case-insensitive).
        dataset: Exact dataset match.
        decode_pods: Exact number of decode pods.
        prefill_pods: Exact number of prefill pods.
        topology: Substring match on topology_str (e.g. ``"D=4"``).
        routing_simulation: Substring match on routing_simulation_str.
        name_contains: Substring match on run name.
        name_excludes: Exclude runs whose name contains this substring.
        fork: Substring match on fork repo/branch (case-insensitive).
        custom: Arbitrary predicate ``(name, config_or_run) -> bool``.

    Returns:
        Filtered ``dict[str, RunConfig]``.  Pass to ``load_runs()`` for full data.
    """
    if runs is None:
        configs = load_all_configs(results_dir)
    elif isinstance(runs, list):
        configs = {n: load_config(n, results_dir) for n in runs}
    elif runs and isinstance(next(iter(runs.values())), RunData):
        configs = {n: r.config for n, r in runs.items()}
    else:
        configs = runs

    filter_kw = dict(
        mode=mode, eplb=eplb, eplb_mode=eplb_mode, eplb_scope=eplb_scope,
        model=model, dataset=dataset, decode_pods=decode_pods,
        prefill_pods=prefill_pods, topology=topology,
        routing_simulation=routing_simulation, name_contains=name_contains,
        name_excludes=name_excludes, fork=fork,
    )

    out = {}
    for name, c in configs.items():
        if not _match_config(name, c, **filter_kw):
            continue
        if custom is not None and not custom(name, c):
            continue
        out[name] = c
    return out


def _runs_subtitle(runs: dict[str, RunData]) -> str:
    """Extract a common subtitle (model, dataset) from a dict of runs."""
    models: set[str] = set()
    datasets: set[str] = set()
    for run in runs.values():
        models.add(run.config.model_short)
        datasets.add(run.config.dataset)
    parts = list(models)
    if datasets:
        parts.append("dataset: " + "/".join(sorted(datasets)))
    return "  |  ".join(parts)


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
    latency_keys_seconds = {
        "ttft_p50", "ttft_p95", "ttft_p99",
        "itl_p50", "itl_p95", "itl_p99",
        "e2e_p50", "e2e_p95", "e2e_p99",
        "queue_p50", "queue_p95", "queue_p99",
        "prefill_time_p50", "prefill_time_p95", "prefill_time_p99",
        "nixl_xfer_p99",
    }
    latency_keys_ms = {
        "decode_time_p50", "decode_time_p95", "decode_time_p99",
    }
    for name, run in runs.items():
        row: dict = {
            "run": name,
            "mode": run.config.mode,
            "eplb": run.config.eplb_mode,
            "dataset": run.config.dataset,
            "decode_redundant": run.config.num_redundant,
            "prefill_redundant": run.config.prefill_num_redundant,
            "interval": run.config.step_interval,
            "lws_size": run.config.lws_size,
            "decode_pods": run.config.decode_pods,
            "prefill_pods": run.config.prefill_pods,
            "prom_duration_m": (run.config.prom_duration_s or 0) / 60,
        }
        if run.prometheus:
            for k, v in run.prometheus.summary_dict().items():
                if v is not None and k in latency_keys_seconds:
                    row[f"{k}_ms"] = v * 1000
                elif v is not None and k in latency_keys_ms:
                    row[f"{k}_ms"] = v
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

    latency_keys_seconds = {
        "ttft_p50", "ttft_p95", "ttft_p99",
        "itl_p50", "itl_p95", "itl_p99",
        "e2e_p50", "e2e_p95", "e2e_p99",
        "queue_p50", "queue_p95", "queue_p99",
        "prefill_time_p50", "prefill_time_p95", "prefill_time_p99",
        "nixl_xfer_p50", "nixl_xfer_p99",
        "nixl_post_time_p50", "nixl_post_time_p99",
    }
    latency_keys_ms = {
        "decode_time_p50", "decode_time_p95", "decode_time_p99",
    }
    gen_range = run.prometheus.stage_range_stats("gen_tokens_per_sec_range")

    rows = []
    for stage_meta in run.prometheus.get_stages():
        idx = stage_meta["stage"]
        row: dict = {
            "stage": idx,
            "concurrency": stage_meta["concurrency"],
        }
        for k, v in run.prometheus.stage_summary_dict(idx).items():
            if v is not None and k in latency_keys_seconds:
                row[f"{k}_ms"] = v * 1000
            elif v is not None and k in latency_keys_ms:
                row[f"{k}_ms"] = v
            elif v is not None:
                row[k] = v
        if gen_range and idx < len(gen_range) and gen_range[idx]["count"] > 0:
            s = gen_range[idx]
            row["gen_tokens_per_sec_mean"] = s["mean"]
            row["gen_tokens_per_sec_min"] = s["min"]
            row["gen_tokens_per_sec_max"] = s["max"]
        rows.append(row)
    return pd.DataFrame(rows).set_index("stage")


def _resolve_max_step(
    max_step: int | str | None, run: RunData, role: str
) -> int | None:
    if isinstance(max_step, str):
        return run.benchmark_max_step(role) if max_step == "auto" else None
    if isinstance(max_step, (int, float)):
        return int(max_step)
    return None


def balancedness_comparison_table(
    runs: dict[str, RunData],
    role: str = "decode",
    max_step: int | str | None = "auto",
) -> pd.DataFrame:
    """Build a comparison DataFrame of expert load balancedness across runs.

    Args:
        role: ``"decode"`` or ``"prefill"`` — only show dumps for this role.
        max_step: Trim snapshots beyond this step.  ``"auto"`` (default)
                  derives the cutoff per run from Prometheus stages + EPLB log
                  timestamps.  Pass an explicit ``int`` to use a fixed cutoff
                  for all runs, or ``None`` to disable trimming.
    """
    rows = []
    for name, run in runs.items():
        cutoff = _resolve_max_step(max_step, run, role)
        for model_key, expert in run.expert_loads.items():
            key_role = model_key.split("/")[0] if "/" in model_key else None
            if key_role is not None and key_role != role:
                continue
            bal = expert.balancedness_series()
            if bal.empty:
                continue
            if cutoff is not None:
                bal = bal[bal["step"] <= cutoff]
                if bal.empty:
                    continue
            label = run.label
            rows.append({
                "run": label,
                "eplb": run.config.eplb_mode,
                "snapshots": len(bal),
                "final_mean_bal": bal["mean_balancedness"].iloc[-1],
                "final_worst_bal": bal["worst_balancedness"].iloc[-1],
                "final_worst_layer": int(bal["worst_layer"].iloc[-1]),
                "avg_mean_bal": bal["mean_balancedness"].mean(),
                "avg_worst_bal": bal["worst_balancedness"].mean(),
            })
            break
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

    ax.plot(bal["step"], bal["vllm_balancedness"], marker="^", markersize=3,
            label="vLLM logged")
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
        for stage_meta in run.prometheus.get_stages():
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
        run_label = runs[name].label if name in runs else name
        ax.bar(x + i * width, vals, width, label=run_label)

    ax.set_ylabel("Latency (ms)")
    ax.set_xlabel("Concurrency")
    subtitle = _runs_subtitle(runs)
    ax.set_title(f"{title}\n{subtitle}" if subtitle else title, fontsize=11)
    ax.set_xticks(x + width * (n_runs - 1) / 2)
    ax.set_xticklabels(concurrencies, rotation=45, ha="right")
    ax.legend()
    ax.grid(axis="y", alpha=0.3)
    plt.tight_layout()


def plot_throughput_comparison(
    runs: dict[str, RunData],
    metric: str = "gen_tokens_per_sec",
    title: str | None = None,
):
    """Per-stage throughput bar chart across runs.

    Shows one group of bars per concurrency stage, with one bar per run.
    Mirrors the layout of ``plot_latency_comparison``.

    Args:
        metric: Prometheus instant metric key
                (e.g. ``"gen_tokens_per_sec"``, ``"prompt_tokens_per_sec"``).
        title: Plot title (auto-generated from metric if ``None``).
    """
    if title is None:
        title = f"{metric} by Concurrency Stage"

    run_stages: dict[str, list[tuple[int, float]]] = {}
    all_concurrencies: set[int] = set()

    for name, run in runs.items():
        if run.prometheus is None or run.prometheus.n_stages == 0:
            continue
        points = []
        for stage_meta in run.prometheus.get_stages():
            idx = stage_meta["stage"]
            conc = stage_meta["concurrency"]
            val = run.prometheus.stage_instant(idx, metric)
            if val is not None:
                points.append((conc, val))
                all_concurrencies.add(conc)
        if points:
            run_stages[run.label] = points

    if not run_stages or not all_concurrencies:
        print("No throughput data to plot"); return

    sorted_conc = sorted(all_concurrencies)
    n_runs = len(run_stages)
    width = 0.8 / max(n_runs, 1)
    x = np.arange(len(sorted_conc))

    fig, ax = plt.subplots(figsize=(max(10, len(sorted_conc) * 1.2), 6))
    for i, (label, points) in enumerate(run_stages.items()):
        lookup = dict(points)
        vals = [lookup.get(c, 0) for c in sorted_conc]
        offset = (i - (n_runs - 1) / 2) * width
        ax.bar(x + offset, vals, width, label=label, alpha=0.85)

    ax.set_xlabel("Concurrency")
    ax.set_ylabel("Tokens / sec")
    subtitle = _runs_subtitle(runs)
    ax.set_title(f"{title}\n{subtitle}" if subtitle else title, fontsize=11)
    ax.set_xticks(x)
    ax.set_xticklabels([str(c) for c in sorted_conc], rotation=30, ha="right")
    ax.legend(fontsize=8)
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
            ax.plot(df["time_min"], df["value"], label=run.label, alpha=0.8)

    ax.set_xlabel("Time (min)")
    ax.set_ylabel("Tokens / sec")
    subtitle = _runs_subtitle(runs)
    ax.set_title(f"{title}\n{subtitle}" if subtitle else title, fontsize=11)
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
            ax.plot(df["time_min"], df["value"] * 100, label=run.label, alpha=0.8)

    ax.set_xlabel("Time (min)")
    ax.set_ylabel("KV Cache Usage (%)")
    subtitle = _runs_subtitle(runs)
    ax.set_title(f"{title}\n{subtitle}" if subtitle else title, fontsize=11)
    ax.set_ylim(0, 105)
    ax.legend()
    ax.grid(alpha=0.3)
    plt.tight_layout()


def plot_balancedness_comparison(
    runs: dict[str, RunData],
    role: str = "decode",
    max_step: int | str | None = "auto",
    title: str | None = None,
    snapshot_idx: int = -1,
    show_heatmaps: bool = True,
):
    """Overlay balancedness over time for all runs that have expert load data.

    Args:
        role: ``"decode"`` or ``"prefill"`` — only show dumps for this role.
        max_step: Trim snapshots beyond this step.  ``"auto"`` (default)
                  derives the cutoff per run from Prometheus stages + EPLB log
                  timestamps.  Pass an explicit ``int`` for a fixed cutoff,
                  or ``None`` to disable trimming.
        show_heatmaps: When True (default), produce an additional figure with
            one expert-load heatmap per run (final snapshot by default).
    """
    # --- time-series plot ---
    fig, axes = plt.subplots(1, 2, figsize=(14, 5))

    entries: list[tuple[str, ExpertLoadData, int | None]] = []
    for name, run in runs.items():
        cutoff = _resolve_max_step(max_step, run, role)
        for model_key, expert in run.expert_loads.items():
            key_role = model_key.split("/")[0] if "/" in model_key else None
            if key_role is not None and key_role != role:
                continue
            bal = expert.balancedness_series()
            if bal.empty:
                continue
            if cutoff is not None:
                bal = bal[bal["step"] <= cutoff]
                if bal.empty:
                    continue
            label = run.label
            axes[0].plot(bal["step"], bal["mean_balancedness"],
                         marker="o", markersize=2, label=label, alpha=0.8)
            axes[1].plot(bal["step"], bal["worst_balancedness"],
                         marker="s", markersize=2, label=label, alpha=0.8)
            entries.append((label, expert, cutoff))
            break

    if title is None:
        first_run = next(iter(runs.values()), None)
        first_expert = entries[0][1] if entries else None
        info_parts = [f"Balancedness Comparison ({role})"]
        if first_run:
            info_parts.append(first_run.config.model_short)
            info_parts.append(f"dataset={first_run.config.dataset}")
        if first_expert:
            info_parts.append(f"EP={first_expert.world_size}")
        title = "  |  ".join(info_parts)

    fig.suptitle(title, fontsize=11)

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

    # --- heatmap grid ---
    if show_heatmaps and entries:
        n = len(entries)
        fig_h, axes_h = plt.subplots(
            n, 1,
            figsize=(max(14, entries[0][1].num_physical * 0.06), max(4, entries[0][1].num_layers * 0.12) * n),
            squeeze=False,
        )
        fig_h.suptitle(f"{title} — Expert Load Heatmaps", fontsize=11)
        for i, (label, expert, cutoff) in enumerate(entries):
            snap_idx = snapshot_idx
            if cutoff is not None and snap_idx == -1:
                snap_idx = expert.closest_snapshot_idx(cutoff)
            plot_expert_load_heatmap(
                expert, snapshot_idx=snap_idx,
                title_suffix=f"  [{label}]", ax=axes_h[i, 0],
            )
        plt.tight_layout()


def plot_rank_balance_at_steps(
    run: RunData,
    role: str = "decode",
    steps: list[int] | None = None,
):
    """Show per-rank load heatmap + per-layer balancedness for a run at given steps.

    Args:
        run: A loaded RunData object.
        role: ``"decode"`` or ``"prefill"`` (matches the key prefix in
              ``run.expert_loads``). Falls back to the first available entry
              when there are no subdirectory-keyed loads.
        steps: Step numbers to visualize.  The closest available snapshot is
               used for each.  ``None`` defaults to ``[first, last]``.
    """
    expert = None
    for key, val in run.expert_loads.items():
        if key.startswith(f"{role}/") or (role in key):
            expert = val
            break
    if expert is None:
        candidates = list(run.expert_loads.keys())
        if not candidates:
            print(f"No expert load data in run '{run.name}'")
            return
        expert = run.expert_loads[candidates[0]]
        print(f"Role '{role}' not found, falling back to '{candidates[0]}'")

    if steps is None:
        all_steps = expert.steps
        steps = [all_steps[0], all_steps[-1]]

    n = len(steps)
    fig, axes = plt.subplots(
        n, 2,
        figsize=(16, max(4, expert.num_layers * 0.1) * n),
        squeeze=False,
    )
    fig.suptitle(
        f"{run.label} — {role}  |  {expert.model}  |  EP={expert.world_size} | dataset: {run.config.dataset}",
        fontsize=11,
    )

    for row, target_step in enumerate(steps):
        idx = expert.closest_snapshot_idx(target_step)
        snap, load, _ = expert.snapshot(idx)
        actual_step = snap["step"]
        rank_load = load.reshape(
            expert.num_layers, expert.world_size, expert.experts_per_rank
        ).sum(axis=2)

        ax_hm = axes[row, 0]
        im = ax_hm.imshow(
            rank_load, aspect="auto", interpolation="nearest", cmap="YlOrRd",
        )
        ax_hm.set_xticks(np.arange(expert.world_size))
        ax_hm.set_xlabel("Rank")
        ax_hm.set_ylabel("Layer")
        ax_hm.set_title(f"Rank Load  (step {actual_step})")
        fig.colorbar(im, ax=ax_hm, label="Tokens", shrink=0.8)

        mean_load = rank_load.mean(axis=1)
        max_load = rank_load.max(axis=1)
        bal = np.where(max_load > 0, mean_load / max_load, 0.0)
        layers = np.arange(expert.num_layers)
        axes[row, 1].barh(layers, bal, color="steelblue")
        axes[row, 1].set_xlabel("Balancedness (mean / max)")
        axes[row, 1].set_ylabel("Layer")
        axes[row, 1].set_title(
            f"Per-Layer Balance  (step {actual_step})  "
            f"avg={bal.mean():.3f}  worst={bal.min():.3f}@L{int(bal.argmin())}"
        )
        axes[row, 1].set_xlim(0, 1.05)
        axes[row, 1].axvline(x=1.0, color="green", linestyle="--", alpha=0.5)
        axes[row, 1].invert_yaxis()

    plt.tight_layout()


def _step_epoch(run: RunData, role: str, step: int) -> float | None:
    """Find the epoch timestamp for a given step from EPLB logs."""
    pairs = run.step_timestamps.get(role, [])
    for s, epoch in pairs:
        if s == step:
            return epoch
    return None


def plot_load_vs_latency(
    run: RunData,
    role: str = "decode",
    step: int | None = None,
    latency_metric: str = "e2e_p99_range",
    title: str | None = None,
):
    """Scatter plot of per-rank expert load vs per-rank latency.

    Requires per-rank Prometheus range metrics (collected with
    ``build_per_rank_range_defs``) and expert load dumps.

    The Prometheus value is sampled at the epoch timestamp of the
    requested dump step, so latency and load are time-aligned.

    Args:
        run: A loaded RunData.
        role: ``"decode"`` or ``"prefill"``.
        step: Step number for the expert load snapshot (``None`` = last
              in-benchmark step).
        latency_metric: Column name from ``per_rank_table()``
                        (e.g. ``"e2e_p99_range"``, ``"decode_time_p99_range"``).
    """
    if run.prometheus is None:
        print("No Prometheus data"); return

    # Resolve step and find its timestamp for time-aligned sampling
    expert = None
    for key, val in run.expert_loads.items():
        if key.startswith(f"{role}/") or (role in key):
            expert = val; break
    if expert is None:
        print(f"No expert load data for role '{role}'"); return

    if step is None:
        ms = run.benchmark_max_step(role)
        step = ms if ms is not None else expert.dedup_snapshots()[-1]["step"]

    at_ts = _step_epoch(run, role, step)

    rank_df = run.prometheus.per_rank_table(at=at_ts)
    if rank_df.empty:
        print("No per-rank Prometheus metrics (re-run collect-prometheus.py)"); return
    if latency_metric not in rank_df.columns:
        print(f"Metric '{latency_metric}' not found. Available: {list(rank_df.columns)}"); return

    rank_load = expert.rank_total_load(step)

    deploy = run.config.raw.get("DEPLOY_NAME", "")
    dp_local = 4 // int(run.config.raw.get("DECODE_TP_SIZE", run.config.raw.get("TP_SIZE", "1")))

    latencies = []
    loads = []
    labels = []
    for (pod, local_rank), row in rank_df.iterrows():
        if role == "decode" and "decode" not in pod:
            continue
        if role == "prefill" and "prefill" not in pod:
            continue
        lat = row.get(latency_metric)
        if lat is None or np.isnan(lat):
            continue
        parts = pod.rsplit("-", 1)
        try:
            pod_idx = int(parts[-1]) if parts else 0
        except ValueError:
            pod_idx = 0
        global_rank = pod_idx * dp_local + int(local_rank)
        if global_rank >= len(rank_load):
            continue
        latencies.append(lat * 1000)
        loads.append(float(rank_load[global_rank]))
        labels.append(f"p{pod_idx}r{local_rank}")

    if not latencies:
        print("No matching data points"); return

    fig, ax = plt.subplots(figsize=(8, 6))
    ax.scatter(loads, latencies, s=60, alpha=0.7, edgecolors="k", linewidths=0.5)
    for i, lbl in enumerate(labels):
        ax.annotate(lbl, (loads[i], latencies[i]), fontsize=7,
                    xytext=(4, 4), textcoords="offset points")

    metric_short = latency_metric.replace("_range", "")
    ax.set_xlabel("Total Expert Load (tokens)")
    ax.set_ylabel(f"{metric_short} (ms)")
    if title is None:
        align = f"ts={at_ts:.0f}" if at_ts else "last value"
        title = (f"{run.label} — {role} load vs latency\n"
                 f"step={step}  |  {align}  |  {run.config.model_short}  |  dataset: {run.config.dataset}  |  EP={expert.world_size}")
    ax.set_title(title, fontsize=10)
    ax.grid(alpha=0.3)

    if len(loads) >= 2:
        z = np.polyfit(loads, latencies, 1)
        xs = np.linspace(min(loads), max(loads), 50)
        ax.plot(xs, np.polyval(z, xs), "--", color="red", alpha=0.5,
                label=f"slope={z[0]:.2e}")
        corr = np.corrcoef(loads, latencies)[0, 1]
        ax.legend(title=f"r={corr:.3f}", fontsize=8)

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
            ax.plot(df["time_min"], df["value"] * 1000, label=run.label, alpha=0.8)

    ax.set_xlabel("Time (min)")
    ax.set_ylabel("Latency (ms)")
    subtitle = _runs_subtitle(runs)
    ax.set_title(f"{title}\n{subtitle}" if subtitle else title, fontsize=11)
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
        labels.append(run.label)
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
    subtitle = _runs_subtitle(runs)
    ax.set_title(f"{title}\n{subtitle}" if subtitle else title, fontsize=11)
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
    subtitle = _runs_subtitle(runs)
    fig.suptitle(f"{title}\n{subtitle}" if subtitle else title, fontsize=11)

    for name, run in runs.items():
        if run.prometheus is None:
            continue
        lbl = run.label
        df_dec = run.prometheus.range_series("decode_time_p99_range")
        if df_dec is not None:
            axes[0].plot(df_dec["time_min"], df_dec["value"] * 1000,
                         label=lbl, alpha=0.8)
        df_pf = run.prometheus.range_series("prefill_time_p99_range")
        if df_pf is not None:
            axes[1].plot(df_pf["time_min"], df_pf["value"] * 1000,
                         label=lbl, alpha=0.8)

    for ax, sub_title in [(axes[0], "Decode P99"), (axes[1], "Prefill P99")]:
        ax.set_xlabel("Time (min)")
        ax.set_ylabel("Latency (ms)")
        ax.set_title(sub_title)
        ax.legend(fontsize=8)
        ax.grid(alpha=0.3)
    plt.tight_layout()


# ---------------------------------------------------------------------------
# Plotting: per-rank latency analysis
# ---------------------------------------------------------------------------


def _per_rank_range_series(
    prom: PrometheusData,
    metric_key: str,
    role: str = "decode",
) -> pd.DataFrame:
    """Parse a per-rank range metric into a tidy DataFrame.

    Returns columns: ``timestamp``, ``time_min``, ``pod``, ``rank``, ``value``.
    Only pods matching *role* are included.
    """
    entry = prom.raw.get(metric_key, {})
    if entry.get("status") != "success":
        return pd.DataFrame()
    results = entry.get("data", {}).get("result", [])
    rows = []
    for series in results:
        labels = series.get("metric", {})
        pod = labels.get("pod", "")
        if role and role not in pod:
            continue
        rank = labels.get("rank", "0")
        for ts_str, val_str in series.get("values", []):
            try:
                rows.append({
                    "timestamp": float(ts_str),
                    "pod": pod,
                    "rank": int(rank),
                    "value": float(val_str) if val_str != "NaN" else np.nan,
                })
            except (TypeError, ValueError):
                continue
    if not rows:
        return pd.DataFrame()
    df = pd.DataFrame(rows)
    t0 = df["timestamp"].min()
    df["time_min"] = (df["timestamp"] - t0) / 60
    return df


def _global_rank(pod: str, local_rank: int, dp_local: int = 4) -> int:
    """Derive the EP global rank from pod name and local rank."""
    parts = pod.rsplit("-", 1)
    try:
        pod_idx = int(parts[-1])
    except (ValueError, IndexError):
        pod_idx = 0
    return pod_idx * dp_local + local_rank


def _stage_window(prom: PrometheusData, stage_idx: int) -> tuple[float, float] | None:
    """Return (start, end) timestamps for a stage's central half."""
    stages = prom.get_stages()
    if stage_idx >= len(stages):
        return None
    s = stages[stage_idx]
    mid = (s["start_time"] + s["end_time"]) / 2
    window = (s["end_time"] - s["start_time"]) / 4
    return (mid - window, mid + window)


def _rank_medians_for_stage(
    df: pd.DataFrame,
    prom: PrometheusData,
    stage_idx: int,
) -> dict[int, float]:
    """Compute per-rank median values within a stage's time window."""
    bounds = _stage_window(prom, stage_idx)
    if bounds is None:
        return {}
    t0, t1 = bounds
    sub = df[(df["timestamp"] >= t0) & (df["timestamp"] <= t1)]
    out: dict[int, float] = {}
    for (pod, rank), grp in sub.groupby(["pod", "rank"]):
        gr = _global_rank(pod, rank)
        vals = grp["value"].dropna()
        if not vals.empty:
            out[gr] = float(vals.median())
    return out


def plot_per_rank_latency_heatmap(
    runs: dict[str, RunData],
    metric: str = "itl_p99",
    role: str = "decode",
    stage: int | None = None,
    title: str | None = None,
):
    """Heatmap of per-rank latency across concurrency stages (one subplot per run).

    Rows = EP ranks, columns = concurrency stages.  Colour intensity shows the
    median metric value within the stage's time window.

    If *stage* is given, only that single stage column is shown.
    """
    key = f"per_rank_{metric}_range"
    metric_label = metric.replace("_", " ").upper()
    _no_scale = ("tokens_per_sec", "requests_running", "requests_waiting",
                 "kv_cache_usage", "iteration_tokens")
    is_tps = any(s in metric for s in _no_scale)
    if is_tps or metric.startswith("decode_time"):
        scale = 1.0
    else:
        scale = 1000.0

    valid = [(n, r) for n, r in runs.items()
             if r.prometheus is not None and r.prometheus.n_stages > 0]
    if not valid:
        print("No per-stage data"); return

    n = len(valid)
    fig, axes = plt.subplots(1, n, figsize=(6 * n + 2, 8), squeeze=False)

    for col, (name, run) in enumerate(valid):
        ax = axes[0, col]
        df = _per_rank_range_series(run.prometheus, key, role)
        all_stages = run.prometheus.get_stages()

        if df.empty or not all_stages:
            ax.set_title(f"{run.label} — no data")
            continue

        stage_indices = [stage] if stage is not None else list(range(len(all_stages)))

        conc_labels = []
        matrix_cols = []
        all_ranks: set[int] = set()
        for si in stage_indices:
            if si >= len(all_stages):
                continue
            rm = _rank_medians_for_stage(df, run.prometheus, si)
            all_ranks.update(rm.keys())
            matrix_cols.append(rm)
            conc_labels.append(str(all_stages[si]["concurrency"]))

        sorted_ranks = sorted(all_ranks)
        mat = np.full((len(sorted_ranks), len(matrix_cols)), np.nan)
        for ci, rm in enumerate(matrix_cols):
            for ri, r in enumerate(sorted_ranks):
                if r in rm:
                    mat[ri, ci] = rm[r] * scale

        im = ax.imshow(mat, aspect="auto", cmap="YlOrRd" if not is_tps else "YlGn")
        ax.set_xticks(range(len(conc_labels)))
        ax.set_xticklabels(conc_labels, fontsize=8)
        ax.set_xlabel("Concurrency")
        ax.set_yticks(range(len(sorted_ranks)))
        ax.set_yticklabels([f"R{r}" for r in sorted_ranks], fontsize=7)
        if col == 0:
            ax.set_ylabel("EP Rank")
        ax.set_title(f"{run.label}")
        _unit = ("tok/s" if "tokens_per_sec" in metric
                 else "reqs" if "requests_" in metric
                 else "%" if "cache_usage" in metric
                 else "tokens" if "iteration_tokens" in metric
                 else "ms")
        plt.colorbar(im, ax=ax, shrink=0.6,
                     label=f"{metric_label} ({_unit})")

    default_title = f"Per-Rank {metric_label} by Stage ({role})"
    subtitle = _runs_subtitle(runs)
    full = f"{title or default_title}\n{subtitle}" if subtitle else (title or default_title)
    fig.suptitle(full, fontsize=12, y=1.02)
    plt.tight_layout()


def plot_per_rank_latency_spread(
    runs: dict[str, RunData],
    metric: str = "itl_p99",
    role: str = "decode",
    title: str | None = None,
):
    """Per-stage min/median/max spread across ranks, one subplot per run.

    For each concurrency stage the plot shows a point for the median across
    ranks and error bars spanning the min-max range.
    """
    key = f"per_rank_{metric}_range"
    metric_label = metric.replace("_", " ").upper()
    _no_scale = ("tokens_per_sec", "requests_running", "requests_waiting",
                 "kv_cache_usage", "iteration_tokens")
    is_tps = any(s in metric for s in _no_scale)
    if is_tps or metric.startswith("decode_time"):
        scale = 1.0
    else:
        scale = 1000.0
    colors = plt.cm.tab10.colors

    fig, ax = plt.subplots(figsize=(12, 5))

    # Build shared x-axis from all concurrency values across runs
    all_concs: list[int] = []
    for run in runs.values():
        if run.prometheus and run.prometheus.n_stages > 0:
            all_concs = [s["concurrency"] for s in run.prometheus.get_stages()]
            break

    for i, (name, run) in enumerate(runs.items()):
        if run.prometheus is None or run.prometheus.n_stages == 0:
            continue
        df = _per_rank_range_series(run.prometheus, key, role)
        if df.empty:
            continue

        stages = run.prometheus.get_stages()
        run_data: dict[int, tuple] = {}
        for si, sm in enumerate(stages):
            rm = _rank_medians_for_stage(df, run.prometheus, si)
            if not rm:
                continue
            vals = np.array(list(rm.values())) * scale
            run_data[sm["concurrency"]] = (np.median(vals), np.min(vals), np.max(vals))

        if not run_data:
            continue
        color = colors[i % len(colors)]

        x_pos, meds_a, los_a, his_a = [], [], [], []
        for xi, c in enumerate(all_concs):
            if c in run_data:
                med, lo, hi = run_data[c]
                x_pos.append(xi)
                meds_a.append(med)
                los_a.append(lo)
                his_a.append(hi)

        meds_a = np.array(meds_a)
        los_a = np.array(los_a)
        his_a = np.array(his_a)
        ax.errorbar(x_pos, meds_a,
                    yerr=[meds_a - los_a, his_a - meds_a],
                    fmt="o-", capsize=4, color=color, linewidth=1.5,
                    label=run.label, alpha=0.85)

    ax.set_xticks(range(len(all_concs)))
    ax.set_xticklabels([str(c) for c in all_concs], fontsize=9)
    ax.set_xlabel("Concurrency")
    _unit = ("tok/s" if "tokens_per_sec" in metric
             else "reqs" if "requests_" in metric
             else "%" if "cache_usage" in metric
             else "tokens" if "iteration_tokens" in metric
             else "ms")
    ax.set_ylabel(f"{metric_label} ({_unit})")
    default_title = title or f"Per-Rank {metric_label} Spread by Stage ({role})"
    subtitle = _runs_subtitle(runs)
    ax.set_title(f"{default_title}\n{subtitle}" if subtitle else default_title, fontsize=11)
    ax.legend()
    ax.grid(alpha=0.3)
    plt.tight_layout()


def plot_per_rank_comparison(
    runs: dict[str, RunData],
    metric: str = "itl_p99",
    role: str = "decode",
    stage: int | None = None,
    title: str | None = None,
):
    """Bar chart of per-rank latency at a given concurrency stage.

    If *stage* is ``None``, plots one facet per stage in the first run that
    has stage data.  When a single stage index is given, draws a single chart.
    """
    key = f"per_rank_{metric}_range"
    metric_label = metric.replace("_", " ").upper()
    _no_scale = ("tokens_per_sec", "requests_running", "requests_waiting",
                 "kv_cache_usage", "iteration_tokens")
    is_tps = any(s in metric for s in _no_scale)
    if is_tps or metric.startswith("decode_time"):
        scale = 1.0
    else:
        scale = 1000.0

    ref_stages = None
    for run in runs.values():
        if run.prometheus and run.prometheus.n_stages > 0:
            ref_stages = run.prometheus.get_stages()
            break
    if ref_stages is None:
        print("No stage data"); return

    stage_indices = [stage] if stage is not None else list(range(len(ref_stages)))

    n_stages = len(stage_indices)
    fig, axes = plt.subplots(1, n_stages,
                             figsize=(max(12, 5 * n_stages), 5),
                             squeeze=False, sharey=True)

    for col, si in enumerate(stage_indices):
        ax = axes[0, col]
        conc = ref_stages[si]["concurrency"] if si < len(ref_stages) else "?"

        all_data: list[tuple[str, dict[int, float]]] = []
        all_ranks: set[int] = set()

        for name, run in runs.items():
            if run.prometheus is None:
                continue
            df = _per_rank_range_series(run.prometheus, key, role)
            if df.empty:
                continue
            rm = _rank_medians_for_stage(df, run.prometheus, si)
            rank_vals = {r: v * scale for r, v in rm.items()}
            all_ranks.update(rank_vals.keys())
            all_data.append((run.label, rank_vals))

        if not all_data:
            ax.set_title(f"C={conc} — no data"); continue

        sorted_ranks = sorted(all_ranks)
        n_runs = len(all_data)
        x = np.arange(len(sorted_ranks))
        width = 0.8 / max(n_runs, 1)

        for j, (label, rank_vals) in enumerate(all_data):
            vals = [rank_vals.get(r, 0) for r in sorted_ranks]
            ax.bar(x + j * width - 0.4 + width / 2, vals, width,
                   label=label, alpha=0.85)

        ax.set_xlabel("EP Rank")
        ax.set_xticks(x)
        ax.set_xticklabels([f"R{r}" for r in sorted_ranks], fontsize=7, rotation=90)
        ax.set_title(f"Concurrency = {conc}")
        ax.grid(axis="y", alpha=0.3)
        if col == 0:
            _unit = ("tok/s" if "tokens_per_sec" in metric
                     else "reqs" if "requests_" in metric
                     else "%" if "cache_usage" in metric
                     else "tokens" if "iteration_tokens" in metric
                     else "ms")
            ax.set_ylabel(f"{metric_label} ({_unit})")

    axes[0, 0].legend(fontsize=8, bbox_to_anchor=(0, -0.25), loc="upper left", ncol=min(len(runs), 4))
    default_title = f"Per-Rank {metric_label} by Stage ({role})"
    subtitle = _runs_subtitle(runs)
    full = f"{title or default_title}\n{subtitle}" if subtitle else (title or default_title)
    fig.suptitle(full, fontsize=12, y=1.02)
    plt.tight_layout(rect=[0, 0.08, 1, 1])


def per_rank_stats_table(
    runs: dict[str, RunData],
    role: str = "decode",
    stage: int | None = None,
    metrics: list[str] | None = None,
) -> pd.DataFrame:
    """Per-rank latency stats broken down by concurrency stage.

    Returns a multi-indexed DataFrame (run × stage × metric) with mean, std,
    min, max, max/mean ratio, and the slowest/fastest ranks.

    If *stage* is given, only that stage is included.  Otherwise all stages.
    """
    if metrics is None:
        metrics = ["itl_p50", "itl_p99", "decode_time_p50", "decode_time_p99",
                    "gen_tokens_per_sec"]

    rows = []
    for name, run in runs.items():
        if run.prometheus is None or run.prometheus.n_stages == 0:
            continue
        stage_list = run.prometheus.get_stages()
        indices = [stage] if stage is not None else list(range(len(stage_list)))

        for si in indices:
            if si >= len(stage_list):
                continue
            conc = stage_list[si]["concurrency"]

            for metric in metrics:
                key = f"per_rank_{metric}_range"
                df = _per_rank_range_series(run.prometheus, key, role)
                if df.empty:
                    continue

                rank_medians = _rank_medians_for_stage(df, run.prometheus, si)
                if not rank_medians:
                    continue

                vals = np.array(list(rank_medians.values()))
                if "tokens_per_sec" in metric or metric.startswith("decode_time"):
                    sc = 1.0
                else:
                    sc = 1000.0

                rows.append({
                    "run": run.label,
                    "concurrency": conc,
                    "metric": metric,
                    "mean": vals.mean() * sc,
                    "std": vals.std() * sc,
                    "min": vals.min() * sc,
                    "max": vals.max() * sc,
                    "max/mean": vals.max() / vals.mean() if vals.mean() > 0 else np.nan,
                    "min_rank": int(min(rank_medians, key=rank_medians.get)),
                    "max_rank": int(max(rank_medians, key=rank_medians.get)),
                })

    if not rows:
        return pd.DataFrame()
    return pd.DataFrame(rows).set_index(["run", "concurrency", "metric"])


def plot_pareto_frontier(
    runs: dict[str, RunData],
    gpus_per_pod: int = 4,
    title: str | None = None,
):
    """Plot throughput-per-GPU vs per-user output speed across concurrency stages.

    Each run produces a curve from its per-stage metrics.  Points toward the
    upper-right are Pareto-optimal.
    """
    fig, ax = plt.subplots(figsize=(12, 7))
    markers = ["o", "s", "D", "^", "v", "P", "X", "*"]
    models: set[str] = set()
    datasets: set[str] = set()

    for i, (name, run) in enumerate(runs.items()):
        if run.prometheus is None or run.prometheus.n_stages == 0:
            continue

        dp = run.config.decode_pods or 0
        pp = run.config.prefill_pods or 0
        total_gpus = (dp + pp) * gpus_per_pod or 1

        x_vals, y_vals = [], []
        for stage in run.prometheus.get_stages():
            gen_tps = run.prometheus.stage_instant(stage["stage"], "gen_tokens_per_sec")
            conc = stage["concurrency"]
            if not gen_tps or gen_tps <= 0 or conc <= 0:
                continue
            x_vals.append(gen_tps / conc)
            y_vals.append(gen_tps / total_gpus)

        if not x_vals:
            continue

        ax.plot(x_vals, y_vals, marker=markers[i % len(markers)],
                markersize=7, linewidth=1.5, label=run.label_long, alpha=0.85)
        models.add(run.config.model_short)
        datasets.add(run.config.dataset)
    assert len(models) == 1, "Comparing runs with different models"
    assert len(datasets) == 1, "Comparing runs with different datasets"

    subtitle = "  |  ".join([*models, f"1 node = {gpus_per_pod}xGB200", "dataset: " + datasets.pop()])
    main_title = title or "Throughput vs Interactivity (Pareto Frontier)"
    ax.set_title(f"{main_title}\n{subtitle}", fontsize=11)
    ax.set_xlabel("Tokens/s/user")
    ax.set_ylabel("Tokens/s/GPU")
    ax.legend(loc="best", fontsize=9)
    ax.grid(alpha=0.3)
    plt.tight_layout()


def plot_throughput_vs_concurrency(
    runs: dict[str, RunData],
    gpus_per_pod: int = 4,
    title: str | None = None,
):
    """Plot output tokens/s per decode GPU vs total concurrency per GPU.

    Uses the mean gen_tokens_per_sec over each stage window (from the range
    query) with min/max shown as error bars.  Falls back to the instant
    (end-of-stage) value when range data is unavailable.

    Total concurrency = per-worker concurrency * n_workers.
    X-axis is normalized by decode GPUs to make different topologies comparable.
    """
    fig, ax = plt.subplots(figsize=(12, 7))
    markers = ["o", "s", "D", "^", "v", "P", "X", "*"]
    models: set[str] = set()
    datasets: set[str] = set()
    for i, (name, run) in enumerate(runs.items()):
        if run.prometheus is None or run.prometheus.n_stages == 0:
            continue

        dp = run.config.decode_pods or 0
        decode_gpus = dp * gpus_per_pod or 1
        n_workers = run.config.n_workers

        range_stats = run.prometheus.stage_range_stats("gen_tokens_per_sec_range")

        x_vals, y_means, y_lo, y_hi = [], [], [], []
        for j, stage in enumerate(run.prometheus.get_stages()):
            conc = stage["concurrency"]
            if conc <= 0:
                continue
            total_conc = conc * n_workers

            if range_stats and j < len(range_stats) and range_stats[j]["count"] > 0:
                s = range_stats[j]
                mean_v = s["mean"] / decode_gpus
                min_v = s["min"] / decode_gpus
                max_v = s["max"] / decode_gpus
            else:
                gen_tps = run.prometheus.stage_instant(stage["stage"], "gen_tokens_per_sec")
                if not gen_tps or gen_tps <= 0:
                    continue
                mean_v = gen_tps / decode_gpus
                min_v = mean_v
                max_v = mean_v

            x_vals.append(total_conc / decode_gpus)
            y_means.append(mean_v)
            y_lo.append(mean_v - min_v)
            y_hi.append(max_v - mean_v)

        if not x_vals:
            continue

        color = f"C{i}"
        ax.errorbar(x_vals, y_means, yerr=[y_lo, y_hi],
                     marker=markers[i % len(markers)], markersize=7,
                     linewidth=1.5, capsize=4, capthick=1.2,
                     label=run.label_long, alpha=0.85, color=color)
        models.add(run.config.model_short)
        datasets.add(run.config.dataset)
    assert len(models) == 1, "Comparing runs with different models"
    assert len(datasets) == 1, "Comparing runs with different datasets"

    subtitle = "  |  ".join([*models, f"1 node = {gpus_per_pod}xGB200", "dataset: " + datasets.pop()])
    main_title = title or "Decode Throughput vs Concurrency (per GPU)"
    ax.set_title(f"{main_title}\n{subtitle}", fontsize=11)
    ax.set_xlabel("Total concurrency / decode GPU")
    ax.set_ylabel("Output tokens/s / decode GPU (mean, min/max)")
    ax.legend(loc="best", fontsize=9)
    ax.grid(alpha=0.3)
    plt.tight_layout()
