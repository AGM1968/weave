#!/bin/bash
# wv-attribution.sh -- file attribution: which files a node's work edited
# (wv-cdafa1).
#
# An edit is attributed to the active node in two places: node_files
# (uncapped, authoritative) and metadata.touched_files (capped display copy).
# The PostToolUse hook writes them directly, about 14 ms an edit. Inside an E5
# capture window (WV_WORKFLOW_ID set) a direct write is a hook write, and
# counted admission keeps only source=agent call-log rows, so it would move the
# graph identity between two agent rows and break the counted chain. There the
# hook queues the attribution instead, and the agent's next mutation-class wv
# call applies it after recording graph_identity_before, so the identity moves
# inside an agent row. Reads never apply it: E5 takes any row that moved the
# identity as a mutation (owner ruling and judge panel 2026-10-02,
# docs/findings/cdafa1-design-panel-2026-10-02).
#
# The queue sits beside the DB it belongs to, so every reader derives the same
# path from the DB it already holds. One line per edit: node id, unit
# separator, repo-relative path. The queue file is not a causal-identity input.
#
# Sourced by: scripts/wv, scripts/lib/wv-post-tool-use.sh,
# scripts/lib/wv-pre-tool-use.sh. No side effects on source.

[ -n "${_WV_ATTRIBUTION_LOADED:-}" ] && return 0
_WV_ATTRIBUTION_LOADED=1
# shellcheck disable=SC1091  # sibling module, resolved at run time
declare -F wv_lock_fd >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/wv-lock.sh"

# _wv_attribution_lock -- hold fd 9's lock exclusively (wv_lock_fd: flock(1),
# else python3 fcntl; wv-7faa60), waiting up to WV_ATTRIBUTION_LOCK_WAIT
# seconds (default 60). Without it an apply can drop an edit queued between
# its read and its rewrite, so apply refuses when it fails; an append is one
# short O_APPEND write and proceeds either way.
_wv_attribution_lock() {
    wv_lock_fd 9 -x "${WV_ATTRIBUTION_LOCK_WAIT:-60}"
}

# wv_attribution_queue_path <db>
wv_attribution_queue_path() {
    printf '%s/attribution-queue' "$(dirname "$1")"
}

# wv_attribution_write <db> <node-id> <rel-path> [cap] -- attribute now: add the
# path to node_files and move it to the end of metadata.touched_files (capped).
wv_attribution_write() {
    local db="$1" node="$2" path="$3" cap="${4:-${WV_TOUCHED_NODE_CAP:-50}}"
    local node_esc="${node//\'/\'\'}" path_esc="${path//\'/\'\'}" cur new
    cur=$(sqlite3 "$db" "SELECT COALESCE(metadata, '{}') FROM nodes WHERE id='$node_esc';" 2>/dev/null) || return 1
    [ -n "$cur" ] || cur='{}'
    new=$(printf '%s' "$cur" | jq -c --arg path "$path" --argjson cap "$cap" \
        '.touched_files = (((.touched_files // []) - [$path]) + [$path] | .[-$cap:])' 2>/dev/null) || new="$cur"
    sqlite3 "$db" "UPDATE nodes SET metadata='${new//\'/\'\'}', updated_at=CURRENT_TIMESTAMP WHERE id='$node_esc';
                   INSERT OR IGNORE INTO node_files(node_id, path) VALUES ('$node_esc', '$path_esc');" \
        >/dev/null 2>&1
}

# wv_attribution_enqueue <db> <node-id> <rel-path> -- defer the attribution to
# the agent's next mutation-class wv call. A path holding a newline cannot be a
# queue line and is refused.
wv_attribution_enqueue() {
    local queue
    case "$3" in *$'\n'*) return 1 ;; esac
    queue=$(wv_attribution_queue_path "$1")
    (
        _wv_attribution_lock || true
        printf '%s\x1f%s\n' "$2" "$3" >> "$queue"
    ) 9>>"$queue.lock"
}

# wv_attribution_pending <db> <node-id> -- the paths queued for a node and not
# yet applied, one per line.
wv_attribution_pending() {
    local queue
    queue=$(wv_attribution_queue_path "$1")
    [ -s "$queue" ] || return 0
    # The separator byte itself, from bash: awk -F'\x1f' passed the four
    # characters, which gawk decodes and macOS awk does not, so on a Mac no
    # line split, no queued path matched, and a close passed that should
    # have been held (Mac round 3 trace, wv-e6ca42).
    awk -F $'\x1f' -v n="$2" '$1 == n { print $2 }' "$queue" 2>/dev/null
}

# wv_attribution_apply <db> -- write every queued attribution and empty the
# queue. A line whose write fails stays queued for the next call.
wv_attribution_apply() {
    local db="$1" queue node path failed=""
    queue=$(wv_attribution_queue_path "$db")
    [ -s "$queue" ] || return 0
    (
        _wv_attribution_lock || exit 1
        [ -s "$queue" ] || exit 0
        while IFS=$'\x1f' read -r node path; do
            [ -n "$node" ] && [ -n "$path" ] || continue
            wv_attribution_write "$db" "$node" "$path" ||
                failed="${failed}${node}"$'\x1f'"${path}"$'\n'
        done < "$queue"
        printf '%s' "$failed" > "$queue.new" && mv -f "$queue.new" "$queue"
    ) 9>>"$queue.lock"
}
