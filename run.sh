#!/usr/bin/env bash
# run.sh — start/stop Gemma-4-31B-IT on 1 or 2 DGX Sparks. Run it on the head node (NODES[0] in cluster.env).
#
#   ./run.sh tp1        one Spark
#   ./run.sh tp2        two Sparks, one QSFP cable
#   ./run.sh stop       stop the container on every node in NODES
#   ./run.sh status     container state on every node + /v1/models
#   ./run.sh logs       follow the head's server log
#
# Any knob in the recipe headers can be set in the environment, e.g.  DRAFT_TOKENS=4 SEQS=8 ./run.sh tp2
# DRY_RUN=1 prints the docker commands without running anything.
set -euo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export REPO_DIR
source "$REPO_DIR/lib/common.sh"

cmd="${1:-}"
case "$cmd" in
  tp1)
    bash "$REPO_DIR/recipes/tp1.sh" ;;
  tp2)
    [ "${#NODES[@]}" -ge 2 ] || { echo "tp2 needs 2 NODES in cluster.env" >&2; exit 2; }
    if [ "${DRY_RUN:-0}" = 1 ]; then echo "# rank 1 on ${NODES[1]}:"; bash "$REPO_DIR/recipes/tp2.sh" 1
    else start_remote_rank "${NODES[1]}" 1 recipes/tp2.sh; sleep 5; fi
    echo "== rank 0 on $(hostname)"; bash "$REPO_DIR/recipes/tp2.sh" 0 ;;
  stop)
    stop_on "${NODES[@]:1}"; docker rm -f "$NAME" >/dev/null 2>&1 || true
    echo "stopped $NAME on ${NODES[*]}" ;;
  status)
    for i in "${!NODES[@]}"; do
      h=${NODES[$i]}; printf '%-10s ' "$h"
      q="docker ps -a --filter name=^${NAME}\$ --format '{{.Status}}'"
      if [ "$i" = 0 ]; then bash -c "$q"; else ssh -n -o BatchMode=yes -o ConnectTimeout=5 "$h" "$q" 2>/dev/null; fi | grep . || echo "-"
    done
    curl -sf "http://127.0.0.1:$PORT/v1/models" | python3 -c 'import json,sys; print("serving:", [m["id"] for m in json.load(sys.stdin)["data"]])' \
      || echo "API on :$PORT not answering (yet) — loading takes a few minutes; ./run.sh logs" ;;
  logs)
    docker logs -f --tail 100 "$NAME" ;;
  *)
    sed -n '2,12p' "$0"; exit 2 ;;
esac
