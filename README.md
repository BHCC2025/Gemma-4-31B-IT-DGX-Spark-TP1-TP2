# Gemma-4-31B-IT on 1 or 2 DGX Sparks (TP1–TP2)

Run NVIDIA's `nvidia/Gemma-4-31B-IT-NVFP4` checkpoint with vLLM on one or two NVIDIA DGX Sparks (GB10, 128 GB
unified memory each). One script, `./run.sh tp1|tp2`, and one config file describing your nodes.

The 31B model is dense: every generated token reads all of its weights, so decode speed is set by memory bandwidth.
Two Sparks each read half the weights per token. Speculative decoding uses Google's
`google/gemma-4-31B-it-assistant` draft model, which stock vLLM loads without patches.

| Sparks | Command | Context | Decode, single stream (code / prose) | Cold prefill 8K | Verified |
|---|---|---|---|---|---|
| 1 | `./run.sh tp1` | 256K | 24.2 / 16.6 tok/s | 1,409 tok/s | 2026-09-29 |
| 2 | `./run.sh tp2` | 256K | **40.6 / 28.0 tok/s** | 1,905 tok/s | 2026-09-29 |

Every row was benched on our own Sparks with `bench/bench.sh` (same prompts for every row) and passed the smoke test.
The draft model roughly triples decode speed (6.8 tok/s without it on one Spark). See [bench/results/](bench/results/).

- **Endpoint:** `http://<head>:8000/v1` (OpenAI-compatible), model `gemma-4-31b-it`
- **Defaults:** thinking off (turn it on per request with `"chat_template_kwargs": {"enable_thinking": true}`),
  tool calling on (`gemma4` parser), draft-model speculative decoding with 4 tokens, FP8 KV cache, prefix caching,
  16 concurrent sequences. Image input works.

## Requirements

| | |
|---|---|
| Hardware | 1–2 DGX Spark (or other GB10 boxes with a ConnectX-7) |
| Cables | TP2: one QSFP cable (see [docs/networking.md](docs/networking.md)) |
| OS | DGX OS 7 (Ubuntu 24.04), Docker with the NVIDIA runtime |
| Disk | ~33 GB free NVMe on **every** node (each node needs its own local copy of both models) |
| Image | `vllm/vllm-openai:v0.29.0` (pinned by digest) |
| Model | `nvidia/Gemma-4-31B-IT-NVFP4` @ `4135a98a`, draft `google/gemma-4-31B-it-assistant` @ `627c5ec1` |
| Access | A Hugging Face login that has accepted the Gemma terms (`hf auth login`); SSH from the head node to the worker (`setup.sh` sets up key login); `sudo` for installs and fabric IPs |

## Quick start

On the Spark you'll serve from (the head node):

```bash
git clone https://github.com/BHCC2025/Gemma-4-31B-IT-DGX-Spark-TP1-TP2.git
cd Gemma-4-31B-IT-DGX-Spark-TP1-TP2
./setup.sh
```

`setup.sh` asks how many Sparks you have (1 or 2) and their SSH names, then:
- checks and installs what's missing
- works out your cabling and assigns fabric IPs if the ports have none, after asking
- writes `cluster.env` for you
- pulls the image and **tests the network with a real NCCL all-reduce** before anything big is downloaded
- downloads the model and the draft model once and copies them to the other Spark

It asks before every change. Re-run it any time. `./setup.sh --check` only reports.

Then start it:

```bash
./run.sh tp1        # 1 Spark
./run.sh tp2        # 2 Sparks, one QSFP cable between them
./run.sh status     # wait for "serving: [...]"; loading takes a few minutes
scripts/smoke-test.sh
```

Stop with `./run.sh stop`, which stops the container on every node listed in `cluster.env`. Cabling details are in
[docs/networking.md](docs/networking.md).

## Settings

Set any of these in the environment for one run (`DRAFT_TOKENS=6 SEQS=8 ./run.sh tp2`). `DRY_RUN=1` prints the
docker commands and starts nothing.

| Variable | TP1 | TP2 | What it does |
|---|---|---|---|
| `SPEC` | draft | draft | Speculative decoding: `draft` (draft model), `ngram` (prompt lookup, no extra model), `off` |
| `DRAFT_TOKENS` | 4 | 4 | Draft tokens per step with `SPEC=draft` (6 is faster for single-user coding, see [docs/draft-model.md](docs/draft-model.md)) |
| `SEQS` | 16 | 16 | Max concurrent sequences |
| `MAXLEN` | 262144 | 262144 | Max context |
| `GMU` | 0.80 | 0.75 | vLLM `--gpu-memory-utilization` |
| `CHUNK` | 8192 | 8192 | `--max-num-batched-tokens` |
| `KV_DTYPE` | fp8 | fp8 | `auto` = BF16 |
| `PREFIX_CACHE` | 1 | 1 | `0` turns prefix caching off |
| `GRAPHS` | default | default | CUDA-graph mode: `default`, `eager` |
| `EXTRA` / `DOCKER_EXTRA` | | | extra args for vLLM / `docker run` |

The recipe headers in [recipes/](recipes/) list the rest.

## How it works

- **TP1:** the ~31 GB checkpoint fits one Spark with plenty of room for KV cache. Stock vLLM, no patches.
- **TP2:** tensor parallel over vLLM's multi-node mp backend (no Ray). Rank 1 starts on the worker, rank 0 on the
  head serves the API. NCCL talks over RoCE on the single cable, with the settings `./setup.sh` tested.
- **Draft model:** see [docs/draft-model.md](docs/draft-model.md). vLLM recognises the `gemma4_assistant` config
  and runs it as the draft; at TP2 it is split across both Sparks like the target.

## Benchmarks

`bench/bench.sh LABEL` runs the same suite against whatever is serving on `:8000`:
- single-stream decode for code, prose and a ~9K-token prompt
- cold prefill at 8K and 28K tokens with unique prompts (prefix cache off)
- the smoke test; add `LONG=1` for the needle test

Results and raw logs go in [bench/results/](bench/results/).

## Troubleshooting

Run `./setup.sh --check` and read the FAIL lines. It writes `.setup/report.txt`, which is what to attach to an issue.
See also [docs/troubleshooting.md](docs/troubleshooting.md). The two most common problems:
- Download fails with 401/403: the Gemma terms haven't been accepted on Hugging Face for both repos, or `hf auth login` wasn't run.
- Out of memory while loading: other containers are still running, or page cache is taking memory. Run `./run.sh stop` on everything and check `free -g`.

## Credits

The draft model is Google's [gemma-4-31B-it-assistant](https://huggingface.co/google/gemma-4-31B-it-assistant); the
NVFP4 checkpoint is NVIDIA's. Single-Spark Gemma 4 measurements, including which images can load the draft model,
are in [EmanueleMeazzo/gemma-4-dgx-spark-vllm](https://github.com/EmanueleMeazzo/gemma-4-dgx-spark-vllm).
vLLM is Copyright contributors to the vLLM project, Apache-2.0.

Full details are in [NOTICE](NOTICE).

## License

Apache-2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE). The models are under the Gemma terms of use.
