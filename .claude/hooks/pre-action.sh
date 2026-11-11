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
# No guard library at all fails closed for an edit to a file in a Weave checkout
# (wv-187945, owner ruling 2026-11-03), as the guard itself does when one of its
# own libraries will not load. Anything else passes with the warning.
if ! declare -F wv_ptu_edit_guard >/dev/null; then
    _pa_tool=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)
    _pa_path=$(printf '%s' "$INPUT" | jq -r '.tool_input | (.file_path // .filePath // .notebook_path // .path // empty)' 2>/dev/null)
    _pa_dir=$(dirname -- "${_pa_path:-.}")
    while [ ! -d "$_pa_dir" ] && [ "$_pa_dir" != / ]; do _pa_dir=$(dirname -- "$_pa_dir"); done
    _pa_root=$(git -C "$_pa_dir" rev-parse --show-toplevel 2>/dev/null)
    case "$_pa_tool" in
        Edit|Write|MultiEdit|NotebookEdit)
            if [ -n "$_pa_root" ] && [ -d "$_pa_root/.weave" ]; then
                echo "🛑 Weave edit guard could not run: wv-pre-tool-use.sh could not be loaded." >&2
                echo "   Edits in $_pa_root are blocked until it can. Fix: ./install.sh, or wv self-update then wv init-repo --update (wv-187945)." >&2
                exit 2
            fi ;;
    esac
    echo "⚠ Weave guard inactive: wv-pre-tool-use.sh could not be loaded — run ./install.sh" >&2
    exit 0
fi
wv_ptu_edit_guard "$INPUT"
exit $?
