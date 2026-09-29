#!/usr/bin/env bash
# scripts/get-draft-model.sh — fetch the speculative-decoding draft model (~1 GB) to DRAFT_DIR on the head and
# copy it to every other node in NODES. Run by ./setup.sh after the target model is in place; safe to re-run.
# The draft repo is gated like the target: accept Google's Gemma licence on Hugging Face and `hf auth login` first.
set -euo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$REPO_DIR/kit/lib/cluster_env.sh"; load_cluster_env "$REPO_DIR/cluster.env"
DRAFT_REPO=google/gemma-4-31B-it-assistant
DRAFT_REV=627c5ec1458b9086b841a91e0512fd31fd2fbbf1
DRAFT_DIR="${DRAFT_DIR:-/var/tmp/models/gemma-4-31B-it-assistant}"

HF_BIN=$(command -v hf || true); [ -x "$REPO_DIR/.setup/venv/bin/hf" ] && HF_BIN="$REPO_DIR/.setup/venv/bin/hf"
if [ -f "$DRAFT_DIR/config.json" ] && [ -f "$DRAFT_DIR/model.safetensors" ]; then
  echo "draft model present at $DRAFT_DIR"
else
  [ -n "$HF_BIN" ] || { echo "no hf CLI — run ./setup.sh first" >&2; exit 2; }
  mkdir -p "$DRAFT_DIR"
  "$HF_BIN" download "$DRAFT_REPO" --revision "$DRAFT_REV" --local-dir "$DRAFT_DIR" \
    || { echo "download failed (gated model? accept the licence on huggingface.co/$DRAFT_REPO, then: $HF_BIN auth login)" >&2; exit 1; }
fi

for h in "${NODES[@]:1}"; do
  ssh -n -o BatchMode=yes "$h" "mkdir -p $(printf %q "$DRAFT_DIR")"
  rsync -a --exclude .cache/ "$DRAFT_DIR/" "$h:$DRAFT_DIR/" || { echo "copying the draft model to $h failed" >&2; exit 1; }
  echo "draft model copied to $h"
done
