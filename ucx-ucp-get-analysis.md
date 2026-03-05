# UCX ucp_get_nb / ucp_get_nbi RDMA READ Analysis

**Source**: UCX v1.12.1 (https://github.com/openucx/ucx, tag v1.12.1)  
**Date**: March 2025

This document analyzes the UCX source code to understand the per-call overhead, pipeline management, and flow of `ucp_get_nb` / `ucp_get_nbi` RDMA READ operations.

---

## 1. ucp_get_nb / ucp_get_nbi Implementation

### Entry Points

Both APIs funnel into `ucp_get_nbx`:

```c
// src/ucp/rma/rma_send.c:313-325
ucs_status_t ucp_get_nbi(ucp_ep_h ep, void *buffer, size_t length, ...)
    → ucp_get_nbx(ep, buffer, length, remote_addr, rkey, &ucp_request_null_param)
    → If returns request pointer: ucp_request_free() + return UCS_INPROGRESS
    → Else: return status

// src/ucp/rma/rma_send.c:329-338
ucs_status_ptr_t ucp_get_nb(ucp_ep_h ep, void *buffer, size_t length, ...)
    → ucp_get_nbx(ep, buffer, length, remote_addr, rkey, &param)  // param has callback
```

**Difference**: `ucp_get_nbi` discards the request handle and returns `UCS_INPROGRESS` when the operation is queued; `ucp_get_nb` returns the request for later completion/cancellation and supports a callback.

### ucp_get_nbx Flow (src/ucp/rma/rma_send.c:341-394)

1. **Worker thread lock**: `UCP_WORKER_THREAD_CS_ENTER_CONDITIONAL(worker)`
2. **Two paths** (controlled by `worker->context->config.ext.proto_enable`):

   **A. Proto path** (when `proto_enable`):
   - `ucp_request_get_param()` – allocate request from mpool
   - `ucp_proto_request_send_op()` – protocol selection + send
   - Uses `ucp_proto_select` for RMA GET; chooses optimized protocol (e.g. get_offload, get_am, or rndv get_zcopy)

   **B. Legacy path** (when `!proto_enable`):
   - `UCP_RKEY_RESOLVE(rkey, ep, rma)` – resolve remote key
   - `ucp_rma_nonblocking()` → `ucp_rma_request_init()` + `ucp_rma_send_request()`

### Per-Call Overhead (Legacy Path)

| Step | Function | Operations |
|------|----------|------------|
| 1 | `UCP_RMA_CHECK_PTR` | Param validation (buffer, length, feature flags) |
| 2 | `UCP_WORKER_THREAD_CS_ENTER_CONDITIONAL` | Optional recursive spinlock (if multi-threaded) |
| 3 | `ucp_request_get_param` | `ucs_mpool_get_inline()` from `worker->req_mp` |
| 4 | `ucp_rma_request_init` | Set req fields, `ucp_request_send_state_init/reset`, optionally `ucp_request_send_buffer_reg_lane` for zcopy |
| 5 | `ucp_rma_send_request` | `ucp_request_send()` → progress callback |

---

## 2. UCP → UCT RDMA READ Translation

### Legacy RMA GET Path

**ucp_rma_basic_progress_get** (src/ucp/rma/rma_basic.c:72-113):

```
if (length < get_zcopy_thresh):
    uct_ep_get_bcopy(ep, memcpy, buffer, frag_length, remote_addr, rkey, &comp)
else:
    uct_ep_get_zcopy(ep, &iov, 1, remote_addr, rkey, &comp)
```

### UCT RC Verbs (src/uct/ib/rc/verbs/rc_verbs_ep.c)

**get_bcopy** (RDMA READ with copy on completion):
- Allocates descriptor from `iface->super.tx.mp`
- Fills `ibv_send_wr` with `IBV_WR_RDMA_READ`, SGE to bounce buffer
- `uct_rc_verbs_ep_post_send_desc()` → `ibv_post_send(ep->qp, wr, &bad_wr)`
- Completion unpacks via callback into user buffer

**get_zcopy** (zero-copy RDMA READ):
- `uct_rc_verbs_ep_rdma_zcopy()` with `IBV_WR_RDMA_READ`
- Posts directly to user-registered memory
- Completion via `uct_rc_ep_get_zcopy_completion_handler`

### UCT RC MLX5 (src/uct/ib/rc/accel/rc_mlx5_ep.c)

**get_bcopy**:
- `uct_rc_mlx5_common_txqp_bcopy_post()` with `MLX5_OPCODE_RDMA_READ`
- `uct_ib_mlx5_post_send(txwq, ctrl, wqe_size, ...)` – WQE copy + doorbell

**get_zcopy**:
- `uct_rc_mlx5_ep_zcopy_post()` with `MLX5_OPCODE_RDMA_READ`
- Same `uct_ib_mlx5_post_send` path

### Call Chain Summary

```
ucp_get_nb/nbi
  → ucp_get_nbx
    → ucp_rma_nonblocking (legacy) OR ucp_proto_request_send_op (proto)
      → ucp_request_send
        → ucp_request_try_send (loop)
          → ucp_rma_basic_progress_get (legacy GET)
            → uct_ep_get_bcopy OR uct_ep_get_zcopy
              → rc_verbs: uct_rc_verbs_ep_post_send_desc → ibv_post_send
              → rc_mlx5:  uct_rc_mlx5_common_txqp_bcopy_post → uct_ib_mlx5_post_send (BF copy + doorbell)
```

---

## 3. Send Queue Full: Pending Queue and Drain

### When UCT Returns UCS_ERR_NO_RESOURCE

- `ucp_request_try_send` (src/ucp/core/ucp_request.inl:328-348):
  - If `status == UCS_ERR_NO_RESOURCE` → `ucp_request_pending_add(req)` returns 1, loop exits

### ucp_request_pending_add (src/ucp/core/ucp_request.c:292-315)

```c
uct_ep = req->send.ep->uct_eps[req->send.lane];
status = uct_ep_pending_add(uct_ep, &req->send.uct, 0);
```

- Request is added to the **UCT endpoint’s** pending queue, not a UCP-level queue.
- UCT owns the pending queue and drain policy.

### UCT RC Pending (src/uct/ib/rc/base/rc_ep.c)

- `uct_rc_ep_pending_add`: pushes request onto per-EP `arb_group`, schedules group on `iface->tx.arbiter`
- Drain happens when **TX CQ credits** become available (completions polled)

### When Is the Pending Queue Drained?

- RC verbs (src/uct/ib/rc/verbs/rc_verbs_iface.c:180-191):
  - `uct_rc_verbs_iface_progress`:
    1. `uct_rc_verbs_iface_poll_rx_common` – poll RX CQ
    2. `uct_rc_iface_poll_tx(&iface->super, count)` – if `count == 0` and not `tx_poll_always`, skip
    3. `uct_rc_verbs_iface_poll_tx` – poll TX CQ
- On TX completion (src/uct/ib/rc/verbs/rc_verbs_iface.c:171-174):
  - `uct_rc_txqp_completion_desc` updates completion index
  - `uct_rc_iface_add_cq_credits_dispatch()`:
    - `iface->tx.cq_available += cq_credits`
    - `ucs_arbiter_dispatch(&iface->tx.arbiter, 1, uct_rc_ep_process_pending, NULL)`

**Critical**: `ucs_arbiter_dispatch(..., 1, ...)` uses `per_group = 1`, i.e. **at most one pending element per group per dispatch**.

So: **one `ucp_worker_progress()` call can drain at most one pending operation per RC endpoint** when credits are added.

---

## 4. ucp_worker_progress() Behavior

### Implementation (src/ucp/core/ucp_worker.c:2625-2646)

```c
unsigned ucp_worker_progress(ucp_worker_h worker)
{
    UCP_WORKER_THREAD_CS_ENTER_CONDITIONAL(worker);
    ucs_assert(worker->inprogress++ == 0);
    count = uct_worker_progress(worker->uct);
    ucs_async_check_miss(&worker->async);
    ucs_assert(--worker->inprogress == 0);
    UCP_WORKER_THREAD_CS_EXIT_CONDITIONAL(worker);
    return count;
}
```

### uct_worker_progress (src/uct/api/uct.h:2587-2590)

```c
return ucs_callbackq_dispatch(&worker->progress_q);
```

### ucs_callbackq_dispatch (src/ucs/datastruct/callbackq.h:204-215)

```c
count = 0;
for (elem = cbq->fast_elems; (cb = elem->cb) != NULL; ++elem) {
    count += cb(elem->arg);
}
return count;
```

- Iterates over **all fast-path callbacks** (up to `UCS_CALLBACKQ_FAST_COUNT = 7`)
- **One invocation per callback** per `ucp_worker_progress()` call
- Typical callbacks: one per UCT iface (e.g. RC, UD, DC, etc.)

### RC Iface Progress Per Call

For each RC iface progress callback:

1. Poll TX CQ – process all available CQEs
2. For each CQE batch: add credits, then `ucs_arbiter_dispatch(arbiter, 1, uct_rc_ep_process_pending, NULL)`
3. Pending drain: **at most 1 pending op per EP per such dispatch**

### How Many Ops per progress() Call?

- **Not** “all pending ops in one call”
- **One pass** over all iface progress callbacks
- Each RC iface: process all available CQEs; then drain **up to 1 pending** per EP per dispatch
- Multiple EPs: each can contribute 1 pending drain per progress cycle when credits are available
- **Recommendation**: call `ucp_worker_progress()` in a loop until it returns 0 to fully drain

---

## 5. WQE Batching at UCT/Verbs Level

### Verbs (ibv_post_send)

- Each `uct_ep_get_bcopy` / `uct_ep_get_zcopy` posts **one** `ibv_send_wr` (possibly with a chain for multi-sge)
- No aggregation of multiple gets into a single `ibv_post_send` call
- One UCP get → one verbs post

### MLX5 (uct_ib_mlx5_post_send)

- Writes WQE(s) into SQ, then rings doorbell
- BF (BlueFlame) mode: copies WQE directly into device mapped memory
- Still **one WQE per UCP get** for single-fragment operations
- Zcopy with multiple IOVs can use multiple WQEs for one logical get

**Conclusion**: No batching of multiple `ucp_get_*` calls into a single post. Each get maps to one or more WQEs as needed.

---

## 6. Per-Call Overhead and Bottlenecks

### Overhead Components

| Component | Location | Notes |
|-----------|----------|--------|
| Worker lock | `UCP_WORKER_THREAD_CS_*` | Recursive spinlock when multi-threaded |
| Request alloc | `ucs_mpool_get_inline` | From worker req mpool; cache-hot |
| Rkey resolve | `UCP_RKEY_RESOLVE` | Usually cached in `rkey->cache` |
| Buffer reg | `ucp_request_send_buffer_reg_lane` | Only for zcopy; md registration cost |
| Memcpy (bcopy) | UCT bounce buffer | Copy on completion for small sizes |
| Post | `ibv_post_send` / MLX5 doorbell | syscall or MMIO |

### Potential Bottlenecks

1. **Pending drain rate**: `per_group=1` limits to one pending op per EP per progress cycle; large batches of gets can build up when SQ is full.
2. **Request mpool**: Exhaustion causes allocation failure.
3. **TX descriptor / CQ**: RC interface limited by `tx.queue_len`, `tx_ops_count`, `max_rd_atomic`.
4. **Thread lock**: `UCP_WORKER_THREAD_CS` adds contention in multi-threaded use.

---

## 7. Configuration That Affects Pipeline Depth

From RC iface and UCP config:

- `UCX_RC_TX_QP_LEN` / `tx.queue_len` – send queue depth
- `UCX_RC_MAX_RD_ATOMIC` / `max_rd_atomic` – max outstanding RDMA reads
- `UCX_RC_TX_MAX_GET_BYTES` – max bytes in flight for gets (can throttle)
- `UCT_RC_*` `max_get_bcopy`, `max_get_zcopy` – size limits
- UCP `get_zcopy_thresh` – bcopy vs zcopy threshold

### Proto Enable

- `UCX_PROTO_ENABLE=y` (default in v1.12.x): uses protocol framework
- Can select different implementations (e.g. get_offload, get_am, rndv get_zcopy) based on size and capabilities

---

## 8. Summary

### Call Chain (Legacy Path)

```
ucp_get_nb/nbi
  → ucp_get_nbx
    → UCP_WORKER_THREAD_CS_ENTER
    → ucp_request_get_param (mpool get)
    → ucp_rma_request_init
    → ucp_rma_send_request → ucp_request_send
      → ucp_request_try_send (loop)
        → ucp_rma_basic_progress_get
          → uct_ep_get_bcopy | uct_ep_get_zcopy
            → ibv_post_send (verbs) | uct_ib_mlx5_post_send (MLX5)
    → UCP_WORKER_THREAD_CS_EXIT
```

### progress() Processing

- **Per call**: One pass over all worker progress callbacks (one per iface)
- **Pending drain**: At most **one pending operation per RC EP** per progress cycle when CQ credits are added
- **To fully drain**: Call `ucp_worker_progress()` repeatedly until it returns 0

### Internal Queues and Drain

- **UCP**: No internal pending queue; defers to UCT
- **UCT RC**: Per-EP pending list on `iface->tx.arbiter`
- **Drain**: Triggered by TX CQ polling in iface progress; each `arbiter_dispatch` processes 1 element per group (`per_group=1`)

### Batching

- **No WQE batching**: Each `ucp_get_*` maps to one (or more for multi-sge) WQE
- MLX5 BF copies one WQE at a time into device memory

### Overhead and Limits

- Worker lock, request mpool get, rkey cache lookup, optional registration
- Pending drain rate and SQ depth are main limits for high-rate get workloads
