#!/usr/bin/env bash
# Run the NVIDIA AI blade simulation harness.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
exec bash "$SCRIPT_DIR/simulate_nvidia_blade.sh"
