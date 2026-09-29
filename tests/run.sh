#!/usr/bin/env bash
# tests/run.sh — every hardware-free test of the kit. Run locally or in CI (.github/workflows/test.yml).
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
rc=0
echo "== python syntax";  python3 -m py_compile lib/*.py bench/*.py tests/*.py && echo ok || rc=1
echo "== bash syntax";    for f in setup.sh new-recipe.sh lib/*.sh bench/*.sh template/*.sh template/*/*.sh tests/*.sh; do bash -n "$f" || { echo "FAIL $f"; rc=1; }; done; echo ok
if command -v shellcheck >/dev/null; then
  echo "== shellcheck"
  shellcheck -S warning -x setup.sh new-recipe.sh lib/*.sh bench/*.sh template/run.sh template/lib/common.sh \
    template/bench/bench.sh template/scripts/smoke-test.sh template/setup.sh tests/*.sh && echo ok || rc=1
  # template launchers contain {{PLACEHOLDERS}}; SC1083 (literal braces) is expected there
  shellcheck -S warning -e SC1083 template/recipes/*.sh && echo ok || rc=1
fi
echo "== topology";       python3 tests/test_topology.py 2>&1 | tail -3; [ "${PIPESTATUS[0]}" = 0 ] || rc=1
echo "== scripts";        bash tests/test_scripts.sh || rc=1
exit $rc
