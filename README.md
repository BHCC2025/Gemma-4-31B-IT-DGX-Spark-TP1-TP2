# dgx-spark-recipe-kit

The shared setup kit for the BHCC2025 DGX Spark recipe repos. Every recipe carries a copy under `kit/`, so a user
gets the same experience whatever model they're setting up:

```bash
git clone https://github.com/BHCC2025/<recipe>.git && cd <recipe>
./setup.sh            # nodes, SSH, dependencies, cabling, fabric IPs, cluster.env, image, network test, model
./run.sh tpN
```

## Recipes using the kit

| Recipe | Sparks | Engine | Single-stream decode, code (fastest setup) |
|---|---|---|---|
| [Qwen3.8-Flash-Next-DGX-Spark-TP1-TP3](https://github.com/BHCC2025/Qwen3.8-Flash-Next-DGX-Spark-TP1-TP3) | 1–3 | vLLM | 57.4 tok/s (3 Sparks) |
| [Gemma-4-31B-IT-DGX-Spark-TP1-TP2](https://github.com/BHCC2025/Gemma-4-31B-IT-DGX-Spark-TP1-TP2) | 1–2 | vLLM | 40.6 tok/s (2 Sparks) |

Every number is benched on our own Sparks with the recipe's `bench/bench.sh`; see each recipe's `bench/results/`.

## What `setup.sh` does

| Step | What it does | Changes anything? |
|---|---|---|
| 1. Nodes | Asks how many Sparks and their SSH names; checks passwordless SSH | offers `ssh-copy-id` |
| 2. Inspect | Runs `lib/probe.py` on every node: OS, GPU, memory, tools, Docker, disk, LAN, every RDMA port | no |
| 3. Dependencies | Docker without sudo, rsync, perftest, the Hugging Face CLI | offers `apt install`, docker group, a local venv for `hf` |
| 4. Cabling | Works out which port is cabled to which node (IPv6 all-nodes ping, so no IPv4 is needed yet), checks the shape (1 cable / triangle), checks IPs and the RoCE v2 GID, pings every cable | offers to assign fabric IPs (NetworkManager connection or netplan, only on those ports) |
| 5. cluster.env | Picks the model directory (checks free space on every node) and writes the detected values into `cluster.env` | shows a diff, asks |
| 6. Image | Pulls the pinned image on every node and checks the GPU is visible inside it | offers `docker pull` |
| 7. Network test | `ib_write_bw` on every cable, then an NCCL all-reduce **inside the recipe's image with the recipe's NCCL settings** | no (runs a short-lived container) |
| 8. Model | `hf download` at the pinned revision on the head, `rsync` to the workers, then the recipe's prepare commands | asks first |

- `--check` changes nothing and downloads nothing (the network test still runs, in short-lived containers). It
  uses the nodes in `cluster.env` if there is one, and writes `.setup/report.txt`, which is what to attach to an issue.
- `--nodes "spark1 spark2"` names the nodes (head first) instead of asking; `--yes` accepts every default;
  `--skip-download` and `--skip-net-test` skip those steps. You can re-run setup at any time.

## How we know it works

- **Every push** runs the hardware-free tests in CI ([tests/](tests/), `bash tests/run.sh`): the cabling logic on
  synthetic 2- and 3-node clusters (including a missing cable, a miswired triangle, a missing RoCE v2 GID and IPv6
  turned off), `new-recipe.sh` for every TP range (no leftover placeholders or markers, every link resolves, `DRY_RUN`
  prints the right commands), `cluster.env` precedence, the benchmark's model check, and shellcheck.
- **On real hardware** (three DGX Sparks, DGX OS 7, one cable and a triangle): a brand-new account with no docker
  group, no SSH key, no Hugging Face CLI and a cable with no IP addresses. `setup.sh` added the docker group,
  installed `hf`, found the cable and assigned its IPs, then measured RDMA at 111.6 Gb/s and NCCL at 11.9 GB/s; the
  Gemma recipe then served TP2 and passed its smoke test. `--check` is also exercised on 1, 2 and 3 nodes.
- **Not tested yet:** other DGX OS releases, machines without NetworkManager (the netplan path), a switch instead of
  direct cables, more than three nodes, and a first model download on a new account (a gated model needs
  `hf auth login`). If you try one of these, please open an issue with your `.setup/report.txt`, whether it
  worked or not.

## Files

| File | Purpose |
|---|---|
| `setup.sh` | the entry point (a recipe's `./setup.sh` just runs `kit/setup.sh`) |
| `lib/probe.py` | per-node facts as JSON, stdlib only, read-only |
| `lib/topology.py` | probes → cables, validation, IP plan, `cluster.env` values |
| `lib/nccl.sh` | NCCL network profiles `pair` (1 cable) and `triangle` (3 cables). Recipes source this, so the setup test and the real run use identical settings |
| `lib/nccl_check.py` | torch.distributed all-reduce with a correctness check and bus bandwidth (sent inside the `docker run` command, so nothing has to be on the workers) |
| `lib/netconfig.sh` | persistent static IP on one CX7 port |
| `lib/recipe.py` | reads `recipe.yaml` for setup |
| `lib/new_recipe.py` | the generator behind `new-recipe.sh` |
| `lib/cluster_env.sh` | `load_cluster_env`: a recipe loads `cluster.env` with it, so a value set in the environment wins for one run (`PORT=8001 ./run.sh tp1`) |
| `bench/` | the shared benchmark (`bench.sh` + its Python helpers) and smoke test. A recipe's `bench/bench.sh` and `scripts/smoke-test.sh` just run these, so every recipe is measured the same way. `bench.sh` refuses to file results under a recipe unless the server is serving that recipe's model; `BENCH_OUT=<dir>` benches anything else |
| `new-recipe.sh` | creates a new recipe repo from `template/` (below) |
| `template/` | the complete starting layout of a recipe repo, with `{{...}}` placeholders that `new-recipe.sh` fills in |
| `tests/` | hardware-free tests, run by CI on every push: `bash tests/run.sh` |

## Starting a new recipe

```bash
git clone https://github.com/BHCC2025/dgx-spark-recipe-kit.git
dgx-spark-recipe-kit/new-recipe.sh --model Gemma-4-31B-IT --hf nvidia/Gemma-4-31B-IT-NVFP4 --tp 1-2
```

That creates `Gemma-4-31B-IT-DGX-Spark-TP1-TP2/` with the full layout below, only the TP sizes you asked for, and
working launchers for them (TP1 on one Spark, TP2 over one cable, TP3 over a triangle). It prints the git commands
that add the kit as a subtree, and every `TODO` left: the model's vLLM flags in `lib/common.sh`, the revision and
image digest in `recipe.yaml`, and the README text. Checked against the published recipes: generated with
`--slug gemma4-31b --served gemma-4-31b-it` and Gemma-4-31B-IT's model flags filled in, the template's TP1 and TP2
launchers pass `docker run` exactly the same arguments as that recipe (draft model off; only their order differs),
and its TP3 uses exactly the same network wiring as the Qwen3.8-Flash-Next TP3.

## Recipe repo standard

Every recipe repo looks like this:

```
<Model>-DGX-Spark-TP<min>-TP<max>/     name always carries the TP range (search); -TP<n> for a single size
  README.md            sections, in order: quick-glance table · requirements · quick start (setup.sh, per node count)
                       · settings · how it works · benchmarks · troubleshooting · credits · license
  recipe.yaml          metadata + the `setup:` block the kit reads (template/recipe.yaml)
  cluster.env.example  every key the recipe reads; setup.sh fills in the detected ones
  setup.sh             exec kit/setup.sh "$@"
  run.sh               tpN | stop | status | logs; DRY_RUN=1 prints the docker commands
  lib/common.sh        shared launcher pieces; sources kit/lib/nccl.sh for the network
  recipes/tpN.sh       one launcher per TP size
  patches/<name>/      each with PROVENANCE.md (source, commit, author, what changed, sha256)
  scripts/             smoke-test.sh (runs the kit's) + recipe-specific helpers (prepare steps)
  .github/             issue template asking for the setup report
  bench/               bench.sh (runs the kit's) + results/<date>-<tp>.md and raw logs
  docs/                networking, troubleshooting, and one page per notable feature (padding, draft model, ...)
  kit/                 this repo (git subtree)
  LICENSE NOTICE CHANGELOG.md
```

Rules:
- **Every TP size a recipe ships gets benched on our own Sparks** with `bench/bench.sh` before `recipe.yaml` marks
  it `verified: true`. Numbers taken from upstream are labelled as upstream figures until then.
- Pin the image (tag and digest) and the model revision.
- Credit upstream work in NOTICE and PROVENANCE.md. Don't copy code across incompatible licences.
- No hardcoded hostnames, IPs or home paths anywhere outside `cluster.env`.
- Publish private first; flip to public after review.

## Updating the kit inside a recipe repo

Recipes vendor a tagged release, never `main`:

```bash
git subtree pull --prefix kit https://github.com/BHCC2025/dgx-spark-recipe-kit.git vX.Y.Z --squash
```

## License

Apache-2.0.
