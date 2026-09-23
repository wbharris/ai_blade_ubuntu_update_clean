#!/usr/bin/env bash
# Non-root checks for cmsh token sanitizers (no cluster required).
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../bcm/bcm-hooks.sh
source "$ROOT/bcm/bcm-hooks.sh"

fail=0
pass() { printf '  PASS  %s\n' "$1"; }
fail_case() { printf '  FAIL  %s\n' "$1"; fail=1; }

got=$(bcm_safe_category gpu) && [[ "$got" == gpu ]] && pass "category gpu" || fail_case "category gpu"
if bcm_safe_category 'gpu; rm -rf /' >/dev/null 2>&1; then
    fail_case "reject category injection"
else
    pass "reject category injection"
fi
if bcm_safe_category 'a b' >/dev/null 2>&1; then
    fail_case "reject category space"
else
    pass "reject category space"
fi

got=$(bcm_safe_reason 'weekly update-clean')
[[ "$got" == "weekly update-clean" ]] && pass "reason plain" || fail_case "reason plain"
got=$(bcm_safe_reason 'foo"; device; foreach')
[[ "$got" != *'"'* && "$got" != *';'* ]] && pass "reason strips quotes and semicolons" || fail_case "reason strips quotes and semicolons"
got=$(bcm_safe_reason '')
[[ "$got" == "update-clean maintenance" ]] && pass "empty reason default" || fail_case "empty reason default"

bcm_safe_host gpu-01 && pass "host gpu-01" || fail_case "host gpu-01"
bcm_safe_host 'gpu-01;id' && fail_case "reject host injection" || pass "reject host injection"

got=$(bcm_safe_status closed) && [[ "$got" == closed ]] && pass "status closed" || fail_case "status closed"
if bcm_safe_status 'closed; commit' >/dev/null 2>&1; then
    fail_case "reject status injection"
else
    pass "reject status injection"
fi

SIM=$(mktemp -d "${TMPDIR:-/tmp}/bcm-units.XXXXXX")
trap 'rm -rf "$SIM"' EXIT
cat >"$SIM/cmsh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${CMSH_LOG:?}"
joined="$*"
if [[ "$joined" == *"get hostname"* ]]; then
    printf '%s\n' "gpu-01"
    exit 0
fi
if [[ "${CMSH_FAIL:-}" == "close" && "$joined" == *"set status"* ]]; then
    exit 1
fi
if [[ "${CMSH_FAIL:-}" == "wlm" && "$joined" == *"drain "* ]]; then
    exit 1
fi
exit 0
EOF
chmod +x "$SIM/cmsh"
cat >"$SIM/scontrol" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$SIM/scontrol"
export CMSH_BIN="$SIM/cmsh" CMSH_LOG="$SIM/cmsh.log" PATH="$SIM:$PATH"
: >"$CMSH_LOG"
export CMSH_FAIL=close
if bcm_drain_category gpu "weekly update-clean"; then
    fail_case "drain succeeded when device close failed"
else
    pass "drain fails when device close fails"
fi
export CMSH_FAIL=wlm
if bcm_drain_category gpu "weekly update-clean"; then
    fail_case "drain succeeded when WLM drain failed"
else
    pass "drain fails when WLM drain failed"
fi
out=$(CMSH_FAIL=close bcm_maintenance_window gpu "weekly update-clean" start 2>&1 || true)
printf '%s\n' "$out" | grep -q 'run fleet update next' \
    && fail_case "maintenance start printed fleet instructions after drain failure" \
    || pass "maintenance start withholds fleet instructions after drain failure"
export CMSH_FAIL=
if bcm_drain_category gpu "weekly update-clean"; then
    pass "drain succeeds when close and WLM succeed"
else
    fail_case "drain succeeds when close and WLM succeed"
fi

printf '\n=== %s ===\n' "$([[ $fail -eq 0 ]] && echo 'bcm sanitizers passed' || echo 'bcm sanitizers failed')"
exit "$fail"
