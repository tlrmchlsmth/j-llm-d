# NIXL PCIe Investigation: Cross-IIO Throughput Gap in Disaggregated Inference

This directory contains all scripts, configurations, and results for the blog
post investigating why NIXL KV cache transfers achieve only ~27 Gbps per NIC
vs ~148 Gbps for `ib_read_bw` with identical 16KB messages in the same
cross-IIO GPU-NIC topology.

## Directory Structure

```
nixl-iio-investigation/
├── README.md                          ← this file
├── nixl-pcie-investigation-blog.md    ← the blog post
├── configs/
│   ├── ib_read_bw/                    ← multi_nic_ib_write_bw.py JSON configs
│   │   ├── vf-same-iio-gpu-2MB.json           Same-IIO baseline (VF)
│   │   ├── vf-cross-iio-gpu-2MB.json          Cross-IIO 2MB (VF)
│   │   ├── vf-cross-iio-gpu-16KB.json         Cross-IIO 16KB (VF)
│   │   ├── vf-cross-socket-1rail-gpu-2MB.json  Cross-socket shared NIC (VF)
│   │   ├── vf-cross-socket-2rail-gpu-2MB.json  Cross-socket 2 NICs (VF)
│   │   └── vf-8gpu-cross-iio-gpu-2MB.json     8-GPU cross-IIO (for ioclk)
│   ├── iio_discovery_all8_write_2MB.json       IIO stack mapping (8 pairs)
│   └── iio_discovery_scenario2_write_2MB.json  Cross-IIO stack mapping
├── scripts/
│   ├── run_e2e_with_iio.sh            ← single NIXL benchmark run + perf stat
│   ├── sweep_mc_with_iio.sh           ← sweep MC values, each with perf stat
│   ├── run_ib_read_bw_with_iio.sh     ← ib_read_bw test + perf stat
│   ├── analyze_e2e_iio.py             ← parses perf stat + metrics for IIO analysis
│   ├── analyze_nic_counters.py        ← wire-level NIC counter burst analysis
│   ├── poll_nic_counters.cpp          ← high-frequency NIC byte counter poller
│   ├── measure_ioclk.sh               ← ioclk/uncore frequency measurement
│   └── check_vf_mrrs.sh               ← VF MRRS investigation commands
└── results/
    ├── ioclk_measurement.md           ← ioclk frequency findings & raw data
    ├── ib_read_bw/                    ← ib_read_bw test results (JSON)
    │   ├── vf-same-iio-gpu-2MB.json           359 Gbps/NIC
    │   ├── vf-cross-iio-gpu-2MB.json          254 Gbps/NIC
    │   ├── vf-cross-iio-gpu-16KB.json         148 Gbps/NIC
    │   ├── vf-cross-socket-1rail-gpu-2MB.json  123 Gbps (2 GPUs sharing 1 NIC)
    │   └── vf-cross-socket-2rail-gpu-2MB.json  124 Gbps (2 GPUs on 2 NICs)
    ├── e2e_s2r2_isl4096/              ← NIXL ISL=4096 + IIO perf stat
    │   ├── perf_decode_isl4096.txt
    │   ├── perf_prefill_isl4096.txt
    │   ├── metrics_mc1.txt
    │   ├── decode_mc1.log
    │   ├── prefill_mc1.log
    │   └── result_mc1.txt
    ├── e2e_s2r2_isl8192/              ← NIXL ISL=8192 + IIO perf stat
    ├── phase1_nic_profile_isl4096/    ← PF NIC counter profiles
    ├── phase1_nic_profile_isl4096_vf/ ← VF NIC counter profiles
    ├── pcm-iio-*.csv                  ← pcm-iio CSV dumps
    └── perf-iio-*.txt                 ← raw perf stat outputs
```

## Prerequisites

### Hardware
- Intel Xeon Platinum 8480+ (Sapphire Rapids), 2 sockets
- AMD Instinct MI300X GPUs (4-8 per pod)
- NVIDIA ConnectX-7 NICs (400G RoCEv2, SR-IOV VFs)
- Cross-IIO topology: GPU and NIC on different PCIe root ports

### Software
- Kubernetes cluster with GPU and RDMA SR-IOV device plugins
- `perftools-rdma` pods or equivalent with `ib_read_bw` and GPU support
- SSH access to bare-metal nodes (for `perf stat`, `pcm`, `setpci`)
- [`multi_nic_ib_write_bw.py`](../../../networking-debug-container/inter_node_tests/multi_nic_ib_write_bw/multi_nic_ib_write_bw.py) - orchestrator for parallel ib_read_bw tests
- [Intel PCM](https://github.com/intel/pcm) (`pcm`, `pcm-iio`) for IIO counters and uncore frequency
- `perf` with uncore IIO PMU support (kernel 5.10+)

### Pod Deployments

Two types of test pods are used:

1. **4-GPU pods** (`test-nic-pcie-<node-ip>`): 4 GPUs + 4 VF NICs, single socket.
   Used for same-IIO and cross-IIO benchmarks.

2. **8-GPU pods** (`test-nic-pcie-8gpu-<node-ip>`): 8 GPUs + 8 VF NICs, both sockets.
   Used for cross-socket benchmarks and ioclk calibration.

Pod manifests: [`test-nic-pcie.yaml`](../../../networking-debug-container/test-nic-pcie.yaml),
[`test-nic-pcie-8gpu.yaml`](../../../networking-debug-container/test-nic-pcie-8gpu.yaml)

Deploy with: [`deploy_test_nic_pcie.sh`](../../../networking-debug-container/deploy_test_nic_pcie.sh)

## Reproducing the Experiments

### Experiment 1: ib_read_bw Throughput Table (Section 4 of blog)

These experiments measure raw RDMA READ throughput for each GPU-NIC placement
scenario using contiguous GPU memory buffers.

**Option A: ib_read_bw only** (using `multi_nic_ib_write_bw.py` directly):

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

**Option B: ib_read_bw + IIO perf stat** (combined measurement):

```bash
cd nixl-iio-investigation/scripts

# Cross-IIO 2MB with IIO counters
./run_ib_read_bw_with_iio.sh \
    ../configs/ib_read_bw/vf-cross-iio-gpu-2MB.json \
    ../results/ib_read_bw_iio

# Cross-IIO 16KB with IIO counters
./run_ib_read_bw_with_iio.sh \
    ../configs/ib_read_bw/vf-cross-iio-gpu-16KB.json \
    ../results/ib_read_bw_iio
```

This starts `perf stat` monitoring IIO events on the source node via SSH,
runs the `ib_read_bw` test, then collects both the bandwidth results and
the perf stat output. Override `IIO_UNITS` env var to target specific stacks.

### Experiment 2: IIO Counter Profiling During NIXL Transfers (Sections 7-8)

**Single run** at a specific (MC, ISL) pair:

```bash
cd nixl-iio-investigation/scripts

# ISL=4096, MC=1 (40,960 descriptors per transfer)
./run_e2e_with_iio.sh 4096 ../results/e2e_s2r2_isl4096

# ISL=8192, MC=1 (81,920 descriptors per transfer)
./run_e2e_with_iio.sh 8192 ../results/e2e_s2r2_isl8192 1 30

# ISL=4096, MC=4
./run_e2e_with_iio.sh 4096 ../results/e2e_s2r2_isl4096_mc4 4 50
```

**MC sweep with IIO** (sweep multiple concurrency levels, each with perf stat):

```bash
cd nixl-iio-investigation/scripts

# Sweep MC=1,2,4,8,16 at ISL=4096 (default)
./sweep_mc_with_iio.sh ../results/mc_sweep_iio

# Custom MC values and ISL
./sweep_mc_with_iio.sh ../results/mc_sweep_isl8192 8192 30 256 1 2 4 8
```

`run_e2e_with_iio.sh`:
1. Discovers prefill/decode pods and resolves their host node IPs
2. Starts `perf stat` on both nodes (SSH + tmux) monitoring IIO events
3. Runs the NIXL benchmark via `sweep_concurrency_with_kv_transfer_logs.sh`
4. Waits for perf stat to finish, then collects output via `scp`

`sweep_mc_with_iio.sh` wraps the above in a loop, with skip-if-exists
and cooldown between runs.

Analyze results:
```bash
python3 scripts/analyze_e2e_iio.py
```

### Experiment 3: NIC Counter Wire-Level Profiling (Phase 1)

Profile NIC byte counters at 100us polling intervals to measure per-transfer
wire-level throughput and duration:

```bash
# Compile the poller (inside a pod with RDMA access)
g++ -O2 -o poll_nic_counters scripts/poll_nic_counters.cpp

# Start polling on decode node (2 NICs)
./poll_nic_counters mlx5_12 /tmp/nic_decode_mlx5_12.tsv &
./poll_nic_counters mlx5_13 /tmp/nic_decode_mlx5_13.tsv &

# ... run benchmark, then Ctrl-C the pollers ...

# Analyze
python3 scripts/analyze_nic_counters.py results/phase1_nic_profile_isl4096_vf
```

### Experiment 4: IIO Clock Frequency Measurement

See `scripts/measure_ioclk.sh` for the full procedure. Summary:

```bash
# On a bare-metal node with SSH access, while ib_read_bw is running:

# Step 1: Measure ioclk free-running counter (reference only, ~45 MHz idle)
sudo perf stat -a -e \
    uncore_iio_free_running_{0..9}/ioclk/,\
    uncore_iio_free_running_{0..9}/bw_out_port0/ \
    sleep 45

# Step 2: Measure uncore/mesh frequency with PCM (this is the real clock)
sudo pcm -r -- sleep 10     # idle baseline
# start ib_read_bw workload, then:
sudo pcm -r -- sleep 10     # under load → ~2.4 GHz
```

Key finding: IIO programmable events use the uncore/mesh clock (~2.4 GHz under
load), NOT the ioclk free-running counter (~45 MHz reference).

### Experiment 5: VF MRRS Investigation

See `scripts/check_vf_mrrs.sh` for the full procedure. Summary:

```bash
# Check current MRRS from inside a pod:
lspci -vvs <vf-bdf> | grep MaxReadReq

# Attempt to change via setpci (will be silently dropped):
sudo setpci -s <vf-bdf> CAP_EXP+8.W=5000

# Verify from host node via SSH:
ssh <node> "sudo setpci -s <vf-bdf> CAP_EXP+8.W"
```

Key finding: VF DevCtl is virtualized by ConnectX-7 firmware; MRRS cannot be
changed at runtime. PF with MRRS=4096B shows no improvement over VF MRRS=128B
for contiguous access.

## Key Results Summary

| Scenario | Throughput/NIC | Notes |
|----------|---------------|-------|
| ib_read_bw same-IIO 2MB | 359 Gbps | PCIe Gen5 x16 near-line-rate |
| ib_read_bw cross-IIO 2MB | 254 Gbps | ~30% drop from mesh crossing |
| ib_read_bw cross-IIO 16KB | 148 Gbps | ~42% drop from completion overhead |
| ib_read_bw cross-socket 1-rail | 123 Gbps | UPI + mesh, shared NIC |
| ib_read_bw cross-socket 2-rail | 124 Gbps | UPI + mesh, 2 NICs (no scaling) |
| NIXL ISL=4096 (scattered 16KB) | ~27 Gbps | ~5.5× slower than ib_read_bw 16KB |
| NIXL ISL=8192 (scattered 16KB) | ~27 Gbps | Same rate, 2× duration |

## Root Cause

The 5.5× gap between NIXL and `ib_read_bw` (both using 16KB messages, same
cross-IIO topology) is caused by **scattered GPU memory access**:

- `ib_read_bw` reads from a single contiguous 16KB buffer → GPU serves CplD at
  full rate → NIC keeps tag pool saturated
- NIXL reads 40,960+ distinct 16KB blocks scattered across GPU HBM → each CplD
  requires a fresh GPU TLB lookup and potentially different HBM bank/channel →
  GPU-side DMA response latency inflates → NIC's in-flight tag pool drains →
  throughput collapses per Little's Law

The IIO completion buffer residence time confirms this: 2,479 cycles for
`ib_read_bw` 16KB (contiguous) vs 2,369-2,618 cycles for NIXL (scattered) --
similar mesh crossing overhead, but COMP_BUF insertion rate drops 5×, proving
the bottleneck is upstream in the GPU's memory subsystem.
