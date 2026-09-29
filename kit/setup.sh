#!/usr/bin/env bash
# setup.sh — get 1-3 DGX Sparks ready for this recipe: nodes and SSH, dependencies, cabling and fabric IPs,
# cluster.env, the Docker image, a real network test, then the model. Run it on the head node from the repo root.
#
#   ./setup.sh                  interactive; asks before every change
#   ./setup.sh --check          report only: change nothing, download nothing (paste this into a GitHub issue)
#   ./setup.sh --yes            accept every default (unattended)
#   ./setup.sh --nodes "spark1 spark2 spark3"     head first; skips the node questions
#   --skip-download  --skip-net-test
#
# Safe to re-run: every step checks what is already there first. Log and report go to .setup/.
set -uo pipefail
KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${REPO_DIR:-$(cd "$KIT_DIR/.." && pwd)}"
STATE="$REPO_DIR/.setup"; mkdir -p "$STATE"
CHECK=0; YES=0; NODES_ARG=""; SKIP_DL=0; SKIP_NET=0
while [ $# -gt 0 ]; do
  case "$1" in
    --check) CHECK=1 ;; --yes|-y) YES=1 ;; --nodes) NODES_ARG="$2"; shift ;;
    --skip-download) SKIP_DL=1 ;; --skip-net-test) SKIP_NET=1 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "unknown option $1 (--help)"; exit 2 ;;
  esac; shift
done
LOG="$STATE/setup-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG") 2>&1

# ---------------------------------------------------------------- ui
B=$'\033[1m'; G=$'\033[32m'; Y=$'\033[33m'; RD=$'\033[31m'; D=$'\033[2m'; N0=$'\033[0m'
FAILS=(); WARNS=(); REPORT=()
step() { printf '\n%s== %s%s\n' "$B" "$*" "$N0"; }
ok()   { printf '  %sok%s    %s\n' "$G" "$N0" "$*"; }
warn() { printf '  %swarn%s  %s\n' "$Y" "$N0" "$*"; WARNS+=("$*"); }
bad()  { printf '  %sFAIL%s  %s\n' "$RD" "$N0" "$*"; FAILS+=("$*"); }
info() { printf '        %s\n' "$*"; }
note() { REPORT+=("$*"); }
# ask_yn "question" [default y|n] — --yes takes the default, --check always answers no to changes
ask_yn() {
  local q=$1 def=${2:-y} a
  if [ "$CHECK" = 1 ]; then printf '  %s(check mode: would ask) %s%s\n' "$D" "$q" "$N0"; return 1; fi
  if [ "$YES" = 1 ]; then [ "$def" = y ]; return; fi
  read -r -p "  ? $q [$([ "$def" = y ] && echo Y/n || echo y/N)] " a </dev/tty
  a=${a:-$def}; [[ "$a" =~ ^[Yy] ]]
}
ask() {  # ask "question" default -> REPLY
  local q=$1 def=${2:-}
  if [ "$YES" = 1 ] || [ "$CHECK" = 1 ]; then REPLY=$def; return; fi
  read -r -p "  ? $q${def:+ [$def]} " REPLY </dev/tty; REPLY=${REPLY:-$def}
}
j() { python3 -c "import json,sys; d=json.load(open(sys.argv[1])); r=eval(sys.argv[2]); print(' '.join(map(str,r)) if isinstance(r,list) else r)" "$@"; }

# ---------------------------------------------------------------- run on node i (0 = this machine)
on()     { local i=$1; shift; if [ "$i" = 0 ]; then bash -c "$*"; else ssh -n -o BatchMode=yes -o ConnectTimeout=8 "${NODES[$i]}" "$*"; fi; }
on_tty() { local i=$1; shift; if [ "$i" = 0 ]; then bash -c "$*" </dev/tty; else ssh -t -o ConnectTimeout=8 "${NODES[$i]}" "$*" </dev/tty; fi; }
on_py()  { local i=$1 f=$2; shift 2
  if [ "$i" = 0 ]; then python3 "$f" "$@"; else ssh -o BatchMode=yes -o ConnectTimeout=8 "${NODES[$i]}" "python3 - $(printf '%q ' "$@")" < "$f"; fi; }
sync_repo() {
  local i
  for ((i = 1; i < ${#NODES[@]}; i++)); do
    on "$i" "mkdir -p $(printf %q "$REPO_DIR")" && rsync -a --delete --exclude .git/ --exclude .setup/ "$REPO_DIR/" "${NODES[$i]}:$REPO_DIR/" \
      || { bad "could not copy the repo to ${NODES[$i]}:$REPO_DIR"; return 1; }
  done
}

# ---------------------------------------------------------------- recipe
[ -f "$REPO_DIR/recipe.yaml" ] || { echo "no recipe.yaml in $REPO_DIR"; exit 2; }
eval "$(python3 "$KIT_DIR/lib/recipe.py" "$REPO_DIR/recipe.yaml")" || { echo "could not read recipe.yaml"; exit 2; }
printf '%s%s%s — setup%s\n' "$B" "$R_NAME" "$N0" "$([ "$CHECK" = 1 ] && echo ' (check only, no changes)')"
info "model $R_HF_REPO@${R_REVISION:0:8} · image $R_IMAGE · TP sizes: $R_TP"
info "log $LOG"
[ -f "$REPO_DIR/cluster.env" ] && source "$REPO_DIR/cluster.env"   # previous answers become defaults

# ---------------------------------------------------------------- 1. nodes and SSH
step "1. Nodes"
MAXN=$(tr ' ' '\n' <<< "$R_TP" | sort -n | tail -1)
if [ -n "$NODES_ARG" ]; then read -r -a NODES <<< "$NODES_ARG"
elif [ -n "${NODES+x}" ] && [ "${#NODES[@]}" -ge 1 ] && ask_yn "Use the nodes from cluster.env: ${NODES[*]}?" y; then :
else
  ask "How many DGX Sparks? ($R_TP)" 1; n=$REPLY
  [[ " $R_TP " == *" $n "* ]] || { bad "this recipe supports $R_TP Sparks, not '$n'"; exit 1; }
  NODES=("$(hostname -s)")
  for ((i = 1; i < n; i++)); do ask "SSH name or IP of Spark $((i + 1))" ""; NODES+=("$REPLY"); done
fi
N=${#NODES[@]}
[ "$N" -le "$MAXN" ] || { bad "$N nodes, but this recipe goes up to $MAXN"; exit 1; }
ok "head (this machine): $(hostname -s)   workers: ${NODES[*]:1}"
for ((i = 1; i < N; i++)); do
  h=${NODES[$i]}
  if ssh -n -o BatchMode=yes -o ConnectTimeout=8 "$h" true 2>/dev/null; then ok "passwordless SSH to $h"; continue; fi
  bad "no passwordless SSH to $h"
  if ask_yn "Set up SSH key login to $h now (asks for $h's password once)?" y; then
    [ -f ~/.ssh/id_ed25519 ] || ssh-keygen -q -t ed25519 -N "" -f ~/.ssh/id_ed25519
    ssh-copy-id -i ~/.ssh/id_ed25519.pub "$h" </dev/tty && ssh -n -o BatchMode=yes "$h" true && { ok "SSH to $h works now"; FAILS=("${FAILS[@]:0:${#FAILS[@]}-1}"); }
  fi
done
[ "${#FAILS[@]}" = 0 ] || { echo; echo "Fix SSH first (ssh-copy-id <host>), then re-run."; exit 1; }
if [ "$CHECK" = 0 ] && [ "$N" -gt 1 ]; then sync_repo && ok "repo copied to the workers at $REPO_DIR"; fi

# ---------------------------------------------------------------- 2. probe
probe_all() {
  local i nb=(); [ "$N" = 1 ] && nb=(--no-neighbors)
  for ((i = 0; i < N; i++)); do
    on_py "$i" "$KIT_DIR/lib/probe.py" --image "$R_IMAGE" --model-dir "$MODEL_DIR" "${nb[@]}" > "$STATE/probe-$i.json" \
      || { bad "probe failed on ${NODES[$i]}"; return 1; }
  done
}
MODEL_DIR="${MODEL_DIR:-$R_MODEL_DIR}"
step "2. Inspecting each Spark"
probe_all || exit 1
for ((i = 0; i < N; i++)); do
  P="$STATE/probe-$i.json"
  info "${NODES[$i]}: $(j "$P" 'd["dgx"] or d["os"]') · $(j "$P" 'd["gpu"] or "no GPU"') · $(j "$P" 'd["mem_total_gib"]') GiB · $(j "$P" 'd["arch"]')"
done

# ---------------------------------------------------------------- 3. dependencies
step "3. Dependencies"
for ((i = 0; i < N; i++)); do
  P="$STATE/probe-$i.json"; h=${NODES[$i]}; pkgs=()
  [[ "$(j "$P" 'd["gpu"]')" == *GB10* ]] && ok "$h: GB10 GPU" || warn "$h: GPU is '$(j "$P" 'd["gpu"]')' — recipes are tested on GB10 only"
  if [ -z "$(j "$P" 'd["tools"]["docker"]')" ]; then
    bad "$h: Docker not installed — DGX OS ships Docker and the NVIDIA Container Toolkit; reinstall them from NVIDIA's DGX Spark docs"
  elif [ "$(j "$P" 'd["docker_ok"]')" = True ]; then ok "$h: Docker usable without sudo"
  else
    bad "$h: Docker needs sudo for $(j "$P" 'd["user"]')"
    if ask_yn "Add $(j "$P" 'd["user"]') to the docker group on $h?" y; then
      on_tty "$i" "sudo usermod -aG docker \$USER" && warn "$h: log out and back in (or reboot) for the docker group to apply, then re-run setup"
    fi
  fi
  [ -n "$(j "$P" 'd["tools"]["rsync"]')" ] && ok "$h: rsync" || pkgs+=(rsync)
  if [ "$N" -gt 1 ]; then [ -n "$(j "$P" 'd["tools"]["ib_write_bw"]')" ] && ok "$h: perftest (ib_write_bw)" || pkgs+=(perftest); fi
  if [ "$i" = 0 ] && [ -z "$(j "$P" 'd["tools"]["hf"]')" ] && [ "$(j "$P" 'd["python_venv"]')" != True ]; then pkgs+=(python3-venv); fi
  if [ "${#pkgs[@]}" -gt 0 ]; then
    bad "$h: missing ${pkgs[*]}"
    if ask_yn "apt install ${pkgs[*]} on $h (sudo)?" y; then
      on_tty "$i" "sudo apt-get update -qq && sudo apt-get install -y -qq ${pkgs[*]}" && ok "$h: installed ${pkgs[*]}" && FAILS=("${FAILS[@]:0:${#FAILS[@]}-1}")
    fi
  fi
done
HF_BIN=$(j "$STATE/probe-0.json" 'd["tools"]["hf"]')
if [ -z "$HF_BIN" ] && [ -x "$STATE/venv/bin/hf" ]; then HF_BIN="$STATE/venv/bin/hf"; fi
if [ -n "$HF_BIN" ]; then ok "head: Hugging Face CLI ($HF_BIN)"
elif ask_yn "Install the Hugging Face CLI into $STATE/venv (no system changes)?" y; then
  python3 -m venv "$STATE/venv" && "$STATE/venv/bin/pip" install -q -U huggingface_hub && HF_BIN="$STATE/venv/bin/hf" && ok "hf CLI installed: $HF_BIN" \
    || bad "could not install the hf CLI"
else warn "no hf CLI — the model download step will be skipped"; fi

# ---------------------------------------------------------------- 4. network
declare -A ENVSET=()
ENVSET[NODES]="($(printf '%q ' "${NODES[@]}"))"
if [ "$N" -gt 1 ]; then
  step "4. Cabling and fabric IPs"
  topo() { python3 "$KIT_DIR/lib/topology.py" $(for ((i = 0; i < N; i++)); do printf '%s=%s ' "${NODES[$i]}" "$STATE/probe-$i.json"; done) > "$STATE/topology.json"; }
  topo
  python3 - "$STATE/topology.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
for l in d["links"]:
    a, b = l["a"], l["b"]
    print(f"        cable  {a['node']}:{a['netdev']} ({a['hca']}, {a['ip']})  <->  {b['node']}:{b['netdev']} ({b['hca']}, {b['ip']})   {a['rate']}")
PY
  mapfile -t terr < <(python3 -c "import json; [print(e) for e in json.load(open('$STATE/topology.json'))['errors']]")
  for e in "${terr[@]}"; do bad "$e"; done
  while IFS= read -r w; do [ -n "$w" ] && warn "$w"; done < <(python3 -c "import json; [print(w) for w in json.load(open('$STATE/topology.json'))['warnings']]")
  nassign=$(j "$STATE/topology.json" 'len(d["assign"])')
  if [ "$nassign" -gt 0 ]; then
    warn "$nassign fabric port(s) need an IPv4 address:"
    python3 -c "import json; [print(f\"          {a['node']}: {a['netdev']} -> {a['cidr']}\") for a in json.load(open('$STATE/topology.json'))['assign']]"
    info "applied as a NetworkManager connection 'spark-fabric-<if>' (or a netplan file), MTU 9000, only on these ports"
    if ask_yn "Configure these addresses now (sudo on each listed node)?" y; then
      while IFS=$'\t' read -r idx ifc cidr; do
        on_tty "$idx" "bash $(printf %q "$REPO_DIR/kit/lib/netconfig.sh") $ifc $cidr" || bad "${NODES[$idx]}: could not set $ifc"
      done < <(python3 -c "import json; [print(a['index'], a['netdev'], a['cidr'], sep='\t') for a in json.load(open('$STATE/topology.json'))['assign']]")
      sleep 5; probe_all && topo
      [ "$(j "$STATE/topology.json" 'len(d["assign"])')" = 0 ] && ok "fabric IPs configured" || bad "some fabric ports still have no IPv4"
    fi
  elif [ "${#terr[@]}" = 0 ]; then ok "every cable has IPv4 on both ends"
  fi
  # link pings
  while IFS=$'\t' read -r ia ifa ipb nb; do
    on "$ia" "ping -c 2 -W 2 -I $ifa ${ipb%/*} >/dev/null 2>&1" && ok "ping ${NODES[$ia]} -> $nb ${ipb%/*} over $ifa" || bad "ping ${NODES[$ia]} -> $nb ${ipb%/*} over $ifa failed"
  done < <(python3 -c "import json; [print(l['pair'][0], l['a']['netdev'], l['b']['ip'], l['b']['node'], sep='\t') for l in json.load(open('$STATE/topology.json'))['links']]")
  while IFS=$'\t' read -r k v; do ENVSET[$k]=$v; done < <(python3 -c "
import json, shlex
for k, v in json.load(open('$STATE/topology.json'))['env'].items():
    print(k, '(' + ' '.join(shlex.quote(str(x)) for x in v) + ')' if isinstance(v, list) else shlex.quote(str(v)), sep='\t')")
else
  step "4. Network"; ok "single Spark — no fabric needed"
  ENVSET[LAN_IF]=$(j "$STATE/probe-0.json" 'd["lan_if"]')
fi

# ---------------------------------------------------------------- 5. model location + cluster.env
step "5. Model location and cluster.env"
need=$R_DISK_GB
for ((i = 0; i < N; i++)); do
  st=$(j "$STATE/probe-$i.json" 'd["model_state"]'); free=$(j "$STATE/probe-$i.json" 'd["disk_free_gb"]')
  if [ "$st" = complete ]; then ok "${NODES[$i]}: model already at $MODEL_DIR"
  elif [ "$free" -ge "$need" ]; then ok "${NODES[$i]}: ${free} GB free for $MODEL_DIR (needs ~$need)"
  else bad "${NODES[$i]}: only ${free} GB free at $(j "$STATE/probe-$i.json" 'd["disk_path"]'), needs ~$need GB"; lowdisk=1; fi
done
if [ "${lowdisk:-0}" = 1 ] || { [ "$CHECK" = 0 ] && [ "$YES" = 0 ] && [ "$(j "$STATE/probe-0.json" 'd["model_state"]')" != complete ]; }; then
  ask "Model directory (same path on every node, local NVMe)" "$MODEL_DIR"
  if [ "$REPLY" != "$MODEL_DIR" ]; then MODEL_DIR=$REPLY; probe_all; ok "re-checked space for $MODEL_DIR"; fi
fi
ENVSET[MODEL_DIR]=$(printf %q "$MODEL_DIR")
BASE="$REPO_DIR/cluster.env"; [ -f "$BASE" ] || BASE="$REPO_DIR/cluster.env.example"
python3 - "$BASE" "$STATE/cluster.env.new" "${!ENVSET[@]}" -- "${ENVSET[@]}" <<'PY'
import re, sys
a = sys.argv[1:]; src, dst = a[0], a[1]; sep = a.index("--"); keys, vals = a[2:sep], a[sep + 1:]
text = open(src).read()
# older files put two assignments on one line ("A=x;   B=y"); split them so each key can be replaced on its own
text = re.sub(r"^([A-Z0-9_]+=[^;\n#]*?);[ \t]+([A-Z0-9_]+=)", r"\1\n\2", text, flags=re.M)
for k, v in zip(keys, vals):
    line = f"{k}={v}"
    if re.search(rf"^{k}=", text, re.M):
        text = re.sub(rf"^{k}=.*$", lambda m: line, text, count=1, flags=re.M)
    else:
        text += ("" if text.endswith("\n") else "\n") + line + "\n"
open(dst, "w").write(text)
PY
if [ -f "$REPO_DIR/cluster.env" ] && cmp -s "$REPO_DIR/cluster.env" "$STATE/cluster.env.new"; then ok "cluster.env is up to date"
else
  info "proposed cluster.env changes:"
  diff -u "$([ -f "$REPO_DIR/cluster.env" ] && echo "$REPO_DIR/cluster.env" || echo /dev/null)" "$STATE/cluster.env.new" | sed -n '3,200p' | grep -E '^[-+]' | sed 's/^/          /'
  if ask_yn "Write cluster.env?" y; then cp "$STATE/cluster.env.new" "$REPO_DIR/cluster.env" && ok "cluster.env written"
  else warn "cluster.env not written (proposal kept in $STATE/cluster.env.new)"; fi
fi
[ -f "$REPO_DIR/cluster.env" ] && source "$REPO_DIR/cluster.env"
[ "$CHECK" = 0 ] && [ "$N" -gt 1 ] && sync_repo

# ---------------------------------------------------------------- 6. image
step "6. Container image"
for ((i = 0; i < N; i++)); do
  h=${NODES[$i]}
  if [ "$(j "$STATE/probe-$i.json" 'd["image_present"]')" != True ]; then
    if ask_yn "Pull $R_IMAGE on $h (~20 GB)?" y; then on "$i" "docker pull -q $R_IMAGE" >/dev/null && ok "$h: image pulled" || { bad "$h: docker pull failed"; continue; }
    else bad "$h: image missing"; continue; fi
  fi
  g=$(on "$i" "docker run --rm --gpus all --entrypoint nvidia-smi $R_IMAGE -L 2>&1" | head -1)
  [[ "$g" == GPU* ]] && ok "$h: image present, GPU visible in the container ($g)" || bad "$h: GPU not visible inside the container: $g"
done

# ---------------------------------------------------------------- 7. network test
nccl_run() {  # profile world
  local prof=$1 W=$2 r port=$((29500 + RANDOM % 400)) out rc=0
  source "$KIT_DIR/lib/nccl.sh"
  # the kit must already be on every node: a missing -v source makes Docker create it as an empty root-owned dir
  for ((r = 0; r < W; r++)); do
    on "$r" "test -f $(printf %q "$KIT_DIR/lib/nccl_check.py")" || { bad "${NODES[$r]}: $KIT_DIR missing (repo not copied)"; return; }
  done
  for ((r = W - 1; r >= 0; r--)); do
    "nccl_env_$prof" "$r"
    on "$r" "docker rm -f kit_nccl_check >/dev/null 2>&1; docker run -d --name kit_nccl_check --gpus all --network host --ipc host \
      --shm-size 8g --ulimit memlock=-1:-1 --cap-add IPC_LOCK --device /dev/infiniband:/dev/infiniband \
      -v $(printf %q "$KIT_DIR/lib"):/kit:ro $(printf '%q ' "${NCCL_ENV[@]}") --entrypoint python3 $R_IMAGE \
      /kit/nccl_check.py --rank $r --world $W --master $NCCL_MASTER --port $port >/dev/null" || rc=1
  done
  out=$(on 0 "timeout 240 docker wait kit_nccl_check >/dev/null; docker logs kit_nccl_check 2>&1 | tail -40")
  for ((r = 0; r < W; r++)); do on "$r" "docker rm -f kit_nccl_check >/dev/null 2>&1"; done
  local res; res=$(grep -E '^\{"ok"' <<< "$out" | tail -1)
  if [ -n "$res" ] && [ "$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['ok'])" "$res")" = True ]; then
    ok "NCCL all-reduce, $prof profile, $W Sparks: $(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(f\"{d['busbw_GBps']} GB/s bus bandwidth ({d['mb']} MB, {d['ms']} ms, NCCL {d['nccl']})\")" "$res")"
    note "nccl $prof x$W: $res"
  else
    bad "NCCL all-reduce, $prof profile, $W Sparks failed"; grep -E 'NCCL WARN|Error|error' <<< "$out" | head -8 | sed 's/^/          /'
    info "full output: rerun with NCCL_DEBUG=INFO ./setup.sh --skip-download"
  fi
}
if [ "$N" -gt 1 ] && [ "$SKIP_NET" = 0 ]; then
  step "7. Network test"
  busy=$(for ((i = 0; i < N; i++)); do j "$STATE/probe-$i.json" '[c for c in d["containers"] if c != "kit_nccl_check" and "dash" not in c.lower()]'; done | xargs)
  if [ "$CHECK" = 1 ] && [ -n "$busy" ]; then warn "containers running ($busy) — skipping the live network test"
  elif [ -n "$busy" ] && ! ask_yn "Containers are running ($busy). Run the network test anyway (needs ~2 GB GPU memory per node)?" n; then
    warn "network test skipped"
  else
    while IFS=$'\t' read -r ia ib hca_a hca_b gid ipb; do
      on "$ib" "pkill -x ib_write_bw; nohup timeout 30 ib_write_bw -d $hca_b -x $gid -F --report_gbits -D 4 -q 4 >/tmp/kit_ibbw.log 2>&1 &"; sleep 2
      bw=$(on "$ia" "ib_write_bw -d $hca_a -x $gid -F --report_gbits -D 4 -q 4 ${ipb%/*} 2>&1" | awk '$1 ~ /^[0-9]+$/ && NF >= 5 {v=$4} END {print v}')
      if [ -n "$bw" ]; then
        if python3 -c "import sys; sys.exit(0 if float('$bw') >= 80 else 1)"; then ok "RDMA ${NODES[$ia]} -> ${NODES[$ib]} ($hca_a): $bw Gb/s"
        else warn "RDMA ${NODES[$ia]} -> ${NODES[$ib]} ($hca_a): only $bw Gb/s (expect ~90+ per port)"; fi
        note "rdma ${NODES[$ia]}->${NODES[$ib]} $hca_a: $bw Gb/s"
      else bad "RDMA test ${NODES[$ia]} -> ${NODES[$ib]} ($hca_a) failed"; fi
    done < <(python3 -c "import json; [print(l['pair'][0], l['pair'][1], l['a']['hca'], l['b']['hca'], l['a']['gid'] if l['a']['gid'] is not None else 5, l['b']['ip'], sep='\t') for l in json.load(open('$STATE/topology.json'))['links']]")
    [[ " $R_TP " == *" 2 "* ]] && nccl_run pair 2
    [ "$N" -ge 3 ] && [[ " $R_TP " == *" 3 "* ]] && nccl_run triangle 3
  fi
fi

# ---------------------------------------------------------------- 8. model
step "8. Model"
if [ "$SKIP_DL" = 1 ]; then info "skipped (--skip-download)"
else
  st=$(j "$STATE/probe-0.json" 'd["model_state"]')
  if [ "$st" = complete ]; then ok "head: $R_HF_REPO at $MODEL_DIR"
  elif [ -z "$HF_BIN" ]; then bad "no hf CLI to download with"
  elif [ "${#FAILS[@]}" -gt 0 ] && ! ask_yn "There are FAIL items above. Download ~${R_DISK_GB} GB anyway?" n; then warn "download postponed until the FAIL items are fixed"
  elif ask_yn "Download $R_HF_REPO@${R_REVISION:0:8} (~${R_DISK_GB} GB) to $MODEL_DIR?" y; then
    mkdir -p "$MODEL_DIR" && "$HF_BIN" download "$R_HF_REPO" --revision "$R_REVISION" --local-dir "$MODEL_DIR" \
      && ok "downloaded to $MODEL_DIR" \
      || bad "download failed (gated model? run: $HF_BIN auth login)"
  fi
  if [ "$(python3 "$KIT_DIR/lib/probe.py" --no-neighbors --model-dir "$MODEL_DIR" | python3 -c 'import json,sys; print(json.load(sys.stdin)["model_state"])')" = complete ]; then
    for ((i = 1; i < N; i++)); do
      if [ "$(j "$STATE/probe-$i.json" 'd["model_state"]')" = complete ]; then ok "${NODES[$i]}: model present"; continue; fi
      if ask_yn "Copy the model to ${NODES[$i]} (~${R_DISK_GB} GB over SSH)?" y; then
        on "$i" "mkdir -p $(printf %q "$MODEL_DIR")" && rsync -a --info=progress2 --exclude .cache/ "$MODEL_DIR/" "${NODES[$i]}:$MODEL_DIR/" \
          && ok "${NODES[$i]}: model copied" || bad "${NODES[$i]}: copy failed"
      fi
    done
    pv="R_PREPARE_$N"
    if [ -n "${!pv:-}" ] && [ "$CHECK" = 0 ]; then
      while IFS= read -r cmd; do [ -z "$cmd" ] && continue
        info "prepare: $cmd"; (cd "$REPO_DIR" && bash -c "$cmd") && ok "$cmd" || bad "$cmd failed"
      done <<< "${!pv}"
    fi
  fi
fi

# ---------------------------------------------------------------- report
step "Summary"
{
  echo "# setup report $(date -Is) — $R_NAME"
  echo "nodes: ${NODES[*]}"
  for ((i = 0; i < N; i++)); do echo "${NODES[$i]}: $(j "$STATE/probe-$i.json" '" / ".join([d["dgx"] or d["os"], d["dgx_build"], d["gpu"], str(d["mem_total_gib"]) + " GiB"])')"; done
  [ -f "$STATE/topology.json" ] && [ "$N" -gt 1 ] && python3 -c "import json; [print('cable', l['a']['node'], l['a']['netdev'], l['a']['ip'], '<->', l['b']['node'], l['b']['netdev'], l['b']['ip']) for l in json.load(open('$STATE/topology.json'))['links']]"
  for r in "${REPORT[@]}"; do echo "$r"; done
  for w in "${WARNS[@]}"; do echo "WARN $w"; done
  for f in "${FAILS[@]}"; do echo "FAIL $f"; done
} > "$STATE/report.txt"
info "report: $STATE/report.txt (attach it to a GitHub issue if something is wrong)"
if [ "${#FAILS[@]}" -gt 0 ]; then
  printf '\n%s%d item(s) to fix:%s\n' "$RD" "${#FAILS[@]}" "$N0"; for f in "${FAILS[@]}"; do echo "  - $f"; done
  exit 1
fi
[ "$CHECK" = 1 ] && printf '\n%sCheck complete — nothing to fix.%s ' "$G" "$N0" || printf '\n%sReady.%s ' "$G" "$N0"
[ "${#WARNS[@]}" -gt 0 ] && printf '(%d warning(s) above) ' "${#WARNS[@]}"
rv="R_RUN_$N"; echo; echo "Start it with:  ${!rv:-./run.sh}"
[ -n "${R_SMOKE:-}" ] && echo "Then check it:  $R_SMOKE"
