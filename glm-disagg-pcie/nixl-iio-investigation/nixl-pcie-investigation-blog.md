# Why NIXL KV Transfers Are Slow: A PCIe Deep Dive

## Table of Contents

1. [Introduction](#introduction)
2. [What Is an IIO Stack?](#what-is-an-iio-stack)
3. [Test Environment](#test-environment)
4. [The GPU-NIC Placement Problem](#the-gpu-nic-placement-problem)
5. [Narrowing the Gap: Message Size Matters](#narrowing-the-gap-message-size-matters)
6. [Investigating the Prefill-Side PCIe Path](#investigating-the-prefill-side-pcie-path)
7. [IIO Counter Results](#iio-counter-results)
8. [Root Cause: Scattered GPU Memory and the BDP Limit](#root-cause-scattered-gpu-memory-and-the-bdp-limit)
9. [Conclusion and Implications](#conclusion-and-implications)

---

## Introduction

In prefill/decode disaggregated LLM inference, the decode server fetches KV cache
blocks from the prefill server using RDMA READ (via [NIXL](https://github.com/ai-dynamo/nixl)
over UCX). A single KV transfer for a large prompt can consist of tens of thousands
of small (16 KB) blocks scattered across GPU memory. On paper, 400 Gbps
RoCEv2 NICs and PCIe Gen5 x16 links should deliver more than enough bandwidth
for this workload.

In practice, we measured KV transfer throughput of only **~27 Gbps** on bare-metal
nodes with Intel Sapphire Rapids CPUs and AMD MI300X GPUs -- roughly **5.5x below**
what `ib_read_bw` achieves for the same message size with contiguous GPU memory.
Network-side counters showed no congestion, no packet drops, no PFC pauses.
The bottleneck was entirely inside the host.

This post traces that bottleneck from the PCIe topology through Intel IIO performance
counters to its root cause: the GPU's internal memory system responding slowly to
scattered DMA read requests, exhausting the NIC's PCIe tag pool and throttling
throughput via the bandwidth-delay product.

---

## What Is an IIO Stack?

Each Intel Sapphire Rapids socket contains multiple **Integrated I/O (IIO) stacks**.
An IIO stack is a PCIe root complex that manages a group of downstream devices
(GPUs, NICs, NVMe drives). Each IIO stack has its own:

- PCIe link interface to downstream devices
- Transaction processing logic
- **Completion buffer (COMP_BUF)** for tracking non-posted transactions
- Connection to the CPU's internal mesh fabric

The completion buffer is central to this investigation. When a PCIe device (say, a GPU)
returns data in response to a Memory Read request, the data arrives as Completion
with Data (CplD) TLPs. These CplD entries queue in the IIO stack's completion buffer
before being forwarded across the mesh to the requesting device's IIO stack.

```
                    IIO Stack (e.g., GPU's IIO stack)
              ┌──────────────────────────────────────────┐
              │                                          │
  from mesh ──▶  [Outbound logic] ──▶ PCIe downstream    │
  (MRd TLPs) │                        (to GPU)          │
              │                                          │
  to mesh  ◀──  [COMP_BUF] ◀── PCIe upstream            │
  (CplD)      │   ^^^^^^^^       (CplD from GPU)        │
              │   completion buffer:                     │
              │   queues 64-byte CplD entries            │
              │   before forwarding to mesh              │
              └──────────────────────────────────────────┘
```

We can measure both the **occupancy** (how many entries are queued at any moment)
and the **insertion rate** (how many entries arrive per second) of this buffer using
Intel's uncore PMU counters. The ratio gives us the average residence time per entry
-- a direct measure of the mesh crossing latency.

**When NIC and GPU share the same IIO stack**, peer-to-peer traffic stays local
within the PCIe switch -- it never enters the mesh or the completion buffer.
**When they are on different IIO stacks**, every Memory Read must traverse the
full round-trip: MRd across the mesh to the GPU's IIO stack, then CplD back through
the completion buffer and mesh to the NIC's IIO stack.

---

## Test Environment

### Hardware

| Component | Detail |
|-----------|--------|
| CPU | Intel Xeon Platinum 8480+ (Sapphire Rapids), 2 sockets |
| GPU | AMD Instinct MI300X (4 per socket, PCIe Gen5 x16) |
| NIC | NVIDIA ConnectX-7 (4 per socket, 400 Gbps RoCEv2, SR-IOV) |
| IOMMU | Passthrough mode (`iommu=pt` in kernel cmdline) |
| VF MRRS | 128 bytes (SR-IOV Virtual Function Max Read Request Size) |
| PF MRRS | 4096 bytes (Physical Function Max Read Request Size) |

### PCIe Topology

Each socket has 4 IIO stacks. Each IIO stack hosts one GPU and one NIC,
connected via a PCIe switch. Here is the topology for one socket:

```
                          Socket 1
  ┌──────────────────┐  ┌──────────────────┐
  │   IIO Stack 5    │  │  IIO Stack 11    │
  │  (PCIe0, 0x81)   │  │  (PCIe2, 0xa0)   │
  │                  │  │                  │
  │  GPU 0 (8b:00.0) │  │  GPU 1 (aa:00.0) │
  │  NIC  (86:00.1)  │  │  NIC  (a5:00.1)  │
  └──────────────────┘  └──────────────────┘
  ┌──────────────────┐  ┌──────────────────┐
  │   IIO Stack 2    │  │   IIO Stack 7    │
  │  (PCIe4, 0xb8)   │  │  (PCIe1, 0xd0)   │
  │                  │  │                  │
  │  GPU 2 (c2:00.0) │  │  GPU 3 (da:00.0) │
  │  NIC  (bd:00.1)  │  │  NIC  (d5:00.1)  │
  └──────────────────┘  └──────────────────┘
```

Within each IIO stack, GPU and NIC communicate via the local PCIe switch
(zero mesh crossings). Across IIO stacks, traffic must traverse the CPU's
internal mesh (two mesh crossings per RDMA READ: one for MRd, one for CplD).

### Deployment

We deploy one prefill pod (TP=2) and one decode pod (TP=2) on separate nodes,
each running [llm-d](https://github.com/llm-d/llm-d) with
`RedHatAI/Llama-3.3-70B-Instruct-FP8-dynamic`. KV cache transfers use NIXL
over UCX with RDMA READ.

**Experimental methodology:** Each pod requests all 8 GPUs and 8 NICs on its
node. Only 2 GPUs are active for inference, but reserving the full node lets
us control exactly which GPUs and NICs are used via `UCX_NET_DEVICES`. In a
normal production deployment, a TP=2 pod would request only 2 GPUs and 2 NICs,
and Kubernetes would assign whichever are available -- with no guarantee about
their PCIe topology relationship. This is precisely the problem we are studying.

---

## The GPU-NIC Placement Problem

Kubernetes allocates GPUs (via the device plugin) and SR-IOV NIC VFs (via the
SR-IOV device plugin) independently. There is no topology-aware joint allocation.
For a TP=2 pod using GPU 0 and GPU 1 on Socket 1, three representative NIC
placements arise:

| Placement | NICs Used | GPU-NIC Relationship |
|-----------|-----------|----------------------|
| Same-IIO | NIC 0, NIC 1 (IIO5, IIO11) | Each GPU shares its IIO stack with its NIC |
| Cross-IIO | NIC 2, NIC 3 (IIO2, IIO7) | NICs on different IIO stacks than GPUs, same socket |
| Cross-socket | NIC 6, NIC 7 (Socket 0) | NICs on a different socket entirely |

### UCX NIC Selection Behavior

By default, UCX (`UCX_MAX_RMA_RAILS=1`) independently selects the "nearest" NIC
for each GPU rank based on NUMA distance. For the same-IIO placement, each GPU
rank picks its co-located NIC -- the ideal case. But for cross-IIO and cross-socket
placements, both GPU ranks may select the *same* nearest NIC, creating a shared
bottleneck where two GPUs funnel traffic through a single 400G link.

Setting `UCX_MAX_RMA_RAILS=2` forces UCX to stripe traffic across both available
NICs, effectively doubling the available network bandwidth per transfer.

### Throughput Comparison

We measured NIXL KV transfer throughput (ISL=4096, MC=1) and `ib_read_bw` (2 MB
messages) for each placement:

| Placement | Rails | NIXL KV Transfer (Gbps) | ib_read_bw 2MB per NIC (Gbps) |
|-----------|-------|------------------------|-------------------------------|
| Same-IIO | 1 | 355 | 359 |
| Cross-IIO | 1 | 14 | 148 |
| Cross-IIO | 2 | 26 | 252 |
| Cross-socket | 1 | 8.6 | 123 |
| Cross-socket | 2 | 16.5 | 124 |

The same-IIO placement delivers **355 Gbps** -- nearly matching `ib_read_bw`'s
359 Gbps. When GPU and NIC share an IIO stack, there is essentially **no gap**
between NIXL and `ib_read_bw`, even though NIXL still scatters its reads across
40,960 descriptors. This is because same-IIO traffic stays within the local PCIe
switch with no mesh involvement.

Cross-IIO with 2 rails drops to **26 Gbps**, a **13.7x degradation** despite using
the same NICs and GPUs. `ib_read_bw` at 2 MB achieves **252 Gbps** in the same
cross-IIO 2-rail configuration -- nearly **10x** the NIXL throughput. Cross-socket
shows a similar pattern: `ib_read_bw` at 124 Gbps vs NIXL at 16.5 Gbps (**7.5x gap**).

The throughput cliff when moving from same-IIO to cross-IIO tells us the bottleneck
is specifically related to the **mesh crossing path**. The rest of this post
investigates why NIXL performs so poorly compared to `ib_read_bw` in the cross-IIO
case.

---

## Narrowing the Gap: Message Size Matters

The 2 MB `ib_read_bw` test is not a fair comparison. NIXL does not transfer a
single contiguous 2 MB buffer per RDMA operation -- it issues tens of thousands
of individual 16 KB RDMA READs, one per KV cache block.

### Deriving the KV Cache Block Size

For `Llama-3.3-70B-Instruct-FP8-dynamic` with TP=2:

- 8 GQA KV heads total, 128 head dimension, FP16 KV cache
- vLLM `block_size=16` tokens
- Per TP rank: `8 / 2 = 4` KV heads
- Each K or V block: `16 tokens × 4 heads × 128 dim × 2 bytes = 16,384 bytes = 16 KB`
- K and V are separate descriptors, so each is a 16 KB RDMA READ

For ISL=4096:
- Blocks per layer: `2 (K+V) × (4096 / 16 tokens) = 512`
- Total descriptors: `512 × 80 layers = 40,960`, each 16 KB
- Total transfer size: `40,960 × 16 KB ≈ 640 MB`

### ib_read_bw at 16 KB

Running `ib_read_bw` with 16 KB messages, VF NICs, GPU memory, and the same
cross-IIO topology gives **~148 Gbps per NIC**. This is significantly lower than
the 252 Gbps at 2 MB, which is expected: smaller messages mean more PCIe
round-trips per byte transferred, and the non-posted completion overhead
dominates.

| Workload | Throughput per NIC (Gbps) |
|----------|--------------------------|
| NIXL KV transfer (ISL=4096, cross-IIO, 2 rails) | ~27 |
| `ib_read_bw` (2 MB, contiguous GPU memory) | ~252 |
| `ib_read_bw` (16 KB, contiguous GPU memory) | ~148 |

The 2 MB to 16 KB drop (252 → 148 Gbps) is the cost of smaller messages on the
non-posted completion path. But the **5.5x gap** between `ib_read_bw` at 16 KB
(148 Gbps) and NIXL (27 Gbps) remains unexplained. Both use:

- The same VF NICs (MRRS = 128 bytes)
- The same GPUs
- The same cross-IIO topology
- The same 16 KB transfer granularity

The only difference: `ib_read_bw` reads from a single contiguous GPU buffer.
NIXL reads 40,960 scattered 16 KB blocks from random locations in GPU memory.

---

## Investigating the Prefill-Side PCIe Path

In an RDMA READ, the **decode** node's NIC initiates the request, but the data
transfer happens on the **prefill** node: the prefill's NIC performs DMA reads
from the prefill's GPU memory and sends the data back over the network. The
prefill node is the RDMA READ responder.

NIC counters on the decode node (the requester) show no anomalies -- the NIC
receives data at whatever rate the prefill can supply, with no PFC pauses or
packet drops. The bottleneck is on the prefill side.

### The Prefill-Side Data Path

On the prefill node, in the cross-IIO configuration, the NIC and GPU reside
on different IIO stacks. When the NIC's RNIC hardware processes an incoming
RDMA READ request, it issues PCIe Memory Read (MRd) TLPs to fetch data from
GPU memory. These MRd TLPs must cross the CPU mesh to reach the GPU's IIO stack:

```
              Prefill Node (RDMA READ responder)
  ┌──────────────────────────────────────────────────────┐
  │                                                      │
  │  NIC                                  GPU 0          │
  │  IIO Stack 2                          IIO Stack 5    │
  │  ┌──────────────┐               ┌──────────────┐    │
  │  │              │ ① MRd (mesh)  │ [Outbound]   │    │
  │  │  NIC issues  │──────────────▶│  ──▶ GPU     │    │
  │  │  MRd TLPs    │              │              │    │
  │  │              │ ② CplD (mesh) │ [COMP_BUF]   │    │
  │  │  NIC receives│◀──────────────│  ◀── GPU     │    │
  │  │  CplD data   │              └──────┬───────┘    │
  │  └──────────────┘                     │            │
  │         ▲                             ▼            │
  │         │                      ┌──────────┐        │
  │         │                      │ GPU HBM  │        │
  │         │                      │ (memory) │        │
  │         │                      └──────────┘        │
  └─────────│──────────────────────────────────────────┘
            │
            ▼ ③ Data sent over network to decode node
```

The full sequence for each 16 KB NIXL descriptor:

1. The NIC issues MRd TLPs (128 bytes each, limited by VF MRRS=128B) into
   the NIC's IIO stack (IIO2)
2. IIO2 forwards MRd across the CPU mesh to the GPU's IIO stack (IIO5)
3. IIO5 forwards MRd downstream to the GPU via PCIe
4. The GPU reads the requested data from HBM and returns CplD TLPs upstream
5. CplD entries queue in the GPU IIO stack's **COMP_BUF**
6. COMP_BUF forwards CplD across the mesh back to IIO2
7. IIO2 delivers CplD to the NIC
8. The NIC packetizes the data and sends it over the network

### Measurement Points

Using `perf stat` with Intel IIO PMU raw events, we can observe:

| IIO Stack | Event | What It Measures |
|-----------|-------|-----------------|
| GPU (IIO5) | `COMP_BUF_OCCUPANCY` (0xd5/0xff) | Cycle-weighted CplD entries in the completion buffer |
| GPU (IIO5) | `COMP_BUF_INSERTS` (0xc2/0x04) | Total 64-byte CplD entries inserted |
| GPU (IIO5) | `OUTBOUND_CL_REQS` (0xd0/0x08) | MRd requests forwarded to the GPU |
| NIC (IIO2) | `INBOUND_ARB_REQ` (0x86/0x08) | MRd requests entering from the NIC |
| NIC (IIO2) | `LOC_P2P` (0x8e/0x20) | Requests targeting a peer IIO stack |

The key metric is `COMP_BUF_OCCUPANCY / COMP_BUF_INSERTS`, which gives the
average number of IIO clock cycles each CplD entry spends in the GPU's
completion buffer -- a direct measure of the mesh crossing latency.

---

## IIO Counter Results

We captured IIO counters during three workloads on the prefill node:
`ib_read_bw` at 2 MB, `ib_read_bw` at 16 KB, and NIXL KV transfers at
ISL=4096 and ISL=8192 (all cross-IIO, 2-rail configuration).

For NIXL workloads, the transfers are bursty (each transfer takes ~200 ms,
separated by idle inference periods). We apply duty-cycle correction using
wire-level active time measured from NIC counter profiling to derive the
effective rates during active transfer periods.

### Results Table

| Workload | COMP_BUF_INS/s (per GPU stack) | COMP_BUF Gbps | Residence (cycles) | Residence (us) | Throughput/NIC |
|----------|-------------------------------|---------------|-------------------|----------------|----------------|
| `ib_read_bw` 2MB | 496 M | 254 | 1,631 | 0.68 | 254 Gbps |
| `ib_read_bw` 16KB | 287 M | 147 | 2,479 | 1.03 | 148 Gbps |
| NIXL ISL=4096 | 58 M | 30 | 2,369 | 0.99 | 27 Gbps |
| NIXL ISL=8192 | 52 M | 27 | 2,618 | 1.09 | 27 Gbps |

**COMP_BUF Gbps** is computed as `COMP_BUF_INS/s × 64 bytes × 8 bits/byte`.
**Residence (us)** uses the uncore mesh clock at ~2.4 GHz (see note below).

> **Note on IIO clock frequency:** IIO programmable PMU events (COMP_BUF_OCCUPANCY,
> COMP_BUF_INSERTS) use the **uncore/mesh clock**, not the `ioclk` free-running
> counter. The `uncore_iio_free_running/ioclk` counter runs at a fixed ~45 MHz
> reference rate unrelated to the event clock. The actual uncore frequency is
> dynamic: ~1.6 GHz at idle, ramping to **~2.4 GHz** under PCIe workloads (measured
> via PCM's `UncFREQ` on this Xeon Platinum 8480+). At 2.4 GHz, the 16KB
> cross-IIO residence of 2,479 cycles converts to **1.03 us**, which matches
> the ~1.0 us mesh crossing overhead measured independently via
> `ib_read_bw --outstanding` sweeps (cross-IIO RTT 10.71 us − same-IIO RTT
> 9.71 us = 1.0 us).

### Key Findings

**1. COMP_BUF throughput matches NIC throughput exactly.**

Across all four workloads, the completion buffer insertion rate (converted to
Gbps) matches the measured NIC throughput. The GPU's IIO stack faithfully
reflects the upstream data rate -- it introduces no additional bottleneck.

**2. Residence time is constant (~2,400 cycles for cross-IIO).**

Whether the workload is delivering 254 Gbps or 27 Gbps, each 64-byte CplD
entry spends roughly the same amount of time in the completion buffer. The
per-packet cost of crossing the mesh is constant. The IIO stack and mesh
are not congested -- they simply process whatever CplD traffic arrives at
the same per-entry rate.

**3. The COMP_BUF insertion rate is 5x lower for NIXL.**

NIXL produces CplD data at only 58 M entries/s versus 287 M/s for `ib_read_bw`
at 16 KB. Since the per-entry processing time is the same, fewer entries are
arriving at the GPU's IIO stack per unit time. The GPU is responding to MRd
requests at 1/5th the rate -- not because the IIO stack is slower, but because
the GPU's internal memory system takes longer to service each request.

**4. ISL scaling is linear at constant throughput.**

NIXL at ISL=8192 takes exactly twice as long as ISL=4096 (397 ms vs 199 ms)
while maintaining the same throughput (~27 Gbps). The COMP_BUF insertion rate
barely changes (52 M/s vs 58 M/s). This confirms a **fixed concurrency window**:
only a handful of KV blocks are in flight at any time. Doubling the total work
simply doubles the total time.

---

## Root Cause: Scattered GPU Memory and the BDP Limit

### The Two-Segment Model

The end-to-end PCIe round-trip for each MRd/CplD pair can be decomposed into
two segments:

```
NIC ─── IIO(NIC) ═══ mesh ═══ IIO(GPU) ─── GPU MMU ─── HBM
        │                      │               │          │
        └────  Segment 1 ──────┘               └── Seg 2 ─┘
          (PCIe + mesh crossing)           (GPU memory access)
              SAME for both                    DIFFERENT
          contiguous & scattered           contiguous vs scattered
```

**Segment 1 (NIC IIO → mesh → GPU IIO):** This is the PCIe and mesh crossing
latency. We measured it directly via the COMP_BUF residence time: ~2,400 uncore
cycles (~1.0 us at 2.4 GHz), constant across all workloads. The host IOMMU is in passthrough mode
(`iommu=pt`), so host-side address translation is not a factor. P2P traffic
takes a direct IIO-to-IIO mesh path that bypasses the CHA coherency engine
(verified by CHA TOR counters showing 10,000x less traffic than IIO).

We also measured the mesh crossing overhead independently using
`ib_read_bw --outstanding` sweeps at 16 KB with VF + GPU memory:

| Config | --outstanding=1 BW (Gbps) | RTT per 16 KB read (us) |
|--------|--------------------------|------------------------|
| Cross-IIO | 12.24 | 10.71 |
| Same-IIO | 13.50 | 9.71 |
| **Difference (mesh crossing)** | | **~1.0 us** |

The ~1.0 us mesh crossing overhead is consistent with the COMP_BUF residence
time of ~1.03 us (2,479 uncore cycles at ~2.4 GHz). At higher outstanding
counts, throughput scales linearly
until saturating at 148 Gbps (cross-IIO) and 197 Gbps (same-IIO) at
`--outstanding=16`.

**Segment 2 (GPU IIO → GPU internal MMU → HBM → back):** This is the GPU's
internal memory access time. It is invisible to CPU-side IIO counters, but its
effect is directly observable: the reduced COMP_BUF insertion rate for NIXL
means fewer CplD entries arrive from the GPU per unit time.

- **Contiguous access** (`ib_read_bw`): sequential addresses, warm GPU TLB,
  HBM row buffer hits → fast per-MRd response
- **Scattered access** (NIXL): 40,960 random GPU virtual addresses, GPU IOTLB
  thrashing, random HBM row activations → slow per-MRd response

### Tag Pool Exhaustion (Little's Law)

The NIC has a finite pool of PCIe tags for tracking outstanding non-posted
(MRd) requests. Each MRd TLP consumes one tag, which is held until the
corresponding CplD returns. The throughput is governed by Little's Law:

```
Throughput = Tag_pool_size_bytes / RTT_per_MRd
```

The tag pool is fixed hardware. The `--outstanding` sweep confirms the NIC
sustains up to 16 concurrent outstanding reads per QP. When Segment 2 latency
increases -- as it does for scattered GPU memory access -- the total round-trip
time per MRd increases proportionally. With a fixed concurrency window, the
throughput drops by the same factor.

### Quantifying the Inflation

From `ib_read_bw --outstanding=1` at 16 KB (contiguous GPU memory):
- Cross-IIO RTT: **10.71 us**

For NIXL at the same 16 KB, with 5.5x lower throughput, the effective RTT
must be ~5.5x higher:
- Estimated NIXL RTT: **~59 us**

Since Segment 1 is constant (~1 us for the mesh crossing), the difference
is entirely in Segment 2:

| Component | ib_read_bw (contiguous) | NIXL (scattered) | Ratio |
|-----------|------------------------|-------------------|-------|
| Segment 1 (mesh crossing) | ~1 us | ~1 us | 1x |
| Segment 2 (GPU memory) | ~9.7 us | ~58 us | ~6x |
| **Total RTT** | **10.7 us** | **~59 us** | **~5.5x** |

The GPU's internal memory access latency inflates by ~6x when servicing
scattered 16 KB reads versus sequential contiguous reads. This 6x
Segment 2 inflation, combined with the fixed PCIe tag pool, produces the
observed 5.5x throughput degradation.

### The Steady-State Feedback Loop

The system reaches a closed-loop equilibrium:

```
            tag freed
           ◀─────────────────────────────────────────────────────┐
           │                                                     │
NIC issues ──▶ NIC IIO ──[MRd]──▶ Mesh ──[MRd]──▶ GPU IIO ──▶ GPU
MRd (128B)    (tag consumed)                                     │
                                                          GPU reads from
                                                          scattered HBM
                                                          (SLOW: ~58 us)
                                                                 │
NIC receives ◀── NIC IIO ◀──[CplD]── Mesh ◀──[CplD]── GPU IIO ◀─┘
CplD, frees tag                        COMP_BUF: ~2.4 us
                                       (constant, not the bottleneck)
```

1. The NIC initially issues MRd TLPs at full rate, filling its tag pool
2. The GPU takes ~58 us to respond to each scattered read (vs ~10 us for contiguous)
3. The NIC's tag pool fills up -- it cannot issue new MRd TLPs until tags are freed
4. In steady state, the NIC's MRd issue rate equals the GPU's CplD response rate
5. For each CplD the NIC gets back, it frees a tag and issues one new MRd
6. Throughput is entirely governed by how fast the GPU can respond: `Throughput = tags × MRRS / RTT`

The COMP_BUF residence time (~2,400 cycles) is a small, constant fraction of
the total RTT. The mesh and IIO stacks are not the bottleneck. The GPU's
internal memory system is.

---

## Conclusion and Implications

### What We Found

The 5.5x throughput gap between `ib_read_bw` (148 Gbps) and NIXL KV transfer
(27 Gbps) at 16 KB message size is caused entirely by the **GPU memory access
pattern**. NIXL's 40,960 scattered 16 KB descriptors force the GPU to service
random HBM accesses with poor TLB and row buffer locality, inflating the
per-request response time by ~6x compared to contiguous access.

### What We Ruled Out

| Hypothesis | Evidence Against |
|------------|-----------------|
| IIO completion buffer saturation | Buffer is less occupied for NIXL than for `ib_read_bw` |
| CPU mesh congestion | Per-entry residence time is identical across all workloads |
| CHA coherency overhead | P2P traffic bypasses CHA entirely (10,000x less CHA traffic) |
| VF MRRS limitation (128B) | `ib_read_bw` with VF (MRRS=128B) + GPU at 16KB achieves 148 Gbps, identical to PF (MRRS=4096B) results. VF MRRS cannot be changed: `setpci` writes are silently dropped even from the host -- ConnectX-7 firmware controls VF DevCtl. |
| Network congestion | Zero PFC pauses, no drops on decode-side NIC counters |
| NIC fan-out contention | Only 2 GPUs active, same topology as `ib_read_bw` |

### Key Takeaway

**Synthetic benchmarks like `ib_read_bw` do not reflect real application
transfer performance.** `ib_read_bw` reads from a single contiguous GPU buffer,
which is the best case for GPU DMA. Real workloads like NIXL scatter KV cache
blocks across GPU memory, and the resulting GPU memory access latency dominates
PCIe throughput via the bandwidth-delay product. The 148 Gbps that `ib_read_bw`
reports at 16 KB is unattainable in practice for scattered transfers.

### Potential Mitigations

| Mitigation | Expected Effect |
|------------|----------------|
| **Contiguous KV allocation** | Reduce scatter; approach `ib_read_bw` contiguous performance |
| **Larger vLLM block size** | Fewer, larger descriptors; better GPU memory locality |
| **Descriptor coalescing** | Merge adjacent blocks into larger RDMA READs |
| **Increase VF MRRS** | Unlikely to help: PF (MRRS=4096B) matches VF (128B) for contiguous access; VF MRRS locked by firmware |
| **Same-IIO GPU-NIC placement** | Eliminate mesh crossing entirely (355 Gbps observed) |
| **Topology-aware K8s scheduling** | Ensure GPU-NIC co-location when assigning SR-IOV VFs |

### Open Questions

- **VF MRRS is locked at 128B** and cannot be changed: `setpci` writes to the
  VF DevCtl register are silently dropped both from within the pod and from
  the host -- the ConnectX-7 firmware controls VF config space. Changing it
  would require a firmware configuration change or kernel driver patch (mlx5
  `pci_set_readrq`). Note: `ib_read_bw` with PF NICs (MRRS=4096B) achieves
  the same throughput as VF NICs (MRRS=128B) for contiguous GPU memory,
  so MRRS is unlikely to be the bottleneck for scattered access either.
  The GPU memory access latency dominates regardless of MRRS.
- The IIO programmable event clock is the dynamic uncore/mesh frequency (~2.4 GHz
  under load on this SKU), not the `ioclk` free-running counter (~45 MHz reference).
  How does uncore frequency scaling affect IIO counter accuracy in bursty workloads?
- Is there a way to increase the NIC-side PCIe tag pool or otherwise increase
  the concurrency window for outstanding DMA reads? Increasing MRRS is one
  approach: larger read requests mean more bytes in flight per tag, effectively
  increasing the bandwidth-delay product for a fixed tag count. However, as
  noted above, VF MRRS is locked by firmware, and PF-level MRRS=4096B already
  shows no improvement for contiguous access.
- Would switching to RDMA WRITE (prefill pushes) help? The sender's NIC still
  performs DMA reads from GPU memory, but the write-sender path achieves 69%
  higher throughput in `ib_write_bw` vs `ib_read_bw` at 16 KB (248 vs 148 Gbps)
  due to NIC pipelining advantages with pre-posted WQEs.
