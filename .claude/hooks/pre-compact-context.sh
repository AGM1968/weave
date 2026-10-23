#!/bin/bash
# PreCompact hook: Claude Code adapter for the graph-state checkpoint commit and
# the compact work snapshot (~100-200 tokens) printed before conversation
# compaction. The implementation is wv_pre_compact_context in
# scripts/lib/wv-lifecycle-end.sh; Codex reaches the same function through wv
# hook dispatch --event=PreCompact --format=host (wv-25903d). It runs in-process
# here, as stop-check.sh does, so the wv it resolves is the one the hook pairs
# with and no wv start is added.

# The payload is not read by the snapshot; never wait on a terminal for it.
INPUT='{}'
[ -t 0 ] || INPUT=$(cat)
HOOK_DIR="${BASH_SOURCE[0]:-$0}"
case "$HOOK_DIR" in */*) HOOK_DIR="${HOOK_DIR%/*}" ;; *) HOOK_DIR=. ;; esac
# Nearest copy first; a copy that fails to load falls through to the next.
for _le_dir in "$HOOK_DIR/../lib" "$HOOK_DIR/../../scripts/lib" "${HOME}/.config/weave/lib"; do
    [ -r "$_le_dir/wv-lifecycle-end.sh" ] || continue
    # shellcheck source=/dev/null
    . "$_le_dir/wv-lifecycle-end.sh" 2>/dev/null && declare -F wv_pre_compact_context >/dev/null && break
    unset _WV_LIFECYCLE_END_LOADED
done
declare -F wv_pre_compact_context >/dev/null || exit 0
# Compaction must go ahead even when the snapshot cannot be built.
wv_pre_compact_context "$INPUT" || true
exit 0
