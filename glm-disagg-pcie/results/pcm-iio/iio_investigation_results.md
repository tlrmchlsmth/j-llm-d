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

## Experiment 3: Multi-Layer Monitoring (IIO + CHA Mesh)

Captured IIO rate counters (Queues A, B) and CHA mesh TOR occupancy simultaneously
during 2MB and 16KB ib_read_bw. 12 events total, some multiplexing on CHA and IIO5.

### CHA Mesh TOR: P2P Traffic Bypasses CHA

| CHA Event | 2MB (57s) | 16KB (57s) | Notes |
|-----------|-----------|------------|-------|
| TOR_INSERTS.LOC_IO | 1.20M | 0.72M | Background only (~1M vs IIO's 14B) |
| TOR_OCCUPANCY.LOC_IO | 454.9M | 229.1M | Background only |
| TOR_INSERTS.MMIO | 0 | 0 | Zero |
| TOR_OCCUPANCY.MMIO | 3.3K / 6.1K | — | Negligible |
| READ_NO_CREDITS (all MCs) | 0 | 0 | No memory stalls |

**Critical finding: P2P non-coherent traffic between IIO stacks does NOT flow through
the CHA TOR.** The mesh has a separate direct IIO-to-IIO forwarding path that bypasses
the coherency/home agent. CHA TOR credits are NOT the bottleneck.

### IIO Rate Counters: Full Pipeline View

| Counter | Location | 2MB raw | 16KB raw | Ratio | Sampling |
|---------|----------|---------|----------|-------|----------|
| COMP_BUF_OCC (0xd5) | IIO5 GPU | 39.6T | 21.9T | 0.55x | ~80% |
| COMP_BUF_INS (0xc2) | IIO5 GPU | 14.3B | 8.5B | 0.59x | ~78% |
| OUTBOUND_CL_REQS (0xd0) | IIO5 GPU | 12.6B | 7.4B | 0.59x | ~81% |
| OUTBOUND_TLP_REQS (0xd1) | IIO5 GPU | 17.3B | 10.2B | 0.59x | ~82% |
| DATA_OF_CPU.CMPD (0x83) | IIO5 GPU | 21K | 22K | ~1x | ~79% |
| **INBOUND_ARB_REQ (0x86)** | **IIO2 NIC** | **16.2B** | **10.7B** | **0.66x** | **100%** |
| **LOC_P2P (0x8e)** | **IIO2 NIC** | **12.7B** | **8.8B** | **0.69x** | **100%** |

IIO2 events at 100% sampling (no multiplexing) are the most reliable.

### Analysis

**GPU IIO5 rates all scale at ~0.59x** — exactly matching the throughput ratio
(252→148 Gbps = 0.587x). The GPU IIO processes proportionally less data; no anomaly.

**NIC IIO2 rates scale at 0.66-0.69x** — more requests per byte for 16KB:
- ARB_REQ per Gbps: 64.3M (2MB) vs 72.3M (16KB) → **+12% overhead**
- LOC_P2P per Gbps: 50.4M (2MB) vs 59.5M (16KB) → **+18% overhead**

The NIC generates extra per-work-request transactions (doorbells, completions, QP updates)
that scale with WR count, not data volume.

**DATA_REQ_OF_CPU.CMPD ≈ 0** for both runs: this event tracks CPU-initiated I/O
completions, not mesh-forwarded P2P completions.

**OUTBOUND_TLP_REQS > OUTBOUND_CL_REQS by ~37%**: each CL request generates
~1.37 TLP pipeline passes, possibly counting CplD forwarding to mesh as "outbound" TLPs.

### What This Rules Out

1. CHA TOR credit exhaustion — P2P traffic doesn't use CHA TOR
2. Memory controller credit stalls — P2P doesn't touch DRAM
3. CHA ingress queue congestion — not involved in P2P path
4. Any coherency-related overhead — traffic is fully non-coherent

### Remaining Bottleneck Location

The bottleneck is in the **IIO-to-IIO non-coherent mesh transport layer**, which is
architecturally separate from the CHA coherency fabric. No PMU events exist for this
layer. The IIO COMP_BUF residence time (Experiment 1: 1,631 vs 2,477 cycles) remains
the closest measurable proxy for the per-transaction overhead in this path.

## Experiment 4: RDMA WRITE vs RDMA READ (Posted vs Non-Posted)

This is the decisive experiment. RDMA READ uses non-posted PCIe transactions (MRd + CplD
round-trip), while RDMA WRITE uses posted PCIe transactions (MWr, fire-and-forget). If the
bottleneck is in the completion return path (CplD traversing the mesh), then writes should
be immune to the small-message degradation.

### Throughput Comparison

| Test | 2MB (Gbps/NIC) | 16KB (Gbps/NIC) | Degradation |
|------|----------------|-----------------|-------------|
| **RDMA READ** | **254** | **148** | **42% drop** |
| **RDMA WRITE** | **254** | **245** | **4% drop** |

**16KB RDMA WRITE achieves 245 Gbps/NIC** — barely degraded from 2MB.
**16KB RDMA READ drops to 148 Gbps/NIC** — 42% throughput loss.

The ~4% write degradation is consistent with normal PCIe/network header overhead
at smaller message sizes. The 42% read degradation is unique to the non-posted path.

### IIO Counters: 4-Way Cross-Node Comparison at 16KB

Monitored IIO counters on BOTH nodes during 16KB tests. node2 = 10.0.67.106,
node7 = 10.0.74.185. Both nodes are identical Intel Xeon 8480+ with same IIO layout.

| | Write Sender | Write Receiver | Read Requester | Read Responder |
|--|-------------|---------------|---------------|---------------|
| **Node** | node7 (10.0.74.185) | node2 (10.0.67.106) | node7 (10.0.74.185) | node2 (10.0.67.106) |
| **NIC operation** | DMA Read from GPU | DMA Write to GPU | DMA Write to GPU | DMA Read from GPU |
| **PCIe type** | **Non-posted** | Posted | Posted | **Non-posted** |
| **Throughput** | **248 Gbps/NIC** | 248 Gbps/NIC | 147 Gbps/NIC | **147 Gbps/NIC** |
| COMP_BUF_OCC (IIO5) | **41.2T** | 4.1M | 12.2B | **21.9T** (~80%) |
| COMP_BUF_INS (IIO5) | **14.8B** | 6.5K | 32.7M | **8.5B** (~78%) |
| LOC_P2P (IIO2) | **14.3B** | 2 | 0 | **8.8B** |
| ARB_REQ (IIO2) | **18.2B** | 356K | 246K | **10.7B** |
| OUTBOUND_CL (IIO5) | **14.8B** | 72K | 65.2M | **7.4B** (~81%) |
| OUTBOUND_TLP (IIO5) | **20.5B** | 142K | 127.3M | **10.2B** (~82%) |
| Avg cycles/entry | **2,787** | — | — | **2,477** |

Notes: All node7 counters at 100% sampling. Node2 read-responder had multiplexing
(percentages shown). Each perf stat ran 50s, workload active ~30s within window.

### Pattern: Non-Posted Shows Massive Activity, Posted Shows Idle

**Non-posted sides** (Write Sender + Read Responder): COMP_BUF_INS in billions,
LOC_P2P in billions — the NIC's cross-IIO DMA reads generate massive non-posted
transaction traffic through the completion buffer.

**Posted sides** (Write Receiver + Read Requester): All counters at background
noise levels — posted writes bypass the completion tracking infrastructure entirely.

### Write Sender vs Read Responder: NIC Pipelining Effect

Both sides perform the same operation (NIC DMA reads from GPU across IIO stacks),
but throughput differs dramatically:

| Metric | Write Sender | Read Responder | Ratio |
|--------|-------------|---------------|-------|
| Throughput | 248 Gbps | 147 Gbps | 1.69x |
| Completions/sec (est.) | ~493M/s | ~287M/s | 1.72x |
| Avg cycles/entry | 2,787 | 2,477 | 1.13x |

The write sender processes **72% more completions per second** despite each completion
spending **12% longer** in the buffer. This is a NIC pipelining advantage:

- **Write sender**: The NIC has pre-posted WQEs in its send queue. It knows exactly
  what data to fetch next and can issue DMA reads for many WQEs proactively, keeping
  the completion pipeline deeply loaded.
- **Read responder**: The NIC must react to incoming RDMA READ requests from the
  network. Each request triggers a DMA read, but the NIC can only pipeline as deep
  as its incoming request queue allows. The reactive processing adds latency.

The 2,787 vs 2,477 cycle difference suggests the write sender loads the buffer
more aggressively (higher avg occupancy / deeper pipeline), causing each individual
entry to wait slightly longer due to queueing, but overall throughput is much higher.

### Receiver-Side Counters for Writes

IIO counters on the **write receiver** (node2, 10.0.67.106):

| Counter | 2MB WRITE (50s) | 16KB WRITE (50s) |
|---------|-----------------|------------------|
| COMP_BUF_OCC (IIO5) | 3.8M | 4.1M |
| COMP_BUF_INS (IIO5) | 6.2K | 6.5K |
| LOC_P2P (IIO2) | 0 | 2 |
| OUTBOUND_CL (IIO5) | 71K | 72K |

All at idle/noise levels for both 2MB and 16KB, confirming posted writes take a
completely different datapath that bypasses the tracked request/completion pipeline.

### Conclusion

This experiment proves that:

1. **The non-posted completion path is the root cause** of the 42% read throughput
   degradation — this path is used regardless of whether it's RDMA READ (responder
   side) or RDMA WRITE (sender side)
2. **The posted write path is immune** to the small-message penalty — receiver-side
   counters show zero activity, and end-to-end write throughput barely degrades (4%)
3. **NIC pipelining matters significantly**: The write sender achieves 69% higher
   throughput than the read responder on the same non-posted path, because the NIC
   can proactively pipeline DMA reads from pre-posted WQEs
4. **RDMA WRITE is not a complete solution**: It moves the bottleneck from the
   responder to the sender, but the sender still achieves much higher throughput
   (248 vs 147 Gbps) due to NIC-level pipelining advantages

```
RDMA READ (16KB, cross-IIO):
  Responder: NIC reads from GPU (non-posted, REACTIVE)     → 147 Gbps
  Requester: NIC writes to GPU (posted, fast)               → (not limiting)

RDMA WRITE (16KB, cross-IIO):
  Sender:    NIC reads from GPU (non-posted, PROACTIVE)     → 248 Gbps
  Receiver:  NIC writes to GPU (posted, fast)               → (not limiting)
```

Both paths involve non-posted DMA reads from GPU, but NIC pipelining control
on the write-sender side yields 69% better throughput for the same operation.

### Implications for NIXL

NIXL uses RDMA READ (the decode server pulls KV cache from the prefill server).
This places it squarely in the degraded non-posted path.

**Note on RDMA WRITE alternative:** Switching to RDMA WRITE (prefill pushes to decode)
does NOT eliminate the non-posted path. The sender's NIC must still DMA READ scattered
KV blocks from the local GPU's memory — the same MRd + CplD round-trip through the
IIO-mesh-IIO pipeline, just on the sender node instead of the responder.

However, Experiment 4 shows the write-sender path achieves **69% higher throughput**
(248 vs 147 Gbps) than the read-responder for the same underlying non-posted DMA read
operation, due to NIC pipelining advantages when initiating from pre-posted WQEs.
Whether this advantage holds with NIXL's 40K+ scattered addresses (vs. ib_write_bw's
single contiguous buffer) is unknown and would need testing.

Viable mitigations:

1. **Increase VF MRRS**: Raise from 128 bytes to 4096 bytes to reduce transaction count
   by 32x. Requires SR-IOV PF driver or firmware changes.
2. **Keep GPU-NIC on same IIO stack**: Scenario 1 topology avoids mesh crossing entirely.
   Only feasible when PCIe topology allows it.

### Pending Experiments

- **Option 1**: Run IIO counters on requester node (10.0.74.185) to verify bottleneck side

## Raw perf stat Events Used

| Event | EventCode | UMask | Description |
|-------|-----------|-------|-------------|
| COMP_BUF_OCCUPANCY.CMPD.ALL_PARTS | 0xd5 | 0xff | Cycle-weighted completion buffer occupancy |
| COMP_BUF_INSERTS.CMPD.ALL_PARTS | 0xc2 | 0x04 | Completions with data inserted into buffer |
| NUM_REQ_OF_CPU_BY_TGT.LOC_P2P | 0x8e | 0x20 | Local peer-to-peer request count |
| OUTBOUND_CL_REQS_ISSUED.TO_IO | 0xd0 | 0x08 | 64B cacheline requests issued to device |
| OUTBOUND_TLP_REQS_ISSUED.TO_IO | 0xd1 | 0x08 | TLP-level requests issued to device |
| INBOUND_ARB_REQ.FINAL_RD_WR | 0x86 | 0x08 | Inbound pipeline arbitration requests (read/write) |
| DATA_REQ_OF_CPU.CMPD.ALL_PARTS | 0x83 | 0x80 | CplD data from device (didn't capture P2P traffic) |

CHA mesh events (UMaskExt encoded in umask bits 32-63 via `umask:config:8-15,32-63`):

| Event | EventCode | perf umask | Description |
|-------|-----------|------------|-------------|
| TOR_OCCUPANCY.LOC_IO | 0x36 | 0xC000FF04 | Cycle-weighted mesh TOR occupancy for local I/O |
| TOR_INSERTS.LOC_IO | 0x35 | 0xC000FF04 | Mesh TOR inserts for local I/O |
| TOR_OCCUPANCY.MMIO | 0x36 | 0x4000 | Mesh TOR occupancy for MMIO transactions |
| TOR_INSERTS.MMIO | 0x35 | 0x4000 | Mesh TOR inserts for MMIO |
| READ_NO_CREDITS (all MCs) | 0x58 | 0x3f | Cycles with no credits to memory controller |

Common IIO perf stat options: `ch_mask=0xff, fc_mask=0x07` (all ports, all flow classes)
For thresh probing: append `thresh=N` to COMP_BUF_OCCUPANCY event spec.

## Files

- `pcm-iio_idle.txt` — pcm-iio baseline with no workload
- `pcm-iio_ib_read_bw_s2r2.txt` — pcm-iio during 2MB ib_read_bw (scenario 2r2 topology)
- `../../ib_read_bw-tests/scenario2r2-ib_read_bw.txt` — 2MB ib_read_bw results
- `../../ib_read_bw-tests/scenario2-ib_read_bw.txt` — 2MB ib_read_bw results (1 rail)
- Test config (16KB read): `/home/rajjoshi/workspace/networking-debug-container/inter_node_tests/multi_nic_ib_write_bw/pcie-tree-2gpu-nic_pairs-16KB.json`
- Test config (2MB read): `/home/rajjoshi/workspace/networking-debug-container/inter_node_tests/multi_nic_ib_write_bw/pcie-tree-2gpu-nic_pairs.json`
- Test config (16KB write): `/home/rajjoshi/workspace/networking-debug-container/inter_node_tests/multi_nic_ib_write_bw/pcie-tree-2gpu-nic_pairs-16KB-write.json`
- Test config (2MB write): `/home/rajjoshi/workspace/networking-debug-container/inter_node_tests/multi_nic_ib_write_bw/pcie-tree-2gpu-nic_pairs-2MB-write.json`
