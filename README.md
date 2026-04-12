# j-llm-d

Development workspace for [llm-d](https://github.com/llm-d/llm-d) — deploying DeepSeek-R1 on GB200 NVL72 clusters with expert-parallelism and prefill/decode disaggregation.

## Prerequisites

1. **Tools**: `kubectl`, `helm`, `just`, `jq`, `envsubst`
2. **Container runtime**: `podman` (not docker)
3. **`.env` file** in the repo root:
   ```
   HF_TOKEN=hf_...
   GH_TOKEN=ghp_...
   KUBECONFIG=/path/to/kubeconfig
   ```
4. Create namespace secrets:
   ```bash
   just create-secrets
   ```

Resources are automatically prefixed with `$USER` (e.g. `$USER-wide-ep-decode`), so multiple users can share the `vllm` namespace without collisions.

## Starting a Server

```bash
# Start in prefill/decode disaggregation mode (default)
just start

# Explicit mode + routing strategy
just start pd load-aware      # P/D mode with load-aware routing
just start pd pd              # P/D mode with P/D-aware routing
just start decode-bench       # Pure decode benchmark (no prefill)

# Start with a dev vLLM build from Lustre
just start pd load-aware true
```

This deploys:
- Decode and prefill LeaderWorkerSets (4 vLLM processes per pod)
- InferencePool (Envoy-based request scheduler)
- Istio gateway + HTTPRoute

Wait for everything to be ready:
```bash
just ready    # Blocks until all pods + gateway are serving
```

## Restarting a Server (Fast)

```bash
just restart                     # Force-deletes LWS pods, then re-applies the full stack
just restart pd load-aware true  # Restart with dev build
```

`restart` force-deletes pods with `--grace-period=0` so they die immediately, then runs `start`. Gateway and InferencePool are updated in-place (not recreated), so only the model server pods restart.

To tear everything down completely:
```bash
just stop            # Graceful shutdown
just stop true       # Force shutdown (--grace-period=0)
```

To redeploy just the routing layer without restarting model servers:
```bash
just deploy_inferencepool load-aware   # or: random, pd, agg
```

## Setting Up a Dev Build

The dev workflow lets you build vLLM from source on a shared Lustre filesystem and deploy it to model server pods.

### 1. Start the dev pod

```bash
just dev-start    # Deploys a persistent CPU-only pod on Lustre
just dev          # Exec into it (zsh shell with dotfiles)
```

### 2. Build vLLM from source

```bash
# Build from upstream main (default)
just dev-build

# Build from a custom fork/branch
just dev-build REMOTE=https://github.com/user/vllm.git BRANCH=my-branch

# Monitor the build
just dev-build-log
```

The build runs in the background on the dev pod and survives disconnects. It installs vLLM in editable mode into a shared venv at `/mnt/lustre/$USER/vllm-venv`.

### 3. Deploy with your dev build

```bash
just start pd load-aware true    # 'true' enables the dev venv
just restart pd load-aware true  # Or restart with it
```

### Tips

- **Pure Python changes** (no C++/CUDA) take effect on pod restart without rebuilding
- **C++/CUDA changes** require `just dev-build` before restarting
- Flush compile caches after image or config changes: `just flush-cache`
- Stop the dev pod when not needed: `just dev-stop`

## Setting Up Monitoring

The monitoring stack is namespace-scoped (no cluster-admin required) and uses Helm.

### Install

```bash
just start-monitoring    # Installs Prometheus + Grafana via Helm
```

### Access dashboards

```bash
just grafana       # Port-forward Grafana to localhost:3000 (background)
just prometheus    # Port-forward Prometheus to localhost:9090 (background)
```

Grafana credentials are configured in `monitoring/grafana-values.yaml`.

### Load vLLM dashboards

```bash
just load-dashboards    # Creates ConfigMaps from monitoring/*.json
```

Grafana auto-discovers new dashboard ConfigMaps within 30 seconds.

### Teardown

```bash
just stop-monitoring
```

## Other Useful Commands

| Command | Description |
|---|---|
| `just` | List all available commands |
| `just start-poker` | Deploy the poker pod (benchmarking container) |
| `just poke` | Exec into poker pod with `BASE_URL` injected |
| `just get-decode-pods` | List decode pod names and IPs |
| `just logs decode` | List persisted log files from Lustre |
| `just logs decode -f` | Follow the latest decode log |
| `just print-gpus` | Show GPU allocation across all nodes |
| `just check-ib` | Check InfiniBand port health |
| `just profile` | End-to-end profiling (start, copy, process, open) |
| `just ready` | Wait for full stack readiness |

## Benchmarking

**nyann-bench** (combined load + eval):

Requires a local checkout of `nyann-bench`. Set `NYANN_BENCH_DIR` in your `.env` file.

```bash
just benchmark-nyann    # Wait for stack readiness, then submit load + eval jobs
just nyann-logs sharegpt-load   # Tail load generator logs
just nyann-logs poker-eval      # Tail eval logs
just stop-nyann                 # Stop benchmark jobs
```

**From local machine:**
```bash
just inference-perf 25000 500 1500 2 2048           # inference-perf (concurrent load)
just parallel-guidellm 4000 4000 128 1000 4         # parallel vllm bench
```

**In-cluster** (from `just poke` shell):
```bash
just benchmark 128 1000 500 1500                    # vllm bench serve
just benchmark_decode_workload 1000 1500             # pure decode (input_len=1)
```
