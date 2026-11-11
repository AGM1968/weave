#!/bin/bash
# SessionEnd hook: Claude Code adapter for the local steps before exit -- prune,
# a local state.sql flush, the graph-state checkpoint commit, and clearing the
# crash sentinel (v1.16.0). No GitHub sync and no push: with them the routine
# stopped completing (wv-a32e69). The implementation is wv_session_end_sync in
# scripts/lib/wv-lifecycle-end.sh; Codex reaches the same function through wv
# hook dispatch --event=SessionEnd --format=host (wv-25903d). It runs in-process
# here, as stop-check.sh does, so the wv it resolves is the one the hook pairs
# with and no wv start is added.

INPUT=$(cat)
HOOK_DIR="${BASH_SOURCE[0]:-$0}"
case "$HOOK_DIR" in */*) HOOK_DIR="${HOOK_DIR%/*}" ;; *) HOOK_DIR=. ;; esac
# Nearest copy first; a copy that fails to load falls through to the next.
for _le_dir in "$HOOK_DIR/../lib" "$HOOK_DIR/../../scripts/lib" "${HOME}/.config/weave/lib"; do
    [ -r "$_le_dir/wv-lifecycle-end.sh" ] || continue
    # shellcheck source=/dev/null
    . "$_le_dir/wv-lifecycle-end.sh" 2>/dev/null && declare -F wv_session_end_sync >/dev/null && break
    unset _WV_LIFECYCLE_END_LOADED
done
declare -F wv_session_end_sync >/dev/null || exit 0
# SessionEnd cannot block; a failed sync must not fail the exit.
wv_session_end_sync "$INPUT" || true
exit 0
