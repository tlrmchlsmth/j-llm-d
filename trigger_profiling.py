#!/usr/bin/env python3
"""
Profile a single vLLM pod and download torch profiler traces.

Usage:
  python3 trigger_profiling.py --pod-type decode
  python3 trigger_profiling.py --pod-type decode --profile-duration 60
  python3 trigger_profiling.py --pod-type prefill
"""

import subprocess
import time
import os
import argparse

KUBECONFIG = "/Users/ecrncevi/nvidia_kubeconfig.yaml"
NAMESPACE = "vllm"
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))

os.environ["KUBECONFIG"] = KUBECONFIG

def kubectl(*args, timeout=60):
    return subprocess.run(
        ["kubectl", "-n", NAMESPACE] + list(args),
        capture_output=True, text=True, timeout=timeout
    )

def find_pod(prefix):
    result = kubectl("get", "pods", "-o", "name")
    if result.returncode != 0:
        print(f"Error getting pods: {result.stderr}")
        return None
    for line in result.stdout.strip().split('\n'):
        pod_name = line.replace('pod/', '')
        if pod_name.startswith(prefix):
            return pod_name
    return None

def profile(pod, action, port=8000, max_retries=3):
    for attempt in range(max_retries):
        try:
            result = kubectl("exec", pod, "-c", "vllm", "--",
                           "curl", "-X", "POST", f"localhost:{port}/{action}_profile",
                           timeout=30)
            if result.returncode == 0:
                return True
            print(f"  Attempt {attempt + 1}: {result.stderr}")
        except subprocess.TimeoutExpired:
            print(f"  Attempt {attempt + 1}: timed out")
        except Exception as e:
            print(f"  Attempt {attempt + 1}: {e}")
        if attempt < max_retries - 1:
            time.sleep(1)
    return False

def download_traces(pod, trace_dir, max_retries=3):
    tar_name = f"{pod}.tar.gz"
    remote_tar = f"/tmp/{tar_name}"
    local_tar = os.path.join(trace_dir, tar_name)

    for attempt in range(max_retries):
        try:
            result = kubectl("exec", pod, "-c", "vllm", "--",
                           "tar", "-czf", remote_tar, "-C", "/trace", ".", timeout=300)
            if result.returncode != 0:
                print(f"  Attempt {attempt + 1}: tar creation failed: {result.stderr}")
                continue

            copy_result = subprocess.run([
                "kubectl", "-n", NAMESPACE, "cp",
                f"{pod}:{remote_tar}", local_tar, "-c", "vllm"
            ], capture_output=True, text=True, timeout=300)

            if copy_result.returncode != 0:
                print(f"  Attempt {attempt + 1}: download failed: {copy_result.stderr}")
                continue

            size_mb = os.path.getsize(local_tar) / (1024 * 1024)
            print(f"Downloaded {local_tar} ({size_mb:.1f} MB)")
            return True

        except subprocess.TimeoutExpired:
            print(f"  Attempt {attempt + 1}: timed out")
        except Exception as e:
            print(f"  Attempt {attempt + 1}: {e}")
        if attempt < max_retries - 1:
            time.sleep(2)
    return False

def main():
    parser = argparse.ArgumentParser(description="Profile a single vLLM pod")
    parser.add_argument("--pod-type", choices=["decode", "prefill"], default="decode")
    parser.add_argument("--profile-duration", type=int, default=0,
                       help="Seconds to profile (0 = start only, don't stop)")
    args = parser.parse_args()

    prefix = f"wide-ep-llm-d-{args.pod_type}"
    pod = find_pod(prefix)
    if not pod:
        print(f"No pods found with prefix {prefix}")
        return 1

    print(f"Profiling {pod}...")

    print("Starting profiler...")
    if not profile(pod, "start"):
        print("Failed to start profiling")
        return 1

    if args.profile_duration > 0:
        print(f"Waiting {args.profile_duration}s...")
        time.sleep(args.profile_duration)

        print("Stopping profiler...")
        if not profile(pod, "stop"):
            print("Failed to stop profiling")

    # Download traces
    i = 0
    while os.path.exists(os.path.join(SCRIPT_DIR, f"{args.pod_type}_{i}")):
        i += 1
    trace_dir = os.path.join(SCRIPT_DIR, f"{args.pod_type}_{i}")
    os.makedirs(trace_dir)

    print(f"Downloading traces to {trace_dir}...")
    if not download_traces(pod, trace_dir):
        print("Failed to download traces")
        return 1

    return 0

if __name__ == "__main__":
    exit(main())
