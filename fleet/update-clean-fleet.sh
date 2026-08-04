#!/usr/bin/env bash
# Multi-node AI / GPU blade fleet runner for update-clean.sh
#
# Copyright (C) 2026 wbharris
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Runs (or deploys + runs) update-clean across many Ubuntu GPU blades over SSH.
# Supports drain checks (skip or wait while GPUs busy), parallel execution,
# and optional cmsh category inventory (see ../bcm/).
#
# Usage:
#   ./fleet/update-clean-fleet.sh -f fleet/hosts.example --gpu-only
#   ./fleet/update-clean-fleet.sh -H node001,node002 -- --dry-run
#   ./fleet/update-clean-fleet.sh -f hosts --parallel 4 --drain-mode wait --drain-wait 600
#   ./fleet/update-clean-fleet.sh --from-bcm-category gpu -- --check

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
LOCAL_UPDATE_CLEAN="${REPO_ROOT}/update-clean.sh"
BCM_HELPER="${REPO_ROOT}/bcm/bcm-hooks.sh"

HOSTS_FILE=""
HOSTS_CSV=""
FROM_BCM_CATEGORY=""
SSH_USER="${SSH_USER:-}"
SSH_OPTS=("-o" "BatchMode=yes" "-o" "StrictHostKeyChecking=accept-new" "-o" "ConnectTimeout=15")
REMOTE_PATH="${REMOTE_PATH:-/usr/local/sbin/update-clean.sh}"
PARALLEL="${PARALLEL:-1}"
DRAIN_MODE="${DRAIN_MODE:-skip}"   # skip | wait | force
DRAIN_WAIT_SEC="${DRAIN_WAIT_SEC:-0}"
DRAIN_POLL_SEC="${DRAIN_POLL_SEC:-30}"
DEPLOY=false
DRY_RUN_FLEET=false
SUMMARY_DIR=""
PASS_ARGS=()
HOSTS=()
RESULTS_DIR=""

usage() {
    cat <<'USAGE'
Usage: update-clean-fleet.sh [fleet options] [-- update-clean args...]

Inventory (pick at least one):
  -f, --hosts-file FILE     Host list (one per line; # comments ok)
  -H, --hosts LIST          Comma-separated hosts (user@host[:port])
  --from-bcm-category CAT   Expand hosts via bcm/bcm-hooks.sh (cmsh)

SSH / deploy:
  -u, --ssh-user USER       Default SSH user (if host has no user@)
  -o, --ssh-opt OPT         Extra ssh -o option (repeatable)
  --remote-path PATH        Remote script path (default: /usr/local/sbin/update-clean.sh)
  --deploy                  scp local update-clean.sh to remote-path before run
  -p, --parallel N          Concurrent nodes (default: 1)
  --dry-run-fleet           Print planned SSH actions only

GPU drain policy (before update-clean on a node):
  --drain-mode MODE         skip | wait | force (default: skip)
                              skip  — if GPUs busy, skip node
                              wait  — poll until idle or --drain-wait timeout
                              force — run anyway (not recommended)
  --drain-wait SEC          Max seconds to wait in wait mode (0 = forever)
  --drain-poll SEC          Poll interval (default: 30)
  --summary-dir DIR         Per-host logs + summary.tsv

  -h, --help

Pass-through tip: add --quiet or --verbose after -- for console noise control on blades.

Everything after -- is passed to update-clean.sh on each node:
  ./update-clean-fleet.sh -f hosts --deploy -- --dry-run
  ./update-clean-fleet.sh -H n1,n2 -- --gpu-only
  ./update-clean-fleet.sh -f hosts --drain-mode wait --drain-wait 3600 --

Environment: SSH_USER REMOTE_PATH PARALLEL DRAIN_MODE DRAIN_WAIT_SEC DRAIN_POLL_SEC
USAGE
}

truthy() {
    case "${1,,}" in
        true|yes|1|on) return 0 ;;
        *) return 1 ;;
    esac
}

info() { printf '[INFO] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
err()  { printf '[ERROR] %s\n' "$*" >&2; }

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -f|--hosts-file) HOSTS_FILE="${2:?}"; shift 2 ;;
            -H|--hosts) HOSTS_CSV="${2:?}"; shift 2 ;;
            --from-bcm-category) FROM_BCM_CATEGORY="${2:?}"; shift 2 ;;
            -u|--ssh-user) SSH_USER="${2:?}"; shift 2 ;;
            -o|--ssh-opt) SSH_OPTS+=("-o" "${2:?}"); shift 2 ;;
            --remote-path) REMOTE_PATH="${2:?}"; shift 2 ;;
            --deploy) DEPLOY=true; shift ;;
            -p|--parallel) PARALLEL="${2:?}"; shift 2 ;;
            --dry-run-fleet) DRY_RUN_FLEET=true; shift ;;
            --drain-mode) DRAIN_MODE="${2:?}"; shift 2 ;;
            --drain-wait) DRAIN_WAIT_SEC="${2:?}"; shift 2 ;;
            --drain-poll) DRAIN_POLL_SEC="${2:?}"; shift 2 ;;
            --summary-dir) SUMMARY_DIR="${2:?}"; shift 2 ;;
            -h|--help) usage; exit 0 ;;
            --) shift; PASS_ARGS=("$@"); break ;;
            *)
                # Convenience: trailing args without -- still go to update-clean
                if [[ "$1" == --* ]] || [[ "$1" == -* ]]; then
                    # Treat remaining as pass-through if they look like update-clean flags
                    PASS_ARGS=("$@")
                    break
                fi
                err "Unknown option: $1 (use -- before update-clean args)"
                usage
                exit 1
                ;;
        esac
    done
}

normalize_host() {
    local h="$1"
    local port="" userhost="$h"

    if [[ "$userhost" =~ ^(.+):([0-9]+)$ ]]; then
        userhost="${BASH_REMATCH[1]}"
        port="${BASH_REMATCH[2]}"
    fi
    if [[ -n "$SSH_USER" && "$userhost" != *@* ]]; then
        userhost="${SSH_USER}@${userhost}"
    fi
    printf '%s|%s\n' "$userhost" "$port"
}

load_hosts() {
    local -a raw=()
    local line h

    if [[ -n "$FROM_BCM_CATEGORY" ]]; then
        if [[ ! -f "$BCM_HELPER" ]]; then
            err "BCM helper not found: $BCM_HELPER"
            exit 1
        fi
        # shellcheck source=/dev/null
        source "$BCM_HELPER"
        if ! mapfile -t raw < <(bcm_list_category_nodes "$FROM_BCM_CATEGORY"); then
            err "Failed to list BCM category: $FROM_BCM_CATEGORY"
            exit 1
        fi
        if [[ ${#raw[@]} -eq 0 ]]; then
            err "No nodes from BCM category: $FROM_BCM_CATEGORY"
            exit 1
        fi
    fi

    if [[ -n "$HOSTS_FILE" ]]; then
        [[ -f "$HOSTS_FILE" ]] || { err "Hosts file not found: $HOSTS_FILE"; exit 1; }
        while IFS= read -r line || [[ -n "$line" ]]; do
            line="${line%%#*}"
            line="${line#"${line%%[![:space:]]*}"}"
            line="${line%"${line##*[![:space:]]}"}"
            [[ -z "$line" ]] && continue
            raw+=("$line")
        done < "$HOSTS_FILE"
    fi

    if [[ -n "$HOSTS_CSV" ]]; then
        IFS=',' read -ra _csv <<< "$HOSTS_CSV"
        for h in "${_csv[@]}"; do
            h="${h#"${h%%[![:space:]]*}"}"
            h="${h%"${h##*[![:space:]]}"}"
            [[ -n "$h" ]] && raw+=("$h")
        done
    fi

    if [[ ${#raw[@]} -eq 0 ]]; then
        err "No hosts specified. Use -f, -H, or --from-bcm-category"
        usage
        exit 1
    fi

    local -A seen=()
    HOSTS=()
    for h in "${raw[@]}"; do
        [[ -n "${seen[$h]:-}" ]] && continue
        seen[$h]=1
        HOSTS+=("$h")
    done
}

safe_label() {
    printf '%s' "$1" | tr -c 'A-Za-z0-9._+@-' '_'
}

ssh_cmd() {
    local target="$1" port="$2"
    shift 2
    local -a cmd=(ssh "${SSH_OPTS[@]}")
    [[ -n "$port" ]] && cmd+=("-p" "$port")
    cmd+=("$target" "$@")
    "${cmd[@]}"
}

remote_gpu_busy_count() {
    local target="$1" port="$2"
    local out remote_script
    # Single remote one-liner avoids heredoc-inside-$(...) parse issues
    remote_script='if command -v nvidia-smi >/dev/null 2>&1; then n=$(nvidia-smi --query-compute-apps=pid --format=csv,noheader,nounits 2>/dev/null | sed "/^[[:space:]]*$/d" | wc -l); echo "${n// /}"; exit 0; fi; if command -v rocm-smi >/dev/null 2>&1; then n=$(rocm-smi --showpids 2>/dev/null | grep -cE "^[0-9]" || echo 0); echo "${n// /}"; exit 0; fi; echo 0'
    out=$(ssh_cmd "$target" "$port" "bash -c $(printf '%q' "$remote_script")" 2>/dev/null) || {
        echo "err"
        return 0
    }
    printf '%s\n' "$(printf '%s\n' "$out" | tail -n1 | tr -d '[:space:]')"
}

wait_or_skip_drain() {
    local label="$1" target="$2" port="$3"
    local count started now elapsed

    case "$DRAIN_MODE" in
        force) return 0 ;;
        skip|wait) ;;
        *) err "Invalid DRAIN_MODE=$DRAIN_MODE"; return 1 ;;
    esac

    count=$(remote_gpu_busy_count "$target" "$port" || true)
    count=$(printf '%s' "$count" | tail -n1 | tr -d '[:space:]')

    if [[ "$count" == "err" || ! "$count" =~ ^[0-9]+$ ]]; then
        warn "$label: could not query GPU busy state; proceeding"
        return 0
    fi

    if [[ "$count" -eq 0 ]]; then
        info "$label: GPUs idle"
        return 0
    fi

    if [[ "$DRAIN_MODE" == "skip" ]]; then
        warn "$label: GPUs busy ($count procs) — skip (drain-mode=skip)"
        return 2
    fi

    info "$label: GPUs busy ($count) — waiting (poll=${DRAIN_POLL_SEC}s max=${DRAIN_WAIT_SEC}s)"
    started=$(date +%s)
    while true; do
        sleep "$DRAIN_POLL_SEC"
        count=$(remote_gpu_busy_count "$target" "$port" || true)
        count=$(printf '%s' "$count" | tail -n1 | tr -d '[:space:]')
        if [[ "$count" =~ ^[0-9]+$ && "$count" -eq 0 ]]; then
            info "$label: GPUs now idle"
            return 0
        fi
        now=$(date +%s)
        elapsed=$((now - started))
        if [[ "$DRAIN_WAIT_SEC" -gt 0 && "$elapsed" -ge "$DRAIN_WAIT_SEC" ]]; then
            warn "$label: drain wait timed out after ${elapsed}s (busy=${count})"
            return 2
        fi
        info "$label: still busy=${count} elapsed=${elapsed}s"
    done
}

deploy_script() {
    local target="$1" port="$2"
    local -a scpcmd=(scp "${SSH_OPTS[@]}")
    [[ -n "$port" ]] && scpcmd+=("-P" "$port")

    if truthy "${DRY_RUN_FLEET:-false}"; then
        info "DRY-RUN-FLEET: would scp $LOCAL_UPDATE_CLEAN -> ${target}:${REMOTE_PATH}"
        return 0
    fi

    [[ -f "$LOCAL_UPDATE_CLEAN" ]] || { err "Local script missing: $LOCAL_UPDATE_CLEAN"; return 1; }
    "${scpcmd[@]}" "$LOCAL_UPDATE_CLEAN" "${target}:/tmp/update-clean.sh.new"
    ssh_cmd "$target" "$port" \
        "sudo install -m 755 /tmp/update-clean.sh.new '${REMOTE_PATH}' && rm -f /tmp/update-clean.sh.new"
}

run_one_host() {
    local raw="$1"
    local target port label logfile status rc drain_rc
    local pass_q=""

    IFS='|' read -r target port < <(normalize_host "$raw")
    label="$raw"
    logfile="${RESULTS_DIR}/$(safe_label "$label").log"
    status="ok"
    rc=0

    {
        printf '[%s] BEGIN host=%s target=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$label" "$target"

        if truthy "${DEPLOY:-false}"; then
            if ! deploy_script "$target" "$port"; then
                status="deploy_fail"
                rc=1
                printf 'STATUS=%s RC=%s\n' "$status" "$rc"
                return
            fi
        fi

        set +e
        wait_or_skip_drain "$label" "$target" "$port"
        drain_rc=$?
        set -e

        if [[ "$drain_rc" -eq 2 ]]; then
            status="skipped_busy"
            rc=2
            printf 'STATUS=%s RC=%s\n' "$status" "$rc"
            return
        fi
        if [[ "$drain_rc" -ne 0 ]]; then
            status="drain_error"
            rc=1
            printf 'STATUS=%s RC=%s\n' "$status" "$rc"
            return
        fi

        if truthy "${DRY_RUN_FLEET:-false}"; then
            info "DRY-RUN-FLEET: would run sudo $REMOTE_PATH ${PASS_ARGS[*]:-}"
            status="dry_run"
            rc=0
        else
            if [[ ${#PASS_ARGS[@]} -gt 0 ]]; then
                pass_q=$(printf '%q ' "${PASS_ARGS[@]}")
            fi
            set +e
            ssh_cmd "$target" "$port" \
                "if [ -x '${REMOTE_PATH}' ] || [ -f '${REMOTE_PATH}' ]; then sudo bash '${REMOTE_PATH}' ${pass_q}; else echo 'update-clean missing at ${REMOTE_PATH}; use --deploy' >&2; exit 127; fi"
            rc=$?
            set -e
            if [[ "$rc" -eq 0 ]]; then
                status="ok"
            else
                status="fail"
            fi
        fi

        printf '[%s] END host=%s status=%s rc=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$label" "$status" "$rc"
        printf 'STATUS=%s RC=%s\n' "$status" "$rc"
    } >"$logfile" 2>&1

    printf '%s\t%s\t%s\t%s\n' "$label" "$status" "$rc" "$logfile" >>"${RESULTS_DIR}/summary.partial"
}

run_pool() {
    local -a pids=()
    local -a running_hosts=()
    local h i pid

    for h in "${HOSTS[@]}"; do
        while [[ ${#pids[@]} -ge "$PARALLEL" ]]; do
            # Wait for any child
            if wait -n 2>/dev/null; then
                :
            else
                # bash without wait -n: wait on first pid
                wait "${pids[0]}" 2>/dev/null || true
            fi
            # Reap finished
            local -a new_pids=()
            for pid in "${pids[@]}"; do
                if kill -0 "$pid" 2>/dev/null; then
                    new_pids+=("$pid")
                fi
            done
            pids=("${new_pids[@]}")
        done
        run_one_host "$h" &
        pids+=("$!")
    done

    for pid in "${pids[@]+"${pids[@]}"}"; do
        wait "$pid" 2>/dev/null || true
    done
}

main() {
    parse_args "$@"

    if [[ ! "$PARALLEL" =~ ^[0-9]+$ ]] || [[ "$PARALLEL" -lt 1 ]]; then
        err "PARALLEL must be >= 1"
        exit 1
    fi
    case "$DRAIN_MODE" in
        skip|wait|force) ;;
        *) err "drain-mode must be skip|wait|force"; exit 1 ;;
    esac

    load_hosts

    if [[ -z "$SUMMARY_DIR" ]]; then
        SUMMARY_DIR="${REPO_ROOT}/fleet-runs/$(date +%Y%m%d-%H%M%S)"
    fi
    RESULTS_DIR="$SUMMARY_DIR"
    mkdir -p "$RESULTS_DIR"
    : >"${RESULTS_DIR}/summary.partial"

    info "Fleet run: ${#HOSTS[@]} host(s) parallel=$PARALLEL drain-mode=$DRAIN_MODE"
    info "Results: $RESULTS_DIR"
    info "update-clean args: ${PASS_ARGS[*]:-<none>}"
    printf '%s\n' "${HOSTS[@]}" >"${RESULTS_DIR}/hosts.txt"

    if [[ "$PARALLEL" -eq 1 ]]; then
        for h in "${HOSTS[@]}"; do
            run_one_host "$h"
        done
    else
        run_pool
    fi

    local summary="${RESULTS_DIR}/summary.tsv"
    {
        printf 'host\tstatus\trc\tlog\n'
        if [[ -f "${RESULTS_DIR}/summary.partial" ]]; then
            sort -u "${RESULTS_DIR}/summary.partial"
        fi
    } >"$summary"

    local ok=0 fail=0 skip=0 other=0 host status rc logf
    while IFS=$'\t' read -r host status rc logf; do
        [[ "$host" == "host" ]] && continue
        [[ -z "$host" ]] && continue
        case "$status" in
            ok|dry_run) ok=$((ok + 1)) ;;
            skipped_busy) skip=$((skip + 1)) ;;
            fail|deploy_fail|drain_error) fail=$((fail + 1)) ;;
            *) other=$((other + 1)) ;;
        esac
    done <"$summary"

    info "=== Fleet summary ==="
    info "ok=$ok skipped_busy=$skip fail=$fail other=$other"
    info "summary: $summary"
    if command -v column >/dev/null 2>&1; then
        column -t -s $'\t' "$summary" || cat "$summary"
    else
        cat "$summary"
    fi

    if [[ "$fail" -gt 0 ]]; then
        exit 1
    fi
    if [[ "$skip" -gt 0 && "$ok" -eq 0 ]]; then
        exit 2
    fi
    exit 0
}

main "$@"
