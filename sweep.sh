#!/usr/bin/env bash
set -euo pipefail

START=512
END=4096
STEP=512

for ((rate=START; rate<=END; rate+=STEP)); do
  echo "=== Starting run with rate=$rate ==="

  just parallel-guidellm "$rate" $((4*rate)) 2000 2000

  # wait for job completion
  echo "Waiting for job $NAME to complete..."
  kubectl wait --for=condition=complete --timeout=1h job/guide-llm

  echo "All pods finished for $NAME"
done

