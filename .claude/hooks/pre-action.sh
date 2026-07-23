#!/bin/bash
# PreToolUse hook: Enforce graph-first before edits (require valid Context Pack)

set -e

INPUT=$(cat)
TOOL=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)
TOOL_INPUT=$(echo "$INPUT" | jq -r '.tool_input // empty' 2>/dev/null)

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "$HOOK_DIR/../lib/wv-resolve-project.sh" 2>/dev/null \
    || source "$HOOK_DIR/../../scripts/lib/wv-resolve-project.sh" 2>/dev/null \
    || source "${HOME}/.config/weave/lib/wv-resolve-project.sh" 2>/dev/null \
    || exit 0
source "$HOOK_DIR/../lib/wv-validate.sh" 2>/dev/null \
    || source "$HOOK_DIR/../../scripts/lib/wv-validate.sh" 2>/dev/null \
    || source "${HOME}/.config/weave/lib/wv-validate.sh" 2>/dev/null \
    || true
source "$HOOK_DIR/../lib/wv-config.sh" 2>/dev/null \
    || source "$HOOK_DIR/../../scripts/lib/wv-config.sh" 2>/dev/null \
    || source "${HOME}/.config/weave/lib/wv-config.sh" 2>/dev/null \
    || true
source "$HOOK_DIR/../lib/wv-hook-common.sh" 2>/dev/null \
    || source "$HOOK_DIR/../../scripts/lib/wv-hook-common.sh" 2>/dev/null \
    || source "${HOME}/.config/weave/lib/wv-hook-common.sh" 2>/dev/null \
    || true
source "$WV_PROJECT_DIR/scripts/lib/wv-resolve-runtime.sh" 2>/dev/null || source "$HOOK_DIR/../../scripts/lib/wv-resolve-runtime.sh" || exit 0
_hc_refresh

_hc_check_read_size "$TOOL" "$TOOL_INPUT" || exit 0
_hc_check_installed_path "$TOOL" "$TOOL_INPUT" || exit $?

_hc_classify_tool "$TOOL" "$TOOL_INPUT"
# Malformed mutation payloads fail closed instead of downgrading to inspection
# (wv-692c2d); empty stdin stays a manual-invocation no-op.
if [ "${_HC_MALFORMED:-false}" = true ] && [ -n "$INPUT" ]; then
    echo "PreToolUse payload malformed (${_HC_MALFORMED_REASON:-unknown}); failing closed" >&2
    exit 2
fi
[ "${_HC_BYPASS_CMD:-false}" = true ] && exit 0
[ "${_HC_SHOULD_CHECK:-false}" = false ] && exit 0

if [ -z "${WV_PROJECT_DIR:-}" ] || [ ! -d "${WV_PROJECT_DIR}/.weave" ]; then exit 0; fi
if [ ! -x "$WV" ]; then exit 0; fi

_hc_db_preflight || exit 0
_hc_init_hygiene_tally "$TOOL"

_PA_PHASE_RC=0
_hc_check_phase "${_HC_NEW_TOTAL:-}" "${_HC_WITH_ACTIVE:-}" "${_HC_TALLY_FILE:-}" || _PA_PHASE_RC=$?
if [ "$_PA_PHASE_RC" -ne 0 ]; then
    if [ "$_PA_PHASE_RC" -eq 2 ]; then exit 2; fi
    exit 0
fi

_hc_check_active_node "${_HC_NEW_TOTAL:-}" "${_HC_WITH_ACTIVE:-}" "${_HC_TALLY_FILE:-}" || exit $?
_hc_check_stale_node || exit $?
_hc_resolve_primary_node || exit 0

_hc_check_context_pack "$_HC_NODE_ID" || exit $?
if [ "${_HC_CONTEXT_STAMP_HIT:-false}" = true ]; then exit 0; fi
_hc_check_contradictions "$_HC_NODE_ID" || exit $?
_hc_check_blockers "$_HC_NODE_ID" || exit $?

touch "${_HC_HOT_ZONE}/.context_checked_${_HC_NODE_ID}" 2>/dev/null || true
exit 0
