#!/bin/bash
# PreToolUse hook: Claude Code adapter for the claim preflight (done_criteria,
# alias, risks before wv work / wv update --status=active). The guard is
# wv_ptu_claim_guard in scripts/lib/wv-pre-tool-use.sh; Codex reaches the same
# guard through wv hook dispatch --event=PreToolUse (wv-d3fbcb).

INPUT=$(cat)
# The directory without forking: these run on every tool call.
HOOK_DIR="${BASH_SOURCE[0]:-$0}"
case "$HOOK_DIR" in */*) HOOK_DIR="${HOOK_DIR%/*}" ;; *) HOOK_DIR=. ;; esac
# Nearest copy first; a copy that fails to load falls through to the next.
for _ptu_dir in "$HOOK_DIR/../lib" "$HOOK_DIR/../../scripts/lib" "${HOME}/.config/weave/lib"; do
    [ -r "$_ptu_dir/wv-pre-tool-use.sh" ] || continue
    # shellcheck source=/dev/null
    . "$_ptu_dir/wv-pre-tool-use.sh" 2>/dev/null && declare -F wv_ptu_claim_guard >/dev/null && break
    unset _WV_PRE_TOOL_USE_LOADED
done
declare -F wv_ptu_claim_guard >/dev/null || exit 0
wv_ptu_claim_guard "$INPUT"
exit $?
