#!/usr/bin/env bash
set -euo pipefail

# Resumable JSONL download from a Lustre-mounted pod via kubectl exec.
# Downloads line-by-line batches using tail+head, appending to the local file.
# Re-run the same command to resume from where it left off.

BATCH_LINES="${BATCH_LINES:-20}"

if [ $# -lt 1 ]; then
  echo "Usage: $0 <run-dir> [lustre-pod]"
  echo "  run-dir:    Path to the run directory (e.g. benchmarks/eplb/pd-async-eplb-short-re0)"
  echo "  lustre-pod: Pod with Lustre access (default: \$DEPLOY_USER-vllm-dev)"
  echo "  env BATCH_LINES=20  Lines per kubectl exec call (default 20)"
  exit 1
fi

RUN_DIR="$1"
CONFIG="$RUN_DIR/config.env"
NS="${NAMESPACE:-vllm}"

if [ ! -f "$CONFIG" ]; then
  echo "ERROR: $CONFIG not found"
  exit 1
fi

LUSTRE_POD="${2:-$(grep '^DEPLOY_USER=' "$CONFIG" | cut -d= -f2)-vllm-dev}"

DUMP_DIR=$(grep '^DECODE_EPLB_EXPERT_LOAD_DUMP_DIR=' "$CONFIG" | cut -d= -f2)
if [ -z "$DUMP_DIR" ]; then
  echo "ERROR: DECODE_EPLB_EXPERT_LOAD_DUMP_DIR not found in $CONFIG"
  exit 1
fi

echo "Run:        $RUN_DIR"
echo "Lustre pod: $LUSTRE_POD"
echo "Dump dir:   $DUMP_DIR"
echo "Batch size: $BATCH_LINES lines"
echo

for ROLE in decode prefill; do
  SRC="$DUMP_DIR/$ROLE"
  DST="$RUN_DIR/expert-load/$ROLE"

  if ! kubectl -n "$NS" exec "$LUSTRE_POD" -- test -d "$SRC" 2>/dev/null; then
    echo "=== $ROLE === (no dumps, skipping)"
    continue
  fi

  REMOTE_FILES=$(kubectl -n "$NS" exec "$LUSTRE_POD" -- \
    sh -c "find '$SRC' -name '*.jsonl' -o -name '*.json' | sort")

  if [ -z "$REMOTE_FILES" ]; then
    echo "=== $ROLE === (no json/jsonl files, skipping)"
    continue
  fi

  mkdir -p "$DST"
  echo "=== $ROLE ==="

  for REMOTE_FILE in $REMOTE_FILES; do
    FNAME=$(basename "$REMOTE_FILE")
    LOCAL_FILE="$DST/$FNAME"

    REMOTE_LINES=$(kubectl -n "$NS" exec "$LUSTRE_POD" -- sh -c "wc -l < '$REMOTE_FILE'" | tr -d ' ')
    LOCAL_LINES=0
    if [ -f "$LOCAL_FILE" ]; then
      LOCAL_LINES=$(wc -l < "$LOCAL_FILE" | tr -d ' ')
    fi

    if [ "$LOCAL_LINES" -ge "$REMOTE_LINES" ]; then
      echo "  $FNAME: $REMOTE_LINES lines (already complete)"
      continue
    fi

    echo "  $FNAME: $REMOTE_LINES lines total, $LOCAL_LINES already downloaded"
    REMAINING=$((REMOTE_LINES - LOCAL_LINES))
    START=$((LOCAL_LINES + 1))

    while [ "$REMAINING" -gt 0 ]; do
      COUNT=$BATCH_LINES
      if [ "$REMAINING" -lt "$BATCH_LINES" ]; then
        COUNT=$REMAINING
      fi

      kubectl -n "$NS" exec "$LUSTRE_POD" -- \
        sh -c "tail -n +$START '$REMOTE_FILE' | head -n $COUNT" >> "$LOCAL_FILE"

      START=$((START + COUNT))
      REMAINING=$((REMAINING - COUNT))
      LOCAL_LINES=$((LOCAL_LINES + COUNT))
      PCT=$(( LOCAL_LINES * 100 / REMOTE_LINES ))
      printf "\r    %d/%d lines (%d%%)" "$LOCAL_LINES" "$REMOTE_LINES" "$PCT"
    done

    echo ""
    echo "  $FNAME: done"
  done
done

echo
echo "Done. Expert loads in $RUN_DIR/expert-load/"
