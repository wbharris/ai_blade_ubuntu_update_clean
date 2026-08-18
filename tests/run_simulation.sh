#!/usr/bin/env bash
# Run the NVIDIA AI blade simulation and capture output
# This script executes simulate_nvidia_blade.sh and presents results

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_SCRIPT="$SCRIPT_DIR/simulate_nvidia_blade.sh"

if [ ! -f "$TEST_SCRIPT" ]; then
    echo "Error: $TEST_SCRIPT not found"
    exit 1
fi

# Execute the simulation
bash "$TEST_SCRIPT"

exit $?
