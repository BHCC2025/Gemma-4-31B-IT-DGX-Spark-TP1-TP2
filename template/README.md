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
| Hardware | {{SPARKS_WORDS_CAP}} DGX Spark (or other GB10 boxes with a ConnectX-7) |
| Cables | TP2: one QSFP cable. TP3: three, in a triangle (see [docs/networking.md](docs/networking.md)) |
| OS | DGX OS 7 (Ubuntu 24.04), Docker with the NVIDIA runtime |
| Disk | TODO GB free NVMe on **every** node (each node needs its own local copy of the model) |
| Image | `{{IMAGE}}` (pinned) |
| Model | `{{HF_REPO}}` @ `TODO` |
| Access | SSH from the head node to the workers (`setup.sh` sets up key login); `sudo` for installs and fabric IPs |

## Quick start

On the Spark you'll serve from (the head node):

```bash
git clone https://github.com/BHCC2025/{{REPO}}.git
cd {{REPO}}
./setup.sh
```

`setup.sh` asks how many Sparks you have and their SSH names, then:
- checks and installs what's missing
- works out your cabling and assigns fabric IPs if the ports have none, after asking
- writes `cluster.env` for you
- pulls the image and **tests the network with a real NCCL all-reduce** before anything big is downloaded
- downloads the model once and copies it to the other Sparks

It asks before every change. Re-run it any time. `./setup.sh --check` only reports.

Then start it:

```bash
{{QUICKSTART_CMDS}}
./run.sh status     # wait for "serving: [...]"; loading takes a few minutes
scripts/smoke-test.sh
```

Stop with `./run.sh stop`, which stops the container on every node listed in `cluster.env`. Cabling details are in
[docs/networking.md](docs/networking.md).

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

The recipe headers in [recipes/](recipes/) list the rest. `cluster.env` values can be overridden the same way
(`PORT=8001 ./run.sh tp1`).

## How it works

TODO: one bullet per TP size (memory fit, network, anything patched), plus one per notable feature with a doc in
[docs/](docs/).

## Benchmarks

`bench/bench.sh LABEL` runs the same suite against whatever is serving on `:8000` (the shared suite from the kit, so
every recipe is measured the same way):
- single-stream decode for code, prose and a ~9K-token prompt
- cold prefill at 8K and 28K tokens with unique prompts (prefix cache off)
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
