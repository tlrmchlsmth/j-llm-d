#!/usr/bin/env python3

import subprocess
import sys
import time
import re
import os
from datetime import datetime

# Configuration
HOME = os.path.expanduser("~")
KC = ["--kubeconfig", f"{HOME}/nvidia_kubeconfig.yaml"]
NS = ["-n", "vllm"]
KUBECTL_CMD = ["kubectl"] + KC + NS
YAML = "/Users/ecrncevi/j-llm-d/gb200-fp4-decode-bench/decode-bench.yaml"
RESULTS_FILE = "/Users/ecrncevi/j-llm-d/sweep_results.txt"
LWS_NAME = "wide-ep-llm-d-decode-bench"

# Configurations to sweep: CHUNK_SIZE, NVSHMEM_QP_DEPTH
CONFIGS = [
    (768, 2048),
    (1024, 2048),
    (1536, 4096),
    (2048, 4096),
]

def run_cmd(cmd, capture_output=True, check=False, cwd=None):
    """Run command and return result"""
    try:
        result = subprocess.run(cmd, capture_output=capture_output, text=True, check=check, cwd=cwd)
        return result
    except subprocess.CalledProcessError as e:
        print(f"Command failed: {' '.join(cmd)}")
        print(f"Error: {e}")
        print(f"Stdout: {e.stdout}")
        print(f"Stderr: {e.stderr}")
        # Return a mock result object with error info
        class MockResult:
            def __init__(self, returncode, stdout="", stderr=""):
                self.returncode = returncode
                self.stdout = stdout
                self.stderr = stderr
        return MockResult(e.returncode, e.stdout if hasattr(e, 'stdout') else "", e.stderr if hasattr(e, 'stderr') else "")

def parse_age_to_minutes(age_str):
    """Parse kubectl age string (e.g., '7m', '1h30m', '2d') to total minutes"""
    if not age_str:
        return 0

    total_minutes = 0

    # Extract days
    days_match = re.search(r'(\d+)d', age_str)
    if days_match:
        total_minutes += int(days_match.group(1)) * 24 * 60

    # Extract hours
    hours_match = re.search(r'(\d+)h', age_str)
    if hours_match:
        total_minutes += int(hours_match.group(1)) * 60

    # Extract minutes
    minutes_match = re.search(r'(\d+)m', age_str)
    if minutes_match:
        total_minutes += int(minutes_match.group(1))

    # Handle seconds (convert to fractional minutes)
    seconds_match = re.search(r'(\d+)s', age_str)
    if seconds_match:
        total_minutes += int(seconds_match.group(1)) / 60

    return total_minutes

def wait_for_pods_ready():
    """Wait for all pods to be 5/5 ready and at least 7 minutes old"""
    print(f"Waiting for {LWS_NAME} pods to be ready...")

    for attempt in range(1, 121):  # 120 attempts max
        # Get pod status
        result = run_cmd(KUBECTL_CMD + ["get", "pods", "--no-headers"])
        if result.returncode != 0:
            print(f"  Failed to get pods (attempt {attempt}/120)")
            time.sleep(30)
            continue

        # Filter our pods
        our_pods = [line for line in result.stdout.split('\n') if line.startswith(f"{LWS_NAME}-")]
        pod_count = len(our_pods)

        if pod_count == 0:
            print(f"  No pods yet (attempt {attempt}/120)")
            time.sleep(30)
            continue

        # Check for 5/5 ready
        ready_pods = [line for line in our_pods if "5/5" in line and "Running" in line]
        ready_count = len(ready_pods)

        print(f"  Pods: {ready_count}/{pod_count} ready (5/5) (attempt {attempt}/120)")

        if ready_count == pod_count and pod_count > 0:
            # Check age (at least 7 minutes)
            old_enough_count = 0
            for pod_line in our_pods:
                parts = pod_line.split()
                if len(parts) >= 5:
                    age_str = parts[4]
                    age_minutes = parse_age_to_minutes(age_str)
                    if age_minutes >= 7:
                        old_enough_count += 1
                    else:
                        print(f"    Pod {parts[0]} is only {age_str} old (need 7m)")

            if old_enough_count == pod_count:
                print(f"All {LWS_NAME} pods are ready (5/5) and >= 7min old!")
                return True
            else:
                print(f"    Only {old_enough_count}/{pod_count} pods are old enough")

        time.sleep(30)

    print("TIMEOUT: Pods not ready after 30 min")
    return False

def update_yaml(chunk_size, qp_depth):
    """Update YAML with new configuration"""
    print(f"Updating YAML: CHUNK={chunk_size}, QP={qp_depth}")

    # Read the file
    with open(YAML, 'r') as f:
        content = f.read()

    # Replace VLLM_MOE_DP_CHUNK_SIZE value
    content = re.sub(
        r'(- name: VLLM_MOE_DP_CHUNK_SIZE\s*\n\s*value: ")[0-9]+(")',
        rf'\g<1>{chunk_size}\g<2>',
        content
    )

    # Replace NVSHMEM_QP_DEPTH value
    content = re.sub(
        r'(- name: NVSHMEM_QP_DEPTH\s*\n\s*value: ")[0-9]+(")',
        rf'\g<1>{qp_depth}\g<2>',
        content
    )

    # Write the file
    with open(YAML, 'w') as f:
        f.write(content)

    # Verify changes
    with open(YAML, 'r') as f:
        new_content = f.read()
        chunk_found = f'value: "{chunk_size}"' in new_content
        qp_found = f'value: "{qp_depth}"' in new_content
        if chunk_found and qp_found:
            print(f"✓ Verified YAML updated: CHUNK={chunk_size}, QP={qp_depth}")
        else:
            print(f"✗ YAML update failed! chunk_found={chunk_found}, qp_found={qp_found}")
            sys.exit(1)

def run_benchmark_with_retry():
    """Run benchmark with retry logic"""
    for retry in range(1, 4):  # 3 attempts
        print(f"Running parallel-guidellm benchmark (attempt {retry}/3)...")

        # Run benchmark
        result = run_cmd([
            "just", "parallel-guidellm", "1024", "2048", "8192", "1", "1500", "8"
        ], cwd="/Users/ecrncevi/j-llm-d")

        # Wait for completion
        print("Waiting for parallel-guidellm job to complete...")
        wait_result = run_cmd(KUBECTL_CMD + [
            "wait", "--for=condition=complete", "job/parallel-guidellm", "--timeout=3600s"
        ])

        if wait_result.returncode == 0:
            print("Benchmark completed successfully!")

            # Collect logs
            print("--- Pod logs summary ---")
            logs_result = run_cmd(KUBECTL_CMD + [
                "get", "pods", "-l", "app=poker,job-name=parallel-guidellm", "-o", "name"
            ])
            if logs_result.returncode == 0:
                for pod_name in logs_result.stdout.strip().split('\n'):
                    if pod_name:
                        print(f"= {pod_name} =")
                        run_cmd(KUBECTL_CMD + ["logs", pod_name, "--tail=30"], capture_output=False)

            return True
        else:
            print(f"Benchmark attempt {retry} failed, cleaning up and retrying...")
            run_cmd(KUBECTL_CMD + ["delete", "job", "parallel-guidellm", "--ignore-not-found=true"])
            time.sleep(10)

    print("All benchmark attempts failed for this config")
    return False

def main():
    with open(RESULTS_FILE, 'w') as f:
        f.write("=== Decode Bench Sweep ===\n")
        f.write(f"Started at {datetime.now().strftime('%a %b %d %H:%M:%S %Z %Y')}\n\n")

    for chunk_size, qp_depth in CONFIGS:
        print("=" * 40)
        print(f"Round: CHUNK_SIZE={chunk_size} QP_DEPTH={qp_depth}")
        print("=" * 40)

        with open(RESULTS_FILE, 'a') as f:
            f.write("=" * 40 + "\n")
            f.write(f"Round: CHUNK_SIZE={chunk_size} QP_DEPTH={qp_depth}\n")
            f.write("=" * 40 + "\n")

        # Update YAML
        update_yaml(chunk_size, qp_depth)

        # Force delete old deployment and wait for cleanup
        print("Deleting existing LWS...")
        run_cmd(KUBECTL_CMD + ["delete", "lws", LWS_NAME, "--ignore-not-found=true"])

        # Wait for all pods to be gone
        print("Waiting for pod cleanup...")
        for cleanup_attempt in range(60):  # 5 minutes max
            result = run_cmd(KUBECTL_CMD + ["get", "pods", "--no-headers"])
            if result.returncode == 0:
                our_pods = [line for line in result.stdout.split('\n') if line.startswith(f"{LWS_NAME}-")]
                if len(our_pods) == 0:
                    print("✓ All pods cleaned up")
                    break
                else:
                    print(f"  {len(our_pods)} pods still terminating...")
            time.sleep(5)

        # Apply new deployment
        print("Applying new LWS...")
        result = run_cmd(KUBECTL_CMD + ["apply", "-f", YAML])
        if result.returncode != 0:
            print(f"Failed to apply YAML: {result.stderr}")
            continue

        # Wait for pods ready
        if not wait_for_pods_ready():
            with open(RESULTS_FILE, 'a') as f:
                f.write("TIMEOUT: Pods not ready after 30 min, skipping this config\n\n")
            continue

        # Run benchmark
        bench_start = time.time()
        success = run_benchmark_with_retry()
        bench_end = time.time()

        if success:
            duration = int(bench_end - bench_start)
            with open(RESULTS_FILE, 'a') as f:
                f.write(f"Benchmark completed in {duration}s\n")
        else:
            with open(RESULTS_FILE, 'a') as f:
                f.write("All benchmark attempts failed\n")

        # Clean up
        run_cmd(KUBECTL_CMD + ["delete", "job", "parallel-guidellm", "--ignore-not-found=true"])

        with open(RESULTS_FILE, 'a') as f:
            f.write("\n")

    # Final cleanup
    run_cmd(KUBECTL_CMD + ["delete", "lws", LWS_NAME, "--ignore-not-found=true"])

    with open(RESULTS_FILE, 'a') as f:
        f.write("=" * 40 + "\n")
        f.write(f"Sweep completed at {datetime.now().strftime('%a %b %d %H:%M:%S %Z %Y')}\n")
        f.write(f"Results saved to {RESULTS_FILE}\n")

if __name__ == "__main__":
    main()
