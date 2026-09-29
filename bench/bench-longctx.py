#!/usr/bin/env python3
"""bench-longctx.py — needle-in-a-haystack + speed at long context against an OpenAI-compatible server.

usage: bench-longctx.py BASE_URL MODEL --ktok 128 256 512 900 [--needles 3] [--gen 200]
For each size: builds varied filler (random sentences, not one repeated line, so attention cannot shortcut it),
hides N passphrases at evenly spaced depths, streams one request and reports prompt tokens, time to first token
(= prefill), prefill tok/s, decode tok/s over the answer, and how many passphrases came back exactly.
Sizes are hit with the server's /tokenize endpoint, so --ktok is real model tokens. Prefix caching is off on these
servers, so every request is a cold prefill.
"""
import argparse, json, random, time, urllib.request

WORDS = ("river mountain copper lantern orchard violet harbor quartz meadow falcon timber saffron glacier ember "
         "prairie cobalt thistle canyon marble willow beacon juniper basalt heron cedar opal tundra fjord sable "
         "citadel lagoon ivory maple onyx pylon quarry reef sierra topaz umber valley walnut yarrow zephyr").split()
VERBS = "measured carried painted counted followed repaired described mapped traded weighed guarded sorted".split()

def sentence(rng):
    a, b, c = rng.sample(WORDS, 3)
    return (f"The {a} keeper {rng.choice(VERBS)} {rng.randint(2, 999)} {b} crates near the {c} "
            f"station on day {rng.randint(1, 365)}.")

def post(url, body, stream=False, timeout=7200):
    req = urllib.request.Request(url, data=json.dumps(body).encode(), headers={"Content-Type": "application/json"})
    return urllib.request.urlopen(req, timeout=timeout)

def count_tokens(base, model, text):
    root = base.rsplit("/v1", 1)[0]
    with post(f"{root}/tokenize", {"model": model, "prompt": text}) as r:
        return json.load(r)["count"]

def build(base, model, ktok, n_needles, seed):
    rng = random.Random(seed)
    # calibrate tokens per sentence on a 2000-sentence sample
    sample = " ".join(sentence(rng) for _ in range(2000))
    per = count_tokens(base, model, sample) / 2000
    n = int(ktok * 1000 / per)
    sents = [sentence(rng) for _ in range(n)]
    needles = []
    for i in range(n_needles):
        key = f"vault-{chr(65 + i)}"
        code = f"{rng.choice(WORDS)}-{rng.choice(WORDS)}-{rng.randint(1000, 9999)}"
        pos = int(n * (i + 1) / (n_needles + 1))
        sents.insert(pos, f"IMPORTANT: the passphrase for {key} is {code}.")
        needles.append((key, code, (i + 1) / (n_needles + 1)))
    q = ("Above is a long log. Somewhere in it are passphrases for " + ", ".join(k for k, _, _ in needles) +
         ". List each vault and its exact passphrase, one per line, like 'vault-A: word-word-1234'. Nothing else.")
    return " ".join(sents) + "\n\n" + q, needles

def run(base, model, ktok, n_needles, gen, seed):
    prompt, needles = build(base, model, ktok, n_needles, seed)
    body = {"model": model, "messages": [{"role": "user", "content": prompt}], "max_tokens": gen,
            "temperature": 0, "stream": True, "stream_options": {"include_usage": True}}
    t0 = time.time(); t_first = None; text = ""; usage = {}
    with post(f"{base}/chat/completions", body, stream=True) as r:
        for raw in r:
            line = raw.decode().strip()
            if not line.startswith("data:") or line == "data: [DONE]":
                continue
            ev = json.loads(line[5:])
            if ev.get("usage"):
                usage = ev["usage"]
            for ch in ev.get("choices", []):
                d = ch.get("delta", {})
                piece = (d.get("content") or "") + (d.get("reasoning") or d.get("reasoning_content") or "")
                if piece and t_first is None:
                    t_first = time.time()
                text += d.get("content") or ""
    t_end = time.time()
    pt, ct = usage.get("prompt_tokens", 0), usage.get("completion_tokens", 0)
    ttft = (t_first or t_end) - t0
    dec = (ct - 1) / (t_end - t_first) if t_first and ct > 1 and t_end > t_first else 0.0
    found = sum(1 for k, c, _ in needles if c in text)
    print(f"ctx={pt:>8,} tok  ttft={ttft:7.1f}s  prefill={pt / ttft if ttft else 0:7.0f} tok/s  "
          f"decode={dec:5.1f} tok/s  needles={found}/{len(needles)}  gen={ct}", flush=True)
    for k, c, depth in needles:
        print(f"    {k} @ {depth:4.0%}  {'OK  ' if c in text else 'MISS'}  expected {c}")
    print("    answer:", " | ".join(text.strip().splitlines())[:300], flush=True)
    return found == len(needles)

if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("base"); ap.add_argument("model")
    ap.add_argument("--ktok", type=float, nargs="+", default=[128, 256, 512, 900])
    ap.add_argument("--needles", type=int, default=3); ap.add_argument("--gen", type=int, default=200)
    ap.add_argument("--seed", type=int, default=7)
    a = ap.parse_args()
    for k in a.ktok:
        run(a.base, a.model, k, a.needles, a.gen, a.seed + int(k))
