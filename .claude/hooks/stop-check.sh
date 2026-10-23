#!/bin/bash
# Stop hook: Claude Code adapter for the session-end guard. The guard is
# wv_stop_guard in scripts/lib/wv-lifecycle-end.sh; Codex reaches the same guard
# through wv hook dispatch --event=Stop --format=host (wv-25903d). It runs
# in-process here rather than through wv, which would add a wv start to every
# response.
#
# Hard block: an active node claimed by this agent, as {"decision":"block"}
# with exit 0. Soft warn on stderr: uncommitted changes, unpushed commits,
# unsaved weave state. No network calls.

INPUT=$(cat)
# The directory without forking: this runs after every response.
HOOK_DIR="${BASH_SOURCE[0]:-$0}"
case "$HOOK_DIR" in */*) HOOK_DIR="${HOOK_DIR%/*}" ;; *) HOOK_DIR=. ;; esac
# Nearest copy first; a copy that fails to load falls through to the next.
for _le_dir in "$HOOK_DIR/../lib" "$HOOK_DIR/../../scripts/lib" "${HOME}/.config/weave/lib"; do
    [ -r "$_le_dir/wv-lifecycle-end.sh" ] || continue
    # shellcheck source=/dev/null
    . "$_le_dir/wv-lifecycle-end.sh" 2>/dev/null && declare -F wv_stop_guard >/dev/null && break
    unset _WV_LIFECYCLE_END_LOADED
done
declare -F wv_stop_guard >/dev/null || exit 0
wv_stop_guard "$INPUT"
exit $?
