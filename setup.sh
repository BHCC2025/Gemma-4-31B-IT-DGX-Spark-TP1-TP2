#!/usr/bin/env bash
# Set up this recipe on 1-3 DGX Sparks. See kit/README.md.
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/kit/setup.sh" "$@"
