#!/bin/bash
# wv-runtime-ignores.sh — the one list of machine-local runtime files Weave
# writes under .weave/ (wv-9a54da). None of them is graph state: committing one
# churns on every load or sync and conflicts between agents, and a dirty .weave/
# makes wv compact --pre-cutover refuse.
#
# wv-init-repo writes these into a consumer's .gitignore and names any that are
# already tracked; this repository's .gitignore carries every entry
# (tests/test-repository-hygiene.sh); test fixtures that stand in for a Weave
# checkout read the same list. Add a file here when wv starts writing one.
#
# Defines data and functions only: no exports, no other sources.

WV_RUNTIME_IGNORES=(
    ".weave/archive/"
    ".weave/*.db"
    ".weave/*.db-wal"
    ".weave/*.db-shm"
    "**/.weave/ast_cache.db"
    "**/.weave/ast_cache.db-wal"
    "**/.weave/ast_cache.db-shm"
    ".weave/.context_policy"
    ".weave/.prune_epoch"
    ".weave/gate-provision.proposed.json"
    ".weave/quality.local.conf"
    ".weave/.applied_deltas"
    ".weave/sync-digest-cache.json"
    ".weave/repair-checkpoint.json"
    ".weave/health.log"
    ".weave/test-times.json"
    ".weave/.export-snapshot.db.*"
    ".weave/deltas/*/.staging-*"
    ".weave/.state.sql.*"
    ".weave/.nodes.jsonl.*"
    ".weave/.edges.jsonl.*"
    ".weave/trails.md.lock"
    ".weave/trails.md.lock.d/"
    ".weave/trails.md.tmp.*"
)

# wv_runtime_ignores — print the list, one .gitignore line per entry.
wv_runtime_ignores() {
    printf '%s\n' "${WV_RUNTIME_IGNORES[@]}"
}

# wv_runtime_tracked <repo root> — print the tracked files the list matches,
# one per line: runtime state that was committed before it was ignored.
wv_runtime_tracked() {
    local root="$1" pat rc=0
    pat=$(mktemp) || return 1
    wv_runtime_ignores > "$pat"
    git -C "$root" ls-files -ci --exclude-from="$pat" -- .weave 2>/dev/null || rc=$?
    rm -f "$pat"
    return "$rc"
}
