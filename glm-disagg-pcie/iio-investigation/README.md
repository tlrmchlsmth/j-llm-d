# Cross-IIO PCIe P2P Throughput Degradation: Root Cause Analysis

## Summary

When a ConnectX-7 NIC and an AMD MI300X GPU reside on **different IIO stacks** of an Intel Sapphire Rapids CPU, GPU-direct RDMA READ throughput drops **42%** (254 to 148 Gbps per NIC) when message size decreases from 2 MB to 16 KB. Using Intel IIO performance counters, we trace the root cause to the **non-posted PCIe completion path** through the CPU's internal mesh fabric: each Memory Read (MRd) TLP must wait for a Completion-with-Data (CplD) to traverse back through the GPU's IIO completion buffer and across the mesh, and the per-transaction overhead of this round trip increases with smaller messages. A decisive RDMA WRITE vs READ comparison confirms that posted writes -- which bypass the completion path entirely -- suffer only 4% degradation at 16 KB.

---

## Table of Contents

1. [Background](#background)
2. [Test Environment](#test-environment)
3. [IIO Architecture Primer](#iio-architecture-primer)
4. [PMU Events Reference](#pmu-events-reference)
5. [Experiment 1: Baseline (2 MB RDMA READ)](#experiment-1-baseline-2-mb-rdma-read)
6. [Experiment 2: Small Messages (16 KB RDMA READ)](#experiment-2-small-messages-16-kb-rdma-read)
7. [Analysis: 2 MB vs 16 KB](#analysis-2-mb-vs-16-kb)
8. [Experiment 3: Ruling Out the CHA Mesh](#experiment-3-ruling-out-the-cha-mesh)
9. [Experiment 4: RDMA WRITE vs READ (The Decisive Test)](#experiment-4-rdma-write-vs-read-the-decisive-test)
10. [Conclusion](#conclusion)
11. [Implications for NIXL and llm-d](#implications-for-nixl-and-llm-d)
12. [Reproducing These Results](#reproducing-these-results)

---

## Background

In **prefill/decode disaggregated LLM inference** (as implemented by [llm-d](https://github.com/llm-d/llm-d)), the decode server fetches KV cache blocks from the prefill server using **RDMA READ** via NIXL/UCX. Each KV transfer consists of tens of thousands of 16 KB blocks scattered across GPU memory.

On bare-metal nodes with Intel Sapphire Rapids CPUs and AMD MI300X GPUs, the PCIe topology determines whether a NIC and GPU share the same IIO stack (connected via a PCIe switch) or sit on different IIO stacks (requiring traffic to cross the CPU's internal mesh fabric). When GPU and NIC are on different IIO stacks, we observed significantly degraded KV transfer throughput. This report documents the investigation into why.

---

## Test Environment

### Hardware

| Component | Detail |
|-----------|--------|
| CPU | Intel Xeon Platinum 8480+ (Sapphire Rapids), 2 sockets |
| GPU | AMD Instinct MI300X (4 per node, PCIe Gen5 x16) |
| NIC | NVIDIA ConnectX-7 (4 per node, 400 Gbps InfiniBand, SR-IOV VFs) |
| Network | 400 Gbps InfiniBand HDR |

### Software

| Setting | Value |
|---------|-------|
| IOMMU | Passthrough (`iommu=pt` in kernel cmdline) |
| SR-IOV | VFs exposed to pods; PF managed by host |
| VF Max Read Request Size (MRRS) | **128 bytes** |
| PF Max Read Request Size (MRRS) | 4096 bytes |
| Kubernetes | Pods with GPU and NIC pass-through |

### PCIe Topology (Socket 1 / NUMA 1)

Both test nodes are identically configured. Each GPU is co-located with a NIC on the same IIO stack:

```
IIO Stack 5 (PCIe0, bus 0x81)         IIO Stack 11 (PCIe2, bus 0xa0)
  ├── GPU 0  (8b:00.0)                  ├── GPU 1  (aa:00.0)
  └── mlx5_14 (86:00.1)                 └── mlx5_15 (a5:00.1)

IIO Stack 2 (PCIe4, bus 0xb8)         IIO Stack 7 (PCIe1, bus 0xd0)
  ├── GPU 2  (c2:00.0)                  ├── GPU 3  (da:00.0)
  └── mlx5_16 (bd:00.1)                 └── mlx5_17 (d5:00.1)
```

### Cross-IIO Test Configuration

The experiments deliberately pair GPUs with NICs on **different** IIO stacks to force traffic through the mesh:

```
Test pair 1:  GPU 0 (IIO5) <--mesh--> mlx5_16 (IIO2)
Test pair 2:  GPU 1 (IIO11) <--mesh--> mlx5_17 (IIO7)
```

### Node Roles

| Node | IP | Tmux Session | Role in RDMA READ | Role in RDMA WRITE |
|------|----|----|----|----|
| node2 | 10.0.67.106 | `node2` | Responder (NIC reads from GPU) | Receiver (NIC writes to GPU) |
| node7 | 10.0.74.185 | `node7` | Requester (NIC writes to GPU) | Sender (NIC reads from GPU) |

---

## IIO Architecture Primer

### What is an IIO Stack?

Each Intel Sapphire Rapids socket contains multiple **Integrated I/O (IIO) stacks**. Each IIO stack is a PCIe root complex with its own:
- PCIe link interface to downstream devices
- Transaction processing logic
- **Completion buffer** for tracking non-posted transactions
- Connection to the CPU's internal mesh fabric

### Cross-IIO Peer-to-Peer Transfers

When a NIC on one IIO stack needs to access GPU memory on a different IIO stack, the traffic must cross the CPU's mesh fabric:

```
RDMA READ — Non-posted round trip (2 mesh crossings):

  NIC          NIC IIO (IIO2)         Mesh          GPU IIO (IIO5)         GPU
   |               |                   |                  |                  |
   |--[MRd TLP]--->|---[MRd]---------->|---[MRd]--------->|---[MRd TLP]---->|
   |               |                   |                  |                  |
   |               |                   |                  |<---[CplD TLP]----|
   |               |                   |<--[CplD]---------|                  |
   |               |<--[CplD]----------|    (queues in    |                  |
   |<--[CplD TLP]--|                   |    COMP_BUF)     |                  |
   |               |                   |                  |                  |

RDMA WRITE — Posted, one-way (1 mesh crossing):

  NIC          NIC IIO (IIO2)         Mesh          GPU IIO (IIO5)         GPU
   |               |                   |                  |                  |
   |--[MWr TLP]--->|---[MWr+data]----->|---[MWr+data]---->|---[MWr TLP]---->|
   |               |                   |                  |    (no return)   |
```

### Non-Posted vs Posted PCIe Transactions

| Property | Non-Posted (MRd) | Posted (MWr) |
|----------|-----------------|--------------|
| Requires completion? | Yes (CplD must return) | No (fire-and-forget) |
| Mesh crossings | 2 (request + completion) | 1 (request only) |
| Tag/credit consumed | Yes, held until CplD returns | No tag needed |
| Completion buffer used | Yes, CplD queues in COMP_BUF | No |
| Flow control | Non-posted credits (limited) | Posted credits (more abundant) |

### The Completion Buffer

The GPU's IIO stack has a **completion buffer (COMP_BUF)** that stages CplD packets before they are forwarded across the mesh to the NIC's IIO stack. This buffer:

- Holds 64-byte cache-line entries of completion data
- Has a measured peak capacity of **1280-1536 entries**
- Acts as a pipeline: entries queue while waiting for mesh bandwidth and credits
- Residence time per entry includes mesh arbitration, crossing latency, and credit returns

---

## PMU Events Reference

All events are from the Sapphire Rapids uncore PMU. IIO events require `ch_mask=0xff,fc_mask=0x07` (all ports, all flow classes).

### IIO Events

| Short Name | Full Event Name | Code | Monitored On | What It Measures |
|------------|----------------|------|-------------|-----------------|
| **COMP_BUF_OCC** | COMP_BUF_OCCUPANCY.CMPD.ALL_PARTS | `0xd5/0xff` | GPU IIO (IIO5) | Cumulative cycle-weighted count of CplD entries sitting in the completion buffer, waiting to be forwarded across the mesh to the NIC. Divide by COMP_BUF_INS to get average residence time in IIO clock cycles. |
| **COMP_BUF_INS** | COMP_BUF_INSERTS.CMPD.ALL_PARTS | `0xc2/0x04` | GPU IIO (IIO5) | Total number of 64-byte CplD entries inserted into the completion buffer. Each PCIe MRd generates one or more CplD entries that pass through this buffer. |
| **OUTBOUND_CL** | OUTBOUND_CL_REQS_ISSUED.TO_IO | `0xd0/0x08` | GPU IIO (IIO5) | Count of 64-byte cacheline-granularity requests issued from the IIO stack downstream to the PCIe device (GPU). Represents MRd requests arriving from the mesh being forwarded to the GPU. |
| **OUTBOUND_TLP** | OUTBOUND_TLP_REQS_ISSUED.TO_IO | `0xd1/0x08` | GPU IIO (IIO5) | Count of TLP-level requests issued to the PCIe device. Higher than OUTBOUND_CL because one cacheline request may require multiple TLP pipeline passes (e.g., CplD forwarding). |
| **ARB_REQ** | INBOUND_ARB_REQ.FINAL_RD_WR | `0x86/0x08` | NIC IIO (IIO2) | Count of inbound read/write requests from the NIC entering the IIO stack's arbitration pipeline. Includes MRd requests from the NIC destined for the mesh, plus NIC-internal control traffic (doorbells, CQE writes). |
| **LOC_P2P** | NUM_REQ_OF_CPU_BY_TGT.LOC_P2P | `0x8e/0x20` | NIC IIO (IIO2) | Count of PCIe requests from the NIC that target a peer device on a **different IIO stack** on the same socket. In our setup, these are MRd requests from the NIC targeting GPU memory across the mesh. |
| **DATA_CMPD** | DATA_REQ_OF_CPU.CMPD.ALL_PARTS | `0x83/0x80` | GPU IIO (IIO5) | Count of CplD data arriving from the PCIe device back to the IIO. Only captures CPU-initiated I/O completions; does **not** capture mesh-forwarded P2P completions (showed near-zero in all tests). |

### CHA Mesh Events

These events monitor the Caching and Home Agent (CHA) coherency fabric. UMaskExt is encoded in umask bits 32-63 via `umask:config:8-15,32-63`.

| Short Name | Full Event Name | Code / perf umask | What It Measures |
|------------|----------------|-------------------|-----------------|
| **TOR_OCC.LOC_IO** | TOR_OCCUPANCY.LOC_IO | `0x36 / 0xC000FF04` | Cycle-weighted occupancy of the Table of Requests (TOR) for local I/O transactions. If P2P traffic used the CHA, this would show high values proportional to traffic volume. |
| **TOR_INS.LOC_IO** | TOR_INSERTS.LOC_IO | `0x35 / 0xC000FF04` | Total local I/O transactions entering the CHA TOR. A high count would indicate P2P traffic flows through the coherency engine. |
| **TOR_OCC.MMIO** | TOR_OCCUPANCY.MMIO | `0x36 / 0x4000` | CHA TOR occupancy for memory-mapped I/O transactions. |
| **TOR_INS.MMIO** | TOR_INSERTS.MMIO | `0x35 / 0x4000` | CHA TOR inserts for MMIO transactions. |
| **READ_NO_CREDITS** | READ_NO_CREDITS (all MCs) | `0x58 / 0x3f` | Cycles where the CHA has no credits to send requests to any memory controller. Non-zero would indicate DRAM bandwidth contention. |

---

## Experiment 1: Baseline (2 MB RDMA READ)

**Goal:** Establish baseline cross-IIO throughput with large messages.

**Setup:** `ib_read_bw` with 2 MB messages, 2 NIC-GPU pairs, 30 seconds. Requester (node7) pulls data from Responder (node2). Perf stat on node2 captures IIO counters on GPU IIO5 and NIC IIO2.

### Throughput

| Pair | NIC | GPU | Throughput |
|------|-----|-----|-----------|
| 1 | mlx5_16 (IIO2) | GPU 0 (IIO5) | **254.14 Gbps** |
| 2 | mlx5_17 (IIO7) | GPU 1 (IIO11) | **254.53 Gbps** |
| | | Aggregate | **508.67 Gbps** |

Near line-rate for 400G InfiniBand after PCIe/protocol overhead.

### GPU IIO Completion Buffer (IIO5)

| Metric | IIO5 (GPU 0) | IIO11 (GPU 1) |
|--------|-------------|---------------|
| COMP_BUF_OCC (cycle-weighted) | 24.3 T | 28.3 T |
| COMP_BUF_INS (entries) | 14.9 B | 14.9 B |
| **Avg cycles/entry** | **1,631** | **1,901** |
| **Avg residence time (@1 GHz)** | **~1.6 us** | **~1.9 us** |

### Completion Buffer Capacity (thresh probing)

| Threshold (entries) | % of time buffer exceeds threshold |
|--------------------|------------------------------------|
| 256 | ~100% |
| 1,024 | ~97.5% |
| 1,280 | ~100% |
| **1,536** | **<1%** |
| 2,048 | 0% |

The buffer peaks between **1,280 and 1,536 entries** during line-rate 2 MB transfers, operating at roughly 54% of peak capacity (~810 average entries).

### NIC IIO (IIO2) -- Negligible Completion Activity

| Metric | IIO2 (NIC) |
|--------|-----------|
| COMP_BUF_INS | 735 K (noise) |
| LOC_P2P | 14.9 B |

The NIC's IIO stack forwards MRd requests into the mesh but does **not** track completions in its own buffer. All completion tracking happens at the GPU's IIO stack.

---

## Experiment 2: Small Messages (16 KB RDMA READ)

**Goal:** Measure throughput degradation with NIXL-like 16 KB messages.

**Setup:** Same as Experiment 1, but with 16 KB message size.

### Throughput

| Pair | Throughput |
|------|-----------|
| 1 (mlx5_16 -> GPU 0) | **~148 Gbps** |
| 2 (mlx5_17 -> GPU 1) | **~148 Gbps** |
| Aggregate | **~296 Gbps** |
| **Degradation from 2 MB** | **42% drop** |

### GPU IIO Completion Buffer (IIO5)

| Metric | IIO5 (GPU 0) |
|--------|-------------|
| COMP_BUF_OCC | 21.3 T |
| COMP_BUF_INS | 8.6 B |
| **Avg cycles/entry** | **2,477** |
| **Avg residence time** | **~2.5 us** |

---

## Analysis: 2 MB vs 16 KB

| Metric | 2 MB | 16 KB | Ratio |
|--------|------|-------|-------|
| **Throughput (per NIC)** | **254 Gbps** | **148 Gbps** | **0.58x** |
| LOC_P2P requests/s (NIC IIO2) | ~495 M/s | ~289 M/s | 0.58x |
| COMP_BUF_INS/s (GPU IIO5) | ~496 M/s | ~287 M/s | 0.58x |
| COMP_BUF avg occupancy (entries) | ~810 | ~710 | 0.88x |
| **COMP_BUF avg cycles/entry** | **1,631** | **2,477** | **1.52x** |
| **COMP_BUF avg residence time** | **~1.6 us** | **~2.5 us** | **1.52x** |
| Buffer peak occupancy | 1,280-1,536 | <1,280 | -- |

### Deriving Residence Time (Little's Law)

The COMP_BUF counters follow Little's Law:

```
avg_residence_time = COMP_BUF_OCCUPANCY / COMP_BUF_INSERTS
```

- `COMP_BUF_OCCUPANCY` accumulates one count per buffer entry per IIO clock cycle (cycle-weighted occupancy)
- `COMP_BUF_INSERTS` counts total entries inserted

The quotient gives the average number of IIO clock cycles each 64-byte CplD entry spends in the buffer before being forwarded across the mesh. At ~1 GHz IIO clock, this converts directly to nanoseconds.

### Root Cause: Per-Transaction Overhead, Not Buffer Saturation

The initial hypothesis was that the completion buffer would **fill up** with small messages, creating backpressure. This is **not** what happened.

Instead:
1. The buffer is **less occupied** with 16 KB messages (710 vs 810 avg entries)
2. Each entry spends **52% longer** in the buffer (2.5 vs 1.6 us)
3. Throughput drops 42%

The mechanism:

```
Throughput = max_inflight_data / round_trip_latency

max_inflight_data = num_PCIe_tags * MRRS
                  = N * 128 bytes  (with VF MRRS = 128)

round_trip_latency = MRd_mesh_crossing + GPU_read + CplD_COMP_BUF_wait + CplD_mesh_crossing
                                                     ^^^^^^^^^^^^^^^^
                                                     2.5 us for 16KB (vs 1.6 us for 2MB)
```

With a fixed tag pool and fixed MRRS, the longer each CplD takes to return through the completion buffer, the lower the sustained throughput. The NIC cannot issue new MRd requests until tags are freed by returning completions. In steady state, the **completion return rate dictates the request issue rate**.

The per-transaction overhead increases with smaller messages because:
- More RDMA work requests per byte means more NIC-internal overhead (doorbells, CQEs, QP state updates)
- Less spatial locality in mesh request/grant patterns
- More TLP header overhead per byte of useful data

---

## Experiment 3: Ruling Out the CHA Mesh

**Goal:** Determine whether the bottleneck is in the CHA coherency fabric or the IIO-to-IIO mesh path.

**Setup:** Captured 12 events simultaneously (IIO rate counters + CHA TOR occupancy) during both 2 MB and 16 KB `ib_read_bw` on the responder (node2). Some event multiplexing occurred.

### CHA TOR: P2P Traffic Bypasses Coherency

| CHA Event | 2 MB (57s) | 16 KB (57s) |
|-----------|-----------|------------|
| TOR_INS.LOC_IO | 1.20 M | 0.72 M |
| TOR_OCC.LOC_IO | 454.9 M | 229.1 M |
| TOR_INS.MMIO | 0 | 0 |
| READ_NO_CREDITS | 0 | 0 |

Compare TOR_INS.LOC_IO (~1 M) with IIO COMP_BUF_INS (~14 B): the CHA sees **10,000x less traffic** than the IIO stacks. P2P non-coherent traffic between IIO stacks takes a **direct IIO-to-IIO mesh path** that bypasses the CHA coherency engine entirely.

### IIO Rate Counters

| Counter | Location | 2 MB | 16 KB | Ratio | Sampling |
|---------|----------|------|-------|-------|----------|
| COMP_BUF_OCC | IIO5 (GPU) | 39.6 T | 21.9 T | 0.55x | ~80% |
| COMP_BUF_INS | IIO5 (GPU) | 14.3 B | 8.5 B | 0.59x | ~78% |
| OUTBOUND_CL | IIO5 (GPU) | 12.6 B | 7.4 B | 0.59x | ~81% |
| OUTBOUND_TLP | IIO5 (GPU) | 17.3 B | 10.2 B | 0.59x | ~82% |
| **ARB_REQ** | **IIO2 (NIC)** | **16.2 B** | **10.7 B** | **0.66x** | **100%** |
| **LOC_P2P** | **IIO2 (NIC)** | **12.7 B** | **8.8 B** | **0.69x** | **100%** |

GPU IIO5 rates scale at ~0.59x, matching the throughput ratio (0.587x). NIC IIO2 rates scale at 0.66-0.69x, indicating **+12-18% more requests per Gbps** for 16 KB -- extra per-work-request overhead (doorbells, CQEs) that scales with WR count, not data volume.

### What This Rules Out

1. **CHA TOR credit exhaustion** -- P2P traffic does not use CHA TOR
2. **Memory controller credit stalls** -- P2P does not touch DRAM
3. **CHA ingress queue congestion** -- not involved in P2P path
4. **Coherency overhead** -- traffic is fully non-coherent

The bottleneck resides in the **IIO-to-IIO non-coherent mesh transport layer**, for which no direct PMU events exist.

---

## Experiment 4: RDMA WRITE vs READ (The Decisive Test)

**Goal:** Isolate the non-posted completion path as the root cause by comparing with posted writes, which do not require completions.

**Setup:** Run both `ib_write_bw` and `ib_read_bw` at 2 MB and 16 KB. Capture IIO counters on **both** nodes (node2 and node7) to observe all four roles: write-sender, write-receiver, read-requester, read-responder.

### Throughput Comparison

| RDMA Operation | 2 MB (Gbps/NIC) | 16 KB (Gbps/NIC) | Degradation |
|----------------|-----------------|------------------|-------------|
| **RDMA READ** | 254 | 148 | **42% drop** |
| **RDMA WRITE** | 254 | 245 | **4% drop** |

16 KB RDMA WRITE barely degrades. 16 KB RDMA READ loses 42% throughput.

### 4-Way Cross-Node IIO Counter Comparison (16 KB)

| | Write Sender | Write Receiver | Read Requester | Read Responder |
|--|-------------|---------------|---------------|---------------|
| **Node** | node7 | node2 | node7 | node2 |
| **NIC operation** | DMA Read from GPU | DMA Write to GPU | DMA Write to GPU | DMA Read from GPU |
| **PCIe transaction type** | Non-posted (MRd+CplD) | Posted (MWr) | Posted (MWr) | Non-posted (MRd+CplD) |
| **Throughput** | **248 Gbps** | 248 Gbps | 147 Gbps | **147 Gbps** |
| COMP_BUF_OCC | **41.2 T** | 4.1 M (idle) | 12.2 B (idle) | **21.9 T** |
| COMP_BUF_INS | **14.8 B** | 6.5 K (idle) | 32.7 M (idle) | **8.5 B** |
| LOC_P2P | **14.3 B** | 2 (idle) | 0 (idle) | **8.8 B** |
| ARB_REQ | **18.2 B** | 356 K (idle) | 246 K (idle) | **10.7 B** |
| OUTBOUND_CL | **14.8 B** | 72 K (idle) | 65.2 M (idle) | **7.4 B** |
| Avg cycles/entry | **2,787** | -- | -- | **2,477** |

Counter descriptions for this table:
- **COMP_BUF_OCC/INS on IIO5**: CplD entries from the GPU queuing in the IIO completion buffer before mesh forwarding. Non-posted sides show trillions of cycle-weighted occupancy; posted sides show noise.
- **LOC_P2P on IIO2**: MRd requests from the NIC targeting a peer device across the mesh. Non-posted sides show billions; posted sides show zero.
- **ARB_REQ on IIO2**: All inbound NIC requests entering the IIO arbitration pipeline. Non-posted sides show billions; posted sides show background noise only.

### Key Observations

**Non-posted sides show massive IIO activity; posted sides show idle.** This pattern holds regardless of whether the operation is READ or WRITE -- what matters is which node's NIC performs the DMA read from GPU.

**Write sender vs read responder** -- both perform the same DMA read from GPU across IIO stacks, but differ in throughput:

| Metric | Write Sender | Read Responder | Ratio |
|--------|-------------|---------------|-------|
| Throughput | 248 Gbps | 147 Gbps | 1.69x |
| Completions/sec | ~493 M/s | ~287 M/s | 1.72x |
| Avg cycles/entry | 2,787 | 2,477 | 1.13x |

The write sender achieves 69% higher throughput because it has **pre-posted WQEs** and can pipeline DMA reads proactively, versus the read responder which reacts to incoming network requests. The sender keeps the completion pipeline more deeply loaded (more completions/sec, slightly higher per-entry latency from deeper queuing).

### Write Receiver-Side Counters (Confirmation)

| Counter | 2 MB WRITE | 16 KB WRITE |
|---------|-----------|------------|
| COMP_BUF_OCC (IIO5) | 3.8 M | 4.1 M |
| COMP_BUF_INS (IIO5) | 6.2 K | 6.5 K |
| LOC_P2P (IIO2) | 0 | 2 |

All at idle/noise levels. Posted writes bypass the completion tracking infrastructure entirely, taking a simpler one-way path through the mesh.

---

## Conclusion

The throughput degradation for small-message cross-IIO RDMA READs is caused by the **non-posted PCIe transaction round-trip** through the IIO completion buffer and mesh fabric.

### The Steady-State Feedback Loop

```
                    tag freed
                   <---------+
                             |
NIC issues MRd  -->  NIC IIO (IIO2)  --[MRd]--->  Mesh  --[MRd]--->  GPU IIO (IIO5)  -->  GPU
(128B, MRRS)         (tag consumed)                                                         |
                                                                                     GPU reads
                                                                                     64B CplD
                                                                                            |
NIC receives    <--  NIC IIO (IIO2)  <-[CplD]---  Mesh  <-[CplD]---  GPU IIO (IIO5)  <-----+
CplD, frees tag                                                       COMP_BUF: ~2.5 us wait
                                                                      (16KB messages)
```

1. The NIC has a finite pool of PCIe tags for outstanding non-posted requests
2. Each MRd TLP (128 bytes, limited by VF MRRS) consumes one tag
3. The tag is held until the CplD returns through the GPU's completion buffer and mesh
4. With 16 KB messages, each CplD spends **~2.5 us** in the completion buffer (vs ~1.6 us for 2 MB)
5. In steady state, the **CplD return rate governs the MRd issue rate**: `Throughput = tags * MRRS / round_trip_latency`

The 52% increase in per-entry residence time (1.6 to 2.5 us) combined with the fixed tag pool produces the observed 42% throughput drop.

### What We Ruled Out

| Hypothesis | Evidence Against |
|------------|-----------------|
| IIO completion buffer saturation | Buffer is **less full** at 16 KB (710 vs 810 entries) |
| CHA mesh congestion | CHA TOR sees 10,000x less traffic than IIO (P2P bypasses CHA) |
| Memory controller stalls | READ_NO_CREDITS = 0; P2P does not touch DRAM |
| Network bottleneck | Same 400G link, same NIC, works fine for writes |
| Posted write path | 16 KB RDMA WRITE: only 4% degradation, zero COMP_BUF activity |

---

## Implications for NIXL and llm-d

### Why NIXL Is Affected

NIXL uses **RDMA READ** for KV cache transfer: the decode server's NIC pulls 16 KB blocks from the prefill server's GPU memory. On the prefill (responder) node, each 16 KB block generates 128 PCIe MRd TLPs (16,384 / 128 bytes MRRS). For a Llama-3.1-70B model at ISL=4096, a single KV transfer involves ~40,960 blocks = **5.2 million PCIe transactions**, all flowing through the non-posted completion path.

When the NIC and GPU are on different IIO stacks, every one of these transactions incurs the mesh round-trip penalty.

### Switching to RDMA WRITE Does Not Eliminate the Problem

If NIXL switched to RDMA WRITE (prefill pushes KV cache to decode), the **sender's NIC must still DMA READ** the scattered 16 KB blocks from the local GPU's memory. The same non-posted MRd + CplD round-trip through the IIO-mesh-IIO pipeline occurs, just on the sender node instead of the responder.

However, Experiment 4 shows the write-sender path achieves **69% higher throughput** (248 vs 147 Gbps) for the same underlying DMA read operation, due to NIC pipelining advantages when initiating from pre-posted WQEs. Whether this advantage holds with 40K+ scattered GPU addresses (vs `ib_write_bw`'s single contiguous buffer) is unknown.

### Viable Mitigations

| Mitigation | Effect | Feasibility |
|------------|--------|-------------|
| **Increase VF MRRS** from 128 to 4096 bytes | Reduces PCIe transaction count by 32x; more data per tag, same round-trip latency | Requires SR-IOV PF driver or firmware changes |
| **Keep GPU-NIC on same IIO stack** | Avoids mesh crossing entirely; P2P stays within PCIe switch | Only feasible when PCIe topology allows co-location |

---

## Reproducing These Results

### Prerequisites

1. Two bare-metal nodes with Intel Sapphire Rapids CPUs and PCIe-attached GPUs + NICs
2. Kubernetes pods deployed with GPU and NIC pass-through (`test-nic-pcie-<IP>`)
3. `pcm-iio` and `perf` available on the physical nodes (not inside pods)
4. `tmux` sessions: one per physical node (named in `scripts/config.sh`)
5. `uv` and `multi_nic_ib_write_bw.py` available on the operator host

### Running

```bash
# Review and edit configuration
vim scripts/config.sh

# Run all experiments (~15 minutes total)
./scripts/run_experiment.sh

# Results are saved to iio-investigation/results/<timestamp>/
```

### Scripts

| Script | Purpose |
|--------|---------|
| `scripts/config.sh` | Shared configuration: node IPs, IIO stacks, perf event specs, paths |
| `scripts/capture_iio_counters.sh` | Launches `perf stat` on a remote node via tmux |
| `scripts/run_bw_test.sh` | Runs a single `ib_read_bw` or `ib_write_bw` test |
| `scripts/run_experiment.sh` | Orchestrates all experiments with interleaved perf capture |

### Test Configurations

| Config | RDMA Op | Message Size | Purpose |
|--------|---------|-------------|---------|
| `configs/read_2MB.json` | READ | 2 MB | Baseline throughput |
| `configs/read_16KB.json` | READ | 16 KB | NIXL-like small messages |
| `configs/write_2MB.json` | WRITE | 2 MB | Write baseline |
| `configs/write_16KB.json` | WRITE | 16 KB | Posted vs non-posted comparison |
