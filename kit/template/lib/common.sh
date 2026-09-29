# shellcheck shell=bash disable=SC2034  # the arrays built here are used by recipes/tpN.sh
# lib/common.sh — shared by recipes/tpN.sh. Sourced, not run.
# Builds the bash arrays each launcher splices into `docker run`. Every knob is an env var with a per-TP default
# that the launcher sets before calling build_all.

REPO_DIR="${REPO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
[ -f "$REPO_DIR/cluster.env" ] \
  || { echo "no $REPO_DIR/cluster.env — run ./setup.sh (or cp cluster.env.example cluster.env and edit it)" >&2; exit 2; }
# cluster.env, with anything already set in the environment taking precedence (PORT=8001 ./run.sh tp1)
# shellcheck disable=SC1091
source "$REPO_DIR/kit/lib/cluster_env.sh"; load_cluster_env "$REPO_DIR/cluster.env"
# NCCL network profiles (pair / triangle) live in the shared kit so ./setup.sh tests exactly these settings.
# shellcheck disable=SC1091
source "$REPO_DIR/kit/lib/nccl.sh"

IMAGE="${IMAGE:-{{IMAGE}}}"
NAME="${NAME:-${CONTAINER_NAME:-{{CONTAINER}}}}"
PORT="${PORT:-8000}"
SERVED_NAMES="${SERVED_NAMES:-{{SERVED}}}"
CACHE_DIR="${CACHE_DIR:-/var/tmp/{{SLUG}}-vllm-cache}"

# Variables forwarded from the head to the workers so every rank runs the same config.
FORWARD_VARS=(IMAGE NAME GMU MAXLEN SEQS CHUNK KV_DTYPE GRAPHS PREFIX_CACHE PORT MPORT MODEL_DIR CACHE_DIR
              IB_GID_INDEX IB_GID_INDEX_TP2 NCCL_DEBUG NCCL_CHANNELS EXTRA DOCKER_EXTRA)
forward_env() {
  local v out=""
  for v in "${FORWARD_VARS[@]}"; do [ -n "${!v+x}" ] && out+="$v=$(printf %q "${!v}") "; done
  printf '%s' "$out"
}

# Start rank N on a worker over SSH. The repo must exist at the same path there (./setup.sh copies it).
start_remote_rank() {  # host rank script
  local host=$1 rank=$2 script=$3
  echo "== rank $rank on $host"
  ssh -o BatchMode=yes "$host" "cd $(printf %q "$REPO_DIR") && $(forward_env) bash $(printf %q "$script") $rank" \
    || { echo "rank $rank on $host failed to start" >&2; exit 1; }
}

stop_on() {  # host...
  local h
  for h in "$@"; do ssh -n -o BatchMode=yes "$h" "docker rm -f $NAME" >/dev/null 2>&1 || true; done
}

# ==== model-specific ==================================================================================================
# TODO: the vLLM flags this model needs, e.g. --quantization modelopt, --trust-remote-code, the tool-call and reasoning
# parsers. Everything else (context, memory, batching, caching) is in SERVE_ARGS below.
MODEL_ARGS=(TODO)

# TODO (optional): speculative decoding, e.g.
#   SPEC_ARGS=(--speculative-config '{"method":"mtp","num_speculative_tokens":3}')
# plus SPEC_MOUNT=(-v "$DRAFT_DIR:/models/draft:ro") if it needs a separate draft model. Add any knob you use here
# (e.g. DRAFT_TOKENS) to FORWARD_VARS above.
build_spec() { SPEC_ARGS=(); SPEC_MOUNT=(); }
# ======================================================================================================================

build_misc() {
  GRAPH_ARGS=()
  case "${GRAPHS:-default}" in
    default) ;;
    eager)   GRAPH_ARGS=(--enforce-eager) ;;
    *) echo "GRAPHS must be default|eager" >&2; exit 2 ;;
  esac
  CHUNK_ARGS=(); [ -n "${CHUNK:-}" ] && CHUNK_ARGS=(--max-num-batched-tokens "$CHUNK")
  PREFIX_ARGS=(--enable-prefix-caching); [ "${PREFIX_CACHE:-1}" = 0 ] && PREFIX_ARGS=(--no-enable-prefix-caching)
  LONGCTX_ENV=(); [ "$MAXLEN" -gt 262144 ] && LONGCTX_ENV=(-e VLLM_ALLOW_LONG_MAX_MODEL_LEN=1)
  # shellcheck disable=SC2206
  NAME_ARGS=(--served-model-name $SERVED_NAMES)
  # Standard GB10 (sm_121) vLLM environment. DeepGEMM faults on sm_121.
  BASE_ENV=(-e HF_HUB_OFFLINE=1 -e TRANSFORMERS_OFFLINE=1 -e VLLM_ENGINE_READY_TIMEOUT_S=3600
            -e PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True -e CUTE_DSL_ARCH=sm_121a
            -e TORCH_CUDA_ARCH_LIST=12.1a -e FLASHINFER_CUDA_ARCH_LIST=12.1a -e FLASHINFER_DISABLE_VERSION_CHECK=1
            -e VLLM_USE_DEEP_GEMM=0 "${LONGCTX_ENV[@]}")
  SERVE_ARGS=(--host 0.0.0.0 --port "$PORT" --kv-cache-dtype "${KV_DTYPE:-fp8}"
              --max-model-len "$MAXLEN" --max-num-seqs "$SEQS" --gpu-memory-utilization "$GMU" "${CHUNK_ARGS[@]}"
              --enable-chunked-prefill "${PREFIX_ARGS[@]}" "${MODEL_ARGS[@]}")
}

build_all() { build_spec; build_misc; }

check_model() {  # dir — DRY_RUN=1 only notes a missing model, so the commands can be printed before any download
  [ -f "$1/config.json" ] && return 0
  if [ "${DRY_RUN:-0}" = 1 ]; then echo "# note: no model at $1 on $(hostname) yet — ./setup.sh downloads it" >&2; return 0; fi
  echo "MODEL MISSING at $1 on $(hostname) — run ./setup.sh" >&2; exit 3
}

# DRY_RUN=1 prints the docker command instead of running it.
run_container() {
  if [ "${DRY_RUN:-0}" = 1 ]; then
    printf 'docker'; printf ' %q' "$@"; printf '\n'; return 0
  fi
  mkdir -p "$CACHE_DIR"
  docker rm -f "$NAME" >/dev/null 2>&1 || true
  # Free page cache first: on a unified-memory box it counts against what the GPU can allocate.
  sync; echo 3 | sudo -n tee /proc/sys/vm/drop_caches >/dev/null 2>&1 || true
  docker "$@" >/dev/null
  sleep 3
  docker ps --format '{{.Names}} {{.Status}}' | grep "^$NAME " || { echo "$NAME exited"; docker logs "$NAME" 2>&1 | tail -20; exit 1; }
}
