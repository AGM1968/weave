#!/bin/bash
# GENERATED FROM contracts/command-capabilities.json -- DO NOT EDIT
#
# Regenerate: python3 scripts/weave_registry.py generate
# Verify:     python3 scripts/weave_registry.py check
#
# A listed suboperation branch is answered there and never reaches the
# command-level branch below it, so an unlisted suboperation falls back to
# the command-level row -- which validation guarantees is never weaker.

WV_CAPABILITIES_SCHEMA="weave.command-capabilities.v1"
WV_CAPABILITIES_SHA256="bb2808e75856202bfd6623498ec256fec65584a0ff6d4e11576791b55853b283"
WV_CAPABILITIES_SCHEMA_SHA256="e0ce380f3281d49ee5d6b8bfab1f0d6cf9160d1544d526c8df1d1eab3e9ca4bb"
WV_CAPABILITIES_IDENTITY="159f47aff9c03c633e00326f7cda690d4fe1cea1622ff1694270ae99f64725b0"

_wv_cap_serve() {
    case "${1}:${2-}" in
        breadcrumbs:capsule|breadcrumbs:clear|breadcrumbs:save|breadcrumbs:show|config:disable|config:enable|config:get|config:list|config:set|config:show|config:unset|findings:list|findings:promote|hotzone:db|hotzone:gc|hotzone:list|memory:crystallize|memory:import|memory:recall|memory:render|memory:scan|quality:diff|quality:functions|quality:hotspots|quality:patterns|quality:promote|quality:prose-shape|quality:reset|quality:scan|quality:structural-search|repo-class:audit|repo-class:set|trails:capsule|trails:clear|trails:save|trails:show) return 1 ;;
    esac
    case "$1" in
        bootstrap|list|ready) return 0 ;;
    esac
    return 1
}

_wv_cap_invalidate() {
    case "${1}:${2-}" in
        config:disable|config:enable|config:set|config:unset|findings:promote|memory:crystallize|memory:import|memory:render) return 0 ;;
        breadcrumbs:capsule|breadcrumbs:clear|breadcrumbs:save|breadcrumbs:show|config:get|config:list|config:show|findings:list|hotzone:db|hotzone:gc|hotzone:list|memory:recall|memory:scan|quality:diff|quality:functions|quality:hotspots|quality:patterns|quality:promote|quality:prose-shape|quality:reset|quality:scan|quality:structural-search|repo-class:audit|repo-class:set|trails:capsule|trails:clear|trails:save|trails:show) return 1 ;;
    esac
    case "$1" in
        add|allowed-tools|batch|batch-done|block|bulk-update|clean-ghosts|commit-refs|compact|config|delete|done|enrich-topology|findings|hook|import|link|load|memory|plan|prune|quick|recover|reindex|remember|resolve|session-summary|ship|ship-agent|sync|test-record|touch|unarchive|unlink|update|work) return 0 ;;
    esac
    return 1
}

_wv_cap_evidence_class() {
    case "${1}:${2-}" in
        hotzone:gc|quality:patterns|quality:reset|quality:scan) printf %s administrative; return 0 ;;
        breadcrumbs:clear|breadcrumbs:save|config:disable|config:enable|config:set|config:unset|findings:promote|memory:crystallize|memory:import|memory:render|quality:promote|repo-class:set|trails:clear|trails:save) printf %s mutation_attempt; return 0 ;;
        breadcrumbs:capsule|breadcrumbs:show|config:get|config:list|config:show|findings:list|hotzone:db|hotzone:list|memory:recall|memory:scan|quality:diff|quality:functions|quality:hotspots|quality:prose-shape|quality:structural-search|repo-class:audit|trails:capsule|trails:show) printf %s observation; return 0 ;;
    esac
    case "$1" in
        context-policy|hotzone|index|self-update|selftest|uninstall) printf %s administrative; return 0 ;;
        add|allowed-tools|batch|batch-done|block|breadcrumbs|bulk-update|clean-ghosts|commit-refs|compact|config|cutover|delete|doctor|done|enrich-topology|findings|hook|import|init|init-repo|link|load|memory|plan|prune|quality|quick|recover|reindex|remember|repo-class|resolve|session-summary|ship|ship-agent|sync|test-record|touch|trails|unarchive|unlink|update|work) printf %s mutation_attempt; return 0 ;;
        analyze|audit-pitfalls|bootstrap|bootstrap-agent|cache|context|digest|discover|edge-types|edges|guide|health|impact|learnings|list|mcp-status|overview|path|pattern-audit|pending-close|preflight|query|ready|refs|related|search|show|status|test-status|tree|validate-finding) printf %s observation; return 0 ;;
    esac
    return 1
}

_wv_cap_targets() {
    case "${1}:${2-}" in
        breadcrumbs:capsule|breadcrumbs:show|config:get|config:list|config:show|findings:list|hotzone:db|hotzone:list|memory:recall|memory:scan|quality:diff|quality:functions|quality:hotspots|quality:prose-shape|quality:structural-search|repo-class:audit|trails:capsule|trails:show) printf %s ""; return 0 ;;
        breadcrumbs:clear|breadcrumbs:save|findings:promote|hotzone:gc|memory:crystallize|memory:import|quality:promote|trails:clear|trails:save) printf %s "brain_db"; return 0 ;;
        config:disable|config:enable|config:set|config:unset) printf %s "installation repo_state"; return 0 ;;
        memory:render) printf %s "repo_state"; return 0 ;;
        quality:patterns|quality:reset|quality:scan) printf %s "quality_db"; return 0 ;;
        repo-class:set) printf %s "git"; return 0 ;;
    esac
    case "$1" in
        add|allowed-tools|batch|batch-done|block|breadcrumbs|bulk-update|clean-ghosts|compact|delete|done|enrich-topology|findings|hook|hotzone|import|index|link|load|plan|recover|reindex|remember|resolve|session-summary|test-record|touch|trails|unarchive|unlink|update|work) printf %s "brain_db"; return 0 ;;
        analyze|audit-pitfalls|bootstrap|bootstrap-agent|cache|context|digest|discover|edge-types|edges|guide|health|impact|learnings|list|mcp-status|overview|path|pattern-audit|pending-close|preflight|query|ready|refs|related|search|selftest|show|status|test-status|tree|validate-finding) printf %s ""; return 0 ;;
        commit-refs|quick) printf %s "brain_db git"; return 0 ;;
        config|doctor) printf %s "installation repo_state"; return 0 ;;
        context-policy|init-repo) printf %s "repo_state working_tree"; return 0 ;;
        cutover) printf %s "repo_state"; return 0 ;;
        init|memory|prune) printf %s "brain_db repo_state"; return 0 ;;
        quality) printf %s "brain_db quality_db"; return 0 ;;
        repo-class) printf %s "git"; return 0 ;;
        self-update|uninstall) printf %s "installation"; return 0 ;;
        ship|ship-agent) printf %s "brain_db external_projection"; return 0 ;;
        sync) printf %s "brain_db external_projection repo_state"; return 0 ;;
    esac
    return 1
}

_wv_cap_refines() {
    case "${1}:${2-}" in
        breadcrumbs:capsule|breadcrumbs:clear|breadcrumbs:save|breadcrumbs:show|config:disable|config:enable|config:get|config:list|config:set|config:show|config:unset|findings:list|findings:promote|hotzone:db|hotzone:gc|hotzone:list|memory:crystallize|memory:import|memory:recall|memory:render|memory:scan|quality:diff|quality:functions|quality:hotspots|quality:patterns|quality:promote|quality:prose-shape|quality:reset|quality:scan|quality:structural-search|repo-class:audit|repo-class:set|trails:capsule|trails:clear|trails:save|trails:show) return 0 ;;
    esac
    return 1
}

_wv_cap_known() {
    case "$1" in
        add|allowed-tools|analyze|audit-pitfalls|batch|batch-done|block|bootstrap|bootstrap-agent|breadcrumbs|bulk-update|cache|clean-ghosts|commit-refs|compact|config|context|context-policy|cutover|delete|digest|discover|doctor|done|edge-types|edges|enrich-topology|findings|guide|health|hook|hotzone|impact|import|index|init|init-repo|learnings|link|list|load|mcp-status|memory|overview|path|pattern-audit|pending-close|plan|preflight|prune|quality|query|quick|ready|recover|refs|reindex|related|remember|repo-class|resolve|search|self-update|selftest|session-summary|ship|ship-agent|show|status|sync|test-record|test-status|touch|trails|tree|unarchive|uninstall|unlink|update|validate-finding|work) return 0 ;;
    esac
    return 1
}
