#!/bin/bash
# wv-cmd-ops.sh — Operations and diagnostic commands
#
# Commands: health, cache, audit-pitfalls, edge-types, help
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
        # shellcheck disable=SC1010  # 'done' is a jq arg name, not the bash keyword
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
    # Suppressed when: (a) verification_method metadata is set, or (b) learning string
    # contains implicit verification keywords (test, passed, verified, lint, etc.)
    local has_verification
    has_verification=$(db_query "
        SELECT COUNT(*) FROM nodes WHERE id='$id'
        AND json_extract(metadata, '\$.verification_method') IS NOT NULL;
    " 2>/dev/null || echo "0")
    if [ "$has_verification" = "0" ]; then
        local learning_text has_implicit kw
        learning_text=$(db_query "
            SELECT LOWER(COALESCE(json_extract(metadata, '\$.learning'), ''))
            FROM nodes WHERE id='$id';
        " 2>/dev/null || echo "")
        has_implicit=false
        for kw in "test" "passed" "verified" "lint" "clean" "make check" "pytest" "ruff" "mypy" "shellcheck"; do
            if [[ "$learning_text" == *"$kw"* ]]; then
                has_implicit=true
                break
            fi
        done
        if [ "$has_implicit" = false ]; then
            warnings="${warnings}\n  ⚠ No verification evidence — consider: wv update $id --metadata='{\"verification_method\":\"tests passed\"}'"
        fi
    fi

    local node_meta node_type finding_missing
    node_meta=$(_done_read_metadata "$id")
    node_type=$(echo "$node_meta" | jq -r '.type // "task"' 2>/dev/null || echo "task")
    if [ "$node_type" = "finding" ]; then
        finding_missing=$(_finding_missing_fields "$node_meta" | paste -sd ', ' - || true)
        if [ -n "$finding_missing" ]; then
            warnings="${warnings}\n  ⚠ Incomplete finding schema — missing or invalid ${finding_missing}"
        fi
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

    # Check: metadata size guard — large metadata (>50KB) causes sqlite3 -json to hang during sync
    local meta_size
    meta_size=$(db_query "
        SELECT LENGTH(COALESCE(metadata, '{}')) FROM nodes WHERE id='$id';
    " 2>/dev/null || echo "0")
    if [ "$meta_size" -gt 51200 ] 2>/dev/null; then
        warnings="${warnings}\n  ⚠ Metadata is ${meta_size} bytes (>50KB) — may cause wv sync to hang. Check for escape accumulation in learning strings."
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
    new_meta=$(echo "$meta" | jq --argjson s "$score" '. + {learning_hygiene: $s}' 2>/dev/null)
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
# cmd_recover — Resume incomplete operations from journal or ship_pending
# ═══════════════════════════════════════════════════════════════════════════

cmd_recover() {
    local json_mode=false
    local auto_mode=false
    local session_mode=false
    while [ $# -gt 0 ]; do
        case "$1" in
            --json) json_mode=true ;;
            --auto) auto_mode=true ;;  # Non-interactive (for wv init/work/ship triggers)
            --session) session_mode=true ;;  # Orphaned active node recovery
        esac
        shift
    done

    # === Session recovery: orphaned active nodes from crashed sessions ===
    if [ "$session_mode" = true ]; then
        _recover_session "$json_mode" "$auto_mode"
        return $?
    fi

    # Source 1: Journal-based recovery (hot zone, lost on reboot)
    local journal_found=false
    local recovery_info=""
    if journal_has_incomplete 2>/dev/null; then
        journal_found=true
        recovery_info=$(journal_recover --json 2>/dev/null || echo '{}')
    fi

    # Source 2: ship_pending metadata fallback (survives reboot via state.sql)
    local pending_nodes=""
    if [ "$journal_found" = false ]; then
        pending_nodes=$(db_query "
            SELECT id, text, json_extract(metadata, '$.ship_pending') as sp
            FROM nodes
            WHERE json_extract(metadata, '$.ship_pending') IS NOT NULL
                AND json_extract(metadata, '$.ship_pending') = 1;
        " 2>/dev/null || true)
    fi

    # Source 3: pending_close markers that need explicit human acknowledgement
    local pending_close_nodes=""
    if [ "$journal_found" = false ] && [ -z "$pending_nodes" ]; then
        pending_close_nodes=$(db_query "
            SELECT id || '|' || text || '|' ||
                   COALESCE(json_extract(metadata, '$.pending_close.reason'), '') || '|' ||
                   COALESCE(json_extract(metadata, '$.pending_close.resume_command'), '')
            FROM nodes
            WHERE json_extract(metadata, '$.needs_human_verification') = 1
                AND json_extract(metadata, '$.pending_close.reason') IS NOT NULL;
        " 2>/dev/null || true)
    fi

    # Nothing to recover
    if [ "$journal_found" = false ] && [ -z "$pending_nodes" ] && [ -z "$pending_close_nodes" ]; then
        if [ "$json_mode" = true ]; then
            echo '{"status":"clean","message":"No incomplete operations"}'
        elif [ "$auto_mode" != true ]; then
            echo -e "${GREEN}✓${NC} No incomplete operations found"
        fi
        return 0
    fi

    # === Journal-based recovery ===
    if [ "$journal_found" = true ]; then
        local op op_id completed_steps pending_step pending_action args
        op=$(echo "$recovery_info" | jq -r '.operation.op')
        op_id=$(echo "$recovery_info" | jq -r '.operation.op_id')
        completed_steps=$(echo "$recovery_info" | jq -r '.operation.completed_steps | join(",")' 2>/dev/null)
        pending_step=$(echo "$recovery_info" | jq -r '.operation.pending_step.step // "unknown"')
        pending_action=$(echo "$recovery_info" | jq -r '.operation.pending_step.action // "unknown"')
        args=$(echo "$recovery_info" | jq -c '.operation.args // {}')

        if [ "$json_mode" = true ]; then
            echo "$recovery_info"
            return 0
        fi

        echo -e "${YELLOW}⚠ Incomplete operation detected${NC}"
        echo "  Operation: wv $op ($op_id)"
        echo "  Completed steps: ${completed_steps:-none}"
        echo "  Stuck at: step $pending_step ($pending_action)"
        echo ""

        # Determine recovery action based on op type and stuck step
        case "$op" in
            ship)
                _recover_ship "$args" "$pending_action" "$auto_mode"
                ;;
            sync)
                _recover_sync "$args" "$pending_action" "$auto_mode"
                ;;
            delete)
                _recover_delete "$args" "$pending_action" "$auto_mode"
                ;;
            *)
                echo -e "${YELLOW}Unknown operation type: $op${NC}" >&2
                echo "  Journal entry preserved. Manual recovery may be needed." >&2
                return 1
                ;;
        esac

        # Mark recovered op as complete so journal_clean can remove it
        _WV_CURRENT_OP_ID="$op_id"
        _WV_CURRENT_OP_TYPE="$op"
        journal_end

        # Clean completed ops from journal
        journal_clean
        return 0
    fi

    # === ship_pending fallback (reboot recovery) ===
    if [ -n "$pending_nodes" ]; then
        if [ "$json_mode" = true ]; then
            echo "{\"status\":\"ship_pending\",\"nodes\":$(echo "$pending_nodes" | jq -R -s 'split("\n") | map(select(length > 0) | split("|") | {id: .[0], text: .[1]})')}"
            return 0
        fi

        echo -e "${YELLOW}⚠ Found node(s) with ship_pending marker (likely interrupted by reboot)${NC}"
        echo "$pending_nodes" | while IFS='|' read -r node_id node_text _; do
            [ -z "$node_id" ] && continue
            echo "  $node_id: $node_text"
        done
        echo ""

        if [ "$auto_mode" = true ]; then
            echo -e "${CYAN}ℹ${NC} Auto-recovering: running sync + push for pending nodes"
        else
            echo -n "  Resume shipping these nodes? [Y/n] "
            read -r answer
            if [ "$answer" = "n" ] || [ "$answer" = "N" ]; then
                echo "  Skipped. Clear markers with: wv update <id> --metadata='{\"ship_pending\":null}'"
                return 0
            fi
        fi

        # Recovery: sync + push (node is already done, just need to persist)
        cmd_sync 2>/dev/null || true
        local git_root
        git_root=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
        if [ -n "$git_root" ]; then
            git -C "$git_root" add .weave/ 2>/dev/null || true
            git -C "$git_root" commit -m "chore: recover ship-pending nodes [skip ci]" --allow-empty 2>/dev/null || true
            if git -C "$git_root" push 2>/dev/null; then
                echo -e "${GREEN}✓${NC} Push successful"
            else
                echo -e "${RED}✗ Push failed${NC}" >&2
                return 1
            fi
        fi

        # Clear ship_pending markers
        echo "$pending_nodes" | while IFS='|' read -r node_id _ _; do
            [ -z "$node_id" ] && continue
            db_query "UPDATE nodes SET metadata = json_remove(metadata, '$.ship_pending') WHERE id = '$node_id';" 2>/dev/null || true
        done
        echo -e "${GREEN}✓${NC} Recovery complete"
    fi

    # === pending_close fallback (human verification required) ===
    if [ -n "$pending_close_nodes" ]; then
        if [ "$json_mode" = true ]; then
            local pending_close_json
            pending_close_json=$(echo "$pending_close_nodes" | jq -R -s '
                split("\n") |
                map(select(length > 0) | split("|") | {
                    id: .[0],
                    text: .[1],
                    reason: .[2],
                    resume_command: .[3]
                })')
            echo "{\"status\":\"needs_human_verification\",\"nodes\":$pending_close_json}"
            return 0
        fi

        echo -e "${YELLOW}⚠ Node(s) waiting for human verification before close${NC}"
        echo "$pending_close_nodes" | while IFS='|' read -r node_id node_text pending_reason resume_cmd; do
            [ -z "$node_id" ] && continue
            echo "  $node_id: $node_text"
            echo "    Reason: $pending_reason"
            if [ -n "$resume_cmd" ]; then
                echo "    Resume: $resume_cmd"
            fi
        done
        if [ "$auto_mode" = true ]; then
            echo -e "${CYAN}ℹ${NC} Leaving pending-close state for explicit human approval"
        fi
        return 0
    fi
}

# Recovery helpers for specific operation types

_recover_ship() {
    local args="$1"
    local stuck_action="$2"
    local auto="$3"
    local id
    id=$(echo "$args" | jq -r '.id // empty')

    case "$stuck_action" in
        done)
            echo "  Recovery: re-run cmd_done + sync + commit + push"
            if [ "$auto" != true ]; then
                echo -n "  Proceed? [Y/n] "
                read -r answer
                [ "$answer" = "n" ] || [ "$answer" = "N" ] && return 0
            fi
            cmd_done "$id" --no-warn 2>/dev/null || true
            cmd_sync 2>/dev/null || true
            _recover_git_commit_push "$id"
            ;;
        sync)
            echo "  Recovery: re-run sync + commit + push"
            if [ "$auto" != true ]; then
                echo -n "  Proceed? [Y/n] "
                read -r answer
                [ "$answer" = "n" ] || [ "$answer" = "N" ] && return 0
            fi
            cmd_sync 2>/dev/null || true
            _recover_git_commit_push "$id"
            ;;
        git_commit)
            echo "  Recovery: re-run git commit + push"
            if [ "$auto" != true ]; then
                echo -n "  Proceed? [Y/n] "
                read -r answer
                [ "$answer" = "n" ] || [ "$answer" = "N" ] && return 0
            fi
            _recover_git_commit_push "$id"
            ;;
        git_push)
            echo "  Recovery: re-run git push"
            if [ "$auto" != true ]; then
                echo -n "  Proceed? [Y/n] "
                read -r answer
                [ "$answer" = "n" ] || [ "$answer" = "N" ] && return 0
            fi
            local git_root
            git_root=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
            if [ -n "$git_root" ]; then
                if git -C "$git_root" push 2>/dev/null; then
                    echo -e "${GREEN}✓${NC} Push successful"
                else
                    echo -e "${RED}✗ Push failed${NC}" >&2
                    return 1
                fi
            fi
            ;;
    esac

    # Clear ship_pending if present
    [ -n "$id" ] && db_query "UPDATE nodes SET metadata = json_remove(metadata, '$.ship_pending') WHERE id = '$id';" 2>/dev/null || true
    echo -e "${GREEN}✓${NC} Recovery complete"
}

_recover_sync() {
    local args="$1"
    local stuck_action="$2"
    local auto="$3"

    case "$stuck_action" in
        dump)
            echo "  Recovery: re-run full sync"
            ;;
        gh_sync)
            echo "  Recovery: re-run GH sync + commit"
            ;;
        git_commit)
            echo "  Recovery: re-run git commit"
            ;;
    esac

    if [ "$auto" != true ]; then
        echo -n "  Proceed? [Y/n] "
        read -r answer
        [ "$answer" = "n" ] || [ "$answer" = "N" ] && return 0
    fi

    local gh_flag
    gh_flag=$(echo "$args" | jq -r '.gh // false')
    if [ "$gh_flag" = "true" ]; then
        cmd_sync --gh 2>/dev/null || true
    else
        cmd_sync 2>/dev/null || true
    fi
    echo -e "${GREEN}✓${NC} Recovery complete"
}

_recover_delete() {
    local args="$1"
    local stuck_action="$2"
    local auto="$3"
    local gh_issue
    gh_issue=$(echo "$args" | jq -r '.gh_issue // empty')

    if [ "$stuck_action" = "gh_close" ] && [ -n "$gh_issue" ]; then
        echo "  Recovery: close GitHub issue #$gh_issue"
        if [ "$auto" != true ]; then
            echo -n "  Proceed? [Y/n] "
            read -r answer
            [ "$answer" = "n" ] || [ "$answer" = "N" ] && return 0
        fi
        if command -v gh >/dev/null 2>&1; then
            local repo
            repo=$(gh repo view --json nameWithOwner -q '.nameWithOwner' 2>/dev/null || echo "")
            if [ -n "$repo" ]; then
                gh issue close "$gh_issue" --repo "$repo" 2>/dev/null && \
                    echo -e "${GREEN}✓${NC} Closed GitHub issue #$gh_issue" >&2 || \
                    echo -e "${YELLOW}Warning: Could not close issue${NC}" >&2
            fi
        fi
    else
        echo "  SQLite delete already completed. No further recovery needed."
    fi
    echo -e "${GREEN}✓${NC} Recovery complete"
}

_recover_git_commit_push() {
    local id="${1:-}"
    local git_root
    git_root=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
    if [ -n "$git_root" ]; then
        git -C "$git_root" add .weave/ 2>/dev/null || true
        local msg="chore: sync Weave [skip ci]"
        [ -n "$id" ] && msg="chore: sync Weave after completing $id [skip ci]"
        git -C "$git_root" commit -m "$msg" --allow-empty 2>/dev/null || true
        if git -C "$git_root" push 2>/dev/null; then
            echo -e "${GREEN}✓${NC} Pushed to remote"
        else
            echo -e "${RED}✗ Push failed${NC}" >&2
            return 1
        fi
    fi
}

# _recover_session — List/reclaim orphaned active nodes from crashed sessions
_recover_session() {
    local json_mode="$1"
    local auto_mode="$2"

    # Get all active nodes
    local active_nodes
    active_nodes=$(db_query "SELECT id, text FROM nodes WHERE status='active' ORDER BY id;" 2>/dev/null || true)

    local active_count=0
    if [ -n "$active_nodes" ]; then
        active_count=$(echo "$active_nodes" | wc -l)
    fi

    if [ "$active_count" -eq 0 ]; then
        if [ "$json_mode" = true ]; then
            echo '{"status":"clean","orphaned_nodes":[],"message":"No orphaned active nodes"}'
        else
            echo -e "${GREEN}✓${NC} No orphaned active nodes found"
        fi
        return 0
    fi

    if [ "$json_mode" = true ]; then
        local json_nodes="[]"
        json_nodes=$(echo "$active_nodes" | while IFS='|' read -r node_id node_text; do
            [ -z "$node_id" ] && continue
            jq -n --arg id "$node_id" --arg text "$node_text" '{id: $id, text: $text}'
        done | jq -s '.')
        jq -n --argjson nodes "$json_nodes" --argjson count "$active_count" \
            '{status: "orphaned", orphaned_nodes: $nodes, count: $count}'
        return 0
    fi

    echo -e "${YELLOW}⚠ ${active_count} node(s) marked active (possibly orphaned from a crashed session):${NC}"
    echo "$active_nodes" | while IFS='|' read -r node_id node_text; do
        [ -z "$node_id" ] && continue
        echo "  $node_id: $node_text"
    done
    echo ""

    if [ "$auto_mode" = true ]; then
        echo -e "${CYAN}ℹ${NC} Auto-reclaiming all active nodes for this session"
        echo "$active_nodes" | while IFS='|' read -r node_id _; do
            [ -z "$node_id" ] && continue
            # Nodes are already active — just confirm
            echo -e "  ${GREEN}✓${NC} $node_id — already active"
        done
        return 0
    fi

    echo "  Options:"
    echo "    wv work <id>           — Re-claim specific node"
    echo "    wv done <id>           — Close if work was complete at crash"
    echo "    wv update <id> --status=todo — Release back to ready queue"
    return 0
}

# ═══════════════════════════════════════════════════════════════════════════
# cmd_doctor — Installation health check
# ═══════════════════════════════════════════════════════════════════════════

# Shared state for _doctor_record (avoids nested function dynamic scoping)
_dr_pass=0 _dr_fail=0 _dr_warn=0 _dr_total=0 _dr_results="" _dr_format="text"

_doctor_record() {
    local name="$1" status="$2" detail="$3"
    _dr_total=$((_dr_total + 1))
    case "$status" in
        pass) _dr_pass=$((_dr_pass + 1)) ;;
        fail) _dr_fail=$((_dr_fail + 1)) ;;
        warn) _dr_warn=$((_dr_warn + 1)) ;;
    esac
    if [ "$_dr_format" = "json" ]; then
        _dr_results="${_dr_results:+$_dr_results,}$(printf '{"check":"%s","status":"%s","detail":"%s"}' "$name" "$status" "$detail")"
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

# _doctor_check_modules — Check a directory for expected module files
_doctor_check_modules() {
    local label="$1" dir="$2" expected="$3"
    local found=0 missing=""
    for mod in $expected; do
        if [ -f "$dir/$mod" ]; then
            found=$((found + 1))
        else
            missing="${missing:+$missing, }$mod"
        fi
    done
    local total_expected
    total_expected=$(echo "$expected" | wc -w | tr -d ' ')
    if [ "$found" -eq "$total_expected" ]; then
        _doctor_record "$label" "pass" "$found/$total_expected"
    else
        _doctor_record "$label" "fail" "$found/$total_expected (missing: $missing)"
    fi
}

cmd_doctor() {
    _dr_format="text"
    while [ $# -gt 0 ]; do
        case "$1" in
            --json) _dr_format="json" ;;
        esac
        shift
    done

    _dr_pass=0 _dr_fail=0 _dr_warn=0 _dr_total=0 _dr_results=""

    [ "$_dr_format" = "text" ] && echo "Weave Doctor — Installation Health"

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

    # 11-12. Module checks
    _doctor_check_modules "lib modules" "$WV_LIB_DIR/lib" \
        "wv-config.sh wv-db.sh wv-validate.sh wv-cache.sh wv-journal.sh wv-gh.sh wv-resolve-project.sh"
    _doctor_check_modules "cmd modules" "$WV_LIB_DIR/cmd" \
        "wv-cmd-core.sh wv-cmd-graph.sh wv-cmd-data.sh wv-cmd-ops.sh wv-cmd-quality.sh"

    # 13. .weave dir
    if [ -d "${WEAVE_DIR:-}" ]; then
        _doctor_record ".weave" "pass" "present"
    else
        _doctor_record ".weave" "warn" "not found"
    fi

    # 14. Journal health: check for incomplete operations
    if journal_has_incomplete 2>/dev/null; then
        local journal_info
        journal_info=$(journal_recover --json 2>/dev/null || echo '{}')
        local journal_op
        journal_op=$(echo "$journal_info" | jq -r '.operation.op // "unknown"' 2>/dev/null)
        _doctor_record "journal" "warn" "incomplete '$journal_op' operation — run 'wv recover'"
    else
        _doctor_record "journal" "pass" "clean (no incomplete operations)"
    fi

    # ── Surface-contract checks ──────────────────────────────────────────────

    # 15. Hook source vs installed drift: compare .claude/hooks/ with ~/.config/weave/hooks/
    local source_hooks_dir="${WEAVE_DIR:+$(dirname "$WEAVE_DIR")}/.claude/hooks"
    # Fallback: walk up from WV_LIB_DIR to find .claude/hooks
    if [ ! -d "$source_hooks_dir" ] && [ -n "${WV_LIB_DIR:-}" ]; then
        local candidate
        candidate=$(dirname "$WV_LIB_DIR")
        [ -d "$candidate/.claude/hooks" ] && source_hooks_dir="$candidate/.claude/hooks"
    fi
    local installed_hooks_dir="$HOME/.config/weave/hooks"
    if [ -d "$source_hooks_dir" ] && [ -d "$installed_hooks_dir" ]; then
        local drifted=""
        for src in "$source_hooks_dir"/*.sh; do
            local fname
            fname=$(basename "$src")
            local dst="$installed_hooks_dir/$fname"
            if [ ! -f "$dst" ]; then
                drifted="${drifted:+$drifted, }$fname (missing)"
            elif [ "$(md5sum "$src" 2>/dev/null | awk '{print $1}')" != "$(md5sum "$dst" 2>/dev/null | awk '{print $1}')" ]; then
                drifted="${drifted:+$drifted, }$fname (stale)"
            fi
        done
        if [ -z "$drifted" ]; then
            _doctor_record "hook drift" "pass" "source and installed hooks match"
        else
            _doctor_record "hook drift" "warn" "run ./install.sh — drifted: $drifted"
        fi
    else
        _doctor_record "hook drift" "warn" "cannot compare — source or installed hooks dir missing"
    fi

    # 16. wv-runtime wrapper present
    if command -v wv-runtime >/dev/null 2>&1; then
        _doctor_record "wv-runtime" "pass" "$(command -v wv-runtime)"
    else
        _doctor_record "wv-runtime" "warn" "not found — install with ./install.sh"
    fi

    # 17. Pre-commit hook installed and is the Weave version
    local git_root
    git_root=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
    if [ -n "$git_root" ]; then
        local pre_commit="$git_root/.git/hooks/pre-commit"
        if [ -f "$pre_commit" ]; then
            if grep -q "Weave pre-commit" "$pre_commit" 2>/dev/null; then
                _doctor_record "pre-commit hook" "pass" "Weave hook installed"
            else
                _doctor_record "pre-commit hook" "warn" "exists but not the Weave version — cp scripts/hooks/pre-commit-weave.sh .git/hooks/pre-commit"
            fi
        else
            _doctor_record "pre-commit hook" "warn" "not installed — cp scripts/hooks/pre-commit-weave.sh .git/hooks/pre-commit"
        fi
    fi

    # 18. Ghost settings: check for chat.hooks.enabled in .vscode/settings.json
    if [ -n "$git_root" ] && [ -f "$git_root/.vscode/settings.json" ]; then
        if grep -q '"chat.hooks.enabled"' "$git_root/.vscode/settings.json" 2>/dev/null; then
            _doctor_record "ghost settings" "warn" '.vscode/settings.json contains chat.hooks.enabled — may interfere with Claude Code hooks'
        else
            _doctor_record "ghost settings" "pass" "no known ghost settings detected"
        fi
    fi

    # 19. Claude settings hook matcher coverage (PreToolUse covers Edit/Write/Bash)
    local claude_settings="$HOME/.claude/settings.json"
    if [ -f "$claude_settings" ]; then
        local matcher
        matcher=$(jq -r '.hooks.PreToolUse[]? | select(.hooks[]?.command | contains("pre-action")) | .matcher // ""' "$claude_settings" 2>/dev/null | head -1)
        if [ -n "$matcher" ]; then
            local missing_tools=""
            for tool in Edit Write Bash; do
                echo "$matcher" | grep -q "$tool" || missing_tools="${missing_tools:+$missing_tools, }$tool"
            done
            if [ -z "$missing_tools" ]; then
                _doctor_record "hook matchers" "pass" "Edit, Write, Bash covered"
            else
                _doctor_record "hook matchers" "warn" "missing: $missing_tools — run ./install.sh"
            fi
        else
            _doctor_record "hook matchers" "warn" "pre-action hook not registered in ~/.claude/settings.json — run ./install.sh"
        fi
    fi

    # Summary
    if [ "$_dr_format" = "json" ]; then
        local overall="pass"
        [ "$_dr_fail" -gt 0 ] && overall="fail"
        printf '{"overall":"%s","passed":%d,"failed":%d,"warnings":%d,"total":%d,"checks":[%s]}\n' \
            "$overall" "$_dr_pass" "$_dr_fail" "$_dr_warn" "$_dr_total" "$_dr_results"
    else
        echo ""
        if [ "$_dr_fail" -gt 0 ]; then
            echo -e "Result: ${RED}${_dr_pass}/${_dr_total} passed${NC} (${_dr_fail} failed, ${_dr_warn} warnings)"
        elif [ "$_dr_warn" -gt 0 ]; then
            echo -e "Result: ${GREEN}${_dr_pass}/${_dr_total} passed${NC} (${_dr_warn} warnings)"
        else
            echo -e "Result: ${GREEN}${_dr_pass}/${_dr_total} passed${NC}"
        fi
    fi

    [ "$_dr_fail" -gt 0 ] && return 1
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
        _st_results="${_st_results:+$_st_results,}$(printf '{"test":"%s","status":"%s","detail":"%s"}' "$name" "$status" "$detail")"
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
_h_orphan_nodes=0 _h_orphan_ids="[]" _h_ghost_edges=0 _h_empty_edge_ctx=0
_h_gh_duplicates=0 _h_gh_duplicate_issues="[]"
_h_stale_active=0 _h_contradictions=0 _h_invalid_statuses=0
_h_health_score=100 _h_issues="" _h_fixed_edge_ctx=0
_h_status_icon="" _h_status_text=""
_h_quality_available="false" _h_quality_score=0 _h_quality_hotspots=0
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
    total=$(wc -l < "$log_file")
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
    _h_done_count=$(db_query "SELECT COUNT(*) FROM nodes WHERE status='done';" 2>/dev/null)
    _h_done_count="${_h_done_count:-0}"
    _h_pending=$(db_query "SELECT COUNT(*) FROM nodes WHERE status='pending';" 2>/dev/null)
    _h_pending="${_h_pending:-0}"

    # Edge stats
    _h_total_edges=$(db_query "SELECT COUNT(*) FROM edges;" 2>/dev/null)
    _h_total_edges="${_h_total_edges:-0}"
    _h_blocking_edges=$(db_query "SELECT COUNT(*) FROM edges WHERE type='blocks';" 2>/dev/null)
    _h_blocking_edges="${_h_blocking_edges:-0}"

    # Pitfall stats
    _h_total_pitfalls=$(db_query "
        SELECT COUNT(*) FROM nodes
        WHERE json_extract(metadata, '\$.pitfall') IS NOT NULL;
    ")
    _h_addressed_pitfalls=$(db_query "
        SELECT COUNT(DISTINCT n.id) FROM nodes n
        JOIN edges e ON e.target = n.id
        WHERE json_extract(n.metadata, '\$.pitfall') IS NOT NULL
        AND e.type IN ('addresses', 'implements', 'supersedes');
    ")
    _h_unaddressed_pitfalls=$((_h_total_pitfalls - _h_addressed_pitfalls))

    # Orphan nodes (no edges at all)
    _h_orphan_nodes=$(db_query "
        SELECT COUNT(*) FROM nodes n
        WHERE n.id NOT IN (SELECT source FROM edges)
        AND n.id NOT IN (SELECT target FROM edges);
    ")
    _h_orphan_ids=$(db_query "
        SELECT json_group_array(n.id) FROM nodes n
        WHERE n.id NOT IN (SELECT source FROM edges)
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
    _h_quality_hotspots=0
    _h_quality_files=0
    _h_quality_head=""
    _h_quality_scanned=""
    local quality_json
    local _hz_args=()
    if [ -n "$WV_HOT_ZONE" ]; then _hz_args=("--hot-zone" "$WV_HOT_ZONE"); fi
    quality_json=$(_wv_quality_python "${_hz_args[@]}" health-info 2>/dev/null || echo '{"available":false}')
    if echo "$quality_json" | jq -e '.available' >/dev/null 2>&1; then
        _h_quality_available=$(echo "$quality_json" | jq -r '.available')
        if [ "$_h_quality_available" = "true" ]; then
            _h_quality_score=$(echo "$quality_json" | jq -r '.score')
            _h_quality_hotspots=$(echo "$quality_json" | jq -r '.hotspot_count')
            _h_quality_files=$(echo "$quality_json" | jq -r '.total_files')
            _h_quality_head=$(echo "$quality_json" | jq -r '.git_head')
            _h_quality_scanned=$(echo "$quality_json" | jq -r '.scanned_at')
        fi
    fi
}

# One-line cache health summary for wv health output
_health_cache_summary() {
    local proj_slug projects_dir jsonl
    proj_slug=$(pwd | tr '/' '-')
    projects_dir="$HOME/.claude/projects"
    # Pick most recent JSONL for this project
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
            '{available: true, score: $score, hotspot_count: $hotspots, total_files: $files, git_head: $git_head, scanned_at: $scanned_at}')
    else
        quality_obj='{"available":false}'
    fi
    # shellcheck disable=SC1010  # 'done' is a jq arg name, not the bash keyword
    jq -n \
        --arg status "$_h_status_text" \
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
        --argjson orphan_ids "$_h_orphan_ids" \
        --argjson ghost_edges "$_h_ghost_edges" \
        --argjson stale_active "$_h_stale_active" \
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
        --argjson gh_duplicate_issues "$_h_gh_duplicate_issues" \
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
                orphan_ids: $orphan_ids,
                ghost_edges: $ghost_edges,
                stale_active: $stale_active,
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
        echo "  Hotspots: $_h_quality_hotspots files above threshold"
        echo "  Last scan: $_h_quality_scanned (${_h_quality_head:0:7})"
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
        echo "  Ghost edges: $_h_ghost_edges"
        echo "  Stale active (>7d): $_h_stale_active"
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
        if [ "$_h_contradictions" -gt 0 ]; then echo -e "  ${YELLOW}⚠${NC} $_h_contradictions unresolved contradiction(s) - run 'wv edges <id>' to inspect"; fi
        if [ "$_h_ghost_edges" -gt 0 ]; then echo -e "  ${YELLOW}⚠${NC} $_h_ghost_edges ghost edge(s) referencing deleted nodes - run 'wv clean-ghosts'"; fi
        if [ "$_h_orphan_nodes" -gt 5 ]; then echo -e "  ${YELLOW}⚠${NC} $_h_orphan_nodes orphan node(s) with no edges - consider linking or pruning"; fi
        if [ "${_h_gh_duplicates:-0}" -gt 0 ] 2>/dev/null; then echo -e "  ${YELLOW}⚠${NC} $_h_gh_duplicates GH issue(s) mapped to multiple open nodes - run 'wv health --json | jq .issues.gh_duplicate_issues' to inspect, then 'wv delete <id> --dry-run'"; fi
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

    while [ $# -gt 0 ]; do
        case "$1" in
            --json) format="json" ;;
            --verbose|-v) verbose=true ;;
            --history) history_count=10 ;;
            --history=*) history_count="${1#--history=}" ;;
            --fix) fix=true ;;
            --strict) strict=true ;;
        esac
        shift
    done

    # Handle --history: show log and exit
    if [ "$history_count" -gt 0 ] 2>/dev/null; then
        _health_show_history "$history_count" "$format"
        return 0
    fi

    # Collect all metrics, compute score, gather quality info
    _health_collect_metrics
    _health_compute_score
    _health_collect_quality

    # Append to health history log (TSV: timestamp, score, nodes, edges, orphans, ghost_edges)
    local log_file="$WEAVE_DIR/health.log"
    mkdir -p "$WEAVE_DIR"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%S)" \
        "$_h_health_score" "$_h_total_nodes" "$_h_total_edges" \
        "$_h_orphan_nodes" "$_h_ghost_edges" >> "$log_file"

    # Backfill empty edge context if --fix
    if [ "$fix" = "true" ]; then
        _health_fix_edges
    fi

    # Format output
    if [ "$format" = "json" ]; then
        _health_format_json "$strict"
        # JSON callers parse the output — exit 0 unless --strict
        if [ "$_h_invalid_statuses" -gt 0 ] || [ "$_h_contradictions" -gt 0 ]; then
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
    # - Always exit 1 for true errors: invalid statuses, contradictions
    if [ "$_h_invalid_statuses" -gt 0 ] || [ "$_h_contradictions" -gt 0 ]; then
        return 1
    fi
    if [ "$strict" = true ] && [ "$_h_health_score" -lt 100 ]; then
        return 1
    fi
    return 0
}

# ═══════════════════════════════════════════════════════════════════════════
# cmd_cache — Claude Code session cache health
# ═══════════════════════════════════════════════════════════════════════════

cmd_cache() {
    local format="text"
    local sessions_n=3
    local all_projects=false

    while [ $# -gt 0 ]; do
        case "$1" in
            --json)          format="json" ;;
            --sessions=*)    sessions_n="${1#--sessions=}" ;;
            --sessions)      shift; sessions_n="${1:-3}" ;;
            --all)           all_projects=true ;;
            --help|-h)
                cat >&2 <<'EOF'
Usage: wv cache [options]

Check Claude Code prompt-cache health for the current project.

Options:
  --sessions=N   Number of recent sessions to analyse (default: 3)
  --all          Include sessions from all projects, not just current
  --json         JSON output

Ratios:
  >65%  OK      — cache is working
  35-65% LOW    — possible warm-up or light bug impact
  <35%  BAD     — likely affected by a cache bug

Bugs:
  Sentinel (Bug 1): standalone Bun binary; every turn re-creates cache
  Resume (Bug 2):   deferred_tools_delta stripped on session save/resume
EOF
                return 0
                ;;
        esac
        shift
    done

    # Detect Claude Code install type
    local claude_bin claude_type="unknown"
    claude_bin=$(command -v claude 2>/dev/null || echo "")
    if [ -n "$claude_bin" ]; then
        local real_bin
        real_bin=$(readlink -f "$claude_bin" 2>/dev/null || echo "$claude_bin")
        if file "$real_bin" 2>/dev/null | grep -q "ELF"; then
            claude_type="standalone-bun"
        elif file "$real_bin" 2>/dev/null | grep -q "script"; then
            claude_type="npx-script"
        fi
    fi

    # Resolve project session directories
    local projects_dir="$HOME/.claude/projects"
    local session_dirs=()
    if [ "$all_projects" = true ]; then
        while IFS= read -r d; do session_dirs+=("$d"); done < <(
            find "$projects_dir" -maxdepth 1 -mindepth 1 -type d 2>/dev/null
        )
    else
        local proj_slug
        proj_slug=$(pwd | tr '/' '-')
        local proj_dir="$projects_dir/${proj_slug}"
        [ -d "$proj_dir" ] && session_dirs=("$proj_dir")
    fi

    if [ ${#session_dirs[@]} -eq 0 ]; then
        echo "No Claude Code session data found for this project." >&2
        echo "Run 'wv cache --all' to check all projects." >&2
        return 0
    fi

    # Collect JSONL paths (most recent N per dir, sorted by mtime)
    local jsonl_list=""
    for dir in "${session_dirs[@]}"; do
        local found
        found=$(find "$dir" -maxdepth 1 -name "*.jsonl" -printf "%T@ %p\n" 2>/dev/null \
            | sort -rn | head -"$sessions_n" | awk '{print $2}')
        [ -n "$found" ] && jsonl_list="$jsonl_list"$'\n'"$found"
    done
    jsonl_list=$(printf '%s' "$jsonl_list" | grep -v '^$')

    if [ -z "$jsonl_list" ]; then
        echo "No session JSONL files found." >&2
        return 0
    fi

    # Write path list to a temp file so the Python heredoc can use stdin cleanly
    local _cache_tmp
    _cache_tmp=$(mktemp /tmp/wv-cache-XXXXXX.txt)
    echo "$jsonl_list" > "$_cache_tmp"
    # shellcheck disable=SC2064
    trap "rm -f '$_cache_tmp'" RETURN

    python3 - "$format" "$claude_type" "$_cache_tmp" <<'PYEOF'
import sys, json, os

format_out  = sys.argv[1]
claude_type = sys.argv[2]
paths_file  = sys.argv[3]

with open(paths_file) as pf:
    paths_raw = pf.read().strip().split('\n')
paths = [p for p in paths_raw if p and os.path.exists(p)]
paths.sort(key=os.path.getmtime, reverse=True)

def analyse(path):
    total_read = total_create = turns = 0
    has_deferred = False
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                e = json.loads(line)
            except json.JSONDecodeError:
                continue
            usage = e.get("usage")
            if usage is None:
                msg = e.get("message", {})
                if isinstance(msg, dict):
                    usage = msg.get("usage")
            if isinstance(usage, dict):
                total_read  += usage.get("cache_read_input_tokens", 0) or 0
                total_create += usage.get("cache_creation_input_tokens", 0) or 0
                turns += 1
            if "deferred_tools_delta" in str(e.get("content", "")):
                has_deferred = True
    total = total_read + total_create
    ratio = total_read / total if total > 0 else None
    return {
        "session_id": os.path.basename(path).replace(".jsonl", "")[:8],
        "path": path,
        "turns": turns,
        "cache_read": total_read,
        "cache_create": total_create,
        "ratio": ratio,
        "has_deferred_tools_delta": has_deferred,
        "status": (
            "ok"  if ratio is not None and ratio > 0.65 else
            "low" if ratio is not None and ratio > 0.35 else
            "bad" if ratio is not None else
            "no_data"
        ),
    }

results = []
for p in paths:
    try:
        results.append(analyse(p))
    except Exception as e:
        pass

if format_out == "json":
    out = {
        "claude_type": claude_type,
        "sessions": results,
    }
    if results:
        reads  = [r["cache_read"]   for r in results if r["ratio"] is not None]
        writes = [r["cache_create"] for r in results if r["ratio"] is not None]
        total  = sum(reads) + sum(writes)
        out["aggregate_ratio"] = sum(reads) / total if total > 0 else None
    print(json.dumps(out, indent=2))
    sys.exit(0)

# ── text output ──────────────────────────────────────────────────────────
CYAN  = "\033[0;36m"
GREEN = "\033[0;32m"
YELLOW= "\033[1;33m"
RED   = "\033[0;31m"
NC    = "\033[0m"

def status_colour(s):
    if s == "ok":      return f"{GREEN}OK{NC}"
    if s == "low":     return f"{YELLOW}LOW{NC}"
    if s == "bad":     return f"{RED}BAD{NC}"
    return f"{YELLOW}no data{NC}"

def ratio_str(r):
    if r is None:
        return "   n/a"
    return f"{r:5.1%}"

type_label = {
    "standalone-bun": f"{YELLOW}standalone (Bun){NC}",
    "npx-script":     f"{GREEN}npx/script{NC}",
}.get(claude_type, claude_type)

print(f"\nClaude Code install: {type_label}")
if claude_type == "standalone-bun":
    print(f"  {YELLOW}Sentinel bug (Bug 1) risk — consider alias to npx version{NC}")

# Filter to sessions that actually have usage data
data_sessions = [r for r in results if r["ratio"] is not None]
empty_sessions = [r for r in results if r["ratio"] is None]

if not data_sessions:
    print("\nNo cache data found in recent sessions.")
    if empty_sessions:
        print(f"({len(empty_sessions)} session(s) had no usage entries — may be too short to measure)")
    sys.exit(0)

print(f"\n{'Session':<12} {'Turns':>6}  {'Read':>12}  {'Create':>10}  {'Ratio':>7}  Status")
print("─" * 68)
for r in data_sessions:
    deferred = "  [deferred_tools_delta]" if r["has_deferred_tools_delta"] else ""
    print(
        f"{CYAN}{r['session_id']}{NC}  "
        f"{r['turns']:>6}  "
        f"{r['cache_read']:>12,}  "
        f"{r['cache_create']:>10,}  "
        f"{ratio_str(r['ratio'])}  "
        f"{status_colour(r['status'])}"
        f"{deferred}"
    )

# Aggregate
total_read  = sum(r["cache_read"]   for r in data_sessions)
total_write = sum(r["cache_create"] for r in data_sessions)
total       = total_read + total_write
agg_ratio   = total_read / total if total > 0 else None
agg_status  = (
    "ok"  if agg_ratio is not None and agg_ratio > 0.65 else
    "low" if agg_ratio is not None and agg_ratio > 0.35 else
    "bad"
)

print("─" * 68)
print(
    f"{'Aggregate':<12}  "
    f"{'':>6}  "
    f"{total_read:>12,}  "
    f"{total_write:>10,}  "
    f"{ratio_str(agg_ratio)}  "
    f"{status_colour(agg_status)}"
)

if empty_sessions:
    print(f"\n({len(empty_sessions)} short session(s) excluded — no usage data)")

# Advisory
if any(r["has_deferred_tools_delta"] for r in data_sessions):
    print(f"\n{YELLOW}deferred_tools_delta found — monitor for Bug 2 (session resume regression){NC}")

if agg_status in ("low", "bad"):
    print(f"\n{YELLOW}Cache health is degraded. Possible causes:{NC}")
    if claude_type == "standalone-bun":
        print("  - Bug 1 (sentinel): switch to 'npx @anthropic-ai/claude-code'")
    print("  - Bug 2 (resume): check for deferred_tools_delta in sessions")
    print("  - Short/fresh sessions (normal for <5 turns)")
PYEOF
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
            resolves) echo -e "  ${GREEN}$type${NC} - Links a task or fix with its finding handoff" ;;
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
  5. Sync:         wv sync --gh
  6. Commit state:  git add .weave/ && git diff --cached --quiet || git commit -m "chore(weave): sync state [skip ci]"
  7. Push:          git push

Create new work:
  wv add "Description"               # standalone node
  wv add "Description" --gh          # node + GitHub issue (linked)
  wv add "Task" --parent=<epic-id>   # child of an epic

Topics: wv guide --topic=github | learnings | context | mcp
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
        mcp)
            cat <<'EOF'
Weave MCP Server

The MCP (Model Context Protocol) server exposes Weave tools to AI clients.

Install & build:
  cd mcp && npm install && npm run build

Configure in your MCP client (e.g. Claude Desktop, VS Code):
  Command: node /path/to/mcp/dist/index.js
  Env: WV_PROJECT_ROOT=/path/to/your/repo

Key compound tools (prefer over multiple CLI calls):
  weave_overview  — status + health + ready work (session start)
  weave_work      — claim node + return context pack
  weave_ship      — done + sync + push in one step
  weave_quick     — create + close trivial task in one call
  weave_preflight — pre-action checks before starting work
  weave_plan      — import markdown plan as epic + tasks

Other tools (23 total):
  weave_add, weave_done, weave_batch_done, weave_update, weave_list,
  weave_link, weave_tree, weave_context, weave_search, weave_resolve,
  weave_learnings, weave_guide, weave_status, weave_health, weave_sync,
  weave_breadcrumbs, weave_close_session

CLI vs MCP:
  - MCP: fewer round-trips (compound tools), typed JSON responses
  - CLI: full command set, scripting, pipe-friendly, env var config
  - Both use the same SQLite graph — changes are visible to either
EOF
            ;;
        *)
            echo "Unknown topic: $topic" >&2
            echo "Topics: workflow (default), github, learnings, context, mcp" >&2
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
  ship <id>         Done + sync + push in one step [--learning="..."] [--gh]
  batch-done        Close multiple nodes [--learning="..."] [--no-warn]
  bulk-update       Update multiple nodes from JSON on stdin [--dry-run]
  work <id>         Claim node & set WV_ACTIVE for subagent context [--quiet]
  preflight <id>    Pre-action checks as JSON (blockers, contradictions, context load)
  recover           Resume incomplete operations (ship/sync/delete) [--auto] [--json] [--session]
  pending-close     List nodes awaiting human acknowledgement after learning overlap [--json]
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
  enrich-topology   Apply epic/task topology from JSON spec [--dry-run] [--sync-gh]
  context [id]      Generate Context Pack [--json required] (uses WV_ACTIVE if no id)
  search <query>    Full-text search nodes [--limit=N] [--status=] [--json]
  reindex           Rebuild full-text search index
  learnings         Show captured learnings [--category=] [--grep=] [--recent=N]
  breadcrumbs       Session breadcrumbs [save|show|clear] [--message="..."]
  digest            Compact one-liner health summary [--json]
  session-summary   Session activity stats (nodes created/completed, learnings)
  audit-pitfalls    Show all pitfalls with resolution status
  init-repo         Bootstrap repo for Weave [--agent=claude|copilot|all] [--update] [--force]
  doctor            Installation + surface-contract checks (deps, hooks, ghost settings, matchers) [--json]
  selftest          Round-trip smoke test in isolated environment [--json]
  mcp-status        Verify MCP server is built and IDE-configured [--json]
  health            System health check with score and diagnostics [--history[=N]]
  guide             Workflow quick reference [--topic=workflow|github|learnings|context|mcp]
  prune             Archive old done nodes
  clean-ghosts      Delete ghost edges referencing deleted nodes [--dry-run] [legacy compatibility]
  refs <file|text>  Extract cross-references (dry-run, no edges)
  import <file>     Import from beads JSONL or JSON
  quality <sub>     Code quality scanner (scan, hotspots, diff, promote, reset)
  findings <sub>    Historical finding promotion (promote)
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
  wv ship wv-a1b2 --learning="decision: ..."  # done + sync + push
  wv batch-done wv-a1b2 wv-c3d4 --learning="sprint complete"
  wv preflight wv-a1b2                        # check blockers/contradictions
  wv recover --auto                           # resume interrupted operations
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
  wv init-repo                                # bootstrap .claude/ for current repo (claude agent)
  wv init-repo --agent=copilot                # add VS Code Copilot config (.vscode/mcp.json + instructions)
  wv init-repo --agent=all                    # both claude and copilot
  wv init-repo --update                       # refresh managed files (skills, agents, instructions)
  wv init-repo --force                        # overwrite ALL files including user-customized
EOF
}

# ═══════════════════════════════════════════════════════════════════════════
# cmd_init_repo — Bootstrap a repo for Claude Code + Weave (Alt-A architecture)
#
# Creates .claude/settings.json with permissions only (no hooks key).
# Global hooks live in ~/.claude/settings.json — installed by install.sh.
# ═══════════════════════════════════════════════════════════════════════════
cmd_init_repo() {
    # Delegate to the standalone wv-init-repo binary which handles
    # --agent=claude|copilot|all, --update, --force, skills, agents,
    # copilot-instructions, mcp.json, etc.
    local init_repo_bin
    init_repo_bin=$(command -v wv-init-repo 2>/dev/null || echo "$HOME/.local/bin/wv-init-repo")

    if [ -x "$init_repo_bin" ]; then
        "$init_repo_bin" "$@"
    else
        echo -e "${RED}✗${NC} wv-init-repo not found. Run install.sh first." >&2
        return 1
    fi
}
