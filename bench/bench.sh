#!/usr/bin/env bash
# bench/bench.sh LABEL [BASE_URL] — the standard benchmark for every recipe in this repo, run against a live server.
# Writes bench/results/<date>-<LABEL>.log. Same suite for every TP size so the numbers compare.
#   single stream, thinking off:  short code x3, short prose x3, ~9K-token prompt x2 (--long 12)
#   cold prefill (unique prompts, prefix cache off):  8K x3, 28K x2
#   smoke test (correctness)
# LONG=1 adds the long-context needle test at 128K/256K (and 512K/900K when the server's max-model-len allows,
# plus 988K on a 1M server).
# Exits non-zero if the smoke test fails (after printing every result).
set -euo pipefail
LABEL="${1:?label, e.g. tp3}"; B="${2:-http://127.0.0.1:${PORT:-8000}/v1}"
D="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mkdir -p "$D/results"; LOG="$D/results/$(date +%F)-$LABEL.log"
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
echo "--- smoke test"; SMOKE=0; bash "$D/../scripts/smoke-test.sh" "$B" || SMOKE=$?
echo "=== done $(date -Is) -> bench/results/$(basename "$LOG")"
[ "$SMOKE" = 0 ] || { echo "SMOKE TEST FAILED (exit $SMOKE)"; exit 1; }
