#!/usr/bin/env bash
# scripts/smoke-test.sh [BASE_URL] — quick correctness check of a running server (the kit's shared smoke test:
# arithmetic, a fact, code, thinking mode and a tool call). Replace this wrapper if the model needs different checks.
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/kit/bench/smoke-test.sh" "$@"
