#!/usr/bin/env bash
# NVIDIA Base Command Manager (BCM) / Bright Cluster Manager hooks
#
# Copyright (C) 2026 wbharris
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Helpers for SuperPOD-style fleets managed by BCM (cmsh, pdsh, categories).
# Source this file or run: ./bcm/bcm-hooks.sh <command> [args...]
#
# Typical maintenance flow:
#   1) bcm_drain_category gpu "update-clean maintenance"
#   2) fleet runner --from-bcm-category gpu --deploy --
#   3) bcm_undrain_category gpu
#
# These commands are best-effort wrappers around cmsh. Exact WLM module names
# vary by site (slurm, pbs, etc.). Override with env vars below.

set -euo pipefail

BCM_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# Site overrides
CMSH_BIN="${CMSH_BIN:-cmsh}"
PDSH_BIN="${PDSH_BIN:-pdsh}"
# WLM path inside cmsh, e.g. "wlm use slurm" — set empty to skip WLM drain
BCM_WLM_USE="${BCM_WLM_USE:-wlm; use slurm}"
# device mode for closed/open (BCM device status)
BCM_DEVICE_CLOSED_STATUS="${BCM_DEVICE_CLOSED_STATUS:-closed}"
BCM_DEVICE_OPEN_STATUS="${BCM_DEVICE_OPEN_STATUS:-ok}"

bcm_have_cmsh() {
    command -v "$CMSH_BIN" >/dev/null 2>&1
}

bcm_have_pdsh() {
    command -v "$PDSH_BIN" >/dev/null 2>&1
}

bcm_require_cmsh() {
    if ! bcm_have_cmsh; then
        printf '%s\n' "cmsh not found (set CMSH_BIN or run on BCM head node)" >&2
        return 1
    fi
}

# List node hostnames in a BCM device category (e.g. gpu, compute, dgx)
bcm_list_category_nodes() {
    local category="${1:?category required}"
    bcm_require_cmsh

    # Prefer foreach over category; fall back to device list filtering
    local out
    out=$("$CMSH_BIN" -c "device; foreach -c ${category} (get hostname)" 2>/dev/null || true)
    if [[ -z "${out// /}" ]]; then
        out=$("$CMSH_BIN" -c "device; foreach -c ${category} (get name)" 2>/dev/null || true)
    fi
    if [[ -z "${out// /}" ]]; then
        # Some sites use: category use X; device list
        out=$("$CMSH_BIN" -c "category use ${category}; device list -f hostname:20" 2>/dev/null \
            | awk 'NR>1 && $1 !~ /^---/ {print $1}' || true)
    fi

    printf '%s\n' "$out" \
        | sed 's/\r//g' \
        | awk 'NF && $1 !~ /^(hostname|name|Device|----)/ {print $1}' \
        | sed 's/[[:space:]]//g' \
        | sort -u
}

# Close devices in category (scheduler-facing "do not place new work")
bcm_close_category() {
    local category="${1:?category required}"
    local reason="${2:-update-clean maintenance}"
    bcm_require_cmsh

    printf '[BCM] Closing devices in category=%s reason=%s\n' "$category" "$reason" >&2
    "$CMSH_BIN" -c "device; foreach -c ${category} (set status ${BCM_DEVICE_CLOSED_STATUS}; set notes \"${reason}\"; commit)" \
        || "$CMSH_BIN" -c "device; foreach -c ${category} (set status ${BCM_DEVICE_CLOSED_STATUS}; commit)"
}

bcm_open_category() {
    local category="${1:?category required}"
    bcm_require_cmsh

    printf '[BCM] Opening devices in category=%s\n' "$category" >&2
    "$CMSH_BIN" -c "device; foreach -c ${category} (set status ${BCM_DEVICE_OPEN_STATUS}; commit)"
}

# WLM drain (Slurm via cmsh when module available)
bcm_wlm_drain_category() {
    local category="${1:?category required}"
    local reason="${2:-update-clean maintenance}"
    local nodes nlist
    bcm_require_cmsh

    mapfile -t nodes < <(bcm_list_category_nodes "$category")
    if [[ ${#nodes[@]} -eq 0 ]]; then
        printf '[BCM] No nodes in category %s\n' "$category" >&2
        return 1
    fi
    nlist=$(IFS=,; echo "${nodes[*]}")

    if [[ -z "${BCM_WLM_USE// /}" ]]; then
        printf '[BCM] BCM_WLM_USE empty — skipping WLM drain\n' >&2
        return 0
    fi

    printf '[BCM] WLM drain nodes=%s reason=%s\n' "$nlist" "$reason" >&2
    # Bright/BCM cmsh WLM syntax varies; try common patterns
    if "$CMSH_BIN" -c "${BCM_WLM_USE}; nodes; drain ${nlist} \"${reason}\"" 2>/dev/null; then
        return 0
    fi
    if "$CMSH_BIN" -c "${BCM_WLM_USE}; drain nodes ${nlist} reason=\"${reason}\"" 2>/dev/null; then
        return 0
    fi
    # Fall back to scontrol on head if available
    if command -v scontrol >/dev/null 2>&1; then
        local n
        for n in "${nodes[@]}"; do
            scontrol update NodeName="$n" State=DRAIN Reason="$reason" || true
        done
        return 0
    fi
    printf '[BCM] WLM drain failed — use site-specific cmsh or scontrol\n' >&2
    return 1
}

bcm_wlm_undrain_category() {
    local category="${1:?category required}"
    local nodes nlist
    bcm_require_cmsh

    mapfile -t nodes < <(bcm_list_category_nodes "$category")
    [[ ${#nodes[@]} -eq 0 ]] && return 1
    nlist=$(IFS=,; echo "${nodes[*]}")

    if [[ -z "${BCM_WLM_USE// /}" ]]; then
        return 0
    fi

    printf '[BCM] WLM undrain nodes=%s\n' "$nlist" >&2
    if "$CMSH_BIN" -c "${BCM_WLM_USE}; nodes; undrain ${nlist}" 2>/dev/null; then
        return 0
    fi
    if "$CMSH_BIN" -c "${BCM_WLM_USE}; resume nodes ${nlist}" 2>/dev/null; then
        return 0
    fi
    if command -v scontrol >/dev/null 2>&1; then
        local n
        for n in "${nodes[@]}"; do
            scontrol update NodeName="$n" State=RESUME || true
        done
        return 0
    fi
    return 1
}

# Combined: close device + WLM drain
bcm_drain_category() {
    local category="${1:?category required}"
    local reason="${2:-update-clean maintenance}"
    bcm_close_category "$category" "$reason" || true
    bcm_wlm_drain_category "$category" "$reason" || true
}

bcm_undrain_category() {
    local category="${1:?category required}"
    bcm_wlm_undrain_category "$category" || true
    bcm_open_category "$category" || true
}

# Run a command on all nodes in category via pdsh (if available)
bcm_pdsh_category() {
    local category="${1:?category required}"
    shift
    local nodes nlist
    mapfile -t nodes < <(bcm_list_category_nodes "$category")
    [[ ${#nodes[@]} -gt 0 ]] || return 1
    nlist=$(IFS=,; echo "${nodes[*]}")

    if bcm_have_pdsh; then
        "$PDSH_BIN" -w "$nlist" "$@"
        return $?
    fi
    # Fallback: serial SSH
    local n
    for n in "${nodes[@]}"; do
        printf '== %s ==\n' "$n"
        ssh -o BatchMode=yes -o ConnectTimeout=15 "$n" "$@"
    done
}

# Full maintenance window helper
bcm_maintenance_window() {
    local category="${1:?category required}"
    local reason="${2:-update-clean maintenance}"
    local action="${3:-start}" # start|end

    case "$action" in
        start)
            bcm_drain_category "$category" "$reason"
            printf '[BCM] Maintenance START category=%s — run fleet update next\n' "$category"
            printf '  %s/../fleet/update-clean-fleet.sh --from-bcm-category %s --deploy --drain-mode skip --\n' \
                "$BCM_DIR" "$category"
            ;;
        end)
            bcm_undrain_category "$category"
            printf '[BCM] Maintenance END category=%s — nodes reopened/undrained\n' "$category"
            ;;
        *)
            printf 'usage: bcm_maintenance_window <category> [reason] start|end\n' >&2
            return 1
            ;;
    esac
}

bcm_cli_usage() {
    cat <<'EOF'
BCM hooks — SuperPOD / Base Command Manager helpers

Usage: bcm-hooks.sh <command> [args]

Commands:
  list-category <cat>              List hostnames in device category
  close-category <cat> [reason]    Set device status closed
  open-category <cat>              Set device status ok/open
  wlm-drain <cat> [reason]         Drain via cmsh WLM or scontrol
  wlm-undrain <cat>                Undrain / resume nodes
  drain <cat> [reason]             close + wlm-drain
  undrain <cat>                    wlm-undrain + open
  pdsh <cat> -- <cmd...>           Run command on category nodes
  maintenance <cat> [reason] start|end

Environment:
  CMSH_BIN          default: cmsh
  PDSH_BIN          default: pdsh
  BCM_WLM_USE       default: "wlm; use slurm"  (set empty to skip)
  BCM_DEVICE_CLOSED_STATUS   default: closed
  BCM_DEVICE_OPEN_STATUS     default: ok

Example SuperPOD window:
  ./bcm/bcm-hooks.sh maintenance gpu "weekly update-clean" start
  ./fleet/update-clean-fleet.sh --from-bcm-category gpu --deploy --parallel 4 --
  ./bcm/bcm-hooks.sh maintenance gpu end
EOF
}

# CLI entry when executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    cmd="${1:-}"
    shift || true
    case "$cmd" in
        list-category) bcm_list_category_nodes "${1:?}" ;;
        close-category) bcm_close_category "${1:?}" "${2:-update-clean maintenance}" ;;
        open-category) bcm_open_category "${1:?}" ;;
        wlm-drain) bcm_wlm_drain_category "${1:?}" "${2:-update-clean maintenance}" ;;
        wlm-undrain) bcm_wlm_undrain_category "${1:?}" ;;
        drain) bcm_drain_category "${1:?}" "${2:-update-clean maintenance}" ;;
        undrain) bcm_undrain_category "${1:?}" ;;
        pdsh)
            cat="${1:?}"
            shift
            [[ "${1:-}" == "--" ]] && shift
            bcm_pdsh_category "$cat" "$@"
            ;;
        maintenance)
            bcm_maintenance_window "${1:?}" "${2:-update-clean maintenance}" "${3:-start}"
            ;;
        -h|--help|help|"")
            bcm_cli_usage
            [[ -n "$cmd" && "$cmd" != help && "$cmd" != "-h" && "$cmd" != "--help" && -n "$cmd" ]] || exit 0
            ;;
        *)
            printf 'Unknown command: %s\n' "$cmd" >&2
            bcm_cli_usage
            exit 1
            ;;
    esac
fi
