#!/usr/bin/env python3
"""Plot Pareto curve from glm-pareto CSV sweep results.

Combines data from multiple config CSV files and plots the Pareto frontier.
Default: TPSU (X) vs TPSG (Y). Points on the frontier are non-dominated
(no other point has both higher TPSG AND higher TPSU).

Usage:
    python3 plot_pareto.py disagg-4p3d-32.csv disagg-2p3d-32.csv
    python3 plot_pareto.py disagg-4p3d-32.csv disagg-2p3d-32.csv -o pareto.png
"""

from __future__ import annotations

import argparse
import csv
from dataclasses import dataclass
from pathlib import Path


@dataclass
class DataPoint:
    config: str
    concurrency: int
    throughput: float  # Output tok/s
    ttft_ms: float    # TTFT mean (ms)
    tpsg: float
    tpsu: float


def load_csv(path: Path) -> list[DataPoint]:
    """Load a glm-pareto CSV and return list of DataPoint."""
    points: list[DataPoint] = []

    with open(path) as f:
        reader = csv.reader(f)
        rows = list(reader)

    # First row: config name in col 1
    config = rows[0][1] if len(rows) > 0 and len(rows[0]) > 1 else path.stem

    # Build lookup: metric name -> list of values (one per concurrency)
    metrics: dict[str, list[float]] = {}
    for row in rows[1:]:
        if len(row) < 2:
            continue
        label = row[1].strip()
        values = []
        for cell in row[2:]:
            try:
                values.append(float(cell))
            except (ValueError, TypeError):
                values.append(float("nan"))
        metrics[label] = values

    concurrencies = metrics.get("Concurrency", [])
    throughputs = metrics.get("Output tok/s", [])
    ttfts = metrics.get("TTFT mean (ms)", [])
    tpsgs = metrics.get("TPSG", [])
    tpsus = metrics.get("TPSU", [])

    n = min(
        len(concurrencies),
        len(throughputs),
        len(ttfts),
        len(tpsgs),
        len(tpsus),
    )
    for i in range(n):
        c = int(concurrencies[i]) if concurrencies[i] == concurrencies[i] else i
        t = throughputs[i] if i < len(throughputs) else 0
        ttft = ttfts[i] if i < len(ttfts) else 0
        tpsg = tpsgs[i] if i < len(tpsgs) else 0
        tpsu = tpsus[i] if i < len(tpsus) else 0

        if t > 0 and ttft > 0:
            points.append(
                DataPoint(
                    config=config,
                    concurrency=c,
                    throughput=t,
                    ttft_ms=ttft,
                    tpsg=tpsg,
                    tpsu=tpsu,
                )
            )

    return points


def pareto_frontier(
    points: list[DataPoint],
    *,
    x_maximize: bool = True,
    y_maximize: bool = True,
    x_val=lambda p: p.tpsu,
    y_val=lambda p: p.tpsg,
) -> list[DataPoint]:
    """Return points on the Pareto frontier.

    By default: maximize both TPSU (x) and TPSG (y). A point is Pareto-optimal
    if no other point has both higher x AND higher y.
    """
    frontier: list[DataPoint] = []
    for p in points:
        dominated = False
        px, py = x_val(p), y_val(p)
        for q in points:
            if p is q:
                continue
            qx, qy = x_val(q), y_val(q)
            # q dominates p if q is >= in both and > in at least one
            if x_maximize and y_maximize:
                if qx >= px and qy >= py and (qx > px or qy > py):
                    dominated = True
                    break
        if not dominated:
            frontier.append(p)

    # Sort by x for a nice curve left-to-right
    frontier.sort(key=lambda p: x_val(p))
    return frontier


def main() -> None:
    parser = argparse.ArgumentParser(description="Plot Pareto curve from glm-pareto CSV files")
    parser.add_argument("csv_files", nargs="+", type=Path, help="Input CSV files")
    parser.add_argument("-o", "--output", type=Path, default=Path("pareto.png"), help="Output image path")
    parser.add_argument("--x", choices=["ttft", "tpsu"], default="tpsu", help="X-axis metric")
    parser.add_argument("--y", choices=["throughput", "tpsg"], default="tpsg", help="Y-axis metric")
    parser.add_argument("--combined", action="store_true", help="Use combined Pareto frontier across all configs (default: per-config)")
    args = parser.parse_args()

    all_points: list[DataPoint] = []
    for path in args.csv_files:
        if not path.exists():
            parser.error(f"File not found: {path}")
        all_points.extend(load_csv(path))

    if not all_points:
        print("No data points loaded.")
        return 1

    # Pareto frontier: TTFT is minimize (negate for domination), others maximize
    def x_val(p):
        return p.tpsu if args.x == "tpsu" else -p.ttft_ms

    def y_val(p):
        return p.tpsg if args.y == "tpsg" else p.throughput

    if not args.combined:
        # Pareto frontier per config (each config's curve considers only its own points)
        frontiers = {}
        for config in sorted(set(p.config for p in all_points)):
            pts = [p for p in all_points if p.config == config]
            f = pareto_frontier(pts, x_maximize=True, y_maximize=True, x_val=x_val, y_val=y_val)
            if f:
                frontiers[config] = f
        if not frontiers:
            print("Empty Pareto frontiers.")
            return 1
        combined_frontier = [p for f in frontiers.values() for p in f]
        combined_frontier.sort(key=lambda p: (p.config, x_val(p)))
    else:
        # Combined Pareto frontier (all points compete)
        combined_frontier = pareto_frontier(
            all_points, x_maximize=True, y_maximize=True, x_val=x_val, y_val=y_val
        )
        frontiers = {None: combined_frontier} if combined_frontier else {}
        if not combined_frontier:
            print("Empty Pareto frontier.")
            return 1

    try:
        import matplotlib.pyplot as plt
    except ImportError:
        print("matplotlib required: pip install matplotlib")
        return 1

    # X,Y axes
    if args.x == "ttft":
        x_label = "TTFT mean (ms)"
    else:
        x_label = "TPSU (tok/s/user)"

    if args.y == "throughput":
        y_label = "Output tok/s"
    else:
        y_label = "TPSG (tok/s/GPU)"

    # Color and marker per config (distinct markers avoid overlap hiding)
    configs = sorted(set(p.config for p in all_points))
    colors = plt.cm.tab10.colors
    markers = ["o", "s", "^", "D", "v", "p", "*", "h"]
    config_colors = {c: colors[i % len(colors)] for i, c in enumerate(configs)}
    config_markers = {c: markers[i % len(markers)] for i, c in enumerate(configs)}

    fig, ax = plt.subplots(figsize=(10, 6))

    # Scatter all points - plot in reverse order so first config is on top (visible)
    for config in reversed(configs):
        pts = [p for p in all_points if p.config == config]
        xs = [p.ttft_ms if args.x == "ttft" else p.tpsu for p in pts]
        ys = [p.throughput if args.y == "throughput" else p.tpsg for p in pts]
        ax.scatter(
            xs, ys,
            c=[config_colors[config]],
            marker=config_markers[config],
            label=config,
            alpha=0.8,
            s=80,
            zorder=2,
            edgecolors="white",
            linewidths=0.5,
        )

    # Pareto frontier line(s)
    if not args.combined:
        for config in configs:
            if config not in frontiers:
                continue
            front = frontiers[config]
            x_f = [p.ttft_ms if args.x == "ttft" else p.tpsu for p in front]
            y_f = [p.throughput if args.y == "throughput" else p.tpsg for p in front]
            color = config_colors[config]
            ax.plot(x_f, y_f, "-", color=color, linewidth=2, alpha=0.9, zorder=3)
            ax.scatter(x_f, y_f, c=[color], s=100, marker=config_markers[config], edgecolors="white", linewidths=1.5, zorder=4)
    else:
        x_front = [p.ttft_ms if args.x == "ttft" else p.tpsu for p in combined_frontier]
        y_front = [p.throughput if args.y == "throughput" else p.tpsg for p in combined_frontier]
        ax.plot(x_front, y_front, "k-", linewidth=2, alpha=0.8, label="Pareto frontier", zorder=3)
        ax.scatter(x_front, y_front, c="black", s=100, marker="o", edgecolors="white", linewidths=1.5, zorder=4)

    ax.set_xlabel(x_label, fontsize=12)
    ax.set_ylabel(y_label, fontsize=12)
    ax.set_title(f"Pareto Curve: {y_label} vs {x_label}")
    ax.legend(loc="best", fontsize=10)
    ax.grid(True, alpha=0.3)
    ax.set_xlim(left=0)
    ax.set_ylim(bottom=0)

    plt.tight_layout()
    plt.savefig(args.output, dpi=150, bbox_inches="tight")
    print(f"Saved {args.output}")

    # Print frontier summary
    print("\nPareto frontier points:")
    if not args.combined:
        for config in configs:
            if config in frontiers:
                print(f"  {config}:")
                for p in frontiers[config]:
                    print(f"    c={p.concurrency}: TPSU={p.tpsu:.0f}, TPSG={p.tpsg:.0f}")
    else:
        for p in combined_frontier:
            print(f"  {p.config} c={p.concurrency}: TPSU={p.tpsu:.0f}, TPSG={p.tpsg:.0f}")

    return 0


if __name__ == "__main__":
    exit(main())
