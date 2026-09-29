#!/usr/bin/env bash
# bench/bench.sh LABEL [BASE_URL] — the shared benchmark suite from the kit (kit/bench/bench.sh), so every recipe and
# every TP size is measured the same way. Writes bench/results/<date>-<LABEL>.log. LONG=1 adds the needle test.
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/kit/bench/bench.sh" "$@"
