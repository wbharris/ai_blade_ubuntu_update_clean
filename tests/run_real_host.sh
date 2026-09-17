#!/usr/bin/env bash
# Real Ubuntu GPU host tests (this machine). Requires root.
# Does not upgrade packages. Isolates logs/lock under $TMPDIR.
#
# Usage: sudo ./tests/run_real_host.sh
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
UC="$ROOT/update-clean.sh"
PASS=0
FAIL=0
SIM=$(mktemp -d "${TMPDIR:-/tmp}/uc-blade-real.XXXXXX")
HOLDS_BEFORE=""
KERN_PKG=""

cleanup() {
    if [ -n "$KERN_PKG" ]; then
        apt-mark unhold "$KERN_PKG" >/dev/null 2>&1 || true
    fi
    rm -rf "$SIM"
}
trap cleanup EXIT

pass() { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
fail_case() { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL + 1)); }

if [ ! -x "$UC" ]; then
    printf 'missing %s\n' "$UC" >&2
    exit 1
fi
if [ "$EUID" -ne 0 ]; then
    printf 'this harness needs root (real dpkg / apt-mark / nvidia-smi / dry-run)\n' >&2
    exit 1
fi

export UPDATE_CLEAN_SKIP_LOGS=true
export LOCKFILE="$SIM/update-clean.lock"
mkdir -p "$SIM"

HOLDS_BEFORE=$(apt-mark showhold 2>/dev/null || true)

printf '=== Real GPU host tests (%s) ===\n' "$UC"
printf 'host: %s\n\n' "$(. /etc/os-release 2>/dev/null; printf '%s' "${PRETTY_NAME:-unknown}")"

out="$SIM/version.txt"
rc=0
"$UC" --version >"$out" 2>&1 || rc=$?
[ "$rc" -eq 0 ] && grep -Eq 'update-clean 1\.[0-9]' "$out" && pass "--version" || fail_case "--version (rc=$rc)"
grep -q 'AI platform: gpu-host' "$out" && pass "--version reports gpu-host" || fail_case "--version reports gpu-host"
grep -Eq 'GPU driver: [0-9]' "$out" && pass "--version reports GPU driver" || fail_case "--version reports GPU driver"

out="$SIM/check.txt"
rc=0
"$UC" --check --offline >"$out" 2>&1 || rc=$?
[ "$rc" -eq 0 ] && grep -q 'Required tools: OK' "$out" && pass "--check --offline" || fail_case "--check --offline (rc=$rc)"
grep -q 'GPU count: 1' "$out" || grep -qE 'GPU count: [1-9]' "$out" \
    && pass "--check GPU count >= 1" || fail_case "--check GPU count >= 1"
grep -q 'No active GPU compute processes detected' "$out" \
    && pass "--check idle GPUs" || fail_case "--check idle GPUs"
grep -q 'SKIP_FIRMWARE: true' "$out" && pass "--check firmware skipped by default" || fail_case "--check firmware skipped by default"

out="$SIM/dryrun.txt"
rc=0
/usr/bin/timeout 90 "$UC" --dry-run --offline --no-kernel >"$out" 2>&1 || rc=$?
if [ "$rc" -eq 124 ]; then
    fail_case "dry-run finished within 90s (timed out — likely unbounded sync)"
elif [ "$rc" -ne 0 ]; then
    fail_case "dry-run exit 0 (rc=$rc)"
else
    pass "dry-run finished within 90s"
fi
grep -Eq 'DRY-RUN: would run: dpkg --configure -a' "$out" \
    && pass "dry-run does not run dpkg --configure -a" \
    || fail_case "dry-run does not run dpkg --configure -a"
if grep -Eq '^[^[]+ set on hold\.$' "$out"; then
    fail_case "dry-run does not apt-mark hold"
else
    pass "dry-run does not apt-mark hold"
fi
grep -q 'DRY-RUN: would apt-mark hold' "$out" \
    && grep -qiE 'cuda-|nvidia-' "$out" \
    && pass "dry-run would hold CUDA/NVIDIA packages" \
    || fail_case "dry-run would hold CUDA/NVIDIA packages"
HOLDS_AFTER=$(apt-mark showhold 2>/dev/null || true)
[ "$HOLDS_AFTER" = "$HOLDS_BEFORE" ] && pass "holds unchanged after dry-run" || fail_case "holds unchanged after dry-run"

KERN_PKG=$(dpkg-query -S "/boot/vmlinuz-$(uname -r)" 2>/dev/null | awk -F: '{print $1}' | head -n1 || true)
if [ -z "$KERN_PKG" ]; then
    fail_case "map running kernel to linux-image package"
else
    apt-mark hold "$KERN_PKG" >/dev/null 2>&1 || true
    listed=$(
        dpkg-query -W -f='${Status}\t${Package}\n' 'linux-image-*' 2>/dev/null \
            | awk -F'\t' '$1 ~ /^(install|hold) ok installed$/ {print $2}' \
            | grep -E '^linux-image(-unsigned)?-[0-9]' \
            || true
    )
    printf '%s\n' "$listed" | grep -Fxq "$KERN_PKG" \
        && pass "held kernel still listed ($KERN_PKG)" \
        || fail_case "held kernel still listed ($KERN_PKG)"
    apt-mark unhold "$KERN_PKG" >/dev/null 2>&1 || true
    KERN_PKG=""
fi

if [ -d /sys/firmware/efi ]; then
    grep -q 'grub-pc' "$UC" && grep -q 'sys/firmware/efi' "$UC" \
        && pass "EFI residual purge skips grub-pc (script)" \
        || fail_case "EFI residual purge skips grub-pc (script)"
else
    pass "not EFI (skip grub-pc assertion)"
fi

grep -Eq 'install\|hold\) ok installed' "$UC" \
    && pass "script matches hold ok installed" \
    || fail_case "script matches hold ok installed"

if command -v nvidia-smi >/dev/null 2>&1; then
    nvidia-smi -L >/dev/null 2>&1 && pass "nvidia-smi -L" || fail_case "nvidia-smi -L"
else
    fail_case "nvidia-smi present on GPU host"
fi

printf '\n=== %s passed, %s failed ===\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
