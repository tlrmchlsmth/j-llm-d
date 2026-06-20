#!/usr/bin/env python3
"""Retry doc_id=43 across gateway, decode, and prefill pods with concurrency."""

import json
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed

GATEWAY_URL = "http://ecrncevi-wide-ep-inference-gateway-istio.vllm.svc.cluster.local"
DECODE_PODS = {
    "decode-0":   "http://10.244.5.64:8000",
    "decode-0-1": "http://10.244.10.185:8000",
}
PREFILL_POD = {
    "prefill-0": "http://10.244.10.5:8000",
}

MESSAGES = [
    {"role": "user", "content": "Question: Caprice is taking piano lessons. Her mother pays the teacher $10 for every half-hour of teaching her daughter. If Caprice is taking one lesson per week, and the lesson lasts 1 hour, how much money would the teacher earn in 5 weeks?\nAnswer:"},
    {"role": "assistant", "content": "If half-hour lesson is worth $10, then a one-hour lesson costs 2 * 10 = $<<10*2=20>>20.\nOne lesson per week would mean that in 5 weeks the teacher would earn 20 * 5 = $<<20*5=100>>100.\n#### 100"},
    {"role": "user", "content": "Question: A school bought 20 cartons of pencils at the start of school. Pencils come in cartons of 10 boxes and each box costs $2. The school also bought 10 cartons of markers. A carton has 5 boxes and costs $4. How much did the school spend in all?\nAnswer:"},
    {"role": "assistant", "content": "The school bought 20 x 10 = <<20*10=200>>200 boxes of pencils.\nThe pencils cost 200 x $2 = $<<200*2=400>>400.\nThe school bought 10 x 5 = <<10*5=50>>50 boxes of markers.\nThe markers cost 50 x $4 = $<<50*4=200>>200.\nThus, the school spent a total of $400 + $200 = $<<400+200=600>>600.\n#### 600"},
    {"role": "user", "content": "Question: If you buy a dozen of doughnuts, it costs $8; but if you buy 2, it costs $1 each. How much will you save from buying 3 sets of 2 doughnuts over buying a dozen doughnuts?\nAnswer:"}
]

NO_Q_KEYWORDS = [
    "please provide", "problem statement", "incomplete", "missing",
    "cut off", "not included", "haven't provided", "provide the problem",
    "provide the word", "cannot answer", "problem is missing"
]

PAYLOAD = json.dumps({
    "model": "nvidia/NVIDIA-Nemotron-3-Ultra-550B-A55B-NVFP4",
    "messages": MESSAGES,
    "temperature": 0,
    "max_tokens": 8192,
    "stop": ["Question:", "</s>", "<|im_end|>"]
}).encode()

def fire(url):
    req = urllib.request.Request(f"{url}/v1/chat/completions", data=PAYLOAD, headers={"Content-Type": "application/json"})
    try:
        resp = json.loads(urllib.request.urlopen(req, timeout=120).read())
        content = resp["choices"][0]["message"]["content"]
        lower = content.lower()
        no_q = any(x in lower for x in NO_Q_KEYWORDS)
        return "NO_QUESTION" if no_q else "OK"
    except Exception as e:
        return f"ERROR:{e}"

def run_target(label, url, n, concurrency=8):
    print(f"=== {label} ({n} requests, {concurrency} concurrent) ===", flush=True)
    results = {"OK": 0, "NO_QUESTION": 0, "ERROR": 0}
    errors = []
    with ThreadPoolExecutor(max_workers=concurrency) as pool:
        futures = {pool.submit(fire, url): i for i in range(1, n + 1)}
        for f in as_completed(futures):
            i = futures[f]
            r = f.result()
            if r.startswith("ERROR"):
                results["ERROR"] += 1
                errors.append(f"  #{i}: {r}")
            else:
                results[r] += 1
    print(f"  {label}: {results['OK']} OK, {results['NO_QUESTION']} NO_QUESTION, {results['ERROR']} ERROR", flush=True)
    for e in errors:
        print(e, flush=True)
    print(flush=True)

N = 20

run_target("GATEWAY", GATEWAY_URL, N)
for name, url in DECODE_PODS.items():
    run_target(f"DECODE {name}", url, N)
for name, url in PREFILL_POD.items():
    run_target(f"PREFILL {name}", url, N)
