#!/usr/bin/env bash
set -euo pipefail

if [ $# -lt 1 ]; then
  echo "Usage: $0 <run-dir> [lustre-pod]"
  echo "  run-dir:    Path to the run directory (e.g. benchmarks/eplb/pd-async-eplb-both)"
  echo "  lustre-pod: Pod with Lustre access (default: \$DEPLOY_USER-vllm-dev)"
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
DUMP_BASE=$(dirname "$DUMP_DIR")

echo "Run:        $RUN_DIR"
echo "Lustre pod: $LUSTRE_POD"
echo "Dump base:  $DUMP_BASE"
echo "Dump TS:    $(basename "$DUMP_DIR")"
echo

for ROLE in decode prefill; do
  SRC="$DUMP_DIR/$ROLE"
  DST="$RUN_DIR/expert-load/$ROLE"

  if ! kubectl -n "$NS" exec "$LUSTRE_POD" -- test -d "$SRC" 2>/dev/null; then
    echo "=== $ROLE === (no dumps, skipping)"
    continue
  fi

  mkdir -p "$DST"
  echo "=== $ROLE ==="
  REMOTE_TGZ="/tmp/eplb_${ROLE}_dumps.tar.gz"
  LOCAL_TGZ="$DST/_dumps.tar.gz"

  echo "  Compressing on pod..."
  kubectl -n "$NS" exec "$LUSTRE_POD" -- tar czf "$REMOTE_TGZ" -C "$SRC" .

  REMOTE_SIZE=$(kubectl -n "$NS" exec "$LUSTRE_POD" -- stat -c%s "$REMOTE_TGZ")
  echo "  Archive size: $(( REMOTE_SIZE / 1048576 )) MB"

  echo "  Downloading..."
  kubectl -n "$NS" cp "$LUSTRE_POD:$REMOTE_TGZ" "$LOCAL_TGZ"

  LOCAL_SIZE=$(wc -c < "$LOCAL_TGZ" | tr -d ' ')
  echo "  Size: remote=$REMOTE_SIZE local=$LOCAL_SIZE"
  if [ "$LOCAL_SIZE" != "$REMOTE_SIZE" ]; then
    echo "  ERROR: size mismatch — transfer corrupted"
    rm -f "$LOCAL_TGZ"
    exit 1
  fi

  echo "  Extracting..."
  tar xzf "$LOCAL_TGZ" -C "$DST"
  rm -f "$LOCAL_TGZ"

  kubectl -n "$NS" exec "$LUSTRE_POD" -- rm -f "$REMOTE_TGZ"
  echo "  $(find "$DST" -name '*.json*' | wc -l | tr -d ' ') file(s)"
done

echo
echo "Done. Expert loads in $RUN_DIR/expert-load/"
