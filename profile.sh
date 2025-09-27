#!/usr/bin/env bash
set -euo pipefail

# Defaults (override with flags)
NAMESPACE="tms-llm-d-wide-ep"
PREFIX="wide-ep-llm-d"
DECODE_PORT="8200"
PREFILL_PORT="8000"
SLEEP_SECS="1"
RUNNER_IMAGE="curlimages/curl:8.10.1"
DRY_RUN="false"

usage() {
  cat <<EOF
Usage: $0 [options]

Options:
  -n, --namespace NAMESPACE   Kubernetes namespace (default: ${NAMESPACE})
  -x, --prefix PREFIX         Pod name prefix to match (default: ${PREFIX})
  --decode-port PORT          Port for *-decode-* pods (default: ${DECODE_PORT})
  --prefill-port PORT         Port for *-prefill-* pods (default: ${PREFILL_PORT})
  -s, --sleep SECONDS         Delay between start/stop (default: ${SLEEP_SECS})
  -i, --image IMAGE           Runner image used in-cluster (default: ${RUNNER_IMAGE})
  -h, --help                  Show this help
EOF
}

# ---- Parse args ----
while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--namespace) NAMESPACE="$2"; shift 2 ;;
    -x|--prefix) PREFIX="$2"; shift 2 ;;
    --decode-port) DECODE_PORT="$2"; shift 2 ;;
    --prefill-port) PREFILL_PORT="$2"; shift 2 ;;
    -s|--sleep) SLEEP_SECS="$2"; shift 2 ;;
    -i|--image) RUNNER_IMAGE="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1"; usage; exit 2 ;;
  esac
done

# ---- Collect name+IP pairs outside the cluster ----
echo ">> Fetching pods in namespace: ${NAMESPACE} (prefix: ${PREFIX})"
PAIRS="$(
  kubectl -n "${NAMESPACE}" get pods --no-headers \
    -o=custom-columns=NAME:.metadata.name,IP:.status.podIP \
  | awk -v pre="${PREFIX}" '
      $1 ~ "^"pre && $2 != "" && $2 != "<none>" { print $1" "$2 }
    '
)"

if [[ -z "${PAIRS}" ]]; then
  echo "!! No matching pods with valid IPs found." >&2
  exit 1
fi

echo ">> Target pods/IPs:"
echo "${PAIRS}" | sed 's/^/   - /'

# ---- Run once inside the cluster (via heredoc; avoids quoting issues) ----
echo ">> Launching ephemeral runner pod to send curls in-cluster..."
kubectl -n "${NAMESPACE}" run profiler-oneshot \
  --image="${RUNNER_IMAGE}" --restart=Never --rm -i --quiet -- \
  sh -s -- "${PAIRS}" "${PREFIX}" "${DECODE_PORT}" "${PREFILL_PORT}" "${SLEEP_SECS}" <<'SH'
PAIRS="$1"
PREFIX="$2"
DECODE_PORT="$3"
PREFILL_PORT="$4"
SLEEP_SECS="$5"

# Start (non-blocking)
printf "%s\n" "$PAIRS" | while read -r name ip; do
  [ -z "$ip" ] && continue
  case "$name" in
    "$PREFIX"-decode-*) port="$DECODE_PORT" ;;
    "$PREFIX"-prefill-*) port="$PREFILL_PORT" ;;
    *) continue ;;
  esac
  (curl -sS -m 3 --connect-timeout 1 -X POST "http://$ip:$port/start_profile" >/dev/null 2>&1 &)
done

sleep "$SLEEP_SECS"

# Stop (non-blocking)
printf "%s\n" "$PAIRS" | while read -r name ip; do
  [ -z "$ip" ] && continue
  case "$name" in
    "$PREFIX"-decode-*) port="$DECODE_PORT" ;;
    "$PREFIX"-prefill-*) port="$PREFILL_PORT" ;;
    *) continue ;;
  esac
  (curl -sS -m 3 --connect-timeout 1 -X POST "http://$ip:$port/stop_profile" >/dev/null 2>&1 &)
done
SH

echo ">> Done."
