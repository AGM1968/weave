#!/bin/bash
# PreToolUse hook: enforce graph-first before edits (require a valid Context Pack).
# Thin dispatcher: decisions live in _hc_* helpers in wv-hook-common.sh, and this
# file only wires them up and maps return codes onto hook exits. Budget: 60 lines.

set -e

INPUT=$(cat)
TOOL=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)
TOOL_INPUT=$(echo "$INPUT" | jq -r '.tool_input // empty' 2>/dev/null)

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# One rule for all five libraries, nearest the running hook first; order matters,
# as wv-resolve-project sets the WV_PROJECT_DIR wv-resolve-runtime reads. Readable
# is not loadable, and a copy that dies part way has already set its double-source
# guard: leaving it set makes every fallback return there, so the library never
# loads and the hook dies at its first _hc_* call with 127 — read as ALLOW.
_pa_source() {
    local lib="$1" dir guard
    for dir in "$HOOK_DIR/../lib" "$HOOK_DIR/../../scripts/lib" "${HOME}/.config/weave/lib"; do
        [ -r "$dir/$lib.sh" ] || continue
        # shellcheck source=/dev/null
        . "$dir/$lib.sh" 2>/dev/null && return 0
        while read -r guard; do unset "$guard"; done < <(compgen -v | grep -E '^_WV_[A-Z0-9_]*_LOADED$')
    done
    return 1
}
_pa_source wv-resolve-project || exit 0
for _pa_lib in wv-validate wv-config wv-hook-common; do _pa_source "$_pa_lib" || true; done
_pa_source wv-resolve-runtime || exit 0
_hc_refresh

_hc_check_read_size "$TOOL" "$TOOL_INPUT" || exit 0
_hc_check_installed_path "$TOOL" "$TOOL_INPUT" || exit $?

_hc_classify_tool "$TOOL" "$TOOL_INPUT"
_hc_check_payload "$INPUT" || exit $?
[ "${_HC_BYPASS_CMD:-false}" = true ] && exit 0
[ "${_HC_SHOULD_CHECK:-false}" = false ] && exit 0

if [ -z "${WV_PROJECT_DIR:-}" ] || [ ! -d "${WV_PROJECT_DIR}/.weave" ] || [ ! -x "$WV" ]; then exit 0; fi

_hc_db_preflight || exit 0
_hc_init_hygiene_tally "$TOOL"

_PA_PHASE_RC=0  # _hc_check_phase: 2 blocks the edit, other nonzero means stop-and-allow
_hc_check_phase "${_HC_NEW_TOTAL:-}" "${_HC_WITH_ACTIVE:-}" "${_HC_TALLY_FILE:-}" || _PA_PHASE_RC=$?
[ "$_PA_PHASE_RC" -eq 0 ] || { [ "$_PA_PHASE_RC" -eq 2 ] && exit 2; exit 0; }

_hc_check_active_node "${_HC_NEW_TOTAL:-}" "${_HC_WITH_ACTIVE:-}" "${_HC_TALLY_FILE:-}" || exit $?
_hc_check_stale_node || exit $?
_hc_resolve_primary_node || exit 0

_hc_check_context_pack "$_HC_NODE_ID" || exit $?
if [ "${_HC_CONTEXT_STAMP_HIT:-false}" = true ]; then exit 0; fi
_hc_check_contradictions "$_HC_NODE_ID" || exit $?
_hc_check_blockers "$_HC_NODE_ID" || exit $?

touch "${_HC_HOT_ZONE}/.context_checked_${_HC_NODE_ID}" 2>/dev/null || true
exit 0
