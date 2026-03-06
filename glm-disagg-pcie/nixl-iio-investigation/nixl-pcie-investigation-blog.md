# Why NIXL KV Transfers Are Slow: A PCIe Deep Dive

## Table of Contents

1. [Introduction](#introduction)
2. [What Is an IIO Stack?](#what-is-an-iio-stack)
3. [Test Environment](#test-environment)
4. [The GPU-NIC Placement Problem](#the-gpu-nic-placement-problem)
5. [Narrowing the Gap: Message Size Matters](#narrowing-the-gap-message-size-matters)
6. [Wire-Line Throughput for Cross-IIO](#wire-line-throughput-for-cross-iio)
7. [Investigating the Prefill-Side PCIe Path](#investigating-the-prefill-side-pcie-path)
8. [IIO Counter Results](#iio-counter-results)
9. [Two Hypotheses for the Low Insertion Rate](#two-hypotheses-for-the-low-insertion-rate)
10. [Validation: Custom RDMA Scatter Benchmark](#validation-custom-rdma-scatter-benchmark)
11. [Investigating the NIXL/UCX Software Stack](#investigating-the-nixlucx-software-stack)
12. [Wire-Level NIC Counter Profiling](#wire-level-nic-counter-profiling)
13. [Isolating the Decode-Side Bottleneck: Two Confounding Factors](#isolating-the-decode-side-bottleneck-two-confounding-factors)
14. [Conclusion and Next Steps](#conclusion-and-next-steps)

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

## Wire-Line Throughput for Cross-IIO

Before investigating the NIXL-specific gap, we need to establish the raw
wireline ceiling for cross-IIO transfers. Using `ib_read_bw` with GPU memory
on the `networking-debug-pod` PF NICs (MRRS = 4096 bytes), we ran four
experiments that isolate which side of the RDMA READ path is the bottleneck.
All tests use `--tx-depth=512` and sweep QP count from 1 to 16.

### Experiment Design

In an RDMA READ, two DMA operations occur on the **responder** (prefill) node:

1. The NIC **reads** from GPU memory (PCIe non-posted MRd + CplD round-trip)
2. The NIC sends data out on the wire

On the **requester** (decode) node, the NIC receives data from the wire and
**writes** it to GPU memory (PCIe posted MWr, fire-and-forget).

To isolate each path, we place the cross-IIO hop on only one side at a time:

| Experiment | Cross-IIO side | Streams | Prefill NIC→GPU | Decode NIC→GPU |
|------------|---------------|---------|-----------------|----------------|
| 1a | Prefill (read) | 1 | mlx5_3→GPU0 (cross-IIO) | mlx5_0→GPU0 (same-IIO) |
| 1b | Prefill (read) | 2 | mlx5_3→GPU0, mlx5_4→GPU1 (cross-IIO) | mlx5_0→GPU0, mlx5_2→GPU1 (same-IIO) |
| 2a | Decode (write) | 1 | mlx5_0→GPU0 (same-IIO) | mlx5_3→GPU0 (cross-IIO) |
| 2b | Decode (write) | 2 | mlx5_0→GPU0, mlx5_2→GPU1 (same-IIO) | mlx5_3→GPU0, mlx5_4→GPU1 (cross-IIO) |

### Results: 2 MB Messages

| Experiment | Description | Per-NIC Throughput (Gbps) |
|------------|-------------|--------------------------|
| 1a | Prefill cross-IIO read, 1 stream | 270 |
| 1b | Prefill cross-IIO read, 2 streams | 272 |
| 2a | Decode cross-IIO write, 1 stream | 359 |
| 2b | Decode cross-IIO write, 2 streams | 359 |

The read vs. write asymmetry is stark. When the NIC **writes** to GPU memory
across IIO stacks (exp 2a/2b), it achieves **359 Gbps** -- essentially line rate.
PCIe writes are **posted** transactions: the NIC fires off MWr TLPs with no
round-trip wait for a completion. When the NIC **reads** from GPU memory across
IIO stacks (exp 1a/1b), throughput drops to **~270 Gbps**. PCIe reads are
**non-posted**: each MRd TLP must wait for CplD data to return across the mesh
before the tag can be reused. This round-trip penalty caps the read path at
roughly 75% of line rate.

Adding a second concurrent stream (1a→1b, 2a→2b) causes no per-NIC degradation,
confirming there is no contention at the IIO level between independent GPU-NIC
pairs crossing the same mesh.

### Results: 16 KB Messages

| Experiment | Description | Per-NIC Throughput (Gbps) |
|------------|-------------|--------------------------|
| 1a | Prefill cross-IIO read, 1 stream | 271 |
| 1b | Prefill cross-IIO read, 2 streams | 272 |
| 2a | Decode cross-IIO write, 1 stream | 267 |
| 2b | Decode cross-IIO write, 2 streams | 266 |

At 16 KB, both read and write converge to **~270 Gbps**. The write path, which
was unconstrained at 2 MB, now also takes a throughput hit: smaller messages
mean more PCIe transactions per byte, and even posted writes face IIO scheduling
and header overhead at high transaction rates.

### Takeaway: The Wireline Ceiling

In the actual P/D deployment (cross-IIO configuration), cross-IIO hops occur
on **both** the prefill and decode sides. The effective wireline ceiling is
determined by the slower of the two paths:

- **Prefill-side NIC reading from GPU** (non-posted): ~270 Gbps per NIC
- **Decode-side NIC writing to GPU** (posted): ~359 Gbps at 2 MB, ~267 Gbps at 16 KB

At 2 MB messages, the prefill-side read path is clearly the bottleneck at
~270 Gbps. At 16 KB, both paths converge to the same ~270 Gbps ceiling.
Either way, **~260-270 Gbps per NIC is the maximum achievable wireline
throughput for cross-IIO RDMA transfers**, regardless of message size.

This means the **252 Gbps** measured by `ib_read_bw` with VF NICs (MRRS = 128B)
in the throughput comparison table above is already within ~93% of this ceiling.
The NIXL throughput of ~27 Gbps is **10x below the wireline limit** -- a gap
that cannot be explained by PCIe topology alone.

### Would NIXL Push Instead of Pull Change the Ceiling?

NIXL currently uses RDMA READ (pull): the **decode** NIC initiates the transfer,
and the **prefill** NIC responds by DMA-reading from GPU memory. A natural
question is whether switching to RDMA WRITE (push) -- where the **prefill** NIC
initiates the transfer from a local Send Queue -- would improve throughput.
The hypothesis: with push, the prefill NIC has a full pipeline of locally queued
Work Requests and can schedule its DMA reads from GPU memory more aggressively
than when reacting to incoming RDMA READ requests from the network.

To test this, we ran both `ib_read_bw` (pull) and `ib_write_bw` (push) with
cross-IIO GPU-NIC pairs (GPU0-mlx5_3, GPU1-mlx5_4) on **both** the prefill
and decode nodes simultaneously -- 2 streams, PF NICs, `--tx-depth=512`,
sweeping QPs from 1 to 16.

**2 MB messages (per-NIC Gbps):**

| Mode | QP=1 | QP=2 | QP=4 | QP=8 | QP=16 |
|------|------|------|------|------|-------|
| Pull (`ib_read_bw`) | 254 | 265 | 271 | 272 | 272 |
| Push (`ib_write_bw`) | 254 | 265 | 270 | 272 | 272 |

**16 KB messages (per-NIC Gbps):**

| Mode | QP=1 | QP=2 | QP=4 | QP=8 | QP=16 |
|------|------|------|------|------|-------|
| Pull (`ib_read_bw`) | 149 | 262 | 267 | 268 | 268 |
| Push (`ib_write_bw`) | 251 | 265 | 270 | 273 | 272 |

At saturation (QP >= 4), pull and push converge to the **same ~272 Gbps
ceiling**. The bottleneck is identical in both cases: the prefill NIC must
DMA-read from GPU memory across IIO stacks, and the non-posted PCIe read
round-trip (MRd → mesh → GPU → CplD → mesh → NIC) caps throughput at ~270 Gbps
regardless of how the work is initiated.

The one difference appears at **16 KB with QP=1**: push achieves 251 Gbps
while pull only reaches 149 Gbps. With push, the NIC has 512 Work Requests
queued locally in its Send Queue, so even a single QP provides enough
outstanding DMA reads to fill the bandwidth-delay product across the mesh.
With pull, the NIC processes incoming RDMA READ requests as they arrive -- at
QP=1, only one request is outstanding at a time, which is insufficient to
hide the mesh round-trip latency for small messages. Adding more QPs (QP >= 2)
closes this gap as the NIC can then overlap multiple in-flight requests.

**Takeaway:** Switching NIXL from pull to push would **not** raise the wireline
ceiling. The prefill-side cross-IIO DMA read path is the fundamental bottleneck,
and it applies equally to both RDMA READ responses and RDMA WRITE initiations.
Push would only help in scenarios where the NIC's request pipeline is
under-filled -- which is precisely the software-level problem we investigate
in the rest of this post.

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

## Isolating the Decode-Side Bottleneck: Two Confounding Factors

The NIC counter profiling in the previous section showed that NIXL's decode
pod sends RDMA READ requests at a flat ~208K WRs/sec per NIC -- far below
the ~1M+ WRs/sec the hardware sustains in `rdma_scatter_bench`. But what
exactly throttles this request rate on the decode pod?

In the original scenario 2r2 (nixl-s6), the decode pod has **two confounding
factors** that could each limit request throughput:

1. **Cross-IIO GPU-NIC latency**: each NIC writes RDMA READ completions to
   a GPU on a different IIO stack, crossing the CPU mesh. This increases the
   per-completion round-trip time, which slows down UCX's poll-and-repost loop.

2. **UCX rails splitting overhead**: with `UCX_MAX_RMA_RAILS=2`, each GPU
   rank splits its 40,960 descriptors across two NICs. UCX's multi-rail
   arbiter adds software overhead for every descriptor to select the target
   NIC, manage per-rail pending queues, and coordinate completions across
   two transport endpoints.

The nixl-s6 baseline configuration for reference:

| Pod | GPUs | NICs | GPU-NIC Pairing | UCX Rails |
|-----|------|------|----------------|-----------|
| **Both** | GPU 0 (11:00.0), GPU 1 (2f:00.0) | mlx5_12 (41:00.1), mlx5_13 (58:00.1) | **Cross-IIO**: GPU 0 (IIO 0)↔mlx5_12 (IIO 2), GPU 1 (IIO 1)↔mlx5_13 (IIO 3) | 2 |

To separate these factors, we designed three targeted experiments: two that
each remove exactly one factor, and a third that removes both.

### nixl-s7: Remove Cross-IIO, Keep Rails Splitting

| Pod | GPUs | NICs | GPU-NIC Pairing | UCX Rails |
|-----|------|------|----------------|-----------|
| **Decode** | GPU 0 (11:00.0), GPU 1 (2f:00.0) | mlx5_10 (0c:00.1), mlx5_11 (2a:00.1) | **Same-IIO**: GPU 0↔mlx5_10 share IIO stack 0, GPU 1↔mlx5_11 share IIO stack 1 | 2 |
| **Prefill** | GPU 0 (11:00.0), GPU 1 (2f:00.0) | mlx5_12 (41:00.1), mlx5_13 (58:00.1) | **Cross-IIO**: GPU 0 (IIO 0)↔mlx5_12 (IIO 2), GPU 1 (IIO 1)↔mlx5_13 (IIO 3) | 2 |

The decode pod's NICs have a low-latency path to their respective GPUs (no
mesh crossing for completion writes). Rails=2 is retained, so each GPU rank
still splits traffic across both NICs via UCX's multi-rail arbiter. Note:
with rails=2, each GPU also uses the *other* GPU's NIC (cross-IIO), so the
decode side is mixed-IIO (50% same, 50% cross). The prefill pod retains
cross-IIO throughout.

### nixl-s8: Remove Rails Splitting, Keep Cross-IIO

| Pod | GPUs | NICs | GPU-NIC Pairing | UCX Rails |
|-----|------|------|----------------|-----------|
| **Decode** | GPU 0 (11:00.0), GPU 7 (da:00.0) | mlx5_11 (2a:00.1), mlx5_16 (bd:00.1) | **Cross-IIO**: GPU 0 (IIO 0)↔mlx5_11 (IIO 1), GPU 7 (IIO 7)↔mlx5_16 (IIO 6) | 1 |
| **Prefill** | GPU 0 (11:00.0), GPU 7 (da:00.0) | mlx5_11 (2a:00.1), mlx5_16 (bd:00.1) | **Cross-IIO**: same as decode | 1 |

With `UCX_MAX_RMA_RAILS=1`, each GPU rank uses exactly one dedicated NIC --
no rails splitting, no multi-rail arbitration. Both GPU-NIC pairs remain
cross-IIO on the decode side.

To force UCX to assign *different* NICs to each rank (UCX's greedy selection
assigns both ranks to the same NIC when all paths are equidistant), we use
`CUDA_VISIBLE_DEVICES=0,7` to place the two TP=2 ranks on GPUs across NUMA
domains: GPU 0 (NUMA 0, IIO stack 0) and GPU 7 (NUMA 1, IIO stack 7). The
NICs mlx5_11 (NUMA 0, IIO stack 1) and mlx5_16 (NUMA 1, IIO stack 6) then
have unambiguous distance: GPU 0 prefers mlx5_11 (same-NUMA) over mlx5_16
(cross-NUMA), and vice versa for GPU 7. UCX correctly assigns one NIC per
rank based on this NUMA distance differentiation.

### nixl-s9: Remove Both Factors on Decode

| Pod | GPUs | NICs | GPU-NIC Pairing | UCX Rails |
|-----|------|------|----------------|-----------|
| **Decode** | GPU 0 (11:00.0), GPU 1 (2f:00.0) | mlx5_10 (0c:00.1), mlx5_11 (2a:00.1) | **Same-IIO**: GPU 0↔mlx5_10 share IIO stack 0, GPU 1↔mlx5_11 share IIO stack 1 | 1 |
| **Prefill** | GPU 0 (11:00.0), GPU 7 (da:00.0) | mlx5_11 (2a:00.1), mlx5_16 (bd:00.1) | **Cross-IIO**: GPU 0 (IIO 0)↔mlx5_11 (IIO 1), GPU 7 (IIO 7)↔mlx5_16 (IIO 6) | 1 |

This scenario removes *both* confounding factors on the decode pod: same-IIO
placement eliminates mesh crossing for completions, and rails=1 eliminates
multi-rail arbitration. Each decode GPU has a dedicated same-IIO NIC. The
prefill pod retains cross-IIO with `CUDA_VISIBLE_DEVICES=0,7` (identical to
nixl-s8), so the wireline ceiling on the prefill side remains unchanged.

On the decode pod, GPUs 0 and 1 (the TP=2 default) naturally use mlx5_10 and
mlx5_11 respectively -- these are the closest NICs by PCIe distance. With
rails=1, UCX assigns one NIC per rank without any ambiguity.

### Results

**NIXL KV transfer throughput (from decode pod vLLM logs):**

| Metric | nixl-s6 (baseline) | nixl-s7 (no cross-IIO) | nixl-s8 (no rails split) | nixl-s9 (neither) |
|--------|--------------------|----------------------|------------------------|--------------------|
| avg_xfer_time | 199.740 ms | 29.321 ms | 23.446 ms | 22.422 ms |
| avg_post_time | 2.132 ms | 2.863 ms | 1.687 ms | 1.797 ms |
| effective_xfer_time | 197.608 ms | 26.458 ms | 21.759 ms | 20.625 ms |
| **Per-rank throughput** | **27.2 Gbps** | **202.9 Gbps** | **246.7 Gbps** | **260.3 Gbps** |

*Per-rank RDMA throughput = (671.1 MB / effective_xfer_time) × 8.*

**Decode NIC request rate and wire-level throughput (from high-fidelity NIC counters):**

| Metric | nixl-s6 | nixl-s7 | nixl-s8 | nixl-s9 |
|--------|---------|---------|---------|---------|
| NIC 1 RX (Gbps) | 28.3 | 189.5 | 241.6 | 250.8 |
| NIC 2 RX (Gbps) | 28.4 | 185.2 | 242.0 | 250.8 |
| NIC 1 WR rate (WRs/sec) | 208,539 | 1,436,484 | 1,834,745 | 1,912,000 |
| NIC 2 WR rate (WRs/sec) | 208,585 | 1,404,503 | 1,836,783 | 1,888,000 |
| TX bytes per WR | 146 | 145 | 73 | 73 |

### Analysis: Confounding Factors That Cripple Together

Each factor individually degrades throughput, but **together they have a
crippling effect** -- the baseline nixl-s6 achieves only 27 Gbps, far worse
than either factor alone would predict.

**Removing cross-IIO (nixl-s7)** produced a **7.5x** throughput improvement
(27 → 203 Gbps). The WR rate jumped from 208K to 1.42M per NIC. Eliminating
the mesh crossing on the decode side dramatically reduces completion latency,
allowing UCX's progress loop to drain completions and repost new WRs much
faster. However, nixl-s7 retains rails=2, and each GPU still has 50% of its
traffic crossing IIO (to the other GPU's NIC), which limits the improvement.

**Removing rails splitting (nixl-s8)** produced a **9.1x** throughput
improvement (27 → 247 Gbps). The WR rate jumped from 208K to 1.84M per NIC.
With rails=1, each GPU has a dedicated NIC and UCX bypasses the multi-rail
arbiter entirely. The TX bytes per WR dropped from 146 to 73 bytes, indicating
that the RDMA READ request packets are smaller without multi-rail coordination
headers. Despite both GPU-NIC pairs being cross-IIO, the elimination of rails
splitting overhead alone is sufficient to recover near-wireline throughput.

The posting time also drops significantly: `avg_post_time` falls from ~2.1-2.9
ms with rails=2 (nixl-s6, nixl-s7) to ~1.7-1.8 ms with rails=1 (nixl-s8,
nixl-s9). With rails=2, each descriptor must pass through UCX's multi-rail
arbiter to select the target NIC, manage per-rail pending queues, and
coordinate two transport endpoints. With rails=1, this entire layer is
bypassed -- the descriptor goes directly to a single transport endpoint,
cutting posting overhead by ~35%.

**Removing both factors (nixl-s9)** produced a **9.6x** throughput
improvement (27 → 260 Gbps). The WR rate reached 1.9M per NIC, and per-NIC
RX throughput hit 250.8 Gbps consistently. This represents the best-case
decode-side configuration: each GPU has a dedicated same-IIO NIC with no
multi-rail overhead.

**Comparing all three isolation experiments:**

| Scenario | Factor(s) Removed | Speedup | Per-NIC WR Rate | Per-NIC RX (Gbps) |
|----------|-------------------|---------|-----------------|-------------------|
| nixl-s7 | Cross-IIO only | 7.5x | 1.42M | ~187 |
| nixl-s8 | Rails splitting only | 9.1x | 1.84M | ~242 |
| nixl-s9 | Both | 9.6x | 1.90M | ~251 |

The key insight is in the progression: nixl-s8 and nixl-s9 are nearly
identical in throughput (247 vs 260 Gbps, ~5% difference), while both are
dramatically faster than nixl-s7 (203 Gbps). This reveals that once rails
splitting is removed, the remaining cross-IIO penalty is modest (~5%). But
when rails splitting is *present*, the cross-IIO latency amplifies the
multi-rail arbitration overhead -- each additional microsecond of
completion latency from the mesh crossing means more time the arbiter
spends waiting, compounding the per-descriptor overhead.

The prefill side remains cross-IIO in all three experiments, giving a
wireline ceiling of ~252 Gbps (from `ib_read_bw`). nixl-s9's per-NIC
throughput of ~251 Gbps essentially **saturates this ceiling**, confirming
that the decode-side software path is no longer the bottleneck when both
factors are eliminated.

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

By isolating two confounding factors on the decode pod -- cross-IIO latency
and UCX multi-rail splitting -- we identified their individual and combined
contributions:

- **Removing cross-IIO** (nixl-s7, rails=2): 7.5x speedup → 203 Gbps, 1.42M WRs/sec per NIC
- **Removing rails splitting** (nixl-s8, rails=1): 9.1x speedup → 247 Gbps, 1.84M WRs/sec per NIC
- **Removing both** (nixl-s9, same-IIO + rails=1): 9.6x speedup → 260 Gbps, 1.90M WRs/sec per NIC

Each factor individually degrades throughput, but together they are
**crippling**: the baseline nixl-s6 (both factors present) achieves only
27 Gbps -- far worse than either factor alone would predict. Cross-IIO
latency amplifies the multi-rail arbitration overhead because each
additional microsecond of mesh-crossing completion latency compounds the
time the arbiter spends waiting per descriptor.

nixl-s9 **saturated the wireline ceiling** (~251 Gbps per NIC vs 252 Gbps
from `ib_read_bw`), confirming that the decode-side software path is no
longer the bottleneck when both factors are eliminated.

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

**The hardware path is not the bottleneck.** The 9.6x throughput gap between
the baseline NIXL configuration (27 Gbps) and the best-case nixl-s9 (260 Gbps)
is caused by two software/configuration factors on the decode pod that
**compound when both are present**:

1. **UCX multi-rail splitting**: with `rails=2`, UCX's arbiter adds
   per-descriptor overhead for NIC selection and cross-rail coordination.
   Removing this alone (nixl-s8) recovers 96% of the wireline ceiling. The
   posting overhead also drops measurably: `avg_post_time` falls from ~2.1-2.9
   ms (rails=2) to ~1.7-1.8 ms (rails=1), a ~35% reduction, as descriptors
   bypass the multi-rail arbiter and go directly to a single transport endpoint.

2. **Cross-IIO completion latency**: the CPU mesh crossing increases
   per-completion round-trip time, slowing UCX's poll-and-repost loop.
   Removing this alone (nixl-s7) recovers 80% of the wireline ceiling.

Either factor in isolation causes moderate degradation, but together they
are crippling: cross-IIO latency amplifies the per-descriptor overhead of
the multi-rail arbiter, and the arbiter's slower dispatch rate in turn
increases the sensitivity to completion latency. Removing both (nixl-s9)
saturates the wireline ceiling at ~251 Gbps per NIC.

The hardware -- NIC, GPU memory, IIO stacks, and CPU mesh -- can sustain
~251 Gbps of scattered 16 KB RDMA READs per NIC when the software pipeline
is efficient (rails=1, dedicated same-IIO NIC per GPU).

### Practical Recommendations

Our experiments show that the ideal configuration is simple: each GPU rank
gets a single dedicated NIC on its own IIO stack, with `UCX_MAX_RMA_RAILS=1`.
But achieving this in practice requires coordination across three layers --
Kubernetes scheduling, UCX transport selection, and vLLM process spawning --
none of which are topology-aware today.

#### The GPU-NIC Placement Gap in Kubernetes

Today, Kubernetes allocates GPUs (via the NVIDIA device plugin) and NICs (via
the SR-IOV device plugin) independently. When a pod requests a subset of the
GPU-NIC pairs available on a node, there is no guarantee that the assigned
devices share a PCIe Root Complex. In practice, cross-IIO pairings are the
norm rather than the exception.

[DRANET](https://dranet.dev/) addresses this gap by using Kubernetes Dynamic
Resource Allocation (DRA) to jointly schedule GPUs and NICs with NUMA and
PCIe topology awareness. DRANET launched in preview on GKE in October 2025.
Until DRANET or similar solutions are widely deployed across cloud providers,
pods that receive a subset of a node's GPU-NIC pairs should expect cross-IIO
pairings and must compensate in software.

#### Why UCX Cannot Fix This Alone

UCX's topology module
([`ucs_topo_get_distance_sysfs`](https://github.com/openucx/ucx/blob/master/src/ucs/sys/topo/base/topo.c))
resolves both the GPU and NIC sysfs paths and walks the PCIe tree to find the
lowest common ancestor. It then classifies the pair into one of three distance
tiers:

| Common Ancestor | Distance Classification | Estimated Bandwidth |
|-----------------|------------------------|---------------------|
| Same PCIe Root Complex (same IIO stack) | Close | `min(3500 MB/s, 19200 MB/s / path_hops)` |
| System root, same NUMA | Medium | ~17 GB/s (flat) |
| System root, different NUMA | Far | ~220 MB/s (flat) |

This estimated bandwidth feeds into UCX's transport scoring function
([`ucp_wireup_iface_bw_distance`](https://github.com/openucx/ucx/blob/master/src/ucp/wireup/wireup.c)),
which ranks NICs for each endpoint connection. The NIC with the highest
effective bandwidth score wins.

The problem is in the "medium" tier: when a GPU and NIC are under different
PCIe Root Complexes but on the same NUMA node (the cross-IIO case), **all
such NICs receive the same flat ~17 GB/s score**. UCX cannot differentiate
between a NIC on a neighboring IIO stack and one on a distant IIO stack
within the same NUMA domain.

Because vLLM spawns a separate process per GPU rank, each rank runs an
independent UCX instance that picks the "best" NIC from its own perspective.
When multiple NICs have identical scores, all instances may converge on the
same NIC -- creating a shared bottleneck where multiple GPUs funnel traffic
through a single 400G link while other NICs sit idle.

#### What vLLM Can Do Today

**1. Per-rank `UCX_NET_DEVICES` binding.** vLLM uses Python multiprocessing
(`fork` or `spawn`) to create per-GPU worker processes. Each worker inherits
the parent's environment at spawn time. vLLM (or a helper init container) can
discover the GPU-NIC topology at startup by walking `/sys/bus/pci/devices/`
sysfs paths and matching PCIe Root Complexes -- the same approach used by the
[`gpu_to_hca_mapping.sh`](https://github.com/llm-d/llm-d) script in this
investigation. Before spawning each worker, setting `UCX_NET_DEVICES` to just
the NIC chosen for that GPU rank gives each UCX instance visibility to only
its dedicated NIC, eliminating the greedy-selection problem entirely. A
precedent already exists in llm-d's GKE configuration, where
`DEEP_EP_DEVICE_TO_HCA_MAPPING` provides a per-GPU NIC binding for
DeepEP/NVSHMEM as a single environment variable.

**2. Default `UCX_MAX_RMA_RAILS=1` when #NICs >= #GPUs.** When the pod has
at least as many NICs as active GPU ranks, there is no need for multi-rail
splitting -- each GPU can have a dedicated NIC. Our experiments show that
`rails=2` introduces multi-rail arbiter overhead that is the larger of the
two confounding factors (9.1x degradation vs baseline). Defaulting to
`rails=1` avoids this overhead entirely.

**3. The goal: dedicated NIC per GPU, no splitting.** The ideal configuration
demonstrated in our experiments is straightforward: each GPU rank gets a
single dedicated NIC (ideally on the same IIO stack) with
`UCX_MAX_RMA_RAILS=1`. This eliminates both confounding factors and saturates
the wireline ceiling. When same-IIO placement is not possible (the common
case without DRANET), per-rank NIC binding with `rails=1` still recovers 96%
of the wireline ceiling by eliminating the rails splitting overhead.

### Areas for Further Investigation

| Area | Rationale |
|------|-----------|
| **Interleaved posting with progress** | NIXL's burst-then-progress pattern leaves the NIC idle for ~3.8 ms during posting. Interleaving `ucp_worker_progress()` every N descriptors (e.g., every 256) would keep the pipeline fed during posting. |
| **UCX arbiter dispatch limit** | UCX's `ucs_arbiter_dispatch(..., per_group=1)` drains only 1 pending per EP per progress call. Increasing `per_group` or bypassing the arbiter for bulk RMA operations could dramatically improve pipeline throughput. |
| **Descriptor coalescing** | Sorting blocks by GPU address and merging adjacent 16 KB blocks into larger READs would reduce descriptor count (e.g., 4 adjacent blocks → one 64 KB READ), reducing both posting overhead and pending queue pressure. |
| **Raw verbs backend for NIXL** | A `libibverbs`-based NIXL plugin (bypassing UCX entirely) could use a tight post/poll loop identical to `rdma_scatter_bench`, recovering the full hardware capability. |

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
