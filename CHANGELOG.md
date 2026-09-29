# Changelog

## 0.1.3 — 2026-09-29

- Quick start opens with a "Before you start" checklist (DGX OS, the cables, and that Hugging Face needs nothing).
- Corrected: neither model is gated on Hugging Face, so no login or licence acceptance is needed to download them
  (checked with an anonymous download). The README, troubleshooting, NOTICE and `scripts/get-draft-model.sh` said
  otherwise.
- `kit/` updated to dgx-spark-recipe-kit v0.4.0: `./setup.sh` test-downloads one small file of the model right after
  the dependencies, so a network problem (or, for a gated model, a missing licence or login) shows up before
  anything big happens.
- Launch commands unchanged (checked with `DRY_RUN=1`).

## 0.1.2 — 2026-09-29

- `kit/` updated to dgx-spark-recipe-kit v0.3.0: `./setup.sh --check` checks every node in `cluster.env` (it only
  checked the head), the RDMA test works for a second user on the same machine, and the benchmark refuses to file
  another model's results here. Tested end to end as a brand-new account on two Sparks.
- README and results corrected against the logs: the draft model speeds decode up 2.4–3.6× (not "triples"); TP2 is
  1.4–1.8× TP1 (not "1.7× at every setting"); beyond 4 draft tokens prose gains 5.5% at most; the acceptance-rate
  figure is removed (the bench doesn't record it); the image is a pinned tag with its digest in `recipe.yaml`.
- Documented, from the logs: with the draft model on, vLLM v0.29.0 gets no prefix-cache hits (`SPEC=off` has them).
- `MODEL_DIR`, `DRAFT_DIR` and `CACHE_DIR` overrides now reach the TP2 worker too; `scripts/get-draft-model.sh`
  honours overrides and stops with an error if copying to a worker fails.
- `DRY_RUN=1` prints only the docker commands; `./run.sh` usage no longer prints code.
- NOTICE credits EmanueleMeazzo/gemma-4-dgx-spark-vllm; GitHub issue template asking for the setup report.
- Launch commands unchanged (checked with `DRY_RUN=1` against 0.1.1), so the benchmark numbers stand.

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
