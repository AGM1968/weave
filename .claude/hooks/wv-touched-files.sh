#!/bin/bash
# PostToolUse hook: Claude Code adapter for file attribution (node_files, the
# capped touched_files list and the session's recent-edits ring). The guard is
# wv_potu_touched_guard in scripts/lib/wv-post-tool-use.sh; Codex reaches the
# same guard through wv hook dispatch --event=PostToolUse (wv-594381). It runs
# in-process here rather than through wv, which would add a wv start to every
# tool call.

INPUT=$(cat)
# The directory without forking: these run on every tool call.
HOOK_DIR="${BASH_SOURCE[0]:-$0}"
case "$HOOK_DIR" in */*) HOOK_DIR="${HOOK_DIR%/*}" ;; *) HOOK_DIR=. ;; esac
# Nearest copy first; a copy that fails to load falls through to the next.
for _potu_dir in "$HOOK_DIR/../lib" "$HOOK_DIR/../../scripts/lib" "${HOME}/.config/weave/lib"; do
    [ -r "$_potu_dir/wv-post-tool-use.sh" ] || continue
    # shellcheck source=/dev/null
    WV_POTU_ONLY=touched . "$_potu_dir/wv-post-tool-use.sh" 2>/dev/null && declare -F wv_potu_touched_guard >/dev/null && break
    unset _WV_POST_TOOL_USE_LOADED
done
declare -F wv_potu_touched_guard >/dev/null || exit 0
wv_potu_touched_guard "$INPUT"
exit $?
