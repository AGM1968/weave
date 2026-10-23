#!/bin/bash
# PostToolUse hook: Claude Code adapter for the per-session wv call budget tally
# and its one-shot advisories. The guard is wv_potu_budget_guard in
# scripts/lib/wv-post-tool-use.sh; Codex reaches the same guard through wv hook
# dispatch --event=PostToolUse (wv-594381). It runs in-process here rather than
# through wv, which would add a wv start to every tool call.

INPUT=$(cat)
# The directory without forking: these run on every tool call.
HOOK_DIR="${BASH_SOURCE[0]:-$0}"
case "$HOOK_DIR" in */*) HOOK_DIR="${HOOK_DIR%/*}" ;; *) HOOK_DIR=. ;; esac
# Nearest copy first; a copy that fails to load falls through to the next.
for _potu_dir in "$HOOK_DIR/../lib" "$HOOK_DIR/../../scripts/lib" "${HOME}/.config/weave/lib"; do
    [ -r "$_potu_dir/wv-post-tool-use.sh" ] || continue
    # shellcheck source=/dev/null
    WV_POTU_ONLY=budget . "$_potu_dir/wv-post-tool-use.sh" 2>/dev/null && declare -F wv_potu_budget_guard >/dev/null && break
    unset _WV_POST_TOOL_USE_LOADED
done
declare -F wv_potu_budget_guard >/dev/null || exit 0
wv_potu_budget_guard "$INPUT"
exit $?
