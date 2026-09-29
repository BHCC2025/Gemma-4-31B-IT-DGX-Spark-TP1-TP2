#!/usr/bin/env bash
# new-recipe.sh — start a new recipe repo from the kit's template, laid out like every other BHCC2025 recipe.
#
#   kit/new-recipe.sh --model Gemma-4-31B-IT --hf nvidia/Gemma-4-31B-IT-NVFP4 --tp 1-2
#       [--image vllm/vllm-openai:v0.29.0] [--served NAME] [--slug NAME] [--out DIR]
#
# Creates ./<Model>-DGX-Spark-TP<min>-TP<max>/ (-TP<n> for a single size) with README, recipe.yaml,
# cluster.env.example, run.sh, lib/common.sh, recipes/tpN.sh, bench/ and scripts/ wrappers for the kit's shared bench
# and smoke test, docs/, NOTICE, CHANGELOG, LICENSE. Then prints the git commands to add the kit and every TODO left
# to fill in. Never overwrites anything.
exec python3 "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/new_recipe.py" "$@"
