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
    local affected_ids="$@"
    local cache_dir="$WV_HOT_ZONE/context_cache"

    if [ -d "$cache_dir" ]; then
        for id in $affected_ids; do
            rm -f "$cache_dir/${id}.json" 2>/dev/null
        done
    fi
}
