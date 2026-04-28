# EPLB Benchmark Runbook

Benchmarking sync vs async Expert Parallel Load Balancing (EPLB) on DeepSeek-R1 / GB200 NVL72.

## Configuration Reference

| Env Var | Default | Description |
|---------|---------|-------------|
| `DECODE_EPLB_ENABLED` | `true` | Enable/disable EPLB on decode pods |
| `EPLB_USE_ASYNC` | `false` | Use async EPLB (background thread + CUDA stream overlap) |
| `EPLB_STEP_INTERVAL` | `3000` | Forward steps between rebalances |
| `EPLB_NUM_REDUNDANT_EXPERTS` | `32` | Extra expert slots for replication (trades KV cache memory) |
| `EPLB_WINDOW_SIZE` | `100` | Steps of load history for rebalance algorithm |
| `EPLB_LOG_BALANCEDNESS` | `true` | Enable balancedness logging + expert load dumps (Phase 3E tests overhead of this) |
| `EPLB_LOG_BALANCEDNESS_INTERVAL` | `EPLB_STEP_INTERVAL / 3` | Steps between balancedness log entries (empty = auto from step interval) |
| `EPLB_EXPERT_LOAD_DUMP_DIR` | `/mnt/lustre/<user>/eplb-dumps/<deploy-name>` | Base directory for expert load dumps; pods append `/decode` or `/prefill` |
| `PREFIX_CACHING` | `true` | Explicit APC on/off (`--enable-prefix-caching` / `--no-prefix-caching`) |
| `PREFILL_EPLB_ENABLED` | `false` | Enable EPLB on prefill pods (P/D mode only) |
| `DECODE_LWS_SIZE` | `4` | Decode LWS group size (pods per EP group; GPUs = size * 4) |
| `MODEL` | `nvidia/DeepSeek-R1-0528-NVFP4-v2` | Model to serve |
| `DEPLOY_USER` | from `.env` | Resource name prefix (e.g., `imarkov-eplb-a`) |

All env vars can be set inline or in `.env`. They flow into `gb200/base/decode.yaml` via Kubernetes env vars and `just start` sed substitution.

## Quick Start

```bash
# Prerequisites
just start-monitoring    # Prometheus + Grafana
just prometheus          # Port-forward to localhost:9090

# Deploy with async EPLB in P/D mode
just eplb-bench-async pd
just ready               # Wait for all pods

# Smoke test: short run to verify data collection works
just parallel-guidellm 64 64 128 256 2

# Verify collection pipeline
just eplb-collect smoke-test

# Check outputs exist
ls benchmarks/eplb/smoke-test/
# Expected: config.env, prometheus.json, expert-load/, eplb-logs/
```

## Tracking Progress

```bash
# nyann-bench (benchmark-stairs / benchmark-constant)
just nyann-logs <NAME_PREFIX>-sharegpt-load   # staircase load
just nyann-logs <NAME_PREFIX>-poker-eval      # gsm8k eval

# parallel-guidellm
just guidellm-logs

# Pod readiness
just get-decode-pods
```

## Phase 1: EPLB Mode x Topology (6 runs)

Cross 3 EPLB modes (no / sync / async) with 2 topologies (P/D / agg).

```bash
# --- P/D topology ---
just eplb-bench-no pd    && just ready && just benchmark-stairs
just eplb-collect pd-no-eplb
just eplb-stop

just eplb-bench-sync pd  && just ready && just benchmark-stairs
just eplb-collect pd-sync-eplb
just eplb-stop

just eplb-bench-async pd && just ready && just benchmark-stairs
just eplb-collect pd-async-eplb
just eplb-stop

# --- Agg topology ---
just eplb-bench-no agg    && just ready && just benchmark-stairs
just eplb-collect agg-no-eplb
just eplb-stop

just eplb-bench-sync agg  && just ready && just benchmark-stairs
just eplb-collect agg-sync-eplb
just eplb-stop

just eplb-bench-async agg && just ready && just benchmark-stairs
just eplb-collect agg-async-eplb
just eplb-stop-all              # final run: tear down everything
```

**Parallel execution** (2 runs at once on ~64 GPUs):

```bash
# Terminal 1
DEPLOY_USER=imarkov-eplb-a just eplb-bench-async pd
DEPLOY_USER=imarkov-eplb-a just ready && DEPLOY_USER=imarkov-eplb-a just benchmark-stairs

# Terminal 2
DEPLOY_USER=imarkov-eplb-b just eplb-bench-no agg
DEPLOY_USER=imarkov-eplb-b just ready && DEPLOY_USER=imarkov-eplb-b just benchmark-stairs

# Collect from each (while pods are still running), then tear down everything
DEPLOY_USER=imarkov-eplb-a just eplb-collect pd-async-eplb
DEPLOY_USER=imarkov-eplb-a just eplb-stop-all
DEPLOY_USER=imarkov-eplb-b just eplb-collect agg-no-eplb
DEPLOY_USER=imarkov-eplb-b just eplb-stop-all
```

**Early exit:** if no-EPLB matches or beats sync/async across both topologies, skip Phase 2.

## Phase 2: Parameter Tuning

Use the winning mode + topology from Phase 1. Sweep one parameter at a time.

### 2A. `num_redundant_experts` sweep

```bash
for NRE in 0 16 32 64 128; do
  EPLB_NUM_REDUNDANT_EXPERTS=$NRE just restart pd
  just ready && just benchmark-stairs
  just eplb-collect nre-$NRE
  just stop-nyann
done
```

### 2B. `step_interval` sweep

```bash
for SI in 500 1000 3000 6000; do
  EPLB_STEP_INTERVAL=$SI just restart pd
  just ready && just benchmark-stairs
  just eplb-collect si-$SI
  just stop-nyann
done
```

### 2C. LWS scale sweep

```bash
for SIZE in 2 4 8; do
  DECODE_LWS_SIZE=$SIZE just restart pd
  just ready && just benchmark-stairs
  just eplb-collect lws-$SIZE
  just stop-nyann
done
```

## Phase 3: Ablations

All on the optimal config from Phase 2.

### 3A. Model ablation

```bash
# DeepSeek-V3.2
MODEL=nvidia/DeepSeek-V3.2-NVFP4 just restart pd
just ready && just benchmark-stairs
just eplb-collect model-v3.2-async
just stop-nyann

# Qwen3-235B (adjust num_redundant_experts proportionally)
MODEL=Qwen/Qwen3-235B-A22B EPLB_NUM_REDUNDANT_EXPERTS=16 just restart pd
just ready && just benchmark-stairs
just eplb-collect model-qwen3-async
just stop-nyann
```

### 3B. Dataset ablation

Different task types activate different expert subsets. Run on the optimal config from Phase 2.

```bash
# Coding (code-specialized expert clusters)
just parallel-guidellm 4000 4000 500 1500 4 --data bigcode/starcoderdata
# Wait for job completion, then collect
just eplb-collect dataset-coding

# Math / reasoning (deep CoT, specific expert patterns)
just parallel-guidellm 4000 4000 500 1500 4 --data AI-MO/aimo-validation-aime
just eplb-collect dataset-math

# Multi-turn chat (diverse conversations)
just parallel-guidellm 4000 4000 500 1500 4 --data lmsys/lmsys-chat-1m
just eplb-collect dataset-chat

# Long-context (prefill-heavy, different EPLB dynamics)
just parallel-guidellm 4000 4000 4000 2000 4
just eplb-collect dataset-long-ctx
```

Note: `parallel-guidellm` deletes the previous guidellm job before launching, so no manual cleanup is needed between runs.

### 3C. Prefill EPLB (TTFT impact)

Test whether enabling EPLB on prefill pods improves TTFT in P/D mode:

```bash
PREFILL_EPLB_ENABLED=true just restart pd
just ready && just benchmark-stairs
just eplb-collect prefill-eplb-on
just stop-nyann
```

### 3D. Prefix caching interaction

```bash
PREFIX_CACHING=false just restart pd
just ready && just benchmark-stairs
just eplb-collect apc-off
just stop-nyann
```

### 3E. `log_balancedness` overhead

Compare baseline (on by default for all runs) vs off:

```bash
EPLB_LOG_BALANCEDNESS=false just restart pd
just ready && just benchmark-constant
just eplb-collect log-balanced-off
just stop-nyann
```

## Results

**Collect while pods are still running.** `just eplb-collect` copies Lustre files via the decode pod (or prefill pod as fallback) -- no dev pod required. Prometheus must be port-forwarded (`just prometheus`).

Each `just eplb-collect <name>` creates `benchmarks/eplb/<name>/`:

| File | Contents |
|------|----------|
| `config.env` | All env vars at collection time (committed) |
| `prometheus.json` | Raw Prometheus API snapshots (gitignored) |
| `eplb-logs/` | Decode pod logs from Lustre (gitignored) |
| `expert-load/` | Per-model expert load balance snapshots (gitignored) |

### Run isolation

- **Parallel runs**: The dump dir includes `DEPLOY_NAME` (e.g., `.../eplb-dumps/imarkov-eplb-a-wide-ep/`), so parallel deployments with different `DEPLOY_USER` values write to separate directories.
- **Re-runs**: Each pod startup creates a timestamped subdirectory (e.g., `.../20260423-143052/`), so re-runs never overwrite previous dumps. `eplb-collect` picks the latest one.

### Expert load dumps

When `EPLB_LOG_BALANCEDNESS=true` and `EPLB_EXPERT_LOAD_DUMP_DIR` is set (default: on Lustre), rank 0 writes a JSON file per model at every rebalance step containing:

- `window_expert_load` -- load history over the sliding window (shape: `[num_moe_layers, num_physical_experts]`)
- `latest_expert_load` -- load from the most recent step
- `physical_to_logical_map` -- current expert placement after rebalancing
- Model metadata: `world_size`, `num_moe_layers`, `num_physical_experts`, `num_logical_experts`, `num_redundant_experts`, `window_size`

Balancedness metrics are computed in post-processing from the raw load tensors. Requires `EPLB_LOG_BALANCEDNESS=true` for the run.

```python
import json, numpy as np

with open("benchmarks/eplb/pd-async-eplb/expert-load/nvidia_DeepSeek-R1-0528-NVFP4-v2_expert_load.json") as f:
    data = json.load(f)

for snap in data["snapshots"]:
    load = np.array(snap["window_expert_load"])  # [layers, experts]
    balance = (load.min(axis=1) / load.max(axis=1)).mean()
    print(f"step {snap['step']}: balancedness={balance:.4f}  shape={load.shape}")
```

Prometheus metrics:

```python
with open("benchmarks/eplb/pd-async-eplb/prometheus.json") as f:
    data = json.load(f)
```

## Analysis

### Jupyter Notebook

`eplb_benchmark_analysis.ipynb` provides interactive visualizations for comparing runs. Open it from the `benchmarks/eplb/` directory:

```bash
cd benchmarks/eplb
jupyter notebook eplb_benchmark_analysis.ipynb
```

The notebook covers:
1. **Metrics overview** -- summary table of Prometheus latency/throughput across runs
2. **Latency comparison** -- TTFT and ITL bar charts + time series
3. **Throughput comparison** -- output/prompt token rate bar charts + time series
4. **KV cache usage** -- memory pressure from `num_redundant_experts`
5. **Expert load balancedness** -- cross-run comparison + per-run deep dives (heatmaps, rank balance, popularity)
6. **Parameter sweep analysis** -- ready-made cells for Phase 2 `nre-*`, `si-*`, `lws-*` sweeps

### Python Module

`eplb_analysis.py` contains all reusable utilities (importable from scripts or notebooks):

```python
from eplb_analysis import load_run, load_all_runs, metrics_comparison_table

# Load a single run
run = load_run("pd-async-eplb")
print(run.config)                           # RunConfig with parsed env vars
print(run.prometheus.instant("ttft_p99"))    # scalar metric value
print(run.expert_loads)                      # dict of ExpertLoadData objects

# Load all runs and compare
runs = load_all_runs()
df = metrics_comparison_table(runs)          # DataFrame of key metrics
```

Key classes:
- `RunData` -- all data for a single run (config + prometheus + expert loads)
- `RunConfig` -- parsed `config.env` with properties like `.eplb_mode`, `.num_redundant`
- `PrometheusData` -- accessor for instant and range query results
- `ExpertLoadData` -- parsed expert load dump with `snapshot()` and `balancedness_series()`

Key functions:
- `load_run(name)` / `load_all_runs()` / `list_runs()` -- data loading
- `metrics_comparison_table(runs)` / `balancedness_comparison_table(runs)` -- DataFrames
- `plot_latency_comparison()` / `plot_throughput_comparison()` -- cross-run bar charts
- `plot_throughput_timeseries()` / `plot_latency_timeseries()` -- range query overlays
- `plot_balancedness_comparison()` / `plot_kv_cache_usage()` -- specialized comparisons
- `plot_expert_load_heatmap()` / `plot_rank_balance()` / `plot_expert_popularity()` -- per-run expert analysis

### Dependencies

```bash
pip install numpy pandas matplotlib jupyter
```
