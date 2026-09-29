#!/usr/bin/env python3
"""new_recipe.py — create a new recipe repo from kit/template/. Run via kit/new-recipe.sh (see --help there)."""
import argparse, datetime, os, re, shutil, sys

KIT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TEMPLATE = os.path.join(KIT, "template")
DEFAULT_IMAGE = "vllm/vllm-openai:v0.29.0"
GMU = {1: "0.80", 2: "0.75", 3: "0.75"}
CABLING = {2: "one QSFP cable", 3: "QSFP triangle"}
QUICK = {1: "# 1 Spark", 2: "# 2 Sparks, one QSFP cable between them",
         3: "# 3 Sparks, QSFP triangle (each Spark cabled to both others)"}


def parse_tp(s):
    m = re.fullmatch(r"([1-3])(?:-([1-3]))?", s)
    if not m:
        sys.exit("--tp must be N or MIN-MAX with sizes 1..3, e.g. 1-2")
    lo, hi = int(m.group(1)), int(m.group(2) or m.group(1))
    if hi < lo:
        sys.exit("--tp: MIN must not be larger than MAX")
    return list(range(lo, hi + 1))


def words(sizes):
    if len(sizes) == 1:
        return "one" if sizes[0] == 1 else f"{sizes[0]}"
    return ", ".join(map(str, sizes[:-1])) + f" or {sizes[-1]}"


def strip_blocks(text, maxtp):
    for n in (2, 3):
        pat = re.compile(rf"<!-- tp{n} -->\n(.*?)<!-- /tp{n} -->\n", re.S)
        text = pat.sub(lambda m: m.group(1) if maxtp >= n else "", text)
    return re.sub(r"\n{3,}", "\n\n", text)


def strip_env_sections(text, maxtp):
    for n in (2, 3):
        if maxtp < n:
            text = re.sub(rf"\n# ---- TP{n}:.*?(?=\n# ---- |\Z)", "\n", text, flags=re.S)
    return re.sub(r"\n{3,}", "\n\n", text).rstrip("\n") + "\n"


def main():
    ap = argparse.ArgumentParser(prog="kit/new-recipe.sh", description=__doc__)
    ap.add_argument("--model", required=True, help='display name used in the repo name, e.g. "Gemma-4-31B-IT"')
    ap.add_argument("--hf", required=True, help="Hugging Face repo of the checkpoint, e.g. nvidia/Gemma-4-31B-IT-NVFP4")
    ap.add_argument("--tp", required=True, help="TP sizes the recipe ships: N or MIN-MAX (1..3), e.g. 1-2")
    ap.add_argument("--image", default=DEFAULT_IMAGE, help=f"vLLM image (default {DEFAULT_IMAGE})")
    ap.add_argument("--served", help="served model name (default: the slug)")
    ap.add_argument("--slug", help="short lowercase name for paths and the container (default: from --model)")
    ap.add_argument("--out", help="output directory (default: ./<repo name>)")
    a = ap.parse_args()

    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", a.model):
        sys.exit("--model: letters, digits, '.', '_' and '-' only (it becomes the repo name)")
    if not re.fullmatch(r"[\w.-]+/[\w.-]+", a.hf):
        sys.exit("--hf must look like org/name")
    sizes = parse_tp(a.tp)
    lo, hi = sizes[0], sizes[-1]
    repo = f"{a.model}-DGX-Spark-TP{lo}-TP{hi}" if lo != hi else f"{a.model}-DGX-Spark-TP{lo}"
    slug = a.slug or re.sub(r"[^a-z0-9]+", "-", a.model.lower()).strip("-")
    if not re.fullmatch(r"[a-z0-9][a-z0-9-]*", slug):
        sys.exit("--slug: lowercase letters, digits and '-' only")
    out = os.path.abspath(a.out or repo)
    if os.path.exists(out) and os.listdir(out):
        sys.exit(f"{out} exists and is not empty — refusing to overwrite")
    version = open(os.path.join(KIT, "VERSION")).read().strip()

    k = len(sizes)
    tok = {
        "REPO": repo, "MODEL": a.model, "HF_REPO": a.hf, "IMAGE": a.image, "SERVED": a.served or slug, "SLUG": slug,
        "CONTAINER": "vllm_" + slug.replace("-", "_"), "MODEL_DIR": "/var/tmp/models/" + a.hf.split("/")[1],
        "YEAR": str(datetime.date.today().year), "TP_MIN": str(lo), "TP_MAX": str(hi),
        "TP_LIST": ", ".join(map(str, sizes)), "TP_CMDS": "|".join(f"tp{n}" for n in sizes),
        "TP_CMDS_COMMA": ", ".join(f"TP{n}" for n in sizes),
        "FIRST_RUN": ", ".join(f"{n}: ./run.sh tp{n}" for n in sizes),
        "SPARKS_WORDS": words(sizes), "SPARKS_NOUN": "Spark" if sizes == [1] else "Sparks", "EACH": "" if len(sizes) == 1 and sizes[0] == 1 else " each", "SPARKS_WORDS_CAP": f"{lo}–{hi}" if lo != hi else str(lo),
        "README_ROWS": "\n".join(f"| {n} | `./run.sh tp{n}` | 256K | – | – | not yet |" for n in sizes),
        "QUICKSTART_CMDS": "\n".join(f"./run.sh tp{n}        {QUICK[n]}" for n in sizes),
        "SETTINGS_HEAD": " | ".join(f"TP{n}" for n in sizes), "SETTINGS_SEP": "---|" * k,
        "SETTINGS_16": " | ".join(["16"] * k), "SETTINGS_MAXLEN": " | ".join(["262144"] * k),
        "SETTINGS_GMU": " | ".join(GMU[n] for n in sizes), "SETTINGS_CHUNK": " | ".join(["8192"] * k),
        "SETTINGS_KV": " | ".join(["fp8"] * k), "SETTINGS_PREFIX": " | ".join(["1"] * k),
        "SETTINGS_GRAPHS": " | ".join(["default"] * k), "SETTINGS_EMPTY": " | ".join([""] * k),
        "RECIPES": "\n".join(
            f"  - id: tp{n}\n    nodes: {n}\n" + (f"    cabling: {CABLING[n]}\n" if n in CABLING else "")
            + f"    command: ./run.sh tp{n}\n    max_model_len: 262144\n"
            f"    decode_tok_s: {{code: 0, prose: 0, source: bench/results/<date>-tp{n}.md}}\n"
            f"    prefill_cold_8k_tok_s: 0\n    verified: false" for n in sizes),
    }

    shutil.copytree(TEMPLATE, out, dirs_exist_ok=True)
    for n in (1, 2, 3):
        if n not in sizes:
            os.remove(os.path.join(out, "recipes", f"tp{n}.sh"))

    left = []
    for root, _, files in os.walk(out):
        for f in files:
            p = os.path.join(root, f)
            if f in ("LICENSE", ".gitkeep"):
                continue
            s = open(p).read()
            for key, val in tok.items():
                s = s.replace("{{" + key + "}}", val)
            if f.endswith(".md"):
                s = strip_blocks(s, hi)
            if f == "cluster.env.example":
                s = strip_env_sections(s, hi)
                s = re.sub(r"^NODES=\(.*\)$", "NODES=(" + " ".join(f"spark{i + 1}" for i in range(hi)) + ")", s,
                           count=1, flags=re.M)
            if f == "README.md":
                if lo == hi:
                    s = s.replace(f"(TP{lo}–TP{hi})", f"(TP{lo})", 1)
                cab = "| Cables |"
                line = next((l for l in s.splitlines() if l.startswith(cab)), None)
                if line and hi == 1:
                    s = s.replace(line + "\n", "")
                elif line and hi == 2:
                    s = s.replace(line, "| Cables | TP2: one QSFP cable (see [docs/networking.md](docs/networking.md)) |")
            open(p, "w").write(s)
            left += [f"{os.path.relpath(p, out)}: {t}" for t in re.findall(r"\{\{[A-Z_]+\}\}", s)]
    if left:
        sys.exit("unfilled placeholders (a kit bug, please report):\n  " + "\n  ".join(left))

    print(f"created {out}\n")
    print("Next:")
    print(f"  cd {out}")
    print('  git init -q -b main && git add -A && git commit -q -m "Scaffold from dgx-spark-recipe-kit"')
    print(f"  git subtree add --prefix kit https://github.com/BHCC2025/dgx-spark-recipe-kit.git v{version} --squash")
    print("  DRY_RUN=1 ./run.sh tp%d     # after cp cluster.env.example cluster.env (or ./setup.sh)" % lo)
    print("\nFill in every TODO (the model's vLLM flags are in lib/common.sh):")
    for root, _, files in sorted(os.walk(out)):
        for f in sorted(files):
            p = os.path.join(root, f)
            if f in ("LICENSE", ".gitkeep"):
                continue
            for i, l in enumerate(open(p).read().splitlines(), 1):
                if "TODO" in l:
                    print(f"  {os.path.relpath(p, out)}:{i}: {l.strip()[:100]}")


if __name__ == "__main__":
    main()
