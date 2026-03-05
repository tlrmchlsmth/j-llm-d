// rdma_scatter_bench: RDMA READ benchmark with contiguous vs scattered GPU memory.
//
// Validates the root cause of NIXL's throughput gap: scattered GPU memory access
// exhausts the NIC's PCIe tag pool, throttling throughput via BDP.
//
// Build (inside networking-debug-pod):
//   g++ -D__HIP_PLATFORM_AMD__ -O2 -o rdma_scatter_bench rdma_scatter_bench.cpp \
//       -I/opt/rocm/include -L/opt/rocm/lib -lamdhip64 -libverbs -Wl,-rpath,/opt/rocm/lib
//
// Usage:
//   Server: ./rdma_scatter_bench server --dev mlx5_3 --gpu 0 --port 19875 \
//               --num-blocks 40960 --block-size 16384 --pool-gb 8 --mode scattered
//   Client: ./rdma_scatter_bench client --dev mlx5_3 --gpu 0 --port 19875 \
//               --server-ip 10.0.66.42 --num-blocks 40960 --block-size 16384 \
//               --pool-gb 8 --mode scattered --transfers 5

#include <hip/hip_runtime.h>
#include <infiniband/verbs.h>

#include <algorithm>
#include <arpa/inet.h>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <netdb.h>
#include <numeric>
#include <random>
#include <sys/resource.h>
#include <sys/socket.h>
#include <unistd.h>
#include <vector>

#define CHECK_HIP(call)                                                        \
    do {                                                                        \
        hipError_t e = (call);                                                  \
        if (e != hipSuccess) {                                                  \
            fprintf(stderr, "HIP error %d at %s:%d: %s\n", e, __FILE__,        \
                    __LINE__, hipGetErrorString(e));                             \
            exit(1);                                                            \
        }                                                                       \
    } while (0)

// ============================================================================
// Structures
// ============================================================================

struct Config {
    bool is_server = true;
    const char *dev_name = "mlx5_3";
    int gpu_id = 0;
    int gid_index = 3; // RoCEv2 GID index
    int port = 19875;
    const char *server_ip = nullptr;
    int num_blocks = 40960;
    int block_size = 16384; // 16 KB
    size_t pool_gb = 8;
    bool scattered = false;
    int transfers = 5;
    int seed = 42;
    int sq_depth = 8192;
    int cq_depth = 16384;
    int signal_every = 512;
    int max_rd_atomic = 16;
    const char *start_barrier = nullptr; // wait for this file before transfers
    bool rerandomize = false; // regenerate random offsets for each transfer
};

struct QPInfo {
    uint32_t qp_num;
    uint32_t psn;
    union ibv_gid gid;
    uint64_t mr_addr;
    uint32_t mr_rkey;
};

// ============================================================================
// Argument parsing
// ============================================================================

static Config parse_args(int argc, char **argv) {
    Config c;
    if (argc < 2) {
        fprintf(stderr,
                "Usage: %s [server|client] [options]\n"
                "  --dev <name>        IB device (default: mlx5_3)\n"
                "  --gpu <id>          GPU device ID (default: 0)\n"
                "  --gid-index <idx>   GID index for RoCEv2 (default: 3)\n"
                "  --port <p>          TCP port (default: 19875)\n"
                "  --server-ip <ip>    Server IP (client only)\n"
                "  --num-blocks <n>    Number of 16KB blocks (default: 40960)\n"
                "  --block-size <b>    Block size in bytes (default: 16384)\n"
                "  --pool-gb <g>       GPU memory pool in GB (default: 8)\n"
                "  --mode <m>          contiguous or scattered (default: contiguous)\n"
                "  --transfers <t>     Number of transfers (default: 5)\n"
                "  --seed <s>          Random seed for scattered mode (default: 42)\n"
                "  --sq-depth <d>      Send queue depth (default: 8192)\n"
                "  --signal-every <n>  Signal completion every N WRs (default: 512)\n"
                "  --max-rd-atomic <n> Max outstanding RDMA READs (default: 16)\n"
                "  --start-barrier <f> Wait for file <f> to exist before transfers\n"
                "  --rerandomize       Re-generate scattered offsets each transfer (cold start sim)\n",
                argv[0]);
        exit(1);
    }

    c.is_server = (strcmp(argv[1], "server") == 0);

    for (int i = 2; i < argc; i++) {
        if (strcmp(argv[i], "--dev") == 0 && i + 1 < argc)
            c.dev_name = argv[++i];
        else if (strcmp(argv[i], "--gpu") == 0 && i + 1 < argc)
            c.gpu_id = atoi(argv[++i]);
        else if (strcmp(argv[i], "--gid-index") == 0 && i + 1 < argc)
            c.gid_index = atoi(argv[++i]);
        else if (strcmp(argv[i], "--port") == 0 && i + 1 < argc)
            c.port = atoi(argv[++i]);
        else if (strcmp(argv[i], "--server-ip") == 0 && i + 1 < argc)
            c.server_ip = argv[++i];
        else if (strcmp(argv[i], "--num-blocks") == 0 && i + 1 < argc)
            c.num_blocks = atoi(argv[++i]);
        else if (strcmp(argv[i], "--block-size") == 0 && i + 1 < argc)
            c.block_size = atoi(argv[++i]);
        else if (strcmp(argv[i], "--pool-gb") == 0 && i + 1 < argc)
            c.pool_gb = atoll(argv[++i]);
        else if (strcmp(argv[i], "--mode") == 0 && i + 1 < argc) {
            c.scattered = (strcmp(argv[++i], "scattered") == 0);
        } else if (strcmp(argv[i], "--transfers") == 0 && i + 1 < argc)
            c.transfers = atoi(argv[++i]);
        else if (strcmp(argv[i], "--seed") == 0 && i + 1 < argc)
            c.seed = atoi(argv[++i]);
        else if (strcmp(argv[i], "--sq-depth") == 0 && i + 1 < argc)
            c.sq_depth = atoi(argv[++i]);
        else if (strcmp(argv[i], "--signal-every") == 0 && i + 1 < argc)
            c.signal_every = atoi(argv[++i]);
        else if (strcmp(argv[i], "--max-rd-atomic") == 0 && i + 1 < argc)
            c.max_rd_atomic = atoi(argv[++i]);
        else if (strcmp(argv[i], "--start-barrier") == 0 && i + 1 < argc)
            c.start_barrier = argv[++i];
        else if (strcmp(argv[i], "--rerandomize") == 0)
            c.rerandomize = true;
    }

    if (!c.is_server && !c.server_ip) {
        fprintf(stderr, "Client mode requires --server-ip\n");
        exit(1);
    }
    return c;
}

// ============================================================================
// Block offset generation
// ============================================================================

static std::vector<uint64_t> generate_offsets(int num_blocks, int block_size,
                                               size_t pool_size, bool scattered,
                                               int seed) {
    size_t num_slots = pool_size / block_size;
    if ((size_t)num_blocks > num_slots) {
        fprintf(stderr, "Pool too small: %zu slots < %d blocks\n", num_slots,
                num_blocks);
        exit(1);
    }

    std::vector<uint64_t> offsets(num_blocks);

    if (!scattered) {
        for (int i = 0; i < num_blocks; i++)
            offsets[i] = (uint64_t)i * block_size;
    } else {
        // Randomly pick num_blocks unique slots from the pool, then shuffle
        std::vector<size_t> all_slots(num_slots);
        std::iota(all_slots.begin(), all_slots.end(), 0);
        std::mt19937_64 rng(seed);
        std::shuffle(all_slots.begin(), all_slots.end(), rng);
        for (int i = 0; i < num_blocks; i++)
            offsets[i] = all_slots[i] * block_size;
    }
    return offsets;
}

// ============================================================================
// TCP exchange helpers
// ============================================================================

static int tcp_listen(int port) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    int opt = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));
    struct sockaddr_in addr = {};
    addr.sin_family = AF_INET;
    addr.sin_port = htons(port);
    addr.sin_addr.s_addr = INADDR_ANY;
    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        perror("bind");
        exit(1);
    }
    listen(fd, 1);
    return fd;
}

static int tcp_accept(int listen_fd) {
    int fd = accept(listen_fd, nullptr, nullptr);
    if (fd < 0) {
        perror("accept");
        exit(1);
    }
    return fd;
}

static int tcp_connect(const char *ip, int port) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in addr = {};
    addr.sin_family = AF_INET;
    addr.sin_port = htons(port);
    inet_pton(AF_INET, ip, &addr.sin_addr);
    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        perror("connect");
        exit(1);
    }
    return fd;
}

static void tcp_exchange(int fd, const QPInfo *local, QPInfo *remote) {
    if (write(fd, local, sizeof(QPInfo)) != sizeof(QPInfo)) {
        perror("write QPInfo");
        exit(1);
    }
    if (read(fd, remote, sizeof(QPInfo)) != sizeof(QPInfo)) {
        perror("read QPInfo");
        exit(1);
    }
}

static void tcp_sync(int fd) {
    char c = 'R';
    write(fd, &c, 1);
    read(fd, &c, 1);
}

// ============================================================================
// RDMA helpers
// ============================================================================

static struct ibv_context *open_device(const char *name) {
    int n;
    struct ibv_device **list = ibv_get_device_list(&n);
    for (int i = 0; i < n; i++) {
        if (strcmp(ibv_get_device_name(list[i]), name) == 0) {
            struct ibv_context *ctx = ibv_open_device(list[i]);
            ibv_free_device_list(list);
            return ctx;
        }
    }
    fprintf(stderr, "Device %s not found\n", name);
    ibv_free_device_list(list);
    exit(1);
}

static void modify_qp_to_init(struct ibv_qp *qp, int port_num) {
    struct ibv_qp_attr attr = {};
    attr.qp_state = IBV_QPS_INIT;
    attr.pkey_index = 0;
    attr.port_num = port_num;
    attr.qp_access_flags =
        IBV_ACCESS_REMOTE_READ | IBV_ACCESS_REMOTE_WRITE | IBV_ACCESS_LOCAL_WRITE;
    if (ibv_modify_qp(qp, &attr,
                       IBV_QP_STATE | IBV_QP_PKEY_INDEX | IBV_QP_PORT |
                           IBV_QP_ACCESS_FLAGS)) {
        perror("modify_qp INIT");
        exit(1);
    }
}

static void modify_qp_to_rtr(struct ibv_qp *qp, uint32_t remote_qpn,
                               union ibv_gid remote_gid, int port_num,
                               int gid_index, int max_rd_atomic) {
    struct ibv_qp_attr attr = {};
    attr.qp_state = IBV_QPS_RTR;
    attr.path_mtu = IBV_MTU_4096;
    attr.dest_qp_num = remote_qpn;
    attr.rq_psn = 0;
    attr.max_dest_rd_atomic = max_rd_atomic;
    attr.min_rnr_timer = 12;
    attr.ah_attr.dlid = 0;
    attr.ah_attr.sl = 0;
    attr.ah_attr.src_path_bits = 0;
    attr.ah_attr.port_num = port_num;
    attr.ah_attr.is_global = 1;
    attr.ah_attr.grh.dgid = remote_gid;
    attr.ah_attr.grh.flow_label = 0;
    attr.ah_attr.grh.hop_limit = 64;
    attr.ah_attr.grh.sgid_index = gid_index;
    attr.ah_attr.grh.traffic_class = 0;
    if (ibv_modify_qp(qp, &attr,
                       IBV_QP_STATE | IBV_QP_AV | IBV_QP_PATH_MTU |
                           IBV_QP_DEST_QPN | IBV_QP_RQ_PSN |
                           IBV_QP_MAX_DEST_RD_ATOMIC | IBV_QP_MIN_RNR_TIMER)) {
        perror("modify_qp RTR");
        exit(1);
    }
}

static void modify_qp_to_rts(struct ibv_qp *qp, int max_rd_atomic) {
    struct ibv_qp_attr attr = {};
    attr.qp_state = IBV_QPS_RTS;
    attr.timeout = 14;
    attr.retry_cnt = 7;
    attr.rnr_retry = 7;
    attr.sq_psn = 0;
    attr.max_rd_atomic = max_rd_atomic;
    if (ibv_modify_qp(qp, &attr,
                       IBV_QP_STATE | IBV_QP_TIMEOUT | IBV_QP_RETRY_CNT |
                           IBV_QP_RNR_RETRY | IBV_QP_SQ_PSN |
                           IBV_QP_MAX_QP_RD_ATOMIC)) {
        perror("modify_qp RTS");
        exit(1);
    }
}

// ============================================================================
// Main benchmark
// ============================================================================

int main(int argc, char **argv) {
    // Raise memlock limit for large MR registrations
    struct rlimit rl = {RLIM_INFINITY, RLIM_INFINITY};
    if (setrlimit(RLIMIT_MEMLOCK, &rl) != 0)
        perror("setrlimit(MEMLOCK) - may need CAP_SYS_RESOURCE");

    Config cfg = parse_args(argc, argv);

    size_t pool_size = cfg.pool_gb * (size_t)(1024 * 1024 * 1024);
    size_t data_size = (size_t)cfg.num_blocks * cfg.block_size;
    const char *mode_str = cfg.scattered ? "scattered" : "contiguous";

    printf("========================================\n");
    printf("RDMA Scatter Benchmark (%s)\n", cfg.is_server ? "SERVER" : "CLIENT");
    printf("========================================\n");
    printf("  Device:      %s\n", cfg.dev_name);
    printf("  GPU:         %d\n", cfg.gpu_id);
    printf("  Mode:        %s\n", mode_str);
    printf("  Blocks:      %d x %d bytes = %.1f MB\n", cfg.num_blocks,
           cfg.block_size, data_size / (1024.0 * 1024.0));
    printf("  Pool:        %zu GB\n", cfg.pool_gb);
    printf("  Transfers:   %d\n", cfg.transfers);
    printf("  SQ depth:    %d\n", cfg.sq_depth);
    printf("  Signal every: %d\n", cfg.signal_every);
    printf("  max_rd_atomic: %d\n", cfg.max_rd_atomic);
    printf("========================================\n\n");

    // --- GPU memory ---
    CHECK_HIP(hipSetDevice(cfg.gpu_id));
    void *gpu_buf = nullptr;
    CHECK_HIP(hipMalloc(&gpu_buf, pool_size));
    CHECK_HIP(hipMemset(gpu_buf, 0, pool_size));
    printf("GPU %d: allocated %zu GB at %p\n", cfg.gpu_id, cfg.pool_gb,
           gpu_buf);

    // Generate block offsets
    auto offsets =
        generate_offsets(cfg.num_blocks, cfg.block_size, pool_size,
                         cfg.scattered, cfg.seed);
    printf("Block offsets: %s (first=%lu, last=%lu)\n", mode_str, offsets[0],
           offsets[cfg.num_blocks - 1]);

    // --- RDMA resources ---
    struct ibv_context *ctx = open_device(cfg.dev_name);
    struct ibv_pd *pd = ibv_alloc_pd(ctx);
    struct ibv_cq *cq = ibv_create_cq(ctx, cfg.cq_depth, nullptr, nullptr, 0);

    struct ibv_mr *mr =
        ibv_reg_mr(pd, gpu_buf, pool_size,
                   IBV_ACCESS_LOCAL_WRITE | IBV_ACCESS_REMOTE_READ |
                       IBV_ACCESS_REMOTE_WRITE);
    if (!mr) {
        perror("ibv_reg_mr");
        exit(1);
    }
    printf("MR registered: lkey=0x%x rkey=0x%x\n", mr->lkey, mr->rkey);

    struct ibv_qp_init_attr qp_init = {};
    qp_init.send_cq = cq;
    qp_init.recv_cq = cq;
    qp_init.qp_type = IBV_QPT_RC;
    qp_init.cap.max_send_wr = cfg.sq_depth;
    qp_init.cap.max_recv_wr = 1;
    qp_init.cap.max_send_sge = 1;
    qp_init.cap.max_recv_sge = 1;
    struct ibv_qp *qp = ibv_create_qp(pd, &qp_init);
    if (!qp) {
        perror("ibv_create_qp");
        exit(1);
    }

    int ib_port = 1;
    modify_qp_to_init(qp, ib_port);

    // Get local GID
    union ibv_gid local_gid;
    ibv_query_gid(ctx, ib_port, cfg.gid_index, &local_gid);

    QPInfo local_info = {};
    local_info.qp_num = qp->qp_num;
    local_info.psn = 0;
    local_info.gid = local_gid;
    local_info.mr_addr = (uint64_t)gpu_buf;
    local_info.mr_rkey = mr->rkey;

    // --- TCP exchange ---
    int tcp_fd;
    QPInfo remote_info = {};

    if (cfg.is_server) {
        int listen_fd = tcp_listen(cfg.port);
        printf("Listening on port %d...\n", cfg.port);
        tcp_fd = tcp_accept(listen_fd);
        printf("Client connected.\n");
        close(listen_fd);
        tcp_exchange(tcp_fd, &local_info, &remote_info);
    } else {
        printf("Connecting to %s:%d...\n", cfg.server_ip, cfg.port);
        tcp_fd = tcp_connect(cfg.server_ip, cfg.port);
        printf("Connected.\n");
        tcp_exchange(tcp_fd, &local_info, &remote_info);
    }

    printf("Remote QP: qp_num=%u, MR addr=%p, rkey=0x%x\n", remote_info.qp_num,
           (void *)remote_info.mr_addr, remote_info.mr_rkey);

    // --- QP transitions ---
    modify_qp_to_rtr(qp, remote_info.qp_num, remote_info.gid, ib_port,
                      cfg.gid_index, cfg.max_rd_atomic);
    modify_qp_to_rts(qp, cfg.max_rd_atomic);
    printf("QP ready (INIT->RTR->RTS, max_rd_atomic=%d)\n", cfg.max_rd_atomic);

    tcp_sync(tcp_fd);
    printf("\n");

    // --- Wait for barrier if specified ---
    if (cfg.start_barrier) {
        printf("Waiting for barrier file: %s\n", cfg.start_barrier);
        while (access(cfg.start_barrier, F_OK) != 0)
            usleep(1000); // poll every 1ms
        printf("Barrier released! Starting benchmark.\n");
    }

    // --- Benchmark (client only) ---
    if (!cfg.is_server) {
        // Remote offsets: server's block layout (same seed → same offsets)
        auto remote_offsets =
            generate_offsets(cfg.num_blocks, cfg.block_size, pool_size,
                             cfg.scattered, cfg.seed);
        // Local offsets: client's block layout (same mode)
        auto local_offsets = offsets;

        printf("Starting %d transfers of %d blocks (%s%s, %.1f MB each)...\n\n",
               cfg.transfers, cfg.num_blocks, mode_str,
               cfg.rerandomize ? ", rerandomize" : "",
               data_size / (1024.0 * 1024.0));

        for (int t = 0; t < cfg.transfers; t++) {
            if (cfg.rerandomize && cfg.scattered) {
                unsigned new_seed = cfg.seed + t + 1;
                local_offsets =
                    generate_offsets(cfg.num_blocks, cfg.block_size, pool_size,
                                     true, new_seed);
                remote_offsets =
                    generate_offsets(cfg.num_blocks, cfg.block_size, pool_size,
                                     true, new_seed + 10000);
            }
            auto t_start = std::chrono::high_resolution_clock::now();

            int posted = 0;
            int completed = 0;

            while (posted < cfg.num_blocks || completed < cfg.num_blocks) {
                // Post as many WRs as SQ space allows
                int can_post =
                    std::min(cfg.sq_depth - (posted - completed),
                             cfg.num_blocks - posted);

                for (int i = 0; i < can_post; i++) {
                    int idx = posted + i;
                    bool do_signal =
                        ((idx + 1) % cfg.signal_every == 0) ||
                        (idx == cfg.num_blocks - 1);

                    struct ibv_sge sge = {};
                    sge.addr = (uint64_t)gpu_buf + local_offsets[idx];
                    sge.length = cfg.block_size;
                    sge.lkey = mr->lkey;

                    struct ibv_send_wr wr = {};
                    wr.wr_id = idx;
                    wr.opcode = IBV_WR_RDMA_READ;
                    wr.sg_list = &sge;
                    wr.num_sge = 1;
                    wr.send_flags = do_signal ? IBV_SEND_SIGNALED : 0;
                    wr.wr.rdma.remote_addr =
                        remote_info.mr_addr + remote_offsets[idx];
                    wr.wr.rdma.rkey = remote_info.mr_rkey;

                    struct ibv_send_wr *bad_wr = nullptr;
                    if (ibv_post_send(qp, &wr, &bad_wr)) {
                        fprintf(stderr, "ibv_post_send failed at idx=%d\n",
                                idx);
                        perror("ibv_post_send");
                        exit(1);
                    }
                }
                posted += can_post;

                // Poll for completions
                struct ibv_wc wc[64];
                int ne = ibv_poll_cq(cq, 64, wc);
                if (ne < 0) {
                    fprintf(stderr, "ibv_poll_cq failed\n");
                    exit(1);
                }
                for (int i = 0; i < ne; i++) {
                    if (wc[i].status != IBV_WC_SUCCESS) {
                        fprintf(stderr,
                                "WC error: wr_id=%lu status=%d (%s)\n",
                                wc[i].wr_id, wc[i].status,
                                ibv_wc_status_str(wc[i].status));
                        exit(1);
                    }
                    // Each signaled completion covers signal_every WRs
                    int sig_idx = wc[i].wr_id;
                    int prev_sig;
                    if (sig_idx == cfg.num_blocks - 1) {
                        prev_sig = (sig_idx / cfg.signal_every) *
                                   cfg.signal_every;
                    } else {
                        prev_sig = sig_idx - cfg.signal_every + 1;
                    }
                    completed = sig_idx + 1;
                }
            }

            auto t_end = std::chrono::high_resolution_clock::now();
            double elapsed_ms =
                std::chrono::duration<double, std::milli>(t_end - t_start)
                    .count();
            double gbps = (data_size * 8.0) / (elapsed_ms * 1e6);

            printf("  Transfer %d: %.1f ms  %.1f Gbps  (%.1f MB)\n", t + 1,
                   elapsed_ms, gbps, data_size / (1024.0 * 1024.0));
        }

        printf("\nDone. Signaling server.\n");
        tcp_sync(tcp_fd);
    } else {
        printf("Waiting for client to complete transfers...\n");
        tcp_sync(tcp_fd);
        printf("Client done.\n");
    }

    // --- Cleanup ---
    close(tcp_fd);
    ibv_destroy_qp(qp);
    ibv_destroy_cq(cq);
    ibv_dereg_mr(mr);
    ibv_dealloc_pd(pd);
    ibv_close_device(ctx);
    CHECK_HIP(hipFree(gpu_buf));

    return 0;
}
