#!/usr/bin/env bash
# kit/bench/bench.sh LABEL [BASE_URL] — the standard benchmark for every recipe that uses the kit, run against a live
# server. A recipe's bench/bench.sh just runs this, so every recipe and every TP size runs the identical suite.
# Writes <recipe>/bench/results/<date>-<LABEL>.log.
#   single stream, thinking off:  short code x3, short prose x3, ~9K-token prompt x2 (--long 12)
#   cold prefill (unique prompts, prefix cache off):  8K x3, 28K x2
#   smoke test (correctness)
# LONG=1 adds the long-context needle test at 128K/256K (and 512K/900K when the server's max-model-len allows,
# plus 988K on a 1M server).
# Exits non-zero if the smoke test fails (after printing every result).
set -euo pipefail
LABEL="${1:?label, e.g. tp3}"; B="${2:-http://127.0.0.1:${PORT:-8000}/v1}"
D="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"              # kit/bench
REPO_DIR="${REPO_DIR:-$(cd "$D/../.." && pwd)}"                  # the recipe (kit/ sits in its root)
RES="$REPO_DIR/bench/results"
# The recipe's scripts/smoke-test.sh if it has one (normally a wrapper for this kit's), else the kit's.
SMOKE_SH="$REPO_DIR/scripts/smoke-test.sh"; [ -f "$SMOKE_SH" ] || SMOKE_SH="$D/smoke-test.sh"
mkdir -p "$RES"; LOG="$RES/$(date +%F)-$LABEL.log"
exec > >(tee -a "$LOG") 2>&1
echo "=== bench $LABEL $(date -Is) $B"
WAIT="${WAIT:-2400}"; t0=$SECONDS   # server load can take 10+ min; give up after WAIT seconds
until curl -sf "$B/models" >/dev/null; do
  [ $((SECONDS - t0)) -lt "$WAIT" ] || { echo "server not up after ${WAIT}s — giving up"; exit 1; }
  if [ -n "${NAME:-}" ] && ! docker ps --format '{{.Names}}' | grep -qx "$NAME"; then echo "container $NAME exited"; docker logs "$NAME" 2>&1 | tail -30; exit 1; fi
  sleep 15; done
M=$(curl -sf "$B/models" | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"][0]["id"])')
MAXLEN=$(curl -sf "$B/models" | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"][0].get("max_model_len", 0))')
echo "model=$M max_model_len=$MAXLEN host=$(hostname)"
free -g | head -2
echo "--- short code, 3 runs";   python3 "$D/bench-decode.py" "$B" "$M" --code
echo "--- short prose, 3 runs";  python3 "$D/bench-decode.py" "$B" "$M"
echo "--- long ~9K prompt, 2 runs"; python3 "$D/bench-decode.py" "$B" "$M" --long 12 --runs 2
echo "--- cold prefill 8K x3";   python3 "$D/bench-prefill-cold.py" "$B" "$M" --ktok 8 --runs 3
echo "--- cold prefill 28K x2";  python3 "$D/bench-prefill-cold.py" "$B" "$M" --ktok 28 --runs 2
if [ "${LONG:-0}" = 1 ]; then
  sizes=(128 256); [ "$MAXLEN" -ge 600000 ] && sizes+=(512 900); [ "$MAXLEN" -ge 1000000 ] && sizes+=(988)
  echo "--- long-context needle test ${sizes[*]}K"; python3 "$D/bench-longctx.py" "$B" "$M" --ktok "${sizes[@]}"
fi
echo "--- smoke test"; SMOKE=0; bash "$SMOKE_SH" "$B" || SMOKE=$?
echo "=== done $(date -Is) -> bench/results/$(basename "$LOG")"
[ "$SMOKE" = 0 ] || { echo "SMOKE TEST FAILED (exit $SMOKE)"; exit 1; }
