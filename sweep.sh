#!/usr/bin/env bash
set -euo pipefail

KC="--kubeconfig $HOME/nvidia_kubeconfig.yaml"
NS="-n vllm"
K="kubectl $KC $NS"
YAML="/Users/ecrncevi/j-llm-d/gb200-fp4-decode-bench/decode-bench.yaml"
RESULTS_FILE="/Users/ecrncevi/j-llm-d/sweep_results.txt"
LWS_NAME="wide-ep-llm-d-decode-bench"

# Configurations to sweep: CHUNK_SIZE NVSHMEM_QP_DEPTH
CONFIGS=(
  "768 2048"
  "1024 2048"
  "1536 4096"
  "2048 4096"
)

echo "=== Decode Bench Sweep ===" | tee "$RESULTS_FILE"
echo "Started at $(date)" | tee -a "$RESULTS_FILE"
echo "" | tee -a "$RESULTS_FILE"

for CONFIG in "${CONFIGS[@]}"; do
  read -r CHUNK QP <<< "$CONFIG"
  echo "========================================" | tee -a "$RESULTS_FILE"
  echo "Round: CHUNK_SIZE=$CHUNK QP_DEPTH=$QP" | tee -a "$RESULTS_FILE"
  echo "========================================" | tee -a "$RESULTS_FILE"

  # Update VLLM_MOE_DP_CHUNK_SIZE in yaml
  sed -i.bak -E '/name: VLLM_MOE_DP_CHUNK_SIZE/{n;s/value: "[0-9]+"/value: "'"$CHUNK"'"/;}' "$YAML"

  # Update NVSHMEM_QP_DEPTH in yaml
  sed -i.bak -E '/name: NVSHMEM_QP_DEPTH/{n;s/value: "[0-9]+"/value: "'"$QP"'"/;}' "$YAML"

  echo "Updated YAML: CHUNK=$CHUNK, QP=$QP"

  # Delete old deployment and apply new
  $K delete lws "$LWS_NAME" --ignore-not-found=true
  sleep 5
  $K apply -f "$YAML"

  # Wait for pods to be ready (match only our pods by name prefix)
  echo "Waiting for $LWS_NAME pods to be ready..."
  READY=false
  for i in $(seq 1 120); do
    POD_COUNT=$($K get pods --no-headers 2>/dev/null | grep "^${LWS_NAME}-" | wc -l | tr -d ' ')
    if [ "$POD_COUNT" -gt 0 ]; then
      # Check for 5/5 containers ready (4 proxy sidecars + 1 vllm container)
      READY_COUNT=$($K get pods --no-headers 2>/dev/null | grep "^${LWS_NAME}-" | grep -c "5/5.*Running" || true)
      echo "  Pods: $READY_COUNT/$POD_COUNT ready (5/5) (attempt $i/120)"

      if [ "$READY_COUNT" -eq "$POD_COUNT" ] && [ "$POD_COUNT" -gt 0 ]; then
        # Check if pods are at least 7 minutes old (exclude 0-6m)
        OLD_ENOUGH=$($K get pods --no-headers 2>/dev/null | grep "^${LWS_NAME}-" | awk '{print $5}' | grep -v -E '^[0-6]m$|^[0-6][0-9]*s$' | wc -l | tr -d ' ')
        if [ "$OLD_ENOUGH" -eq "$POD_COUNT" ]; then
          READY=true
          echo "All $LWS_NAME pods are ready (5/5) and >= 7min old!"
          break
        else
          echo "    Pods not old enough yet (need 7min)"
        fi
      fi
    else
      echo "  No pods yet (attempt $i/120)"
    fi
    sleep 30
  done

  if [ "$READY" != "true" ]; then
    echo "TIMEOUT: Pods not ready after 30 min, skipping this config" | tee -a "$RESULTS_FILE"
    continue
  fi

  # Run benchmark with retry logic
  BENCHMARK_SUCCESS=false
  for RETRY in $(seq 1 3); do
    echo "Running parallel-guidellm benchmark (attempt $RETRY/3)..."
    BENCH_START=$(date +%s)
    cd /Users/ecrncevi/j-llm-d
    just parallel-guidellm 1024 2048 16384 1 1500 8 || true

    # Wait for guidellm job to complete
    echo "Waiting for parallel-guidellm job to complete..."
    if $K wait --for=condition=complete job/parallel-guidellm --timeout=3600s 2>/dev/null; then
      BENCH_END=$(date +%s)
      BENCH_DURATION=$((BENCH_END - BENCH_START))
      echo "Benchmark completed in ${BENCH_DURATION}s" | tee -a "$RESULTS_FILE"

      # Collect logs from guidellm pods
      echo "--- Pod logs summary ---" | tee -a "$RESULTS_FILE"
      for POD in $($K get pods -l app=poker,job-name=parallel-guidellm -o name 2>/dev/null); do
        echo "= $POD =" | tee -a "$RESULTS_FILE"
        $K logs "$POD" --tail=30 2>/dev/null | tee -a "$RESULTS_FILE" || true
      done
      BENCHMARK_SUCCESS=true
      break
    else
      echo "Benchmark attempt $RETRY failed, cleaning up and retrying..." | tee -a "$RESULTS_FILE"
      JOB_STATUS=$($K get job parallel-guidellm -o jsonpath='{.status.conditions[*].type}' 2>/dev/null || echo "unknown")
      echo "Job status: $JOB_STATUS" | tee -a "$RESULTS_FILE"

      # Clean up failed job before retry
      $K delete job parallel-guidellm --ignore-not-found=true
      sleep 10
    fi
  done

  if [ "$BENCHMARK_SUCCESS" != "true" ]; then
    echo "All benchmark attempts failed for this config" | tee -a "$RESULTS_FILE"
  fi

  # Clean up guidellm job
  $K delete job parallel-guidellm --ignore-not-found=true
  echo "" | tee -a "$RESULTS_FILE"
done

# Final cleanup
$K delete lws "$LWS_NAME" --ignore-not-found=true

echo "========================================" | tee -a "$RESULTS_FILE"
echo "Sweep completed at $(date)" | tee -a "$RESULTS_FILE"
echo "Results saved to $RESULTS_FILE"
