# Changelog

## 0.1.0 — 2026-09-29

- First version: TP1 and TP2 behind one `run.sh`, configured through `cluster.env`, set up with `./setup.sh`
  (dgx-spark-recipe-kit under `kit/`).
- Speculative decoding with Google's `gemma-4-31B-it-assistant` draft model by default (`SPEC=draft`);
  `SPEC=ngram` and `SPEC=off` for comparison.
- TP2 uses vLLM's multi-node mp backend (no Ray) with the kit's pair NCCL profile.
- Draft tokens default to 4, chosen from a 0–6 sweep on both TP sizes (`bench/results/2026-09-29-tp1-tp2.md`).
- TP1 and TP2 benched on our own Sparks with this repo's launcher: 24.2 / 16.6 tok/s (TP1) and 40.6 / 28.0 tok/s
  (TP2), code / prose. Both rows verified.
