#!/usr/bin/env bash
# recipes/tp2.sh — {{MODEL}} across TWO DGX Sparks (TP2) over one QSFP cable, vLLM mp backend.
# Normally started via ./run.sh tp2 (worker rank 1 first, then the head, rank 0, which serves the API).
#   recipes/tp2.sh 0|1    run one rank on the current node
#
# The network is NCCL over RoCE on the one cabled CX7 port of each node (cluster.env TP2_*, kit pair profile).
# TODO: one paragraph — why these settings. Lower GMU than TP1 if CUDA graph capture runs out of memory.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
RANK="${1:?rank 0 or 1}"

GMU="${GMU:-0.75}"; MAXLEN="${MAXLEN:-262144}"; SEQS="${SEQS:-16}"
CHUNK="${CHUNK-8192}"
MPORT="${MPORT:-29531}"
build_all

case "$RANK" in
  0) HOST_IP="$TP2_HEAD_IP";   HEADLESS=() ;;
  1) HOST_IP="$TP2_WORKER_IP"; HEADLESS=(--headless) ;;
  *) echo "rank must be 0 or 1" >&2; exit 2 ;;
esac
nccl_env_pair "$RANK"                         # kit/lib/nccl.sh: NCCL over RoCE on the one cabled port

check_model "$MODEL_DIR"
run_container run --gpus all -d --name "$NAME" --restart no \
  --network host --ipc host --shm-size 32g --ulimit memlock=-1:-1 --cap-add IPC_LOCK --ulimit nofile=1048576:1048576 \
  --device /dev/infiniband:/dev/infiniband \
  -v "$MODEL_DIR:/models/{{SLUG}}:ro" -v "$CACHE_DIR:/root/.cache" "${SPEC_MOUNT[@]}" \
  -e VLLM_HOST_IP="$HOST_IP" "${BASE_ENV[@]}" "${NCCL_ENV[@]}" ${DOCKER_EXTRA:-} \
  "$IMAGE" \
    /models/{{SLUG}} "${NAME_ARGS[@]}" "${SERVE_ARGS[@]}" --tensor-parallel-size 2 \
    "${SPEC_ARGS[@]}" "${GRAPH_ARGS[@]}" \
    --distributed-executor-backend mp --nnodes 2 --node-rank "$RANK" \
    --master-addr "$TP2_HEAD_IP" --master-port "$MPORT" "${HEADLESS[@]}" ${EXTRA:-}
[ "${DRY_RUN:-0}" = 1 ] || echo "launched $NAME rank=$RANK host=$HOST_IP tp=2 kv=${KV_DTYPE:-fp8} gmu=$GMU maxlen=$MAXLEN"
