#!/usr/bin/env python3
"""Decode/prefill benchmark against any OpenAI-compatible /v1/chat/completions.

usage: bench-decode.py [BASE_URL] [MODEL] [--long N_KTOK] [--runs N] [--max-tokens N] [--no-think] [--code] [--timings]
  --no-think / --think -> chat_template_kwargs.enable_thinking=false/true (server default otherwise) ; --code -> code-generation prompt (for MTP acceptance)
  BASE_URL defaults to http://127.0.0.1:8000/v1 ; MODEL defaults to the first id in /v1/models
  --long 16   -> ~16K-token prompt (measures prefill tok/s and decode at depth)
Reports per run: prompt tokens, generated tokens, TTFT, prefill tok/s, decode tok/s.
"""
import json, statistics, sys, time, urllib.request

base = "http://127.0.0.1:8000/v1"
model = None
runs, max_tokens, long_k = 3, 512, 0
no_think, code, timings, think = False, False, False, False
a = sys.argv[1:]
i = 0
while i < len(a):
    if a[i] == "--long":
        long_k = int(a[i + 1]); i += 2
    elif a[i] == "--runs":
        runs = int(a[i + 1]); i += 2
    elif a[i] == "--max-tokens":
        max_tokens = int(a[i + 1]); i += 2
    elif a[i] == "--no-think":
        no_think = True; i += 1
    elif a[i] == "--think":
        think = True; i += 1
    elif a[i] == "--code":
        code = True; i += 1
    elif a[i] == "--timings":
        timings = True; i += 1
    elif a[i].startswith("http"):
        base = a[i].rstrip("/"); i += 1
    else:
        model = a[i]; i += 1

if model is None:
    with urllib.request.urlopen(base + "/models") as r:
        model = json.load(r)["data"][0]["id"]

filler = ("The quick brown fox jumps over the lazy dog. PCIe lanes carry data between the host and the GPU. "
          "Expert weights stream from system memory into the accelerator each token. ")
if long_k:
    prompt = (filler * (long_k * 1000 * 4 // len(filler) + 1)) + "\n\nSummarize the text above in 3 sentences."
elif code:
    prompt = ("Write a complete, production-quality Python module implementing a thread-safe LRU cache with "
              "per-entry TTL expiry. Include type hints, docstrings, and a pytest test file at the end. Output code only.")
else:
    prompt = "Write about 600 words explaining how PCIe works, for a curious engineer."

body = {"model": model, "messages": [{"role": "user", "content": prompt}], "max_tokens": max_tokens,
        "stream": True, "stream_options": {"include_usage": True}}
if no_think:
    body["chat_template_kwargs"] = {"enable_thinking": False}
if think:
    body["chat_template_kwargs"] = {"enable_thinking": True}
if timings:
    body["timings_per_token"] = True


def one():
    req = urllib.request.Request(base + "/chat/completions", data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json", "Authorization": "Bearer x"})
    t0 = time.time(); tfirst = None; n = 0; usage = None; tm = None
    with urllib.request.urlopen(req, timeout=1800) as r:
        for line in r:
            line = line.decode().strip()
            if not line.startswith("data:"):
                continue
            d = line[5:].strip()
            if d == "[DONE]":
                break
            j = json.loads(d)
            if j.get("usage"):
                usage = j["usage"]
            if j.get("timings"):
                tm = j["timings"]
            ch = j.get("choices") or []
            if ch:
                delta = ch[0].get("delta") or {}
                if delta.get("content") or delta.get("reasoning_content") or delta.get("reasoning"):
                    if tfirst is None:
                        tfirst = time.time()
                    n += 1
    t1 = time.time()
    if tfirst is None:
        tfirst = t1
    p_tok = usage["prompt_tokens"] if usage else None
    c_tok = usage["completion_tokens"] if usage else n
    ttft = tfirst - t0
    gen_s = t1 - tfirst
    return {"prompt_tokens": p_tok, "completion_tokens": c_tok, "ttft": ttft,
            "prefill_tps": (p_tok / ttft if p_tok and ttft > 0 else None),
            "decode_tps": (c_tok / gen_s if gen_s > 0 else None), "total": t1 - t0, "tm": tm}


print(f"model={model} base={base} long_k={long_k} runs={runs} max_tokens={max_tokens} no_think={no_think} code={code}")
res = []
for k in range(runs):
    r = one(); res.append(r)
    pf = f"{r['prefill_tps']:.0f}" if r["prefill_tps"] else "n/a"
    dc = f"{r['decode_tps']:.1f}" if r["decode_tps"] else "n/a"
    extra = ""
    if r.get("tm"):
        tm = r["tm"]; dn = tm.get("draft_n"); da = tm.get("draft_n_accepted")
        if dn:
            extra += f" draft={da}/{dn} acc={da/dn:.2f}"
        if tm.get("predicted_per_second"):
            extra += f" srv_decode={tm['predicted_per_second']:.1f}"
    print(f"run{k+1}: prompt={r['prompt_tokens']} gen={r['completion_tokens']} ttft={r['ttft']:.2f}s "
          f"prefill={pf} tok/s decode={dc} tok/s total={r['total']:.1f}s{extra}")
dec = [r["decode_tps"] for r in res if r["decode_tps"]]
pre = [r["prefill_tps"] for r in res if r["prefill_tps"]]
line = f"MEDIAN decode={statistics.median(dec):.1f} tok/s" if dec else "MEDIAN decode=n/a"
if pre:
    line += f"  prefill={statistics.median(pre):.0f} tok/s"
print(line)
