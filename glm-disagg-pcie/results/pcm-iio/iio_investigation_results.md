# IIO Stack Investigation: Cross-Root-Port P2P Throughput Degradation

**Date:** 2026-02-27
**Node:** 10.0.67.106 (Intel Xeon Platinum 8480+ Sapphire Rapids, `iommu=pt`)
**Test:** `ib_read_bw` cross-IIO-stack (Scenario 2r2 topology), 2 NIC-GPU pairs

## Hardware Topology (Socket 1 / NUMA 1)

| IIO Stack | pcm-iio Label | Root Port Bus | Devices |
|-----------|---------------|---------------|---------|
| IIO2      | Stack 9 (PCIe4) | 0xb8        | **GPU 2** (c2:00.0) + **mlx5_16** (bd:00.1) |
| IIO7      | Stack 4 (PCIe1) | 0xd0        | **GPU 3** (da:00.0) + **mlx5_17** (d5:00.1) |
| IIO5      | Stack 2 (PCIe0) | 0x81        | **GPU 0** (8b:00.0) + mlx5_14 (86:00.1) |
| IIO11     | Stack 6 (PCIe2) | 0xa0        | **GPU 1** (aa:00.0) + mlx5_15 (a5:00.1) |

In the test, GPU 0 pairs with mlx5_16 and GPU 1 pairs with mlx5_17 (cross-IIO-stack).
Data path: NIC (IIO2/IIO7) → mesh fabric → GPU (IIO5/IIO11)

## pcm-iio Unit Calibration

pcm-iio on SPR reports data volume in **16-byte (4-DWORD) granules**, calibrated against actual ib_read_bw results:
- Stack 2 (GPU 0): 1,996M granules/s × 16 = 31.94 GB/s = 255.5 Gbps (ib_read_bw: 249.77 Gbps + PCIe overhead)
- Stack 6 (GPU 1): 2,002M granules/s × 16 = 32.03 GB/s = 256.3 Gbps (ib_read_bw: 254.11 Gbps + PCIe overhead)

## IIO Clock Frequency

Measured via `uncore_iio_free_running_N/ioclk/` during 2MB ib_read_bw workload:

| IIO Unit | ioclk (60s window) | Active-period estimate |
|----------|-------------------|----------------------|
| IIO2 (NIC, mlx5_16) | 30,677,118,904 | **~1.02 GHz** (reliable) |
| IIO7 (NIC, mlx5_17) | 2,222,194,456 | ~74 MHz (unreliable) |
| IIO5 (GPU 0) | 1,338,969,534 | ~44 MHz (unreliable - power gating?) |
| IIO11 (GPU 1) | 0 | Counter not working |

**Best estimate: IIO clock ≈ 1 GHz** (from IIO2, the only stack with reliable ioclk values)

## Experiment 1: 2MB ib_read_bw (~254 Gbps/NIC)

### Per-NIC Throughput
- Pair 1 (mlx5_16 → GPU 0): **254.14 Gbps**
- Pair 2 (mlx5_17 → GPU 1): **254.53 Gbps**
- Aggregate: **508.67 Gbps**

### GPU IIO Stacks (IIO5, IIO11) — Completion Buffer

| Counter | IIO5 (GPU 0) | IIO11 (GPU 1) |
|---------|-------------|---------------|
| COMP_BUF_OCCUPANCY (0xd5, cycle-weighted) | 24,310,558,753,485 (24.3T) | 28,300,000,000,000 (~28.3T) |
| COMP_BUF_INSERTS (0xc2, total entries) | 14,877,729,875 (14.9B) | 14,852,235,777 (14.9B) |
| **Avg cycles per entry** | **1,631** | **~1,901** |
| **Avg residence time (@1GHz)** | **~1,631 ns** | **~1,901 ns** |

### Completion Buffer Capacity Probing (thresh)

| Threshold | IIO5 cycles above | IIO11 cycles above | % of active time |
|-----------|-------------------|-------------------|-----------------|
| 256 | 23.49B | 23.50B | ~100% |
| 1024 | 22.91B | 22.93B | ~97.5% |
| 1280 | 28.27B | 28.35B | ~100% |
| **1536** | **64M** | **212M** | **<1%** |
| 2048 | 0 | 0 | 0% |
| 3072 | 0 | 0 | 0% |

**Buffer peaks between 1280 and 1536 entries** during line-rate 2MB transfers.

### NIC IIO Stacks (IIO2, IIO7) — Completion Buffer

| Counter | IIO2 (NIC mlx5_16) | IIO7 (NIC mlx5_17) |
|---------|-------------------|-------------------|
| COMP_BUF_OCCUPANCY | 436,473,814 (436M) | 451,683,630 (452M) |
| COMP_BUF_INSERTS | 734,501 (735K) | 732,957 (733K) |
| LOC_P2P requests | 14,874,017,801 (14.9B) | 14,908,522,505 (14.9B) |

**NIC IIO stacks show negligible completion buffer activity.** The NIC's IIO acts as a forwarding
agent for P2P traffic — it sends MRd requests into the mesh but does not track completions
in its own buffer. The GPU's IIO stack handles all completion tracking.

### Identifying NIC IIO Stacks

Used `NUM_REQ_OF_CPU_BY_TGT.LOC_P2P` (event=0x8e, umask=0x20) to identify which IIO
stacks handle NIC P2P traffic:

| IIO Stack | LOC_P2P requests/s | Role |
|-----------|-------------------|------|
| IIO2 | ~495M/s | **NIC (mlx5_16)** |
| IIO7 | ~495M/s | **NIC (mlx5_17)** |
| IIO5 | ~7.7M/s | GPU 0 (low — receives, doesn't originate P2P) |
| IIO11 | ~7.7M/s | GPU 1 (same) |

## Experiment 2: 16KB ib_read_bw (~148 Gbps/NIC)

Simulates NIXL's scattered 16KB block reads.

### Per-NIC Throughput
- Pair 1 (mlx5_16 → GPU 0): **~148 Gbps**
- Pair 2 (mlx5_17 → GPU 1): **~148 Gbps**
- Aggregate: **~296 Gbps**
- **42% throughput drop from 2MB messages**

### GPU IIO Stacks (IIO5, IIO11) — Completion Buffer

| Counter | IIO5 (GPU 0) | IIO11 (GPU 1) |
|---------|-------------|---------------|
| COMP_BUF_OCCUPANCY | 21,338,092,229,060 (21.3T) | ~22.0T |
| COMP_BUF_INSERTS | 8,613,457,361 (8.6B) | ~8.5B |
| **Avg cycles per entry** | **2,477** | **~2,588** |
| **Avg residence time (@1GHz)** | **~2,477 ns** | **~2,588 ns** |

### NIC IIO Stacks (IIO2, IIO7) — Completion Buffer

| Counter | IIO2 (NIC) | IIO7 (NIC) |
|---------|-----------|-----------|
| COMP_BUF_OCCUPANCY | 5,997,028 (6M) | 3,850,658 (4M) |
| COMP_BUF_INSERTS | 10,997 (11K) | ~11K |
| LOC_P2P requests | 8,671,501,569 (8.7B) | 8,613,443,073 (8.6B) |

NIC completion buffer is negligible for both message sizes. This is an architectural property,
not dependent on message size.

## Key Comparison: 2MB vs 16KB

| Metric | 2MB | 16KB | Ratio (16KB/2MB) |
|--------|-----|------|-----------------|
| **Throughput (per NIC)** | **254 Gbps** | **148 Gbps** | **0.58x** |
| NIC LOC_P2P requests/s | ~495M/s | ~289M/s | 0.58x |
| GPU COMP_BUF_INSERTS/s | ~496M/s | ~287M/s | 0.58x |
| GPU COMP_BUF avg occupancy (entries) | ~810 | ~710 | 0.88x |
| **GPU COMP_BUF avg cycles/entry** | **1,631** | **2,477** | **1.52x** |
| **GPU COMP_BUF avg residence time** | **~1.6 µs** | **~2.5 µs** | **1.52x** |
| Buffer peak occupancy | 1280-1536 | <1280 (buffer less full) | — |

## Analysis

### What COMP_BUF_OCCUPANCY / COMP_BUF_INSERTS means

By Little's Law: **avg_residence_time = avg_occupancy / arrival_rate**

- `COMP_BUF_OCCUPANCY` = Σ (entries in buffer per cycle) — cycle-weighted cumulative counter
- `COMP_BUF_INSERTS` = total entries inserted into the buffer

Division gives **average IIO clock cycles each 64-byte cache-line completion entry
spent in the GPU's IIO completion buffer** before being forwarded across the mesh to the NIC.

At ~1 GHz IIO clock:
- 2MB: 1,631 cycles ≈ **1.6 µs per cache line**
- 16KB: 2,477 cycles ≈ **2.5 µs per cache line**

### Why ~1.6 µs per cache line is reasonable

The GPU's IIO completion buffer isn't a simple PCIe link buffer. It's a staging area for data
that must traverse the mesh fabric to reach the NIC's IIO stack on a different root port.
The residence time includes:
1. Queueing behind ~810 other entries on average
2. Arbitrating for mesh bandwidth
3. Mesh fabric crossing latency (~100-200 ns per hop)
4. Acknowledgment/credit return from the mesh

At 810 avg entries and 496M entries/s, the buffer acts as a deep pipeline keeping the mesh
fully utilized. At ~54% of peak capacity (810/1500), it's healthy — not saturated.

### The Root Cause: Per-Transaction Overhead, Not Buffer Saturation

The initial hypothesis was that the IIO completion buffer would **saturate** (fill completely)
with smaller messages, creating backpressure. **This is NOT what we observed.**

Instead:
1. The buffer is **LESS occupied** with 16KB messages (710 entries vs 810)
2. But each entry sits **52% longer** (2.5 µs vs 1.6 µs)
3. Throughput drops 42% (148 vs 254 Gbps)

The bottleneck is **per-transaction processing overhead** through the IIO-mesh-IIO path:
- With 2MB messages, the NIC posts large read requests that generate many sequential
  completions from the same address region — the IIO/mesh can pipeline efficiently
- With 16KB messages, each read request is small and targets a different address —
  more request/grant mesh transactions per byte of useful data, more TLP header overhead,
  less pipelining benefit

Each cache line of 16KB data requires more "work" from the mesh infrastructure per byte
transferred, even though the buffer has plenty of capacity. This is a throughput-per-transaction
efficiency problem, not a resource exhaustion problem.

### Implications for NIXL

NIXL posts 40,960 individual RDMA READ work requests per KV transfer, each for a scattered
16KB block at a different GPU memory address. Combined with VF MRRS=128 bytes (each 16KB
read becomes 128 PCIe MRd TLPs), this creates 5.2 million PCIe transactions per transfer.

The IIO-mesh-IIO path degrades not because it runs out of buffer space, but because:
1. **Transaction overhead scales with count, not just data volume**
2. **Scattered addresses reduce pipelining efficiency**
3. **128-byte MRRS amplifies the problem 32x** vs. PF MRRS of 4096 bytes

In Scenario 1 (same PCIe tree), P2P traffic stays within the PCIe switch and never
traverses the mesh, so these IIO overheads don't apply.

## Raw perf stat Events Used

| Event | EventCode | UMask | Description |
|-------|-----------|-------|-------------|
| COMP_BUF_OCCUPANCY.CMPD.ALL_PARTS | 0xd5 | 0xff | Cycle-weighted completion buffer occupancy |
| COMP_BUF_INSERTS.CMPD.ALL_PARTS | 0xc2 | 0x04 | Completions with data inserted into buffer |
| NUM_REQ_OF_CPU_BY_TGT.LOC_P2P | 0x8e | 0x20 | Local peer-to-peer request count |

Common perf stat options: `ch_mask=0xff, fc_mask=0x07` (all ports, all flow classes)
For thresh probing: append `thresh=N` to COMP_BUF_OCCUPANCY event spec.

## Files

- `pcm-iio_idle.txt` — pcm-iio baseline with no workload
- `pcm-iio_ib_read_bw_s2r2.txt` — pcm-iio during 2MB ib_read_bw (scenario 2r2 topology)
- `../../ib_read_bw-tests/scenario2r2-ib_read_bw.txt` — 2MB ib_read_bw results
- `../../ib_read_bw-tests/scenario2-ib_read_bw.txt` — 2MB ib_read_bw results (1 rail)
- Test config (16KB): `/home/rajjoshi/workspace/networking-debug-container/inter_node_tests/multi_nic_ib_write_bw/pcie-tree-2gpu-nic_pairs-16KB.json`
- Test config (2MB): `/home/rajjoshi/workspace/networking-debug-container/inter_node_tests/multi_nic_ib_write_bw/pcie-tree-2gpu-nic_pairs.json`
