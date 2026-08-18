#!/usr/bin/env bash
# Build a versioned source tarball for GitHub Releases.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
VER=$(tr -d '[:space:]' <"$ROOT/VERSION")
[[ "$VER" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
    printf 'Invalid VERSION: %s\n' "$VER" >&2
    exit 1
}

NAME="ai_blade_ubuntu_update_clean-${VER}"
OUTDIR="${1:-$ROOT/dist}"
STAGE=$(mktemp -d)
# shellcheck disable=SC2064
trap 'rm -rf "$STAGE"' EXIT

mkdir -p "$OUTDIR" "$STAGE/$NAME"

cp -a \
    "$ROOT/update-clean.sh" \
    "$ROOT/VERSION" \
    "$ROOT/CHANGELOG.md" \
    "$ROOT/README.md" \
    "$ROOT/LICENSE" \
    "$ROOT/update-clean.conf.example" \
    "$STAGE/$NAME/"

cp -a "$ROOT/systemd" "$ROOT/fleet" "$ROOT/bcm" "$ROOT/ansible" "$ROOT/tests" \
    "$STAGE/$NAME/"

# Do not ship helper/dev-only files
rm -f "$STAGE/$NAME/cleanup-push.sh" 2>/dev/null || true

TARBALL="$OUTDIR/${NAME}.tar.gz"
tar -C "$STAGE" -czf "$TARBALL" "$NAME"
(cd "$OUTDIR" && sha256sum "$(basename "$TARBALL")" >"${NAME}.tar.gz.sha256")

printf '%s\n' "$TARBALL"
printf '%s\n' "$OUTDIR/${NAME}.tar.gz.sha256"
