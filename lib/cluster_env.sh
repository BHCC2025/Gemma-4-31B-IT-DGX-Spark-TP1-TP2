# shellcheck shell=bash
# kit/lib/cluster_env.sh — sourced by a recipe's lib/common.sh.
#
#   load_cluster_env FILE
#
# Sources the recipe's cluster.env, but a plain VAR=value that is already set in the environment wins, so a one-off
# override works for every key, e.g. `PORT=8001 ./run.sh tp1` or `SERVED_NAMES="a b" ./run.sh tp2`. Without this,
# cluster.env would silently overwrite the value. Arrays (NODES=(...), LAN_IPS=(...)) always come from the file,
# since the environment can't hold arrays.
load_cluster_env() {
  local _f=$1 _k _kv _keep=()
  while IFS= read -r _k; do
    [ -n "${!_k+x}" ] && _keep+=("$_k=$(printf %q "${!_k}")")
  done < <(sed -nE 's/^([A-Za-z_][A-Za-z0-9_]*)=([^(].*)?$/\1/p' "$_f")
  # shellcheck disable=SC1090
  source "$_f"
  for _kv in ${_keep[@]+"${_keep[@]}"}; do eval "$_kv"; done
}
