#!/usr/bin/env bash
# Non-root unit tests against sourced update-clean.sh (no apt, no lock).
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../update-clean.sh
source "$ROOT/update-clean.sh"

fail=0
pass() { printf '  PASS  %s\n' "$1"; }
fail_case() { printf '  FAIL  %s\n' "$1"; fail=1; }

re=$(kernel_related_grep_ere "6.5.0-14")
printf '%s\n' "linux-headers-6.5.0-14" | grep -Eq -- "$re" && pass "kernel ere matches 6.5.0-14 headers" || fail_case "kernel ere matches 6.5.0-14 headers"
printf '%s\n' "linux-headers-6.5.0-140" | grep -Eq -- "$re" && fail_case "kernel ere does not match 6.5.0-140" || pass "kernel ere does not match 6.5.0-140"
printf '%s\n' "linux-modules-extra-6.5.0-14-generic" | grep -Eq -- "$re" && pass "kernel ere matches extra-generic suffix" || fail_case "kernel ere matches extra-generic suffix"

truthy true && pass "truthy true" || fail_case "truthy true"
truthy false && fail_case "truthy false" || pass "truthy false"
truthy yes && pass "truthy yes" || fail_case "truthy yes"

SIM=$(mktemp -d "${TMPDIR:-/tmp}/uc-units.XXXXXX")
trap 'rm -rf "$SIM"' EXIT
mkdir -p "$SIM/bin"
cat >"$SIM/bin/rocm-smi" <<'EOF'
#!/usr/bin/env bash
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
    printf '%s\n' "18421" "18422"
    exit 0
fi
exit 0
EOF
chmod +x "$SIM/bin/rocm-smi"
PATH="$SIM/bin:$PATH"
hash -r || true
GPU_VENDOR_PREFER=rocm
query_gpu_driver || true
[[ "$GPU_DRIVER" == "6.2.1" ]] && pass "rocm driver 6.2.1" || fail_case "rocm driver (got ${GPU_DRIVER:-empty})"
[[ "$GPU_COUNT" == "2" ]] && pass "rocm gpu count 2" || fail_case "rocm gpu count (got ${GPU_COUNT:-empty})"
count_gpu_compute_processes
[[ "$GPU_PROCESS_COUNT" == "2" && "$GPU_BUSY" == "true" ]] && pass "rocm busy pids" || fail_case "rocm busy pids (count=${GPU_PROCESS_COUNT:-?} busy=${GPU_BUSY:-?})"

printf '\n=== %s ===\n' "$([[ $fail -eq 0 ]] && echo 'shell units passed' || echo 'shell units failed')"
exit "$fail"
