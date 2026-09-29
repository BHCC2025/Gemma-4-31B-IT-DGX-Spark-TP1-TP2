#!/usr/bin/env bash
# Set up this recipe on your DGX Sparks: ./setup.sh (or --check to only report). See kit/README.md.
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/kit/setup.sh" "$@"
