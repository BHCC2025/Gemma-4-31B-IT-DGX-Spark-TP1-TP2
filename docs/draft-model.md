# Draft model: speculative decoding

Google publishes a small draft model for Gemma 4 31B, `google/gemma-4-31B-it-assistant` (~0.5B parameters, BF16,
927 MB). Each step it proposes `DRAFT_TOKENS` tokens, and the 31B model checks them all in one forward pass. Every
accepted token is one the big model didn't have to generate on its own, which is what makes a dense,
bandwidth-limited model like this one faster.

## Pieces

- `scripts/get-draft-model.sh` downloads the draft model at a pinned revision to `DRAFT_DIR` on the head and copies
  it to the other Spark. `./setup.sh` runs it for you.
- The launchers mount `DRAFT_DIR` at `/models/draft` and pass
  `--speculative-config '{"model":"/models/draft","num_speculative_tokens":N}'`.
- No patches. vLLM v0.29.0 recognises the draft's `gemma4_assistant` config and runs it as `gemma4_mtp`, sharing
  the target's KV cache. At TP2 the draft is split across both Sparks like the target.
- Older images can't do this: their `transformers` fails on the `gemma4_assistant` model type. Stay on the pinned
  image.

## Choosing DRAFT_TOKENS

Measured on our Sparks with `bench/bench.sh` (full table in
[bench/results/2026-09-29-tp1-tp2.md](../bench/results/2026-09-29-tp1-tp2.md)):

| `DRAFT_TOKENS` | TP1 code / prose | TP2 code / prose |
|---|---|---|
| off | 6.8 / 6.8 | 12.0 / 12.1 |
| 2 | 17.2 / 14.7 | 30.5 / 25.3 |
| **4 (default)** | **24.2 / 16.6** | **40.6 / 28.0** |
| 6 | 29.0 / 17.5 | 44.2 / 28.9 |

- **4** is the default: prose and long prompts stop improving there.
- **6** for single-user coding: code keeps gaining because it is predictable, but results vary more run to run.
- **Lower** (2–3) if many requests share the server: rejected draft tokens are wasted work under load.
- `SPEC=ngram` (prompt lookup, no draft model) and `SPEC=off` are there for comparison.

## Cost

~1 GB of disk per node and a little memory for the draft weights. Prefill speed is unchanged.
