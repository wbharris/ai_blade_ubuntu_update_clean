#!/usr/bin/env bash
# Non-root unit tests against sourced update-clean.sh (no apt, no lock).
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../update-clean.sh
source "$ROOT/update-clean.sh"

fail=0
pass() { printf '  PASS  %s\n' "$1"; }
fail_case() { printf '  FAIL  %s\n' "$1"; fail=1; }

status_re='^(install|hold) ok installed$'
held_list=$(
    printf '%s\n' \
        $'hold ok installed\tlinux-image-7.0.0-31-generic' \
        $'install ok installed\tlinux-image-6.8.0-40-generic' \
        $'unknown ok not-installed\tlinux-image-unsigned-7.0.0-31-generic' \
        | awk -F'\t' -v re="$status_re" '$1 ~ re {print $2}'
)
printf '%s\n' "$held_list" | grep -Fq 'linux-image-7.0.0-31-generic' \
    && printf '%s\n' "$held_list" | grep -Fq 'linux-image-6.8.0-40-generic' \
    && ! printf '%s\n' "$held_list" | grep -Fq 'linux-image-unsigned-7.0.0-31-generic' \
    && pass "dpkg status includes hold ok installed" \
    || fail_case "dpkg status includes hold ok installed"

re=$(kernel_related_grep_ere "6.5.0-14")
printf '%s\n' "linux-headers-6.5.0-14" | grep -Eq -- "$re" && pass "kernel ere matches 6.5.0-14 headers" || fail_case "kernel ere matches 6.5.0-14 headers"
printf '%s\n' "linux-headers-6.5.0-140" | grep -Eq -- "$re" && fail_case "kernel ere does not match 6.5.0-140" || pass "kernel ere does not match 6.5.0-140"
printf '%s\n' "linux-modules-extra-6.5.0-14-generic" | grep -Eq -- "$re" && pass "kernel ere matches extra-generic suffix" || fail_case "kernel ere matches extra-generic suffix"

GPU_VENDOR_PREFER=auto
nvidia_cli_ok && pass "nvidia_cli_ok auto" || fail_case "nvidia_cli_ok auto"
GPU_VENDOR_PREFER=rocm
nvidia_cli_ok && fail_case "nvidia_cli_ok rocm" || pass "nvidia_cli_ok rocm"
GPU_VENDOR_PREFER=auto

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
[[ "$GPU_PROCESS_COUNT" == "2" && "$GPU_BUSY" == "true" && "$GPU_QUERY_OK" == "true" ]] \
    && pass "rocm busy pids" || fail_case "rocm busy pids (count=${GPU_PROCESS_COUNT:-?} busy=${GPU_BUSY:-?} ok=${GPU_QUERY_OK:-?})"

cat >"$SIM/bin/rocm-smi" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
if count_gpu_compute_processes; then
    fail_case "rocm query failure was treated as success"
else
    [[ "$GPU_QUERY_OK" == "false" && "$GPU_BUSY" == "false" ]] \
        && pass "rocm query failure is unknown" \
        || fail_case "rocm query failure state (ok=${GPU_QUERY_OK:-?} busy=${GPU_BUSY:-?})"
fi

cat >"$SIM/bin/nvidia-smi" <<'EOF'
#!/usr/bin/env bash
exit 9
EOF
chmod +x "$SIM/bin/nvidia-smi"
GPU_VENDOR_PREFER=auto
if count_gpu_compute_processes; then
    fail_case "nvidia-smi failure was treated as idle"
else
    [[ "$GPU_QUERY_OK" == "false" ]] && pass "nvidia-smi failure is unknown" || fail_case "nvidia-smi failure state"
fi
cat >"$SIM/bin/nvidia-smi" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
count_gpu_compute_processes
[[ "$GPU_QUERY_OK" == "true" && "$GPU_PROCESS_COUNT" == "0" && "$GPU_BUSY" == "false" ]] \
    && pass "nvidia-smi empty success is idle" \
    || fail_case "nvidia-smi empty success (count=${GPU_PROCESS_COUNT:-?} ok=${GPU_QUERY_OK:-?})"

marker="$SIM/proxy-pwn"
rm -f "$marker"
cat >"$SIM/bin/apt-config" <<'EOF'
#!/usr/bin/env bash
printf "%s\n" "HTTP_PROXY='http://proxy.example:3128'"
EOF
chmod +x "$SIM/bin/apt-config"
unset http_proxy HTTP_PROXY https_proxy HTTPS_PROXY
load_apt_proxy_env
[[ "${http_proxy:-}" == "http://proxy.example:3128" ]] && pass "apt proxy URL loaded" || fail_case "apt proxy URL loaded (${http_proxy:-empty})"
unset http_proxy HTTP_PROXY https_proxy HTTPS_PROXY
cat >"$SIM/bin/apt-config" <<EOF
#!/usr/bin/env bash
printf "%s\n" "HTTP_PROXY='http://x'; touch ${marker}'"
EOF
load_apt_proxy_env
[[ ! -e "$marker" && -z "${http_proxy:-}" ]] && pass "apt proxy eval rejected" || fail_case "apt proxy eval rejected"
_apt_proxy_from_shell_line "HTTP_PROXY='http://ok.example/\$(id)'" >/dev/null 2>&1 \
    && fail_case "apt proxy rejects command substitution" \
    || pass "apt proxy rejects command substitution"

fleet_out=$(
    bash --noprofile --norc -c '
        set -euo pipefail
        unset SSH_STRICT_HOST_KEY_CHECKING SSH_KNOWN_HOSTS_FILE
        source "$1"
        printf "%s\n" "${SSH_OPTS[@]}" | grep -qx "StrictHostKeyChecking=yes"
        ssh_cmd() { printf "%s\n" "unknown"; }
        DRAIN_MODE=skip
        if wait_or_skip_drain node node.example ""; then
            exit 2
        fi
        ssh_cmd() { printf "%s\n" "0"; }
        wait_or_skip_drain node node.example ""
    ' bash "$ROOT/fleet/update-clean-fleet.sh"
) && pass "fleet host key default and fail-closed drain" || fail_case "fleet host key default and fail-closed drain (${fleet_out:-rc $?})"

printf '\n=== %s ===\n' "$([[ $fail -eq 0 ]] && echo 'shell units passed' || echo 'shell units failed')"
exit "$fail"
