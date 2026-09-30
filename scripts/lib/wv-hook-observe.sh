#!/bin/bash
# wv-hook-observe.sh — typed evidence of a host-hook policy decision (wv-664b7f).
#
# A host hook decides before wv is invoked, so its decision has no wv call and
# never enters the attempt journal or the E1 denominator (contracts/
# policy-rules-v1.json denominator, wv-bd3041). Without a record, a hook denial
# names no rule anywhere, and policy totality cannot tell a hook rule that
# fired from one that never ran. _hc_observe writes that record: the contract
# rule_id, the decision, any bypass, and the contract identity, and nothing
# that identifies a wv call (contracts/hook-observation-v1.schema.json).
#
# Opt-in, like the attempt journal: WV_HOOK_OBSERVATIONS names a JSONL path.
# Unset, this does nothing. It never changes a hook's decision or exit status.
# No side effects on source, so the hottest hook (bash-dedup) can load it.

[ -n "${_WV_HOOK_OBSERVE_LOADED:-}" ] && return 0
_WV_HOOK_OBSERVE_LOADED=1
_HO_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# _hc_observe <rule_id> <decision> [bypass]
# The hook event defaults to PreToolUse; a Stop hook sets _HC_HOOK_EVENT=Stop.
_hc_observe() {
    local rule="$1" decision="$2" bypass="${3:-}" path="${WV_HOOK_OBSERVATIONS:-}"
    [ -n "$path" ] || return 0
    if [ -z "${WV_POLICY_IDENTITY:-}" ]; then
        # shellcheck source=/dev/null
        . "$_HO_LIB_DIR/wv-policy-rules.sh" 2>/dev/null ||
            . "${HOME}/.local/lib/weave/lib/wv-policy-rules.sh" 2>/dev/null || true
    fi
    jq -cn \
        --arg hook "$(basename "${0:-hook}")" \
        --arg hook_event "${_HC_HOOK_EVENT:-PreToolUse}" \
        --arg rule "$rule" --arg decision "$decision" --arg bypass "$bypass" \
        --arg identity "${WV_POLICY_IDENTITY:+sha256:$WV_POLICY_IDENTITY}" \
        --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{format: "weave.hook-observation.v1", event: "hook_decision", hook: $hook,
          hook_event: $hook_event, rule: $rule, decision: $decision,
          policy_identity: $identity, ts: $ts}
         + (if $bypass == "" then {} else {bypass: $bypass} end)' \
        >> "$path" 2>/dev/null || true
    return 0
}
