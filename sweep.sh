#!/usr/bin/env bash
set -euo pipefail

START=2048
END=4096
STEP=512

for ((rate=START; rate<=END; rate+=STEP)); do
  echo "=== Starting run with rate=$rate ==="

  just parallel-guidellm "$rate" $((8*rate)) 128 2000

  # wait for job completion
  echo "Waiting for job parallel-guidellm to complete..."
  kubectl wait --for=condition=complete --timeout=1h job/parallel-guidellm

  echo "All pods finished for parallel-guidellm"
done

