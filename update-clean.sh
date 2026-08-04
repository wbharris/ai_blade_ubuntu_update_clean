#!/usr/bin/env bash
# AI Blade / SuperPOD (Ubuntu) - Update & Cleanup Script
# Full system update + thorough cleanup for NVIDIA AI compute blades
# (DGX, HGX, SuperPOD nodes, and other Ubuntu GPU servers).
#
# Derived from debian_ubuntu_update_clean with AI-platform awareness.
#
# Copyright (C) 2026 wbharris
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.
#
# Requirements: Bash 4+, run as root (sudo), apt-based Ubuntu/Debian
# Config: /etc/update-clean.conf, root or SUDO_USER home configs (see README)
# Logs: /var/log/update-clean/ (retention via LOG_RETENTION)
# Exit codes: 0 = success; 1 = one or more failures (count in FAILURES / EXIT_CODE)
#
# Usage: sudo ./update-clean.sh [--dry-run] [--no-kernel] [--help] [--version]
# Recommended: run weekly during maintenance windows on SuperPOD blades

set -euo pipefail
set -o errtrace

# Require Bash 4+ (mapfile, array sorting)
if [ -z "${BASH_VERSINFO:-}" ] || [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
    printf '%s\n' "This script requires Bash 4+. Found: ${BASH_VERSION:-unknown}" >&2
    exit 1
fi

umask 022

PATH="/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"
export PATH

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
if [ ! -d "$SCRIPT_DIR" ] || [ ! -r "$SCRIPT_DIR" ]; then
    printf '%s\n' "Error: Cannot access script directory: $SCRIPT_DIR" >&2
    exit 1
fi

# ────────────────────────────────────────────────────────────────
# Defaults & Config
# ────────────────────────────────────────────────────────────────
DRY_RUN=false
SKIP_KERNEL=false
DEBUG=false
SKIP_CONNECTIVITY=false
SKIP_GPU_CHECK=false
SKIP_FIRMWARE=${SKIP_FIRMWARE:-true}   # safer default on AI blades (use vendor tooling)
HOLD_NVIDIA=${HOLD_NVIDIA:-true}
DOCKER_PRUNE=${DOCKER_PRUNE:-dangling} # none|dangling|unused
GPU_ONLY=false
LOG_RETENTION=${LOG_RETENTION:-3}
KERNEL_KEEP=${KERNEL_KEEP:-2}
KERNEL_KEEP_MAX=${KERNEL_KEEP_MAX:-10}
BACKUP_MODE=${BACKUP_MODE:-false}
REBOOT_IF_REQUIRED=${REBOOT_IF_REQUIRED:-false}
LOG_DIR="${LOG_DIR:-/var/log/update-clean}"
LOCKFILE="${LOCKFILE:-/run/update-clean.lock}"
LAST_RUN_DIR="${LAST_RUN_DIR:-/var/lib/update-clean}"
# Base OS packages always held; NVIDIA packages held dynamically when HOLD_NVIDIA=true
CRITICAL_PACKAGES=(base-files base-passwd bash coreutils util-linux)
readonly SCRIPT_NAME="update-clean"
SCRIPT_VERSION=$(cat "$SCRIPT_DIR/VERSION" 2>/dev/null || echo "unknown")
readonly SCRIPT_DIR
EXIT_CODE=0
KERNELS_REMOVED=false
AI_PLATFORM="unknown"
AI_PLATFORM_DETAIL=""
GPU_COUNT=0
GPU_BUSY=false
GPU_PROCESS_COUNT=0
NVIDIA_DRIVER=""
CUDA_VERSION=""

# Thresholds and retry limits (override via env if needed)
readonly MIN_DISK_KB=${MIN_DISK_KB:-2097152}       # 2 GB root/var/boot
readonly MIN_LOG_DIR_KB=${MIN_LOG_DIR_KB:-1024}    # 1 MB
readonly BOOT_MIN_KB=${BOOT_MIN_KB:-10240}         # 10 MB — skip kernel removal
readonly BOOT_LOW_KB=${BOOT_LOW_KB:-51200}         # 50 MB — low /boot warning
readonly APT_UPDATE_MAX_RETRIES=${APT_UPDATE_MAX_RETRIES:-3}
# AI blades often store container images under /var — warn if low
readonly VAR_LOW_KB=${VAR_LOW_KB:-10485760}        # 10 GB low /var warning

# CLI override markers (explicit flags win over config file)
CLI_KERNEL_KEEP=""
CLI_DRY_RUN=false
CLI_SKIP_KERNEL=false
CLI_SKIP_CONNECTIVITY=false
CLI_REBOOT_IF_REQUIRED=false
CLI_DEBUG=false
CLI_SKIP_GPU_CHECK=false
CLI_SKIP_FIRMWARE=""
CLI_HOLD_NVIDIA=""
CLI_DOCKER_PRUNE=""
CLI_GPU_ONLY=false

# ────────────────────────────────────────────────────────────────
# Colors (TTY-aware)
# ────────────────────────────────────────────────────────────────
if [ -t 1 ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    NC='\033[0m'
else
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    NC=''
fi

log()     { printf '%b\n' "[$(date '+%Y-%m-%d %H:%M:%S')] $1"; }
info()    { printf '%b\n' "${BLUE}[INFO]${NC} $1"; }
success() { printf '%b\n' "${GREEN}[SUCCESS]${NC} $1"; }
warn()    { printf '%b\n' "${YELLOW}[WARNING]${NC} $1"; }
error()   { printf '%b\n' "${RED}[ERROR]${NC} $1"; }

_record_failure() { EXIT_CODE=$((EXIT_CODE + 1)); }

has_cmd() { command -v "$1" >/dev/null 2>&1; }

require_cmds() {
    local -a cmds=(apt-get dpkg awk sed grep tar mktemp flock)
    local cmd
    for cmd in "${cmds[@]}"; do
        if ! has_cmd "$cmd"; then
            error "Required command missing: $cmd"
            exit 1
        fi
    done
}

load_config_files() {
    local conf owner
    local -a confs=(/etc/update-clean.conf)

    if [ "$EUID" -eq 0 ]; then
        confs+=("/root/.config/update-clean.conf" "/root/.update-clean.conf")
        if [ -n "${SUDO_USER:-}" ] && [ -d "/home/$SUDO_USER" ]; then
            confs+=(
                "/home/$SUDO_USER/.config/update-clean.conf"
                "/home/$SUDO_USER/.update-clean.conf"
            )
        fi
    else
        confs+=("$HOME/.config/update-clean.conf" "$HOME/.update-clean.conf")
    fi

    for conf in "${confs[@]}"; do
        [ -f "$conf" ] || continue
        if [[ "$conf" == /etc/* ]]; then
            owner=$(stat -c %u "$conf" 2>/dev/null || echo "invalid")
            if ! [[ "$owner" =~ ^[0-9]+$ ]] || [ "$owner" != "0" ]; then
                warn "Config $conf not owned by root (uid=$owner); skipping"
                continue
            fi
        fi
        if [ ! -r "$conf" ]; then
            warn "Config $conf is not readable; skipping"
            continue
        fi
        # shellcheck source=/dev/null
        source "$conf"
    done
}

validate_config_values() {
    if ! [[ "$LOG_RETENTION" =~ ^[0-9]+$ ]] || [ "$LOG_RETENTION" -lt 0 ]; then
        warn "Invalid LOG_RETENTION='$LOG_RETENTION', using default 3"
        LOG_RETENTION=3
    fi
    if ! [[ "$KERNEL_KEEP" =~ ^[0-9]+$ ]] || [ "$KERNEL_KEEP" -lt 0 ]; then
        warn "Invalid KERNEL_KEEP='$KERNEL_KEEP', using default 2"
        KERNEL_KEEP=2
    elif [ "$KERNEL_KEEP" -gt "$KERNEL_KEEP_MAX" ]; then
        warn "KERNEL_KEEP=$KERNEL_KEEP exceeds max $KERNEL_KEEP_MAX, using $KERNEL_KEEP_MAX"
        KERNEL_KEEP=$KERNEL_KEEP_MAX
    fi
    case "${DOCKER_PRUNE,,}" in
        none|dangling|unused|all) ;;
        *)
            warn "Invalid DOCKER_PRUNE='$DOCKER_PRUNE', using dangling"
            DOCKER_PRUNE=dangling
            ;;
    esac
    case "${SKIP_FIRMWARE,,}" in
        true|false|yes|no|1|0) ;;
        *)
            warn "Invalid SKIP_FIRMWARE='$SKIP_FIRMWARE', using true"
            SKIP_FIRMWARE=true
            ;;
    esac
    case "${HOLD_NVIDIA,,}" in
        true|false|yes|no|1|0) ;;
        *)
            warn "Invalid HOLD_NVIDIA='$HOLD_NVIDIA', using true"
            HOLD_NVIDIA=true
            ;;
    esac
}

truthy() {
    case "${1,,}" in
        true|yes|1|on) return 0 ;;
        *) return 1 ;;
    esac
}

apply_cli_config_overrides() {
    # Explicit CLI flags override values loaded from config files
    [ -n "$CLI_KERNEL_KEEP" ] && KERNEL_KEEP="$CLI_KERNEL_KEEP"
    $CLI_DRY_RUN && DRY_RUN=true
    $CLI_SKIP_KERNEL && SKIP_KERNEL=true
    $CLI_SKIP_CONNECTIVITY && SKIP_CONNECTIVITY=true
    $CLI_REBOOT_IF_REQUIRED && REBOOT_IF_REQUIRED=true
    $CLI_DEBUG && DEBUG=true
    $CLI_SKIP_GPU_CHECK && SKIP_GPU_CHECK=true
    $CLI_GPU_ONLY && GPU_ONLY=true
    [ -n "$CLI_SKIP_FIRMWARE" ] && SKIP_FIRMWARE="$CLI_SKIP_FIRMWARE"
    [ -n "$CLI_HOLD_NVIDIA" ] && HOLD_NVIDIA="$CLI_HOLD_NVIDIA"
    [ -n "$CLI_DOCKER_PRUNE" ] && DOCKER_PRUNE="$CLI_DOCKER_PRUNE"
}

# ────────────────────────────────────────────────────────────────
# Helpers
# ────────────────────────────────────────────────────────────────
get_avail_kb() {
    local part="$1"
    local val

    val=$(df -B 1K "$part" 2>/dev/null | awk 'NR==2 {print $4+0}')
    printf '%d' "${val:-0}"
}

get_used_kb_for_paths() {
    local sum

    sum=$(df -B 1K "$@" 2>/dev/null | awk 'NR>1 {s+=$3} END {print s+0}')
    printf '%d' "${sum:-0}"
}

check_partition_space() {
    local part="$1" min_kb="${2:-$MIN_DISK_KB}"
    local avail_kb

    [ -d "$part" ] || return 0
    avail_kb=$(get_avail_kb "$part")
    if [ "$avail_kb" -lt "$min_kb" ]; then
        if [ "$min_kb" -ge 1048576 ]; then
            error "Less than $((min_kb / 1024 / 1024)) GB free on $part"
        else
            error "Less than $((min_kb / 1024)) MB free on $part"
        fi
        return 1
    fi
    return 0
}

warn_low_partition_space() {
    local part="$1" min_kb="$2"
    local avail_kb

    [ -d "$part" ] || return 0
    avail_kb=$(get_avail_kb "$part")
    if [ "$avail_kb" -lt "$min_kb" ]; then
        warn "Very low space on $part (< $((min_kb / 1024)) MB). Kernel updates may fail."
    fi
}

report_partition_space() {
    local part="$1" min_kb="${2:-$MIN_DISK_KB}"
    local avail_kb

    [ -d "$part" ] || return 0
    avail_kb=$(get_avail_kb "$part")
    printf 'Disk space on %s: ' "$part"
    if [ "$avail_kb" -ge "$min_kb" ]; then
        printf 'OK (%s MB free)\n' "$((avail_kb / 1024))"
    else
        printf 'LOW (%s MB free)\n' "$((avail_kb / 1024))"
    fi
}

calc_disk_freed_mb() {
    local before="$1" after="$2"
    local freed_kb=$((before - after))
    awk "BEGIN {printf \"%.2f\", $freed_kb / 1024 }"
}

log_to_syslog() {
    if has_cmd logger; then
        logger -t "$SCRIPT_NAME" -p user.info -- "$1"
    fi
}

dump_debug_state() {
    $DEBUG || return
    printf 'DEBUG STATE:\n'
    printf '  KERNEL_KEEP=%s SKIP_KERNEL=%s DRY_RUN=%s DEBUG=%s\n' \
        "${KERNEL_KEEP:-}" "${SKIP_KERNEL:-}" "${DRY_RUN:-}" "${DEBUG:-}"
    printf '  LOG_DIR=%s\n  LOG_FILE=%s\n  APT_LOG=%s\n' \
        "${LOG_DIR:-<unset>}" "${LOG_FILE:-<unset>}" "${APT_LOG:-<unset>}"
    printf '  DISTRO=%s ARCHIVE_HOST=%s SKIP_CONNECTIVITY=%s\n' \
        "${DISTRO_NAME:-<unset>}" "${ARCHIVE_HOST:-<unset>}" "${SKIP_CONNECTIVITY:-}"
    printf '  AI_PLATFORM=%s SKIP_FIRMWARE=%s HOLD_NVIDIA=%s DOCKER_PRUNE=%s\n' \
        "${AI_PLATFORM:-}" "${SKIP_FIRMWARE:-}" "${HOLD_NVIDIA:-}" "${DOCKER_PRUNE:-}"
}

format_cmd_args() {
    local -a args=("$@")
    local out="" arg
    for arg in "${args[@]}"; do
        out+="$(printf '%q' "$arg") "
    done
    printf '%s' "${out%" "}"
}

# is_apt_locked: returns 0 if an apt/dpkg lock is held, 1 if unlocked.
# (Return 0 means "locked" — inverted from typical "success = free" wording.)
is_apt_locked() {
    local locks=(
        /var/lib/dpkg/lock-frontend
        /var/lib/dpkg/lock
        /var/lib/apt/lists/lock
        /var/cache/apt/archives/lock
    )
    local lock

    if has_cmd fuser; then
        for lock in "${locks[@]}"; do
            if [ -e "$lock" ] && fuser "$lock" >/dev/null 2>&1; then
                return 0
            fi
        done
        return 1
    fi

    if has_cmd lsof; then
        for lock in "${locks[@]}"; do
            if [ -e "$lock" ] && lsof "$lock" >/dev/null 2>&1; then
                return 0
            fi
        done
        return 1
    fi

    for lock in "${locks[@]}"; do
        if [ -e "$lock" ]; then
            return 0
        fi
    done
    return 1
}

list_installed_kernel_images() {
    dpkg-query -W -f='${Status}\t${Package}\n' 'linux-image-*' 2>/dev/null \
        | awk -F'\t' '$1 ~ /^install ok installed/ {print $2}' \
        | grep -E '^linux-image(-unsigned)?-[0-9][0-9a-zA-Z.\-+]*' \
        | grep -Ev -- '-(meta|dbg|dbgsym|rt|cloud|kvm|virtual)$' \
        | grep -Ev 'linux-image-(generic|generic-hwe|amd64)(-lts|-hwe)?$' \
        | sort -V
}

create_etc_backup() {
    local backup_file old_umask

    info "BACKUP_MODE: Creating backup of /etc before purging configs"
    if ! mkdir -p /var/backups; then
        warn "Cannot create /var/backups"
        return 1
    fi

    backup_file="/var/backups/etc-before-cleanup-$(date +%Y%m%d-%H%M%S).tar.gz"
    old_umask=$(umask)
    umask 077
    if tar --one-file-system \
        --exclude='/etc/ssl/private' \
        -czf "$backup_file" /etc/ 2>/dev/null; then
        chmod 600 "$backup_file"
        info "Backup saved to $backup_file"
    else
        warn "Backup of /etc failed"
        umask "$old_umask"
        return 1
    fi
    umask "$old_umask"
}

detect_distro() {
    if [ -f /etc/os-release ]; then
        # shellcheck source=/dev/null
        . /etc/os-release
        DISTRO_ID="${ID:-unknown}"
        DISTRO_NAME="${PRETTY_NAME:-$DISTRO_ID}"
        DISTRO_VERSION="${VERSION_ID:-}"
    else
        DISTRO_ID="unknown"
        DISTRO_NAME="Unknown"
        DISTRO_VERSION=""
    fi

    case "$DISTRO_ID" in
        debian)
            ARCHIVE_HOST="deb.debian.org"
            ;;
        ubuntu)
            ARCHIVE_HOST="archive.ubuntu.com"
            ;;
        kali)
            ARCHIVE_HOST="archive.kali.org"
            ;;
        *)
            ARCHIVE_HOST=""
            ;;
    esac

    ARCHIVE_HOST="${ARCHIVE_HOST:-deb.debian.org}"
}


# ────────────────────────────────────────────────────────────────
# AI blade / SuperPOD platform detection & GPU health
# ────────────────────────────────────────────────────────────────
detect_ai_platform() {
    AI_PLATFORM="generic-ubuntu"
    AI_PLATFORM_DETAIL=""
    local product="" board="" dgx_ver=""

    if [ -f /etc/dgx-release ]; then
        AI_PLATFORM="dgx"
        dgx_ver=$(grep -E '^DGX_SWBUILD_VERSION|^DGX_OTA_VERSION|^DGX_NAME' /etc/dgx-release 2>/dev/null | tr '\n' ' ' | sed 's/[[:space:]]*$//')
        AI_PLATFORM_DETAIL="${dgx_ver:-DGX OS}"
    fi

    if has_cmd dmidecode; then
        product=$(dmidecode -s system-product-name 2>/dev/null | tr -d '\r' | head -n1 || true)
        board=$(dmidecode -s baseboard-product-name 2>/dev/null | tr -d '\r' | head -n1 || true)
    elif [ -r /sys/class/dmi/id/product_name ]; then
        product=$(tr -d '\0' </sys/class/dmi/id/product_name 2>/dev/null || true)
        board=$(tr -d '\0' </sys/class/dmi/id/board_name 2>/dev/null || true)
    fi

    local blob
    blob=$(printf '%s %s %s' "$product" "$board" "$AI_PLATFORM_DETAIL" | tr '[:upper:]' '[:lower:]')

    if [[ "$blob" == *superpod* ]] || [[ "$blob" == *super-pod* ]]; then
        AI_PLATFORM="superpod"
        AI_PLATFORM_DETAIL="${product:-SuperPOD} ${board}"
    elif [[ "$blob" == *dgx* ]]; then
        AI_PLATFORM="dgx"
        AI_PLATFORM_DETAIL="${AI_PLATFORM_DETAIL:-$product}"
    elif [[ "$blob" == *hgx* ]] || [[ "$blob" == *grace* ]] || [[ "$blob" == *hopper* ]] || [[ "$blob" == *blackwell* ]]; then
        AI_PLATFORM="hgx"
        AI_PLATFORM_DETAIL="${product:-HGX} ${board}"
    elif has_cmd nvidia-smi || [ -e /dev/nvidia0 ] || [ -d /sys/module/nvidia ]; then
        if [ "$AI_PLATFORM" = "generic-ubuntu" ]; then
            AI_PLATFORM="nvidia-gpu"
            AI_PLATFORM_DETAIL="${product:-NVIDIA GPU host}"
        fi
    fi

    AI_PLATFORM_DETAIL=$(printf '%s' "$AI_PLATFORM_DETAIL" | sed 's/[[:space:]]*$//')
}

query_nvidia_driver() {
    NVIDIA_DRIVER=""
    CUDA_VERSION=""
    GPU_COUNT=0

    if ! has_cmd nvidia-smi; then
        return 1
    fi

    NVIDIA_DRIVER=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -n1 | tr -d '[:space:]' || true)
    CUDA_VERSION=$(nvidia-smi 2>/dev/null | awk -F'CUDA Version: ' '/CUDA Version:/ {print $2}' | awk '{print $1}' | head -n1 || true)
    GPU_COUNT=$(nvidia-smi -L 2>/dev/null | grep -c '^GPU ' || true)
    GPU_COUNT=${GPU_COUNT:-0}
    return 0
}

count_gpu_compute_processes() {
    GPU_PROCESS_COUNT=0
    GPU_BUSY=false

    if ! has_cmd nvidia-smi; then
        return 0
    fi

    # Prefer compute-apps query; fall back to pmon-style parse
    local apps
    apps=$(nvidia-smi --query-compute-apps=pid --format=csv,noheader,nounits 2>/dev/null | sed '/^[[:space:]]*$/d' | wc -l || true)
    apps=${apps// /}
    if [[ "$apps" =~ ^[0-9]+$ ]]; then
        GPU_PROCESS_COUNT=$apps
    else
        GPU_PROCESS_COUNT=0
    fi

    if [ "$GPU_PROCESS_COUNT" -gt 0 ]; then
        GPU_BUSY=true
    fi
}

report_gpu_health() {
    info "=== AI blade / GPU health ==="
    info "Platform: $AI_PLATFORM${AI_PLATFORM_DETAIL:+ ($AI_PLATFORM_DETAIL)}"

    if ! has_cmd nvidia-smi; then
        warn "nvidia-smi not found — no NVIDIA driver tooling on PATH"
        if [ -e /dev/nvidia0 ]; then
            warn "/dev/nvidia0 exists but nvidia-smi missing (broken driver install?)"
        fi
        return 0
    fi

    if ! query_nvidia_driver; then
        warn "nvidia-smi present but failed to query GPUs"
        _record_failure
        return 1
    fi

    info "NVIDIA driver: ${NVIDIA_DRIVER:-unknown}"
    info "CUDA (reported by driver): ${CUDA_VERSION:-unknown}"
    info "GPU count: $GPU_COUNT"

    if [ "$GPU_COUNT" -gt 0 ]; then
        info "GPU inventory:"
        nvidia-smi -L 2>/dev/null | while IFS= read -r line; do
            info "  $line"
        done || true

        info "GPU utilization / memory (snapshot):"
        nvidia-smi --query-gpu=index,name,temperature.gpu,utilization.gpu,utilization.memory,memory.used,memory.total,power.draw \
            --format=csv 2>/dev/null | while IFS= read -r line; do
            info "  $line"
        done || true
    fi

    count_gpu_compute_processes
    if $GPU_BUSY; then
        warn "GPU compute processes active: $GPU_PROCESS_COUNT (training/inference in progress)"
        nvidia-smi --query-compute-apps=gpu_uuid,pid,process_name,used_gpu_memory \
            --format=csv 2>/dev/null | while IFS= read -r line; do
            warn "  $line"
        done || true
    else
        success "No active GPU compute processes detected"
    fi

    # Fabric Manager (NVSwitch / multi-GPU HGX / SuperPOD blades)
    if has_cmd systemctl; then
        if systemctl list-unit-files nvidia-fabricmanager.service >/dev/null 2>&1 \
            || systemctl status nvidia-fabricmanager >/dev/null 2>&1; then
            local fm
            fm=$(systemctl is-active nvidia-fabricmanager 2>/dev/null || echo "unknown")
            info "nvidia-fabricmanager: $fm"
            if [ "$fm" != "active" ] && [ "$GPU_COUNT" -gt 1 ]; then
                warn "Fabric Manager not active on multi-GPU node — NVLink/NVSwitch fabric may be degraded"
            fi
        fi
        if systemctl list-unit-files nvidia-persistenced.service >/dev/null 2>&1 \
            || systemctl status nvidia-persistenced >/dev/null 2>&1; then
            info "nvidia-persistenced: $(systemctl is-active nvidia-persistenced 2>/dev/null || echo unknown)"
        fi
        if systemctl list-unit-files nvidia-dcgm.service >/dev/null 2>&1 \
            || systemctl status nvidia-dcgm >/dev/null 2>&1; then
            info "nvidia-dcgm: $(systemctl is-active nvidia-dcgm 2>/dev/null || echo unknown)"
        fi
    fi

    if has_cmd dcgmi; then
        info "DCGM discovery (short):"
        dcgmi discovery -l 2>/dev/null | head -n 40 | while IFS= read -r line; do
            info "  $line"
        done || warn "dcgmi discovery failed"
    fi

    # InfiniBand / SuperPOD fabric peek (Mellanox OFED / MLNX_OFED)
    if has_cmd ibstat; then
        info "InfiniBand adapters (ibstat summary):"
        ibstat 2>/dev/null | awk '/^CA |^[[:space:]]*State:|^[[:space:]]*Rate:|^[[:space:]]*Physical state:/ {print}' | head -n 40 | while IFS= read -r line; do
            info "  $line"
        done || true
    elif has_cmd ibv_devinfo; then
        info "RDMA devices:"
        ibv_devinfo -l 2>/dev/null | while IFS= read -r line; do
            info "  $line"
        done || true
    fi

    if has_cmd nvidia-container-cli; then
        info "NVIDIA Container Toolkit: present (nvidia-container-cli)"
    elif has_cmd nvidia-ctk; then
        info "NVIDIA Container Toolkit: present (nvidia-ctk)"
    fi

    if has_cmd docker; then
        info "Docker: $(docker --version 2>/dev/null | head -n1)"
        if docker info 2>/dev/null | grep -qi 'Runtimes:.*nvidia\|nvidia'; then
            info "Docker NVIDIA runtime: available"
        fi
    fi

    info "=== End GPU health ==="
}

list_nvidia_hold_packages() {
    # Installed packages that should not be auto-removed on AI blades
    dpkg-query -W -f='${Status}\t${Package}\n' \
        'nvidia-*' 'libnvidia-*' 'cuda-*' 'libcuda*' 'nsight-*' \
        'datacenter-gpu-manager*' 'fabricmanager*' 'nv-fabricmanager*' \
        2>/dev/null \
        | awk -F'\t' '$1 ~ /^install ok installed/ {print $2}' \
        | sort -u
}

hold_nvidia_packages() {
    local -a pkgs=()
    local p

    truthy "$HOLD_NVIDIA" || {
        info "HOLD_NVIDIA disabled — not holding NVIDIA packages"
        return 0
    }

    mapfile -t pkgs < <(list_nvidia_hold_packages)
    if [ "${#pkgs[@]}" -eq 0 ]; then
        info "No NVIDIA/CUDA packages found to hold"
        return 0
    fi

    info "Holding ${#pkgs[@]} NVIDIA/CUDA-related package(s) during cleanup..."
    if $DRY_RUN; then
        for p in "${pkgs[@]:0:15}"; do
            info "DRY-RUN: would apt-mark hold $p"
        done
        [ "${#pkgs[@]}" -gt 15 ] && info "DRY-RUN: ... and $((${#pkgs[@]} - 15)) more"
        return 0
    fi

    # apt-mark hold accepts multiple packages; batch to avoid arg limits
    local i batch=40
    for ((i = 0; i < ${#pkgs[@]}; i += batch)); do
        apt-mark hold "${pkgs[@]:i:batch}" 2>/dev/null || true
    done
}

docker_cleanup() {
    local mode="${DOCKER_PRUNE,,}"

    if ! has_cmd docker; then
        return 0
    fi

    if [ "$mode" = "none" ]; then
        info "Docker prune skipped (DOCKER_PRUNE=none)"
        return 0
    fi

    if ! docker info >/dev/null 2>&1; then
        warn "Docker present but daemon not reachable; skipping prune"
        return 0
    fi

    if $DRY_RUN; then
        info "DRY-RUN: would docker prune mode=$mode"
        return 0
    fi

    case "$mode" in
        dangling)
            info "Pruning dangling Docker images (safe default for AI blades)..."
            docker image prune -f 2>&1 | tee -a "${APT_LOG:-/dev/null}" || _record_failure
            ;;
        unused)
            info "Pruning unused Docker images (not referenced by containers)..."
            docker image prune -a -f 2>&1 | tee -a "${APT_LOG:-/dev/null}" || _record_failure
            docker container prune -f 2>&1 | tee -a "${APT_LOG:-/dev/null}" || true
            docker network prune -f 2>&1 | tee -a "${APT_LOG:-/dev/null}" || true
            ;;
        all)
            warn "DOCKER_PRUNE=all: aggressive prune (volumes excluded for safety)"
            docker system prune -a -f 2>&1 | tee -a "${APT_LOG:-/dev/null}" || _record_failure
            ;;
    esac
}

guard_reboot_if_gpus_busy() {
    # Called when reboot is requested; returns 1 to block reboot
    count_gpu_compute_processes
    if $GPU_BUSY; then
        error "Refusing reboot: $GPU_PROCESS_COUNT GPU compute process(es) still running"
        error "Drain workloads or re-run with maintenance window; use --offline after drain if needed"
        return 1
    fi
    return 0
}

check_debian_based() {
    if ! has_cmd apt; then
        error "This script requires apt and is intended for Debian-based systems."
        exit 1
    fi

    case "$DISTRO_ID" in
        debian*|ubuntu|kali*|linuxmint|pop|elementary|zorin|kubuntu|xubuntu|lubuntu|mint|*ubuntu*)
            return 0
            ;;
        *)
            warn "Unsupported or unknown distro '$DISTRO_ID'. Proceeding anyway (apt-based assumed)."
            ;;
    esac
}

check_connectivity() {
    local host="${ARCHIVE_HOST:-deb.debian.org}"

    if has_cmd curl; then
        if curl -sSf --connect-timeout 5 "https://${host}/" >/dev/null 2>&1; then
            return 0
        fi
    elif has_cmd wget; then
        if wget -q --timeout=5 --spider "https://${host}/" >/dev/null 2>&1; then
            return 0
        fi
    fi

    if has_cmd getent && getent hosts "$host" >/dev/null 2>&1; then
        warn "HTTPS check failed but DNS resolves for $host; proceeding."
        return 0
    fi

    if has_cmd ping; then
        if ping -c 1 -W 3 "$host" >/dev/null 2>&1; then
            warn "Could not reach https://${host} but host responds to ping; proceeding."
            return 0
        fi
        if ping -c 1 -W 3 8.8.8.8 >/dev/null 2>&1; then
            warn "Could not reach $host but internet ping (8.8.8.8) succeeded; proceeding."
            return 0
        fi
    fi

    return 1
}

find_running_kernel_pkg() {
    local running_ver="$1"
    shift
    local pkg vmlinuz
    local -a candidates=("$@")

    [ -z "$running_ver" ] && return 1

    vmlinuz="/boot/vmlinuz-${running_ver}"
    if [ -f "$vmlinuz" ]; then
        pkg=$(dpkg-query -S "$vmlinuz" 2>/dev/null | awk -F: '{print $1}' | head -n1)
        if [ -n "$pkg" ]; then
            printf '%s' "$pkg"
            return 0
        fi
    fi

    if [ "${#candidates[@]}" -eq 0 ]; then
        mapfile -t candidates < <(list_installed_kernel_images)
    fi

    for pkg in "${candidates[@]}"; do
        if [[ "$pkg" == *"$running_ver"* ]]; then
            printf '%s' "$pkg"
            return 0
        fi
    done

    return 1
}

purge_kernel_related() {
    local pkg="$1"
    local ver suffix candidate related

    if [[ "$pkg" =~ ^linux-image-(.+)$ ]]; then
        ver="${BASH_REMATCH[1]}"
        for suffix in headers modules-extra modules modules-unsigned; do
            candidate="linux-${suffix}-${ver}"
            if dpkg-query -W -f='${Status}' "$candidate" 2>/dev/null | grep -q 'install ok installed'; then
                apt_run purge "$candidate" || true
            fi
        done
        while IFS= read -r related; do
            [ -z "$related" ] || [ "$related" = "$pkg" ] && continue
            apt_run purge "$related" || true
        done < <(
            dpkg-query -W -f='${Package}\n' 2>/dev/null \
                | grep -E '^linux-(headers|modules)' \
                | grep -F -- "$ver" || true
        )
    fi
}

apt_run() {
    local -a args=("$@")
    local apt_log="${APT_LOG:-/dev/null}"

    if $DRY_RUN; then
        info "DRY-RUN: would run: apt-get -y $(format_cmd_args "${args[@]}")"
        return 0
    fi

    local -a cmd=(
        apt-get
        -o Dpkg::Options::="--force-confdef"
        -o Dpkg::Options::="--force-confold"
        -y
        "${args[@]}"
    )

    # pipefail ensures apt-get exit code is preserved through tee
    if ! DEBIAN_FRONTEND=noninteractive "${cmd[@]}" 2>&1 | tee -a "$apt_log"; then
        _record_failure
        return 1
    fi
    return 0
}

apt_get_update_with_retries() {
    local attempt=0
    local apt_log="${APT_LOG:-/dev/null}"

    while :; do
        if apt-get update 2>&1 | tee -a "$apt_log"; then
            return 0
        fi
        attempt=$((attempt + 1))
        if [ "$attempt" -ge "$APT_UPDATE_MAX_RETRIES" ]; then
            return 1
        fi
        warn "apt-get update failed, retrying (attempt $((attempt + 1))/$APT_UPDATE_MAX_RETRIES)..."
        sleep $((attempt * 2))
    done
}

remove_old_kernels() {
    local -a kernels=()
    local -a to_remove=()
    local running_pkg running_ver pkg delcount boot_kb keep

    if [ -d /boot ]; then
        boot_kb=$(get_avail_kb /boot)
        if [ "$boot_kb" -lt "$BOOT_MIN_KB" ]; then
            warn "Skipping kernel removal: /boot has less than $((BOOT_MIN_KB / 1024)) MB free"
            return 0
        fi
    fi

    mapfile -t kernels < <(list_installed_kernel_images)

    running_ver=$(uname -r 2>/dev/null || true)
    running_pkg=$(find_running_kernel_pkg "$running_ver" "${kernels[@]}" || true)

    if [ -n "$running_pkg" ]; then
        info "Running kernel package: $running_pkg ($running_ver)"
    elif [ -n "$running_ver" ]; then
        warn "Could not match installed package for running kernel $running_ver; skipping kernel removal"
        return 0
    fi

    if [ "${#kernels[@]}" -eq 0 ]; then
        info "No linux-image packages found."
        return 0
    fi

    for pkg in "${kernels[@]}"; do
        if [ -n "$running_pkg" ] && [ "$pkg" = "$running_pkg" ]; then
            continue
        fi
        if [ -n "$running_ver" ] && [[ "$pkg" == *"$running_ver"* ]]; then
            continue
        fi
        to_remove+=("$pkg")
    done

    keep="${KERNEL_KEEP:-2}"

    if [ "${#to_remove[@]}" -le "$keep" ]; then
        info "No old kernels to remove (keeping $keep beside running kernel)."
        return 0
    fi

    delcount=$(( ${#to_remove[@]} - keep ))
    if [ "$delcount" -lt 1 ] || [ "$delcount" -gt "${#to_remove[@]}" ]; then
        warn "Kernel removal count out of range; skipping removal"
        return 0
    fi
    KERNELS_REMOVED=true

    info "Kernels scheduled for removal ($delcount):"
    for pkg in "${to_remove[@]:0:delcount}"; do
        info "  $pkg"
    done

    for pkg in "${to_remove[@]:0:delcount}"; do
        if $DRY_RUN; then
            info "DRY-RUN: Would purge old kernel: $pkg"
            continue
        fi
        info "Purging old kernel: $pkg"
        apt_run purge "$pkg" || warn "Failed to purge $pkg"
        purge_kernel_related "$pkg"
    done
}

show_dry_run_preview() {
    local apt_log="${APT_LOG:-/dev/null}"

    info "DRY-RUN preview: upgradable packages (read-only)"
    apt list --upgradable 2>/dev/null | sed -n '1,40p' || true
    info "DRY-RUN preview: autoremove simulation (read-only)"
    apt-get -s --purge autoremove 2>&1 | sed -n '1,40p' | tee -a "$apt_log" || true
}

rotate_old_logs() {
    local keep="$1"
    local -a files=()
    local i

    [ "$keep" -le 0 ] && return
    [ -d "$LOG_DIR" ] || return

    if find "$LOG_DIR" -maxdepth 0 -printf '%T@\n' >/dev/null 2>&1; then
        mapfile -t files < <(
            find "$LOG_DIR" -maxdepth 1 -type f -name 'update-clean-*.log' -printf '%T@ %p\n' 2>/dev/null \
                | sort -nr | awk '{print $2}'
        )
    else
        while IFS= read -r file; do
            [ -z "$file" ] && continue
            files+=("$file")
        done < <(ls -1t "$LOG_DIR"/update-clean-*.log 2>/dev/null || true)
    fi

    for ((i = keep; i < ${#files[@]}; i++)); do
        rm -f "${files[i]}" || warn "Failed to remove old log ${files[i]}"
    done
}

flatpak_update() {
    if flatpak update --help 2>&1 | grep -q assumeyes; then
        flatpak update --assumeyes "$@"
    else
        flatpak update -y "$@"
    fi
}

flatpak_uninstall_unused() {
    if flatpak uninstall --help 2>&1 | grep -q assumeyes; then
        flatpak uninstall --unused --assumeyes "$@"
    else
        flatpak uninstall --unused -y "$@"
    fi
}

remove_disabled_snaps() {
    local name rev

    if has_cmd jq; then
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            name="${line%% *}"
            rev="${line##* }"
            snap remove "$name" --revision="$rev" 2>/dev/null || true
        done < <(
            snap list --all --format=json 2>/dev/null \
                | jq -r '.[] | select(.notes[]? == "disabled") | "\(.name) \(.revision)"' 2>/dev/null || true
        )
        return
    fi

    while IFS= read -r name rev; do
        [ -z "$name" ] && continue
        snap remove "$name" --revision="$rev" 2>/dev/null || true
    done < <(snap list --all 2>/dev/null | awk '$NF == "disabled" {print $1, $3}' || true)
}

hold_critical_packages() {
    local curpkg
    local -a to_hold=()

    curpkg=$(find_running_kernel_pkg "$(uname -r)" || true)
    to_hold=("${CRITICAL_PACKAGES[@]}")
    [ -n "$curpkg" ] && to_hold+=("$curpkg")
    [ "${#to_hold[@]}" -eq 0 ] && return 0
    apt-mark hold "${to_hold[@]}" 2>/dev/null || true
}

send_completion_notification() {
    local msg="$1"

    if has_cmd notify-send && [ -n "${DISPLAY:-}" ]; then
        notify-send "Update & Cleanup" "$msg" 2>/dev/null || true
    fi

    if [ -n "${ADMIN_EMAIL:-}" ] && has_cmd mail; then
        printf '%s\n' "$msg" | mail -s "$SCRIPT_NAME completion" "$ADMIN_EMAIL" 2>/dev/null || true
    fi
}

safe_run() {
    local desc="$1"
    shift
    info "$desc"
    if ! "$@"; then
        warn "$desc failed — continuing"
        _record_failure
    fi
}

check_systemd_resolved() {
    if has_cmd systemctl && systemctl is-active --quiet systemd-resolved 2>/dev/null; then
        return 0
    fi
    return 1
}

# ────────────────────────────────────────────────────────────────
# CLI Parsing (do this very early, before logging or heavy work)
# ────────────────────────────────────────────────────────────────
usage() {
    cat << USAGE
Usage: sudo $0 [options]

Options:
  --dry-run         Simulate actions without making changes
  --no-kernel       Skip old kernel removal
  --keep-kernels N  Keep N kernels besides running (default: 2; 0 = only running)
  --reboot-if-required  Reboot automatically when required (blocked if GPUs busy)
  --offline         Skip internet connectivity checks
  --no-gpu-check    Skip NVIDIA GPU health / busy checks
  --gpu-only        Report AI blade / GPU health only, then exit
  --no-firmware     Skip fwupd firmware updates (default on AI blades)
  --with-firmware   Allow fwupd firmware updates
  --no-hold-nvidia  Do not apt-mark hold NVIDIA/CUDA packages during cleanup
  --docker-prune MODE  none|dangling|unused|all (default: dangling)
  --last, --status  Show information from the last run
  --check, --doctor Run pre-flight checks only (no updates)
  --debug           Enable shell trace (set -x) for troubleshooting
  --help, -h        Show this help
  --version, -v     Show version information

Environment / Config:
  LOG_RETENTION     Number of logs to keep (default: 3)
  KERNEL_KEEP       Kernels to keep besides running (default: 2, max 10)
  LOG_DIR           Log directory (default: /var/log/update-clean)
  LOCKFILE          Instance lock file (default: /run/update-clean.lock)
  LAST_RUN_DIR      Last-run record directory (default: /var/lib/update-clean)
  BACKUP_MODE       Backup /etc before purging configs (default: false)
  REBOOT_IF_REQUIRED Reboot automatically if required (default: false)
  SKIP_FIRMWARE     Skip fwupd (default: true on AI blades)
  HOLD_NVIDIA       Hold NVIDIA/CUDA packages during cleanup (default: true)
  DOCKER_PRUNE      none|dangling|unused|all (default: dangling)
  ADMIN_EMAIL       Optional email address for completion notification
  CRITICAL_PACKAGES Array of packages to hold during cleanup

Target platforms:
  NVIDIA DGX / DGX OS, HGX blades, SuperPOD compute nodes, Ubuntu GPU servers
USAGE
}

show_version() {
    detect_distro
    detect_ai_platform
    query_nvidia_driver || true
    printf '%s %s\n' "$SCRIPT_NAME" "$SCRIPT_VERSION"
    printf 'Distro: %s\n' "$DISTRO_NAME"
    printf 'AI platform: %s%s\n' "$AI_PLATFORM" "${AI_PLATFORM_DETAIL:+ ($AI_PLATFORM_DETAIL)}"
    if [ -n "$NVIDIA_DRIVER" ]; then
        printf 'NVIDIA driver: %s  CUDA: %s  GPUs: %s\n'             "$NVIDIA_DRIVER" "${CUDA_VERSION:-?}" "$GPU_COUNT"
    fi

    if [ -d "$SCRIPT_DIR/.git" ]; then
        local commit
        commit=$(git -C "$SCRIPT_DIR" rev-parse --short HEAD 2>/dev/null || echo "unknown")
        printf 'Commit: %s\n' "$commit"
    fi

    local last_file="${LAST_RUN_DIR:-/var/lib/update-clean}/last-run"
    if [ -f "$last_file" ]; then
        printf '\nLast run:\n'
        sed 's/^/  /' "$last_file"
    fi
}

show_last_run() {
    local last_file="${LAST_RUN_DIR:-/var/lib/update-clean}/last-run"
    local log_path

    if [ -f "$last_file" ]; then
        printf '%s\n' "Last run information:"
        cat "$last_file"
        log_path=$(awk -F= '/^LOG_FILE=/ {print $2}' "$last_file" 2>/dev/null | tail -n1)
        if [ -n "$log_path" ] && [ -f "$log_path" ]; then
            printf '\nTail of log file (%s):\n' "$log_path"
            tail -n 80 "$log_path" 2>/dev/null || true
        fi
    else
        printf '%s\n' "No last-run record found."
    fi
}

run_preflight_checks() {
    detect_distro
    check_debian_based

    printf '%s\n' "=== Pre-flight Checks ==="
    printf 'Distro: %s\n' "$DISTRO_NAME"

    printf 'Running as root: '
    if [ "$EUID" -eq 0 ]; then printf '%s\n' "OK"; else printf '%s\n' "FAIL (must be root)"; fi

    printf 'Internet'
    if [ -n "$ARCHIVE_HOST" ]; then
        printf ' (%s)' "$ARCHIVE_HOST"
    fi
    printf ': '
    if $SKIP_CONNECTIVITY; then
        printf '%s\n' "SKIPPED (--offline)"
    elif check_connectivity; then
        printf '%s\n' "OK"
    else
        printf '%s\n' "FAIL"
    fi

    for part in / /var /boot; do
        report_partition_space "$part" "$MIN_DISK_KB"
    done

    printf 'APT lock free: '
    if ! has_cmd fuser; then
        printf '%s\n' "UNKNOWN (fuser not installed)"
    elif is_apt_locked; then
        printf '%s\n' "LOCKED"
    else
        printf '%s\n' "OK"
    fi

    printf 'systemd-resolved active: '
    if check_systemd_resolved; then
        printf '%s\n' "OK"
    else
        printf '%s\n' "INACTIVE or systemctl not available"
    fi

    printf 'Required tools: '
    local missing=""
    for tool in apt dpkg; do
        if ! has_cmd "$tool"; then
            missing="$missing $tool"
        fi
    done
    if [ -z "$missing" ]; then
        printf '%s\n' "OK"
    else
        printf 'MISSING:%s\n' "$missing"
    fi

    detect_ai_platform
    printf 'AI platform: %s%s\n' "$AI_PLATFORM" "${AI_PLATFORM_DETAIL:+ ($AI_PLATFORM_DETAIL)}"
    printf 'nvidia-smi: '
    if has_cmd nvidia-smi; then
        printf 'OK\n'
        query_nvidia_driver || true
        count_gpu_compute_processes
        printf 'Driver: %s  CUDA: %s  GPUs: %s  Busy procs: %s\n'             "${NVIDIA_DRIVER:-?}" "${CUDA_VERSION:-?}" "$GPU_COUNT" "$GPU_PROCESS_COUNT"
    else
        printf 'MISSING\n'
    fi
    printf 'Docker: '
    if has_cmd docker; then printf '%s\n' "present"; else printf '%s\n' "not installed"; fi
    printf 'SKIP_FIRMWARE: %s  HOLD_NVIDIA: %s  DOCKER_PRUNE: %s\n'         "$SKIP_FIRMWARE" "$HOLD_NVIDIA" "$DOCKER_PRUNE"

    printf '%s\n' "=== Checks complete ==="
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)
            DRY_RUN=true
            CLI_DRY_RUN=true
            shift
            ;;
        --no-kernel)
            SKIP_KERNEL=true
            CLI_SKIP_KERNEL=true
            shift
            ;;
        --keep-kernels)
            shift
            if [ $# -eq 0 ]; then
                error "--keep-kernels requires a number"
                exit 1
            fi
            if ! [[ "$1" =~ ^[0-9]+$ ]]; then
                error "--keep-kernels requires a numeric value"
                exit 1
            fi
            if [ "$1" -gt "$KERNEL_KEEP_MAX" ]; then
                error "--keep-kernels cannot exceed $KERNEL_KEEP_MAX"
                exit 1
            fi
            CLI_KERNEL_KEEP="$1"
            KERNEL_KEEP="$1"
            shift
            ;;
        --reboot-if-required)
            REBOOT_IF_REQUIRED=true
            CLI_REBOOT_IF_REQUIRED=true
            shift
            ;;
        --offline)
            SKIP_CONNECTIVITY=true
            CLI_SKIP_CONNECTIVITY=true
            shift
            ;;
        --last|--status)
            show_last_run
            exit 0
            ;;
        --check|--doctor)
            run_preflight_checks
            exit 0
            ;;
        --debug)
            DEBUG=true
            CLI_DEBUG=true
            shift
            ;;
        --no-gpu-check)
            SKIP_GPU_CHECK=true
            CLI_SKIP_GPU_CHECK=true
            shift
            ;;
        --gpu-only)
            GPU_ONLY=true
            CLI_GPU_ONLY=true
            shift
            ;;
        --no-firmware)
            SKIP_FIRMWARE=true
            CLI_SKIP_FIRMWARE=true
            shift
            ;;
        --with-firmware)
            SKIP_FIRMWARE=false
            CLI_SKIP_FIRMWARE=false
            shift
            ;;
        --no-hold-nvidia)
            HOLD_NVIDIA=false
            CLI_HOLD_NVIDIA=false
            shift
            ;;
        --docker-prune)
            shift
            if [ $# -eq 0 ]; then
                error "--docker-prune requires MODE (none|dangling|unused|all)"
                exit 1
            fi
            CLI_DOCKER_PRUNE="$1"
            DOCKER_PRUNE="$1"
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        --version|-v)
            show_version
            exit 0
            ;;
        *)
            error "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

load_config_files
apply_cli_config_overrides
validate_config_values
require_cmds

export DEBIAN_FRONTEND=noninteractive
export APT_LISTCHANGES_FRONTEND=none

detect_distro
check_debian_based
detect_ai_platform

if $DEBUG; then
    set -x
    info "Debug mode enabled (set -x)"
fi

if $GPU_ONLY; then
    # Health-only path: no root required for most queries, but some need it
    info "GPU-only mode — reporting AI blade health and exiting"
    report_gpu_health
    exit 0
fi

if $DRY_RUN; then
    info "DRY RUN MODE ENABLED - No changes will be made"
    info "DRY-RUN may still use the network to list upgradable packages"
fi

# ────────────────────────────────────────────────────────────────
# Logging (with color stripping for file)
# ────────────────────────────────────────────────────────────────

if ! mkdir -p "$LOG_DIR"; then
    printf '%s\n' "Failed to create log directory $LOG_DIR" >&2
    exit 1
fi
chmod 755 "$LOG_DIR"

if [ ! -w "$LOG_DIR" ]; then
    printf '%s\n' "Log directory $LOG_DIR is not writable" >&2
    exit 1
fi

if [ "$(get_avail_kb "$LOG_DIR")" -lt "$MIN_LOG_DIR_KB" ]; then
    printf '%s\n' "Insufficient space in $LOG_DIR for logs (< 1 MB free)" >&2
    exit 1
fi

LOG_FILE=$(mktemp --tmpdir="$LOG_DIR" "update-clean-$(date +%Y%m%d-%H%M%S)-XXXXXX.log") \
    || { printf '%s\n' "Cannot create log file in $LOG_DIR" >&2; exit 1; }
APT_LOG="${LOG_FILE}.apt-warnings"

exec > >(tee >(sed 's/\x1b\[[0-9;]*m//g' >> "$LOG_FILE")) 2>&1

log "Running $SCRIPT_NAME version: $SCRIPT_VERSION on $DISTRO_NAME"
log_to_syslog "Running $SCRIPT_NAME version: $SCRIPT_VERSION on $DISTRO_NAME"
dump_debug_state

log "Cleaning up old logs (keeping last $LOG_RETENTION)..."
rotate_old_logs "${LOG_RETENTION:-0}"

SCRIPT_START=$(date +%s)

# ────────────────────────────────────────────────────────────────
# Pre-flight checks
# ────────────────────────────────────────────────────────────────
if [ "$EUID" -ne 0 ]; then
    error "This script must be run as root (use sudo)."
    exit 1
fi

if $SKIP_CONNECTIVITY; then
    warn "Skipping internet connectivity check (--offline)"
else
    info "Checking internet connectivity..."
    if ! check_connectivity; then
        error "No internet connection detected."
        exit 1
    fi
fi

for partition in "/" "/var" "/boot"; do
    check_partition_space "$partition" "$MIN_DISK_KB" || exit 1
done

warn_low_partition_space "/boot" "$BOOT_LOW_KB"
warn_low_partition_space "/var" "$VAR_LOW_KB"

info "AI platform: $AI_PLATFORM${AI_PLATFORM_DETAIL:+ ($AI_PLATFORM_DETAIL)}"
if ! $SKIP_GPU_CHECK; then
    report_gpu_health || true
    if $GPU_BUSY; then
        warn "GPUs are busy — updates will proceed, but reboot will be blocked if requested"
        warn "Prefer draining jobs before SuperPOD blade maintenance"
    fi
else
    info "Skipping GPU health checks (--no-gpu-check)"
fi

if is_apt_locked; then
    warn "APT is locked by another process. Waiting up to 60s..."
    for _ in {1..12}; do
        if ! is_apt_locked; then
            break
        fi
        sleep 5
    done
    if is_apt_locked; then
        error "APT still locked after waiting. Please resolve and try again."
        exit 1
    fi
fi

if ! check_systemd_resolved; then
    warn "systemd-resolved is not active. DNS resolution may be affected."
fi

BEFORE=$(get_used_kb_for_paths / /var /boot)

# ────────────────────────────────────────────────────────────────
# File lock + trap
# ────────────────────────────────────────────────────────────────
exec 200>"$LOCKFILE" || { error "Cannot open lockfile $LOCKFILE"; exit 1; }
if ! flock -n 200; then
    error "Another instance of $SCRIPT_NAME is already running."
    exit 1
fi

err_trap() {
    local rc=$?
    local cmd=${BASH_COMMAND:-}
    local lineno=${BASH_LINENO[0]:-?}
    local i

    _record_failure
    error "Unhandled error (rc=$rc) while running: '$cmd' at or near line $lineno"
    if [ "${#BASH_SOURCE[@]}" -gt 1 ]; then
        error "Call stack (most recent call last):"
        for ((i = 1; i < ${#BASH_SOURCE[@]}; i++)); do
            error "  ${BASH_SOURCE[i]}:${BASH_LINENO[i - 1]} ${FUNCNAME[i]:-main}"
        done
    fi
    exit "$rc"
}

cleanup() {
    trap - INT TERM EXIT ERR

    local rc=${1:-$?}
    sync 2>/dev/null || true
    flock -u 200 2>/dev/null || true
    exec 200>&- 2>/dev/null || true
    rm -f "$LOCKFILE" 2>/dev/null || true
    if [ "$rc" -ne 0 ]; then
        error "Script exited with status $rc"
    fi
    exit "$rc"
}

trap 'err_trap' ERR
trap 'cleanup $?' INT TERM EXIT

# ────────────────────────────────────────────────────────────────
# Core update
# ────────────────────────────────────────────────────────────────
info "Configuring any interrupted package installations..."
if ! dpkg --configure -a; then
    warn "dpkg --configure -a had issues"
    _record_failure
fi

info "Fixing broken dependencies..."
apt_run install -f || warn "apt install -f had issues"

info "Updating package lists..."
if $DRY_RUN; then
    info "DRY-RUN: Would run apt-get update (skipped)"
else
    if ! apt_get_update_with_retries; then
        warn "apt-get update had issues after retries"
        _record_failure
    fi
fi

info "Checking package cache integrity (apt-get check)..."
if ! apt-get check; then
    warn "Package cache check reported issues"
    _record_failure
fi

info "Upgrading packages..."
apt_run upgrade || warn "apt upgrade had issues"

info "Listing upgradable packages after initial upgrade:"
apt list --upgradable 2>/dev/null || true

if $DRY_RUN; then
    show_dry_run_preview
fi

info "Performing full system upgrade..."
apt_run full-upgrade || warn "full-upgrade had issues"

# ────────────────────────────────────────────────────────────────
# Complete cleanup
# ────────────────────────────────────────────────────────────────
info "Holding critical packages to prevent accidental removal..."
hold_critical_packages
hold_nvidia_packages

if $DRY_RUN; then
    info "DRY-RUN: Would run autoremove, clean, purge configs, kernel removal, etc."
else
    info "Removing unnecessary packages (autoremove --purge)..."
    apt_run --purge autoremove || warn "autoremove had issues"

    info "Cleaning package cache (autoclean + clean)..."
    apt-get autoclean 2>&1 | tee -a "${APT_LOG:-/dev/null}" || _record_failure
    apt-get clean 2>&1 | tee -a "${APT_LOG:-/dev/null}" || _record_failure

    if [ "${BACKUP_MODE}" = true ]; then
        create_etc_backup || true
    fi

    # '~c' is an apt/dpkg selection: packages in "rc" state (removed, config remains)
    info "Purging residual configuration files..."
    apt_run purge '~c' || warn "Purging residual configs had issues"
fi

if $SKIP_KERNEL; then
    info "Skipping old kernel removal (--no-kernel)."
else
    info "Removing old kernels (keeping current + previous)..."
    remove_old_kernels
fi

if $KERNELS_REMOVED; then
    if ! $DRY_RUN; then
        info "Old kernels were removed. To recover: boot GRUB menu and select a previous kernel entry."
    else
        info "DRY-RUN: Would remove old kernels. Recovery: boot GRUB menu and select a previous kernel."
    fi
fi

if $KERNELS_REMOVED && has_cmd update-grub && ! $DRY_RUN; then
    safe_run "Updating GRUB bootloader" update-grub
fi

if has_cmd flatpak; then
    if $DRY_RUN; then
        info "DRY-RUN: Would update Flatpaks and remove unused"
    else
        safe_run "Updating Flatpaks" flatpak_update
        safe_run "Removing unused Flatpaks" flatpak_uninstall_unused
    fi
fi

if has_cmd snap; then
    if $DRY_RUN; then
        info "DRY-RUN: Would refresh Snaps and remove old revisions"
    else
        safe_run "Refreshing Snaps" snap refresh
        remove_disabled_snaps
    fi
fi

if truthy "$SKIP_FIRMWARE"; then
    info "Skipping fwupd firmware updates (SKIP_FIRMWARE=true; use --with-firmware to enable)"
    info "On DGX/SuperPOD, prefer NVIDIA-documented firmware / Base Command Manager workflows"
elif has_cmd fwupdmgr; then
    if $DRY_RUN; then
        info "DRY-RUN: Would update firmware"
    else
        safe_run "Refreshing firmware metadata" fwupdmgr refresh --force
        safe_run "Applying firmware updates" fwupdmgr update -y || true
    fi
fi

# Container image cleanup for AI blades
docker_cleanup

if has_cmd journalctl; then
    if $DRY_RUN; then
        info "DRY-RUN: Would vacuum journal logs"
    else
        safe_run "Vacuuming journal logs (last 30 days)" journalctl --vacuum-time=30d
    fi
fi

if ! $DRY_RUN; then
    info "Cleaning partial package lists..."
    if [ -d /var/lib/apt/lists/partial ]; then
        rm -rf -- /var/lib/apt/lists/partial/* || warn "Failed to clean partial apt lists"
    fi

    if has_cmd updatedb; then
        safe_run "Updating locate database" updatedb
    fi

    if has_cmd mandb; then
        safe_run "Rebuilding man page database" mandb -q
    fi
else
    info "DRY-RUN: Would perform final cleanups"
fi

# ────────────────────────────────────────────────────────────────
# Final status & summary
# ────────────────────────────────────────────────────────────────
AFTER=$(get_used_kb_for_paths / /var /boot)
FREED_MB=$(calc_disk_freed_mb "$BEFORE" "$AFTER")

REBOOT_DURING_RUN=false
if [ -f /var/run/reboot-required ]; then
    if [ "$(stat -c %Y /var/run/reboot-required 2>/dev/null || echo 0)" -gt "$SCRIPT_START" ]; then
        REBOOT_DURING_RUN=true
    fi
fi

if [ "$REBOOT_DURING_RUN" = true ]; then
    warn "Reboot is required to complete some updates."
    if [ "${REBOOT_IF_REQUIRED}" = true ] && ! $DRY_RUN; then
        if ! $SKIP_GPU_CHECK && ! guard_reboot_if_gpus_busy; then
            warn "Reboot deferred because GPUs are busy"
            _record_failure
        else
            info "REBOOT_IF_REQUIRED set; rebooting now"
            log_to_syslog "Rebooting after $SCRIPT_NAME run"
            reboot
        fi
    else
        warn "Run: sudo reboot (or use --reboot-if-required) after draining GPU jobs"
        if ! $SKIP_GPU_CHECK; then
            count_gpu_compute_processes
            if $GPU_BUSY; then
                warn "Currently $GPU_PROCESS_COUNT GPU process(es) — do not reboot until drained"
            fi
        fi
    fi
else
    success "No reboot required from this run."
fi

LAST_RUN_FILE="$LAST_RUN_DIR/last-run"
RUN_STATUS=success
[ "$EXIT_CODE" -ne 0 ] && RUN_STATUS=failure

if ! $DRY_RUN; then
    mkdir -p "$LAST_RUN_DIR"
    RUN_TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
    REBOOT_FLAG=$([ "$REBOOT_DURING_RUN" = true ] && echo "yes" || echo "no")
    cat > "$LAST_RUN_FILE" << LAST
VERSION=$SCRIPT_VERSION
DISTRO=$DISTRO_NAME
AI_PLATFORM=$AI_PLATFORM
NVIDIA_DRIVER=${NVIDIA_DRIVER:-}
CUDA_VERSION=${CUDA_VERSION:-}
GPU_COUNT=$GPU_COUNT
GPU_BUSY=$GPU_BUSY
GPU_PROCESS_COUNT=$GPU_PROCESS_COUNT
TIMESTAMP=$RUN_TIMESTAMP
STATUS=$RUN_STATUS
FAILURES=$EXIT_CODE
DISK_FREED_MB=$FREED_MB
REBOOT_REQUIRED=$REBOOT_FLAG
LOG_FILE=$LOG_FILE
LAST
    if has_cmd jq; then
        jq -n \
            --arg v "$SCRIPT_VERSION" \
            --arg d "$DISTRO_NAME" \
            --arg platform "$AI_PLATFORM" \
            --arg driver "${NVIDIA_DRIVER:-}" \
            --arg cuda "${CUDA_VERSION:-}" \
            --argjson gpus "${GPU_COUNT:-0}" \
            --argjson busy_procs "${GPU_PROCESS_COUNT:-0}" \
            --arg t "$RUN_TIMESTAMP" \
            --arg status "$RUN_STATUS" \
            --argjson failures "$EXIT_CODE" \
            --arg freed "$FREED_MB" \
            --arg reboot "$REBOOT_FLAG" \
            --arg log "$LOG_FILE" \
            '{version:$v,distro:$d,ai_platform:$platform,nvidia_driver:$driver,cuda_version:$cuda,gpu_count:$gpus,gpu_process_count:$busy_procs,timestamp:$t,status:$status,failures:$failures,disk_freed_mb:$freed,reboot_required:$reboot,log_file:$log}' \
            >"$LAST_RUN_DIR/last-run.json" 2>/dev/null \
            || warn "Failed to write $LAST_RUN_DIR/last-run.json"
    fi
    info "Last run record written to $LAST_RUN_FILE"
else
    info "DRY-RUN: Would write last-run record"
fi

if has_cmd needrestart && ! $DRY_RUN; then
    info "Checking services that need restart..."
    needrestart -r a -l 2>/dev/null || true
elif $DRY_RUN; then
    info "DRY-RUN: Would check for services needing restart"
fi

MSG="System update completed. Freed ${FREED_MB} MB."
if [ "$REBOOT_DURING_RUN" = true ]; then
    MSG="$MSG Reboot recommended."
fi
if [ "$EXIT_CODE" -ne 0 ]; then
    MSG="$MSG Some steps reported failures."
fi
send_completion_notification "$MSG"
log_to_syslog "$MSG (failures=$EXIT_CODE)"

log "=== Update Summary ==="
log "Distro: $DISTRO_NAME"
log "AI platform: $AI_PLATFORM${AI_PLATFORM_DETAIL:+ ($AI_PLATFORM_DETAIL)}"
log "NVIDIA driver: ${NVIDIA_DRIVER:-n/a}  CUDA: ${CUDA_VERSION:-n/a}  GPUs: $GPU_COUNT  busy_procs: $GPU_PROCESS_COUNT"
log "Disk space freed (/, /var, /boot): ${FREED_MB} MB"
log "Failures recorded: $EXIT_CODE"
log "Full log saved to: $LOG_FILE"
log "APT warnings logged to: $APT_LOG"

if [ "$EXIT_CODE" -eq 0 ]; then
    success "Update and cleanup completed successfully!"
    exit 0
else
    warn "Update and cleanup finished with $EXIT_CODE failure(s)."
    exit 1
fi