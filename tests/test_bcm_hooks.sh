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

printf '\n=== %s ===\n' "$([[ $fail -eq 0 ]] && echo 'bcm sanitizers passed' || echo 'bcm sanitizers failed')"
exit "$fail"
