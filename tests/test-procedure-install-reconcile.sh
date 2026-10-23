#!/usr/bin/env bash
# A real local install must reconcile canonical procedures by deletion, not only
# copy additions. Otherwise a removed procedure remains in CONFIG_DIR and keeps
# projecting into consumer repos on later init/update runs.
set -euo pipefail
export WV_TEST_SUITE=1  # the user's config.env cannot log this suite's wv calls (wv-6b0f57)

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
SOURCE="$TMP/source"
CONFIG="$TMP/config"
REPO="$TMP/repo"

# Use a disposable full source tree so the installer exercises its normal local
# source path without touching this checkout or the user's install.
mkdir -p "$SOURCE" "$REPO"
# Copy the source tree WITHOUT the volatile directories. `cp -a "$ROOT/."`
# copied .git, .weave and mcp/node_modules too: tens of thousands of files that
# this fixture never reads, being written by whatever else the aggregate is
# running at the time. A file that appears or vanishes mid-copy fails cp, and
# under set -e that ends the suite before its first assertion -- which is how
# this pair reported 0/0 in the aggregate while passing standalone.
# Amp review/measurement scratch is volatile too (wv-9c0896).
rsync -a --exclude=.git --exclude=.weave --exclude=node_modules \
    --exclude=__pycache__ --exclude=dist --exclude='/.amp/in/' "$ROOT/" "$SOURCE/"

PROC="$SOURCE/templates/procedures/zzz-install-reconcile.md"
ASSET="$SOURCE/templates/procedures/zzz-install-reconcile.txt"
printf '%s\n' 'fixture asset' > "$ASSET"
printf '%s\n' '---' 'id: zzz-install-reconcile' 'description: install reconcile fixture' \
    'fallback: "wv guide --procedure=zzz-install-reconcile"' 'adapters: [codex]' \
    'visibility: shared' 'status: ready' 'resources:' '  - path: zzz-install-reconcile.txt' \
    '---' '# fixture' > "$PROC"

install_local() {
    HOME="$TMP/home" WV_INSTALL_DIR="$TMP/bin" WV_LIB_DIR="$TMP/lib" WV_CONFIG_DIR="$CONFIG" \
        SKIP_AST_GREP=1 bash "$SOURCE/install.sh" --no-mcp --local-source="$SOURCE" >/dev/null
}

install_local
[ -f "$CONFIG/procedures/zzz-install-reconcile.md" ]
[ -f "$CONFIG/procedures/zzz-install-reconcile.txt" ]
WV_CONFIG_DIR="$CONFIG" "$CONFIG/project-procedures.sh" --repo="$REPO" --agent=codex
[ "$(jq -r '[.procedures[]?.id] | index("zzz-install-reconcile")' "$REPO/.codex/weave.json")" != "null" ]

rm "$PROC" "$ASSET"
install_local
[ ! -e "$CONFIG/procedures/zzz-install-reconcile.md" ]
[ ! -e "$CONFIG/procedures/zzz-install-reconcile.txt" ]
WV_CONFIG_DIR="$CONFIG" "$CONFIG/project-procedures.sh" --repo="$REPO" --agent=codex
[ "$(jq -r '[.procedures[]?.id] | index("zzz-install-reconcile")' "$REPO/.codex/weave.json")" = "null" ]

echo 'Results: 5/5 passed'
