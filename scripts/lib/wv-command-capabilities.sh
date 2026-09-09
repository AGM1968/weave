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
WV_CAPABILITIES_SHA256="ef1005cfb8b6a298c8b04c445d0845a370706728dbb810cb5a040c67f9fa8084"
WV_CAPABILITIES_SCHEMA_SHA256="e0ce380f3281d49ee5d6b8bfab1f0d6cf9160d1544d526c8df1d1eab3e9ca4bb"
WV_CAPABILITIES_IDENTITY="511dcf009d3cc6dbf0f5519e0d59e80a6bf64d7bc209d394b948ac5487578948"

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
        hotzone|index|self-update|selftest|uninstall) printf %s administrative; return 0 ;;
        add|allowed-tools|batch|batch-done|block|breadcrumbs|bulk-update|clean-ghosts|commit-refs|compact|config|cutover|delete|doctor|done|enrich-topology|findings|hook|import|init|init-repo|link|load|memory|plan|prune|quality|quick|recover|reindex|remember|repo-class|resolve|session-summary|ship|ship-agent|sync|test-record|touch|trails|unarchive|unlink|update|work) printf %s mutation_attempt; return 0 ;;
        analyze|audit-pitfalls|bootstrap|bootstrap-agent|cache|context|digest|discover|edge-types|edges|guide|health|impact|learnings|list|mcp-status|overview|path|pattern-audit|pending-close|preflight|query|ready|refs|related|search|show|status|test-status|tree|validate-finding) printf %s observation; return 0 ;;
    esac
    return 1
}

_wv_cap_targets() {
    case "${1}:${2-}" in
        breadcrumbs:capsule) printf %s ""; return 0 ;;
        breadcrumbs:clear) printf %s "brain_db"; return 0 ;;
        breadcrumbs:save) printf %s "brain_db"; return 0 ;;
        breadcrumbs:show) printf %s ""; return 0 ;;
        config:disable) printf %s "installation repo_state"; return 0 ;;
        config:enable) printf %s "installation repo_state"; return 0 ;;
        config:get) printf %s ""; return 0 ;;
        config:list) printf %s ""; return 0 ;;
        config:set) printf %s "installation repo_state"; return 0 ;;
        config:show) printf %s ""; return 0 ;;
        config:unset) printf %s "installation repo_state"; return 0 ;;
        findings:list) printf %s ""; return 0 ;;
        findings:promote) printf %s "brain_db"; return 0 ;;
        hotzone:db) printf %s ""; return 0 ;;
        hotzone:gc) printf %s "brain_db"; return 0 ;;
        hotzone:list) printf %s ""; return 0 ;;
        memory:crystallize) printf %s "brain_db"; return 0 ;;
        memory:import) printf %s "brain_db"; return 0 ;;
        memory:recall) printf %s ""; return 0 ;;
        memory:render) printf %s "repo_state"; return 0 ;;
        memory:scan) printf %s ""; return 0 ;;
        quality:diff) printf %s ""; return 0 ;;
        quality:functions) printf %s ""; return 0 ;;
        quality:hotspots) printf %s ""; return 0 ;;
        quality:patterns) printf %s "quality_db"; return 0 ;;
        quality:promote) printf %s "brain_db"; return 0 ;;
        quality:prose-shape) printf %s ""; return 0 ;;
        quality:reset) printf %s "quality_db"; return 0 ;;
        quality:scan) printf %s "quality_db"; return 0 ;;
        quality:structural-search) printf %s ""; return 0 ;;
        repo-class:audit) printf %s ""; return 0 ;;
        repo-class:set) printf %s "git"; return 0 ;;
        trails:capsule) printf %s ""; return 0 ;;
        trails:clear) printf %s "brain_db"; return 0 ;;
        trails:save) printf %s "brain_db"; return 0 ;;
        trails:show) printf %s ""; return 0 ;;
    esac
    case "$1" in
        add) printf %s "brain_db"; return 0 ;;
        allowed-tools) printf %s "brain_db"; return 0 ;;
        analyze) printf %s ""; return 0 ;;
        audit-pitfalls) printf %s ""; return 0 ;;
        batch) printf %s "brain_db"; return 0 ;;
        batch-done) printf %s "brain_db"; return 0 ;;
        block) printf %s "brain_db"; return 0 ;;
        bootstrap) printf %s ""; return 0 ;;
        bootstrap-agent) printf %s ""; return 0 ;;
        breadcrumbs) printf %s "brain_db"; return 0 ;;
        bulk-update) printf %s "brain_db"; return 0 ;;
        cache) printf %s ""; return 0 ;;
        clean-ghosts) printf %s "brain_db"; return 0 ;;
        commit-refs) printf %s "brain_db git"; return 0 ;;
        compact) printf %s "brain_db"; return 0 ;;
        config) printf %s "installation repo_state"; return 0 ;;
        context) printf %s ""; return 0 ;;
        cutover) printf %s "repo_state"; return 0 ;;
        delete) printf %s "brain_db"; return 0 ;;
        digest) printf %s ""; return 0 ;;
        discover) printf %s ""; return 0 ;;
        doctor) printf %s "installation repo_state"; return 0 ;;
        done) printf %s "brain_db"; return 0 ;;
        edge-types) printf %s ""; return 0 ;;
        edges) printf %s ""; return 0 ;;
        enrich-topology) printf %s "brain_db"; return 0 ;;
        findings) printf %s "brain_db"; return 0 ;;
        guide) printf %s ""; return 0 ;;
        health) printf %s ""; return 0 ;;
        hook) printf %s "brain_db"; return 0 ;;
        hotzone) printf %s "brain_db"; return 0 ;;
        impact) printf %s ""; return 0 ;;
        import) printf %s "brain_db"; return 0 ;;
        index) printf %s "brain_db"; return 0 ;;
        init) printf %s "brain_db repo_state"; return 0 ;;
        init-repo) printf %s "repo_state working_tree"; return 0 ;;
        learnings) printf %s ""; return 0 ;;
        link) printf %s "brain_db"; return 0 ;;
        list) printf %s ""; return 0 ;;
        load) printf %s "brain_db"; return 0 ;;
        mcp-status) printf %s ""; return 0 ;;
        memory) printf %s "brain_db repo_state"; return 0 ;;
        overview) printf %s ""; return 0 ;;
        path) printf %s ""; return 0 ;;
        pattern-audit) printf %s ""; return 0 ;;
        pending-close) printf %s ""; return 0 ;;
        plan) printf %s "brain_db"; return 0 ;;
        preflight) printf %s ""; return 0 ;;
        prune) printf %s "brain_db repo_state"; return 0 ;;
        quality) printf %s "brain_db quality_db"; return 0 ;;
        query) printf %s ""; return 0 ;;
        quick) printf %s "brain_db git"; return 0 ;;
        ready) printf %s ""; return 0 ;;
        recover) printf %s "brain_db"; return 0 ;;
        refs) printf %s ""; return 0 ;;
        reindex) printf %s "brain_db"; return 0 ;;
        related) printf %s ""; return 0 ;;
        remember) printf %s "brain_db"; return 0 ;;
        repo-class) printf %s "git"; return 0 ;;
        resolve) printf %s "brain_db"; return 0 ;;
        search) printf %s ""; return 0 ;;
        self-update) printf %s "installation"; return 0 ;;
        selftest) printf %s ""; return 0 ;;
        session-summary) printf %s "brain_db"; return 0 ;;
        ship) printf %s "brain_db external_projection"; return 0 ;;
        ship-agent) printf %s "brain_db external_projection"; return 0 ;;
        show) printf %s ""; return 0 ;;
        status) printf %s ""; return 0 ;;
        sync) printf %s "brain_db external_projection repo_state"; return 0 ;;
        test-record) printf %s "brain_db"; return 0 ;;
        test-status) printf %s ""; return 0 ;;
        touch) printf %s "brain_db"; return 0 ;;
        trails) printf %s "brain_db"; return 0 ;;
        tree) printf %s ""; return 0 ;;
        unarchive) printf %s "brain_db"; return 0 ;;
        uninstall) printf %s "installation"; return 0 ;;
        unlink) printf %s "brain_db"; return 0 ;;
        update) printf %s "brain_db"; return 0 ;;
        validate-finding) printf %s ""; return 0 ;;
        work) printf %s "brain_db"; return 0 ;;
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
        add|allowed-tools|analyze|audit-pitfalls|batch|batch-done|block|bootstrap|bootstrap-agent|breadcrumbs|bulk-update|cache|clean-ghosts|commit-refs|compact|config|context|cutover|delete|digest|discover|doctor|done|edge-types|edges|enrich-topology|findings|guide|health|hook|hotzone|impact|import|index|init|init-repo|learnings|link|list|load|mcp-status|memory|overview|path|pattern-audit|pending-close|plan|preflight|prune|quality|query|quick|ready|recover|refs|reindex|related|remember|repo-class|resolve|search|self-update|selftest|session-summary|ship|ship-agent|show|status|sync|test-record|test-status|touch|trails|tree|unarchive|uninstall|unlink|update|validate-finding|work) return 0 ;;
    esac
    return 1
}
