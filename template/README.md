# {{MODEL}} on {{SPARKS_WORDS}} DGX {{SPARKS_NOUN}} (TP{{TP_MIN}}–TP{{TP_MAX}})

Run `{{HF_REPO}}` with vLLM on {{SPARKS_WORDS}} NVIDIA DGX {{SPARKS_NOUN}} (GB10, 128 GB unified memory{{EACH}}). One script,
`./run.sh {{TP_CMDS}}`, and one config file describing your nodes.

TODO: one paragraph — what is new or notable about this recipe.

| Sparks | Command | Context | Decode, single stream (code / prose) | Cold prefill 8K | Verified |
|---|---|---|---|---|---|
{{README_ROWS}}

Every row is benched on our own Sparks with `bench/bench.sh` (same prompts for every row) and must pass the smoke
test before it is marked verified. See [bench/results/](bench/results/).

- **Endpoint:** `http://<head>:8000/v1` (OpenAI-compatible), model `{{SERVED}}`
- **Defaults:** TODO — thinking on/off, tool-call parser, speculative decoding, KV cache type, concurrent sequences.

## Requirements

| | |
|---|---|
| Hardware | {{SPARKS_WORDS_CAP}} DGX {{SPARKS_NOUN_CAP}} (or other GB10 boxes with a ConnectX-7) |
{{CABLES_ROW}}| OS | DGX OS 7 (Ubuntu 24.04), Docker with the NVIDIA runtime |
| Disk | TODO GB free NVMe{{DISK_WHERE}} |
| Image | `{{IMAGE}}` (pinned) |
| Model | `{{HF_REPO}}` @ `TODO` |
| Access | {{ACCESS}} |

## Quick start

Before you start:
- DGX OS 7 on {{EVERY_SPARK}}, with its current updates.
<!-- multi -->
- The QSFP cables connected: {{CABLING_SENTENCE}}.
  No IP addresses are needed on the cabled ports; `./setup.sh` assigns them ([docs/networking.md](docs/networking.md)).
<!-- /multi -->
- Nothing to set up on Hugging Face unless the model is gated: `./setup.sh` test-downloads one small file first, and
  if the model is gated it shows the licence page to accept and offers to log you in.

On the Spark you'll serve from (the head node):

```bash
git clone https://github.com/BHCC2025/{{REPO}}.git
cd {{REPO}}
./setup.sh
```

`setup.sh` asks how many Sparks you have and their SSH names, then:
- checks and installs what's missing
<!-- multi -->
- works out your cabling and assigns fabric IPs if the ports have none, after asking
<!-- /multi -->
- writes `cluster.env` for you
<!-- multi -->
- pulls the image and **tests the network with a real NCCL all-reduce** before anything big is downloaded
- downloads the model once and copies it to the other Sparks
<!-- /multi -->
<!-- single -->
- pulls the image and checks the GPU is visible inside it
- downloads the model
<!-- /single -->

It asks before every change. Re-run it any time. `./setup.sh --check` only reports.

Then start it:

```bash
{{QUICKSTART_CMDS}}
./run.sh status     # wait for "serving: [...]"; loading takes a few minutes
scripts/smoke-test.sh
```

Stop with `./run.sh stop`, which stops the container on every node listed in `cluster.env`.
<!-- multi -->
Cabling details are in [docs/networking.md](docs/networking.md).
<!-- /multi -->

## Settings

Set any of these in the environment for one run (`SEQS=8 ./run.sh tp{{TP_MAX}}`). `DRY_RUN=1` prints the docker
commands and starts nothing.

| Variable | {{SETTINGS_HEAD}} | What it does |
|---|{{SETTINGS_SEP}}---|
| `SEQS` | {{SETTINGS_16}} | Max concurrent sequences |
| `MAXLEN` | {{SETTINGS_MAXLEN}} | Max context |
| `GMU` | {{SETTINGS_GMU}} | vLLM `--gpu-memory-utilization` |
| `CHUNK` | {{SETTINGS_CHUNK}} | `--max-num-batched-tokens` |
| `KV_DTYPE` | {{SETTINGS_KV}} | `auto` = BF16 |
| `PREFIX_CACHE` | {{SETTINGS_PREFIX}} | `0` turns prefix caching off |
| `GRAPHS` | {{SETTINGS_GRAPHS}} | CUDA-graph mode: `default`, `eager` |
| `EXTRA` / `DOCKER_EXTRA` | {{SETTINGS_EMPTY}} | extra args for vLLM / `docker run` |

{{EXTRA_KNOBS}} be set the same way, and so can any `cluster.env` value
(`PORT=8001 ./run.sh tp{{TP_MIN}}`).

## How it works

TODO: one bullet per TP size (memory fit, network, anything patched), plus one per notable feature with a doc in
[docs/](docs/).

## Benchmarks

`bench/bench.sh LABEL` runs the same suite against whatever is serving on `:8000` (the shared suite from the kit, so
every recipe is measured the same way):
- single-stream decode for code, prose and a ~9K-token prompt
- cold prefill at 8K and 28K tokens (unique prompts, so no prefix-cache hits)
- the smoke test; add `LONG=1` for the needle test

Results and raw logs go in [bench/results/](bench/results/).

## Troubleshooting

Run `./setup.sh --check` and read the FAIL lines. It writes `.setup/report.txt`, which is what to attach to an issue.
See also [docs/troubleshooting.md](docs/troubleshooting.md). The two most common problems:
- TODO: the most common model-specific problem.
- Out of memory while loading: other containers are still running, or page cache is taking memory. Run `./run.sh stop` on everything and check `free -g`.

## Credits

TODO: the checkpoint's authors, any upstream recipe or patch (by GitHub handle), and what came from each.
vLLM is Copyright contributors to the vLLM project, Apache-2.0.

Full details are in [NOTICE](NOTICE).

## License

Apache-2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).
