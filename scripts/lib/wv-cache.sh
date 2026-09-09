#!/bin/bash
# wv-cache.sh — Context cache management
#
# Sourced by: wv entry point (after wv-config.sh)
# Dependencies: wv-config.sh (for WV_HOT_ZONE)

# ═══════════════════════════════════════════════════════════════════════════
# Context Cache Invalidation
# ═══════════════════════════════════════════════════════════════════════════

invalidate_context_cache() {
    # Invalidate context cache for affected nodes when edges change
    # Called by: cmd_block, cmd_link, cmd_done, cmd_resolve, cmd_refs, cmd_prune
    local affected_ids
    affected_ids="$*"  # join with IFS; used as space-separated list in loop below
    local cache_dir="$WV_HOT_ZONE/context_cache"

    if [ -d "$cache_dir" ]; then
        local node_id
        for node_id in $affected_ids; do
            # Context cache keys have existed as both <id>.json and
            # <id>-<mode>.json; clear either form during the transition.
            rm -f "$cache_dir/${node_id}.json" "$cache_dir/${node_id}"-*.json 2>/dev/null
        done
    fi

    # Also clear pre-action.sh first-call-only stamps so context is re-checked
    for node_id in $affected_ids; do
        rm -f "$WV_HOT_ZONE/.context_checked_${node_id}" 2>/dev/null
    done
}

# ═══════════════════════════════════════════════════════════════════════════
# Run Cache — command-level output caching for read-only commands
# ═══════════════════════════════════════════════════════════════════════════
# Caches stdout of pure-read commands (ready, list, bootstrap) in tmpfs.
# Invalidated by a sentinel file touched on every successful write command.
# TTL provides eventual consistency for out-of-band writes (MCP, other shells).
#
# Which commands those are is NOT decided here. _wv_cap_serve and
# _wv_cap_invalidate in the generated wv-command-capabilities.sh project it from
# contracts/command-capabilities.json, which is also where E1 reads evidence
# class and where wv pattern-audit reads totality. Three hand-maintained lists
# used to live here -- read, write and exempt -- and a fourth copy in E1 drifted
# from them unnoticed for a month. To change how a command is cached, edit the
# registry and regenerate; there is nothing to add here.
#
# Disable: WV_RUN_CACHE=0

WV_RUN_CACHE_TTL="${WV_RUN_CACHE_TTL:-45}"
WV_RUN_CACHE_DIR="${WV_HOT_ZONE}/run_cache"
WV_RUN_CACHE_SENTINEL="${WV_HOT_ZONE}/.run_cache.invalidate"

wv_run_cache_invalidate() {
    touch "$WV_RUN_CACHE_SENTINEL" 2>/dev/null || true
}

_wv_run_cache_key() {
    # Hash argv + presentation context into a cache key. The resolved agent
    # identity MUST be in the key: agent-filtered reads (e.g. wv ready hides
    # nodes claimed by other agents) differ per agent, so two agents sharing a
    # hot zone would otherwise serve each other stale, wrongly-filtered output
    # (wv-727175).
    local tty_flag=0
    [ -t 1 ] && tty_flag=1
    local agent_id=""
    if command -v resolve_agent_id >/dev/null 2>&1; then
        agent_id=$(resolve_agent_id)
    fi
    printf '%s\0%s\0%s\0%s\0%s\0%s\0' \
        "$*" "$tty_flag" "${NO_COLOR:-}" "${WV_MODE:-}" "${WV_AGENT:-0}" "$agent_id" \
        | md5sum | cut -c1-16
}

_wv_run_cache_is_fresh() {
    local cache_file="$1"
    [ -f "$cache_file" ] || return 1

    local now mtime age
    now=$(date +%s)
    mtime=$(stat -c %Y "$cache_file" 2>/dev/null || echo 0)
    age=$((now - mtime))
    [ "$age" -le "$WV_RUN_CACHE_TTL" ] || return 1

    # Invalidated by a write since this entry was created?
    if [ -f "$WV_RUN_CACHE_SENTINEL" ] && [ "$cache_file" -ot "$WV_RUN_CACHE_SENTINEL" ]; then
        return 1
    fi

    return 0
}

# wv_run_cache_wrap <dispatch_func> <args...>
# Called from main() for cacheable read commands. Runs dispatch_func on miss,
# caches stdout on success, serves from cache on hit.
wv_run_cache_wrap() {
    local dispatch_func="$1"
    shift

    mkdir -p "$WV_RUN_CACHE_DIR" 2>/dev/null || true

    local key cache_file
    key=$(_wv_run_cache_key "$@")
    cache_file="$WV_RUN_CACHE_DIR/${key}.out"

    if _wv_run_cache_is_fresh "$cache_file"; then
        cat "$cache_file"
        return 0
    fi

    local tmp rc=0
    tmp=$(mktemp "$WV_RUN_CACHE_DIR/.tmp.XXXXXX" 2>/dev/null) || tmp=$(mktemp)
    if "$dispatch_func" "$@" > "$tmp"; then
        mv "$tmp" "$cache_file"
        cat "$cache_file"
        return 0
    else
        rc=$?
        cat "$tmp"
        rm -f "$tmp"
        return "$rc"
    fi
}
