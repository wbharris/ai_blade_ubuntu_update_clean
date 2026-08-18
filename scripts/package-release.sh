#!/usr/bin/env bash
# Build a versioned source tarball for GitHub Releases.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
VER=$(tr -d '[:space:]' <"$ROOT/VERSION")
[[ "$VER" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
    printf 'Invalid VERSION: %s\n' "$VER" >&2
    exit 1
}
embedded=$(sed -n 's/^readonly SCRIPT_VERSION_EMBEDDED="\([^"]*\)".*/\1/p' "$ROOT/update-clean.sh" | head -n1)
if [ "$embedded" != "$VER" ]; then
    printf 'VERSION=%s but SCRIPT_VERSION_EMBEDDED=%s\n' "$VER" "$embedded" >&2
    exit 1
fi

NAME="ai_blade_ubuntu_update_clean-${VER}"
STABLE="ai_blade_ubuntu_update_clean"
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

# Versioned archive (pin a release) and stable name (releases/latest/download/...)
TARBALL="$OUTDIR/${NAME}.tar.gz"
tar -C "$STAGE" -czf "$TARBALL" "$NAME"
cp -a "$STAGE/$NAME" "$STAGE/$STABLE"
STABLE_TAR="$OUTDIR/${STABLE}.tar.gz"
tar -C "$STAGE" -czf "$STABLE_TAR" "$STABLE"

(cd "$OUTDIR" && sha256sum "$(basename "$TARBALL")" >"${NAME}.tar.gz.sha256")
(cd "$OUTDIR" && sha256sum "$(basename "$STABLE_TAR")" >"${STABLE}.tar.gz.sha256")

printf '%s\n' "$TARBALL" "$OUTDIR/${NAME}.tar.gz.sha256" "$STABLE_TAR" "$OUTDIR/${STABLE}.tar.gz.sha256"
