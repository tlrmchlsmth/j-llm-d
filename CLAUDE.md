# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Preferences

- Use `podman` instead of `docker` for container builds

## Repository Overview

This is a development workspace for llm-d (https://github.com/llm-d/llm-d), a Kubernetes-native distributed inference serving stack for large language models. The repository contains:

- `llm-d/` - Git submodule pointing to the main llm-d project
- Custom deployment configurations and automation for testing llm-d deployments
- Benchmarking and profiling tools for measuring inference performance

## Architecture

llm-d provides three well-lit paths for deploying large models:

1. **Intelligent Inference Scheduling** - vLLM behind Inference Gateway (IGW) with predicted latency balancing, prefix-cache aware routing, and customizable scheduling
2. **Prefill/Decode Disaggregation** - Split inference into prefill servers (handling prompts) and decode servers (handling responses) to reduce TTFT and improve TPOT predictability
3. **Wide Expert-Parallelism** - Deploy large MoE models like DeepSeek-R1 with Data Parallelism and Expert Parallelism over fast accelerator networks

Key components:
- **vLLM** - Default model server and inference engine
- **Inference Gateway (IGW)** - Request scheduler and balancer using Envoy proxy
- **Kubernetes** - Infrastructure orchestrator and workload control plane
- **NIXL** - Fast interconnect library for KV cache transfer (RDMA, IB/RoCE, TPU ICI)

## Common Commands

This repository uses `just` as the task runner. Commands are defined in `Justfile` for local orchestration and `Justfile.remote` for in-cluster operations.

### Environment Setup

The Justfile requires a `.env` file with:
- `HF_TOKEN` - HuggingFace token for model access
- `GH_TOKEN` - GitHub token
- `NAMESPACE` - Kubernetes namespace (default: `vllm`)
- `NVIDIA_KUBECONFIG` - Path to alternate kubeconfig for nvidia cluster (fp4 deployments)
- `POKER_IMAGE` - Poker container image repository (required)
- `POKER_TAG` - Poker container image tag (required)

### Deployment Commands

```bash
# List available commands
just

# Create required secrets in the namespace
just create-secrets

# Start the full stack (wide-ep-lws guide)
just start

# Stop and clean up the deployment
just stop

# Restart the deployment
just restart

# Deploy a "poker" pod for interactive testing
just start-poker

# Get an interactive shell in the poker pod with Justfile.remote
just poke

# FP4 model deployment (nvidia cluster)
just start-fp4      # Deploy fp4 model servers only
just stop-fp4       # Clean up fp4 deployment
just restart-fp4    # Restart fp4 deployment

# Poker pod deployment (auto-detects cluster via NVIDIA_KUBECONFIG)
just start-poker    # Deploy poker pod (uses nvidia cluster if NVIDIA_KUBECONFIG set)
just poke           # Interactive shell in poker pod (auto-detects cluster)
```

### Monitoring and Debugging

```bash
# Get decode pod names and IPs (cached to .tmp/decode_pods.txt)
just get-decode-pods

# Print GPU allocation across all nodes
just print-gpus

# Print CoreWeave node details
just cks-nodes

# Copy PyTorch traces from all decode pods to ./traces/N (N auto-increments)
just copy-traces
```

#### Grafana Annotations

Benchmark commands automatically create Grafana annotations that appear as vertical lines on time series panels, marking benchmark start/end with parameters.

**Automatic annotations**: The `benchmark` and `benchmark_g` commands in `Justfile.remote` automatically create annotations when executed.

**Manual annotation creation** (from within poker pod):
```bash
# Panel-specific annotation (appears on specific dashboard panel)
curl -X POST "http://grafana.vllm.svc.cluster.local/api/annotations" \
  -u "admin:admin" \
  -H "Content-Type: application/json" \
  -d '{
    "dashboardId": 7,
    "panelId": 1,
    "time": '"$(date +%s)000"',
    "text": "BENCHMARK START\nType: GuideILM\nConcurrency: 128\nRequests: 1000",
    "tags": ["benchmark", "start"]
  }'
```

**Finding Dashboard and Panel IDs**:
- **Dashboard ID**: Check the URL when viewing your dashboard: `http://localhost:3000/d/DASHBOARD_ID/dashboard-name`
- **Panel ID**: Edit the panel → look at the URL: `...&editPanel=PANEL_ID`

**Authentication**: Annotations require Grafana authentication. The default `admin:admin` credentials are configured in the `_annotate` function in `Justfile.remote`.

### Benchmarking

The repository includes two approaches for benchmarking:

**Parallel benchmarking with GuideILM** (from local machine):
```bash
just parallel-guidellm [CONCURRENT_PER_WORKER] [REQUESTS_PER_WORKER] [INPUT_LEN] [OUTPUT_LEN] [N_WORKERS]
# Example: just parallel-guidellm 4000 4000 128 1000 4
```

**In-cluster benchmarking** (via `just poke` shell using Justfile.remote):
```bash
# Standard benchmark using vLLM bench
just benchmark [MAX_CONCURRENCY] [NUM_REQUESTS] [INPUT_LEN] [OUTPUT_LEN]

# GuideILM-based benchmark
just benchmark_g [MAX_CONCURRENCY] [NUM_REQUESTS] [INPUT_LEN] [OUTPUT_LEN]

# Pure decode workload (simulates steady-state P/D decode side)
just benchmark_decode_workload [NUM_REQUESTS] [OUTPUT_LEN]

# Benchmark individual vLLM instance (bypassing gateway)
just benchmark_no_pd [POD_IP] [REQUEST_RATE] [NUM_REQUESTS] [INPUT_LEN] [OUTPUT_LEN]

# LM evaluation harness
just eval
```

### Profiling

**Profiling commands** (via `just poke` shell using Justfile.remote):
```bash
# Profile a single vLLM instance
just profile [URL]

# Profile all decode pods: starts profiling on all, waits 1s, stops all
just profile_all_decode
```

### Results Aggregation

After running parallel benchmarks:
```bash
# Aggregate results from N workers (assumes 0.json, 1.json, ..., N-1.json)
python agg.py [N] [--use-total] [--show-details]
```

## Key Configuration Files

- `Justfile` - Local automation and deployment orchestration
- `Justfile.remote` - In-cluster benchmarking commands (copied to poker pod)
- `poker.yaml` - Interactive testing pod definition
- `parallel-guidellm.yaml` - Kubernetes Job template for parallel benchmarking
- `llm-d/guides/wide-ep-lws/` - Wide expert-parallelism guide (primary focus of this workspace)
  - `manifests/modelserver/coreweave/` - CoreWeave-specific model server configs
  - `manifests/modelserver/gb200_dsv31_fp4/` - Nvidia cluster FP4 model server configs
  - `manifests/gateway/istio/` - Istio gateway configurations
  - `inferencepool.values.yaml` - Helm values for InferencePool

## Development Workflow

1. **Deploy the stack**: `just start` deploys model servers, InferencePool, and gateway
2. **Get pod information**: `just get-decode-pods` fetches and caches decode pod names/IPs (automatically called by other commands)
3. **Interactive testing**: `just poke` opens a shell in the poker pod with benchmarking tools
   - Note: `just poke` automatically discovers decode pod IPs and injects them into the Justfile inside the poker pod
4. **Run benchmarks**: Use commands from Justfile.remote to test inference performance
5. **Profile decode pods**: `just profile_all_decode` (from poker pod) starts/stops profiling on all decode pods
6. **Copy traces**: `just copy-traces` retrieves PyTorch traces from pods to `./traces/N/`
7. **Parallel load testing**: `just parallel-guidellm` runs distributed load tests
8. **Aggregate results**: `python agg.py N` sums throughput across parallel workers
9. **Iterate**: Modify configurations and `just restart`

## Important Notes

- The wide-ep-lws guide requires **24x H200 GPUs** with InfiniBand RDMA across 3 nodes
- Default model is `deepseek-ai/DeepSeek-R1-0528` configured with DP=8 (1 prefill + 2 decode workers)
- FP4 model deployment uses `nvidia/DeepSeek-R1-0528-FP4-v2` on nvidia cluster via gb200_dsv31_fp4 manifests
- Deployment uses LeaderWorkerSet for multi-host inference coordination
- vLLM API servers can take **7-10 minutes** to start up for large MoE models
- CoreWeave-specific configurations include custom scheduler (`custom-binpack-scheduler`) and RDMA resources
- The poker pod image (configured via required `POKER_IMAGE` env var) includes pre-installed benchmarking tools (vllm, guidellm, lm_eval)
- PyTorch profiling traces are stored in decode pods at `/traces` and copied locally to `./traces/` (gitignored)
- Decode pod information is cached in `.tmp/decode_pods.txt` to avoid repeated kubectl queries
- Dual cluster support: CoreWeave (default kubectl) and nvidia cluster (via NVIDIA_KUBECONFIG)

## Just Variable Expansion Notes

When working with Just recipes, be aware of how variable expansion works with quotes:

- **Just strips outer quotes during expansion**: If you define `VAR := "value with spaces"`, then `{{VAR}}` expands to `value with spaces` (quotes removed)
- **Add quotes in bash assignments**: When using Just variables in bash scripts, wrap the expansion in quotes: `BASH_VAR="{{JUST_VAR}}"` to properly handle values with spaces
- **Example from this codebase**:
  - Justfile variable: `DECODE_POD_IPS := "10.0.2.28 10.0.3.185"`
  - Bash usage in recipe: `DECODE_IPS="{{DECODE_POD_IPS}}"` (quotes around the expansion)
  - Result after expansion: `DECODE_IPS="10.0.2.28 10.0.3.185"` ✅
  - Without quotes: `DECODE_IPS={{DECODE_POD_IPS}}` → `DECODE_IPS=10.0.2.28 10.0.3.185` → bash error (tries to run `10.0.3.185` as a command)
