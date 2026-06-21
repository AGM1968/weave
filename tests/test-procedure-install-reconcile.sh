#!/usr/bin/env bash
# A real local install must reconcile canonical procedures by deletion, not only
# copy additions. Otherwise a removed procedure remains in CONFIG_DIR and keeps
# projecting into consumer repos on later init/update runs.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
SOURCE="$TMP/source"
CONFIG="$TMP/config"
REPO="$TMP/repo"

# Use a disposable full source tree so the installer exercises its normal local
# source path without touching this checkout or the user's install.
mkdir -p "$SOURCE" "$REPO"
cp -a "$ROOT/." "$SOURCE/"

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
