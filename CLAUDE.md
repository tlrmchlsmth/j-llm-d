# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Preferences

- Use `podman` instead of `docker` for container builds
- Prefer `just` commands when available — never run `kubectl apply` directly if a Justfile recipe exists for it (e.g. `just start`, `just restart`). Direct applies bypass `$DEPLOY_USER` namespacing and other setup.

## Repository Overview

This is a development workspace for [llm-d](https://github.com/llm-d/llm-d), a Kubernetes-native distributed inference serving stack for large language models. The current focus is deploying DeepSeek-R1 on **GB200 NVL72** clusters with wide expert-parallelism and prefill/decode disaggregation.

The repository contains:

- `llm-d/` - Git submodule pointing to the main llm-d project
- `gb200/` - Kustomize-based deployment manifests for GB200 NVL72 (model servers, gateway, InferencePool)
- `poker/` - Interactive in-cluster benchmarking pod (Dockerfile + manifests)
- `dev/` - Persistent CPU-only pod for building vLLM from source on Lustre
- `monitoring/` - Namespace-scoped Prometheus + Grafana stack
- `profiling/` - PyTorch profiler trace processing scripts
- `local/` - SSH tunnel scripts for remote cluster access (GB200, OCI bastions)
- `glm-pareto/` - Pareto frontier analysis results (TP/EP/DP/P+D configurations)
- `pd-config/` - AI Configurator sweep configs and results for Llama 3.1 70B

## Architecture

llm-d provides three well-lit paths for deploying large models:

1. **Intelligent Inference Scheduling** - vLLM behind Inference Gateway (IGW) with predicted latency balancing, prefix-cache aware routing, and customizable scheduling
2. **Prefill/Decode Disaggregation** - Split inference into prefill servers (handling prompts) and decode servers (handling responses) to reduce TTFT and improve TPOT predictability
3. **Wide Expert-Parallelism** - Deploy large MoE models like DeepSeek-R1 with Data Parallelism and Expert Parallelism over fast accelerator networks

Key components:
- **vLLM** - Model server and inference engine
- **Inference Gateway (IGW)** - Request scheduler and balancer using Envoy proxy (via Gateway API InferencePool)
- **Kubernetes** - Infrastructure orchestrator and workload control plane
- **LeaderWorkerSet (LWS)** - Multi-host inference coordination
- **NIXL** - Fast interconnect library for KV cache transfer (RDMA, IB/RoCE)

## Current Deployment Target

- **Hardware**: GB200 NVL72 with InfiniBand RDMA
- **Model**: `nvidia/DeepSeek-R1-NVFP4` (FP4 quantized)
- **Topology**: Prefill LWS + Decode LWS (4 vLLM processes per pod)
- **Namespace**: `vllm` (configurable)
- **Naming**: All resources prefixed with `$DEPLOY_USER-wide-ep` (e.g., `$DEPLOY_USER-wide-ep-decode`)
- **Storage**: Lustre PVC (`lustre-pvc-vllm`) for shared vLLM builds and caches

## Decode vs Prefill Architecture

Decode and prefill pods differ in important ways:

- **Decode**: Has routing sidecar init containers (proxy ports 8000-8003 → vLLM ports 8200-8203). Uses `deepep_low_latency` all2all backend and MNNVL for cross-pod NVLink fabric. `TP_SIZE` defaults to 1 (pure EP).
- **Prefill**: No routing sidecars — serves directly on ports 8000-8003. Uses `deepep_high_throughput` all2all backend. `TP_SIZE` defaults to 1 (pure EP, same as decode).

The `TP_SIZE` env var controls tensor parallelism per DP rank. `DP_SIZE_LOCAL` is derived as `4 / TP_SIZE` (4 GPUs per pod). Changing `TP_SIZE` changes the TP/EP tradeoff without modifying the launch script.

## Common Commands

This repository uses `just` as the task runner. Commands are defined in `Justfile` for local orchestration and `Justfile.remote` for in-cluster operations.

### Environment Setup

The Justfile requires a `.env` file with:
- `HF_TOKEN` - HuggingFace token for model access
- `GH_TOKEN` - GitHub token
- `KUBECONFIG` - Path to kubeconfig
- `DEPLOY_USER` - (optional) Override username for resource naming (defaults to `$USER`)

### Deployment Commands

```bash
just                     # List available commands
just create-secrets      # Create HF and GH secrets in the namespace

# Start the full stack (model servers + InferencePool + gateway)
just start               # Default: P/D mode with load-aware routing
just start pd            # Explicit P/D mode (prefill + decode)
just start decode-bench  # Pure decode benchmark mode (no prefill)
just start pd pd         # P/D mode with P/D-aware routing
just start pd load-aware true  # P/D mode with dev vLLM build from Lustre

just stop                # Tear down everything
just restart             # Stop then start

just deploy_inferencepool load-aware  # Redeploy InferencePool with different routing
# Routing options: load-aware, random, pd
```

### Interactive Testing

```bash
just start-poker  # Deploy the poker pod (benchmarking/debugging container)
just poke          # Exec into poker pod (injects BASE_URL and copies Justfile.remote)
```

### Monitoring and Debugging

```bash
just get-decode-pods  # Fetch decode pod names/IPs (cached to .tmp/decode_pods.txt)
just print-gpus       # Print GPU allocation across all nodes
just cks-nodes        # Print CoreWeave node details
just check-ib         # Check InfiniBand port health on GPU nodes

# Monitoring stack (namespace-scoped, no cluster-admin required)
just start-monitoring  # Install Prometheus + Grafana via Helm
just stop-monitoring   # Uninstall monitoring stack
just grafana           # Port-forward Grafana to localhost:3000
just prometheus        # Port-forward Prometheus to localhost:9090
just load-dashboards   # Load vLLM Grafana dashboards from ConfigMaps
```

### Benchmarking

**From local machine:**
```bash
# Parallel vLLM bench (Kubernetes Job with N indexed workers)
just parallel-guidellm [CONCURRENT] [REQUESTS] [INPUT_LEN] [OUTPUT_LEN] [N_WORKERS]

# inference-perf (kubernetes-sigs/inference-perf, concurrent load)
just inference-perf [NUM_REQUESTS] [INPUT_LEN] [OUTPUT_LEN] [NUM_WORKERS] [WORKER_MAX_CONCURRENCY]
just inference-perf-logs  # Tail inference-perf results
```

**In-cluster benchmarking** (via `just poke` shell using Justfile.remote):
```bash
just benchmark MC NUM_REQUESTS INPUT_LEN OUTPUT_LEN       # vllm bench serve
just benchmark_g MC NUM_REQUESTS INPUT_LEN OUTPUT_LEN      # GuideILM
just benchmark_decode_workload NUM_REQUESTS OUTPUT_LEN     # Pure decode (input_len=1)
just benchmark_no_pd POD_IP RR NUM_REQUESTS INPUT_LEN OUTPUT_LEN  # Direct pod
just eval                                                   # lm_eval harness (gsm8k)
```

### Profiling

```bash
# End-to-end: start profiles on all decode ranks, copy traces, process, open
just profile

# Individual steps:
just copy-traces           # Copy traces from decode pods to ./traces/N/
just process-traces [N]    # Combine per-rank traces + fix Perfetto overlaps
```

### Dev Environment (vLLM from source on Lustre)

```bash
just dev-start       # Deploy persistent CPU-only dev pod on Lustre
just dev             # Exec into dev pod
just dev-build       # Build vLLM from source in background (survives disconnects)
just dev-build-log   # Tail the build log
just dev-stop        # Delete the dev pod
just flush-cache     # Clear vLLM/FlashInfer compile caches on Lustre
```

After building, deploy with `just start pd load-aware true` to use the dev vLLM build.

## Key Configuration Files

- `Justfile` - Local automation and deployment orchestration
- `Justfile.remote` - In-cluster benchmarking commands (copied to poker pod via `just poke`)
- `gb200/base/` - Base kustomize resources (decode LWS, prefill LWS, service account)
- `gb200/overlays/pd/` - P/D overlay (adds NixlConnector KV transfer config)
- `gb200/overlays/decode-bench/` - Decode-bench overlay (removes prefill, adds DecodeBenchConnector)
- `gb200/gateway.yaml` - Istio Gateway + Service
- `gb200/httproute.yaml` - HTTPRoute to InferencePool
- `gb200/inferencepool-*.values.yaml` - Helm values for InferencePool routing strategies
- `inference-perf-job.yaml` - kubernetes-sigs/inference-perf Job + ConfigMap template
- `parallel-guidellm.yaml` - Kubernetes Job template for parallel vllm bench
- `poker/poker.yaml` - Poker pod manifest
- `monitoring/` - Prometheus/Grafana Helm values and RBAC
- `profiling/process_traces.py` - Multi-rank trace combiner with Perfetto fix

## Development Workflow

1. **Deploy the stack**: `just start` applies kustomize overlays, deploys InferencePool via Helm, and creates the Istio gateway
2. **Monitor pods**: `just get-decode-pods` to check readiness (vLLM can take 7-10 minutes to start for large MoE models)
3. **Interactive testing**: `just poke` opens a shell in the poker pod with benchmarking tools
4. **Run benchmarks**: Use `just benchmark ...` from the poker pod, or `just inference-perf ...` / `just parallel-guidellm ...` from your local machine
5. **Profile**: `just profile` does end-to-end profiling (start on all ranks, copy, process, open in Finder)
6. **Dev iteration**: Use `just dev-start` / `just dev-build` to build custom vLLM on Lustre, then `just start pd load-aware true` to deploy with it
7. **Monitoring**: `just start-monitoring` + `just grafana` for Grafana dashboards at localhost:3000
8. **Iterate**: Modify gb200/ configs and `just restart`

## Important Notes

- Deployment uses LeaderWorkerSet for multi-host inference coordination
- Decode pods run 4 vLLM processes per pod (ports 8000-8003) with routing sidecars
- vLLM API servers can take **7-10 minutes** to start up for large MoE models
- The poker pod image (`quay.io/tms/poker`) includes guidellm, lm_eval, and network tools. **It must be multi-arch (arm64 + amd64)** — always use `just release <version>` from `poker/` to build and push. Never do a single-arch `podman build && podman push`.
- PyTorch profiling traces are stored in decode pods at `/traces` and copied locally to `./traces/` (gitignored)
- Decode pod information is cached in `.tmp/decode_pods.txt` to avoid repeated kubectl queries
- The `profiling/process_traces.py` script aligns traces across pods using deep_ep sync barriers and fixes Perfetto overlapping events

## Just Variable Expansion Notes

When working with Just recipes, be aware of how variable expansion works with quotes:

- **Just strips outer quotes during expansion**: If you define `VAR := "value with spaces"`, then `{{VAR}}` expands to `value with spaces` (quotes removed)
- **Add quotes in bash assignments**: When using Just variables in bash scripts, wrap the expansion in quotes: `BASH_VAR="{{JUST_VAR}}"` to properly handle values with spaces
