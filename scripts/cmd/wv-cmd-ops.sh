#!/bin/bash
# wv-cmd-ops.sh — Operations and diagnostic commands
#
# Commands: health, audit-pitfalls, edge-types, help
# Sourced by: wv entry point (after lib modules)
# Dependencies: wv-config.sh, wv-db.sh, wv-validate.sh, wv-cache.sh, wv-cmd-core.sh

# ═══════════════════════════════════════════════════════════════════════════
# cmd_digest — Compact one-liner health summary for session start
# ═══════════════════════════════════════════════════════════════════════════

cmd_digest() {
    local format="text"

    while [ $# -gt 0 ]; do
        case "$1" in
            --json) format="json" ;;
        esac
        shift
    done

    local total active ready blocked blocked_ext done_c pending
    total=$(db_query "SELECT COUNT(*) FROM nodes;" 2>/dev/null || echo "0")
    active=$(db_query "SELECT COUNT(*) FROM nodes WHERE status='active';" 2>/dev/null || echo "0")
    ready=$(cmd_ready --count 2>/dev/null || echo "0")
    blocked=$(db_query "SELECT COUNT(*) FROM nodes WHERE status='blocked';" 2>/dev/null || echo "0")
    blocked_ext=$(db_query "SELECT COUNT(*) FROM nodes WHERE status='blocked-external';" 2>/dev/null || echo "0")
    done_c=$(db_query "SELECT COUNT(*) FROM nodes WHERE status='done';" 2>/dev/null || echo "0")
    pending=$(db_query "SELECT COUNT(*) FROM nodes WHERE status IN ('todo','pending');" 2>/dev/null || echo "0")

    local unaddressed_pitfalls
    unaddressed_pitfalls=$(db_query "
        SELECT COUNT(*) FROM nodes n
        WHERE json_extract(n.metadata, '\$.pitfall') IS NOT NULL
        AND n.id NOT IN (
            SELECT e.target FROM edges e
            WHERE e.type IN ('addresses', 'implements', 'supersedes')
        );
    " 2>/dev/null || echo "0")

    local stale_active
    stale_active=$(db_query "
        SELECT COUNT(*) FROM nodes
        WHERE status='active' AND datetime(updated_at) < datetime('now', '-7 days');
    " 2>/dev/null || echo "0")

    local ghost_edges
    ghost_edges=$(db_query "
        SELECT COUNT(*) FROM edges
        WHERE source NOT IN (SELECT id FROM nodes)
        OR target NOT IN (SELECT id FROM nodes);
    " 2>/dev/null || echo "0")

    # Build alerts
    local alerts=""
    [ "$unaddressed_pitfalls" -gt 0 ] && alerts="${alerts}${alerts:+, }${unaddressed_pitfalls} unaddressed pitfalls"
    [ "$stale_active" -gt 0 ] && alerts="${alerts}${alerts:+, }${stale_active} stale active (>7d)"
    [ "$ghost_edges" -gt 0 ] && alerts="${alerts}${alerts:+, }${ghost_edges} ghost edges"

    if [ "$format" = "json" ]; then
        jq -n \
            --argjson total "$total" \
            --argjson active "$active" \
            --argjson ready "$ready" \
            --argjson blocked "$blocked" \
            --argjson blocked_external "$blocked_ext" \
            --argjson done "$done_c" \
            --argjson pending "$pending" \
            --argjson unaddressed_pitfalls "$unaddressed_pitfalls" \
            --argjson stale_active "$stale_active" \
            --argjson ghost_edges "$ghost_edges" \
            --arg alerts "$alerts" \
            '{nodes: $total, active: $active, ready: $ready, blocked: $blocked,
              blocked_external: $blocked_external, done: $done, pending: $pending,
              alerts: $alerts,
              issues: {unaddressed_pitfalls: $unaddressed_pitfalls,
                       stale_active: $stale_active, ghost_edges: $ghost_edges}}'
        return
    fi

    # One-liner output
    local summary="📊 ${total} nodes: ${active} active, ${ready} ready, ${blocked} blocked"
    [ "$blocked_ext" -gt 0 ] && summary="${summary}, ${blocked_ext} blocked-external"
    summary="${summary}, ${done_c} done"
    if [ -n "$alerts" ]; then
        summary="${summary} ⚠ ${alerts}"
    fi
    echo "$summary"
}

# ═══════════════════════════════════════════════════════════════════════════
# cmd_overview — Session start overview (status + health + ready + breadcrumb)
# ═══════════════════════════════════════════════════════════════════════════

cmd_overview() {
    local format="text"
    while [ $# -gt 0 ]; do
        case "$1" in
            --json) format="json" ;;
        esac
        shift
    done

    db_ensure

    # Status counts
    local total active ready_count blocked done_c
    total=$(db_query "SELECT COUNT(*) FROM nodes;")
    active=$(db_query "SELECT COUNT(*) FROM nodes WHERE status='active';")
    blocked=$(db_query "SELECT COUNT(*) FROM nodes WHERE status='blocked';")
    done_c=$(db_query "SELECT COUNT(*) FROM nodes WHERE status='done';")
    ready_count=$(cmd_ready --count 2>/dev/null || echo "0")

    # Health indicators
    local ghost_edges orphans total_edges
    ghost_edges=$(db_query "SELECT COUNT(*) FROM edges
        WHERE source NOT IN (SELECT id FROM nodes)
        OR target NOT IN (SELECT id FROM nodes);")
    orphans=$(db_query "SELECT COUNT(*) FROM nodes
        WHERE id NOT IN (SELECT source FROM edges)
        AND id NOT IN (SELECT target FROM edges);")
    total_edges=$(db_query "SELECT COUNT(*) FROM edges;")

    # Breadcrumb — stored as markdown at $WEAVE_DIR/breadcrumbs.md
    local breadcrumb=""
    local bc_file="${WEAVE_DIR}/breadcrumbs.md"
    if [ -f "$bc_file" ]; then
        breadcrumb=$(grep -v '^#' "$bc_file" | grep -v '^$' | head -1 | sed 's/^[[:space:]]*//')
    fi

    # Ready list (top 5) — intermediate variable to avoid SIGPIPE
    local raw_ready
    raw_ready=$(cmd_ready --json 2>/dev/null || echo "[]")
    local ready_list
    ready_list=$(echo "$raw_ready" | jq -c '[.[:5][] | {id, text}]' 2>/dev/null || echo "[]")

    if [ "$format" = "json" ]; then
        printf '{"status":{"total":%d,"active":%d,"ready":%d,"blocked":%d,"done":%d},' \
            "$total" "$active" "$ready_count" "$blocked" "$done_c"
        printf '"health":{"ghost_edges":%d,"orphans":%d,"total_edges":%d},' \
            "$ghost_edges" "$orphans" "$total_edges"
        printf '"breadcrumb":%s,' "$(echo "$breadcrumb" | jq -Rs '.')"
        printf '"ready":%s}\n' "$ready_list"
    else
        echo "Weave Overview"
        echo "  Nodes: $total ($active active, $ready_count ready, $blocked blocked, $done_c done)"
        echo "  Edges: $total_edges (${ghost_edges} ghost)"
        [ "$orphans" -gt 0 ] && echo "  ⚠ $orphans orphan nodes"
        [ -n "$breadcrumb" ] && echo "  Breadcrumb: $breadcrumb"
        if [ "$ready_count" -gt 0 ]; then
            echo ""
            echo "  Ready work:"
            echo "$ready_list" | jq -r '.[] | "    \(.id): \(.text)"' 2>/dev/null
        fi
    fi
}

# ═══════════════════════════════════════════════════════════════════════════
# cmd_preflight — Pre-action checks as JSON for MCP clients
# ═══════════════════════════════════════════════════════════════════════════

cmd_preflight() {
    local id="${1:-}"

    if [ -z "$id" ]; then
        echo '{"error":"node ID required"}' >&2
        return 1
    fi

    validate_id "$id" || { echo '{"error":"invalid ID format"}'; return 1; }

    # Check node existence
    local exists
    exists=$(db_query "SELECT COUNT(*) FROM nodes WHERE id='$id';")
    if [ "$exists" = "0" ]; then
        cat <<EOF
{"node_exists":false,"node_active":false,"has_done_criteria":false,"has_blockers":false,"contradictions":[],"context_load":"NONE","warnings":["Node $id not found"]}
EOF
        return 0
    fi

    # Gather node info
    local status text metadata
    status=$(db_query "SELECT status FROM nodes WHERE id='$id';")
    text=$(db_query "SELECT text FROM nodes WHERE id='$id';")
    metadata=$(db_query "SELECT COALESCE(json(metadata), '{}') FROM nodes WHERE id='$id';" 2>/dev/null || echo "{}")
    [[ "$metadata" != "{"* ]] && metadata="{}"

    local node_active=false
    [ "$status" = "active" ] && node_active=true

    # Check done_criteria
    local has_done_criteria=false
    local dc
    dc=$(echo "$metadata" | jq -r '.done_criteria // empty' 2>/dev/null)
    [ -n "$dc" ] && has_done_criteria=true

    # Check blockers
    local has_blockers=false
    local blocker_count
    blocker_count=$(db_query "
        SELECT COUNT(*) FROM edges e
        JOIN nodes blocker ON e.source = blocker.id
        WHERE e.target = '$id'
        AND e.type = 'blocks'
        AND blocker.status != 'done';
    " 2>/dev/null || echo "0")
    [ "$blocker_count" -gt 0 ] && has_blockers=true

    # Check contradictions (active node blocked, done node with open blockers)
    local contradictions="[]"
    local contra_items=""
    if [ "$status" = "active" ] && [ "$has_blockers" = "true" ]; then
        contra_items="\"Active node has unresolved blockers\""
    fi
    if [ "$status" = "done" ] && [ "$has_blockers" = "true" ]; then
        [ -n "$contra_items" ] && contra_items="${contra_items},"
        contra_items="${contra_items}\"Done node still has open blockers\""
    fi
    [ -n "$contra_items" ] && contradictions="[$contra_items]"

    # Context load estimate (based on edge count + descendants)
    local edge_count
    edge_count=$(db_query "SELECT COUNT(*) FROM edges WHERE source='$id' OR target='$id';" 2>/dev/null || echo "0")
    local context_load="LOW"
    [ "$edge_count" -gt 3 ] && context_load="MEDIUM"
    [ "$edge_count" -gt 8 ] && context_load="HIGH"

    # Collect warnings
    local warnings="[]"
    local warn_items=""
    [ "$has_done_criteria" = "false" ] && warn_items="\"No done_criteria defined\""

    local has_learning
    has_learning=$(echo "$metadata" | jq -r 'if (.decision // .pattern // .pitfall // .learning) then "yes" else "no" end' 2>/dev/null || echo "no")

    # Orphan check
    local total_edges
    total_edges=$(db_query "SELECT COUNT(*) FROM edges WHERE source='$id' OR target='$id';" 2>/dev/null || echo "0")
    if [ "$total_edges" = "0" ]; then
        [ -n "$warn_items" ] && warn_items="${warn_items},"
        warn_items="${warn_items}\"Orphan node — no edges\""
    fi

    # Status anomaly
    if [ "$status" = "blocked" ] && [ "$has_blockers" = "false" ]; then
        [ -n "$warn_items" ] && warn_items="${warn_items},"
        warn_items="${warn_items}\"Status is blocked but no active blockers found\""
    fi

    [ -n "$warn_items" ] && warnings="[$warn_items]"

    # Output JSON
    cat <<EOF
{"node_exists":true,"node_active":$node_active,"has_done_criteria":$has_done_criteria,"has_blockers":$has_blockers,"contradictions":$contradictions,"context_load":"$context_load","warnings":$warnings}
EOF
}

# ═══════════════════════════════════════════════════════════════════════════
# validate_on_done — Write-time validation warnings when closing a node
# ═══════════════════════════════════════════════════════════════════════════

validate_on_done() {
    local id="${1:-}"
    local suppress_warn="${WV_NO_WARN:-0}"

    # Suppressed by env or --no-warn
    [ "$suppress_warn" = "1" ] && return 0

    local warnings=""

    # Check: no learning captured
    local has_learning
    has_learning=$(db_query "
        SELECT COUNT(*) FROM nodes WHERE id='$id'
        AND (json_extract(metadata, '\$.decision') IS NOT NULL
          OR json_extract(metadata, '\$.pattern') IS NOT NULL
          OR json_extract(metadata, '\$.pitfall') IS NOT NULL
          OR json_extract(metadata, '\$.learning') IS NOT NULL);
    " 2>/dev/null || echo "0")
    if [ "$has_learning" = "0" ]; then
        warnings="${warnings}\n  ⚠ No learning captured — consider: --learning=\"...\""
    fi

    # Check: no verification evidence
    local has_verification
    has_verification=$(db_query "
        SELECT COUNT(*) FROM nodes WHERE id='$id'
        AND json_extract(metadata, '\$.verification_method') IS NOT NULL;
    " 2>/dev/null || echo "0")
    if [ "$has_verification" = "0" ]; then
        warnings="${warnings}\n  ⚠ No verification evidence — consider: wv update $id --metadata='{\"verification_method\":\"tests passed\"}'"
    fi

    # Check: orphan node (no edges)
    local edge_count
    edge_count=$(db_query "
        SELECT COUNT(*) FROM edges
        WHERE source='$id' OR target='$id';
    " 2>/dev/null || echo "0")
    if [ "$edge_count" = "0" ]; then
        warnings="${warnings}\n  ⚠ Orphan node — no edges. Consider: wv link $id <parent> --type=implements"
    fi

    # Print warnings if any
    if [ -n "$warnings" ]; then
        echo -e "${YELLOW}Validation hints:${NC}${warnings}" >&2
    fi
}

# ═══════════════════════════════════════════════════════════════════════════
# score_learning — Heuristic quality score for learning metadata
# ═══════════════════════════════════════════════════════════════════════════

score_learning() {
    local id="${1:-}"
    local score=0

    local meta
    meta=$(db_query "SELECT json(metadata) FROM nodes WHERE id='$id';" 2>/dev/null)
    [ -z "$meta" ] && return

    # Collect all learning text (decision + pattern + pitfall + learning)
    local all_text
    all_text=$(echo "$meta" | jq -r '[.decision, .pattern, .pitfall, .learning] | map(select(. != null)) | join(" ")' 2>/dev/null)
    [ -z "$all_text" ] && return

    # +1: Length > 20 chars (not a stub)
    if [ ${#all_text} -gt 20 ]; then
        score=$((score + 1))
    fi

    # +2: Contains a categorized prefix (pattern:/pitfall:/decision:/technique:)
    if echo "$all_text" | grep -qiE '(pattern:|pitfall:|decision:|technique:)'; then
        score=$((score + 2))
    fi

    # +1: References a specific file or function (contains . or / or ())
    if echo "$all_text" | grep -qE '(\.[a-z]{1,4}\b|/[a-z]|[a-z_]+\(\))'; then
        score=$((score + 1))
    fi

    # Store score in metadata
    local new_meta
    new_meta=$(echo "$meta" | jq --argjson s "$score" '. + {learning_quality: $s}' 2>/dev/null)
    if [ -n "$new_meta" ]; then
        new_meta="${new_meta//\'/\'\'}"
        db_query "UPDATE nodes SET metadata='$new_meta' WHERE id='$id';" 2>/dev/null
    fi
}

# ═══════════════════════════════════════════════════════════════════════════
# Session activity tracking
# ═══════════════════════════════════════════════════════════════════════════

_save_session_snapshot() {
    local snapshot="$WV_HOT_ZONE/.session_snapshot"
    local total done_count learnings
    total=$(db_query "SELECT COUNT(*) FROM nodes;" 2>/dev/null || echo 0)
    done_count=$(db_query "SELECT COUNT(*) FROM nodes WHERE status='done';" 2>/dev/null || echo 0)
    learnings=$(db_query "
        SELECT COUNT(*) FROM nodes
        WHERE json_extract(metadata, '\$.learning') IS NOT NULL
           OR json_extract(metadata, '\$.decision') IS NOT NULL
           OR json_extract(metadata, '\$.pattern') IS NOT NULL
           OR json_extract(metadata, '\$.pitfall') IS NOT NULL;
    " 2>/dev/null || echo 0)
    printf '%s\t%s\t%s\t%s\n' "$(date -u +%s)" "$total" "$done_count" "$learnings" > "$snapshot"
}

cmd_session_summary() {
    local format="text"
    while [ $# -gt 0 ]; do
        case "$1" in --json) format="json" ;; esac
        shift
    done

    local snapshot="$WV_HOT_ZONE/.session_snapshot"
    if [ ! -f "$snapshot" ]; then
        echo "No session snapshot found. Run 'wv load' at session start."
        return 0
    fi

    local start_ts start_total start_done start_learnings
    IFS=$'\t' read -r start_ts start_total start_done start_learnings < "$snapshot"

    local now_ts now_total now_done now_learnings
    now_ts=$(date -u +%s)
    now_total=$(db_query "SELECT COUNT(*) FROM nodes;" 2>/dev/null || echo 0)
    now_done=$(db_query "SELECT COUNT(*) FROM nodes WHERE status='done';" 2>/dev/null || echo 0)
    now_learnings=$(db_query "
        SELECT COUNT(*) FROM nodes
        WHERE json_extract(metadata, '\$.learning') IS NOT NULL
           OR json_extract(metadata, '\$.decision') IS NOT NULL
           OR json_extract(metadata, '\$.pattern') IS NOT NULL
           OR json_extract(metadata, '\$.pitfall') IS NOT NULL;
    " 2>/dev/null || echo 0)

    local elapsed=$(( now_ts - start_ts ))
    local hours=$(( elapsed / 3600 ))
    local mins=$(( (elapsed % 3600) / 60 ))
    local created=$(( now_total - start_total ))
    local completed=$(( now_done - start_done ))
    local new_learnings=$(( now_learnings - start_learnings ))

    # Format duration
    local duration
    if [ "$hours" -gt 0 ]; then
        duration="${hours}h ${mins}m"
    else
        duration="${mins}m"
    fi

    if [ "$format" = "json" ]; then
        jq -n \
            --arg duration "$duration" \
            --argjson elapsed "$elapsed" \
            --argjson created "$created" \
            --argjson completed "$completed" \
            --argjson learnings "$new_learnings" \
            '{
                duration: $duration,
                elapsed_seconds: $elapsed,
                nodes_created: $created,
                nodes_completed: $completed,
                learnings_captured: $learnings
            }'
    else
        echo -e "Session: ${CYAN}${duration}${NC} | Nodes: ${GREEN}+${created}${NC} created, ${GREEN}${completed}${NC} completed | Learnings: ${GREEN}${new_learnings}${NC} captured"
    fi
}

# ═══════════════════════════════════════════════════════════════════════════
# cmd_doctor — Installation health check
# ═══════════════════════════════════════════════════════════════════════════

cmd_doctor() {
    local format="text"
    while [ $# -gt 0 ]; do
        case "$1" in
            --json) format="json" ;;
        esac
        shift
    done

    local pass=0 fail=0 warn=0 total=0
    local results=""

    _doctor_record() {
        local name="$1" status="$2" detail="$3"
        total=$((total + 1))
        case "$status" in
            pass) pass=$((pass + 1)) ;;
            fail) fail=$((fail + 1)) ;;
            warn) warn=$((warn + 1)) ;;
        esac
        if [ "$format" = "json" ]; then
            results="${results:+$results,}$(printf '{"check":"%s","status":"%s","detail":"%s"}' "$name" "$status" "$detail")"
        else
            local icon
            case "$status" in
                pass) icon="${GREEN}✓${NC}" ;;
                fail) icon="${RED}✗${NC}" ;;
                warn) icon="${YELLOW}⊘${NC}" ;;
            esac
            echo -e "  $icon $name: $detail"
        fi
    }

    [ "$format" = "text" ] && echo "Weave Doctor — Installation Health"

    # 1. sqlite3 present
    if command -v sqlite3 >/dev/null 2>&1; then
        local sq_ver
        sq_ver=$(sqlite3 --version 2>/dev/null | awk '{print $1}')
        _doctor_record "sqlite3" "pass" "$sq_ver"
        # 2. sqlite3 version >= 3.35
        local sq_major sq_minor
        sq_major=$(echo "$sq_ver" | cut -d. -f1)
        sq_minor=$(echo "$sq_ver" | cut -d. -f2)
        if [ "$sq_major" -gt 3 ] 2>/dev/null || { [ "$sq_major" -eq 3 ] && [ "$sq_minor" -ge 35 ]; } 2>/dev/null; then
            _doctor_record "sqlite3 version" "pass" ">= 3.35"
        else
            _doctor_record "sqlite3 version" "warn" "$sq_ver < 3.35"
        fi
        # 3. FTS5
        local fts5
        fts5=$(sqlite3 ":memory:" "SELECT sqlite_compileoption_used('ENABLE_FTS5');" 2>/dev/null || echo "0")
        if [ "$fts5" = "1" ]; then
            _doctor_record "FTS5" "pass" "available"
        else
            _doctor_record "FTS5" "warn" "not available"
        fi
    else
        _doctor_record "sqlite3" "fail" "not found"
    fi

    # 4. jq present
    if command -v jq >/dev/null 2>&1; then
        _doctor_record "jq" "pass" "$(jq --version 2>/dev/null)"
    else
        _doctor_record "jq" "fail" "not found"
    fi

    # 5. git present
    if command -v git >/dev/null 2>&1; then
        _doctor_record "git" "pass" "$(git --version 2>/dev/null | awk '{print $3}')"
    else
        _doctor_record "git" "fail" "not found"
    fi

    # 6. gh present (optional)
    if command -v gh >/dev/null 2>&1; then
        _doctor_record "gh" "pass" "$(gh --version 2>/dev/null | head -1 | awk '{print $3}')"
    else
        _doctor_record "gh" "warn" "not found (optional)"
    fi

    # 7. Hot zone exists
    local hot_zone="${WV_HOT_ZONE:-}"
    if [ -z "$hot_zone" ]; then
        hot_zone=$(resolve_hot_zone 2>/dev/null)
    fi
    if [ -d "$hot_zone" ]; then
        # 8. Hot zone space
        local avail_kb
        avail_kb=$(df -k "$hot_zone" 2>/dev/null | awk 'NR==2 {print $4}')
        local avail_mb=$((avail_kb / 1024))
        if check_free_space "$hot_zone"; then
            _doctor_record "hot zone" "pass" "$hot_zone (${avail_mb}MB free)"
        else
            _doctor_record "hot zone" "warn" "$hot_zone (${avail_mb}MB free — low)"
        fi
    else
        _doctor_record "hot zone" "fail" "not found: $hot_zone"
    fi

    # 9-10. Database accessible + integrity
    if [ -n "${WV_DB:-}" ] && [ -f "$WV_DB" ]; then
        local db_test
        db_test=$(sqlite3 "$WV_DB" "SELECT 1;" 2>/dev/null)
        if [ "$db_test" = "1" ]; then
            local integrity
            integrity=$(sqlite3 "$WV_DB" "PRAGMA integrity_check;" 2>/dev/null)
            if [ "$integrity" = "ok" ]; then
                _doctor_record "database" "pass" "accessible, integrity OK"
            else
                _doctor_record "database" "fail" "integrity check failed"
            fi
        else
            _doctor_record "database" "fail" "not accessible"
        fi
    else
        _doctor_record "database" "warn" "no active database"
    fi

    # 11. Lib modules
    local lib_dir="$WV_LIB_DIR/lib"
    local lib_expected="wv-config.sh wv-db.sh wv-validate.sh wv-cache.sh wv-gh.sh wv-resolve-project.sh"
    local lib_found=0 lib_missing=""
    for mod in $lib_expected; do
        if [ -f "$lib_dir/$mod" ]; then
            lib_found=$((lib_found + 1))
        else
            lib_missing="${lib_missing:+$lib_missing, }$mod"
        fi
    done
    local lib_total
    lib_total=$(echo "$lib_expected" | wc -w | tr -d ' ')
    if [ "$lib_found" -eq "$lib_total" ]; then
        _doctor_record "lib modules" "pass" "$lib_found/$lib_total"
    else
        _doctor_record "lib modules" "fail" "$lib_found/$lib_total (missing: $lib_missing)"
    fi

    # 12. Cmd modules
    local cmd_dir="$WV_LIB_DIR/cmd"
    local cmd_expected="wv-cmd-core.sh wv-cmd-graph.sh wv-cmd-data.sh wv-cmd-ops.sh"
    local cmd_found=0 cmd_missing=""
    for mod in $cmd_expected; do
        if [ -f "$cmd_dir/$mod" ]; then
            cmd_found=$((cmd_found + 1))
        else
            cmd_missing="${cmd_missing:+$cmd_missing, }$mod"
        fi
    done
    local cmd_total
    cmd_total=$(echo "$cmd_expected" | wc -w | tr -d ' ')
    if [ "$cmd_found" -eq "$cmd_total" ]; then
        _doctor_record "cmd modules" "pass" "$cmd_found/$cmd_total"
    else
        _doctor_record "cmd modules" "fail" "$cmd_found/$cmd_total (missing: $cmd_missing)"
    fi

    # 13. .weave dir
    if [ -d "${WEAVE_DIR:-}" ]; then
        _doctor_record ".weave" "pass" "present"
    else
        _doctor_record ".weave" "warn" "not found"
    fi

    # Summary
    if [ "$format" = "json" ]; then
        local overall="pass"
        [ "$fail" -gt 0 ] && overall="fail"
        printf '{"overall":"%s","passed":%d,"failed":%d,"warnings":%d,"total":%d,"checks":[%s]}\n' \
            "$overall" "$pass" "$fail" "$warn" "$total" "$results"
    else
        echo ""
        if [ "$fail" -gt 0 ]; then
            echo -e "Result: ${RED}${pass}/${total} passed${NC} (${fail} failed, ${warn} warnings)"
        elif [ "$warn" -gt 0 ]; then
            echo -e "Result: ${GREEN}${pass}/${total} passed${NC} (${warn} warnings)"
        else
            echo -e "Result: ${GREEN}${pass}/${total} passed${NC}"
        fi
    fi

    [ "$fail" -gt 0 ] && return 1
    return 0
}

# ═══════════════════════════════════════════════════════════════════════════
# cmd_mcp_status — Verify MCP server is built and reachable
# ═══════════════════════════════════════════════════════════════════════════

cmd_mcp_status() {
    local format="text"
    while [ $# -gt 0 ]; do
        case "$1" in
            --json) format="json" ;;
        esac
        shift
    done

    local pass=0 fail=0 warn=0 total=0
    local results=""

    _mcp_record() {
        local name="$1" status="$2" detail="$3"
        total=$((total + 1))
        case "$status" in
            pass) pass=$((pass + 1)) ;;
            fail) fail=$((fail + 1)) ;;
            warn) warn=$((warn + 1)) ;;
        esac
        if [ "$format" = "json" ]; then
            results="${results:+$results,}$(printf '{"check":"%s","status":"%s","detail":"%s"}' "$name" "$status" "$detail")"
        else
            local icon
            case "$status" in
                pass) icon="${GREEN}✓${NC}" ;;
                fail) icon="${RED}✗${NC}" ;;
                warn) icon="${YELLOW}⊘${NC}" ;;
            esac
            echo -e "  $icon $name: $detail"
        fi
    }

    [ "$format" = "text" ] && echo "Weave MCP Status"

    # 1. Node.js
    if command -v node >/dev/null 2>&1; then
        local node_ver
        node_ver=$(node --version 2>/dev/null)
        _mcp_record "node" "pass" "$node_ver"
    else
        _mcp_record "node" "fail" "not found"
    fi

    # 2. MCP server built (check installed path, then repo root)
    local lib_dir="${WV_LIB_DIR:-$HOME/.local/lib/weave}"
    local repo_mcp="$REPO_ROOT/mcp/dist/index.js"
    local mcp_js=""
    if [ -f "$lib_dir/mcp/dist/index.js" ]; then
        mcp_js="$lib_dir/mcp/dist/index.js"
        _mcp_record "server built" "pass" "$mcp_js"
    elif [ -f "$repo_mcp" ]; then
        mcp_js="$repo_mcp"
        _mcp_record "server built" "pass" "$mcp_js (local dev)"
    else
        _mcp_record "server built" "fail" "not found — run install.sh --with-mcp"
    fi

    # 3. Server loadable (verify dist exists and has content — can't require() as it starts stdio)
    if [ -n "$mcp_js" ]; then
        local mcp_size
        mcp_size=$(wc -c < "$mcp_js" 2>/dev/null || echo "0")
        if [ "$mcp_size" -gt 1000 ] 2>/dev/null; then
            _mcp_record "server dist" "pass" "$(( mcp_size / 1024 ))KB bundle"
        else
            _mcp_record "server dist" "warn" "bundle looks too small (${mcp_size}B)"
        fi
    fi

    # 4. Check for IDE configs (supports both agents in same repo)
    local repo_root="$REPO_ROOT"
    local has_vscode=false has_claude=false
    if [ -f "$repo_root/.vscode/mcp.json" ]; then
        _mcp_record "VS Code config" "pass" ".vscode/mcp.json"
        has_vscode=true
    fi
    if [ -f "$repo_root/.claude/settings.local.json" ]; then
        if grep -q "mcpServers" "$repo_root/.claude/settings.local.json" 2>/dev/null; then
            _mcp_record "Claude config" "pass" "mcpServers in settings.local.json"
            has_claude=true
        fi
    fi
    if ! $has_vscode && ! $has_claude; then
        _mcp_record "IDE config" "warn" "no IDE config found — run wv-init-repo --agent=copilot or --agent=all"
    fi

    # Summary
    if [ "$format" = "json" ]; then
        local overall="pass"
        [ "$fail" -gt 0 ] && overall="fail"
        printf '{"overall":"%s","passed":%d,"failed":%d,"warnings":%d,"total":%d,"checks":[%s]}\n' \
            "$overall" "$pass" "$fail" "$warn" "$total" "$results"
    else
        echo ""
        if [ "$fail" -gt 0 ]; then
            echo -e "Result: ${RED}${pass}/${total} passed${NC} (${fail} failed, ${warn} warnings)"
        elif [ "$warn" -gt 0 ]; then
            echo -e "Result: ${GREEN}${pass}/${total} passed${NC} (${warn} warnings)"
        else
            echo -e "Result: ${GREEN}${pass}/${total} passed${NC}"
        fi
    fi

    [ "$fail" -gt 0 ] && return 1
    return 0
}

# ═══════════════════════════════════════════════════════════════════════════
# cmd_selftest — Round-trip smoke test in isolated environment
# ═══════════════════════════════════════════════════════════════════════════

cmd_selftest() {
    local format="text"
    while [ $# -gt 0 ]; do
        case "$1" in
            --json) format="json" ;;
        esac
        shift
    done

    local pass=0 fail=0 total=0
    local results=""
    local test_dir
    test_dir=$(mktemp -d "${TMPDIR:-/tmp}/wv-selftest-XXXXXX")

    # Isolated environment — override hot zone and DB
    local orig_db="${WV_DB:-}"
    local orig_hz="${WV_HOT_ZONE:-}"
    export WV_HOT_ZONE="$test_dir"
    export WV_DB="$test_dir/brain.db"
    # Reset db_ensure guard so init works in new location
    _WV_DB_READY=""
    _WV_SIZE_CHECKED=""

    _selftest_cleanup() {
        export WV_DB="$orig_db"
        export WV_HOT_ZONE="$orig_hz"
        _WV_DB_READY=""
        _WV_SIZE_CHECKED=""
        cd /tmp
        rm -rf "$test_dir"
    }

    _selftest_check() {
        local name="$1" ok="$2" detail="$3"
        total=$((total + 1))
        if [ "$ok" = "1" ]; then
            pass=$((pass + 1))
            local status="pass"
        else
            fail=$((fail + 1))
            local status="fail"
        fi
        if [ "$format" = "json" ]; then
            results="${results:+$results,}$(printf '{"test":"%s","status":"%s","detail":"%s"}' "$name" "$status" "$detail")"
        else
            local icon
            [ "$status" = "pass" ] && icon="${GREEN}✓${NC}" || icon="${RED}✗${NC}"
            echo -e "  $icon $name: $detail"
        fi
    }

    [ "$format" = "text" ] && echo "Weave Selftest — Round-trip Smoke Test"

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

    # 3. Link
    if [ -n "$id1" ] && [ -n "$id2" ]; then
        local link_out
        link_out=$(cmd_link "$id2" "$id1" --type=implements 2>&1) && _selftest_check "link" "1" "$id2 -> $id1" \
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
        done_out=$(cmd_done "$id1" 2>&1) && _selftest_check "done" "1" "completed $id1" \
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

    # Cleanup
    _selftest_cleanup

    # Summary
    if [ "$format" = "json" ]; then
        local overall="pass"
        [ "$fail" -gt 0 ] && overall="fail"
        printf '{"overall":"%s","passed":%d,"failed":%d,"total":%d,"tests":[%s]}\n' \
            "$overall" "$pass" "$fail" "$total" "$results"
    else
        echo ""
        if [ "$fail" -gt 0 ]; then
            echo -e "Result: ${RED}${pass}/${total} passed${NC} (${fail} failed)"
        else
            echo -e "Result: ${GREEN}${pass}/${total} passed${NC}"
        fi
    fi

    [ "$fail" -gt 0 ] && return 1
    return 0
}

# ═══════════════════════════════════════════════════════════════════════════
# cmd_health — System health check
# ═══════════════════════════════════════════════════════════════════════════

cmd_health() {
    local format="text"
    local verbose=false
    local history_count=0

    while [ $# -gt 0 ]; do
        case "$1" in
            --json) format="json" ;;
            --verbose|-v) verbose=true ;;
            --history) history_count=10 ;;
            --history=*) history_count="${1#--history=}" ;;
        esac
        shift
    done

    # Handle --history: show log and exit
    if [ "$history_count" -gt 0 ] 2>/dev/null; then
        local log_file="$WEAVE_DIR/health.log"
        if [ ! -f "$log_file" ]; then
            echo "No health history yet. Run 'wv health' to start logging."
            return 0
        fi
        local total
        total=$(wc -l < "$log_file")
        if [ "$format" = "json" ]; then
            tail -n "$history_count" "$log_file" | awk -F'\t' '{
                printf "{\"timestamp\":\"%s\",\"score\":%s,\"nodes\":%s,\"edges\":%s,\"orphans\":%s,\"ghost_edges\":%s}\n", $1, $2, $3, $4, $5, $6
            }' | jq -s '.'
        else
            echo -e "${CYAN}Health History${NC} (last $history_count of $total entries)"
            echo ""
            printf "  %-25s %5s %5s %5s %7s %11s\n" "Timestamp" "Score" "Nodes" "Edges" "Orphans" "Ghost Edges"
            printf "  %-25s %5s %5s %5s %7s %11s\n" "─────────────────────────" "─────" "─────" "─────" "───────" "───────────"
            tail -n "$history_count" "$log_file" | while IFS=$'\t' read -r ts score nodes edges orphans ghosts; do
                local icon="✅"
                [ "$score" -lt 90 ] 2>/dev/null && icon="⚠️"
                [ "$score" -lt 70 ] 2>/dev/null && icon="❌"
                printf "  %-25s %3s %s %5s %5s %7s %11s\n" "$ts" "$score" "$icon" "$nodes" "$edges" "$orphans" "$ghosts"
            done
        fi
        return 0
    fi
    
    # Collect metrics (with fallbacks for empty results)
    local total_nodes=$(db_query "SELECT COUNT(*) FROM nodes;" 2>/dev/null)
    total_nodes="${total_nodes:-0}"
    local active=$(db_query "SELECT COUNT(*) FROM nodes WHERE status='active';" 2>/dev/null)
    active="${active:-0}"
    local ready=$(cmd_ready --count 2>/dev/null)
    ready="${ready:-0}"
    local blocked=$(db_query "SELECT COUNT(*) FROM nodes WHERE status='blocked';" 2>/dev/null)
    blocked="${blocked:-0}"
    local blocked_ext=$(db_query "SELECT COUNT(*) FROM nodes WHERE status='blocked-external';" 2>/dev/null)
    blocked_ext="${blocked_ext:-0}"
    local done_count=$(db_query "SELECT COUNT(*) FROM nodes WHERE status='done';" 2>/dev/null)
    done_count="${done_count:-0}"
    local pending=$(db_query "SELECT COUNT(*) FROM nodes WHERE status='pending';" 2>/dev/null)
    pending="${pending:-0}"
    
    # Edge stats
    local total_edges=$(db_query "SELECT COUNT(*) FROM edges;" 2>/dev/null)
    total_edges="${total_edges:-0}"
    local blocking_edges=$(db_query "SELECT COUNT(*) FROM edges WHERE type='blocks';" 2>/dev/null)
    blocking_edges="${blocking_edges:-0}"
    
    # Pitfall stats
    local total_pitfalls=$(db_query "
        SELECT COUNT(*) FROM nodes 
        WHERE json_extract(metadata, '\$.pitfall') IS NOT NULL;
    ")
    local addressed_pitfalls=$(db_query "
        SELECT COUNT(DISTINCT n.id) FROM nodes n
        JOIN edges e ON e.target = n.id
        WHERE json_extract(n.metadata, '\$.pitfall') IS NOT NULL
        AND e.type IN ('addresses', 'implements', 'supersedes');
    ")
    local unaddressed_pitfalls=$((total_pitfalls - addressed_pitfalls))
    
    # Orphan nodes (no edges at all)
    local orphan_nodes=$(db_query "
        SELECT COUNT(*) FROM nodes n
        WHERE n.id NOT IN (SELECT source FROM edges)
        AND n.id NOT IN (SELECT target FROM edges);
    ")
    
    # Ghost edges (referencing non-existent nodes)
    local ghost_edges=$(db_query "
        SELECT COUNT(*) FROM edges
        WHERE source NOT IN (SELECT id FROM nodes)
        OR target NOT IN (SELECT id FROM nodes);
    ")
    
    # Stale active nodes (active for more than 7 days)
    local stale_active=$(db_query "
        SELECT COUNT(*) FROM nodes 
        WHERE status='active' 
        AND datetime(updated_at) < datetime('now', '-7 days');
    ")
    
    # Unresolved contradictions
    local contradictions=$(db_query "
        SELECT COUNT(*) FROM edges 
        WHERE type='contradicts';
    ")
    
    # Check for invalid statuses (wv-01e7 fix)
    local invalid_statuses
    invalid_statuses=$(db_query "
        SELECT COUNT(*) FROM nodes
        WHERE status NOT IN ('todo', 'active', 'done', 'blocked');
    ")
    
    # Health score calculation (0-100)
    local health_score=100
    local issues=""
    
    # Deduct points for issues
    if [ "$invalid_statuses" -gt 0 ]; then
        health_score=$((health_score - invalid_statuses * 20))
        issues="${issues}invalid_statuses:$invalid_statuses,"
    fi
    if [ "$unaddressed_pitfalls" -gt 0 ]; then
        health_score=$((health_score - unaddressed_pitfalls * 10))
        issues="${issues}unaddressed_pitfalls:$unaddressed_pitfalls,"
    fi
    if [ "$stale_active" -gt 0 ]; then
        health_score=$((health_score - stale_active * 5))
        issues="${issues}stale_active:$stale_active,"
    fi
    if [ "$contradictions" -gt 0 ]; then
        health_score=$((health_score - contradictions * 15))
        issues="${issues}unresolved_contradictions:$contradictions,"
    fi
    if [ "$ghost_edges" -gt 0 ]; then
        # Proportional penalty: ghost_ratio * 30, capped at 30
        # e.g. 50 ghosts / 134 total = 37% → penalty = min(11, 30) = 11
        local ghost_penalty=30
        if [ "$total_edges" -gt 0 ]; then
            ghost_penalty=$(( ghost_edges * 30 / total_edges ))
            [ "$ghost_penalty" -gt 30 ] && ghost_penalty=30
        fi
        [ "$ghost_penalty" -lt 5 ] && ghost_penalty=5  # minimum 5 if any ghosts exist
        health_score=$((health_score - ghost_penalty))
        issues="${issues}ghost_edges:$ghost_edges,"
    fi
    if [ "$orphan_nodes" -gt 5 ]; then
        # Proportional penalty: orphan_ratio * 15, capped at 15
        local orphan_penalty=5
        if [ "$total_nodes" -gt 0 ]; then
            orphan_penalty=$(( orphan_nodes * 15 / total_nodes ))
            [ "$orphan_penalty" -gt 15 ] && orphan_penalty=15
        fi
        [ "$orphan_penalty" -lt 3 ] && orphan_penalty=3  # minimum 3 if threshold exceeded
        health_score=$((health_score - orphan_penalty))
        issues="${issues}orphan_nodes:$orphan_nodes,"
    fi
    
    # Clamp to 0-100
    [ "$health_score" -lt 0 ] && health_score=0
    [ "$health_score" -gt 100 ] && health_score=100

    # Append to health history log (TSV: timestamp, score, nodes, edges, orphans, ghost_edges)
    local log_file="$WEAVE_DIR/health.log"
    mkdir -p "$WEAVE_DIR"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%S)" \
        "$health_score" "$total_nodes" "$total_edges" \
        "$orphan_nodes" "$ghost_edges" >> "$log_file"

    # Determine status emoji/text
    local status_icon status_text
    if [ "$health_score" -ge 90 ]; then
        status_icon="✅"
        status_text="healthy"
    elif [ "$health_score" -ge 70 ]; then
        status_icon="⚠️"
        status_text="warning"
    else
        status_icon="❌"
        status_text="unhealthy"
    fi
    
    if [ "$format" = "json" ]; then
        jq -n \
            --arg status "$status_text" \
            --argjson score "$health_score" \
            --argjson total_nodes "$total_nodes" \
            --argjson active "$active" \
            --argjson ready "$ready" \
            --argjson blocked "$blocked" \
            --argjson blocked_external "$blocked_ext" \
            --argjson done "$done_count" \
            --argjson pending "$pending" \
            --argjson total_edges "$total_edges" \
            --argjson blocking_edges "$blocking_edges" \
            --argjson total_pitfalls "$total_pitfalls" \
            --argjson addressed_pitfalls "$addressed_pitfalls" \
            --argjson unaddressed_pitfalls "$unaddressed_pitfalls" \
            --argjson orphan_nodes "$orphan_nodes" \
            --argjson ghost_edges "$ghost_edges" \
            --argjson stale_active "$stale_active" \
            --argjson contradictions "$contradictions" \
            --argjson invalid_statuses "$invalid_statuses" \
            '{
                status: $status,
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
                    ghost_edges: $ghost_edges,
                    stale_active: $stale_active,
                    unresolved_contradictions: $contradictions,
                    invalid_statuses: $invalid_statuses
                }
            }'
        return
    fi
    
    # Text output
    echo -e "${CYAN}Weave Health Check${NC} $status_icon"
    echo ""
    echo -e "${CYAN}Score:${NC} $health_score/100 ($status_text)"
    echo ""
    echo -e "${CYAN}Nodes:${NC}"
    echo "  Total: $total_nodes"
    local blocked_line="Active: $active | Ready: $ready | Blocked: $blocked"
    [ "$blocked_ext" -gt 0 ] && blocked_line="${blocked_line} | Blocked-Ext: $blocked_ext"
    echo "  ${blocked_line} | Done: $done_count | Pending: $pending"
    echo ""
    echo -e "${CYAN}Edges:${NC}"
    echo "  Total: $total_edges (blocking: $blocking_edges)"
    echo ""
    echo -e "${CYAN}Pitfalls:${NC}"
    if [ "$unaddressed_pitfalls" -gt 0 ]; then
        echo -e "  Total: $total_pitfalls | Addressed: $addressed_pitfalls | ${RED}Unaddressed: $unaddressed_pitfalls${NC}"
    else
        echo -e "  Total: $total_pitfalls | Addressed: $addressed_pitfalls | ${GREEN}Unaddressed: $unaddressed_pitfalls${NC}"
    fi
    
    if [ "$verbose" = true ]; then
        echo ""
        echo -e "${CYAN}Diagnostics:${NC}"
        echo "  Orphan nodes: $orphan_nodes"
        echo "  Ghost edges: $ghost_edges"
        echo "  Stale active (>7d): $stale_active"
        echo "  Unresolved contradictions: $contradictions"
        echo "  Invalid statuses: $invalid_statuses"
    fi
    
    # Show issues if any
    if [ -n "$issues" ] && [ "$health_score" -lt 100 ]; then
        echo ""
        echo -e "${YELLOW}Issues:${NC}"
        [ "$unaddressed_pitfalls" -gt 0 ] && echo -e "  ${YELLOW}⚠${NC} $unaddressed_pitfalls unaddressed pitfall(s) - run 'wv audit-pitfalls'"
        [ "$stale_active" -gt 0 ] && echo -e "  ${YELLOW}⚠${NC} $stale_active node(s) active >7 days - consider completing or closing"
        [ "$contradictions" -gt 0 ] && echo -e "  ${YELLOW}⚠${NC} $contradictions unresolved contradiction(s) - run 'wv edges <id>' to inspect"
        [ "$ghost_edges" -gt 0 ] && echo -e "  ${YELLOW}⚠${NC} $ghost_edges ghost edge(s) referencing deleted nodes - run 'wv clean-ghosts'"
        [ "$orphan_nodes" -gt 5 ] && echo -e "  ${YELLOW}⚠${NC} $orphan_nodes orphan node(s) with no edges - consider linking or pruning"
        [ "$invalid_statuses" -gt 0 ] && echo -e "  ${RED}✗${NC} $invalid_statuses node(s) with invalid status - run 'wv update <id> --status=todo' to fix"
    fi
}

# ═══════════════════════════════════════════════════════════════════════════
# cmd_audit_pitfalls — Show all pitfalls with resolution status
# ═══════════════════════════════════════════════════════════════════════════

cmd_audit_pitfalls() {
    local format="text"
    local show_addressed=true
    local show_unaddressed=true

    while [ $# -gt 0 ]; do
        case "$1" in
            --json) format="json" ;;
            --only-unaddressed) show_addressed=false ;;
            --only-addressed) show_unaddressed=false ;;
        esac
        shift
    done

    # Query all nodes with pitfall metadata
    local query="
        SELECT id, text, status, json(metadata) as metadata FROM nodes
        WHERE json_extract(metadata, '\$.pitfall') IS NOT NULL
        ORDER BY updated_at DESC;
    "

    local results
    results=$(db_query_json "$query")
    local count
    [ -z "$results" ] && count=0 || count=$(echo "$results" | jq 'length' 2>/dev/null || echo "0")

    if [ "$count" = "0" ] || [ "$count" = "" ]; then
        echo "No pitfalls recorded yet."
        return
    fi

    # For each pitfall node, check for incoming addresses/implements/supersedes edges
    echo "$results" | jq -c '.[]' | while IFS= read -r row; do
        local id text status pitfall
        id=$(echo "$row" | jq -r '.id')
        text=$(echo "$row" | jq -r '.text')
        status=$(echo "$row" | jq -r '.status')
        local metadata
        metadata=$(echo "$row" | jq -r '.metadata // "{}"')

        if [ "${metadata:0:1}" != "{" ]; then
            metadata=$(echo "$metadata" | jq -r '.' 2>/dev/null || echo "{}")
        fi

        pitfall=$(echo "$metadata" | jq -r '.pitfall // empty' 2>/dev/null)

        # Check for incoming resolution edges
        local resolvers
        resolvers=$(db_query "
            SELECT source FROM edges
            WHERE target='$id'
            AND type IN ('addresses', 'implements', 'supersedes')
        " 2>/dev/null || echo "")

        local is_addressed=false
        if [ -n "$resolvers" ]; then
            local resolver_count
            resolver_count=$(echo "$resolvers" | wc -l)
            [ "$resolver_count" -gt 0 ] && is_addressed=true
        fi

        if [ "$is_addressed" = true ]; then
            [ "$show_addressed" = false ] && continue
        else
            [ "$show_unaddressed" = false ] && continue
        fi

        if [ "$format" = "json" ]; then
            local resolver_ids
            if [ -n "$resolvers" ]; then
                resolver_ids=$(echo "$resolvers" | jq -R . | jq -s . 2>/dev/null || echo "[]")
            else
                resolver_ids="[]"
            fi
            jq -c -n \
                --arg id "$id" \
                --arg text "$text" \
                --arg status "$status" \
                --arg pitfall "$pitfall" \
                --argjson addressed "$is_addressed" \
                --argjson resolvers "$resolver_ids" \
                '{id: $id, text: $text, status: $status, pitfall: $pitfall, addressed: $addressed, addressed_by: $resolvers}'
        else
            local status_label node_status_label
            if [ "$is_addressed" = true ]; then
                status_label="${GREEN}[ADDRESSED]${NC}"
            else
                status_label="${RED}[UNADDRESSED]${NC}"
            fi
            # Show node status if not 'done'
            if [ "$status" != "done" ]; then
                node_status_label=" ${YELLOW}(${status})${NC}"
            else
                node_status_label=""
            fi
            echo -e "${CYAN}$id${NC} ${status_label}${node_status_label}: $text"
            echo -e "  ${YELLOW}Pitfall:${NC} $pitfall"

            if [ -n "$resolvers" ]; then
                echo -e "  ${GREEN}Addressed by:${NC}"
                echo "$resolvers" | while IFS= read -r resolver_id; do
                    [ -z "$resolver_id" ] && continue
                    local resolver_text
                    resolver_text=$(db_query "SELECT text FROM nodes WHERE id='$resolver_id';" 2>/dev/null)
                    echo "    - $resolver_id: $resolver_text"
                done
            fi
            echo ""
        fi
    done | if [ "$format" = "json" ]; then jq -s .; else cat; fi

    if [ "$format" != "json" ]; then
        # Count totals for summary
        local total_addressed
        local total_unaddressed
        total_addressed=$(db_query "
            SELECT COUNT(DISTINCT target) FROM edges
            WHERE type IN ('addresses', 'implements', 'supersedes')
            AND target IN (
                SELECT id FROM nodes
                WHERE json_extract(metadata, '\$.pitfall') IS NOT NULL
            )
        " 2>/dev/null || echo "0")
        total_unaddressed=$((count - total_addressed))

        echo -e "${CYAN}Summary:${NC}"
        echo -e "  Total pitfalls: $count"
        echo -e "  ${GREEN}Addressed: $total_addressed${NC}"
        echo -e "  ${RED}Unaddressed: $total_unaddressed${NC}"
    fi
}

# ═══════════════════════════════════════════════════════════════════════════
# cmd_edge_types — Show valid edge types
# ═══════════════════════════════════════════════════════════════════════════

cmd_edge_types() {
    echo -e "${CYAN}Valid edge types:${NC}"
    echo ""
    for type in $VALID_EDGE_TYPES; do
        case "$type" in
            blocks) echo -e "  ${GREEN}$type${NC} - Workflow dependency (target blocked by source)" ;;
            relates_to) echo -e "  ${GREEN}$type${NC} - General semantic relationship" ;;
            implements) echo -e "  ${GREEN}$type${NC} - Target implements source concept/spec" ;;
            contradicts) echo -e "  ${GREEN}$type${NC} - Target contradicts source" ;;
            supersedes) echo -e "  ${GREEN}$type${NC} - Target supersedes/replaces source" ;;
            references) echo -e "  ${GREEN}$type${NC} - Target references/mentions source" ;;
            obsoletes) echo -e "  ${GREEN}$type${NC} - Target makes source obsolete" ;;
            addresses) echo -e "  ${GREEN}$type${NC} - Source addresses/fixes pitfall in target" ;;
        esac
    done
}

# ═══════════════════════════════════════════════════════════════════════════
# ═══════════════════════════════════════════════════════════════════════════
# cmd_guide — Quick workflow reference
# ═══════════════════════════════════════════════════════════════════════════

cmd_guide() {
    local topic=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --topic=*) topic="${1#*=}" ;;
        esac
        shift
    done

    case "$topic" in
        workflow|"")
            cat <<'EOF'
Weave Workflow Quick Reference

  1. Find work:    wv ready
  2. Claim it:     wv work <id>
  3. Do the work   (edit files, run tests)
  4. Complete:     wv done <id> --learning="decision: ... | pattern: ... | pitfall: ..."
  5. Persist:      wv sync --gh && git push

Create new work:
  wv add "Description"               # standalone node
  wv add "Description" --gh          # node + GitHub issue (linked)
  wv add "Task" --parent=<epic-id>   # child of an epic

Topics: wv guide --topic=github | learnings | context
EOF
            ;;
        github)
            cat <<'EOF'
Weave GitHub Integration

Create with a linked issue (atomic):
  wv add "Fix auth bug" --gh         # creates node + GH issue, links them

Close (auto-closes linked GH issue):
  wv done <id> --learning="..."      # closes node + linked GH issue

Ship (done + sync + push in one):
  git add <files> && git commit -m "..."   # commit code first
  wv ship <id> --learning="..."            # close + sync + push

Sync epic bodies / Mermaid diagrams:
  wv sync --gh                       # full bidirectional sync

Check GitHub sync status:
  gh issue list --label weave-synced
  wv show <id> --json | jq '.[0].metadata | fromjson | .gh_issue'

Label taxonomy applied automatically:
  weave-synced   all Weave-linked issues
  epic           nodes with child tasks
  task           leaf task nodes
EOF
            ;;
        learnings)
            cat <<'EOF'
Weave Learnings

Capture on close (preferred format):
  wv done <id> --learning="decision: What was chosen and why | pattern: Reusable technique | pitfall: Specific mistake to avoid"

Or via metadata before closing:
  wv update <id> --metadata='{"decision":"...","pattern":"...","pitfall":"...","verification_evidence":"..."}'
  wv done <id>

Good learnings are:
  Specific  — not "be careful with X" but "X fails when Y because Z"
  Actionable — includes the fix, not just the problem
  Scoped    — tied to a concrete context, not generic advice

View learnings:
  wv learnings                          # all
  wv learnings --category=pitfall       # pitfalls only
  wv learnings --grep="sqlite"          # search
  wv learnings --recent=5               # last 5
  wv learnings --node=<id>              # for one node
  wv audit-pitfalls --only-unaddressed  # unresolved pitfalls
EOF
            ;;
        context)
            cat <<'EOF'
Weave Context Policy

Session start hook injects a policy based on repo size:
  HIGH   — read files <500 lines whole; grep first for larger
  MEDIUM — always grep before read; no full reads >500 lines
  LOW    — always grep first; only read <200 line slices; summarize

Context Pack (before complex work):
  wv context <id> --json | jq .
  Returns: node, blockers, ancestors, related nodes, pitfalls, contradictions

Scope rules:
  - Max 4-5 tasks per session (context limits kill mid-task)
  - Check wv status before editing — 0 active nodes means create one first
  - Run wv context before starting complex work to see pitfalls + ancestors
EOF
            ;;
        *)
            echo "Unknown topic: $topic" >&2
            echo "Topics: workflow (default), github, learnings, context" >&2
            return 1
            ;;
    esac
}

# ═══════════════════════════════════════════════════════════════════════════
# cmd_help — Show help
# ═══════════════════════════════════════════════════════════════════════════

cmd_help() {
    cat <<EOF
wv — Weave CLI: In-memory graph for AI coding agents

Usage: wv <command> [args]

Commands:
  init              Initialize database
  add <text>        Add a node (returns ID) [--gh creates GitHub issue]
  delete <id>       Permanently remove a node + edges [--force] [--dry-run] [--no-gh]
  done <id>         Mark node complete [--learning="..."] [--no-warn] [auto-closes GH issue]
  batch-done        Close multiple nodes [--learning="..."] [--no-warn]
  bulk-update       Update multiple nodes from JSON on stdin [--dry-run]
  work <id>         Claim node & set WV_ACTIVE for subagent context [--quiet]
  ready             List unblocked work
  list              List nodes (excludes done by default)
  show <id>         Show node details
  status            Compact status for context injection
  update <id>       Update node (--status=, --text=, --metadata=, --remove-key=)
  block <id>        Add blocking edge (--by=<blocker>)
  link <from> <to>  Create semantic edge (--type=<type> [--weight=] [--context=])
  resolve <n1> <n2> Resolve contradiction (--winner=<id> | --merge | --defer [--rationale=])
  related <id>      Show semantic relationships ([--type=] [--direction=] [--json])
  edges <id>        Inspect all edges for a node ([--type=] [--json])
  path <id>         Show ancestry chain
  tree              Show epic -> task hierarchy [--active] [--depth=N] [--json] [--mermaid] [root]
  plan <file>       Import markdown section as epic + tasks [--sprint=N] [--gh] [--dry-run] [--template]
  context [id]      Generate Context Pack [--json required] (uses WV_ACTIVE if no id)
  search <query>    Full-text search nodes [--limit=N] [--status=] [--json]
  reindex           Rebuild full-text search index
  learnings         Show captured learnings [--category=] [--grep=] [--recent=N]
  breadcrumbs       Session breadcrumbs [save|show|clear] [--message="..."]
  digest            Compact one-liner health summary [--json]
  session-summary   Session activity stats (nodes created/completed, learnings)
  audit-pitfalls    Show all pitfalls with resolution status
  doctor            Installation health check (deps, modules, hot zone) [--json]
  selftest          Round-trip smoke test in isolated environment [--json]
  mcp-status        Verify MCP server is built and IDE-configured [--json]
  health            System health check with score and diagnostics [--history[=N]]
  guide             Workflow quick reference [--topic=workflow|github|learnings|context]
  prune             Archive old done nodes
  refs <file|text>  Extract cross-references (dry-run, no edges)
  import <file>     Import from beads JSONL or JSON
  batch [file]      Execute multiple wv commands from file or stdin [--dry-run] [--stop-on-error]
  sync              Persist to git layer (.weave/) [--gh GH sync] [--dry-run]
  load              Load from git layer

Options:
  --json            Output as JSON (ready, list, show, health, search)
  --all             Include done nodes (list)
  --count           Return count only (ready)
  --verbose, -v     Show diagnostics (health)
  --history[=N]     Show last N health checks (default 10)
  --format=chain    Show as "A → B → C" (path)
  --node=<id>       Filter to one node (learnings)
  --show-graph      Show pitfall resolution graph (learnings)
  --age=48h         Prune age threshold (prune)
  --dry-run         Show what would be pruned (prune, import)
  --max=N           Max references to extract (refs, default 10)
  --limit=N         Max results to return (search, default 10)
  --status=<status> Filter by status (search)
  --link            Create edges for detected refs (refs, requires --from)
  --from=<id>       Source node for edge creation (refs --link)
  --interactive     Prompt for non-auto refs in link mode (refs --link)
  --gh              Create GitHub issue (add) or run GH sync (sync)
  --learning="..."  Store learning note on close (done)
  --no-warn         Suppress validation warnings (done) [also: WV_NO_WARN=1]
  --remove-key=<k>  Remove a single metadata key (update)
  --metadata=<json> Merge JSON into existing metadata (update)
  --category=<cat>  Filter by type: decision/pattern/pitfall/learning (learnings)
  --grep=<pattern>  Search text and metadata (learnings)
  --recent=<N>      Show only last N learnings (learnings)
  --message="..."   Custom note for breadcrumbs (breadcrumbs save)

Examples:
  wv add "Fix authentication bug"
  wv add "Refactor API" --status=active --gh
  wv ready
  wv work wv-a1b2                             # claim node, show WV_ACTIVE export
  eval "\$(wv work wv-a1b2 --quiet)"          # claim and set WV_ACTIVE in one command
  wv context --json                           # uses WV_ACTIVE if set
  wv done wv-a1b2 --learning="pattern: always check X"
  wv batch-done wv-a1b2 wv-c3d4 --learning="sprint complete"
  echo '[{"id":"wv-a1b2","alias":"my-task"},{"id":"wv-c3d4","status":"active"}]' | wv bulk-update
  wv update wv-a1b2 --metadata='{"priority":1}'  # merges, not replaces
  wv update wv-a1b2 --remove-key=old_field        # remove single key
  wv block wv-c3d4 --by=wv-a1b2
  wv link wv-a1b2 wv-c3d4 --type=implements --weight=0.8
  wv resolve wv-a1b2 wv-c3d4 --winner=wv-a1b2 --rationale="Approach A is more performant"
  wv related wv-a1b2 --type=implements
  wv edges wv-a1b2
  wv sync --gh
  wv path wv-c3d4 --format=chain
  wv search "authentication" --limit=5
  wv search "bug" --status=todo --json
  wv reindex
  wv plan --template > docs/my-plan.md          # scaffold a plan from template
  wv plan docs/my-plan.md --sprint=1 --dry-run   # preview import
  wv plan docs/my-plan.md --sprint=1 --gh         # import with GitHub issues
  wv refs docs/design.md
  wv refs -t "see wv-a1b2" --link --from=wv-c3d4
  wv refs file.md --json
  wv breadcrumbs save --message="Pausing for review"
  wv breadcrumbs show
  wv digest
  wv learnings --category=pitfall --recent=5
  wv learnings --grep="testing"
  wv done wv-a1b2 --no-warn
EOF
}
