#!/bin/bash
# PreToolUse hook: Claude Code adapter for the edit guard (graph-first before
# edits). The guard is wv_ptu_edit_guard in scripts/lib/wv-pre-tool-use.sh, which
# loads wv-hook-common and the rest of its libraries itself; Codex reaches the
# same guard through wv hook dispatch --event=PreToolUse (wv-d3fbcb). It runs
# in-process here rather than through wv, which would add a wv start to every
# tool call (judge panel 2026-10-01).

INPUT=$(cat)
# The directory without forking: these run on every tool call.
HOOK_DIR="${BASH_SOURCE[0]:-$0}"
case "$HOOK_DIR" in */*) HOOK_DIR="${HOOK_DIR%/*}" ;; *) HOOK_DIR=. ;; esac
# Nearest copy first: a checkout hook runs the checkout's guards, an installed
# hook the installed ones. A copy that fails to load falls through to the next.
for _ptu_dir in "$HOOK_DIR/../lib" "$HOOK_DIR/../../scripts/lib" "${HOME}/.config/weave/lib"; do
    [ -r "$_ptu_dir/wv-pre-tool-use.sh" ] || continue
    # shellcheck source=/dev/null
    WV_PTU_EDIT_ONLY=1 . "$_ptu_dir/wv-pre-tool-use.sh" 2>/dev/null && declare -F wv_ptu_edit_guard >/dev/null && break
    unset _WV_PRE_TOOL_USE_LOADED
done
declare -F wv_ptu_edit_guard >/dev/null || { echo "⚠ Weave guard inactive: wv-pre-tool-use.sh could not be loaded — run ./install.sh" >&2; exit 0; }
wv_ptu_edit_guard "$INPUT"
exit $?
