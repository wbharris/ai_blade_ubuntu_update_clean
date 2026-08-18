#!/usr/bin/env bash
# Real harness: mock an 8x H100 blade and run update-clean.sh.
# Covers quiet GPU summary, SKIP_IF_GPU_BUSY, hold warning, dry-run disk n/a,
# single upgrade preview, inspect modes, and instance lock.
#
# Usage: ./tests/simulate_nvidia_blade.sh
# Exit 0 if every case passes.

set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
UC="$ROOT/update-clean.sh"
SIM=$(mktemp -d "${TMPDIR:-/tmp}/nvidia-blade-sim.XXXXXX")
PASS=0
FAIL=0
# shellcheck disable=SC2064
trap 'rm -rf "$SIM"' EXIT

if [ ! -x "$UC" ]; then
    printf 'missing %s\n' "$UC" >&2
    exit 1
fi

# ── mocks (8x H100, driver 550.127.08, CUDA 12.4) ──────────────
mkdir -p "$SIM/bin"

cat > "$SIM/bin/nvidia-smi" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
joined="$*"

if [[ "$joined" == *"--query-gpu=driver_version"* ]]; then
    printf '%s\n' "550.127.08"
    exit 0
fi
if [[ "$joined" == *"-L"* ]]; then
    for i in 0 1 2 3 4 5 6 7; do
        printf 'GPU %s: NVIDIA H100 80GB HBM3 (UUID: GPU-aaa00000-0000-0000-0000-00000000000%s)\n' "$i" "$i"
    done
    exit 0
fi
if [[ "$joined" == *"--query-gpu=index,name"* ]]; then
    printf '%s\n' "index, name, temperature.gpu, utilization.gpu, utilization.memory, memory.used, memory.total, power.draw"
    for i in 0 1 2 3 4 5 6 7; do
        printf '%s\n' "$i, NVIDIA H100 80GB HBM3, 41, 2 %, 1 %, 412 MiB, 81559 MiB, 72.14 W"
    done
    exit 0
fi
if [[ "$joined" == *"--query-compute-apps=pid"* ]]; then
    if [[ "${SIM_GPU_BUSY:-0}" == "1" ]]; then
        printf '%s\n' "18421" "18422" "19004"
    fi
    exit 0
fi
if [[ "$joined" == *"--query-compute-apps=gpu_uuid"* ]]; then
    printf '%s\n' "gpu_uuid, pid, process_name, used_gpu_memory"
    if [[ "${SIM_GPU_BUSY:-0}" == "1" ]]; then
        printf '%s\n' \
            "GPU-aaa00000-0000-0000-0000-000000000000, 18421, python, 62340 MiB" \
            "GPU-aaa00000-0000-0000-0000-000000000001, 18422, python, 61880 MiB" \
            "GPU-aaa00000-0000-0000-0000-000000000002, 19004, torchrun, 70210 MiB"
    fi
    exit 0
fi
cat <<'BANNER'
+-----------------------------------------------------------------------------------------+
| NVIDIA-SMI 550.127.08             Driver Version: 550.127.08     CUDA Version: 12.4     |
+-----------------------------------------------------------------------------------------+
BANNER
EOF
chmod +x "$SIM/bin/nvidia-smi"

cat > "$SIM/bin/nvidia-container-cli" << 'EOF'
#!/usr/bin/env bash
echo "nvidia-container-cli version 1.16.2"
EOF
chmod +x "$SIM/bin/nvidia-container-cli"

cat > "$SIM/bin/ibstat" << 'EOF'
#!/usr/bin/env bash
printf '%s\n' "CA 'mlx5_0'" "	State: Active" "	Physical state: LinkUp" "	Rate: 400"
EOF
chmod +x "$SIM/bin/ibstat"

cat > "$SIM/bin/dcgmi" << 'EOF'
#!/usr/bin/env bash
printf '%s\n' "8 GPUs found." "| 0      | Name: NVIDIA H100 80GB HBM3"
EOF
chmod +x "$SIM/bin/dcgmi"

run_uc() {
    local out="$1"
    shift
    env PATH="$SIM/bin:$PATH" \
        UPDATE_CLEAN_SKIP_LOGS=true \
        LOCKFILE="$SIM/update-clean.lock" \
        "$@" >"$out" 2>&1
}

expect_rc() {
    local name="$1" got="$2" want="$3"
    if [ "$got" -eq "$want" ]; then
        printf '  PASS  %s (exit %s)\n' "$name" "$got"
        PASS=$((PASS + 1))
    else
        printf '  FAIL  %s (exit %s, want %s)\n' "$name" "$got" "$want"
        FAIL=$((FAIL + 1))
    fi
}

expect_grep() {
    local name="$1" file="$2" pat="$3"
    if grep -Eq -- "$pat" "$file"; then
        printf '  PASS  %s\n' "$name"
        PASS=$((PASS + 1))
    else
        printf '  FAIL  %s (missing /%s/)\n' "$name" "$pat"
        FAIL=$((FAIL + 1))
    fi
}

expect_no_grep() {
    local name="$1" file="$2" pat="$3"
    if grep -Eq -- "$pat" "$file"; then
        printf '  FAIL  %s (unexpected /%s/)\n' "$name" "$pat"
        FAIL=$((FAIL + 1))
    else
        printf '  PASS  %s\n' "$name"
        PASS=$((PASS + 1))
    fi
}

printf '=== NVIDIA AI blade simulation (real update-clean.sh) ===\n'
printf 'script: %s\nmocks:  %s\n\n' "$UC" "$SIM"

# 1) --version sees mocked driver / 8 GPUs
out="$SIM/01-version.txt"
rc=0
run_uc "$out" "$UC" --version || rc=$?
expect_rc "version exit" "$rc" 0
expect_grep "version driver" "$out" "550.127.08"
expect_grep "version 8 GPUs" "$out" "GPUs: 8"
expect_no_grep "version no instance lock" "$out" "Acquired instance lock"

# 2) --check idle: full inventory, no lock
out="$SIM/02-check-idle.txt"
rc=0
run_uc "$out" SIM_GPU_BUSY=0 "$UC" --check --offline || rc=$?
expect_rc "check idle exit" "$rc" 0
expect_grep "check 8x H100" "$out" "GPU 0: NVIDIA H100"
expect_grep "check idle success" "$out" "No active GPU compute processes"
expect_no_grep "check no instance lock" "$out" "Acquired instance lock"

# 3) --check busy: process list
out="$SIM/03-check-busy.txt"
rc=0
run_uc "$out" SIM_GPU_BUSY=1 "$UC" --check --offline || rc=$?
expect_rc "check busy exit" "$rc" 0
expect_grep "check busy count" "$out" "GPU compute processes active: 3"
expect_grep "check torchrun" "$out" "torchrun"

# 4) quiet idle dry-run: one GPU line, n/a disk, one preview, hold warning
out="$SIM/04-quiet-idle.txt"
rc=0
run_uc "$out" SIM_GPU_BUSY=0 "$UC" --dry-run --offline --quiet || rc=$?
expect_rc "quiet idle exit" "$rc" 0
expect_grep "quiet one-line GPU" "$out" "GPU: driver=550.127.08 runtime=12.4 gpus=8 busy=0"
expect_no_grep "quiet no inventory dump" "$out" "GPU inventory:"
expect_grep "dry-run disk n/a" "$out" "n/a \\(dry-run\\)"
preview=$(grep -c 'DRY-RUN preview: upgradable' "$out" || true)
if [ "${preview:-0}" -eq 1 ]; then
    printf '  PASS  single upgrade preview\n'
    PASS=$((PASS + 1))
else
    printf '  FAIL  single upgrade preview (count=%s)\n' "$preview"
    FAIL=$((FAIL + 1))
fi
expect_no_grep "no duplicate remaining-upgrades" "$out" "Remaining upgrades after initial upgrade"
expect_grep "hold-list warning" "$out" "HOLD_GPU is on but no matching vendor packages"
expect_grep "would apt upgrade" "$out" "DRY-RUN: would run: apt-get -y upgrade"

# 5) quiet busy dry-run: skip apt, exit 3
out="$SIM/05-quiet-busy.txt"
rc=0
run_uc "$out" SIM_GPU_BUSY=1 "$UC" --dry-run --offline --quiet || rc=$?
expect_rc "busy skip exit 3" "$rc" 3
expect_grep "busy skip message" "$out" "SKIP_IF_GPU_BUSY: 3 GPU"
expect_grep "busy would skip" "$out" "would skip the update"
expect_no_grep "busy no apt upgrade" "$out" "DRY-RUN: would run: apt-get -y upgrade"
expect_grep "busy shows jobs" "$out" "torchrun"

# 6) --no-skip-if-gpu-busy on a busy node still plans apt
out="$SIM/06-force-busy.txt"
rc=0
run_uc "$out" SIM_GPU_BUSY=1 "$UC" --dry-run --offline --quiet --no-skip-if-gpu-busy || rc=$?
expect_rc "force busy exit" "$rc" 0
expect_grep "force proceeds" "$out" "SKIP_IF_GPU_BUSY is off"
expect_grep "force plans upgrade" "$out" "DRY-RUN: would run: apt-get -y upgrade"

# 7) --last does not take the instance lock
out="$SIM/07-last.txt"
rc=0
run_uc "$out" "$UC" --last || rc=$?
expect_rc "last exit" "$rc" 0
expect_no_grep "last no instance lock" "$out" "Acquired instance lock"

# 8) second instance refused
out="$SIM/08-lock.txt"
exec 9>"$SIM/update-clean.lock"
if flock -n 9; then
    rc=0
    run_uc "$out" SIM_GPU_BUSY=0 "$UC" --dry-run --offline --quiet || rc=$?
    flock -u 9 || true
    exec 9>&- || true
    expect_rc "lock conflict exit" "$rc" 1
    expect_grep "already running" "$out" "already running"
else
    printf '  FAIL  could not take test lock\n'
    FAIL=$((FAIL + 1))
fi

printf '\n=== %s passed, %s failed ===\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
    printf '\n--- last failing artifacts in %s ---\n' "$SIM"
    exit 1
fi
exit 0
