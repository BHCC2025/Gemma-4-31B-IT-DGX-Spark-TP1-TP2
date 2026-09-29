# Changelog

## 0.1.1 — 2026-09-29

- `kit/` updated to dgx-spark-recipe-kit v0.2.1 (the TP2 network settings were already v0.1.2's):
  - `bench/bench.sh` and `scripts/smoke-test.sh` now run the kit's shared suite (same test code as before), so every
    recipe is measured the same way.
  - `./setup.sh --check` works on a fresh 2-Spark clone (it used to fail or stop in the network test).
- `cluster.env` values can be overridden from the environment for one run (`PORT=8001 ./run.sh tp1`); they used to
  be silently ignored.
- `DRY_RUN=1` prints the docker commands before the models are downloaded (it stopped at MODEL MISSING).
- `./run.sh status` checks the head locally instead of over SSH to itself.
- Launch commands are unchanged (checked with `DRY_RUN=1`), so the 0.1.0 numbers stand.

## 0.1.0 — 2026-09-29

- First version: TP1 and TP2 behind one `run.sh`, configured through `cluster.env`, set up with `./setup.sh`
  (dgx-spark-recipe-kit under `kit/`).
- Speculative decoding with Google's `gemma-4-31B-it-assistant` draft model by default (`SPEC=draft`);
  `SPEC=ngram` and `SPEC=off` for comparison.
- TP2 uses vLLM's multi-node mp backend (no Ray) with the kit's pair NCCL profile.
- Draft tokens default to 4, chosen from a 0–6 sweep on both TP sizes (`bench/results/2026-09-29-tp1-tp2.md`).
- TP1 and TP2 benched on our own Sparks with this repo's launcher: 24.2 / 16.6 tok/s (TP1) and 40.6 / 28.0 tok/s
  (TP2), code / prose. Both rows verified.
