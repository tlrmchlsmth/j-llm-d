# NIXL PCIe Investigation: Cross-IIO Throughput Gap in Disaggregated Inference

This directory contains all scripts, configurations, and results for the blog
post [*Why NIXL KV Transfers Are Slow: A PCIe Deep Dive*](./nixl-pcie-investigation-blog.md),
which investigates why NIXL KV cache transfers achieve only ~27 Gbps per NIC
vs ~148 Gbps for `ib_read_bw` with identical 16 KB messages in the same
cross-IIO GPU-NIC topology -- and how removing two confounding factors on the
decode pod recovers the full wireline ceiling (~251 Gbps).

## Directory Structure

```
glm-disagg-pcie/
├── nixl-iio-investigation/              ← this directory
│   ├── README.md                        ← you are here
│   ├── nixl-pcie-investigation-blog.md  ← the blog post
│   ├── configs/
│   │   ├── ib_read_bw/                  ← multi_nic_ib_write_bw.py JSON configs
│   │   │   ├── vf-same-iio-gpu-2MB.json
│   │   │   ├── vf-cross-iio-gpu-2MB.json
│   │   │   ├── vf-cross-iio-gpu-16KB.json
│   │   │   ├── vf-cross-socket-1rail-gpu-2MB.json
│   │   │   ├── vf-cross-socket-2rail-gpu-2MB.json
│   │   │   └── vf-8gpu-cross-iio-gpu-2MB.json
│   │   ├── iio_discovery_all8_write_2MB.json
│   │   └── iio_discovery_scenario2_write_2MB.json
│   ├── scripts/
│   │   ├── profile_nic_throughput.sh    ← NIC counter profiling during NIXL e2e
│   │   ├── run_isolation_experiments.sh ← master orchestrator for nixl-s1..s6
│   │   ├── run_multi_scatter_bench.sh   ← 4-instance scatter_bench (TP=2, rails=2)
│   │   ├── run_ib_read_bw_with_iio.sh  ← ib_read_bw + IIO perf stat
│   │   ├── run_e2e_with_iio.sh          ← NIXL benchmark + IIO perf stat
│   │   ├── sweep_mc_with_iio.sh         ← MC sweep with IIO perf stat
│   │   ├── analyze_nic_counters.py      ← NIC counter burst analysis
│   │   ├── analyze_nic_burst_detail.py  ← time-series burst detail
│   │   ├── analyze_e2e_iio.py           ← IIO perf stat analysis
│   │   ├── poll_nic_counters.cpp        ← high-frequency NIC byte counter poller
│   │   ├── rdma_scatter_bench.cpp       ← custom RDMA READ scatter benchmark
│   │   ├── check_vf_mrrs.sh            ← VF MRRS investigation
│   │   └── measure_ioclk.sh            ← IIO clock frequency measurement
│   └── results/                         ← collected experiment data
│       ├── ib_read_bw/                  ← wireline ib_read_bw results (JSON)
│       ├── e2e_s2r2_isl4096/            ← NIXL + IIO perf stat
│       ├── e2e_s2r2_isl8192/
│       ├── phase1_nic_profile_isl4096/
│       ├── phase1_nic_profile_isl4096_vf/
│       ├── ucx_max_rd_atomic_test/
│       ├── ioclk_measurement.md
│       └── perf-iio-*, pcm-iio-*
├── iio-investigation/                   ← standalone IIO root-cause analysis
│   ├── README.md                        ← detailed IIO experiment documentation
│   ├── configs/                         ← read/write 2MB/16KB JSON configs
│   └── scripts/                         ← config.sh, capture/run/experiment
├── wireline-cross-iio/
│   └── run_wireline_cross_iio.sh        ← cross-IIO wireline sweep (exp1a-2b)
├── results/
│   ├── nixl_isolation/                  ← nixl-s1..s9 per-scenario results
│   ├── wireline-cross-iio/             ← ib_read_bw sweep results + NIC TSVs
│   ├── wireline-cross-iio-both-sides/  ← pull vs push results + run script
│   └── processed_data/                 ← CSV generation and correction scripts
├── switch_scenario.sh                   ← switch NIXL NIC scenario (s1..s9)
├── single_query_with_nic_counters.sh    ← quick NIC verification (warm/cold TTFT)
├── sweep_mc.sh                          ← concurrency sweep
├── sweep_isl.sh                         ← input sequence length sweep
├── sweep_mc_with_nic_counters.sh        ← concurrency sweep + NIC snapshots
└── run_all_mc_sweeps.sh                 ← multi-scenario sweep orchestrator
```

## Prerequisites

### Hardware

- Intel Xeon Platinum 8480+ (Sapphire Rapids), 2 sockets
- AMD Instinct MI300X GPUs (8 per node, PCIe Gen5 x16)
- NVIDIA ConnectX-7 NICs (400G RoCEv2, SR-IOV VFs, 8 per node)
- Cross-IIO topology: GPU and NIC on different PCIe root ports
- IOMMU passthrough (`iommu=pt` in kernel cmdline)

### Software

- Kubernetes cluster with GPU (NVIDIA device plugin) and RDMA (SR-IOV device plugin)
- `networking-debug-pod-<node-ip>` pods with `ib_read_bw`, `ib_write_bw`, GPU support
- SSH access to bare-metal nodes (for `perf stat`, `pcm`, `setpci`, static compilation)
- [`multi_nic_ib_write_bw.py`](../../networking-debug-container/inter_node_tests/multi_nic_ib_write_bw/multi_nic_ib_write_bw.py) - orchestrator for parallel perftest runs
- `uv` (for running multi_nic_ib_write_bw.py)
- [Intel PCM](https://github.com/intel/pcm) (`pcm`, `pcm-iio`) for IIO counters
- `perf` with uncore IIO PMU support (kernel 5.10+)
- `g++` on bare-metal nodes (for compiling `poll_nic_counters.cpp` and `rdma_scatter_bench.cpp`)
- Python 3.8+ with standard library (no extra packages needed for analysis scripts)

### Pod Deployments

Two types of pods are used:

1. **vLLM model server pods** (`ms-glm-disagg-llm-d-modelservice-{decode,prefill}`):
   TP=2 decode and prefill pods running vLLM with NIXL/UCX for KV cache transfer.
   Deployed via Helm in the `glm-disagg-pcie/ms/` chart.

2. **Networking debug pods** (`networking-debug-pod-<node-ip>`):
   Privileged pods with perftest tools (`ib_read_bw`, `ib_write_bw`), GPU access,
   and RDMA libraries. Used for wireline benchmarks and `rdma_scatter_bench`.
   Deployed via [`deploy_test_nic_pcie.sh`](../../networking-debug-container/deploy_test_nic_pcie.sh).

### GPU-NIC Topology Reference

```
+--------+-----------------+-----------------------------+------------+
| GPU ID | GPU PCI Address | Nearest HCA PCI Addr (dist) | HCA Device |
+--------+-----------------+-----------------------------+------------+
| GPU 0  | 11:00.0         | 0c:00.1 (10)                | mlx5_10    |
| GPU 1  | 2f:00.0         | 2a:00.1 (10)                | mlx5_11    |
| GPU 2  | 46:00.0         | 41:00.1 (10)                | mlx5_12    |
| GPU 3  | 5d:00.0         | 58:00.1 (10)                | mlx5_13    |
| GPU 4  | 8b:00.0         | 86:00.1 (10)                | mlx5_14    |
| GPU 5  | aa:00.0         | a5:00.1 (10)                | mlx5_15    |
| GPU 6  | c2:00.0         | bd:00.1 (10)                | mlx5_16    |
| GPU 7  | da:00.0         | d5:00.1 (10)                | mlx5_17    |
+--------+-----------------+-----------------------------+------------+
```

Each GPU shares an IIO stack with its nearest NIC (same-IIO). Using any other
NIC with that GPU requires crossing the CPU mesh (cross-IIO).

---

## Experiment Guide

Experiments are listed in the order they appear in the blog post. Each section
lists the blog section it corresponds to, the script(s) to run, and expected
output.

### Experiment 1: ib_read_bw Throughput Table (Blog Sections 4-5)

Measures raw RDMA READ wireline throughput for each GPU-NIC placement scenario
using contiguous GPU memory buffers.

**Script**: Direct invocation of `multi_nic_ib_write_bw.py` with pre-built
JSON configs.

```bash
cd /path/to/networking-debug-container/inter_node_tests/multi_nic_ib_write_bw

# Same-IIO baseline (2MB): ~359 Gbps/NIC
uv run python3 ./multi_nic_ib_write_bw.py \
    --config /path/to/nixl-iio-investigation/configs/ib_read_bw/vf-same-iio-gpu-2MB.json

# Cross-IIO 2MB: ~254 Gbps/NIC
uv run python3 ./multi_nic_ib_write_bw.py \
    --config /path/to/nixl-iio-investigation/configs/ib_read_bw/vf-cross-iio-gpu-2MB.json

# Cross-IIO 16KB: ~148 Gbps/NIC
uv run python3 ./multi_nic_ib_write_bw.py \
    --config /path/to/nixl-iio-investigation/configs/ib_read_bw/vf-cross-iio-gpu-16KB.json

# Cross-socket 1-rail (shared NIC): ~123 Gbps total
uv run python3 ./multi_nic_ib_write_bw.py \
    --config /path/to/nixl-iio-investigation/configs/ib_read_bw/vf-cross-socket-1rail-gpu-2MB.json

# Cross-socket 2-rail (2 NICs): ~124 Gbps total
uv run python3 ./multi_nic_ib_write_bw.py \
    --config /path/to/nixl-iio-investigation/configs/ib_read_bw/vf-cross-socket-2rail-gpu-2MB.json
```

**Expected results**: JSON output with `summary.per_nic_avg_bw_gbps` matching
the values in the blog's throughput table.

**Results location**: `results/ib_read_bw/`

---

### Experiment 2: Cross-IIO Wireline Sweep (Blog Section 6)

Sweeps `ib_read_bw` across QP counts (1-16) and message sizes (2MB, 16KB) for
four experiment configurations (exp1a, exp1b, exp2a, exp2b) that isolate
prefill-side vs decode-side cross-IIO bottlenecks.

**Script**: `wireline-cross-iio/run_wireline_cross_iio.sh`

```bash
cd glm-disagg-pcie/wireline-cross-iio

# Run full sweep (all 4 experiments × 2 sizes × 5 QP counts = 40 runs)
./run_wireline_cross_iio.sh ../results/wireline-cross-iio

# Override defaults:
# MULTI_NIC_SCRIPT=/path/to/multi_nic_ib_write_bw.py
# NAMESPACE=my-namespace
```

**What it does**:
1. Discovers decode/prefill vLLM pods and their node IPs
2. Locates networking-debug pods on the same nodes
3. Deploys `poll_nic_counters` binary into the decode debug pod
4. For each (experiment, message_size, num_qps) combination:
   - Generates a JSON config pairing the correct GPUs and NICs
   - Starts NIC counter pollers on decode-side NICs
   - Runs `ib_read_bw` via `multi_nic_ib_write_bw.py`
   - Stops pollers and collects NIC counter traces
5. Prints a summary table

**Output**: Per-run JSON results and NIC TSV traces in the output directory.

**Results location**: `results/wireline-cross-iio/`

---

### Experiment 3: Pull vs Push Comparison (Blog Section 6)

Compares RDMA READ (pull/non-posted) vs RDMA WRITE (push/posted) throughput
at cross-IIO with QP sweep, using both nodes' cross-IIO GPU-NIC pairs.

**Script**: `results/wireline-cross-iio-both-sides/run_pull_vs_push.sh`

```bash
cd glm-disagg-pcie/results/wireline-cross-iio-both-sides
./run_pull_vs_push.sh
```

**What it does**:
1. Generates JSON configs for pull (read) and push (write) at 2MB and 16KB
2. Sweeps QP counts 1-16 for each
3. Saves JSON results

**Results location**: `results/wireline-cross-iio-both-sides/`

---

### Experiment 4: IIO Counter Profiling (Blog Sections 7-8)

Runs NIXL e2e benchmarks while capturing Intel IIO PMU counters (`COMP_BUF_OCCUPANCY`,
`COMP_BUF_INSERTS`, etc.) via `perf stat` on bare-metal nodes.

**Scripts**:
- `scripts/run_e2e_with_iio.sh` — single run at a given ISL
- `scripts/sweep_mc_with_iio.sh` — sweep MC values with IIO capture

```bash
cd nixl-iio-investigation/scripts

# Single run: ISL=4096, MC=1
./run_e2e_with_iio.sh 4096 ../results/e2e_s2r2_isl4096

# Single run: ISL=8192, MC=1
./run_e2e_with_iio.sh 8192 ../results/e2e_s2r2_isl8192 1 30

# MC sweep with IIO (default MC=1,2,4,8,16)
./sweep_mc_with_iio.sh ../results/mc_sweep_iio

# Custom MC sweep
./sweep_mc_with_iio.sh ../results/mc_sweep_isl8192 8192 30 256 1 2 4 8
```

**What `run_e2e_with_iio.sh` does**:
1. Discovers prefill/decode pods and resolves host node IPs
2. Starts `perf stat` on both nodes (via SSH + tmux) monitoring IIO events
3. Runs the NIXL benchmark via `sweep_concurrency_with_kv_transfer_logs.sh`
4. Collects perf stat output from both nodes

**Analysis**:
```bash
python3 scripts/analyze_e2e_iio.py
```

**Results location**: `results/e2e_s2r2_isl4096/`, `results/e2e_s2r2_isl8192/`

---

### Experiment 5: Wire-Level NIC Counter Profiling (Blog Section 12)

Profiles NIC byte counters at ~100µs polling intervals during NIXL transfers
to measure per-transfer wire-level throughput, WR rate, and burst duration.

**Scripts**:
- `scripts/poll_nic_counters.cpp` — C++ high-frequency counter poller
- `scripts/profile_nic_throughput.sh` — orchestrates polling during NIXL e2e
- `scripts/analyze_nic_counters.py` — burst detection and rate computation

```bash
cd nixl-iio-investigation

# Full automated flow (compile poller → start → run NIXL → stop → analyze):
./scripts/profile_nic_throughput.sh nixl results/nic_profile_test 50 4096 256

# Manual poller use (inside a pod):
g++ -O2 -o poll_nic_counters scripts/poll_nic_counters.cpp
./poll_nic_counters mlx5_12 /tmp/nic_mlx5_12.tsv 0  # 0 = no sleep (max fidelity)
# ... run benchmark, then Ctrl-C the poller ...

# Analyze collected traces:
python3 scripts/analyze_nic_counters.py results/nic_profile_test
```

**What `profile_nic_throughput.sh` does**:
1. Discovers decode/prefill pods and their nodes
2. Auto-discovers active NICs from `UCX_NET_DEVICES` on each pod
3. Compiles `poll_nic_counters.cpp` as a static binary on the bare-metal node
4. Copies binary into both vLLM pods
5. Starts pollers on all active NICs (both pods)
6. Runs the NIXL e2e benchmark
7. Stops pollers, collects TSV traces
8. Runs `analyze_nic_counters.py` for burst analysis

**Results location**: `results/nixl_isolation/<scenario>/nic_*.tsv`

---

### Experiment 6: Custom RDMA Scatter Benchmark (Blog Section 10)

Tests whether scattered GPU memory access (as done by NIXL) is the throughput
bottleneck, by issuing the same 40,960 scattered 16KB RDMA READs using raw
`libibverbs` with a tight post/poll loop.

**Scripts**:
- `scripts/rdma_scatter_bench.cpp` — custom RDMA benchmark (HIP + libibverbs)
- `scripts/run_multi_scatter_bench.sh` — 4-instance run mimicking TP=2, rails=2

**Build** (inside a networking-debug pod with ROCm and libibverbs):
```bash
hipcc -O2 -o rdma_scatter_bench scripts/rdma_scatter_bench.cpp \
    -libverbs -lrdmacm -lpthread
```

**Single instance**:
```bash
# Server (prefill pod):
./rdma_scatter_bench server \
    --dev mlx5_3 --gid-index 3 --gpu 0 \
    --pool-gb 2 --num-blocks 20480 --block-size 16384 \
    --mode scattered --transfers 10

# Client (decode pod):
./rdma_scatter_bench client \
    --server-ip <prefill-pod-ip> --dev mlx5_3 --gid-index 3 --gpu 0 \
    --pool-gb 2 --num-blocks 20480 --block-size 16384 \
    --mode scattered --transfers 10 \
    --sq-depth 8192 --signal-every 512 --max-rd-atomic 16
```

**Multi-instance** (4 concurrent flows matching NIXL topology):
```bash
cd nixl-iio-investigation/scripts

./run_multi_scatter_bench.sh \
    networking-debug-pod-10.0.69.254 \
    networking-debug-pod-10.0.73.254 \
    ../results/scatter_multi

# With rerandomized offsets per transfer:
RERANDOMIZE=1 ./run_multi_scatter_bench.sh \
    networking-debug-pod-10.0.69.254 \
    networking-debug-pod-10.0.73.254 \
    ../results/scatter_multi_rerand
```

**What `run_multi_scatter_bench.sh` does**:
1. Starts 4 scatter_bench servers on the prefill pod (2 GPUs × 2 NICs)
2. Starts NIC counter pollers on the decode pod
3. Starts 4 barrier-gated clients on the decode pod
4. Releases all clients simultaneously
5. Waits for completion, stops pollers, collects results
6. Runs NIC counter analysis

**Results location**: Output directory specified on command line

---

### Experiment 7: NIXL Scenario Isolation (Blog Section 13)

The core investigation: switching between NIC/GPU/rails configurations to
isolate the two confounding factors (cross-IIO latency and UCX rails splitting)
that cripple NIXL throughput on the decode pod.

#### Scenario Definitions

| Scenario | Decode GPUs | Decode NICs | Decode IIO | Rails | Prefill GPUs | Prefill NICs | Prefill IIO |
|----------|-------------|-------------|------------|-------|--------------|--------------|-------------|
| **nixl-s6** (baseline) | 0, 1 | mlx5_12, mlx5_13 | Cross | 2 | 0, 1 | mlx5_12, mlx5_13 | Cross |
| **nixl-s7** | 0, 1 | mlx5_10, mlx5_11 | Same | 2 | 0, 1 | mlx5_12, mlx5_13 | Cross |
| **nixl-s8** | 0, 7 | mlx5_11, mlx5_16 | Cross | 1 | 0, 7 | mlx5_11, mlx5_16 | Cross |
| **nixl-s9** | 0, 1 | mlx5_10, mlx5_11 | Same | 1 | 0, 7 | mlx5_11, mlx5_16 | Cross |

#### Running Individual Scenarios

**Step 1: Switch scenario** (triggers pod rollout):
```bash
cd glm-disagg-pcie

# Switch to a specific scenario
./switch_scenario.sh nixl-s6   # baseline: cross-IIO, rails=2
./switch_scenario.sh nixl-s7   # decode same-IIO, rails=2
./switch_scenario.sh nixl-s8   # cross-IIO, rails=1, CUDA_VIS=0,7
./switch_scenario.sh nixl-s9   # decode same-IIO + rails=1, prefill cross-IIO + rails=1
```

The script:
1. Patches deployment strategy to `Recreate`
2. Sets `UCX_NET_DEVICES`, `UCX_MAX_RMA_RAILS`, and optionally `CUDA_VISIBLE_DEVICES` per pod
3. Waits for rollout completion
4. Verifies pods landed on correct nodes and prints UCX env

**Step 2: Verify NIC assignment** (warm up + check which NICs are active):
```bash
# Args: <max_concurrent> [num_prompts] [ISL] [OSL]
# First run is warmup:
NET_DEBUG_NS=raj-network-debug ./single_query_with_nic_counters.sh 1 1 4096 256

# Second run shows actual NIC activity:
NET_DEBUG_NS=raj-network-debug ./single_query_with_nic_counters.sh 1 1 4096 256
```

Check the output for non-zero byte deltas on the expected NICs.

**Step 3: Run NIC-profiled e2e benchmark**:
```bash
cd nixl-iio-investigation

./scripts/profile_nic_throughput.sh nixl \
    ../results/nixl_isolation/nixl-s7 50 4096 256
```

#### Running Scenarios via Orchestrator

```bash
cd nixl-iio-investigation/scripts

# Run all early experiments s1-s6 (handles TP=1 and TP=2 deploys):
./run_isolation_experiments.sh all

# Run only TP=1 group (s1, s2, s5):
./run_isolation_experiments.sh tp1

# Run only TP=2 group (s3, s4, s6):
./run_isolation_experiments.sh tp2

# Run confounding-factor experiments (s6-s9, the blog's Section 13):
./run_isolation_experiments.sh confound

# Run a single experiment (s1 through s9):
./run_isolation_experiments.sh nixl-s7
```

**What it does** for each scenario:
1. Deploys the correct TP configuration (TP=1 or TP=2) if needed
2. Calls `switch_scenario.sh` to set UCX env vars
3. Waits for pods to stabilize
4. Runs `profile_nic_throughput.sh` (NIC counter profiling + NIXL benchmark)
5. Extracts and tabulates results

**Results location**: `results/nixl_isolation/nixl-s{1..9}/`

Each scenario directory contains:
- `result_mc1.txt` — benchmark summary with NIXL KV transfer metrics
- `metrics_mc1.txt` — vLLM metrics endpoint dump
- `decode_mc1.log`, `prefill_mc1.log` — vLLM inference logs
- `nic_decode_mlx5_*.tsv` — per-NIC byte counter traces (decode)
- `nic_prefill_mlx5_*.tsv` — per-NIC byte counter traces (prefill)

---

### Experiment 8: IIO Clock and VF MRRS (Blog Section 9)

#### IIO Clock Frequency

```bash
cd nixl-iio-investigation/scripts
./measure_ioclk.sh
```

Key finding: IIO programmable events use the uncore/mesh clock (~2.4 GHz under
load), NOT the `ioclk` free-running counter (~45 MHz reference).

#### VF MRRS Investigation

```bash
cd nixl-iio-investigation/scripts
./check_vf_mrrs.sh
```

Key finding: VF DevCtl is virtualized by ConnectX-7 firmware; MRRS cannot be
changed at runtime. VF MRRS locked at 128B.

---

### Experiment 9: Cross-IIO Root-Cause IIO Analysis (iio-investigation/)

A standalone investigation using `perf stat` IIO counters to prove that the
cross-IIO throughput degradation is caused by the non-posted PCIe completion
round-trip, not buffer saturation or CHA mesh congestion.

```bash
cd glm-disagg-pcie/iio-investigation

# Review and edit node-specific configuration
vim scripts/config.sh

# Run all experiments (~15 minutes):
./scripts/run_experiment.sh
```

See [iio-investigation/README.md](../iio-investigation/README.md) for full
documentation of this experiment set.

---

## Analysis Scripts

| Script | Input | Output | Description |
|--------|-------|--------|-------------|
| `scripts/analyze_nic_counters.py` | Directory of `*.tsv` files | Per-NIC burst stats: duration, throughput, WR rate | Detects transfer bursts in NIC counter data and computes steady-state rates |
| `scripts/analyze_nic_burst_detail.py` | Single `*.tsv` file | Per-sample time series with ramp-up, steady-state, tail-off phases | Microsecond-resolution burst phase analysis |
| `scripts/analyze_e2e_iio.py` | `e2e_*` result directories | IIO duty-cycle-corrected rates, comparison with ib_read_bw baselines | Parses perf stat + benchmark metrics for IIO analysis |

Usage:
```bash
# Analyze NIC counter traces for a scenario:
python3 scripts/analyze_nic_counters.py ../results/nixl_isolation/nixl-s9

# Detailed burst analysis (takes a single TSV file, not a directory):
python3 scripts/analyze_nic_burst_detail.py ../results/nixl_isolation/nixl-s9/nic_decode_mlx5_11.tsv

# IIO perf stat analysis:
python3 scripts/analyze_e2e_iio.py
```

---

## Key Results Summary

### Wireline Throughput (ib_read_bw)

| Topology | 2 MB (Gbps/NIC) | 16 KB (Gbps/NIC) |
|----------|-----------------|-------------------|
| Same-IIO | 359 | — |
| Cross-IIO | 254 | 148 |
| Cross-socket (1 NIC) | 123 | — |
| Cross-socket (2 NICs) | 124 | — |

### NIXL Scenario Isolation

| Scenario | Factor(s) Removed | Per-Rank Gbps | Per-NIC WR/s | Per-NIC RX Gbps |
|----------|-------------------|---------------|--------------|-----------------|
| nixl-s6 (baseline) | None | 27.2 | 208K | 28 |
| nixl-s7 | Cross-IIO on decode | 202.9 | 1.42M | 187 |
| nixl-s8 | Rails splitting | 246.7 | 1.84M | 242 |
| nixl-s9 | Both | 260.3 | 1.90M | 251 |

---

## Root Cause

The 9.6x gap between baseline NIXL (27 Gbps) and best-case nixl-s9 (260 Gbps)
is caused by two **confounding factors** on the decode pod that compound when
both are present:

1. **UCX multi-rail splitting** (rails=2): Each GPU rank splits descriptors
   across 2 NICs via UCX's multi-rail arbiter, adding per-descriptor overhead.
   Removing this alone (nixl-s8) recovers 96% of the wireline ceiling.

2. **Cross-IIO completion latency**: GPU-NIC pairs on different IIO stacks
   incur additional mesh-crossing latency for completions. Removing this alone
   (nixl-s7) recovers 80% of the wireline ceiling.

Either factor causes moderate degradation; together they are crippling.
nixl-s9 (both removed) saturates the wireline ceiling at ~251 Gbps per NIC.
