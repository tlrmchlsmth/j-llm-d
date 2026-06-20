#!/usr/bin/env python3
"""
Repro: vLLM stop sequences fire on reasoning tokens inside <think> blocks.

Demonstrates that "Question:" stop sequence kills generation mid-reasoning
in P/D mode, returning content=null. The same prompt works fine when:
  - "Question:" is removed from stop sequences (Proof 2)
  - The request hits a pod directly instead of going through P/D (Proof 3)

Usage (on poker pod or any pod with access to the gateway):
  python3 repro_stop_in_reasoning.py

Requires: GATEWAY_URL and PREFILL_URL environment variables, or defaults below.
"""

import json
import os
import urllib.request

GATEWAY_URL = os.environ.get(
    "GATEWAY_URL",
    "http://ecrncevi-wide-ep-inference-gateway-istio.vllm.svc.cluster.local",
)
PREFILL_URL = os.environ.get("PREFILL_URL", "http://10.244.8.12:8000")
MODEL = "nvidia/NVIDIA-Nemotron-3-Ultra-550B-A55B-NVFP4"

# 8-shot GSM8K prompt (doc_id=0) that reproducibly triggers the bug in P/D.
# The model's reasoning restates the problem as "5.  Question: How much..."
# which matches the "Question:" stop sequence.
MESSAGES = [
    {"role": "user", "content": "Question: Jen and Tyler are gymnasts practicing flips. Jen is practicing the triple-flip while Tyler is practicing the double-flip. Jen did sixteen triple-flips during practice. Tyler flipped in the air half the number of times Jen did. How many double-flips did Tyler do?\nAnswer:"},
    {"role": "assistant", "content": "Jen did 16 triple-flips, so she did 16 * 3 = <<16*3=48>>48 flips.\nTyler did half the number of flips, so he did 48 / 2 = <<48/2=24>>24 flips.\nA double flip has two flips, so Tyler did 24 / 2 = <<24/2=12>>12 double-flips.\n#### 12"},
    {"role": "user", "content": "Question: Four people in a law firm are planning a party. Mary will buy a platter of pasta for $20 and a loaf of bread for $2. Elle and Andrea will split the cost for buying 4 cans of soda which cost $1.50 each, and chicken wings for $10. Joe will buy a cake that costs $5. How much more will Mary spend than the rest of the firm put together?\nAnswer:"},
    {"role": "assistant", "content": "Mary will spend $20 + $2 = $<<20+2=22>>22.\nElle and Andrea will spend $1.5 x 4 = $<<1.5*4=6>>6 for the soda.\nElle and Andrea will spend $6 + $10 = $<<6+10=16>>16 for the soda and chicken wings.\nElle, Andrea, and Joe together will spend $16 + $5 = $<<16+5=21>>21.\nSo, Mary will spend $22 - $21 = $<<22-21=1>>1 more than all of them combined.\n#### 1"},
    {"role": "user", "content": "Question: A charcoal grill burns fifteen coals to ash every twenty minutes of grilling. The grill ran for long enough to burn three bags of coals. Each bag of coal contains 60 coals. How long did the grill run?\nAnswer:"},
    {"role": "assistant", "content": "The grill burned 3 * 60 = <<3*60=180>>180 coals.\nIt takes 20 minutes to burn 15 coals, so the grill ran for 180 / 15 * 20 = <<180/15*20=240>>240 minutes.\n#### 240"},
    {"role": "user", "content": "Question: Toula went to the bakery and bought various types of pastries. She bought 3 dozen donuts which cost $68 per dozen, 2 dozen mini cupcakes which cost $80 per dozen, and 6 dozen mini cheesecakes for $55 per dozen. How much was the total cost?\nAnswer:"},
    {"role": "assistant", "content": "The cost of the donuts is 3 x $68 = $<<3*68=204>>204.\nThe cost of the mini cupcakes is 2 x $80 = $<<2*80=160>>160.\nThe cost of the mini cheesecakes is 6 x $55 = $<<6*55=330>>330.\nTherefore the total cost is $204 + $160 + $330 = $<<204+160+330=694>>694.\n#### 694"},
    {"role": "user", "content": "Question: Carlos is planting a lemon tree. The tree will cost $90 to plant. Each year it will grow 7 lemons, which he can sell for $1.5 each. It costs $3 a year to water and feed the tree. How many years will it take before he starts earning money on the lemon tree?\nAnswer:"},
    {"role": "assistant", "content": "He makes $1.5 * 7 = $<<1.5*7=10.5>>10.5 selling mass lemons per year.\nHe then earns $10.5 - $3 = $<<10.5-3=7.5>>7.5 per year.\nSo it will take $90 / $7.5 = <<90/7.5=12>>12 years to earn the money back.\n#### 12"},
    {"role": "user", "content": "Question: Marissa is hiking a 12-mile trail. She took 1 hour to walk the first 4 miles, then another hour to walk the next two miles. If she wants her average speed for the entire trail to be 4 miles per hour, what speed (in miles per hour) does she need to walk the remaining distance?\nAnswer:"},
    {"role": "assistant", "content": "First, we need to determine the total time Marissa has for the hike. We can use the formula time = distance / speed. Since her desired average speed is 4 miles per hour, the total time is 12 miles / 4 miles per hour = <<12/4=3>>3 hours.\nThe total time she took for the first 6 miles is 1 + 1 = <<1+1=2>>2 hours.\nShe has 3 - 2 = <<3-2=1>>1 hour to walk the remaining distance.\nThe remaining distance is 12 - 4 - 2 = <<12-4-2=6>>6 miles.\nSo, her speed for the remaining distance is 6 miles / 1 hour = <<6/1=6>>6 miles per hour.\n#### 6"},
    {"role": "user", "content": "Question: Caprice is taking piano lessons. Her mother pays the teacher $10 for every half-hour of teaching her daughter. If Caprice is taking one lesson per week, and the lesson lasts 1 hour, how much money would the teacher earn in 5 weeks?\nAnswer:"},
    {"role": "assistant", "content": "If half-hour lesson is worth $10, then a one-hour lesson costs 2 * 10 = $<<10*2=20>>20.\nOne lesson per week would mean that in 5 weeks the teacher would earn 20 * 5 = $<<20*5=100>>100.\n#### 100"},
    {"role": "user", "content": "Question: A school bought 20 cartons of pencils at the start of school. Pencils come in cartons of 10 boxes and each box costs $2. The school also bought 10 cartons of markers. A carton has 5 boxes and costs $4. How much did the school spend in all?\nAnswer:"},
    {"role": "assistant", "content": "The school bought 20 x 10 = <<20*10=200>>200 boxes of pencils.\nThe pencils cost 200 x $2 = $<<200*2=400>>400.\nThe school bought 10 x 5 = <<10*5=50>>50 boxes of markers.\nThe markers cost 50 x $4 = $<<50*4=200>>200.\nThus, the school spent a total of $400 + $200 = $<<400+200=600>>600.\n#### 600"},
    {"role": "user", "content": "Question: Janet’s ducks lay 16 eggs per day. She eats three for breakfast every morning and bakes muffins for her friends every day with four. She sells every egg at the farmers' market daily for $2 per fresh duck egg. How much in dollars does she make every day at the farmers' market?\nAnswer:"},
]


def fire(url, stop):
    payload = json.dumps({
        "model": MODEL,
        "messages": MESSAGES,
        "temperature": 0,
        "max_tokens": 8192,
        "stop": stop,
    }).encode()
    req = urllib.request.Request(
        f"{url}/v1/chat/completions",
        data=payload,
        headers={"Content-Type": "application/json"},
    )
    return json.loads(urllib.request.urlopen(req, timeout=180).read())


def print_result(label, resp):
    c = resp["choices"][0]
    content = c["message"]["content"]
    reasoning = c["message"].get("reasoning") or ""
    print(f"=== {label} ===")
    print(f"content: {repr(content[:200] if content else content)}")
    print(f"reasoning (last 200 chars): ...{reasoning[-200:]}")
    print(f"stop_reason: {c.get('stop_reason')}")
    print(f"finish_reason: {c['finish_reason']}")
    print(f"completion_tokens: {resp['usage']['completion_tokens']}")
    has_question = "Question:" in reasoning
    print(f"reasoning contains 'Question:': {has_question}")
    print()


print("Prompt: GSM8K doc_id=0 (8-shot, 21 messages, temperature=0)")
print(f"Gateway: {GATEWAY_URL}")
print(f"Prefill: {PREFILL_URL}")
print()

print_result(
    "PROOF 1: Gateway (P/D) WITH Question: stop → content=null, stop fires on reasoning",
    fire(GATEWAY_URL, ["Question:", "</s>", "<|im_end|>"]),
)

print_result(
    "PROOF 2: Gateway (P/D) WITHOUT Question: stop → content works",
    fire(GATEWAY_URL, ["</s>", "<|im_end|>"]),
)

print_result(
    "PROOF 3: Prefill direct WITH Question: stop → content works (different reasoning path)",
    fire(PREFILL_URL, ["Question:", "</s>", "<|im_end|>"]),
)
