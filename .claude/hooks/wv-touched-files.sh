#!/bin/bash
# PostToolUse hook: capture file paths edited via Edit/Write/NotebookEdit into
# (a) the active node's metadata.touched_files list (dedup, cap 50), and
# (b) a per-session recent-edits ring buffer on tmpfs (cap 20, FIFO).
#
# Together they let `wv ready` re-rank: nodes whose touched_files overlap
# recent session edits float to top — the agent steers toward work that is
# already in cache (file context loaded, mental model warm).
#
# Sprint B1 from PROPOSAL-wv-active-counterweight (relevance signal in the
# in-source layer; the runtime tracked similar via session edit history).

set -euo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "$HOOK_DIR/../lib/wv-resolve-project.sh" 2>/dev/null || source "$HOOK_DIR/../../scripts/lib/wv-resolve-project.sh" || exit 0
source "$HOOK_DIR/../lib/wv-hook-common.sh" 2>/dev/null \
    || source "$HOOK_DIR/../../scripts/lib/wv-hook-common.sh" 2>/dev/null \
    || source "${HOME}/.config/weave/lib/wv-hook-common.sh" 2>/dev/null \
    || true
source "$WV_PROJECT_DIR/scripts/lib/wv-resolve-runtime.sh" 2>/dev/null || source "$HOOK_DIR/../../scripts/lib/wv-resolve-runtime.sh" || exit 0
_hc_refresh

INPUT=$(cat)
TOOL=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)
is_attribution_tool "$TOOL" || exit 0

# Skip on tool failure. jq's `// true` collapses explicit false → true (boolean
# alternative semantics), so check explicit equality instead.
if echo "$INPUT" | jq -e '.tool_response.success == false' >/dev/null 2>&1; then
    exit 0
fi

FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // .tool_input.filePath // .tool_input.path // ""' 2>/dev/null)
[ -z "$FILE_PATH" ] && exit 0

# Normalize to repo-relative path when possible (stable comparison key).
REPO_ROOT="${WV_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
# Reject home dir — hook firing from ~ must not treat home as project root.
if [ "$REPO_ROOT" = "$HOME" ] || [ "$REPO_ROOT" = "/root" ]; then REPO_ROOT=""; fi
REL_PATH="$FILE_PATH"
case "$FILE_PATH" in
    "$REPO_ROOT"/*) REL_PATH="${FILE_PATH#$REPO_ROOT/}" ;;
esac

# Per-repo session ring on tmpfs (matches budget-tally hot-zone naming).
_TF_HOT_ZONE="${_HC_HOT_ZONE}"
RING_DIR="${WV_TOUCHED_DIR:-$_TF_HOT_ZONE}"
RING_FILE="${RING_DIR}/recent-edits.txt"
mkdir -p "$RING_DIR" 2>/dev/null || exit 0

# Append to ring (newest at bottom), keep last 20 unique paths.
RING_CAP="${WV_TOUCHED_RING_CAP:-20}"
{
    if [ -f "$RING_FILE" ]; then
        grep -vF -- "$REL_PATH" "$RING_FILE" 2>/dev/null || true
    fi
    echo "$REL_PATH"
} | tail -n "$RING_CAP" > "${RING_FILE}.new" 2>/dev/null && mv "${RING_FILE}.new" "$RING_FILE" 2>/dev/null || true

# Locate active node and append to its metadata.touched_files (cap 50).
_TF_DB="${WV_DB:-$_HC_DB}"
[ ! -f "$_TF_DB" ] && exit 0

ACTIVE_ID=$(resolve_active_primary "$_TF_DB" "$_TF_HOT_ZONE") || true
[ -z "$ACTIVE_ID" ] && exit 0

CUR_META=$(sqlite3 "$_TF_DB" "SELECT COALESCE(metadata, '{}') FROM nodes WHERE id='$ACTIVE_ID';" 2>/dev/null)
[ -z "$CUR_META" ] && CUR_META='{}'

NODE_CAP="${WV_TOUCHED_NODE_CAP:-50}"
NEW_META=$(echo "$CUR_META" | jq \
    --arg path "$REL_PATH" \
    --argjson cap "$NODE_CAP" \
    '.touched_files = (((.touched_files // []) - [$path]) + [$path] | .[-$cap:])' 2>/dev/null || echo "$CUR_META")

# SQL-escape single quotes by doubling them.
ACTIVE_ID_ESC="${ACTIVE_ID//\'/\'\'}"
REL_PATH_ESC="${REL_PATH//\'/\'\'}"
NEW_META_ESC="${NEW_META//\'/\'\'}"
sqlite3 "$_TF_DB" "UPDATE nodes SET metadata='$NEW_META_ESC', updated_at=CURRENT_TIMESTAMP WHERE id='$ACTIVE_ID';" 2>/dev/null || true
sqlite3 "$_TF_DB" "INSERT OR IGNORE INTO node_files(node_id, path) VALUES ('$ACTIVE_ID_ESC', '$REL_PATH_ESC');" 2>/dev/null || true

exit 0
