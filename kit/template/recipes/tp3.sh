#!/usr/bin/env bash
# recipes/tp3.sh — {{MODEL}} across THREE DGX Sparks (TP3), vLLM mp backend.
# Normally started via ./run.sh tp3 (workers rank 1 and 2 first, then the head, rank 0, which serves the API).
#   recipes/tp3.sh 0|1|2    run one rank on the current node
#
# Network (docs/networking.md): bootstrap over the LAN, data over both CX7 ports of each node, which in a triangle
# each reach ONE neighbour (kit triangle profile).
# TP=3 only works if the model's attention heads, KV heads and MLP/expert widths all divide by 3. Check config.json
# before shipping this; if they don't, the model needs load-time padding (see the Qwen3.8-Flash-Next recipe) or
# the recipe stops at TP2.
# TODO: one paragraph — why these settings.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
RANK="${1:?rank 0, 1 or 2}"

GMU="${GMU:-0.75}"; MAXLEN="${MAXLEN:-262144}"; SEQS="${SEQS:-16}"
CHUNK="${CHUNK-8192}"
MPORT="${MPORT:-29533}"
build_all

case "$RANK" in
  0) HEADLESS=() ;;
  1|2) HEADLESS=(--headless) ;;
  *) echo "rank must be 0, 1 or 2" >&2; exit 2 ;;
esac
HOST_IP="${LAN_IPS[$RANK]}"; HEAD_IP="${LAN_IPS[0]}"
nccl_env_triangle "$RANK"                     # kit/lib/nccl.sh: LAN bootstrap, both CX7 ports, no NIC merging

check_model "$MODEL_DIR"
run_container run --gpus all -d --name "$NAME" --restart no \
  --network host --ipc host --shm-size 32g --ulimit memlock=-1:-1 --cap-add IPC_LOCK --ulimit nofile=1048576:1048576 \
  --device /dev/infiniband:/dev/infiniband \
  -v "$MODEL_DIR:/models/{{SLUG}}:ro" -v "$CACHE_DIR:/root/.cache" "${SPEC_MOUNT[@]}" \
  -e VLLM_HOST_IP="$HOST_IP" "${BASE_ENV[@]}" "${NCCL_ENV[@]}" ${DOCKER_EXTRA:-} \
  "$IMAGE" \
    /models/{{SLUG}} "${NAME_ARGS[@]}" "${SERVE_ARGS[@]}" --tensor-parallel-size 3 \
    "${SPEC_ARGS[@]}" "${GRAPH_ARGS[@]}" \
    --distributed-executor-backend mp --nnodes 3 --node-rank "$RANK" \
    --master-addr "$HEAD_IP" --master-port "$MPORT" "${HEADLESS[@]}" ${EXTRA:-}
[ "${DRY_RUN:-0}" = 1 ] || echo "launched $NAME rank=$RANK host=$HOST_IP tp=3 kv=${KV_DTYPE:-fp8} gmu=$GMU maxlen=$MAXLEN"
