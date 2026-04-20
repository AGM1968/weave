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
            rm -f "$cache_dir/${node_id}"-*.json 2>/dev/null
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
# Caches stdout of pure-read commands (status, ready, list) in tmpfs.
# Invalidated by a sentinel file touched on every successful write command.
# TTL provides eventual consistency for out-of-band writes (MCP, other shells).
#
# Disable: WV_RUN_CACHE=0

WV_RUN_CACHE_TTL="${WV_RUN_CACHE_TTL:-45}"
WV_RUN_CACHE_DIR="${WV_HOT_ZONE}/run_cache"
WV_RUN_CACHE_SENTINEL="${WV_HOT_ZONE}/.run_cache.invalidate"

_wv_run_cache_is_read_cmd() {
    case "${1:-}" in
        status|ready|list|bootstrap) return 0 ;;
        *) return 1 ;;
    esac
}

_wv_run_cache_is_write_cmd() {
    case "${1:-}" in
        add|done|batch-done|bulk-update|delete|work|update|quick|ship|\
        block|link|unlink|resolve|\
        batch|plan|enrich-topology|sync|load|compact|prune|clean-ghosts|import|reindex)
            return 0 ;;
        *) return 1 ;;
    esac
}

wv_run_cache_invalidate() {
    touch "$WV_RUN_CACHE_SENTINEL" 2>/dev/null || true
}

_wv_run_cache_key() {
    # Hash argv + presentation context into a cache key
    local tty_flag=0
    [ -t 1 ] && tty_flag=1
    printf '%s\0%s\0%s\0%s\0%s\0' \
        "$*" "$tty_flag" "${NO_COLOR:-}" "${WV_MODE:-}" "${WV_AGENT:-0}" \
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
