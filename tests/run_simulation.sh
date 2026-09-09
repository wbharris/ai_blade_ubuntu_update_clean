#!/usr/bin/env bash
# Run the NVIDIA AI blade simulation harness (requires root).
set -euo pipefail
if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    printf 'Error: tests must be run as root (sudo ./tests/run_simulation.sh)\n' >&2
    exit 1
fi
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
exec bash "$SCRIPT_DIR/simulate_nvidia_blade.sh"
