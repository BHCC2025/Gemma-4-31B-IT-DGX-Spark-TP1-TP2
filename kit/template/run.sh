#!/usr/bin/env bash
# run.sh — start/stop {{MODEL}} on DGX Sparks. Run it on the head node (NODES[0] in cluster.env).
#
#   ./run.sh tpN        N Sparks (the sizes this recipe ships are the recipes/tpN.sh files)
#   ./run.sh stop       stop the container on every node in NODES
#   ./run.sh status     container state on every node + /v1/models
#   ./run.sh logs       follow the head's server log
#
# Any knob in the recipe headers can be set in the environment for one run, e.g.  SEQS=8 ./run.sh tp2
# (that includes cluster.env keys: PORT=8001 ./run.sh tp1). DRY_RUN=1 prints the docker commands.
set -euo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export REPO_DIR
source "$REPO_DIR/lib/common.sh"

cmd="${1:-}"
case "$cmd" in
  tp[0-9])
    n=${cmd#tp}; script="recipes/$cmd.sh"
    [ -f "$REPO_DIR/$script" ] || { echo "this recipe has no $cmd (sizes: $(ls "$REPO_DIR"/recipes | sed 's/\.sh$//' | xargs))" >&2; exit 2; }
    if [ "$n" = 1 ]; then bash "$REPO_DIR/$script"; exit; fi
    [ "${#NODES[@]}" -ge "$n" ] || { echo "$cmd needs $n NODES in cluster.env" >&2; exit 2; }
    for ((r = 1; r < n; r++)); do
      if [ "${DRY_RUN:-0}" = 1 ]; then echo "# rank $r on ${NODES[$r]}:"; bash "$REPO_DIR/$script" "$r"
      else start_remote_rank "${NODES[$r]}" "$r" "$script"; fi
    done
    [ "${DRY_RUN:-0}" = 1 ] || sleep 5
    echo "== rank 0 on $(hostname)"; bash "$REPO_DIR/$script" 0 ;;
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
    sed -n '2,10p' "$0"; exit 2 ;;
esac
