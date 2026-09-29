#!/usr/bin/env bash
# tests/test_scripts.sh — the kit's shell pieces without any hardware: new-recipe.sh for every TP range (no leftover
# placeholders, DRY_RUN commands for every size, clear errors), load_cluster_env precedence, and the bench guard
# against a stand-in OpenAI-style server. Needs bash, python3 and curl.
set -uo pipefail
KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T=$(mktemp -d); trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$T"' EXIT
fails=0
ok()   { printf 'ok    %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; fails=$((fails + 1)); }
check() { local name=$1; shift; if "$@" >/dev/null 2>&1; then ok "$name"; else fail "$name"; fi; }

# ---- new-recipe.sh ---------------------------------------------------------------------------------------------
declare -A NAMEOF=([1]=Test-Model-DGX-Spark-TP1 [1-2]=Test-Model-DGX-Spark-TP1-TP2 [1-3]=Test-Model-DGX-Spark-TP1-TP3
                   [2-3]=Test-Model-DGX-Spark-TP2-TP3 [3]=Test-Model-DGX-Spark-TP3)
for tp in 1 1-2 1-3 2-3 3; do
  d="$T/r$tp"
  if ! "$KIT/new-recipe.sh" --model Test-Model --hf org/Test-Model-NVFP4 --tp "$tp" --out "$d" > "$T/gen.out" 2>&1; then
    fail "new-recipe --tp $tp: $(tail -1 "$T/gen.out")"; continue; fi
  grep -q "^name: ${NAMEOF[$tp]}\$" "$d/recipe.yaml" && ok "new-recipe --tp $tp: name ${NAMEOF[$tp]}" || fail "new-recipe --tp $tp: name"
  left=$(grep -rn --exclude=LICENSE -E '\{\{[A-Z_]+\}\}' "$d" | head -3)
  [ -z "$left" ] && ok "new-recipe --tp $tp: no placeholders left" || fail "new-recipe --tp $tp: placeholders left: $left"
  python3 - "$d" "$tp" <<'PY' && ok "new-recipe --tp $tp: links resolve, no markers left, text fits the sizes" || fail "new-recipe --tp $tp: docs"
import os, re, sys
d, tp = sys.argv[1], sys.argv[2]
bad = []
for root, _, files in os.walk(d):
    for f in files:
        if not f.endswith(".md"): continue
        p = os.path.join(root, f); s = open(p).read()
        if "<!--" in s: bad.append(f"{f}: marker left")
        for link in re.findall(r"\]\(([^)#:]+)\)", s):
            if not os.path.exists(os.path.join(root, link)): bad.append(f"{f}: broken link {link}")
r = open(os.path.join(d, "README.md")).read()
if tp == "1":
    for w in ("worker", "fabric", "NCCL", "networking.md"):
        if w in r: bad.append(f"README (TP1 only) mentions {w}")
hw = next(l for l in r.splitlines() if l.startswith("| Hardware |"))
if ("DGX Sparks" in hw) != (tp != "1"): bad.append(f"Hardware row grammar: {hw}")
if "3" not in tp and "TP3" in r: bad.append("README mentions TP3")
if "2" not in tp.replace("1-3", "123").replace("2-3", "23") and "TP2:" in r: bad.append("README mentions TP2")
if bad: print("\n".join(bad)); sys.exit(1)
PY
  for f in run.sh lib/common.sh recipes/*.sh bench/bench.sh scripts/smoke-test.sh setup.sh; do
    (cd "$d" && bash -n $f) || fail "new-recipe --tp $tp: bash -n $f"; done
  python3 - "$d/recipe.yaml" <<'PY' && ok "new-recipe --tp $tp: recipe.yaml parses" || fail "new-recipe --tp $tp: recipe.yaml"
import sys
try:
    import yaml
except ImportError:
    sys.exit(0)   # PyYAML not installed here; CI installs it
y = yaml.safe_load(open(sys.argv[1]))
assert [r["id"] for r in y["recipes"]] == [f"tp{n}" for n in y["setup"]["tp_sizes"]]
assert sorted(y["setup"]["first_run"]) == y["setup"]["tp_sizes"]
PY
  # a working recipe: the kit next to it, the example cluster.env, model flags filled in
  ln -s "$KIT" "$d/kit"; cp "$d/cluster.env.example" "$d/cluster.env"
  sed -i.bak 's|^MODEL_ARGS=(TODO)|MODEL_ARGS=(--dtype auto)|' "$d/lib/common.sh"
  for n in 1 2 3; do
    [ -f "$d/recipes/tp$n.sh" ] || continue
    c=$(cd "$d" && DRY_RUN=1 ./run.sh tp$n 2>/dev/null | grep -c '^docker ')
    [ "$c" = "$n" ] && ok "new-recipe --tp $tp: DRY_RUN tp$n prints $n docker command(s)" || fail "new-recipe --tp $tp: DRY_RUN tp$n gave $c"
  done
done
check "new-recipe refuses to overwrite"       bash -c "! '$KIT/new-recipe.sh' --model Test-Model --hf org/x --tp 1-2 --out '$T/r1-2'"
check "new-recipe rejects a bad --tp"          bash -c "! '$KIT/new-recipe.sh' --model X --hf org/x --tp 4 --out '$T/bad'"
check "new-recipe rejects a bad --model"       bash -c "! '$KIT/new-recipe.sh' --model 'a b' --hf org/x --tp 1 --out '$T/bad'"
d="$T/r1-2"
check "run.sh refuses a size the recipe lacks" bash -c "cd '$d' && ! DRY_RUN=1 ./run.sh tp3"
check "real launch without the model stops"    bash -c "cd '$d' && ./run.sh tp1 2>&1 | grep -q 'MODEL MISSING'"

# ---- load_cluster_env --------------------------------------------------------------------------------------------
cat > "$T/c.env" <<'X'
PORT=8000
SERVED_NAMES="a b"   # comment
NODES=(n1 n2)
EMPTY=
X
r=$(env -u PORT bash -c "source '$KIT/lib/cluster_env.sh'; load_cluster_env '$T/c.env'; echo \"\$PORT|\$SERVED_NAMES|\${NODES[*]}\"")
[ "$r" = "8000|a b|n1 n2" ] && ok "load_cluster_env: file values" || fail "load_cluster_env: file values ($r)"
r=$(PORT=8001 SERVED_NAMES="x" NODES=bogus bash -c "source '$KIT/lib/cluster_env.sh'; load_cluster_env '$T/c.env'; echo \"\$PORT|\$SERVED_NAMES|\${NODES[*]}\"")
[ "$r" = "8001|x|n1 n2" ] && ok "load_cluster_env: environment wins, arrays from the file" || fail "load_cluster_env: override ($r)"

# ---- bench guard ---------------------------------------------------------------------------------------------------
cat > "$T/fake.py" <<'PY'
import http.server, json, sys
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        b = json.dumps({"data": [{"id": sys.argv[2], "max_model_len": 262144}]}).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json"); self.end_headers(); self.wfile.write(b)
    do_POST = lambda self: (self.send_response(500), self.end_headers())
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY
python3 "$T/fake.py" 18471 other-model & python3 "$T/fake.py" 18472 test-model &
for _ in $(seq 20); do curl -sf 127.0.0.1:18471/v1/models >/dev/null && curl -sf 127.0.0.1:18472/v1/models >/dev/null && break; sleep 0.2; done
d="$T/r1-2"; before=$(ls "$d/bench/results" | wc -l)
(cd "$d" && WAIT=5 bash bench/bench.sh guard http://127.0.0.1:18471/v1 > "$T/g.out" 2>&1); rc=$?
[ "$rc" = 2 ] && grep -q "Nothing written" "$T/g.out" && [ "$(ls "$d/bench/results" | wc -l)" = "$before" ] \
  && ok "bench refuses another model and writes nothing" || fail "bench guard (rc=$rc: $(head -1 "$T/g.out"))"
(cd "$d" && WAIT=5 timeout 30 bash bench/bench.sh own http://127.0.0.1:18472/v1 > "$T/g2.out" 2>&1)
grep -q "^model=test-model" "$T/g2.out" && compgen -G "$d/bench/results/*-own.log" >/dev/null \
  && ok "bench accepts the recipe's own model" || fail "bench own model: $(head -2 "$T/g2.out" | tr '\n' ' ')"
mkdir -p "$T/adhoc"; (cd "$d" && BENCH_OUT="$T/adhoc" WAIT=5 timeout 30 bash bench/bench.sh x http://127.0.0.1:18471/v1 >/dev/null 2>&1)
compgen -G "$T/adhoc/*-x.log" >/dev/null && ! compgen -G "$d/bench/results/*-x.log" >/dev/null \
  && ok "BENCH_OUT sends another model's results elsewhere" || fail "BENCH_OUT"

echo; [ "$fails" = 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
