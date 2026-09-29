#!/usr/bin/env bash
# Set up this recipe on 1 or 2 DGX Sparks: ./setup.sh (or --check to only report). See kit/README.md.
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/kit/setup.sh" "$@"
