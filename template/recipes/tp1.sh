#!/usr/bin/env bash
# recipes/tp1.sh — {{MODEL}} on ONE DGX Spark (TP1), vLLM. Normally started via ./run.sh tp1.
#
# TODO: one paragraph — why these settings (memory fit, context, speculative decoding, anything unusual).
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

GMU="${GMU:-0.80}"; MAXLEN="${MAXLEN:-262144}"; SEQS="${SEQS:-16}"
CHUNK="${CHUNK-8192}"                          # CHUNK= (set, empty) for vLLM's default
build_all

check_model "$MODEL_DIR"
run_container run --gpus all -d --name "$NAME" --restart no \
  --network host --ipc host --shm-size 32g --ulimit memlock=-1:-1 --cap-add IPC_LOCK --ulimit nofile=1048576:1048576 \
  -v "$MODEL_DIR:/models/{{SLUG}}:ro" -v "$CACHE_DIR:/root/.cache" "${SPEC_MOUNT[@]}" \
  "${BASE_ENV[@]}" ${DOCKER_EXTRA:-} \
  "$IMAGE" \
    /models/{{SLUG}} "${NAME_ARGS[@]}" "${SERVE_ARGS[@]}" --tensor-parallel-size 1 \
    "${SPEC_ARGS[@]}" "${GRAPH_ARGS[@]}" ${EXTRA:-}
[ "${DRY_RUN:-0}" = 1 ] || echo "launched $NAME tp=1 kv=${KV_DTYPE:-fp8} gmu=$GMU maxlen=$MAXLEN seqs=$SEQS"
