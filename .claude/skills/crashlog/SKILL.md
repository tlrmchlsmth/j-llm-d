---
name: crashlog
description: Diagnose the most recent pod crash from Lustre logs. Use when the user says pods are crashlooping or asks about a crash.
allowed-tools: Bash, Read
---

# Pod Crash Diagnosis

## What the user is doing when they run /crashlog

The user is actively watching pods in another terminal (`watch "kubectl get pods | grep tms"`). They have already seen the pods crash and restart — they know which role is failing and roughly when. They are running /crashlog because they need the **error message and stack trace** so they can fix the code. They do not need confirmation that pods are crashing, health checks, or status updates. They need the error, fast.

## Environment

The user runs vLLM model servers on Kubernetes using LeaderWorkerSets. Pod logs are persisted to Lustre at `/mnt/lustre/tms/logs/{decode,prefill}/`. When pods crashloop, the current pod's log is tiny (just starting up) — the crash evidence is in an **older** log file.

LWS creates multiple pods per group (leader + workers: `-0`, `-0-1`, `-0-2`, `-0-3`). Crashes often happen on WORKER pods, not the leader. Always check ALL pod logs.

## Rules

1. The pods ARE crashing. Do not second-guess this. Do not check pod status. Do not say pods look healthy. Just find the error.
2. Never skip the Lustre log scan. Never conclude "no errors found" without checking ALL pods and the 3 most recent logs per pod.
3. Do not add commentary about whether pods are up. Do not say "let me check if..." — just run the scan and report the error.
4. Get the stack trace automatically for every error found. Do not ask first.

## Instructions

1. Scan ALL pods across both roles. For each pod, check the 3 most recent logs and find the first one with errors:

```bash
kubectl -n vllm exec tms-vllm-dev -- bash -c '
ERR_PAT="RuntimeError:\|CUDA error:\|AssertionError\|ValueError:\|TypeError:\|NameError:\|CUDA_ERROR\|KeyError:\|AttributeError:\|illegal"
for role in decode prefill; do
  for pod in tms-wide-ep-${role}-0 tms-wide-ep-${role}-0-1 tms-wide-ep-${role}-0-2 tms-wide-ep-${role}-0-3; do
    LOGS=($(ls -t /mnt/lustre/tms/logs/$role/${pod}_*.log 2>/dev/null))
    FOUND=0
    for i in 0 1 2; do
      F="${LOGS[$i]:-}"
      [ -z "$F" ] && continue
      SIZE=$(wc -c < "$F" 2>/dev/null || echo 0)
      [ "$SIZE" -lt 500 ] && continue
      ERRS=$(grep -c "$ERR_PAT" "$F" 2>/dev/null || echo 0)
      if [ "$ERRS" -gt 0 ]; then
        echo "=== $pod: $(basename $F) ($SIZE bytes, $ERRS errors) ==="
        grep "$ERR_PAT" "$F" | grep -v "Traceback\|  File \"\|^^^^\|resource_tracker\|DeprecationWarning" | sort -u | tail -5
        echo ""
        FOUND=1
        break
      fi
    done
    [ "$FOUND" -eq 0 ] && echo "=== $pod: no errors in recent logs ==="
  done
done
'
```

2. For EVERY error found, immediately get the stack trace — do not ask or wait:

```bash
kubectl -n vllm exec tms-vllm-dev -- bash -c '
grep -B15 "THE_ERROR_MESSAGE" /mnt/lustre/tms/logs/ROLE/THE_LOG_FILE.log | tail -25
'
```

3. Report: the error message, which file/line caused it, and the root cause. Keep it short.

If the user provides $ARGUMENTS (e.g. "decode" or "prefill"), only check that role.
