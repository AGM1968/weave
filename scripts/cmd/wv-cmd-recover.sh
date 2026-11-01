#!/bin/bash
# wv-cmd-recover.sh — resume incomplete operations from the journal or ship_pending
#
# Commands: recover
# Sourced by: wv entry point (autoloaded on first use)
# Dependencies: wv-journal.sh, wv-cmd-gitstate.sh
#
# Moved unchanged from wv-cmd-ops.sh (wv-c153c4). wv init calls cmd_recover --auto when it
# rehydrates after a reboot, and init is how nearly every suite builds its fixture,
# so every suite running it was routed from ops.

# ═══════════════════════════════════════════════════════════════════════════
# cmd_recover — Resume incomplete operations from journal or ship_pending
# ═══════════════════════════════════════════════════════════════════════════

# cmd_recover — the recover operation's one exit for policy evidence. Only a
# ship journal stuck at its close step can raise the fabrication question, and
# _recover_ship records its own verdict there; every other outcome recovered
# no close, which the rule records as its allow so the call can be countable
# (wv-15422b).
cmd_recover() {
    _WV_RECOVER_CLOSE_DECIDED=false
    local rc=0
    _recover_run "$@" || rc=$?
    # Only the recover operation records it: init runs recovery as a side
    # effect of rehydrating, where this rule is not the call's to decide.
    [ "$_WV_RECOVER_CLOSE_DECIDED" = true ] || [ "${_WV_ATTEMPT_OPERATION:-recover}" != "recover" ] ||
        wv_policy_verdict recovery_never_fabricates_closure allow no "" "no close was recovered"
    return "$rc"
}

_recover_run() {
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
            SELECT id
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

    # Source 4: explicit git-state surfacing for dirty/ahead .weave windows.
    # Intentionally disabled in --auto mode so init/work/ship do not perform
    # implicit git probing on read-path-triggered recovery checks.
    local git_pending_json=""
    local git_sync_pending=false
    local git_sync_state="clean"
    local git_sync_action="none"
    local git_sync_reason="clean"
    local git_sync_hint="no action required"
    if [ "$auto_mode" != true ] && [ "$journal_found" = false ] && [ -z "$pending_nodes" ] && [ -z "$pending_close_nodes" ]; then
        git_pending_json=$(_detect_git_pending 2>/dev/null || echo '{}')
        git_sync_pending=$(echo "$git_pending_json" | jq -r '.pending // false' 2>/dev/null || echo "false")
        git_sync_state=$(echo "$git_pending_json" | jq -r '.state // "clean"' 2>/dev/null || echo "clean")
        git_sync_action=$(echo "$git_pending_json" | jq -r '.action // "none"' 2>/dev/null || echo "none")
        git_sync_reason=$(echo "$git_pending_json" | jq -r '.reason // "clean"' 2>/dev/null || echo "clean")
        git_sync_hint=$(echo "$git_pending_json" | jq -r '.hint // "no action required"' 2>/dev/null || echo "no action required")
    fi

    # Nothing to recover
    if [ "$journal_found" = false ] && [ -z "$pending_nodes" ] && [ -z "$pending_close_nodes" ] && [ "$git_sync_pending" != true ]; then
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
                _recover_ship "$args" "$pending_action" "$auto_mode" || return $?
                ;;
            sync)
                _recover_sync "$args" "$pending_action" "$auto_mode" || return $?
                ;;
            delete)
                _recover_delete "$args" "$pending_action" "$auto_mode" || return $?
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
            local pending_json
            pending_json=$(db_query_json "SELECT id, text,
                    COALESCE(json_extract(metadata, '$.ship_pending_mode'), 'legacy') AS mode
                FROM nodes
                WHERE json_extract(metadata, '$.ship_pending') = 1;")
            echo "{\"status\":\"ship_pending\",\"nodes\":$pending_json}"
            return 0
        fi

        echo -e "${YELLOW}⚠ Found node(s) with ship_pending marker (likely interrupted by reboot)${NC}"
        echo "$pending_nodes" | while read -r node_id; do
            [ -z "$node_id" ] && continue
            local node_text pending_mode
            node_text=$(db_query "SELECT text FROM nodes WHERE id='$(sql_escape "$node_id")';")
            pending_mode=$(db_query "SELECT COALESCE(json_extract(metadata, '$.ship_pending_mode'), 'legacy') FROM nodes WHERE id='$(sql_escape "$node_id")';")
            echo "  $node_id: $node_text ($pending_mode)"
        done
        echo ""

        if [ "$auto_mode" = true ]; then
            echo -e "${CYAN}ℹ${NC} Auto-recovering: running sync for pending nodes"
        else
            echo -n "  Resume shipping these nodes? [Y/n] "
            read -r answer
            if [ "$answer" = "n" ] || [ "$answer" = "N" ]; then
                echo "  Skipped. Clear markers with: wv update <id> --metadata='{\"ship_pending\":null}'"
                return 0
            fi
        fi

        # Recovery: sync local graph state (node is already done, just need to persist)
        local invalid_pending
        invalid_pending=$(echo "$pending_nodes" | while read -r node_id; do
            [ -z "$node_id" ] && continue
            local pending_status pending_mode
            pending_status=$(db_query "SELECT status FROM nodes WHERE id='$(sql_escape "$node_id")';" 2>/dev/null)
            pending_mode=$(db_query "SELECT COALESCE(json_extract(metadata, '$.ship_pending_mode'), 'legacy') FROM nodes WHERE id='$(sql_escape "$node_id")';" 2>/dev/null)
            if [ "$pending_status" != "done" ] || { [ "$pending_mode" != "post_close" ] && [ "$pending_mode" != "legacy" ]; }; then
                echo "$node_id($pending_status/$pending_mode)"
            fi
        done)
        if [ -n "$invalid_pending" ]; then
            echo -e "${RED}Error: contradictory or pre-close ship state; markers preserved: $(echo "$invalid_pending" | tr '\n' ' ')${NC}" >&2
            return 1
        fi
        local _recover_prev_skip_sync_commit="${_WV_SKIP_SYNC_COMMIT:-}"
        export _WV_SKIP_SYNC_COMMIT=1
        local fallback_sync_rc=0
        cmd_sync 2>/dev/null || fallback_sync_rc=$?
        if [ -n "$_recover_prev_skip_sync_commit" ]; then
            export _WV_SKIP_SYNC_COMMIT="$_recover_prev_skip_sync_commit"
        else
            unset _WV_SKIP_SYNC_COMMIT
        fi
        if [ "$fallback_sync_rc" -ne 0 ]; then
            echo -e "${RED}Error: recovery sync failed; ship_pending markers preserved${NC}" >&2
            return "$fallback_sync_rc"
        fi

        # Clear each marker durably only after every node is confirmed done.
        local clear_rc=0
        while read -r node_id; do
            [ -z "$node_id" ] && continue
            _ship_clear_pending_durable "$node_id" || clear_rc=$?
            [ "$clear_rc" -eq 0 ] || break
        done <<< "$pending_nodes"
        if [ "$clear_rc" -ne 0 ]; then
            echo -e "${RED}Error: failed to clear ship_pending marker(s); recovery remains pending${NC}" >&2
            return "$clear_rc"
        fi
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

    # === source-4 git-state fallback (explicit surfaces only) ===
    if [ "$git_sync_pending" = true ]; then
        if [ "$json_mode" = true ]; then
            if [ "$git_sync_state" = "recoverable" ]; then
                echo "$git_pending_json" | jq '. + {status:"git_pending"}'
            else
                echo "$git_pending_json" | jq '. + {status:"git_unresolvable"}'
            fi
            return 0
        fi

        echo -e "${YELLOW}⚠ Git-state pending detected${NC}"
        echo "  State: $git_sync_state"
        if [ "$git_sync_action" != "none" ]; then
            echo "  Action: $git_sync_action"
        fi
        echo "  Reason: $git_sync_reason"
        echo "  Hint: $git_sync_hint"
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
    local recover_status recover_mode recover_marker
    recover_status=$(db_query "SELECT status FROM nodes WHERE id='$(sql_escape "$id")';" 2>/dev/null)
    recover_mode=$(db_query "SELECT COALESCE(json_extract(metadata, '$.ship_pending_mode'), 'legacy') FROM nodes WHERE id='$(sql_escape "$id")';" 2>/dev/null)
    recover_marker=$(db_query "SELECT CASE WHEN json_extract(metadata, '$.ship_pending') = 1 THEN 1 ELSE 0 END FROM nodes WHERE id='$(sql_escape "$id")';" 2>/dev/null)

    case "$stuck_action" in
        persist_intent)
            if [ "$recover_marker" != "1" ]; then
                echo "  Recovery: no intent was persisted; safely aborting incomplete ship"
                return 0
            fi
            if [ "$recover_status" != "active" ] && [ "$recover_status" != "todo" ]; then
                echo -e "${RED}Error: contradictory pre-close recovery state ($recover_status/$recover_mode); journal preserved${NC}" >&2
                return 1
            fi
            if [ "$recover_mode" != "pre_close" ]; then
                echo -e "${RED}Error: contradictory pre-close recovery mode ($recover_status/$recover_mode); journal preserved${NC}" >&2
                return 1
            fi
            if [ "$auto" = true ]; then
                echo -e "${YELLOW}Recovery stopped before close; run 'wv recover' to abort safely, then re-run ship.${NC}" >&2
                return 1
            fi
            echo -n "  Abort the incomplete pre-close attempt (node remains open)? [y/N] "
            read -r answer
            if [ "$answer" != "y" ] && [ "$answer" != "Y" ]; then
                return 2
            fi
            _ship_clear_pending_durable "$id" || return $?
            recover_marker=0
            ;;
        done)
            if [ "$recover_status" != "done" ] || [ "$recover_marker" != "1" ] || [ "$recover_mode" != "post_close" ]; then
                _WV_RECOVER_CLOSE_DECIDED=true
                wv_policy_verdict recovery_never_fabricates_closure deny yes "" \
                    "the close was never durably recorded, so recovery would invent it"
                echo -e "${RED}Error: close was not durably completed; refusing to manufacture closure ($recover_status/$recover_mode)${NC}" >&2
                return 1
            fi
            _WV_RECOVER_CLOSE_DECIDED=true
            wv_policy_verdict recovery_never_fabricates_closure allow no "" "the close was durably recorded"
            echo "  Recovery: close completed atomically; re-run sync"
            local _recover_prev_skip_sync_commit="${_WV_SKIP_SYNC_COMMIT:-}"
            local _recover_prev_skip_sync_commit_set="${_WV_SKIP_SYNC_COMMIT+x}"
            export _WV_SKIP_SYNC_COMMIT=1
            local rc=0
            cmd_sync || rc=$?
            if [ "$rc" -ne 0 ]; then
                if [ -n "$_recover_prev_skip_sync_commit_set" ]; then
                    export _WV_SKIP_SYNC_COMMIT="$_recover_prev_skip_sync_commit"
                else
                    unset _WV_SKIP_SYNC_COMMIT
                fi
                return "$rc"
            fi
            if [ -n "$_recover_prev_skip_sync_commit_set" ]; then
                export _WV_SKIP_SYNC_COMMIT="$_recover_prev_skip_sync_commit"
            else
                unset _WV_SKIP_SYNC_COMMIT
            fi
            ;;
        sync)
            if [ "$recover_status" != "done" ] || [ "$recover_marker" != "1" ] || { [ "$recover_mode" != "post_close" ] && [ "$recover_mode" != "legacy" ]; }; then
                echo -e "${RED}Error: contradictory ship sync recovery state ($recover_status/$recover_mode); marker preserved${NC}" >&2
                return 1
            fi
            echo "  Recovery: re-run sync"
            if [ "$auto" != true ]; then
                echo -n "  Proceed? [Y/n] "
                read -r answer
                [ "$answer" = "n" ] || [ "$answer" = "N" ] && return 2
            fi
            local _recover_prev_skip_sync_commit="${_WV_SKIP_SYNC_COMMIT:-}"
            local _recover_prev_skip_sync_commit_set="${_WV_SKIP_SYNC_COMMIT+x}"
            export _WV_SKIP_SYNC_COMMIT=1
            local rc=0
            cmd_sync || rc=$?
            if [ "$rc" -ne 0 ]; then
                if [ -n "$_recover_prev_skip_sync_commit_set" ]; then
                    export _WV_SKIP_SYNC_COMMIT="$_recover_prev_skip_sync_commit"
                else
                    unset _WV_SKIP_SYNC_COMMIT
                fi
                return "$rc"
            fi
            if [ -n "$_recover_prev_skip_sync_commit_set" ]; then
                export _WV_SKIP_SYNC_COMMIT="$_recover_prev_skip_sync_commit"
            else
                unset _WV_SKIP_SYNC_COMMIT
            fi
            ;;
        clear_pending)
            if [ "$recover_status" != "done" ] || { [ "$recover_marker" = "1" ] && [ "$recover_mode" != "post_close" ] && [ "$recover_mode" != "legacy" ]; }; then
                echo -e "${RED}Error: contradictory marker-clear recovery state ($recover_status/$recover_mode); journal preserved${NC}" >&2
                return 1
            fi
            echo "  Recovery: durably clear completed ship marker"
            if [ "$auto" != true ]; then
                echo -n "  Proceed? [Y/n] "
                read -r answer
                [ "$answer" = "n" ] || [ "$answer" = "N" ] && return 2
            fi
            ;;
        git_commit)
            echo "  Recovery: legacy push-complete ship detected; local graph is already synced"
            if [ "$auto" != true ]; then
                echo -n "  Proceed? [Y/n] "
                read -r answer
                [ "$answer" = "n" ] || [ "$answer" = "N" ] && return 2
            fi
            local git_pending_json git_sync_hint
            git_pending_json=$(_detect_git_pending 2>/dev/null || echo '{}')
            git_sync_hint=$(echo "$git_pending_json" | jq -r '.hint // "no action required"' 2>/dev/null || echo "no action required")
            echo "  Hint: $git_sync_hint"
            ;;
        git_push)
            echo "  Recovery: legacy push-complete ship detected; local graph is already synced"
            if [ "$auto" != true ]; then
                echo -n "  Proceed? [Y/n] "
                read -r answer
                [ "$answer" = "n" ] || [ "$answer" = "N" ] && return 2
            fi
            local git_pending_json git_sync_hint
            git_pending_json=$(_detect_git_pending 2>/dev/null || echo '{}')
            git_sync_hint=$(echo "$git_pending_json" | jq -r '.hint // "no action required"' 2>/dev/null || echo "no action required")
            echo "  Hint: $git_sync_hint"
            ;;
        *)
            echo -e "${RED}Error: unsupported ship recovery action '$stuck_action'; journal preserved${NC}" >&2
            return 1
            ;;
    esac

    # Clear ship_pending durably before the recovered journal can complete.
    if [ -n "$id" ] && [ "$recover_marker" = "1" ]; then
        _ship_clear_pending_durable "$id" || return $?
    fi
    echo -e "${GREEN}✓${NC} Recovery complete"
}

_recover_sync() {
    local args="$1"
    local stuck_action="$2"
    local auto="$3"

    case "$stuck_action" in
        dump)
            echo "  Recovery: re-run sync in --mode=repair (resumable from last checkpoint)"
            ;;
        gh_sync)
            echo "  Recovery: re-run GH sync + commit (uses --mode=repair to resume from last checkpoint)"
            ;;
        git_commit)
            echo "  Recovery: re-run git commit"
            ;;
        *)
            echo -e "${RED}Error: unsupported sync recovery action '$stuck_action'; journal preserved${NC}" >&2
            return 1
            ;;
    esac

    if [ "$auto" != true ]; then
        echo -n "  Proceed? [Y/n] "
        read -r answer
        [ "$answer" = "n" ] || [ "$answer" = "N" ] && return 2
    fi

    local gh_flag
    gh_flag=$(echo "$args" | jq -r '.gh // false')
    if [ "$gh_flag" = "true" ]; then
        # Phase D: prefer --mode=repair so an interrupted sync resumes from
        # its checkpoint instead of redoing the entire walk.
        cmd_sync --gh --mode=repair || return $?
    else
        cmd_sync || return $?
    fi
    echo -e "${GREEN}✓${NC} Recovery complete"
}

_recover_delete() {
    local args="$1"
    local stuck_action="$2"
    local auto="$3"
    local gh_issue id
    gh_issue=$(echo "$args" | jq -r '.gh_issue // empty')
    id=$(echo "$args" | jq -r '.id // empty')

    case "$stuck_action" in
        sqlite_delete)
            [ -n "$id" ] || return 1
            if [ "$(db_query "SELECT COUNT(*) FROM nodes WHERE id='$(sql_escape "$id")';" 2>/dev/null)" != "0" ]; then
                echo "  SQLite delete was not completed; re-run wv delete manually."
                return 1
            fi
            echo "  SQLite delete is confirmed complete."
            ;;
        gh_close)
            [ -n "$gh_issue" ] || { echo -e "${RED}Error: missing GitHub issue for delete recovery${NC}" >&2; return 1; }
            echo "  Recovery: close GitHub issue #$gh_issue"
            if [ "$auto" != true ]; then
                echo -n "  Proceed? [Y/n] "
                read -r answer
                [ "$answer" = "n" ] || [ "$answer" = "N" ] && return 2
            fi
            command -v gh >/dev/null 2>&1 || return 1
            local repo
            repo=$(gh repo view --json nameWithOwner -q '.nameWithOwner' 2>/dev/null || echo "")
            [ -n "$repo" ] || return 1
            gh issue close "$gh_issue" --repo "$repo" >/dev/null || return $?
            echo -e "${GREEN}✓${NC} Closed GitHub issue #$gh_issue" >&2
            ;;
        *)
            echo -e "${RED}Error: unsupported delete recovery action '$stuck_action'; journal preserved${NC}" >&2
            return 1
            ;;
    esac
    echo -e "${GREEN}✓${NC} Recovery complete"
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
        jq -n --slurpfile nodes <(printf '%s' "$json_nodes") --argjson count "$active_count" \
            '{status: "orphaned", orphaned_nodes: $nodes[0], count: $count}'
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
