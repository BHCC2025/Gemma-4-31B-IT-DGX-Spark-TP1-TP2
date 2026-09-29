#!/usr/bin/env python3
"""Measure TRUE prefill speed with prompts the prefix cache has never seen.

  bench-prefill-cold.py [BASE_URL] [MODEL] [--ktok 12] [--runs 3]

Why this exists: bench-decode.py --long reuses the same prompt across runs, so on a
server with prefix caching run 2+ are cache hits and the reported prefill rate is
several times the real one.

Every prompt here starts with a fresh UUID and is filled with randomly drawn words, so
no two runs share a prefix beyond the chat template itself.
"""
import json, random, statistics, sys, time, urllib.request, uuid

base, model = "http://127.0.0.1:8000/v1", None
ktok, runs = 12, 3
a = sys.argv[1:]; i = 0
while i < len(a):
    if a[i] == "--ktok": ktok = int(a[i+1]); i += 2
    elif a[i] == "--runs": runs = int(a[i+1]); i += 2
    elif base == "http://127.0.0.1:8000/v1" and a[i].startswith("http"): base = a[i]; i += 1
    else: model = a[i]; i += 1

if model is None:
    model = json.load(urllib.request.urlopen(base + "/models", timeout=30))["data"][0]["id"]

WORDS = ("reconcile ledger vendor invoice quarter regional threshold audit variance accrual "
         "pipeline schema migration rollback checksum tenant quota latency percentile shard "
         "cursor idempotent backfill retention partition manifest artifact rollout canary").split()

def make_prompt(target_tokens):
    rnd = random.Random(uuid.uuid4().int)
    # ~0.75 words per token; overshoot slightly, the exact size is reported per run
    n = int(target_tokens * 0.78)
    body = " ".join(rnd.choice(WORDS) for _ in range(n))
    return f"Session {uuid.uuid4()}. Notes follow.\n\n{body}\n\nReply with one short word."

def run_once():
    prompt = make_prompt(ktok * 1000)
    body = {"model": model, "messages": [{"role": "user", "content": prompt}],
            "max_tokens": 8, "stream": True, "stream_options": {"include_usage": True},
            "chat_template_kwargs": {"enable_thinking": False}}
    req = urllib.request.Request(base + "/chat/completions",
        data=json.dumps(body).encode(), headers={"Content-Type": "application/json"})
    t0 = time.time(); ttft = None; usage = None
    with urllib.request.urlopen(req, timeout=900) as r:
        for raw in r:
            if not raw.startswith(b"data: "): continue
            chunk = raw[6:].strip()
            if chunk == b"[DONE]": break
            try: d = json.loads(chunk)
            except Exception: continue
            if d.get("usage"): usage = d["usage"]
            for ch in d.get("choices") or []:
                delta = ch.get("delta") or {}
                if ttft is None and (delta.get("content") or delta.get("reasoning_content")):
                    ttft = time.time() - t0
    total = time.time() - t0
    pt = (usage or {}).get("prompt_tokens")
    return pt, ttft, total

print(f"cold prefill: {model} @ {base}  target ~{ktok}K tokens, {runs} runs, unique prompt each time")
rates = []
for k in range(runs):
    pt, ttft, total = run_once()
    if pt and ttft:
        rate = pt / ttft
        rates.append(rate)
        print(f"  run{k+1}: prompt={pt} ttft={ttft:.2f}s prefill={rate:.0f} tok/s total={total:.2f}s")
    else:
        print(f"  run{k+1}: incomplete (prompt_tokens={pt} ttft={ttft})")
if rates:
    print(f"MEDIAN cold prefill = {statistics.median(rates):.0f} tok/s")
