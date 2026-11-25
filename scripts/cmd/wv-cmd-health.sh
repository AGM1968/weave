#!/bin/bash
# wv-cmd-health.sh — graph health score and the isolated smoke test
#
# Commands: health, selftest
# Sourced by: wv entry point (autoloaded on first use)
# Dependencies: wv-config.sh, wv-db.sh, wv-cache.sh
#
# Moved unchanged from wv-cmd-ops.sh (wv-71933b, the wv-c153c4 split) so a change
# here routes only to the suites that exercise health and selftest.

# ═══════════════════════════════════════════════════════════════════════════
# cmd_selftest — Round-trip smoke test in isolated environment
# ═══════════════════════════════════════════════════════════════════════════

# Shared state for _selftest_check (avoids subshell capture issues)
_st_pass=0 _st_fail=0 _st_total=0 _st_results="" _st_format="text"

_selftest_check() {
    local name="$1" ok="$2" detail="$3"
    _st_total=$((_st_total + 1))
    if [ "$ok" = "1" ]; then
        _st_pass=$((_st_pass + 1))
        local status="pass"
    else
        _st_fail=$((_st_fail + 1))
        local status="fail"
    fi
    if [ "$_st_format" = "json" ]; then
        _st_results="${_st_results:+$_st_results,}$(printf '{"test":"%s","status":"%s","detail":"%s"}' "$name" "$status" "$(wv_json_escape "$detail")")"
    else
        local icon
        [ "$status" = "pass" ] && icon="${GREEN}✓${NC}" || icon="${RED}✗${NC}"
        echo -e "  $icon $name: $detail"
    fi
}

# _selftest_run_tests — Execute the 9 smoke tests (uses _selftest_check for recording)
_selftest_run_tests() {
    # 1. Init
    local init_out
    init_out=$(db_init 2>&1) && _selftest_check "init" "1" "database created" \
        || _selftest_check "init" "0" "failed: $init_out"

    # 2. Add nodes
    local id1 id2
    id1=$(cmd_add "selftest parent node" 2>/dev/null) && _selftest_check "add node 1" "1" "$id1" \
        || _selftest_check "add node 1" "0" "failed"
    id2=$(cmd_add "selftest child node" 2>/dev/null) && _selftest_check "add node 2" "1" "$id2" \
        || _selftest_check "add node 2" "0" "failed"

    # 3. Link. relates_to, not implements: step 6 closes node 1 while node 2 is
    # still open, and a node does not close over an open child (wv-76b361).
    # The closing node here is a blocker, which is what auto-unblock tests.
    if [ -n "$id1" ] && [ -n "$id2" ]; then
        local link_out
        link_out=$(cmd_link "$id2" "$id1" --type=relates_to 2>&1) && _selftest_check "link" "1" "$id2 -> $id1" \
            || _selftest_check "link" "0" "failed: $link_out"
    else
        _selftest_check "link" "0" "skipped (no node IDs)"
    fi

    # 4. Block
    if [ -n "$id1" ] && [ -n "$id2" ]; then
        local block_out
        block_out=$(cmd_block "$id2" --by="$id1" 2>&1) && _selftest_check "block" "1" "$id2 blocked by $id1" \
            || _selftest_check "block" "0" "failed: $block_out"
    else
        _selftest_check "block" "0" "skipped (no node IDs)"
    fi

    # 5. Work (claim parent)
    if [ -n "$id1" ]; then
        local work_out
        work_out=$(cmd_work "$id1" 2>&1) && _selftest_check "work" "1" "claimed $id1" \
            || _selftest_check "work" "0" "failed: $work_out"
    else
        _selftest_check "work" "0" "skipped"
    fi

    # 6. Done (complete parent — should auto-unblock child)
    if [ -n "$id1" ]; then
        local done_out
        done_out=$(cmd_done "$id1" --skip-verification 2>&1) && _selftest_check "done" "1" "completed $id1" \
            || _selftest_check "done" "0" "failed: $done_out"
    else
        _selftest_check "done" "0" "skipped"
    fi

    # 7. Verify child unblocked
    if [ -n "$id2" ]; then
        local child_status
        child_status=$(db_query "SELECT status FROM nodes WHERE id='$id2'")
        [ "$child_status" = "todo" ] && _selftest_check "auto-unblock" "1" "$id2 status=$child_status" \
            || _selftest_check "auto-unblock" "0" "$id2 status=$child_status (expected todo)"
    else
        _selftest_check "auto-unblock" "0" "skipped"
    fi

    # 8. Search (FTS5)
    local search_out
    search_out=$(cmd_search "selftest" --json 2>/dev/null)
    local search_count
    search_count=$(echo "$search_out" | jq 'length' 2>/dev/null || echo "0")
    [ "$search_count" -ge 1 ] 2>/dev/null && _selftest_check "search" "1" "$search_count results" \
        || _selftest_check "search" "0" "no results"

    # 9. Health
    local health_out
    health_out=$(cmd_health --json 2>/dev/null)
    local health_score
    health_score=$(echo "$health_out" | jq -r '.score' 2>/dev/null || echo "0")
    [ "$health_score" -gt 0 ] 2>/dev/null && _selftest_check "health" "1" "score $health_score" \
        || _selftest_check "health" "0" "score=$health_score"
}

cmd_selftest() {
    _st_format="text"
    while [ $# -gt 0 ]; do
        case "$1" in
            --json) _st_format="json" ;;
        esac
        shift
    done

    _st_pass=0 _st_fail=0 _st_total=0 _st_results=""
    local test_dir
    test_dir=$(mktemp -d "${TMPDIR:-/tmp}/wv-selftest-XXXXXX")

    # Isolated environment — override hot zone, DB, AND WEAVE_DIR
    # Without WEAVE_DIR override, auto_sync writes state.sql/deltas to the
    # real .weave/ directory, corrupting the live graph on next load.
    local orig_db="${WV_DB:-}"
    local orig_hz="${WV_HOT_ZONE:-}"
    local orig_wd="${WEAVE_DIR:-}"
    export WV_HOT_ZONE="$test_dir"
    export WV_DB="$test_dir/brain.db"
    export WEAVE_DIR="$test_dir/.weave"
    mkdir -p "$WEAVE_DIR/deltas"
    _WV_DB_READY=""
    _WV_SIZE_CHECKED=""

    [ "$_st_format" = "text" ] && echo "Weave Selftest — Round-trip Smoke Test"

    _selftest_run_tests

    # Cleanup
    export WV_DB="$orig_db"
    export WV_HOT_ZONE="$orig_hz"
    export WEAVE_DIR="$orig_wd"
    _WV_DB_READY=""
    _WV_SIZE_CHECKED=""
    cd /tmp || true
    rm -rf "$test_dir"

    # Summary
    if [ "$_st_format" = "json" ]; then
        local overall="pass"
        [ "$_st_fail" -gt 0 ] && overall="fail"
        printf '{"overall":"%s","passed":%d,"failed":%d,"total":%d,"tests":[%s]}\n' \
            "$overall" "$_st_pass" "$_st_fail" "$_st_total" "$_st_results"
    else
        echo ""
        if [ "$_st_fail" -gt 0 ]; then
            echo -e "Result: ${RED}${_st_pass}/${_st_total} passed${NC} (${_st_fail} failed)"
        else
            echo -e "Result: ${GREEN}${_st_pass}/${_st_total} passed${NC}"
        fi
    fi

    [ "$_st_fail" -gt 0 ] && return 1
    return 0
}

# ═══════════════════════════════════════════════════════════════════════════
# cmd_health — System health check
# ═══════════════════════════════════════════════════════════════════════════

# ═══════════════════════════════════════════════════════════════════════════
# cmd_health — Health check with score (decomposed into helpers)
# ═══════════════════════════════════════════════════════════════════════════

# Shared state for cmd_health helpers
_h_total_nodes=0 _h_active=0 _h_ready=0 _h_blocked=0 _h_blocked_ext=0
_h_done_count=0 _h_pending=0 _h_total_edges=0 _h_blocking_edges=0
_h_total_pitfalls=0 _h_addressed_pitfalls=0 _h_unaddressed_pitfalls=0
_h_orphan_nodes=0 _h_orphan_ids="[]" _h_intentional_standalones=0
_h_intentional_standalone_ids="[]" _h_ghost_edges=0 _h_empty_edge_ctx=0
_h_gh_duplicates=0 _h_gh_duplicate_issues="[]"
_h_stale_active=0 _h_contradictions=0 _h_invalid_statuses=0
_h_stale_blocked=0 _h_stale_blocked_ids="[]" _h_fixed_stale_blocked=0
_h_health_score=100 _h_issues="" _h_fixed_edge_ctx=0
_h_status_icon="" _h_status_text=""
_h_quality_available="false" _h_quality_score=0 _h_quality_hotspots=0 _h_quality_baseline_note=""
_h_quality_files=0 _h_quality_head="" _h_quality_scanned=""

# Show health history log and exit. Args: $1=count, $2=format
_health_show_history() {
    local count="$1" format="$2"
    local log_file="$WEAVE_DIR/health.log"
    if [ ! -f "$log_file" ]; then
        echo "No health history yet. Run 'wv health' to start logging."
        return 0
    fi
    local total
    total=$(( $(wc -l < "$log_file") ))
    if [ "$format" = "json" ]; then
        tail -n "$count" "$log_file" | awk -F'\t' '{
            printf "{\"timestamp\":\"%s\",\"score\":%s,\"nodes\":%s,\"edges\":%s,\"orphans\":%s,\"ghost_edges\":%s}\n", $1, $2, $3, $4, $5, $6
        }' | jq -s '.'
    else
        echo -e "${CYAN}Health History${NC} (last $count of $total entries)"
        echo ""
        printf "  %-25s %5s %5s %5s %7s %11s\n" "Timestamp" "Score" "Nodes" "Edges" "Orphans" "Ghost Edges"
        printf "  %-25s %5s %5s %5s %7s %11s\n" "─────────────────────────" "─────" "─────" "─────" "───────" "───────────"
        tail -n "$count" "$log_file" | while IFS=$'\t' read -r ts score nodes edges orphans ghosts; do
            local icon="✅"
            [ "$score" -lt 90 ] 2>/dev/null && icon="⚠️"
            [ "$score" -lt 70 ] 2>/dev/null && icon="❌"
            printf "  %-25s %3s %s %5s %5s %7s %11s\n" "$ts" "$score" "$icon" "$nodes" "$edges" "$orphans" "$ghosts"
        done
    fi
}

# Collect all health metrics from DB into _h_* shared variables.
_health_collect_metrics() {
    # Node counts
    _h_total_nodes=$(db_query "SELECT COUNT(*) FROM nodes;" 2>/dev/null)
    _h_total_nodes="${_h_total_nodes:-0}"
    _h_active=$(db_query "SELECT COUNT(*) FROM nodes WHERE status='active';" 2>/dev/null)
    _h_active="${_h_active:-0}"
    _h_ready=$(cmd_ready --count 2>/dev/null)
    _h_ready="${_h_ready:-0}"
    _h_blocked=$(db_query "SELECT COUNT(*) FROM nodes WHERE status='blocked';" 2>/dev/null)
    _h_blocked="${_h_blocked:-0}"
    _h_blocked_ext=$(db_query "SELECT COUNT(*) FROM nodes WHERE status='blocked-external';" 2>/dev/null)
    _h_blocked_ext="${_h_blocked_ext:-0}"
    # Blocked with no open blocker (wv-3259b3): every local edge-removal path
    # recomputes (wv-81338c), but a stale status already in the graph, or one
    # replayed from an older client, was visible only to wv preflight, one node
    # at a time. Same predicate as preflight's has_blockers.
    _h_stale_blocked_ids=$(db_query "
        SELECT json_group_array(id) FROM (
            SELECT n.id FROM nodes n
            WHERE n.status = 'blocked'
            AND NOT EXISTS (
                SELECT 1 FROM edges e JOIN nodes b ON e.source = b.id
                WHERE e.target = n.id AND e.type = 'blocks' AND b.status != 'done')
            ORDER BY n.id);
    " 2>/dev/null)
    _h_stale_blocked_ids="${_h_stale_blocked_ids:-[]}"
    _h_stale_blocked=$(jq 'length' <<< "$_h_stale_blocked_ids" 2>/dev/null) || _h_stale_blocked=0
    _h_done_count=$(db_query "SELECT COUNT(*) FROM nodes WHERE status='done';" 2>/dev/null)
    _h_done_count="${_h_done_count:-0}"
    _h_pending=$(db_query "SELECT COUNT(*) FROM nodes WHERE status='pending';" 2>/dev/null)
    _h_pending="${_h_pending:-0}"

    # Edge stats
    _h_total_edges=$(db_query "SELECT COUNT(*) FROM edges;" 2>/dev/null)
    _h_total_edges="${_h_total_edges:-0}"
    _h_blocking_edges=$(db_query "SELECT COUNT(*) FROM edges WHERE type='blocks';" 2>/dev/null)
    _h_blocking_edges="${_h_blocking_edges:-0}"

    # Pitfall stats — only count open (non-done) nodes; done-node pitfalls are captured learnings
    _h_total_pitfalls=$(db_query "
        SELECT COUNT(*) FROM nodes
        WHERE json_extract(metadata, '\$.pitfall') IS NOT NULL
        AND status != 'done';
    ")
    _h_addressed_pitfalls=$(db_query "
        SELECT COUNT(DISTINCT n.id) FROM nodes n
        JOIN ($(wv_pitfall_resolver_edges_sql)) r ON r.pitfall = n.id
        WHERE json_extract(n.metadata, '\$.pitfall') IS NOT NULL
        AND n.status != 'done';
    ")
    _h_unaddressed_pitfalls=$((_h_total_pitfalls - _h_addressed_pitfalls))

    # Intentional standalone nodes (no edges, but explicitly marked standalone=true)
    _h_intentional_standalones=$(db_query "
        SELECT COUNT(*) FROM nodes n
        WHERE COALESCE(json_extract(n.metadata, '\$.standalone'), 0) = 1
        AND n.id NOT IN (SELECT source FROM edges)
        AND n.id NOT IN (SELECT target FROM edges);
    ")
    _h_intentional_standalones="${_h_intentional_standalones:-0}"
    _h_intentional_standalone_ids=$(db_query "
        SELECT json_group_array(n.id) FROM nodes n
        WHERE COALESCE(json_extract(n.metadata, '\$.standalone'), 0) = 1
        AND n.id NOT IN (SELECT source FROM edges)
        AND n.id NOT IN (SELECT target FROM edges);
    ")
    _h_intentional_standalone_ids="${_h_intentional_standalone_ids:-[]}"

    # Orphan nodes (no edges at all, excluding intentional standalones and done nodes)
    _h_orphan_nodes=$(db_query "
        SELECT COUNT(*) FROM nodes n
        WHERE COALESCE(json_extract(n.metadata, '\$.standalone'), 0) != 1
        AND n.status != 'done'
        AND n.id NOT IN (SELECT source FROM edges)
        AND n.id NOT IN (SELECT target FROM edges);
    ")
    _h_orphan_ids=$(db_query "
        SELECT json_group_array(n.id) FROM nodes n
        WHERE COALESCE(json_extract(n.metadata, '\$.standalone'), 0) != 1
        AND n.status != 'done'
        AND n.id NOT IN (SELECT source FROM edges)
        AND n.id NOT IN (SELECT target FROM edges);
    ")
    _h_orphan_ids="${_h_orphan_ids:-[]}"

    # GH issue duplicates: non-done nodes sharing the same gh_issue number
    _h_gh_duplicates=$(db_query "
        SELECT COUNT(DISTINCT json_extract(metadata, '\$.gh_issue'))
        FROM nodes
        WHERE json_extract(metadata, '\$.gh_issue') IS NOT NULL
        AND status != 'done'
        GROUP BY json_extract(metadata, '\$.gh_issue')
        HAVING COUNT(*) > 1;
    " 2>/dev/null | wc -l | tr -d ' ')
    _h_gh_duplicates="${_h_gh_duplicates:-0}"
    if [ "${_h_gh_duplicates:-0}" -gt 0 ] 2>/dev/null; then
        local _dup_raw
        _dup_raw=$(db_query "
            SELECT json_group_array(json_object(
                'gh_issue', gi,
                'nodes', (
                    SELECT json_group_array(id)
                    FROM nodes n2
                    WHERE json_extract(n2.metadata, '\$.gh_issue') = gi
                    AND n2.status != 'done'
                )
            ))
            FROM (
                SELECT DISTINCT json_extract(metadata, '\$.gh_issue') as gi
                FROM nodes
                WHERE json_extract(metadata, '\$.gh_issue') IS NOT NULL
                AND status != 'done'
                GROUP BY gi
                HAVING COUNT(*) > 1
            );
        " 2>/dev/null)
        _h_gh_duplicate_issues="${_dup_raw:-[]}"
    fi

    # Ghost edges (referencing non-existent nodes)
    _h_ghost_edges=$(db_query "
        SELECT COUNT(*) FROM edges
        WHERE source NOT IN (SELECT id FROM nodes)
        OR target NOT IN (SELECT id FROM nodes);
    ")

    # Empty edge context
    _h_empty_edge_ctx=$(db_query "SELECT COUNT(*) FROM edges WHERE context='{}';")
    _h_empty_edge_ctx="${_h_empty_edge_ctx:-0}"

    # Stale active nodes (active for more than 7 days)
    _h_stale_active=$(db_query "
        SELECT COUNT(*) FROM nodes
        WHERE status='active'
        AND datetime(updated_at) < datetime('now', '-7 days');
    ")

    # Unresolved contradictions
    _h_contradictions=$(db_query "
        SELECT COUNT(*) FROM edges
        WHERE type='contradicts';
    ")

    # Invalid statuses (wv-01e7 fix)
    _h_invalid_statuses=$(db_query "
        SELECT COUNT(*) FROM nodes
        WHERE status NOT IN ('todo', 'active', 'done', 'blocked', 'blocked-external');
    ")

    # System metrics: RAM and tmpfs (hot zone)
    _h_ram_total_mb=0
    _h_ram_available_mb=0
    _h_shm_used_mb=0
    _h_shm_total_mb=0
    _h_db_size_kb=0
    if [ -f /proc/meminfo ]; then
        local ram_total_kb ram_avail_kb
        ram_total_kb=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
        ram_avail_kb=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)
        _h_ram_total_mb=$((ram_total_kb / 1024))
        _h_ram_available_mb=$((ram_avail_kb / 1024))
    fi
    if df /dev/shm >/dev/null 2>&1; then
        _h_shm_total_mb=$(df -BM /dev/shm | awk 'NR==2 {gsub(/M/,"",$2); print $2}')
        _h_shm_used_mb=$(df -BM /dev/shm | awk 'NR==2 {gsub(/M/,"",$3); print $3}')
    fi
    if [ -n "$WV_DB" ] && [ -f "$WV_DB" ]; then
        _h_db_size_kb=$(du -k "$WV_DB" 2>/dev/null | cut -f1)
        _h_db_size_kb="${_h_db_size_kb:-0}"
    fi
    _health_check_fts
}

# Probe content as well as index structure, without db_ensure repairing the
# evidence first. Also runs before fast-cache lookup: out-of-band damage does
# not touch the CLI write sentinel. A refused probe cannot certify health.
_health_check_fts() {
    _h_fts_integrity=preinit
    [ -f "$WV_DB" ] || return 0
    if sqlite3 -cmd ".timeout 5000" "$WV_DB" \
        "INSERT INTO nodes_fts(nodes_fts,rank) VALUES('integrity-check',1);" >/dev/null 2>&1; then
        _h_fts_integrity=ok
    else
        _h_fts_integrity=failed
    fi
}

# Compute health score from collected metrics. Sets _h_health_score, _h_issues,
# _h_status_icon, _h_status_text.
_health_compute_score() {
    _h_health_score=100
    _h_issues=""

    if [ "$_h_invalid_statuses" -gt 0 ]; then
        _h_health_score=$((_h_health_score - _h_invalid_statuses * 20))
        _h_issues="${_h_issues}invalid_statuses:$_h_invalid_statuses,"
    fi
    if [ "$_h_unaddressed_pitfalls" -gt 0 ]; then
        _h_health_score=$((_h_health_score - _h_unaddressed_pitfalls * 10))
        _h_issues="${_h_issues}unaddressed_pitfalls:$_h_unaddressed_pitfalls,"
    fi
    if [ "$_h_stale_active" -gt 0 ]; then
        _h_health_score=$((_h_health_score - _h_stale_active * 5))
        _h_issues="${_h_issues}stale_active:$_h_stale_active,"
    fi
    if [ "$_h_contradictions" -gt 0 ]; then
        _h_health_score=$((_h_health_score - _h_contradictions * 15))
        _h_issues="${_h_issues}unresolved_contradictions:$_h_contradictions,"
    fi
    if [ "$_h_ghost_edges" -gt 0 ]; then
        local ghost_penalty=30
        if [ "$_h_total_edges" -gt 0 ]; then
            ghost_penalty=$(( _h_ghost_edges * 30 / _h_total_edges ))
            if [ "$ghost_penalty" -gt 30 ]; then ghost_penalty=30; fi
        fi
        if [ "$ghost_penalty" -lt 5 ]; then ghost_penalty=5; fi
        _h_health_score=$((_h_health_score - ghost_penalty))
        _h_issues="${_h_issues}ghost_edges:$_h_ghost_edges,"
    fi
    if [ "$_h_orphan_nodes" -gt 5 ]; then
        local orphan_penalty=5
        if [ "$_h_total_nodes" -gt 0 ]; then
            orphan_penalty=$(( _h_orphan_nodes * 15 / _h_total_nodes ))
            if [ "$orphan_penalty" -gt 15 ]; then orphan_penalty=15; fi
        fi
        if [ "$orphan_penalty" -lt 3 ]; then orphan_penalty=3; fi
        _h_health_score=$((_h_health_score - orphan_penalty))
        _h_issues="${_h_issues}orphan_nodes:$_h_orphan_nodes,"
    fi
    if [ "${_h_stale_blocked:-0}" -gt 0 ] 2>/dev/null; then
        local sb_penalty=$(( _h_stale_blocked * 5 ))
        if [ "$sb_penalty" -gt 15 ]; then sb_penalty=15; fi
        _h_health_score=$((_h_health_score - sb_penalty))
        _h_issues="${_h_issues}stale_blocked:$_h_stale_blocked,"
    fi
    if [ "${_h_gh_duplicates:-0}" -gt 0 ] 2>/dev/null; then
        local dup_penalty=$(( _h_gh_duplicates * 5 ))
        if [ "$dup_penalty" -gt 15 ]; then dup_penalty=15; fi
        _h_health_score=$((_h_health_score - dup_penalty))
        _h_issues="${_h_issues}gh_duplicates:$_h_gh_duplicates,"
    fi
    # RAM pressure: warn at <1GB available, critical at <500MB
    _h_ram_warning=false
    _h_ram_critical=false
    if [ "$_h_ram_available_mb" -gt 0 ]; then
        if [ "$_h_ram_available_mb" -lt 500 ]; then
            _h_ram_critical=true
            _h_health_score=$((_h_health_score - 15))
            _h_issues="${_h_issues}ram_critical:${_h_ram_available_mb}MB,"
        elif [ "$_h_ram_available_mb" -lt 1024 ]; then
            _h_ram_warning=true
            _h_health_score=$((_h_health_score - 5))
            _h_issues="${_h_issues}ram_low:${_h_ram_available_mb}MB,"
        fi
    fi

    # Clamp to 0-100
    if [ "$_h_health_score" -lt 0 ]; then _h_health_score=0; fi
    if [ "$_h_health_score" -gt 100 ]; then _h_health_score=100; fi

    if [ "$_h_fts_integrity" = failed ]; then
        _h_health_score=0
        _h_issues="${_h_issues}fts_integrity:failed,"
    fi

    # Status icon/text
    if [ "$_h_health_score" -ge 90 ]; then
        _h_status_icon="✅"; _h_status_text="healthy"
    elif [ "$_h_health_score" -ge 70 ]; then
        _h_status_icon="⚠️"; _h_status_text="warning"
    else
        _h_status_icon="❌"; _h_status_text="unhealthy"
    fi
}

# Collect code quality info (informational, does NOT affect main score).
# Sets _h_quality_* shared variables.
_health_collect_quality() {
    _h_quality_available="false"
    _h_quality_score=0
    _h_quality_baseline_note=""
    _h_quality_hotspots=0
    _h_quality_files=0
    _h_quality_head=""
    _h_quality_scanned=""
    _h_quality_stale="false"
    local quality_json
    local _hz_args=()
    if [ -n "$WV_HOT_ZONE" ]; then _hz_args=("--hot-zone" "$WV_HOT_ZONE"); fi
    quality_json=$(_wv_quality_python "${_hz_args[@]}" health-info 2>/dev/null || echo '{"available":false}')
    if echo "$quality_json" | jq -se 'length == 1 and (.[0] | .available)' >/dev/null 2>&1; then
        _h_quality_available=$(echo "$quality_json" | jq -r '.available')
        if [ "$_h_quality_available" = "true" ]; then
            _h_quality_score=$(echo "$quality_json" | jq -r '.score')
            _h_quality_baseline_note=$(echo "$quality_json" | jq -r '.baseline_note // ""')
            _h_quality_hotspots=$(echo "$quality_json" | jq -r '.hotspot_count')
            _h_quality_files=$(echo "$quality_json" | jq -r '.total_files')
            _h_quality_head=$(echo "$quality_json" | jq -r '.git_head')
            _h_quality_scanned=$(echo "$quality_json" | jq -r '.scanned_at')
            _h_quality_stale=$(echo "$quality_json" | jq -r '.stale == true')
        fi
    fi
}

# One-line cache health summary for wv health output
_health_cache_summary() {
    local proj_slug projects_dir jsonl
    proj_slug=$(pwd | tr '/' '-')
    projects_dir="$HOME/.claude/projects"
    # Pick most recent JSONL for this project
    # shellcheck disable=SC2012  # newest by mtime; session file names are uuids
    jsonl=$(ls -t "$projects_dir/${proj_slug}"/*.jsonl 2>/dev/null | head -1 || true)
    if [ -z "$jsonl" ]; then
        echo "  no session data (run 'wv cache' to diagnose)"
        return
    fi
    python3 - "$jsonl" <<'PYEOF'
import sys, json, os
path = sys.argv[1]
total_read = total_create = turns = 0
try:
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line: continue
            try: e = json.loads(line)
            except: continue
            usage = e.get("usage")
            if usage is None:
                msg = e.get("message", {})
                if isinstance(msg, dict): usage = msg.get("usage")
            if isinstance(usage, dict):
                total_read  += usage.get("cache_read_input_tokens", 0) or 0
                total_create += usage.get("cache_creation_input_tokens", 0) or 0
                turns += 1
except Exception:
    pass
total = total_read + total_create
if total == 0:
    print("  no usage data in latest session")
    sys.exit(0)
ratio = total_read / total
status = "OK" if ratio > 0.65 else "LOW" if ratio > 0.35 else "BAD"
GREEN = "\033[0;32m"; YELLOW = "\033[1;33m"; RED = "\033[0;31m"; NC = "\033[0m"
colour = GREEN if status == "OK" else (YELLOW if status == "LOW" else RED)
sid = os.path.basename(path)[:8]
print(f"  {sid}  {turns} turns  {ratio:.1%} read  {colour}{status}{NC}  (run 'wv cache' for full report)")
PYEOF
}

# Backfill empty edge context. Sets _h_fixed_edge_ctx count.
# _health_fix_stale_blocked — return stale-blocked nodes to todo through the
# recompute every edge-removal path uses (wv-81338c), so only a node that held
# a blocks edge moves; a blocked status set by hand on an edgeless node stays.
_health_fix_stale_blocked() {
    _h_fixed_stale_blocked=0
    [ "${_h_stale_blocked:-0}" -gt 0 ] 2>/dev/null || return 0
    declare -F _recompute_blocked_targets >/dev/null || _wv_autoload core
    local ids moved
    ids=$(db_query "
        SELECT n.id FROM nodes n, json_each('$(sql_escape "$_h_stale_blocked_ids")') j
        WHERE n.id = j.value
        AND EXISTS (SELECT 1 FROM edges e WHERE e.target = n.id AND e.type = 'blocks');
    " 2>/dev/null) || return 1
    [ -n "$ids" ] || return 0
    # shellcheck disable=SC2086  # one argument per id
    moved=$(_recompute_blocked_targets $ids) || return 1
    _h_fixed_stale_blocked=$(printf '%s' "$moved" | grep -c . || true)
}

_health_fix_edges() {
    _h_fixed_edge_ctx=0
    if [ "${_h_empty_edge_ctx:-0}" -eq 0 ]; then
        return 0
    fi
    while IFS=$'\x1f' read -r src tgt etype src_label tgt_label; do
        [ -z "$src" ] && continue
        local ctx
        ctx=$(jq -nc --arg s "$src_label" --arg t "$tgt_label" --arg e "$etype" \
            '{summary: ($s + " " + $e + " " + $t), auto: true}')
        local ctx_escaped="${ctx//\'/\'\'}"
        db_query "UPDATE edges SET context='$ctx_escaped'
            WHERE source='$src' AND target='$tgt' AND type='$etype'
            AND context='{}';"
        _h_fixed_edge_ctx=$((_h_fixed_edge_ctx + 1))
    done < <(sqlite3 -batch -cmd ".timeout 5000" -separator $'\x1f' "$WV_DB" \
        "SELECT e.source, e.target, e.type,
                COALESCE(s.alias, substr(s.text,1,40)),
                COALESCE(t.alias, substr(t.text,1,40))
         FROM edges e
         JOIN nodes s ON e.source = s.id
         JOIN nodes t ON e.target = t.id
         WHERE e.context = '{}';")
    # Update count after fix
    _h_empty_edge_ctx=$(db_query "SELECT COUNT(*) FROM edges WHERE context='{}';")
    _h_empty_edge_ctx="${_h_empty_edge_ctx:-0}"
}

# Emit health report as JSON. Args: $1=strict flag
_health_format_json() {
    local strict="$1"
    local quality_obj
    if [ "$_h_quality_available" = "true" ]; then
        quality_obj=$(jq -n \
            --argjson score "$_h_quality_score" \
            --argjson hotspots "$_h_quality_hotspots" \
            --argjson files "$_h_quality_files" \
            --arg git_head "$_h_quality_head" \
            --arg scanned_at "$_h_quality_scanned" \
            --argjson stale "$_h_quality_stale" \
            --arg baseline_note "$_h_quality_baseline_note" \
            '{available: true, score: $score, baseline_note: $baseline_note, hotspot_count: $hotspots, total_files: $files, git_head: $git_head, scanned_at: $scanned_at, stale: $stale}')
    else
        quality_obj='{"available":false}'
    fi
    # shellcheck disable=SC1010  # 'done' is a jq arg name, not the bash keyword
    jq -n \
        --arg status "$_h_status_text" \
        --arg fts_integrity "$_h_fts_integrity" \
        --argjson score "$_h_health_score" \
        --argjson total_nodes "$_h_total_nodes" \
        --argjson active "$_h_active" \
        --argjson ready "$_h_ready" \
        --argjson blocked "$_h_blocked" \
        --argjson blocked_external "$_h_blocked_ext" \
        --argjson done "$_h_done_count" \
        --argjson pending "$_h_pending" \
        --argjson total_edges "$_h_total_edges" \
        --argjson blocking_edges "$_h_blocking_edges" \
        --argjson total_pitfalls "$_h_total_pitfalls" \
        --argjson addressed_pitfalls "$_h_addressed_pitfalls" \
        --argjson unaddressed_pitfalls "$_h_unaddressed_pitfalls" \
        --argjson orphan_nodes "$_h_orphan_nodes" \
        --slurpfile orphan_ids <(printf '%s' "$_h_orphan_ids") \
        --argjson intentional_standalones "$_h_intentional_standalones" \
        --slurpfile intentional_standalone_ids <(printf '%s' "$_h_intentional_standalone_ids") \
        --argjson ghost_edges "$_h_ghost_edges" \
        --argjson stale_active "$_h_stale_active" \
        --arg stale_blocked "$_h_stale_blocked" \
        --slurpfile stale_blocked_ids <(printf '%s' "$_h_stale_blocked_ids") \
        --arg fixed_stale_blocked "$_h_fixed_stale_blocked" \
        --argjson contradictions "$_h_contradictions" \
        --argjson invalid_statuses "$_h_invalid_statuses" \
        --argjson empty_edge_context "$_h_empty_edge_ctx" \
        --argjson fixed_edge_context "$_h_fixed_edge_ctx" \
        --argjson quality "$quality_obj" \
        --argjson ram_total_mb "$_h_ram_total_mb" \
        --argjson ram_available_mb "$_h_ram_available_mb" \
        --argjson shm_used_mb "$_h_shm_used_mb" \
        --argjson shm_total_mb "$_h_shm_total_mb" \
        --argjson db_size_kb "$_h_db_size_kb" \
        --argjson gh_duplicates "$_h_gh_duplicates" \
        --slurpfile gh_duplicate_issues <(printf '%s' "$_h_gh_duplicate_issues") \
        '# The three id lists are uncapped, one entry per matching node or
        # issue: files, not argv, past which execve fails E2BIG (wv-200d36).
        $orphan_ids[0] as $orphan_ids
        | $intentional_standalone_ids[0] as $intentional_standalone_ids
        | $gh_duplicate_issues[0] as $gh_duplicate_issues
        | $stale_blocked_ids[0] as $stale_blocked_ids
        | {
            status: $status,
            fts_integrity: $fts_integrity,
            score: $score,
            nodes: {
                total: $total_nodes,
                active: $active,
                ready: $ready,
                blocked: $blocked,
                blocked_external: $blocked_external,
                done: $done,
                pending: $pending
            },
            edges: {
                total: $total_edges,
                blocking: $blocking_edges
            },
            pitfalls: {
                total: $total_pitfalls,
                addressed: $addressed_pitfalls,
                unaddressed: $unaddressed_pitfalls
            },
            issues: {
                orphan_nodes: $orphan_nodes,
                orphan_ids: $orphan_ids,
                intentional_standalones: $intentional_standalones,
                intentional_standalone_ids: $intentional_standalone_ids,
                ghost_edges: $ghost_edges,
                stale_active: $stale_active,
                stale_blocked: ($stale_blocked | tonumber),
                stale_blocked_ids: $stale_blocked_ids,
                fixed_stale_blocked: ($fixed_stale_blocked | tonumber),
                unresolved_contradictions: $contradictions,
                invalid_statuses: $invalid_statuses,
                empty_edge_context: $empty_edge_context,
                fixed_edge_context: $fixed_edge_context,
                gh_duplicates: $gh_duplicates,
                gh_duplicate_issues: $gh_duplicate_issues
            },
            code_quality: $quality,
            system: {
                ram_total_mb: $ram_total_mb,
                ram_available_mb: $ram_available_mb,
                shm_used_mb: $shm_used_mb,
                shm_total_mb: $shm_total_mb,
                db_size_kb: $db_size_kb
            }
        }'
}

# Emit health report as text. Args: $1=verbose flag
_health_format_text() {
    local verbose="$1"

    echo -e "${CYAN}Weave Health Check${NC} $_h_status_icon"
    echo ""
    echo -e "${CYAN}Score:${NC} $_h_health_score/100 ($_h_status_text)"
    if [ "$_h_fts_integrity" = failed ]; then
        echo "  FTS5 index check failed or unavailable — run: wv doctor"
    fi
    echo ""
    echo -e "${CYAN}Nodes:${NC}"
    echo "  Total: $_h_total_nodes"
    local blocked_line="Active: $_h_active | Ready: $_h_ready | Blocked: $_h_blocked"
    if [ "$_h_blocked_ext" -gt 0 ]; then
        blocked_line="${blocked_line} | Blocked-Ext: $_h_blocked_ext"
    fi
    echo "  ${blocked_line} | Done: $_h_done_count | Pending: $_h_pending"
    echo ""
    echo -e "${CYAN}Edges:${NC}"
    echo "  Total: $_h_total_edges (blocking: $_h_blocking_edges)"
    echo ""
    echo -e "${CYAN}Pitfalls:${NC}"
    if [ "$_h_unaddressed_pitfalls" -gt 0 ]; then
        echo -e "  Total: $_h_total_pitfalls | Addressed: $_h_addressed_pitfalls | ${RED}Unaddressed: $_h_unaddressed_pitfalls${NC}"
    else
        echo -e "  Total: $_h_total_pitfalls | Addressed: $_h_addressed_pitfalls | ${GREEN}Unaddressed: $_h_unaddressed_pitfalls${NC}"
    fi
    echo ""
    echo -e "${CYAN}Quality:${NC}"
    if [ "$_h_quality_available" = "true" ]; then
        echo "  Score: $_h_quality_score/100"
        # A bare 0/100 read as a regression (wv-0f2438); the note comes from
        # the [baseline] section of .weave/quality.conf.
        [ -z "$_h_quality_baseline_note" ] || echo "  $_h_quality_baseline_note"
        echo "  Hotspots: $_h_quality_hotspots files above threshold"
        echo "  Last scan: $_h_quality_scanned (${_h_quality_head:0:7})"
        if [ "$_h_quality_stale" = "true" ]; then
            echo "  Scan is stale or incomplete; run: wv quality scan"
        fi
    else
        echo "  no scan data"
    fi
    echo ""
    echo -e "${CYAN}Cache:${NC}"
    _health_cache_summary

    if [ "$verbose" = true ]; then
        echo ""
        echo -e "${CYAN}Diagnostics:${NC}"
        echo "  Orphan nodes: $_h_orphan_nodes"
        echo "  Intentional standalones: $_h_intentional_standalones (excluded from orphan count)"
        echo "  Ghost edges: $_h_ghost_edges"
        echo "  Stale active (>7d): $_h_stale_active"
        echo "  Blocked with no open blocker: $_h_stale_blocked"
        echo "  Unresolved contradictions: $_h_contradictions"
        echo "  Invalid statuses: $_h_invalid_statuses"
        echo "  Empty edge context: $_h_empty_edge_ctx"
        echo ""
        echo -e "${CYAN}System:${NC}"
        echo "  RAM: ${_h_ram_available_mb}MB available / ${_h_ram_total_mb}MB total"
        echo "  tmpfs (/dev/shm): ${_h_shm_used_mb}MB used / ${_h_shm_total_mb}MB total"
        if [ "$_h_db_size_kb" -gt 0 ]; then
            echo "  Hot zone DB: ${_h_db_size_kb}KB"
        fi
    fi

    # Show issues if any
    if [ -n "$_h_issues" ] && [ "$_h_health_score" -lt 100 ]; then
        echo ""
        echo -e "${YELLOW}Issues:${NC}"
        if [ "$_h_unaddressed_pitfalls" -gt 0 ]; then echo -e "  ${YELLOW}⚠${NC} $_h_unaddressed_pitfalls unaddressed pitfall(s) - run 'wv audit-pitfalls'"; fi
        if [ "$_h_stale_active" -gt 0 ]; then echo -e "  ${YELLOW}⚠${NC} $_h_stale_active node(s) active >7 days - consider completing or closing"; fi
        if [ "$_h_stale_blocked" -gt 0 ]; then echo -e "  ${YELLOW}⚠${NC} $_h_stale_blocked node(s) blocked with no open blocker ($(jq -r 'join(", ")' <<< "$_h_stale_blocked_ids")) - run 'wv health --fix' to return those with a blocks edge to todo"; fi
        if [ "$_h_fixed_stale_blocked" -gt 0 ]; then echo -e "  ${GREEN}✓${NC} Fixed: returned $_h_fixed_stale_blocked stale-blocked node(s) to todo"; fi
        if [ "$_h_contradictions" -gt 0 ]; then echo -e "  ${YELLOW}⚠${NC} $_h_contradictions unresolved contradiction(s) - run 'wv edges <id>' to inspect"; fi
        if [ "$_h_ghost_edges" -gt 0 ]; then echo -e "  ${YELLOW}⚠${NC} $_h_ghost_edges ghost edge(s) referencing deleted nodes - run 'wv clean-ghosts'"; fi
        if [ "$_h_orphan_nodes" -gt 5 ]; then echo -e "  ${YELLOW}⚠${NC} $_h_orphan_nodes orphan node(s) with no edges - consider linking or pruning"; fi
        if [ "${_h_gh_duplicates:-0}" -gt 0 ] 2>/dev/null; then echo -e "  ${YELLOW}⚠${NC} $_h_gh_duplicates GH issue(s) mapped to multiple open nodes - run 'wv health --json | jq .issues.gh_duplicate_issues' to inspect, then 'wv delete <id> --no-gh --dry-run' (use --no-gh to avoid closing an issue still owned by the survivor)"; fi
        if [ "$_h_invalid_statuses" -gt 0 ]; then echo -e "  ${RED}✗${NC} $_h_invalid_statuses node(s) with invalid status - run 'wv update <id> --status=todo' to fix"; fi
        if [ "$_h_empty_edge_ctx" -gt 0 ]; then echo -e "  ${YELLOW}⚠${NC} $_h_empty_edge_ctx edge(s) missing context - run 'wv health --fix' to backfill"; fi
        if [ "$_h_fixed_edge_ctx" -gt 0 ]; then echo -e "  ${GREEN}✓${NC} Fixed: enriched $_h_fixed_edge_ctx edge(s) with auto-context (marked auto:true)"; fi
        if [ "$_h_ram_critical" = true ]; then echo -e "  ${RED}✗${NC} RAM critically low: ${_h_ram_available_mb}MB available — system may OOM kill processes"; fi
        if [ "$_h_ram_warning" = true ]; then echo -e "  ${YELLOW}⚠${NC} RAM low: ${_h_ram_available_mb}MB available — avoid heavy builds (cargo, npm)"; fi
    fi
}

cmd_health() {
    local format="text"
    local verbose=false
    local history_count=0
    local fix=false
    local strict=false
    local fast=false

    while [ $# -gt 0 ]; do
        case "$1" in
            --json) format="json" ;;
            --verbose|-v) verbose=true ;;
            --history) history_count=10 ;;
            --history=*) history_count="${1#--history=}" ;;
            --fix) fix=true ;;
            --strict) strict=true ;;
            --fast) fast=true ;;
            --help|-h) cmd_help health; return 0 ;;
            -*) _wv_reject_arg health "$1"; return 1 ;;  # wv-016983
        esac
        shift
    done

    # Handle --history: show log and exit
    if [ "$history_count" -gt 0 ] 2>/dev/null; then
        _health_show_history "$history_count" "$format"
        return 0
    fi
    # A graph that does not exist scored 100/100 healthy (wv-90083c). One that
    # exists but db_ensure will not migrate (lineage drift) is still probed and
    # scored below, floored and with its recovery (wv-71d076), so only a
    # missing database is refused here.
    if ! db_ensure && [ ! -s "$WV_DB" ]; then
        echo -e "${RED}Error: cannot open the graph database ($WV_DB); not reporting from it${NC}" >&2
        return 1
    fi

    # --fast: score-focused path for hook callers (wv-0d77b1). Skips quality
    # collection — the score is computed before quality and does not depend on
    # it, so the value is exact, not approximate. Freshness reuses the run-cache
    # write sentinel (touched after every successful write command), so any
    # CLI graph write invalidates the cache; the TTL bounds staleness from
    # out-of-band writers that bypass the CLI (direct sqlite, runtime).
    if [ "$fast" = "true" ]; then
        local cache_file="$WV_HOT_ZONE/.health_fast.json"
        local fast_ttl="${WV_HEALTH_FAST_TTL:-300}"

        # Writability probe (wv-71d076). Everything the score is computed from
        # describes the graph's SHAPE — counts, orphans, ghost edges — and none
        # of it moves when the writer-lineage schema drifts. A hot zone that
        # wv sync and wv commit-refs cannot persist to therefore scores 100/100,
        # and session start reports that number at the top of every session.
        # This is the classifier wv doctor already uses, and it costs two
        # pragma_table_info reads.
        local _hf_lineage
        _hf_lineage=$(db_lineage_pair_verdict \
            "$(db_lineage_shape nodes)" "$(db_lineage_shape edges)" 2>/dev/null || echo unknown)
        _health_check_fts

        if [ -f "$cache_file" ]; then
            local _hf_now _hf_mtime _hf_age _hf_fresh=true
            _hf_now=$(date +%s)
            _hf_mtime=$(wv_stat mtime "$cache_file" || echo 0)
            _hf_age=$((_hf_now - _hf_mtime))
            [ "$_hf_age" -le "$fast_ttl" ] || _hf_fresh=false
            # Strictly newer than the write sentinel, as the run cache (wv-228099).
            if [ -f "$WV_RUN_CACHE_SENTINEL" ] && ! [ "$cache_file" -nt "$WV_RUN_CACHE_SENTINEL" ]; then
                _hf_fresh=false
            fi
            # The cache is invalidated by CLI writes and by time, and a schema
            # drift is neither: a CLI upgrade or an out-of-band migration moves
            # the verdict without touching the write sentinel. Without this the
            # cached 100 outlives the drift for the whole TTL, which is exactly
            # the stale reassurance this probe was added to remove. A cache
            # written before the probe existed has no .lineage and is treated as
            # a mismatch, so the first run after an upgrade recomputes.
            if [ "$_hf_fresh" = "true" ] \
               && [ "$(jq -r '.lineage // "unrecorded"' "$cache_file" 2>/dev/null)" != "$_hf_lineage" ]; then
                _hf_fresh=false
            fi
            if [ "$_hf_fresh" = "true" ] \
               && [ "$(jq -r '.fts_integrity // "unrecorded"' "$cache_file" 2>/dev/null)" != "$_h_fts_integrity" ]; then
                _hf_fresh=false
            fi
            if [ "$_hf_fresh" = "true" ]; then
                if [ "$format" = "json" ]; then
                    cat "$cache_file" || return 1
                else
                    echo "Health: $(jq -r '.score' "$cache_file" 2>/dev/null)/100 (fast, cached)"
                    jq -r '.recovery // empty' "$cache_file" 2>/dev/null \
                        | while read -r _hf_rec; do
                              echo "  graph is not writable or could not be verified — inspect with: $_hf_rec" >&2
                          done
                    [ "$_h_fts_integrity" != failed ] || echo "  FTS5 index check failed or unavailable — run: wv doctor" >&2
                fi
                [ "$_h_fts_integrity" != failed ]
                return $?
            fi
        fi
        _health_collect_metrics
        _health_compute_score

        # A graph that cannot be written is not healthy at any shape score, so
        # the verdict floors it rather than subtracting from it. The three
        # tiers mirror wv doctor's, from the same classifier: canonical passes,
        # preinit is benign (db_init has not run yet, which is the ordinary
        # state of a fresh hot zone at session start), anything else fails.
        # 'unknown' means the probe itself could not run; that is reported but
        # does not floor, because a probe failure is not evidence of drift.
        local _hf_score="${_h_health_score:-0}" _hf_recovery=""
        case "$_hf_lineage" in
            canonical|preinit|unknown) ;;
            *)
                _hf_score=0
                # Moved aside, never deleted: the zone may hold writes no
                # repository has yet (wv-4ccc98).
                _hf_recovery=$(hot_zone_rebuild_advice)
                ;;
        esac
        if [ "$_h_fts_integrity" = failed ]; then
            _hf_score=0
            [ -n "$_hf_recovery" ] || _hf_recovery='wv doctor'
        fi

        # Append to the same trend log as the full path (only on recompute —
        # a cache hit means the DB is unchanged, so the data point is a duplicate).
        # The floored score is what gets logged: the trend should show the drift,
        # not the shape score that ignored it.
        if [ -d "$WEAVE_DIR" ]; then
            printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
                "$(date -u +%Y-%m-%dT%H:%M:%S)" \
                "$_hf_score" "$_h_total_nodes" "$_h_total_edges" \
                "$_h_orphan_nodes" "$_h_ghost_edges" >> "$WEAVE_DIR/health.log"
        fi
        local _hf_json
        _hf_json=$(jq -n \
            --arg score "$_hf_score" \
            --arg nodes "${_h_total_nodes:-0}" \
            --arg edges "${_h_total_edges:-0}" \
            --arg orphans "${_h_orphan_nodes:-0}" \
            --arg lineage "$_hf_lineage" \
            --arg fts_integrity "$_h_fts_integrity" \
            --arg recovery "$_hf_recovery" \
            '{"score":($score|tonumber),"total_nodes":($nodes|tonumber),"total_edges":($edges|tonumber),"orphan_nodes":($orphans|tonumber),"fast":true,"lineage":$lineage,"fts_integrity":$fts_integrity}
             + (if $recovery == "" then {} else {"recovery":$recovery} end)') || return 1
        # Cache storage is optional; its refusal must not substitute an older
        # healthy payload for the verdict just computed.
        { printf '%s\n' "$_hf_json" > "$cache_file.tmp" && mv "$cache_file.tmp" "$cache_file"; } 2>/dev/null \
            || rm -f "$cache_file.tmp" 2>/dev/null
        if [ "$format" = "json" ]; then
            printf '%s\n' "$_hf_json"
        else
            echo "Health: ${_hf_score}/100 (fast)"
            [ -n "$_hf_recovery" ] && \
                echo "  graph is not writable or could not be verified (lineage=$_hf_lineage) — inspect with: $_hf_recovery" >&2
            [ "$_h_fts_integrity" != failed ] || echo "  FTS5 index check failed or unavailable — run: wv doctor" >&2
        fi
        [ "$_h_fts_integrity" != failed ]
        return $?
    fi

    # Collect all metrics, compute score, gather quality info
    _health_collect_metrics
    _health_compute_score
    _health_collect_quality

    # Append to health history log only if this project has been initialised with wv-init-repo.
    # Guard prevents auto-creating .weave/ in repos that never opted in.
    local log_file="$WEAVE_DIR/health.log"
    if [ -d "$WEAVE_DIR" ]; then
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%S)" \
            "$_h_health_score" "$_h_total_nodes" "$_h_total_edges" \
            "$_h_orphan_nodes" "$_h_ghost_edges" >> "$log_file"
    fi

    # Backfill empty edge context if --fix
    if [ "$fix" = "true" ]; then
        _health_fix_edges
        _health_fix_stale_blocked || echo "wv health: could not recompute the stale-blocked nodes" >&2
    fi

    # Format output
    if [ "$format" = "json" ]; then
        _health_format_json "$strict" || return 1
        # JSON callers parse the output — warnings exit 0 unless --strict.
        if [ "$_h_fts_integrity" = failed ] || [ "$_h_invalid_statuses" -gt 0 ] || [ "$_h_contradictions" -gt 0 ]; then
            return 1
        fi
        if [ "$strict" = true ] && [ "$_h_health_score" -lt 100 ]; then
            return 1
        fi
        return 0
    fi

    _health_format_text "$verbose"

    # Exit code logic:
    # - Default: exit 0 (warnings are informational, not errors)
    # - --strict: exit 1 if score < 100 (for CI fail-on-warning)
    # - Always exit 1 for failed index checks, invalid statuses, contradictions
    if [ "$_h_fts_integrity" = failed ] || [ "$_h_invalid_statuses" -gt 0 ] || [ "$_h_contradictions" -gt 0 ]; then
        return 1
    fi
    if [ "$strict" = true ] && [ "$_h_health_score" -lt 100 ]; then
        return 1
    fi
    return 0
}
