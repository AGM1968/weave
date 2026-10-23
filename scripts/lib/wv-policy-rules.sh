#!/bin/bash
# GENERATED FROM contracts/policy-rules-v1.json -- DO NOT EDIT
#
# Regenerate: python3 scripts/weave_policy.py generate
# Verify:     python3 scripts/weave_policy.py check
#
# _wv_policy_applicable <operation> [suboperation] prints the rules that can
# decide inside such a call, space-separated and sorted. A suboperation
# branch already includes its operation's rules.

WV_POLICY_SCHEMA="weave.policy-rules.v1"
WV_POLICY_CONTRACT_VERSION="1.13.1"
WV_POLICY_IDENTITY="b2ee8de64da4f4750849fda6635967b3622f188ed7130be8bab6968b4bcedc2e"

_wv_policy_applicable() {
    case "${1}:${2-}" in
        repo-class:set) printf %s "owned_override_requires_acknowledgement"; return 0 ;;
    esac
    case "$1" in
        add) printf %s "active_add_requires_claim_readiness add_duplicate_check orphan_prevention reconstruct_never_overwrites"; return 0 ;;
        batch-done) printf %s "close_awaits_human_verification close_complexity_ceiling close_requires_learning close_requires_quality_evidence close_tests_not_red close_trend_not_deteriorating completion_scope_integrity finding_close_requires_violation_type learning_overlap_advisory"; return 0 ;;
        block) printf %s "block_graph_acyclic"; return 0 ;;
        bulk-update) printf %s "close_complexity_ceiling close_tests_not_red close_trend_not_deteriorating completion_scope_integrity reopen_requires_explicit_intent"; return 0 ;;
        compact) printf %s "compact_waits_for_claims"; return 0 ;;
        cutover) printf %s "cutover_waits_for_claims"; return 0 ;;
        delete) printf %s "delete_preserves_children"; return 0 ;;
        doctor) printf %s "repository_write_requires_owned"; return 0 ;;
        done) printf %s "close_awaits_human_verification close_complexity_ceiling close_requires_learning close_requires_quality_evidence close_tests_not_red close_trend_not_deteriorating completion_scope_integrity finding_close_requires_violation_type learning_overlap_advisory"; return 0 ;;
        init) printf %s "init_preserves_existing_graph init_refuses_symlinked_weave_dir repository_write_requires_owned"; return 0 ;;
        init-repo) printf %s "repository_write_requires_owned"; return 0 ;;
        quick) printf %s "add_duplicate_check close_complexity_ceiling close_tests_not_red close_trend_not_deteriorating completion_scope_integrity"; return 0 ;;
        recover) printf %s "recovery_never_fabricates_closure"; return 0 ;;
        resolve) printf %s "close_complexity_ceiling close_tests_not_red close_trend_not_deteriorating completion_scope_integrity"; return 0 ;;
        ship) printf %s "close_awaits_human_verification close_complexity_ceiling close_requires_learning close_requires_quality_evidence close_tests_not_red close_trend_not_deteriorating completion_scope_integrity finding_close_requires_violation_type learning_overlap_advisory"; return 0 ;;
        ship-agent) printf %s "close_awaits_human_verification close_complexity_ceiling close_requires_learning close_requires_quality_evidence close_tests_not_red close_trend_not_deteriorating completion_scope_integrity finding_close_requires_violation_type learning_overlap_advisory"; return 0 ;;
        sync) printf %s "sync_shrink_floor"; return 0 ;;
        update) printf %s "close_complexity_ceiling close_tests_not_red close_trend_not_deteriorating completion_scope_integrity reopen_requires_explicit_intent"; return 0 ;;
        work) printf %s "claim_ownership reopen_requires_explicit_intent reserved_slot_claim"; return 0 ;;
    esac
    return 0
}
