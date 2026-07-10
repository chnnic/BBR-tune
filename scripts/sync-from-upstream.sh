#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TARGET="$ROOT/bbr-tune.sh"
METADATA="$ROOT/UPSTREAM.env"
UPSTREAM_URL="https://github.com/chnnic/SSH-Hardening.git"
MODE=sync

if [ "${1:-}" = "--check" ]; then
    MODE=check
    shift
fi

SOURCE_REPO="${1:-}"
TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/bbr-tune-sync.XXXXXX")
trap 'rm -rf "$TMP_DIR"' EXIT

metadata_value() {
    local KEY="$1"
    awk -F= -v key="$KEY" '$1 == key { sub(/^[^=]*=/, ""); print; exit }' "$METADATA"
}

if [ -z "$SOURCE_REPO" ]; then
    git clone -q "$UPSTREAM_URL" "$TMP_DIR/upstream"
    SOURCE_REPO="$TMP_DIR/upstream"
    if [ "$MODE" = check ]; then
        [ -f "$METADATA" ] || { echo "Missing $METADATA" >&2; exit 1; }
        PINNED_COMMIT=$(metadata_value UPSTREAM_COMMIT)
        git -C "$SOURCE_REPO" checkout -q "$PINNED_COMMIT"
    fi
fi

MODULE="$SOURCE_REPO/src/modules/bbr.sh"
CORE="$SOURCE_REPO/src/lib/core.sh"
[ -f "$MODULE" ] || { echo "Missing upstream BBR module: $MODULE" >&2; exit 1; }
[ -f "$CORE" ] || { echo "Missing upstream core: $CORE" >&2; exit 1; }
git -C "$SOURCE_REPO" diff --quiet -- src/modules/bbr.sh src/lib/core.sh || {
    echo "Upstream BBR/core changes must be committed before syncing" >&2
    exit 1
}

UPSTREAM_COMMIT=$(git -C "$SOURCE_REPO" rev-parse HEAD)
UPSTREAM_VERSION=$(awk -F'"' '/^APP_VERSION=/{print $2; exit}' "$CORE")
MODULE_SHA256=$(sha256sum "$MODULE" | awk '{print $1}')
[ -n "$UPSTREAM_VERSION" ] || { echo "Unable to read upstream version" >&2; exit 1; }

PREFIX="$TMP_DIR/prefix"
SUFFIX="$TMP_DIR/suffix"
GENERATED="$TMP_DIR/bbr-tune.sh"
awk '{print} /^# BEGIN SYNCED BBR MODULE - DO NOT EDIT BY HAND$/{exit}' "$TARGET" > "$PREFIX"
awk 'found || /^# END SYNCED BBR MODULE$/{found=1; print}' "$TARGET" > "$SUFFIX"
grep -q '^# BEGIN SYNCED BBR MODULE - DO NOT EDIT BY HAND$' "$PREFIX" || { echo "Missing module start marker" >&2; exit 1; }
grep -q '^# END SYNCED BBR MODULE$' "$SUFFIX" || { echo "Missing module end marker" >&2; exit 1; }

{
    cat "$PREFIX"
    cat "$MODULE"
    cat "$SUFFIX"
} > "$GENERATED"
sed -i -E "s/(同步至 )V[0-9]+\.[0-9]+\.[0-9]+/\1${UPSTREAM_VERSION}/" "$GENERATED"
bash -n "$GENERATED"

if [ "$MODE" = check ]; then
    cmp -s "$GENERATED" "$TARGET" || {
        echo "bbr-tune.sh is not synchronized with ${UPSTREAM_COMMIT}" >&2
        exit 1
    }
    [ "$(metadata_value UPSTREAM_MODULE_SHA256)" = "$MODULE_SHA256" ] || {
        echo "UPSTREAM.env module hash is stale" >&2
        exit 1
    }
    echo "BBR standalone script matches ${UPSTREAM_VERSION} (${UPSTREAM_COMMIT})."
    exit 0
fi

mv "$GENERATED" "$TARGET"
chmod 755 "$TARGET"
cat > "$TMP_DIR/UPSTREAM.env" << EOF
UPSTREAM_REPOSITORY=${UPSTREAM_URL}
UPSTREAM_COMMIT=${UPSTREAM_COMMIT}
UPSTREAM_VERSION=${UPSTREAM_VERSION}
UPSTREAM_MODULE_SHA256=${MODULE_SHA256}
EOF
mv "$TMP_DIR/UPSTREAM.env" "$METADATA"
sed -i -E "s/(同步至 )V[0-9]+\.[0-9]+\.[0-9]+/\1${UPSTREAM_VERSION}/" "$ROOT/README.md"
echo "Synchronized BBR-tune with ${UPSTREAM_VERSION} (${UPSTREAM_COMMIT})."
