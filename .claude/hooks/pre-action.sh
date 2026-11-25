#!/usr/bin/env bash
# PreToolUse hook: Claude Code adapter for the edit guard (graph-first before
# edits). The guard is wv_ptu_edit_guard in scripts/lib/wv-pre-tool-use.sh, which
# loads wv-hook-common and the rest of its libraries itself; Codex reaches the
# same guard through wv hook dispatch --event=PreToolUse (wv-d3fbcb). It runs
# in-process here rather than through wv, which would add a wv start to every
# tool call (judge panel 2026-10-01).
# wv bash guard (wv-7257a8): bash >= 4 or a clear refusal. Identical in every executed entry point; master: scripts/lib/wv-bash-guard.sh.
_wv_bash_guard() {
    if [ -n "${WV_TEST_BASH_TOO_OLD:-}" ] && [ "${WV_TEST_MODE:-}" != 1 ]; then echo "wv: WV_TEST_BASH_TOO_OLD needs WV_TEST_MODE=1; ignoring it." >&2; fi
    if [ "${BASH_VERSINFO[0]:-0}" -ge 4 ] && ! { [ "${WV_TEST_MODE:-}" = 1 ] && [ "${WV_TEST_BASH_TOO_OLD:-}" = 1 ]; }; then
        unset WV_BASH_REEXEC
        return 0
    fi
    local b
    if [ -z "${WV_BASH_REEXEC:-}" ] && [ -f "$0" ]; then
        for b in ${WV_BASH:-} /opt/homebrew/bin/bash /usr/local/bin/bash /usr/bin/bash /bin/bash; do
            # shellcheck disable=SC2016  # the child bash expands it
            if [ -x "$b" ] && [ "$("$b" -c 'echo "${BASH_VERSINFO[0]}"' 2>/dev/null)" -ge 4 ] 2>/dev/null; then
                WV_BASH_REEXEC=1 WV_TEST_BASH_TOO_OLD='' exec "$b" "$0" "$@"
            fi
        done
    fi
    echo "wv: $0 needs bash 4 or newer but is running under bash ${BASH_VERSION:-unknown}." >&2
    echo "    On macOS /bin/bash is 3.2: install a newer one (brew install bash) or set WV_BASH to it." >&2
    exit 1
}
_wv_bash_guard "$@"
# end wv bash guard

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
