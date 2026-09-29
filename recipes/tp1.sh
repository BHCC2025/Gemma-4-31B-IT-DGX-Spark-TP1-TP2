#!/usr/bin/env bash
# recipes/tp1.sh — Gemma-4-31B-IT NVFP4 on ONE DGX Spark. Normally started via ./run.sh tp1.
#
# The whole ~31 GB checkpoint fits on one GB10 with plenty of room for KV cache. FP8 KV, prefix caching,
# 262K context, draft-model speculative decoding (SPEC=draft, DRAFT_TOKENS per step).
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

GMU="${GMU:-0.80}"; MAXLEN="${MAXLEN:-262144}"; SEQS="${SEQS:-16}"
CHUNK="${CHUNK-8192}"
build_all

check_model "$MODEL_DIR"
[ "${SPEC:-draft}" != draft ] || check_model "$DRAFT_DIR"
run_container run --gpus all -d --name "$NAME" --restart no \
  --network host --ipc host --shm-size 32g --ulimit memlock=-1:-1 --cap-add IPC_LOCK --ulimit nofile=1048576:1048576 \
  -v "$MODEL_DIR:/models/gemma4-31b:ro" -v "$CACHE_DIR:/root/.cache" "${SPEC_MOUNT[@]}" \
  "${BASE_ENV[@]}" ${DOCKER_EXTRA:-} \
  "$IMAGE" \
    /models/gemma4-31b "${NAME_ARGS[@]}" "${SERVE_ARGS[@]}" --tensor-parallel-size 1 \
    "${SPEC_ARGS[@]}" "${GRAPH_ARGS[@]}" ${EXTRA:-}
echo "launched $NAME tp=1 spec=${SPEC:-draft}/${DRAFT_TOKENS:-4} kv=${KV_DTYPE:-fp8} gmu=$GMU maxlen=$MAXLEN seqs=$SEQS"
