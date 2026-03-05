# Why NIXL KV Transfers Are Slow: A PCIe Deep Dive

## Table of Contents

1. [Introduction](#introduction)
2. [What Is an IIO Stack?](#what-is-an-iio-stack)
3. [Test Environment](#test-environment)
4. [The GPU-NIC Placement Problem](#the-gpu-nic-placement-problem)
5. [Narrowing the Gap: Message Size Matters](#narrowing-the-gap-message-size-matters)
6. [Investigating the Prefill-Side PCIe Path](#investigating-the-prefill-side-pcie-path)
7. [IIO Counter Results](#iio-counter-results)
8. [Two Hypotheses for the Low Insertion Rate](#two-hypotheses-for-the-low-insertion-rate)
9. [Validation: Custom RDMA Scatter Benchmark](#validation-custom-rdma-scatter-benchmark)
10. [Investigating the NIXL/UCX Software Stack](#investigating-the-nixlucx-software-stack)
11. [Wire-Level NIC Counter Profiling](#wire-level-nic-counter-profiling)
12. [Conclusion and Next Steps](#conclusion-and-next-steps)

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

This post traces that bottleneck from PCIe topology through Intel IIO performance
counters to its root cause. Our initial hypothesis -- that scattered GPU memory
access was inflating DMA read latency -- was debunked by a custom RDMA benchmark
that achieved **~137 Gbps** with the same scattered access pattern. The real
bottleneck is in the **NIXL/UCX software stack**, which does not load the NIC's
RDMA READ pipeline with enough outstanding requests to fill the bandwidth-delay
product across the cross-IIO mesh path.

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

The apparent differences: `ib_read_bw` reads from a single contiguous GPU buffer
and uses the low-level `libibverbs` API directly. NIXL reads 40,960 scattered
16 KB blocks from random locations in GPU memory, going through the UCX
software stack. Which of these differences explains the 5.5x gap?

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
at 16 KB. Since the per-entry processing time is the same, fewer CplD entries
are arriving at the GPU's IIO stack per unit time. Either the NIC is issuing
fewer MRd requests (software pipeline underloaded), or the GPU is responding
more slowly to each request (scattered memory access). The next section
investigates which explanation is correct.

**4. ISL scaling is linear at constant throughput.**

NIXL at ISL=8192 takes exactly twice as long as ISL=4096 (397 ms vs 199 ms)
while maintaining the same throughput (~27 Gbps). The COMP_BUF insertion rate
barely changes (52 M/s vs 58 M/s). This confirms a **fixed concurrency window**:
only a handful of KV blocks are in flight at any time. Doubling the total work
simply doubles the total time.

---

## Two Hypotheses for the Low Insertion Rate

The COMP_BUF insertion rate for NIXL is 5x lower than `ib_read_bw` at 16 KB
(58 M/s vs 287 M/s), while the per-entry residence time is identical. This
means fewer CplD entries arrive at the GPU's IIO stack per unit time. There
are two possible explanations:

**Hypothesis 1: GPU memory scatter inflates DMA read latency.** NIXL's 40,960
scattered 16 KB reads hit random GPU virtual addresses, causing IOTLB thrashing
and random HBM row activations. Each MRd takes longer to complete, the NIC's
PCIe tag pool fills up, and the NIC cannot issue new MRd TLPs until tags are
freed. The system reaches a steady state where the MRd issue rate equals the
GPU's slow CplD response rate.

**Hypothesis 2: Software does not load the read pipeline.** The NIXL/UCX
software stack does not issue enough concurrent RDMA READ operations to keep
the NIC's pipeline full. The NIC's tag pool never fills up -- it simply has
fewer MRd TLPs in flight because the software hasn't posted them. The GPU
responds fine; it just receives fewer requests.

Both hypotheses produce the same observable: fewer CplD entries per second in
the COMP_BUF, with the same per-entry residence time. The IIO counters alone
cannot distinguish between them.

### The BDP Framework

Regardless of which hypothesis is correct, the throughput is governed by the
bandwidth-delay product:

```
Throughput = Data_in_flight / Round_trip_time
```

The end-to-end PCIe round-trip for each MRd/CplD pair decomposes into two
segments:

```
NIC ─── IIO(NIC) ═══ mesh ═══ IIO(GPU) ─── GPU MMU ─── HBM
        │                      │               │          │
        └────  Segment 1 ──────┘               └── Seg 2 ─┘
          (PCIe + mesh crossing)           (GPU memory access)
```

**Segment 1 (NIC IIO → mesh → GPU IIO):** The PCIe and mesh crossing
latency, measured directly via the COMP_BUF residence time: ~2,400 uncore
cycles (~1.0 us at 2.4 GHz), constant across all workloads. The host IOMMU is
in passthrough mode (`iommu=pt`), and P2P traffic takes a direct IIO-to-IIO
mesh path that bypasses the CHA coherency engine (verified by CHA TOR counters
showing 10,000x less traffic than IIO).

We measured the mesh crossing overhead independently using
`ib_read_bw --outstanding` sweeps at 16 KB with VF + GPU memory:

| Config | --outstanding=1 BW (Gbps) | RTT per 16 KB read (us) |
|--------|--------------------------|------------------------|
| Cross-IIO | 12.24 | 10.71 |
| Same-IIO | 13.50 | 9.71 |
| **Difference (mesh crossing)** | | **~1.0 us** |

At higher outstanding counts, throughput scales linearly until saturating at
148 Gbps (cross-IIO) and 197 Gbps (same-IIO) at `--outstanding=16`.

**Segment 2 (GPU IIO → GPU internal → HBM → back):** The GPU's internal
memory access time. Invisible to CPU-side IIO counters, but its effect is
observable through the insertion rate. Under Hypothesis 1, scattered access
inflates Segment 2 latency. Under Hypothesis 2, Segment 2 latency is normal
but fewer MRd requests arrive to begin with.

To distinguish the hypotheses, we need a controlled experiment that isolates
the scatter pattern from the software stack.

---

## Validation: Custom RDMA Scatter Benchmark

We built a custom RDMA READ benchmark (`rdma_scatter_bench.cpp`) that uses raw
`libibverbs` to replicate NIXL's exact scatter pattern while bypassing the
NIXL/UCX software stack entirely. This isolates the hardware path: if
scattered reads are inherently slow, the benchmark will show the same
throughput degradation regardless of the software stack.

### Benchmark Design

The benchmark allocates a large GPU memory pool via `hipMalloc`, registers it
as a single IB memory region, then issues 40,960 individual 16 KB RDMA READs
to randomly scattered offsets within the pool -- matching NIXL's descriptor
count and access pattern exactly.

Key parameters (vs UCX defaults):

| Parameter | `rdma_scatter_bench` | UCX default |
|-----------|---------------------|-------------|
| SQ depth | 8,192 | 256 |
| CQ depth | 16,384 | 4,096 |
| Signal every | 512 WQEs | 64 WQEs |
| `max_rd_atomic` | 16 | 4 |
| Posting style | Tight post/poll loop | Progress-based |

The benchmark posts WQEs and polls completions in a tight interleaved loop,
keeping the NIC's pipeline full at all times. This represents the maximum
throughput achievable on the hardware path.

### Results

| Mode | Pool Size | Throughput (Gbps) |
|------|-----------|-------------------|
| Contiguous | 2 GB | 137-139 |
| Scattered | 2 GB | 137-138 |
| Contiguous | 6 GB | 139 |
| Scattered | 6 GB | 137 |
| `ib_read_bw` 16KB (reference) | N/A | 148 |
| **NIXL KV transfer** | **~50+ GB** | **~27** |

**Scattered and contiguous memory access give identical throughput at ~137 Gbps.**
The MI300X GPU memory system handles random 16 KB DMA reads across a 6 GB
pool just as efficiently as sequential contiguous ones. The scatter pattern is
NOT the bottleneck.

The ~137 Gbps is slightly below `ib_read_bw`'s 148 Gbps due to per-WQE posting
overhead in our custom benchmark vs `ib_read_bw`'s highly optimized path. But
it is **5x higher** than NIXL's 27 Gbps.

### Hypothesis 1 Debunked

This result definitively rules out Hypothesis 1 (GPU memory scatter). The
scatter bench achieves near-line-rate throughput with the exact same scatter
pattern that NIXL uses. The GPU responds just as quickly to scattered reads
as to contiguous ones -- the COMP_BUF insertion rate difference we observed
for NIXL is not caused by the GPU's memory system.

**Therefore, Hypothesis 2 is correct: the NIXL/UCX software stack does not load
the NIC's RDMA READ pipeline with enough outstanding requests to fill the
bandwidth-delay product.** The NIC's tag pool has capacity, the GPU is fast
enough, but the software doesn't issue MRd requests quickly enough to keep the
pipeline full.

---

## Investigating the NIXL/UCX Software Stack

With the hardware path ruled out, we turn to the software. NIXL uses UCX's
UCP layer (via the `libplugin_UCX.so` plugin) for RDMA transfers. Each of the
40,960 KV cache block descriptors becomes a `ucp_get_nb` call, which UCX
translates into an IB verbs RDMA READ work request.

### UCX RC Transport Defaults

We examined the UCX v1.12 source code to identify the RC transport parameters
that control the RDMA READ pipeline. The defaults are conservative:

| Parameter | UCX Default | `rdma_scatter_bench` | Effect |
|-----------|------------|---------------------|--------|
| `UCX_RC_TX_QUEUE_LEN` | **256** | 8,192 | NIC Send Queue depth per QP |
| `UCX_RC_TX_MAX_BATCH` | **16** | N/A (raw verbs) | WQEs batched per doorbell ring |
| `UCX_RC_TX_CQ_MODERATION` | **64** | 512 | WQEs per signaled completion |
| `UCX_RC_MAX_RD_ATOMIC` | **4** | 16 | Outstanding RDMA READs per QP |
| `UCX_RC_TX_NUM_GET_BYTES` | **inf** | N/A | Max outstanding GET bytes (no limit) |
| `UCX_RC_TX_CQ_LEN` | **4,096** | 16,384 | Completion Queue length |

With the default SQ depth of 256, UCX must cycle through the Send Queue ~160
times for 40,960 descriptors, ringing the NIC doorbell every 16 WQEs (2,560
doorbell rings per transfer). Our scatter bench uses a 8,192-deep SQ and
signals only every 512 WQEs.

### UCX Tuning Experiments

We systematically tuned each parameter on the live NIXL deployment (applied
to both prefill and decode pods, verified via `kubectl exec -- env`):

**Experiment 1: `UCX_RC_MAX_RD_ATOMIC=16`**

Increases the per-QP outstanding RDMA READ limit from 4 to 16, matching
our scatter bench. With 2 rails (`UCX_MAX_RMA_RAILS=2`), this allows
32 concurrent RDMA READs across both NICs.

Result: **~27 Gbps** -- no improvement.

**Experiment 2: Full transport tuning**

Applied all parameters simultaneously:
- `UCX_RC_TX_QUEUE_LEN=4096` (16x increase in SQ depth)
- `UCX_RC_TX_MAX_BATCH=64` (4x increase in doorbell batching)
- `UCX_RC_TX_CQ_MODERATION=256` (4x reduction in CQ signaling)
- `UCX_RC_MAX_RD_ATOMIC=16` (4x increase in outstanding READs)

Result: **~27 Gbps** -- still no improvement.

**Experiment 3: `UCX_RC_TX_POLL_ALWAYS=y`**

Forces UCX to poll TX completions on every `ucp_worker_progress()` call
(default skips TX polling if RX completions are found first).

Result: **~27 Gbps** -- no improvement.

### Source Code Analysis: Where the Pipeline Stalls

To understand why transport-level tuning has no effect, we examined the NIXL
and UCX source code. The analysis reveals the bottleneck is in the
descriptor posting pattern and UCX's internal pending queue management.

**NIXL posting path** (`src/plugins/ucx/ucx_backend.cpp`):

```
postXfer → sendXferRange → sendXferRangeBatch → ep.read() → ucp_get_nbx()
```

`sendXferRangeBatch` posts all 40,960 descriptors in a tight loop with **no
`ucp_worker_progress()` calls between iterations**. The entire batch is posted
before any completions are processed.

**UCX internal behavior when the SQ fills:**

When the Send Queue fills up (at entry #256 with default `TX_QUEUE_LEN`), UCX
returns `UCS_ERR_NO_RESOURCE` and adds the operation to an internal **pending
queue** via `uct_ep_pending_add()`. The remaining ~40,704 descriptors each
take this fast path (~100 ns for pending_add vs ~300 ns for a successful post).

The critical bottleneck is in how the pending queue drains:
`ucp_worker_progress()` calls `ucs_arbiter_dispatch(..., per_group=1)`, which
dispatches **at most 1 pending operation per RC endpoint per progress call**.
Even when 64 SQ credits are freed at once (due to `TX_CQ_MODERATION=64`), the
arbiter only posts 1 new WQE per endpoint per iteration.

**The pipeline stall pattern:**

```
Phase 1: Burst posting (~4 ms)
  ├─ First 256 ucp_get_nbx → succeed (fill SQ)
  ├─ Next 40,704 ucp_get_nbx → UCS_ERR_NO_RESOURCE → pending queue
  └─ NIC processes initial 256 WQEs in ~160 μs, then sits IDLE for ~3.8 ms

Phase 2: Progress draining
  ├─ NIXL calls status() → while(worker->progress());
  ├─ Each progress(): poll CQ (batch of 64 credits) + dispatch 1 pending/EP
  └─ ~20,352 progress iterations needed to drain 40,704 pendings (2 EPs)
```

During Phase 1, the NIC finishes its initial 256 WQEs in ~160 μs (with
`max_rd_atomic=16`, 256 WQEs / 16 concurrent = 16 batches × ~10 μs each).
The NIC then waits idle for ~3.8 ms while the software continues adding
to the pending queue. This explains why increasing the SQ depth or
`max_rd_atomic` has no effect: the software pipeline, not the hardware
pipeline, is the bottleneck.

**Progress threading:** When NIXL's progress thread is enabled, it uses
`poll()` with a minimum 1 ms timeout between progress bursts. This introduces
additional idle gaps. When inline progress is used (the default for
`checkXfer()`), the tight `while(progress())` loop is faster but still
constrained by the 1-pending-per-EP-per-call arbiter limit.

---

## Wire-Level NIC Counter Profiling

To move beyond IIO-level inference and directly measure the NIC's behavior, we
built a high-fidelity NIC counter poller (`poll_nic_counters.cpp`) that reads
InfiniBand `port_xmit_data` (TX) and `port_rcv_data` (RX) counters via sysfs
at maximum frequency (no sleep between reads, ~5 μs per sample). This captures
the time-series throughput profile of each VF NIC inside the decode pod during
NIXL KV transfers.

### Methodology

The poller runs inside the decode pod (where the VF counters reflect per-VF
traffic), capturing timestamped TX and RX byte counts for both NICs (mlx5_12,
mlx5_13) simultaneously. We run a short e2e benchmark (50 prompts, MC=1) and
collect traces spanning the full benchmark duration.

For the decode side of an RDMA READ:
- **TX** = outgoing RDMA READ request packets (MRd). These are small packets
  (~146 bytes on the wire, consisting of BTH + RETH headers).
- **RX** = incoming completion data (CplD). Each 16 KB KV block arrives as
  a stream of RX bytes.

### NIXL Throughput Profile

The NIC counter traces reveal a striking pattern: NIXL's throughput per NIC
is **flat at ~27 Gbps** across every transfer burst, with no visible ramp-up,
stalls, or inter-transfer gaps.

| NIC | TX Rate (Gbps) | RX Rate (Gbps) | WR Rate (WRs/sec) | TX per WR (bytes) |
|-----|---------------|----------------|-------------------|--------------------|
| mlx5_12 | 0.240 | 26.9 | 205,452 | 146 |
| mlx5_13 | 0.239 | 26.8 | 204,698 | 146 |

Both NICs show identical behavior across all ~25 transfer bursts, with
WR rates stable to within 1%.

### WR Rate Derivation

The Work Request (WR) posting rate is derived from the TX byte counter:

1. **Total TX bytes per burst**: measured directly from `port_xmit_data` delta
2. **Total blocks per burst**: `RX_bytes / 16,384` (each 16 KB block = one RDMA READ)
3. **TX bytes per WR**: `TX_bytes / total_blocks` = ~146 bytes (consistent with
   RDMA READ request packet: 12B BTH + 28B RETH + headers + padding)
4. **WR rate**: `total_blocks / burst_duration`

Cross-check: `205,452 WRs/sec × 16,384 bytes/WR × 8 bits/byte = 26.9 Gbps`,
which matches the RX rate exactly. The NIC is receiving data at exactly the
rate predicted by its outgoing request rate.

### The Constant Rate Confirms a Software Bottleneck

The flat throughput profile is the key evidence. If the NIC were starved
by GPU memory latency (Hypothesis 1), we would expect variable throughput
with stalls or a ramp-up/ramp-down pattern as the NIC's tag pool fills and
drains. Instead, the NIC receives a perfectly steady stream of work at
~205K WRs/sec -- the rate at which UCX's progress loop drains the pending
queue through the `per_group=1` arbiter.

### Comparison with rdma_scatter_bench

To calibrate what the hardware is capable of, we ran `rdma_scatter_bench`
in a multi-instance configuration that faithfully reproduces NIXL's TP=2,
rails=2 topology: 4 concurrent instances (2 GPUs × 2 NICs on decode, each
reading from the corresponding GPU on prefill), with barrier synchronization
to ensure simultaneous start.

**Multi-instance scatter_bench (TP=2, rails=2 topology):**

| Instance | Per-Instance Gbps | Notes |
|----------|------------------|-------|
| GPU0/mlx5_3 | 114-125 | First transfer slow (~9.7 Gbps, ATC cold) |
| GPU0/mlx5_4 | 114-125 | Warm transfers: 114-125 Gbps |
| GPU1/mlx5_3 | 114-125 | Identical pattern on second GPU |
| GPU1/mlx5_4 | 114-125 | |

NIC-level aggregates (from counter traces, 2 QPs per NIC):

| NIC | Cold 1st Transfer | Warm Steady State |
|-----|--------------------|--------------------|
| mlx5_3 | ~19.5 Gbps | 230-253 Gbps |
| mlx5_4 | ~22 Gbps | 230-253 Gbps |

The "cold" first transfer (~19.5 Gbps aggregate) reflects Address Translation
Cache (ATC) warmup on the very first RDMA access after `ibv_reg_mr`. Once
the ATC is populated, subsequent transfers sustain 230-253 Gbps aggregate per
NIC -- nearly saturating PCIe Gen5 x16 write bandwidth.

### Ruling Out Cold Start: The --rerandomize Experiment

A natural concern: each NIXL KV transfer involves a new vLLM request's KV
blocks at different GPU memory addresses. Could NIXL's ~27 Gbps reflect a
per-transfer cold-start penalty similar to scatter_bench's slow first transfer?

We added a `--rerandomize` option to `rdma_scatter_bench` that regenerates
completely new random offsets (different seed) for both local and remote
buffers on every transfer iteration. This simulates NIXL's behavior where
every request accesses different KV block addresses.

**Single-instance (1 GPU, 1 NIC):**

| Mode | Transfer 1 | Transfers 2-10 |
|------|-----------|---------------|
| Warm (same offsets each time) | 137.7 Gbps | 138.8-139.0 Gbps |
| **Rerandomize** (new offsets each time) | **138.0 Gbps** | **137.5-140.0 Gbps** |

**Multi-instance (4 concurrent, TP=2 rails=2 topology, rerandomize):**

| Instance | Transfer 1 | Transfers 2-5 |
|----------|-----------|---------------|
| GPU0/mlx5_3 | 134.4 Gbps | 138.6-140.8 Gbps |
| GPU0/mlx5_4 | 135.9 Gbps | 137.9-139.7 Gbps |
| GPU1/mlx5_3 | 136.1 Gbps | 138.8-139.9 Gbps |
| GPU1/mlx5_4 | 135.9 Gbps | 137.8-140.6 Gbps |

NIC aggregate (from counter traces): ~135 Gbps per NIC, constant across all
transfers.

**There is no cold-start penalty from changing offsets.** The NIC's ATC caches
page-level translations for the entire `ibv_reg_mr`-registered GPU memory
pool. Accessing different random offsets within the registered region does not
cause ATC misses -- only the very first access after MR registration triggers
ATC warmup.

Since NIXL's GPU memory is also pre-registered at vLLM startup, all KV
transfers (including the first) benefit from a warm ATC. Yet NIXL achieves
only 27 Gbps. The cold-start hypothesis is ruled out.

### WR Rate Comparison Summary

| Workload | WR Rate (WRs/sec) | Per-NIC RX (Gbps) | Ratio vs NIXL |
|----------|-------------------|--------------------|---------------|
| NIXL (all transfers) | 205K | 26.9 | 1.0x |
| scatter_bench multi cold (1st transfer) | 74K | 9.2 | 0.4x |
| scatter_bench multi warm (2nd+ transfers) | 1,056K | 132 | 5.1x |
| scatter_bench multi rerandomize (all) | ~1,030K | ~135 | 5.0x |

NIXL's WR rate is 2.8x higher than scatter_bench's truly cold first transfer
(which suffers ATC warmup, not address randomization). But it is **5x lower**
than scatter_bench's sustained rate with the same topology and scatter pattern.
The hardware can clearly sustain 1M+ WRs/sec per QP; NIXL's software stack
delivers only 205K.

---

## Conclusion and Next Steps

### What We Found

The 5.5x throughput gap between `ib_read_bw` (148 Gbps) and NIXL KV transfer
(27 Gbps) at 16 KB message size is **not caused by the GPU memory access
pattern**. A custom RDMA benchmark issuing the same 40,960 scattered 16 KB
reads achieves ~137 Gbps -- nearly matching `ib_read_bw` -- even under the
full TP=2, rails=2 topology with 4 concurrent cross-IIO flows and randomized
offsets on every transfer.

The bottleneck is in the **NIXL/UCX software stack**, which delivers Work
Requests at only **205K WRs/sec** per NIC versus the **1M+ WRs/sec** the
hardware sustains in `rdma_scatter_bench`. High-fidelity NIC counter profiling
confirmed a flat, constant throughput profile with no stalls or gaps -- the NIC
is fed work at a steady but insufficient rate. Despite tuning UCX's RC transport
parameters (Send Queue depth, doorbell batching, CQ moderation, `max_rd_atomic`),
NIXL throughput remains at ~27 Gbps. The constraint is above the transport
layer, in how descriptors are posted and how progress is driven.

### What We Ruled Out

| Hypothesis | Evidence Against |
|------------|-----------------|
| IIO completion buffer saturation | Buffer is less occupied for NIXL than for `ib_read_bw` |
| CPU mesh congestion | Per-entry residence time is identical across all workloads |
| CHA coherency overhead | P2P traffic bypasses CHA entirely (10,000x less CHA traffic) |
| **Scattered GPU memory access** | **Custom scatter bench achieves ~137 Gbps with identical scatter pattern** |
| VF MRRS limitation (128B) | `ib_read_bw` with VF (MRRS=128B) + GPU at 16KB achieves 148 Gbps, identical to PF (MRRS=4096B). VF MRRS locked by firmware. |
| UCX RC transport defaults | Tuning TX_QUEUE_LEN, TX_MAX_BATCH, TX_CQ_MODERATION, MAX_RD_ATOMIC, TX_POLL_ALWAYS has no effect |
| Network congestion | Zero PFC pauses, no drops on decode-side NIC counters |
| NIC fan-out contention | Only 2 GPUs active, same topology as `ib_read_bw` |
| Per-transfer cold start (new KV block addresses) | `--rerandomize` scatter bench shows no throughput drop with new random offsets each transfer. ATC covers entire registered MR. |
| NIC stalls or variable rate | NIC counter profiling shows flat, constant 205K WRs/sec with no gaps. Bottleneck is upstream in software. |

### Key Takeaway

**The hardware path is not the bottleneck.** The NIC, GPU memory system, IIO
stacks, and CPU mesh can all support ~137 Gbps of scattered 16 KB RDMA READs
in the cross-IIO configuration. The 5.5x gap is entirely due to the NIXL/UCX
software stack not loading the pipeline with enough outstanding read requests
to fill the bandwidth-delay product.

### Areas for Further Investigation

| Area | Rationale |
|------|-----------|
| **Interleaved posting with progress** | NIXL's burst-then-progress pattern leaves the NIC idle for ~3.8 ms during posting. Interleaving `ucp_worker_progress()` every N descriptors (e.g., every 256) would keep the pipeline fed during posting. |
| **UCX arbiter dispatch limit** | UCX's `ucs_arbiter_dispatch(..., per_group=1)` drains only 1 pending per EP per progress call. Increasing `per_group` or bypassing the arbiter for bulk RMA operations could dramatically improve pipeline throughput. |
| **Descriptor coalescing** | Sorting blocks by GPU address and merging adjacent 16 KB blocks into larger READs would reduce descriptor count (e.g., 4 adjacent blocks → one 64 KB READ), reducing both posting overhead and pending queue pressure. |
| **Raw verbs backend for NIXL** | A `libibverbs`-based NIXL plugin (bypassing UCX entirely) could use a tight post/poll loop identical to `rdma_scatter_bench`, recovering the full ~137 Gbps hardware capability. |
| **Same-IIO GPU-NIC placement** | Eliminates the mesh crossing entirely (355 Gbps observed), making the BDP constraint irrelevant. |
| **Topology-aware K8s scheduling** | Ensure GPU-NIC co-location when assigning SR-IOV VFs. |

### Open Questions

- The IIO programmable event clock is the dynamic uncore/mesh frequency (~2.4 GHz
  under load on this SKU), not the `ioclk` free-running counter (~45 MHz reference).
  How does uncore frequency scaling affect IIO counter accuracy in bursty workloads?
- Would switching to RDMA WRITE (prefill pushes) help? The sender's NIC still
  performs DMA reads from GPU memory, but the write-sender path achieves 69%
  higher throughput in `ib_write_bw` vs `ib_read_bw` at 16 KB (248 vs 148 Gbps)
  due to NIC pipelining advantages with pre-posted WQEs.
- What is the breakdown of time within a single NIXL transfer? How much time is
  spent posting descriptors vs waiting for completions vs stalled on progress?
