#!/bin/bash
# wv-cmd-core.sh — Core workflow commands
#
# Commands: init, add, done, ready, list, show, status, update
# Sourced by: wv entry point (after lib modules)
# Dependencies: wv-config.sh, wv-db.sh, wv-validate.sh, wv-cache.sh

# ═══════════════════════════════════════════════════════════════════════════
# cmd_init — Initialize Weave directory
# ═══════════════════════════════════════════════════════════════════════════

cmd_init() {
    local force=false
    while [ $# -gt 0 ]; do
        case "$1" in
            --force) force=true ;;
        esac
        shift
    done

    # Force reset: wipe everything and start fresh
    if [ "$force" = true ]; then
        local count=0
        if [ -f "$WV_DB" ]; then
            count=$(sqlite3 -cmd ".timeout 5000" "$WV_DB" "SELECT COUNT(*) FROM nodes;" 2>/dev/null || echo "0")
        fi
        if [ "$count" -gt 0 ]; then
            echo -e "${YELLOW}Destroying existing graph ($count nodes)...${NC}" >&2
        fi
        # Remove hot zone DB
        rm -f "$WV_DB" 2>/dev/null || true
        # Remove .weave/ state files (preserve archive/)
        rm -f "$WEAVE_DIR/state.sql" 2>/dev/null || true
        rm -f "$WEAVE_DIR/nodes.jsonl" 2>/dev/null || true
        rm -f "$WEAVE_DIR/edges.jsonl" 2>/dev/null || true
        rm -f "$WEAVE_DIR/health.log" 2>/dev/null || true
        rm -rf "$WEAVE_DIR/cache" 2>/dev/null || true
        db_init
        wv_delta_init "$WV_DB"
        echo -e "${GREEN}✓ Initialized Weave at $WEAVE_DIR (clean slate)${NC}"
        echo "  Hot zone: $WV_HOT_ZONE"
        return
    fi

    # Reboot recovery: hot zone DB is gone but state.sql exists on disk
    if [ ! -f "$WV_DB" ] && [ -f "$WEAVE_DIR/state.sql" ]; then
        echo -e "${YELLOW}Hot zone database missing (likely reboot) — recovering from state.sql${NC}" >&2
        cmd_load
        local count
        count=$(sqlite3 -cmd ".timeout 5000" "$WV_DB" "SELECT COUNT(*) FROM nodes;" 2>/dev/null || echo "0")
        echo -e "${GREEN}✓ Recovered $count nodes at $WEAVE_DIR${NC}"
        echo "  Hot zone: $WV_HOT_ZONE"
        # Check for interrupted operations after reboot (ship_pending fallback)
        cmd_recover --auto 2>/dev/null || true
        return
    fi

    # Guard against reinitializing over existing data
    if [ -f "$WV_DB" ]; then
        local count
        count=$(sqlite3 -cmd ".timeout 5000" "$WV_DB" "SELECT COUNT(*) FROM nodes;" 2>/dev/null || echo "0")
        if [ "$count" -gt 0 ]; then
            echo -e "${RED}Error: Database already exists with $count nodes.${NC}" >&2
            echo "Use 'wv init --force' to reinitialize (destroys existing data)." >&2
            echo "Use 'wv load' to reload from .weave/state.sql." >&2
            return 1
        fi
    fi

    db_init
    wv_delta_init "$WV_DB"
    echo -e "${GREEN}✓ Initialized Weave at $WEAVE_DIR${NC}"
    echo "  Hot zone: $WV_HOT_ZONE"
}

# ═══════════════════════════════════════════════════════════════════════════
# _do_unblock_cascade — Unblock nodes whose blockers are all done
# Shared by cmd_done, cmd_add, cmd_update, cmd_quick, and wv plan.
# Args: $1 = node ID that was just set to done (optional — if empty, sweeps all)
# ═══════════════════════════════════════════════════════════════════════════

_do_unblock_cascade() {
    local id="${1:-}"
    if [ -n "$id" ]; then
        # Targeted: unblock nodes blocked only by this specific node
        db_query "
            UPDATE nodes SET status='todo', updated_at=CURRENT_TIMESTAMP
            WHERE status='blocked'
            AND id IN (
                SELECT target FROM edges WHERE source='$(sql_escape "$id")' AND type='blocks'
            )
            AND NOT EXISTS (
                SELECT 1 FROM edges e
                JOIN nodes blocker ON e.source = blocker.id
                WHERE e.target = nodes.id
                AND e.type = 'blocks'
                AND blocker.status != 'done'
            );
        "
    else
        # Sweep: unblock ALL blocked nodes whose blockers are all done
        # Used after bulk imports (wv plan) where multiple done nodes were created at once
        db_query "
            UPDATE nodes SET status='todo', updated_at=CURRENT_TIMESTAMP
            WHERE status='blocked'
            AND NOT EXISTS (
                SELECT 1 FROM edges e
                JOIN nodes blocker ON e.source = blocker.id
                WHERE e.target = nodes.id
                AND e.type = 'blocks'
                AND blocker.status != 'done'
            );
        "
    fi
}

# ═══════════════════════════════════════════════════════════════════════════
# cmd_add helpers
# ═══════════════════════════════════════════════════════════════════════════

# _add_dedup_check — Warn if similar non-done nodes exist. Returns 1 if dupe found.
_add_dedup_check() {
    local text="$1"
    db_ensure
    db_migrate_fts5 2>/dev/null || true
    # Extract significant words (>4 chars) for token-based matching
    local search_tokens
    search_tokens=$(echo "$text" | tr -cs '[:alnum:]' ' ' | \
        awk '{for(i=1;i<=NF;i++) if(length($i)>4) {printf "%s ", $i; c++; if(c>=5) exit}}')
    search_tokens=$(echo "$search_tokens" | sed 's/[(){}*:^~"]//g' | xargs)
    local similar=""
    if [ -n "$search_tokens" ]; then
        local token_count
        token_count=$(echo "$search_tokens" | wc -w)
        if [ "$token_count" -ge 2 ]; then
            local fts_query
            fts_query=$(echo "$search_tokens" | sed 's/ / AND /g')
            similar=$(db_query "
                SELECT n.id, n.text, n.status
                FROM nodes_fts f
                JOIN nodes n ON f.rowid = n.rowid
                WHERE nodes_fts MATCH '$fts_query'
                AND n.status != 'done'
                LIMIT 3;
            " 2>/dev/null || echo "")
        fi
    fi
    if [ -n "$similar" ]; then
        echo -e "${YELLOW}⚠ Similar active nodes exist:${NC}" >&2
        echo "$similar" | while IFS='|' read -r sid stext sstatus; do
            echo -e "  ${CYAN}$sid${NC} [$sstatus]: $stext" >&2
        done
        echo -e "${YELLOW}  Use --force to create anyway${NC}" >&2
        return 1
    fi
    return 0
}

# _add_create_gh_issue — Create a GitHub issue linked to a Weave node
_add_create_gh_issue() {
    local id="$1" text="$2" metadata="$3" alias="$4"
    local repo
    repo=$(gh repo view --json nameWithOwner -q '.nameWithOwner' 2>/dev/null || echo "")
    if [ -z "$repo" ]; then
        return 0
    fi
    local priority type_label priority_label
    priority=$(echo "$metadata" | jq -r '.priority // 2' 2>/dev/null || echo "2")
    case "$(echo "$metadata" | jq -r '.type // "task"' 2>/dev/null)" in
        bug) type_label="bug" ;; feature) type_label="enhancement" ;; *) type_label="task" ;;
    esac
    case "$priority" in
        0|1) priority_label="P1" ;; 3) priority_label="P3" ;; 4) priority_label="P4" ;; *) priority_label="P2" ;;
    esac
    local alias_part=""
    if [ -n "$alias" ]; then
        alias_part=" | **Alias:** \`$alias\`"
    fi
    local gh_body="**Weave ID**: \`$id\`${alias_part}

---
*Synced from Weave*"
    gh label create "$type_label" --repo "$repo" --color "1d76db" --description "Weave task type" 2>/dev/null || true
    gh label create "$priority_label" --repo "$repo" --color "e4e669" --description "Weave priority" 2>/dev/null || true
    gh label create "weave-synced" --repo "$repo" --color "bfdadc" --description "Synced from/to Weave" 2>/dev/null || true
    local gh_url
    # GitHub titles max 256 chars — truncate with ellipsis
    local gh_title="$text"
    if [ "${#gh_title}" -gt 256 ]; then
        gh_title="${gh_title:0:253}..."
    fi
    gh_url=$(gh issue create --repo "$repo" \
        --title "$gh_title" --body "$gh_body" \
        --label "$type_label" --label "$priority_label" --label "weave-synced" 2>&1) || true
    if [[ "$gh_url" == http* ]]; then
        local gh_num
        gh_num=$(echo "$gh_url" | grep -oE '[0-9]+$')
        local updated_meta
        updated_meta=$(echo "$metadata" | jq --arg gh "$gh_num" '. + {gh_issue: ($gh | tonumber)}' 2>/dev/null || echo "$metadata")
        updated_meta="${updated_meta//\'/\'\'}"
        db_query "UPDATE nodes SET metadata='$updated_meta' WHERE id='$id';"
        echo -e "${GREEN}✓${NC} GitHub issue #$gh_num created" >&2
    else
        echo -e "${YELLOW}Warning: GitHub issue creation failed${NC}" >&2
    fi
}

# ═══════════════════════════════════════════════════════════════════════════
# cmd_add — Add a new node
# ═══════════════════════════════════════════════════════════════════════════

cmd_add() {
    local text="$1"
    local status="todo"
    local metadata="{}"
    local create_gh=false
    local alias=""
    local force=false
    local parent=""
    local format="text"

    shift || true
    while [ $# -gt 0 ]; do
        case "$1" in
            --status=*) status="${1#*=}" ;;
            --metadata=*) metadata="${1#*=}" ;;
            --alias=*) alias="${1#*=}" ;;
            --parent=*) parent="${1#*=}" ;;
            --gh) create_gh=true ;;
            --force) force=true ;;
            --json) format="json" ;;
            --*) ;; # skip unrecognized flags
            *) text="$text $1" ;;
        esac
        shift
    done

    if [ -z "$text" ]; then
        echo -e "${RED}Error: text required${NC}" >&2
        echo "Usage: wv add \"task description\" [--status=todo|active|done|blocked] [--parent=<id>] [--gh] [--force]" >&2
        return 1
    fi

    # Validate parent if provided
    if [ -n "$parent" ]; then
        validate_id "$parent" || return 1
        db_ensure
        local parent_exists
        parent_exists=$(db_query "SELECT COUNT(*) FROM nodes WHERE id='$(sql_escape "$parent")';" 2>/dev/null)
        if [ "$parent_exists" = "0" ]; then
            echo -e "${RED}Error: parent node $parent not found${NC}" >&2
            return 1
        fi
    fi

    # Validate metadata JSON before storing
    if ! echo "$metadata" | jq '.' >/dev/null 2>&1; then
        echo -e "${RED}Error: invalid JSON in --metadata${NC}" >&2
        return 1
    fi

    # Dedup check: warn if similar non-done nodes exist (skip with --force or --parent)
    # Child nodes naturally share vocabulary with their parent — skip for decomposition.
    if [ "$force" != "true" ] && [ -z "$parent" ]; then
        if ! _add_dedup_check "$text"; then
            return 1
        fi
    fi

    local id=$(generate_id)
    local original_text="$text"

    # Escape single quotes in text and metadata
    text="${text//\'/\'\'}"
    metadata="${metadata//\'/\'\'}"

    local alias_sql="NULL"
    if [ -n "$alias" ]; then
        alias_sql="'$(sql_escape "$alias")'"
    fi
    db_query "INSERT INTO nodes (id, text, status, metadata, alias) VALUES ('$id', '$text', '$status', '$metadata', $alias_sql);"

    if [ -n "$alias" ]; then
        echo -e "${GREEN}✓${NC} $id ($alias): $text" >&2
    else
        echo -e "${GREEN}✓${NC} $id: $text" >&2
    fi

    # Link to parent if --parent provided
    if [ -n "$parent" ]; then
        cmd_link "$id" "$parent" --type=implements 2>/dev/null
        echo -e "${GREEN}✓${NC} Linked to parent $parent" >&2
    fi

    # Orphan prevention: require --parent when active epics exist (skip with --force)
    if [ -z "$parent" ] && [ "$force" != "true" ]; then
        local node_type
        node_type=$(echo "$metadata" | jq -r '.type // "task"' 2>/dev/null || echo "task")
        if [ "$node_type" != "epic" ]; then
            local active_epics
            active_epics=$(db_query "
                SELECT id FROM nodes
                WHERE status IN ('todo','active')
                AND json_extract(metadata,'\$.type') = 'epic'
                ORDER BY created_at DESC LIMIT 3;
            " 2>/dev/null || true)
            if [ -n "$active_epics" ]; then
                local epic_list
                epic_list=$(echo "$active_epics" | tr '\n' ' ' | sed 's/ $//')
                echo -e "${RED}Error: --parent required when active epics exist (use --force to override)${NC}" >&2
                echo -e "${CYAN}  Active epic(s): $epic_list${NC}" >&2
                echo -e "${CYAN}  Usage: wv add \"...\" --parent=<epic-id>${NC}" >&2
                # Remove the orphan node we just created
                db_query "DELETE FROM nodes WHERE id='$id';" 2>/dev/null || true
                return 1
            fi
            # No active epics — just warn about missing alias
            if [ -z "$alias" ]; then
                echo -e "${YELLOW}⚠ No alias — use --alias=<name>${NC}" >&2
            fi
        fi
    fi

    # Auto-unblock cascade when created with --status=done
    if [ "$status" = "done" ]; then
        _do_unblock_cascade "$id"
    fi

    # Create matching GitHub issue if --gh flag is set
    if [ "$create_gh" = true ] && command -v gh >/dev/null 2>&1; then
        _add_create_gh_issue "$id" "$text" "$metadata" "$alias"
    fi

    if [ "$format" = "json" ]; then
        jq -n --arg id "$id" --arg text "$original_text" --arg status "$status" \
            '{"id": $id, "text": $text, "status": $status}'
    else
        echo "$id"
    fi

    auto_sync 2>/dev/null || true
}

# ═══════════════════════════════════════════════════════════════════════════
# _store_node_commits — Find commits referencing $id and store in metadata
# _aggregate_epic_commits — Collect child commits onto an epic node
# ═══════════════════════════════════════════════════════════════════════════

_store_node_commits() {
    local id="$1"
    local shas shas_json
    shas=$(git log --format="%h" --grep="$id" --since="90 days ago" 2>/dev/null | head -10 | tr '\n' ' ' | sed 's/ $//')
    [ -z "$shas" ] && return 0
    shas_json=$(echo "$shas" | tr ' ' '\n' | jq -R . | jq -s . 2>/dev/null || echo "[]")
    [ "$shas_json" = "[]" ] && return 0
    local cur_meta_raw cur_meta updated
    cur_meta_raw=$(db_query_json "SELECT metadata FROM nodes WHERE id='$(sql_escape "$id")';" 2>/dev/null || echo "[]")
    cur_meta=$(echo "$cur_meta_raw" | jq -r '.[0].metadata // "{}"' 2>/dev/null || echo "{}")
    [[ "$cur_meta" != "{"* ]] && cur_meta="{}"
    updated=$(echo "$cur_meta" | jq --argjson s "$shas_json" '. + {commits: $s}' 2>/dev/null || echo "$cur_meta")
    updated="${updated//\'/\'\'}"
    db_query "UPDATE nodes SET metadata='$updated' WHERE id='$(sql_escape "$id")';"
}

_aggregate_epic_commits() {
    local epic_id="$1"
    local child_metas all_shas
    child_metas=$(db_query_json "
        SELECT metadata FROM nodes
        WHERE id IN (SELECT source FROM edges WHERE target='$(sql_escape "$epic_id")' AND type='implements');
    " 2>/dev/null || echo "[]")
    all_shas=$(echo "$child_metas" | jq '[
        .[] | .metadata |
        if . and . != "" then (. | fromjson | .commits // []) else [] end | .[]
    ] | unique | sort' 2>/dev/null || echo "[]")
    [ "$all_shas" = "[]" ] && return 0
    local epic_meta_raw epic_meta updated
    epic_meta_raw=$(db_query_json "SELECT metadata FROM nodes WHERE id='$(sql_escape "$epic_id")';" 2>/dev/null || echo "[]")
    epic_meta=$(echo "$epic_meta_raw" | jq -r '.[0].metadata // "{}"' 2>/dev/null || echo "{}")
    [[ "$epic_meta" != "{"* ]] && epic_meta="{}"
    updated=$(echo "$epic_meta" | jq --argjson s "$all_shas" '. + {commits: $s}' 2>/dev/null || echo "$epic_meta")
    updated="${updated//\'/\'\'}"
    db_query "UPDATE nodes SET metadata='$updated' WHERE id='$(sql_escape "$epic_id")';"
}

# ═══════════════════════════════════════════════════════════════════════════
# cmd_done — Mark node as done (decomposed into helpers)
# ═══════════════════════════════════════════════════════════════════════════

# Shared state for cmd_done helpers (avoids stdout capture in subshells)
_done_skip_learning=false

# Store learning in node metadata with FTS5 dedup check and format suggestion.
# Sets _done_skip_learning=true if user chose to skip/dedup (interactive only).
# Non-interactive: records learning_overlap_noted in metadata as advisory; does NOT block.
# Args: $1=id, $2=learning text (already ANSI-stripped), $3=acknowledge overlap (0/1)
_done_read_metadata() {
    local id="$1"
    local cur_meta cur_meta_raw
    cur_meta_raw=$(db_query_json "SELECT metadata FROM nodes WHERE id='$id';" 2>/dev/null || echo "[]")
    cur_meta=$(echo "$cur_meta_raw" | jq -r '.[0].metadata // "{}"' 2>/dev/null || echo "{}")
    if [[ "$cur_meta" != "{"* ]]; then
        cur_meta=$(echo "$cur_meta" | jq -r '.' 2>/dev/null || echo "{}")
    fi
    echo "$cur_meta"
}

_done_can_prompt_overlap() {
    [ "${WV_NONINTERACTIVE:-0}" != "1" ] && [ -z "${CI:-}" ] && [ -t 0 ] && [ -t 2 ]
}

# Reserved for future genuinely-blocking close conditions (not learning overlap).
# Currently only called by --acknowledge-overlap recovery path in cmd_done.
_done_mark_pending_close() {
    local id="$1" learning="$2" overlap_id="$3"
    local cur_meta new_meta created_at resume_cmd
    cur_meta=$(_done_read_metadata "$id")
    created_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    resume_cmd="wv done $id --acknowledge-overlap"
    new_meta=$(echo "$cur_meta" | jq \
        --arg learning "$learning" \
        --arg overlap_id "$overlap_id" \
        --arg created_at "$created_at" \
        --arg resume_cmd "$resume_cmd" \
        '. + {
            needs_human_verification: true,
            pending_close: {
                reason: "learning_overlap",
                overlap_with: $overlap_id,
                learning: $learning,
                created_at: $created_at,
                resume_command: $resume_cmd
            }
        }' 2>/dev/null || echo "$cur_meta")
    new_meta="${new_meta//\'/\'\'}"
    db_query "UPDATE nodes SET metadata='$new_meta', updated_at=CURRENT_TIMESTAMP WHERE id='$id';"
}

_done_store_learning() {
    local id="$1" learning="$2" acknowledge_overlap="${3:-0}"
    _done_skip_learning=false
    _done_pending_close=false

    # FTS5 dedup check: prompt if a similar learning already exists
    local search_terms
    search_terms=$(echo "$learning" | tr -cs '[:alnum:]' ' ' | \
        awk '{for(i=1;i<=NF;i++) if(length($i)>4) {print $i; c++; if(c>=3) exit}}')
    if [ -n "$search_terms" ]; then
        # Sanitize FTS5 operators to prevent query syntax injection
        search_terms=$(echo "$search_terms" | sed 's/[(){}*:^~"]//g' | tr '\n' ' ')
        local fts_match
        fts_match=$(db_query "
            SELECT id FROM nodes_fts
            WHERE nodes_fts MATCH '${search_terms}'
            AND id != '$id'
            LIMIT 1;
        " 2>/dev/null || true)
        if [ -n "$fts_match" ]; then
            echo -e "${YELLOW}⚠ Learning may overlap with $fts_match${NC}" >&2
            if [ "$acknowledge_overlap" = "1" ]; then
                echo -e "  → Acknowledged via --acknowledge-overlap, proceeding." >&2
            elif _done_can_prompt_overlap; then
                # Interactive terminal: show overlapping learning and prompt for action
                local overlap_learning
                overlap_learning=$(db_query_json "SELECT metadata FROM nodes WHERE id='$fts_match';" 2>/dev/null \
                    | jq -r '.[0].metadata | if . and . != "" then (. | fromjson | .learning // "(no learning)") else "(no learning)" end' 2>/dev/null || echo "(no learning)")
                echo -e "${CYAN}  Overlapping (${fts_match}):${NC} ${overlap_learning}" >&2
                echo -e "${YELLOW}  [d]edup  [a]cknowledge  [s]kip learning${NC}" >&2
                printf "  > " >&2
                local overlap_action
                read -r overlap_action </dev/tty
                case "$overlap_action" in
                    d|D|dedup)
                        echo -e "  → Dedup: revise your --learning to reduce overlap, then re-run wv done." >&2
                        _done_skip_learning=true
                        ;;
                    s|S|skip)
                        echo -e "  → Learning skipped." >&2
                        _done_skip_learning=true
                        ;;
                    *)
                        echo -e "  → Acknowledged, proceeding with intentional overlap." >&2
                        ;;
                esac
            else
                # Non-interactive: record overlap as advisory audit trail and proceed.
                # Overlap is a quality heuristic, not a data integrity constraint —
                # blocking automated callers (agents, CI, sync) causes stuck nodes.
                # Note: _done_read_metadata is called again below to store the learning
                # key; it does a fresh SELECT so learning_overlap_noted is preserved.
                local cur_meta new_meta
                cur_meta=$(_done_read_metadata "$id")
                new_meta=$(echo "$cur_meta" | jq \
                    --arg overlap_id "$fts_match" \
                    '. + {learning_overlap_noted: $overlap_id}' 2>/dev/null || echo "$cur_meta")
                new_meta="${new_meta//\'/\'\'}"
                db_query "UPDATE nodes SET metadata='$new_meta', updated_at=CURRENT_TIMESTAMP WHERE id='$id';"
                echo -e "${YELLOW}  → Overlap noted in metadata (learning_overlap_noted: $fts_match), proceeding.${NC}" >&2
            fi
        fi
    fi

    if [ "$_done_skip_learning" = true ] || [ "$_done_pending_close" = true ]; then
        return 0
    fi

    # Merge learning into node metadata
    local cur_meta
    cur_meta=$(_done_read_metadata "$id")
    local new_meta
    new_meta=$(echo "$cur_meta" | jq --arg l "$learning" '. + {learning: $l}' 2>/dev/null || echo "$cur_meta")
    new_meta="${new_meta//\'/\'\'}"
    db_query "UPDATE nodes SET metadata='$new_meta', updated_at=CURRENT_TIMESTAMP WHERE id='$id';"
    score_learning "$id" 2>/dev/null || true

    # Soft format suggestion: nudge toward structured learning format
    local has_structured=false
    if [[ "$learning" == *"decision:"* ]] || [[ "$learning" == *"pattern:"* ]] || [[ "$learning" == *"pitfall:"* ]]; then
        has_structured=true
    fi
    if [ "$has_structured" = false ]; then
        echo -e "${YELLOW}Tip: structured learnings are more useful for future sessions${NC}" >&2
        echo -e "${YELLOW}  Format: --learning=\"decision: ... | pattern: ... | pitfall: ...\"${NC}" >&2
    fi
}

# Close linked GitHub issue with learnings + commit comment.
# Args: $1=id
_done_close_gh_issue() {
    local id="$1"

    if ! command -v gh >/dev/null 2>&1; then
        return 0
    fi

    # Read metadata for GH issue number
    # Note: pipefail is set globally — use intermediate variables to avoid
    # SIGPIPE (141) when jq closes stdin before sqlite3/gh finish writing.
    local meta meta_raw
    meta_raw=$(db_query_json "SELECT metadata FROM nodes WHERE id='$id';" 2>/dev/null || echo "[]")
    meta=$(echo "$meta_raw" | jq -r '.[0].metadata // "{}"' 2>/dev/null || echo "{}")
    if [[ "$meta" != "{"* ]]; then
        meta=$(echo "$meta" | jq -r '.' 2>/dev/null || echo "{}")
    fi
    local gh_num
    gh_num=$(echo "$meta" | jq -r '.gh_issue // empty' 2>/dev/null)
    if [ -z "$gh_num" ] || [ "$gh_num" = "null" ]; then
        return 0
    fi

    local repo
    repo=$(gh repo view --json nameWithOwner -q '.nameWithOwner' 2>/dev/null || echo "")
    if [ -z "$repo" ]; then
        return 0
    fi

    # Build close comment with learnings from metadata
    local comment="Completed. Weave node \`$id\` closed."
    local l_decision l_pattern l_pitfall l_learning
    l_decision=$(echo "$meta" | jq -r '.decision // empty' 2>/dev/null)
    l_pattern=$(echo "$meta" | jq -r '.pattern // empty' 2>/dev/null)
    l_pitfall=$(echo "$meta" | jq -r '.pitfall // empty' 2>/dev/null)
    l_learning=$(echo "$meta" | jq -r '.learning // empty' 2>/dev/null)

    if [ -n "$l_decision" ] || [ -n "$l_pattern" ] || [ -n "$l_pitfall" ] || [ -n "$l_learning" ]; then
        comment="$comment

**Learnings:**"
        if [ -n "$l_decision" ]; then comment="$comment
- **Decision:** $l_decision"; fi
        if [ -n "$l_pattern" ]; then comment="$comment
- **Pattern:** $l_pattern"; fi
        if [ -n "$l_pitfall" ]; then comment="$comment
- **Pitfall:** $l_pitfall"; fi
        if [ -n "$l_learning" ]; then comment="$comment
- **Notes:** $l_learning"; fi
    fi

    # Find related commits via Weave-ID trailer
    local shas
    shas=$(git log --format="%H" --grep="Weave-ID: $id" --since="90 days ago" 2>/dev/null | head -10)
    if [ -z "$shas" ]; then
        shas=$(git log --format="%H" --grep="$id" --since="90 days ago" 2>/dev/null | head -10)
    fi
    if [ -n "$shas" ]; then
        local repo_url
        repo_url=$(gh repo view --json url -q '.url' 2>/dev/null || echo "")
        comment="$comment

**Commits:**"
        for sha in $shas; do
            local short_sha subj
            short_sha=$(echo "$sha" | cut -c1-7)
            subj=$(git log --format="%s" -1 "$sha" 2>/dev/null)
            if [ -n "$repo_url" ]; then
                comment="$comment
- [\`$short_sha\`]($repo_url/commit/$sha) $subj"
            else
                comment="$comment
- \`$short_sha\` $subj"
            fi
        done
    fi

    # Remove stale status labels before closing
    gh issue edit "$gh_num" --repo "$repo" --remove-label "weave:active" >/dev/null 2>&1 || true
    gh issue edit "$gh_num" --repo "$repo" --remove-label "weave:blocked" >/dev/null 2>&1 || true

    if gh issue close "$gh_num" --repo "$repo" --comment "$comment" >/dev/null 2>&1; then
        echo -e "${GREEN}✓${NC} Closed GitHub issue #$gh_num" >&2
    else
        echo -e "${YELLOW}Warning: could not close GitHub issue #$gh_num${NC}" >&2
    fi

    # Refresh parent epic body (checkboxes + Mermaid) after child close
    _refresh_parent_gh "$id"
}

# Append completion record to breadcrumbs.md.
# Args: $1=id
_done_write_breadcrumb() {
    local id="$1"

    if [ -z "${WEAVE_DIR:-}" ]; then
        return 0
    fi

    local breadcrumb_file="$WEAVE_DIR/breadcrumbs.md"
    local node_alias
    node_alias=$(db_query "SELECT COALESCE(alias, '') FROM nodes WHERE id='$id';" 2>/dev/null || true)
    local label="$id"
    if [ -n "$node_alias" ]; then
        label="$id ($node_alias)"
    fi
    local unblocked
    unblocked=$(db_query "SELECT id FROM nodes WHERE status='todo' AND id IN (SELECT target FROM edges WHERE source='$id' AND type='blocks');" 2>/dev/null | tr '\n' ', ' | sed 's/,$//')
    local next_ready
    next_ready=$(cmd_ready --json 2>/dev/null | jq -r '.[0].id // empty' 2>/dev/null || true)
    {
        echo ""
        echo "## $(date '+%Y-%m-%d %H:%M') — Completed $label"
        if [ -n "$unblocked" ]; then echo "- Unblocked: $unblocked"; fi
        if [ -n "$next_ready" ]; then echo "- Next ready: $next_ready"; fi
    } >> "$breadcrumb_file" 2>/dev/null || true
}

cmd_done() {
    local id="${1:-}"
    local reason=""
    local learning=""
    local no_warn=0
    local skip_verification=0
    local acknowledge_overlap=0
    local format="text"

    shift || true
    while [ $# -gt 0 ]; do
        case "$1" in
            --reason=*) reason="${1#*=}" ;;
            --learning=*) learning="${1#*=}" ;;
            --no-warn) no_warn=1 ;;
            --skip-verification) skip_verification=1 ;;
            --acknowledge-overlap) acknowledge_overlap=1 ;;
            --json) format="json" ;;
        esac
        shift
    done

    if [ -z "$id" ]; then
        echo -e "${RED}Error: node ID required${NC}" >&2
        return 1
    fi

    # Validate ID format (SQL injection prevention)
    validate_id "$id" || return 1

    # Verify node exists
    local exists
    exists=$(db_query "SELECT COUNT(*) FROM nodes WHERE id='$id';")
    if [ "$exists" = "0" ]; then
        echo -e "${RED}Error: node $id not found${NC}" >&2
        return 1
    fi

    local node_meta pending_reason pending_resume_cmd
    node_meta=$(_done_read_metadata "$id")
    pending_reason=$(echo "$node_meta" | jq -r '.pending_close.reason // empty' 2>/dev/null || echo "")
    pending_resume_cmd=$(echo "$node_meta" | jq -r '.pending_close.resume_command // empty' 2>/dev/null || echo "")
    if [ -n "$pending_reason" ] && [ "$acknowledge_overlap" = "0" ]; then
        echo -e "${YELLOW}⚠ Node $id is waiting for human verification before close${NC}" >&2
        if [ -n "$pending_resume_cmd" ]; then
            echo -e "${YELLOW}  Resume with: $pending_resume_cmd${NC}" >&2
        fi
        return 2
    fi
    if [ "$acknowledge_overlap" = "1" ] && [ -z "$learning" ]; then
        learning=$(echo "$node_meta" | jq -r '.pending_close.learning // empty' 2>/dev/null || echo "")
    fi

    # Require --learning or --skip-verification for closure quality
    # Bypass: WV_REQUIRE_LEARNING=0 (for tests), --no-warn (for recovery/internal)
    if [ "${WV_REQUIRE_LEARNING:-1}" = "1" ] && [ -z "$learning" ] && [ "$skip_verification" = "0" ] && [ "$no_warn" = "0" ]; then
        echo -e "${RED}Error: --learning=\"...\" or --skip-verification required${NC}" >&2
        echo -e "  Capture what future sessions would get wrong without this:" >&2
        echo -e "  wv done $id --learning=\"decision: ... | pattern: ... | pitfall: ...\"" >&2
        echo -e "  wv done $id --skip-verification  # for trivial work" >&2
        return 1
    fi

    # Warn if closing an epic with no tracked children (implements edges)
    local node_type
    node_type=$(db_query "SELECT json_extract(metadata,'$.type') FROM nodes WHERE id='$id';" 2>/dev/null || true)
    if [ "$node_type" = "epic" ]; then
        local child_count
        child_count=$(db_query "SELECT COUNT(*) FROM edges WHERE target='$id' AND type='implements';" 2>/dev/null || echo "0")
        if [ "$child_count" = "0" ]; then
            echo -e "${YELLOW}⚠ Epic closed with no tracked children — sub-tasks were never linked via --parent or wv link${NC}" >&2
            echo -e "${YELLOW}  Future sessions cannot use wv context or wv path to navigate this epic's work${NC}" >&2
        fi
    fi

    # Store learning in metadata if provided
    if [ -n "$learning" ]; then
        # Strip ANSI escape codes (color sequences leak from terminal output)
        learning=$(printf '%s' "$learning" | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g')
        _done_store_learning "$id" "$learning" "$acknowledge_overlap"
        if [ "$_done_pending_close" = true ]; then
            return 2
        fi
    fi

    # === Close: update status, release claim, clear primary, aggregate commits ===
    db_query "UPDATE nodes
        SET status='done',
            metadata = json_remove(COALESCE(metadata,'{}'), '$.claimed_by', '$.pending_close', '$.needs_human_verification'),
            updated_at = CURRENT_TIMESTAMP
        WHERE id='$id';"

    local primary
    primary=$(get_primary_node 2>/dev/null || echo "")
    if [ "$primary" = "$id" ]; then
        clear_primary_node
    fi

    _store_node_commits "$id" 2>/dev/null || true
    local parent_epic
    parent_epic=$(db_query "SELECT target FROM edges WHERE source='$(sql_escape "$id")' AND type='implements' LIMIT 1;" 2>/dev/null || true)
    if [ -n "$parent_epic" ]; then
        _aggregate_epic_commits "$parent_epic" 2>/dev/null || true
    fi

    # Auto-unblock nodes that were only blocked by this one
    _do_unblock_cascade "$id"

    if [ "$format" = "json" ]; then
        local text
        text=$(db_query "SELECT text FROM nodes WHERE id='$id';")
        jq -n --arg id "$id" --arg text "$text" --arg status "done" \
            '{"id": $id, "text": $text, "status": $status}'
    else
        echo -e "${GREEN}✓${NC} Closed: $id"
    fi

    # Write-time validation warnings (always to stderr — safe in json mode)
    if [ "$no_warn" != "1" ] && [ "${WV_NO_WARN:-0}" != "1" ]; then
        validate_on_done "$id"
    fi

    # === Post-close: GH issue, cache, notifications, breadcrumbs ===
    _done_close_gh_issue "$id"

    # Invalidate context cache for completed node and any nodes it was blocking
    local affected_nodes
    affected_nodes=$(db_query "SELECT target FROM edges WHERE source='$id' AND type='blocks';" | tr '\n' ' ')
    # shellcheck disable=SC2086  # word-split intentional — affected_nodes is space-delimited ID list
    invalidate_context_cache "$id" $affected_nodes

    # Live progress notification to GitHub
    if [ -n "$learning" ]; then
        gh_notify "$id" "done" --learning="$learning"
    else
        gh_notify "$id" "done"
    fi

    _done_write_breadcrumb "$id"
    auto_sync 2>/dev/null || true
}

# ═══════════════════════════════════════════════════════════════════════════
# cmd_batch_done — Close multiple nodes at once
# ═══════════════════════════════════════════════════════════════════════════

cmd_batch_done() {
    local learning=""
    local no_warn=0
    local ids=()

    while [ $# -gt 0 ]; do
        case "$1" in
            --learning=*) learning="${1#*=}" ;;
            --no-warn) no_warn=1 ;;
            wv-*) ids+=("$1") ;;
        esac
        shift
    done

    if [ ${#ids[@]} -eq 0 ]; then
        echo -e "${RED}Error: at least one node ID required${NC}" >&2
        echo "Usage: wv batch-done <id1> <id2> ... [--learning=\"...\"] [--no-warn]" >&2
        return 1
    fi

    local closed=0 failed=0
    for id in "${ids[@]}"; do
        local args=("$id")
        [ -n "$learning" ] && args+=("--learning=$learning")
        [ "$no_warn" = "1" ] && args+=("--no-warn")

        if cmd_done "${args[@]}"; then
            ((closed++))
        else
            ((failed++))
        fi
    done

    echo ""
    echo -e "${GREEN}Batch complete:${NC} $closed closed, $failed failed (of ${#ids[@]} total)"
}

# ═══════════════════════════════════════════════════════════════════════════
# cmd_bulk_update — Update multiple nodes from JSON on stdin
# ═══════════════════════════════════════════════════════════════════════════

cmd_bulk_update() {
    local dry_run=false

    # Check for --help before stdin check
    for arg in "$@"; do
        case "$arg" in
            --help|-h)
                cat <<'USAGE'
Usage: echo '<json>' | wv bulk-update [--dry-run]

Reads a JSON array from stdin. Each object specifies a node ID and fields to update.

Fields: id (required), alias, status, text, metadata (merged), remove-keys (array)

Example:
  echo '[
    {"id": "wv-a1b2", "alias": "my-task", "status": "active"},
    {"id": "wv-c3d4", "metadata": {"priority": 1}},
    {"id": "wv-e5f6", "remove-keys": ["old_field"]}
  ]' | wv bulk-update

Use --dry-run to validate without applying changes.
USAGE
                return 0
                ;;
        esac
    done

    while [ $# -gt 0 ]; do
        case "$1" in
            --dry-run) dry_run=true ;;
        esac
        shift
    done

    # Read JSON from stdin
    local input
    if [ -t 0 ]; then
        echo -e "${RED}Error: no input on stdin${NC}" >&2
        echo "Usage: echo '[{\"id\":\"wv-xxxxxx\",\"alias\":\"test\"}]' | wv bulk-update" >&2
        return 1
    fi
    input=$(cat)

    # Validate JSON array
    if ! echo "$input" | jq 'if type == "array" then . else error("not an array") end' >/dev/null 2>&1; then
        echo -e "${RED}Error: stdin must be a JSON array${NC}" >&2
        return 1
    fi

    local count
    count=$(echo "$input" | jq 'length')
    if [ "$count" -eq 0 ]; then
        echo -e "${YELLOW}No items in array${NC}" >&2
        return 0
    fi

    # Phase 1: Validate all IDs exist before applying any changes
    local missing=0
    for i in $(seq 0 $((count - 1))); do
        local item_id
        item_id=$(echo "$input" | jq -r ".[$i].id // empty")
        if [ -z "$item_id" ]; then
            echo -e "${RED}Error: item [$i] missing 'id' field${NC}" >&2
            return 1
        fi

        # Resolve alias to ID if needed
        if [[ "$item_id" != wv-* ]]; then
            local resolved
            resolved=$(db_query "SELECT id FROM nodes WHERE alias='$(sql_escape "$item_id")' LIMIT 1;")
            if [ -n "$resolved" ]; then
                item_id="$resolved"
            fi
        fi

        validate_id "$item_id" 2>/dev/null || true
        local exists
        exists=$(db_query "SELECT COUNT(*) FROM nodes WHERE id='$item_id';")
        if [ "$exists" = "0" ]; then
            echo -e "${RED}Error: node $item_id not found (item [$i])${NC}" >&2
            ((missing++)) || true
        fi
    done

    if [ "$missing" -gt 0 ]; then
        echo -e "${RED}Aborting: $missing node(s) not found. No changes applied.${NC}" >&2
        return 1
    fi

    if [ "$dry_run" = true ]; then
        echo -e "${YELLOW}Dry run:${NC} would update $count node(s):"
        for i in $(seq 0 $((count - 1))); do
            local item_id fields
            item_id=$(echo "$input" | jq -r ".[$i].id")
            fields=$(echo "$input" | jq -c ".[$i] | del(.id)" | sed 's/[{}]//g')
            echo "  $item_id: $fields"
        done
        return 0
    fi

    # Phase 2: Apply updates
    local updated=0 failed=0
    for i in $(seq 0 $((count - 1))); do
        local item
        item=$(echo "$input" | jq -c ".[$i]")

        local item_id
        item_id=$(echo "$item" | jq -r '.id')

        # Resolve alias to ID
        if [[ "$item_id" != wv-* ]]; then
            local resolved
            resolved=$(db_query "SELECT id FROM nodes WHERE alias='$(sql_escape "$item_id")' LIMIT 1;")
            [ -n "$resolved" ] && item_id="$resolved"
        fi

        # Build update args for cmd_update
        local args=("$item_id")

        local val
        val=$(echo "$item" | jq -r '.status // empty')
        [ -n "$val" ] && args+=("--status=$val")

        val=$(echo "$item" | jq -r '.alias // empty')
        [ -n "$val" ] && args+=("--alias=$val")

        val=$(echo "$item" | jq -r '.text // empty')
        [ -n "$val" ] && args+=("--text=$val")

        val=$(echo "$item" | jq -c '.metadata // empty')
        if [ -n "$val" ] && [ "$val" != '""' ]; then
            args+=("--metadata=$val")
        fi

        # Handle remove-keys array
        local remove_keys
        remove_keys=$(echo "$item" | jq -r '.["remove-keys"]? // empty | .[]?' 2>/dev/null)
        if [ -n "$remove_keys" ]; then
            while IFS= read -r key; do
                # Direct SQL remove (cmd_update --remove-key returns early after first key)
                db_query "UPDATE nodes SET metadata = json_remove(metadata, '\$.${key}'), updated_at=CURRENT_TIMESTAMP WHERE id='$item_id';"
            done <<< "$remove_keys"
        fi

        # Apply the update if there are fields beyond just id and remove-keys
        local field_count
        field_count=$(echo "$item" | jq 'del(.id, .["remove-keys"]) | length')
        if [ "$field_count" -gt 0 ]; then
            if cmd_update "${args[@]}" 2>/dev/null; then
                ((updated++)) || true
            else
                echo -e "${RED}Failed to update $item_id${NC}" >&2
                ((failed++)) || true
            fi
        elif [ -n "$remove_keys" ]; then
            echo -e "${GREEN}✓${NC} Updated: $item_id (removed keys)"
            ((updated++)) || true
        fi
    done

    echo ""
    echo -e "${GREEN}Bulk update:${NC} $updated updated, $failed failed (of $count total)"

    auto_sync 2>/dev/null || true
}

# ═══════════════════════════════════════════════════════════════════════════
# cmd_work — Claim a node and set up subagent context inheritance
# ═══════════════════════════════════════════════════════════════════════════

cmd_work() {
    # Check for incomplete operations before claiming new work
    if journal_has_incomplete 2>/dev/null; then
        echo -e "${YELLOW}⚠ Incomplete operation detected — run 'wv recover' first${NC}" >&2
    fi

    local id="${1:-}"
    local quiet=false
    local force=false
    local format="text"

    shift || true
    while [ $# -gt 0 ]; do
        case "$1" in
            --quiet|-q) quiet=true ;;
            --force|-f) force=true ;;
            --json)     format="json" ;;
        esac
        shift
    done

    if [ -z "$id" ]; then
        echo -e "${RED}Error: node ID required${NC}" >&2
        echo "Usage: wv work <id> [--quiet] [--force] [--json]" >&2
        echo "" >&2
        echo "Claims a node and sets WV_ACTIVE for subagent context inheritance." >&2
        echo "Use --force to override a stale claim from another agent." >&2
        echo "Run the export command to enable subagent context:" >&2
        echo "  eval \"\$(wv work <id> --quiet)\"" >&2
        return 1
    fi

    # Validate ID format
    validate_id "$id" || return 1

    # Verify node exists
    local exists
    exists=$(db_query "SELECT COUNT(*) FROM nodes WHERE id='$id';")
    if [ "$exists" = "0" ]; then
        echo -e "${RED}Error: node $id not found${NC}" >&2
        return 1
    fi

    # Resolve agent identity (strip quotes for SQL safety)
    local agent_id
    agent_id="$(sql_escape "${WV_AGENT_ID:-$(hostname)-$(whoami)}")"

    # Atomic CAS claim: succeeds only if unclaimed or already claimed by this agent
    local claim_changes
    claim_changes=$(db_query "
        UPDATE nodes
        SET metadata = json_set(COALESCE(metadata,'{}'), '$.claimed_by', '$agent_id'),
            status = 'active',
            updated_at = CURRENT_TIMESTAMP
        WHERE id = '$id'
          AND (json_extract(metadata, '$.claimed_by') IS NULL
               OR json_extract(metadata, '$.claimed_by') = '$agent_id');
        SELECT changes();
    ")

    if [ "$claim_changes" = "0" ]; then
        # Claim lost — another agent holds it
        local holder
        holder=$(db_query "SELECT json_extract(metadata, '$.claimed_by') FROM nodes WHERE id='$id';")
        if [ "$force" = true ]; then
            [ "$format" != "json" ] && echo -e "${YELLOW}⚠ Overriding stale claim held by: $holder${NC}" >&2
            db_query "UPDATE nodes
                SET metadata = json_set(COALESCE(metadata,'{}'), '$.claimed_by', '$agent_id'),
                    status = 'active',
                    updated_at = CURRENT_TIMESTAMP
                WHERE id = '$id';"
        else
            if [ "$format" = "json" ]; then
                jq -n --arg id "$id" --arg holder "$holder" \
                    '{"ok": false, "error": "claimed_by_other", "holder": $holder, "id": $id}' >&2
            else
                echo -e "${RED}✗ $id is claimed by $holder${NC}" >&2
                echo "  Use --force to override a stale claim." >&2
            fi
            return 1
        fi
    fi

    set_primary_node "$id"

    if [ "$format" = "json" ]; then
        # Structured output for runtime consumption
        local text
        text=$(db_query "SELECT text FROM nodes WHERE id='$id';")
        jq -n --arg id "$id" --arg text "$text" --arg status "active" \
            '{"id": $id, "text": $text, "status": $status}'
        return 0
    fi

    if [ "$quiet" = true ]; then
        # Machine-readable output for eval
        echo "export WV_ACTIVE=$id"
    else
        # Human-readable output
        local text
        text=$(db_query "SELECT text FROM nodes WHERE id='$id';")
        echo -e "${GREEN}✓${NC} Claimed: $id"
        echo "  $text"

        # Show last commit touching node's files for context
        if command -v git >/dev/null 2>&1 && git rev-parse --is-inside-work-tree &>/dev/null; then
            local last_commit
            last_commit=$(git log -1 --oneline 2>/dev/null || true)
            if [ -n "$last_commit" ]; then
                echo -e "  ${DIM}Last commit: $last_commit${NC}"
            fi
        fi
        echo ""
        echo -e "${CYAN}To enable subagent context inheritance:${NC}"
        echo "  export WV_ACTIVE=$id"
        echo ""
        echo -e "${CYAN}Or use eval for one command:${NC}"
        echo "  eval \"\$(wv work $id --quiet)\""

        # Nudge: check for done_criteria in metadata
        local has_criteria
        has_criteria=$(db_query "
            SELECT COUNT(*) FROM nodes WHERE id='$id'
            AND json_extract(metadata, '\$.done_criteria') IS NOT NULL;
        " 2>/dev/null || echo "0")
        if [ "$has_criteria" = "0" ]; then
            echo ""
            echo -e "${YELLOW}  Hint: No done_criteria set. Define acceptance criteria:${NC}" >&2
            echo -e "${YELLOW}    wv update $id --metadata='{\"done_criteria\":\"tests pass, docs updated\"}'${NC}" >&2
        fi
    fi

    # Live progress notification to GitHub
    gh_notify "$id" "work"
}

# ═══════════════════════════════════════════════════════════════════════════
# cmd_ready — Show nodes ready to work on
# ═══════════════════════════════════════════════════════════════════════════

cmd_ready() {
    local format="text"
    local count_only=false
    local show_all=false
    local subtree_id=""

    while [ $# -gt 0 ]; do
        case "$1" in
            --json)      format="json" ;;
            --count)     count_only=true ;;
            --all)       show_all=true ;;
            --subtree=*) subtree_id="${1#--subtree=}" ;;
            --subtree)   shift; subtree_id="${1:-}" ;;
        esac
        shift
    done

    # Agent identity for claim filtering (same default as cmd_work)
    local agent_id
    agent_id="$(sql_escape "${WV_AGENT_ID:-$(hostname)-$(whoami)}")"

    # Validate subtree epic and build recursive CTE (walks implements edges downward)
    local subtree_cte="" subtree_join=""
    if [ -n "$subtree_id" ]; then
        subtree_id="$(sql_escape "$subtree_id")"
        local epic_exists
        epic_exists=$(db_query "SELECT COUNT(*) FROM nodes WHERE id='$subtree_id';" 2>/dev/null || echo "0")
        if [ "$epic_exists" = "0" ]; then
            echo -e "${RED}Error: node $subtree_id not found${NC}" >&2
            return 1
        fi
        subtree_cte="WITH RECURSIVE _subtree(id) AS (
            SELECT '$subtree_id'
            UNION
            SELECT e.source FROM edges e
            JOIN _subtree s ON e.target = s.id
            WHERE e.type = 'implements'
        )"
        subtree_join="JOIN _subtree st ON n.id = st.id"
    fi

    # Ready = todo status AND not blocked by any open node
    local ready_where="
        n.status = 'todo'
        AND NOT EXISTS (
            SELECT 1 FROM edges e
            JOIN nodes blocker ON e.source = blocker.id
            WHERE e.target = n.id
            AND e.type = 'blocks'
            AND blocker.status != 'done'
        )
    "

    # Default: hide nodes claimed by other agents; --all shows everything
    local claim_filter=""
    if [ "$show_all" = false ]; then
        claim_filter="AND (json_extract(n.metadata, '$.claimed_by') IS NULL
                          OR json_extract(n.metadata, '$.claimed_by') = '$agent_id')"
    fi

    if [ "$count_only" = true ]; then
        db_query "$subtree_cte SELECT COUNT(*) FROM nodes n $subtree_join WHERE $ready_where $claim_filter;"
        return
    fi

    if [ "$format" = "json" ]; then
        local results
        results=$(db_query_json "$subtree_cte SELECT n.id, n.text, n.status, n.metadata FROM nodes n $subtree_join WHERE $ready_where $claim_filter ORDER BY n.created_at ASC, n.id ASC;")
        [ -z "$results" ] && echo "[]" || echo "$results"
    else
        db_query "$subtree_cte SELECT n.id, n.text, json_extract(n.metadata, '$.claimed_by') FROM nodes n $subtree_join WHERE $ready_where $claim_filter ORDER BY n.created_at ASC, n.id ASC;" \
        | while IFS='|' read -r id text claimed_by; do
            if [ -n "$claimed_by" ]; then
                echo -e "${CYAN}$id${NC}: $text ${YELLOW}(claimed: $claimed_by)${NC}"
            else
                echo -e "${CYAN}$id${NC}: $text"
            fi
        done
    fi
}

# ═══════════════════════════════════════════════════════════════════════════
# cmd_list — List nodes with filtering
# ═══════════════════════════════════════════════════════════════════════════

cmd_list() {
    local status_filter=""
    local priority_filter=""
    local type_filter=""
    local format="text"
    local all=false

    while [ $# -gt 0 ]; do
        case "$1" in
            --status=*) status_filter="${1#*=}" ;;
            --priority=*) priority_filter="${1#*=}" ;;
            --type=*) type_filter="${1#*=}" ;;
            --json) format="json" ;;
            --all) all=true ;;
        esac
        shift
    done

    # Validate status filter (prevent SQL injection)
    if [ -n "$status_filter" ]; then
        case "$status_filter" in
            todo|active|blocked|blocked-external|done|pending) ;; # valid
            *)
                echo -e "${RED}Error: invalid status '$status_filter'${NC}" >&2
                echo "Valid statuses: todo, active, blocked, blocked-external, done, pending" >&2
                return 1
                ;;
        esac
    fi

    # Validate priority filter (must be numeric)
    if [ -n "$priority_filter" ]; then
        if ! [[ "$priority_filter" =~ ^[0-9]+$ ]]; then
            echo -e "${RED}Error: priority must be a number${NC}" >&2
            return 1
        fi
    fi

    # Validate type filter (alphanumeric only, prevent injection)
    if [ -n "$type_filter" ]; then
        if ! [[ "$type_filter" =~ ^[a-zA-Z0-9_-]+$ ]]; then
            echo -e "${RED}Error: invalid type filter${NC}" >&2
            return 1
        fi
    fi

    # Build WHERE clause with multiple filters
    local where_clause=""
    local filters=""

    if [ "$all" != true ] && [ -z "$status_filter" ]; then
        filters="status != 'done'"
    elif [ -n "$status_filter" ]; then
        filters="status = '$status_filter'"
    fi

    if [ -n "$priority_filter" ]; then
        if [ -n "$filters" ]; then
            filters="$filters AND priority = $priority_filter"
        else
            filters="priority = $priority_filter"
        fi
    fi

    if [ -n "$type_filter" ]; then
        if [ -n "$filters" ]; then
            filters="$filters AND type = '$type_filter'"
        else
            filters="type = '$type_filter'"
        fi
    fi

    if [ -n "$filters" ]; then
        where_clause="WHERE $filters"
    fi

    if [ "$format" = "json" ]; then
        local results
        results=$(db_query_json "SELECT id, text, status, metadata, alias FROM nodes $where_clause ORDER BY priority DESC, created_at DESC, id ASC;")
        [ -z "$results" ] && echo "[]" || echo "$results"
    else
        # Text mode: exclude metadata to avoid multiline JSON breaking pipe-delimited parsing
        db_query "SELECT id, text, status FROM nodes $where_clause ORDER BY priority DESC, created_at DESC, id ASC;" | while IFS='|' read -r id text status; do
            local color="$NC"
            case "$status" in
                active) color="$GREEN" ;;
                blocked) color="$RED" ;;
                todo) color="$CYAN" ;;
                done) color="$YELLOW" ;;
            esac
            echo -e "${color}[$status]${NC} $id: $text"
        done
    fi
}

# ═══════════════════════════════════════════════════════════════════════════
# cmd_show — Show node details
# ═══════════════════════════════════════════════════════════════════════════

cmd_show() {
    local id="${1:-}"
    local format="text"
    
    shift || true
    while [ $# -gt 0 ]; do
        case "$1" in
            --json) format="json" ;;
        esac
        shift
    done
    
    if [ -z "$id" ]; then
        echo -e "${RED}Error: node ID required${NC}" >&2
        return 1
    fi

    # Validate ID format (SQL injection prevention)
    validate_id "$id" || return 1
    
    local query="SELECT id, text, status, json(metadata) AS metadata, created_at, updated_at, alias FROM nodes WHERE id='$id';"

    # Check if node exists
    local exists=$(db_query "SELECT 1 FROM nodes WHERE id='$id';")
    if [ -z "$exists" ]; then
        echo -e "${RED}Error: node '$id' not found${NC}" >&2
        return 1
    fi

    if [ "$format" = "json" ]; then
        db_query_json "$query"
    else
        # Use unit separator — node text can contain '|'
        db_ensure
        sqlite3 -batch -cmd ".timeout 5000" -separator $'\x1f' "$WV_DB" "$query" | while IFS=$'\x1f' read -r id text status metadata created updated node_alias; do
            echo -e "${CYAN}ID:${NC}       $id"
            [ -n "$node_alias" ] && echo -e "${CYAN}Alias:${NC}    $node_alias"
            echo -e "${CYAN}Text:${NC}     $text"
            echo -e "${CYAN}Status:${NC}   $status"
            local _intent
            _intent=$(echo "$metadata" | jq -r '.current_intent // empty' 2>/dev/null)
            [ -n "$_intent" ] && echo -e "${CYAN}Intent:${NC}   $_intent"
            echo -e "${CYAN}Metadata:${NC} $metadata"
            echo -e "${CYAN}Created:${NC}  $created"
            echo -e "${CYAN}Updated:${NC}  $updated"
        done
        
        # Show blocking relationships
        local blockers=$(db_query "SELECT source FROM edges WHERE target='$id' AND type='blocks';")
        if [ -n "$blockers" ]; then
            echo -e "${CYAN}Blocked by:${NC}"
            echo "$blockers" | while read -r blocker_id; do
                local blocker_text=$(db_query "SELECT text FROM nodes WHERE id='$blocker_id';")
                echo "  - $blocker_id: $blocker_text"
            done
        fi
    fi
}

# ═══════════════════════════════════════════════════════════════════════════
# cmd_status — Compact status for context injection
# ═══════════════════════════════════════════════════════════════════════════

cmd_status() {
    # Compact status for context injection (~50 tokens)
    local active=$(db_query "SELECT COUNT(*) FROM nodes WHERE status='active';")
    local ready=$(cmd_ready --count)
    local blocked=$(db_query "SELECT COUNT(*) FROM nodes WHERE status='blocked';")
    local pending_close=$(db_query "SELECT COUNT(*) FROM nodes WHERE json_extract(metadata, '$.needs_human_verification') = 1;")

    if [ "${pending_close:-0}" -gt 0 ] 2>/dev/null; then
        echo "Work: $active active, $ready ready, $blocked blocked. $pending_close pending-close."
    else
        echo "Work: $active active, $ready ready, $blocked blocked."
    fi

    if [ "$active" -gt 0 ]; then
        local primary
        primary=$(get_primary_node)
        if [ -n "$primary" ]; then
            # Verify primary is still active
            local pstatus
            pstatus=$(db_query "SELECT status FROM nodes WHERE id='$primary';" 2>/dev/null)
            if [ "$pstatus" = "active" ]; then
                local ptext
                ptext=$(db_query "SELECT text FROM nodes WHERE id='$primary';")
                echo "Primary: $primary: $ptext"
            else
                # Primary is no longer active — clear and fall back
                clear_primary_node
                local current=$(db_query "SELECT id || ': ' || text FROM nodes WHERE status='active' LIMIT 1;")
                echo "Current: $current"
            fi
        else
            local current=$(db_query "SELECT id || ': ' || text FROM nodes WHERE status='active' LIMIT 1;")
            echo "Current: $current"
        fi
    fi
}

# ═══════════════════════════════════════════════════════════════════════════
# cmd_pending_close — List nodes awaiting human verification before close
# ═══════════════════════════════════════════════════════════════════════════

cmd_pending_close() {
    local json_mode=false count_only=false
    while [ $# -gt 0 ]; do
        case "$1" in
            --json)  json_mode=true ;;
            --count) count_only=true ;;
            *) echo -e "${RED}Unknown option: $1${NC}" >&2; return 1 ;;
        esac
        shift
    done

    if [ "$count_only" = true ]; then
        db_query "SELECT COUNT(*) FROM nodes WHERE json_extract(metadata, '$.needs_human_verification') = 1;"
        return 0
    fi

    local nodes
    nodes=$(db_query "
        SELECT id || '|' ||
               COALESCE(text,'') || '|' ||
               COALESCE(json_extract(metadata, '$.pending_close.reason'), '') || '|' ||
               COALESCE(json_extract(metadata, '$.pending_close.resume_command'), '')
        FROM nodes
        WHERE json_extract(metadata, '$.needs_human_verification') = 1
        ORDER BY updated_at DESC;")

    if [ -z "$nodes" ]; then
        if [ "$json_mode" = true ]; then
            echo "[]"
        else
            echo "No pending-close nodes."
        fi
        return 0
    fi

    if [ "$json_mode" = true ]; then
        echo "$nodes" | jq -R -s '
            split("\n") | map(select(. != "")) |
            map(split("|") | {id: .[0], text: .[1], reason: .[2], resume_command: .[3]})
        '
        return 0
    fi

    local count
    count=$(echo "$nodes" | grep -c .)
    echo "Pending-close: $count node(s) awaiting human verification."
    while IFS='|' read -r nid ntext reason resume_cmd; do
        [ -z "$nid" ] && continue
        echo "  $nid: $ntext"
        [ -n "$reason" ]     && echo "    Reason:  $reason"
        if [ -n "$resume_cmd" ]; then
            echo "    Resume:  $resume_cmd"
        else
            echo "    Resume:  wv update $nid --metadata='{\"verification\":{\"method\":\"...\",\"result\":\"pass\"}}' && wv done $nid"
        fi
    done <<< "$nodes"
}

# ═══════════════════════════════════════════════════════════════════════════
# cmd_update — Update node fields
# ═══════════════════════════════════════════════════════════════════════════

cmd_update() {
    local id="${1:-}"
    shift || true
    
    if [ -z "$id" ]; then
        echo -e "${RED}Error: node ID required${NC}" >&2
        return 1
    fi

    # Validate ID format (SQL injection prevention)
    validate_id "$id" || return 1
    
    local updates=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --status=*)
                local status="${1#*=}"
                validate_status "$status" || return 1
                updates="${updates}status='$status',"
                ;;
            --text=*)
                local text="${1#*=}"
                text="${text//\'/\'\'}"
                updates="${updates}text='$text',"
                ;;
            --metadata=*)
                local metadata="${1#*=}"
                # Validate JSON before storing
                if ! echo "$metadata" | jq '.' >/dev/null 2>&1; then
                    echo -e "${RED}Error: invalid JSON in --metadata${NC}" >&2
                    return 1
                fi
                # Merge into existing metadata (not replace)
                local cur_meta_raw cur_meta
                cur_meta_raw=$(db_query_json "SELECT metadata FROM nodes WHERE id='$id';" 2>/dev/null || echo "[]")
                cur_meta=$(echo "$cur_meta_raw" | jq -r '.[0].metadata // "{}"' 2>/dev/null || echo "{}")
                if [[ "$cur_meta" != "{"* ]]; then
                    cur_meta=$(echo "$cur_meta" | jq -r '.' 2>/dev/null || echo "{}")
                fi
                metadata=$(echo "$cur_meta" | jq --argjson new "$metadata" '. * $new' 2>/dev/null || echo "$metadata")
                metadata="${metadata//\'/\'\'}"
                updates="${updates}metadata='$metadata',"
                ;;
            --alias=*)
                local alias="${1#*=}"
                if [ "$alias" = "" ]; then
                    updates="${updates}alias=NULL,"
                else
                    updates="${updates}alias='$(sql_escape "$alias")',"
                fi
                ;;
            --remove-key=*)
                local remove_key="${1#*=}"
                if [ -z "$remove_key" ]; then
                    echo -e "${RED}Error: key name required for --remove-key${NC}" >&2
                    return 1
                fi
                # Use json_remove to atomically remove a single metadata key
                db_query "UPDATE nodes SET metadata = json_remove(metadata, '\$.${remove_key}'), updated_at=CURRENT_TIMESTAMP WHERE id='$id';"
                echo -e "${GREEN}✓${NC} Removed metadata key '${remove_key}' from $id"
                auto_sync 2>/dev/null || true
                return 0
                ;;
        esac
        shift
    done
    
    if [ -z "$updates" ]; then
        echo -e "${RED}Error: no updates specified${NC}" >&2
        return 1
    fi
    
    # Remove trailing comma, add updated_at
    updates="${updates%,},updated_at=CURRENT_TIMESTAMP"
    
    db_query "UPDATE nodes SET $updates WHERE id='$id';"
    echo -e "${GREEN}✓${NC} Updated: $id"

    # Auto-unblock cascade when status changed to done
    if [[ "$updates" == *"status='done'"* ]]; then
        _do_unblock_cascade "$id"
    fi

    auto_sync 2>/dev/null || true
}

# ═══════════════════════════════════════════════════════════════════════════
# cmd_quick — One-shot create + commit + close for trivial tasks
# Creates node as active, commits staged changes, then closes the node.
# This ensures the pre-commit hook (which requires an active node) passes.
# ═══════════════════════════════════════════════════════════════════════════

cmd_quick() {
    local text="$1"
    local learning="trivial fix"
    local metadata="{}"

    shift || true
    while [ $# -gt 0 ]; do
        case "$1" in
            --learning=*) learning="${1#*=}" ;;
            --metadata=*) metadata="${1#*=}" ;;
            --*) ;; # skip unrecognized flags
            *) text="$text $1" ;;
        esac
        shift
    done

    if [ -z "$text" ]; then
        echo -e "${RED}Error: text required${NC}" >&2
        echo "Usage: wv quick \"task description\" [--learning=\"...\"]" >&2
        return 1
    fi

    # Validate metadata JSON
    if ! echo "$metadata" | jq '.' >/dev/null 2>&1; then
        echo -e "${RED}Error: invalid JSON in --metadata${NC}" >&2
        return 1
    fi

    local id=$(generate_id)

    # Escape single quotes
    text="${text//\'/\'\'}"
    metadata="${metadata//\'/\'\'}"
    learning="${learning//\'/\'\'}"

    # Step 1: Create node as ACTIVE (so pre-commit hook passes)
    local now_meta
    now_meta=$(echo "$metadata" | jq -c --arg l "$learning" '. + {learning: $l}' 2>/dev/null || echo "{\"learning\":\"$learning\"}")
    now_meta="${now_meta//\'/\'\'}"

    db_query "INSERT INTO nodes (id, text, status, metadata) VALUES ('$id', '$text', 'active', '$now_meta');"
    echo -e "${GREEN}✓${NC} $id: $text (active)" >&2

    # Step 2: Commit staged changes if any exist
    local committed=false
    if command -v git >/dev/null 2>&1; then
        local git_root
        git_root=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
        if [ -n "$git_root" ]; then
            # Check for staged or unstaged tracked changes
            local has_staged has_unstaged
            has_staged=$(git -C "$git_root" diff --cached --quiet 2>/dev/null; echo $?)
            has_unstaged=$(git -C "$git_root" diff --quiet 2>/dev/null; echo $?)

            if [ "$has_staged" != "0" ] || [ "$has_unstaged" != "0" ]; then
                # Stage tracked changes (not untracked files — user should add those explicitly)
                git -C "$git_root" add -u 2>/dev/null || true
                if git -C "$git_root" commit -m "$text"; then
                    committed=true
                    echo -e "${GREEN}✓${NC} Committed" >&2
                else
                    echo -e "${YELLOW}⚠${NC} Commit failed — closing node anyway" >&2
                fi
            else
                echo -e "${YELLOW}⊘${NC} No changes to commit" >&2
            fi
        fi
    fi

    # Step 3: Close the node + unblock cascade
    db_query "UPDATE nodes SET status = 'done' WHERE id = '$id';"
    _do_unblock_cascade "$id"
    echo -e "${GREEN}✓${NC} $id (quick-closed)" >&2
    echo "$id"

    # Step 4: Sync .weave/ state
    cmd_sync 2>/dev/null || true
}

# ═══════════════════════════════════════════════════════════════════════════
# cmd_ship — Done + sync + push in one command
# ═══════════════════════════════════════════════════════════════════════════

cmd_ship() {
    # Check for incomplete operations before starting a new ship
    if journal_has_incomplete 2>/dev/null; then
        echo -e "${YELLOW}⚠ Recovering incomplete operation before shipping...${NC}" >&2
        cmd_recover --auto 2>/dev/null || true
    fi

    local id="${1:-}"
    local learning=""
    local gh_flag=false
    local skip_verification=false

    shift || true
    while [ $# -gt 0 ]; do
        case "$1" in
            --learning=*) learning="${1#*=}" ;;
            --gh) gh_flag=true ;;
            --skip-verification) skip_verification=true ;;
        esac
        shift
    done

    if [ -z "$id" ]; then
        echo -e "${RED}Error: node ID required${NC}" >&2
        echo "Usage: wv ship <id> [--learning=\"...\"] [--gh]" >&2
        return 1
    fi

    # Validate ID format
    validate_id "$id" || return 1

    # Auto-detect GH sync need before journaling
    local needs_gh=false
    if [ "$gh_flag" = true ]; then
        needs_gh=true
    else
        local gh_found
        gh_found=$(db_query "
            WITH RECURSIVE ancestry(id) AS (
                SELECT '$id'
                UNION ALL
                SELECT e.target FROM edges e JOIN ancestry a ON e.source = a.id WHERE e.type = 'implements'
            )
            SELECT 1 FROM nodes n JOIN ancestry a ON n.id = a.id
            WHERE json_extract(n.metadata, '$.gh_issue') IS NOT NULL
            LIMIT 1;
        " 2>/dev/null || true)
        if [ -n "$gh_found" ]; then
            needs_gh=true
        fi
    fi

    # Set ship_pending metadata marker (survives reboot for fallback recovery)
    db_query "UPDATE nodes SET metadata = json_set(COALESCE(metadata,'{}'), '$.ship_pending', json('true')) WHERE id = '$id';" 2>/dev/null || true

    # Begin journaled operation
    journal_begin "ship" "{\"id\":\"$id\",\"gh\":$needs_gh}"

    # Step 1: Close the node
    journal_step 1 "done" "{\"id\":\"$id\"}"
    local done_rc=0
    if [ -n "$learning" ]; then
        cmd_done "$id" --learning="$learning" || done_rc=$?
    elif [ "$skip_verification" = true ]; then
        cmd_done "$id" --skip-verification || done_rc=$?
    else
        echo -e "${RED}Error: --learning=\"...\" or --skip-verification required${NC}" >&2
        echo "Usage: wv ship <id> --learning=\"decision: ... | pattern: ... | pitfall: ...\"" >&2
        journal_abort 2>/dev/null || true
        return 1
    fi
    if [ "$done_rc" -eq 2 ]; then
        db_query "UPDATE nodes SET metadata = json_remove(COALESCE(metadata,'{}'), '$.ship_pending') WHERE id = '$id';" 2>/dev/null || true
        journal_end
        journal_clean
        return 2
    elif [ "$done_rc" -ne 0 ]; then
        return "$done_rc"
    fi
    journal_complete 1

    # Step 2: Sync to disk (with GH if needed)
    journal_step 2 "sync" "{\"gh\":$needs_gh}"
    if [ "$needs_gh" = true ]; then
        echo -e "${CYAN}ℹ${NC} GitHub-linked node detected — syncing with --gh"
        cmd_sync --gh
    else
        cmd_sync
    fi
    journal_complete 2

    # Step 3: Git commit
    journal_step 3 "git_commit"
    if command -v git >/dev/null 2>&1; then
        local git_root
        git_root=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
        if [ -n "$git_root" ]; then
            git -C "$git_root" add .weave/ 2>/dev/null || true
            git -C "$git_root" commit -m "chore: sync Weave after completing $id [skip ci]" --allow-empty 2>/dev/null || true
        fi
    fi
    journal_complete 3

    # Step 4: Git push
    journal_step 4 "git_push"
    if command -v git >/dev/null 2>&1 && [ -n "${git_root:-}" ]; then
        if git -C "$git_root" push 2>/dev/null; then
            echo -e "${GREEN}✓${NC} Pushed to remote"
        else
            echo -e "${RED}✗ PUSH FAILED — work is NOT on remote${NC}" >&2
            echo -e "${YELLOW}  Run 'git push' manually or 'wv recover' to retry${NC}" >&2
            journal_end
            return 1
        fi
    fi
    journal_complete 4

    # Clear ship_pending marker and complete journal
    db_query "UPDATE nodes SET metadata = json_remove(metadata, '$.ship_pending') WHERE id = '$id';" 2>/dev/null || true
    journal_end
    journal_clean
}

# ═══════════════════════════════════════════════════════════════════════════
# cmd_delete — Permanently delete a node and its edges
# ═══════════════════════════════════════════════════════════════════════════

cmd_delete() {
    local id="${1:-}"
    local force=false
    local dry_run=false
    local close_gh=true

    shift || true
    while [ $# -gt 0 ]; do
        case "$1" in
            --force) force=true ;;
            --dry-run) dry_run=true ;;
            --no-gh) close_gh=false ;;
        esac
        shift
    done

    if [ -z "$id" ]; then
        echo -e "${RED}Error: node ID required${NC}" >&2
        echo "Usage: wv delete <id> [--force] [--dry-run] [--no-gh]" >&2
        return 1
    fi

    validate_id "$id" || return 1

    # Verify node exists
    local node_text node_status
    node_text=$(db_query "SELECT text FROM nodes WHERE id='$id';")
    node_status=$(db_query "SELECT status FROM nodes WHERE id='$id';")
    if [ -z "$node_text" ]; then
        echo -e "${RED}Error: node $id not found${NC}" >&2
        return 1
    fi

    # Check for children (nodes that implement this one)
    local children
    children=$(db_query "SELECT source FROM edges WHERE target='$id' AND type='implements';")
    if [ -n "$children" ] && [ "$force" != "true" ]; then
        local child_count
        child_count=$(echo "$children" | wc -l)
        echo -e "${RED}Error: node $id has $child_count child node(s):${NC}" >&2
        echo "$children" | while read -r child_id; do
            local child_text
            child_text=$(db_query "SELECT COALESCE(alias, substr(text,1,50)) FROM nodes WHERE id='$child_id';")
            echo -e "  ${CYAN}$child_id${NC}: $child_text" >&2
        done
        echo -e "${YELLOW}Use --force to delete anyway (children will be orphaned)${NC}" >&2
        return 1
    fi

    # Collect edge info for display
    local edge_count
    edge_count=$(db_query "SELECT COUNT(*) FROM edges WHERE source='$id' OR target='$id';")

    # Get GH issue number for closing
    local gh_num=""
    local meta_raw meta
    meta_raw=$(db_query_json "SELECT metadata FROM nodes WHERE id='$id';" 2>/dev/null || echo "[]")
    meta=$(echo "$meta_raw" | jq -r '.[0].metadata // "{}"' 2>/dev/null || echo "{}")
    if [[ "$meta" != "{"* ]]; then
        meta=$(echo "$meta" | jq -r '.' 2>/dev/null || echo "{}")
    fi
    gh_num=$(echo "$meta" | jq -r '.gh_issue // empty' 2>/dev/null)

    if [ "$dry_run" = "true" ]; then
        echo -e "${YELLOW}Would delete:${NC}"
        echo "  Node: $id [$node_status]"
        echo "  Text: $node_text"
        echo "  Edges: $edge_count"
        [ -n "$gh_num" ] && [ "$gh_num" != "null" ] && echo "  GitHub issue: #$gh_num (would be closed)"
        return 0
    fi

    # Begin journaled operation
    journal_begin "delete" "{\"id\":\"$id\",\"gh_issue\":\"${gh_num:-}\"}"

    # Step 1: SQLite delete (archive + edges + node)
    journal_step 1 "sqlite_delete" "{\"id\":\"$id\"}"

    # Archive node to JSONL before deletion
    local archive_dir="$WEAVE_DIR/archive"
    local archive_file="$archive_dir/$(date +%Y-%m-%d).jsonl"
    mkdir -p "$archive_dir"
    db_query_json "SELECT * FROM nodes WHERE id='$id'" | jq -c '.[]' >> "$archive_file" 2>/dev/null || true

    # Collect connected nodes for cache invalidation
    local affected_nodes="$id"
    local connected
    connected=$(db_query "SELECT DISTINCT source FROM edges WHERE target='$id' UNION SELECT DISTINCT target FROM edges WHERE source='$id';" | tr '\n' ' ')
    affected_nodes="$affected_nodes $connected"

    # Delete edges first (no ON DELETE CASCADE)
    db_query "DELETE FROM edges WHERE source='$id' OR target='$id';"
    # Delete node
    db_query "DELETE FROM nodes WHERE id='$id';"

    echo -e "${GREEN}✓${NC} Deleted: $id ($node_text)"
    [ "$edge_count" -gt 0 ] && echo "  Removed $edge_count edge(s)"

    journal_complete 1

    # Step 2: Close matching GitHub issue if linked
    if [ "$close_gh" = "true" ] && [ -n "$gh_num" ] && [ "$gh_num" != "null" ]; then
        journal_step 2 "gh_close" "{\"issue\":$gh_num}"
        if command -v gh >/dev/null 2>&1; then
            local repo
            repo=$(gh repo view --json nameWithOwner -q '.nameWithOwner' 2>/dev/null || echo "")
            if [ -n "$repo" ]; then
                gh issue close "$gh_num" --repo "$repo" --comment "Deleted from Weave graph (node \`$id\`)" 2>/dev/null && \
                    echo -e "${GREEN}✓${NC} Closed GitHub issue #$gh_num" >&2 || \
                    echo -e "${YELLOW}Warning: Could not close GitHub issue #$gh_num${NC}" >&2
            fi
        fi
        journal_complete 2
    fi

    journal_end
    journal_clean

    # Invalidate caches for affected nodes
    for affected_id in $affected_nodes; do
        invalidate_context_cache "$affected_id" 2>/dev/null || true
    done

    auto_sync 2>/dev/null || true
}
