#!/usr/bin/env bash
# Mocked AMD ROCm blade: same update-clean.sh, rocm-smi instead of nvidia-smi.
# Usage: sudo ./tests/simulate_amd_blade.sh
set -euo pipefail

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    printf 'Error: tests must be run as root (sudo ./tests/simulate_amd_blade.sh)\n' >&2
    exit 1
fi

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
UC="$ROOT/update-clean.sh"
SIM=$(mktemp -d "${TMPDIR:-/tmp}/amd-blade-sim.XXXXXX")
PASS=0
FAIL=0
# shellcheck disable=SC2064
trap 'rm -rf "$SIM"' EXIT

mkdir -p "$SIM/bin"
cat >"$SIM/bin/rocm-smi" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
joined="$*"
if [[ "$joined" == *showdriverversion* ]]; then
    printf '%s\n' "Driver version: 6.2.1"
    exit 0
fi
if [[ "$joined" == *"-i"* ]]; then
    printf '%s\n' "GPU[0] : AMD Instinct MI300X" "GPU[1] : AMD Instinct MI300X"
    exit 0
fi
if [[ "$joined" == *showpids* ]]; then
    if [[ "${SIM_GPU_BUSY:-0}" == "1" ]]; then
        printf '%s\n' "18421" "19004"
    fi
    exit 0
fi
printf '%s\n' "ROCm System Management Interface"
exit 0
EOF
chmod +x "$SIM/bin/rocm-smi"

run_uc() {
    local out="$1"
    shift
    env PATH="$SIM/bin:$PATH" \
        GPU_VENDOR_PREFER=rocm \
        UPDATE_CLEAN_SKIP_LOGS=true \
        LOCKFILE="$SIM/update-clean.lock" \
        MIN_DISK_KB=1 \
        BOOT_DISK_KB=1 \
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

printf '=== AMD ROCm blade simulation (real update-clean.sh) ===\n\n'

out="$SIM/version.txt"
rc=0
run_uc "$out" "$UC" --version || rc=$?
expect_rc "version exit" "$rc" 0
expect_grep "version driver" "$out" "6\\.2\\.1"
expect_grep "version 2 GPUs" "$out" "GPUs: 2"
expect_no_grep "version no instance lock" "$out" "Acquired instance lock"

out="$SIM/check-idle.txt"
rc=0
run_uc "$out" SIM_GPU_BUSY=0 "$UC" --check --offline || rc=$?
expect_rc "check idle exit" "$rc" 0
expect_grep "check GPU count" "$out" "GPU count: 2"
expect_no_grep "check idle no lock" "$out" "Acquired instance lock"

out="$SIM/check-busy.txt"
rc=0
run_uc "$out" SIM_GPU_BUSY=1 "$UC" --check --offline || rc=$?
expect_rc "check busy exit" "$rc" 0
expect_grep "check busy count" "$out" "2"

out="$SIM/busy-skip.txt"
rc=0
run_uc "$out" SIM_GPU_BUSY=1 "$UC" --dry-run --offline --quiet || rc=$?
expect_rc "busy skip exit 3" "$rc" 3
expect_no_grep "busy no apt upgrade" "$out" "DRY-RUN: would run: apt-get -y upgrade"

out="$SIM/force-busy.txt"
rc=0
run_uc "$out" SIM_GPU_BUSY=1 "$UC" --dry-run --offline --quiet --no-skip-if-gpu-busy || rc=$?
expect_rc "force busy exit" "$rc" 0
expect_grep "force plans upgrade" "$out" "DRY-RUN: would run: apt-get -y upgrade"

printf '\n=== %s passed, %s failed ===\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
    printf '\n--- artifacts in %s ---\n' "$SIM"
    exit 1
fi
exit 0
