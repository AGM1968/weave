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

    local repo_root
    repo_root=$(dirname "$WEAVE_DIR")
    if [ -L "$WEAVE_DIR" ]; then
        wv_policy_verdict init_refuses_symlinked_weave_dir deny yes "" \
            "initialising through a symlink writes graph state outside the repository"
        echo "wv: refusing symlinked Weave directory: $WEAVE_DIR" >&2
        return 1
    fi
    wv_policy_verdict init_refuses_symlinked_weave_dir allow no "" "the Weave directory is not a symlink"
    wv_repository_require_owned "$repo_root" "wv init" || return 1

    # Force reset: wipe everything and start fresh
    if [ "$force" = true ]; then
        local count=0
        if [ -f "$WV_DB" ]; then
            count=$(sqlite3 -cmd ".timeout 5000" "$WV_DB" "SELECT COUNT(*) FROM nodes;" 2>/dev/null || echo "0")
        fi
        if [ "$count" -gt 0 ]; then
            wv_policy_verdict init_preserves_existing_graph allow yes --force \
                "reinitialised over a graph holding nodes"
            echo -e "${YELLOW}Destroying existing graph ($count nodes)...${NC}" >&2
        else
            wv_policy_verdict init_preserves_existing_graph allow no "" "no graph with nodes to destroy"
        fi
        # Remove hot zone DB. The replacement may reuse the inode, so the
        # db_ensure memo is cleared rather than trusted to notice. The WAL and
        # shared-memory files go with it: a WAL left behind is replayed over
        # the fresh database the next connection opens (wv-f241fa).
        rm -f "$WV_DB" "$WV_DB-wal" "$WV_DB-shm" 2>/dev/null || true
        _WV_DB_READY=""
        # Remove .weave/ state files (preserve archive/)
        rm -f "$WEAVE_DIR/state.sql" 2>/dev/null || true
        rm -f "$WEAVE_DIR/nodes.jsonl" 2>/dev/null || true
        rm -f "$WEAVE_DIR/edges.jsonl" 2>/dev/null || true
        rm -f "$WEAVE_DIR/health.log" 2>/dev/null || true
        rm -rf "$WEAVE_DIR/cache" 2>/dev/null || true
        mkdir -p "$WEAVE_DIR"
        db_init
        wv_delta_init "$WV_DB"
        echo -e "${GREEN}✓ Initialized Weave at $WEAVE_DIR (clean slate)${NC}"
        echo "  Hot zone: $WV_HOT_ZONE"
        return
    fi

    # Reboot recovery: hot zone DB is gone but state.sql exists on disk
    if [ ! -f "$WV_DB" ] && [ -f "$WEAVE_DIR/state.sql" ]; then
        echo -e "${YELLOW}Hot zone database missing (likely reboot) — recovering from state.sql${NC}" >&2
        wv_policy_verdict init_preserves_existing_graph allow no "" "rehydrates the committed graph rather than replacing it"
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
            wv_policy_verdict init_preserves_existing_graph deny yes "" \
                "initialising over a graph holding nodes destroys it"
            echo -e "${RED}Error: Database already exists with $count nodes.${NC}" >&2
            echo "Use 'wv init --force' to reinitialize (destroys existing data)." >&2
            echo "Use 'wv load' to reload from .weave/state.sql." >&2
            return 1
        fi
    fi
    wv_policy_verdict init_preserves_existing_graph allow no "" "no graph with nodes to overwrite"

    mkdir -p "$WEAVE_DIR"
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

# _add_dedup_check — Warn if similar non-done nodes or exact recent done nodes exist.
# Returns 1 if a likely duplicate is found. With a third argument (the bypass
# flag in effect) it still evaluates, records the override, and returns 0.
_add_dedup_check() {
    local text="$1"
    local duplicate_hint="${2:-Use --force to create anyway}"
    local bypass="${3:-}"
    db_ensure
    # Similar open nodes by IDF-weighted word overlap (wv-c2d02a): the share of
    # the new text's rare-word weight that an open node also contains, flagged
    # at 0.45. The previous rule ANDed the first five words longer than four
    # characters in one FTS5 MATCH, so a rewording that changed one of them was
    # never caught. On the graph's own history (11 real duplicate pairs, 80
    # distinct open nodes) this catches 6/11 where that caught 5/11 - all five
    # included - and wrongly flags 8/80 where that flagged 19/80. Weights count
    # the new text as a document, as the measurement did; texts with fewer than
    # two long words are not compared, and a match needs two shared long words.
    # Prints id|text|status, best first.
    local similar=""
    similar=$(python3 - "$WV_DB" "$text" <<'PY' 2>/dev/null || true
import math, re, sqlite3, sys
db_path, new_text = sys.argv[1], sys.argv[2]
words = lambda t: {w.lower() for w in re.split(r"[^0-9A-Za-z]+", t or "") if len(w) > 4}
new = words(new_text)
if len(new) < 2:
    sys.exit(0)
rows = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True).execute(
    "SELECT id, text, status FROM nodes").fetchall()
df = {}
for _, text, _ in rows:
    for w in words(text):
        df[w] = df.get(w, 0) + 1
n_docs = len(rows) + 1
idf = {w: math.log(n_docs / (1 + df.get(w, 0) + 1)) for w in new}
total = sum(idf.values()) or 1.0
scored = []
for node_id, text, status in rows:
    if status == "done":
        continue
    shared = new & words(text)
    score = sum(idf[w] for w in shared) / total
    # Two shared long words at least: in a small graph every word weighs about
    # the same, so one common word ("active") scored 0.5 between distinct
    # nodes. On the graph's history this guard changes neither number above.
    if score >= 0.45 and len(shared) >= 2:
        scored.append((score, node_id, text, status))
for _, node_id, text, status in sorted(scored, reverse=True)[:3]:
    print(f"{node_id}|{' '.join(text.split())}|{status}")
PY
)
    if [ -n "$similar" ] && [ -n "$bypass" ]; then
        wv_policy_verdict add_duplicate_check allow unknown "$bypass" "similar open node exists"
        return 0
    fi
    if [ -n "$similar" ]; then
        wv_policy_verdict add_duplicate_check deny unknown "" "similar open node exists"
        echo -e "${YELLOW}⚠ Similar active nodes exist:${NC}" >&2
        echo "$similar" | while IFS='|' read -r sid stext sstatus; do
            echo -e "  ${CYAN}$sid${NC} [$sstatus]: $stext" >&2
        done
        echo -e "${YELLOW}  ${duplicate_hint}${NC}" >&2
        return 1
    fi

    local exact_done=""
    local escaped_text
    escaped_text=$(sql_escape "$text")
    exact_done=$(db_query "
        SELECT id, text, status
        FROM nodes
        WHERE status = 'done'
        AND lower(trim(text)) = lower(trim('$escaped_text'))
        AND created_at >= datetime('now', '-30 days')
        ORDER BY updated_at DESC, created_at DESC
        LIMIT 3;
    " 2>/dev/null || echo "")
    if [ -n "$exact_done" ] && [ -n "$bypass" ]; then
        wv_policy_verdict add_duplicate_check allow unknown "$bypass" "matching node closed within 30 days"
        return 0
    fi
    if [ -n "$exact_done" ]; then
        wv_policy_verdict add_duplicate_check deny unknown "" "matching node closed within 30 days"
        echo -e "${YELLOW}⚠ Matching completed nodes exist:${NC}" >&2
        echo "$exact_done" | while IFS='|' read -r sid stext sstatus; do
            echo -e "  ${CYAN}$sid${NC} [$sstatus]: $stext" >&2
        done
        echo -e "${YELLOW}  ${duplicate_hint}${NC}" >&2
        return 1
    fi
    # A gate that examined the call and let it through says so: silence is not
    # an allow, and a call is countable only when every applicable rule spoke
    # (wv-15422b).
    wv_policy_verdict add_duplicate_check allow no "" "no similar open or recently closed node"

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
    local standalone=false
    local parent=""
    local format="text"
    local criteria=""
    local risks_flag=""
    local verification_plan=""
    # --id reconstructs a node under an id the graph has lost, so a pushed
    # Weave-ID trailer stops pointing at nothing (wv-0f1092). Empty for every
    # ordinary add, which keeps generating a fresh id.
    local reconstruct_id=""

    shift || true
    while [ $# -gt 0 ]; do
        case "$1" in
            --status=*) status="${1#*=}" ;;
            --metadata=*) metadata="${1#*=}" ;;
            --alias=*) alias="${1#*=}" ;;
            --parent=*) parent="${1#*=}" ;;
            --gh) create_gh=true ;;
            --force) force=true ;;
            --standalone) force=true; standalone=true ;;
            --json) format="json" ;;
            --criteria=*) criteria="${1#*=}" ;;
            --risks=*) risks_flag="${1#*=}" ;;
            --verification-plan=*) verification_plan="${1#*=}" ;;
            --id=*) reconstruct_id="${1#*=}" ;;
            --*) _wv_reject_arg add "$1"; return 1 ;;
            *) text="$text $1" ;;
        esac
        shift
    done

    if [ -z "$text" ]; then
        echo -e "${RED}Error: text required${NC}" >&2
        echo "Usage: wv add \"task description\" [--status=todo|active|done|blocked] [--parent=<id>] [--gh] [--force] [--standalone] [--criteria=\"c1|c2\"] [--risks=low|medium|high|none] [--verification-plan=\"...\"]" >&2
        return 1
    fi

    validate_status "$status" || return 1

    # Merge --criteria and --risks into metadata before JSON validation.
    # --criteria="c1|c2|c3"  → done_criteria: ["c1","c2","c3"]
    # --risks=<level>         → risk_level + risks: [] (all levels seed empty list so pre-claim hook's has("risks") check passes)
    if [ -n "$criteria" ]; then
        local criteria_json
        criteria_json=$(printf '%s' "$criteria" | python3 -c "
import sys, json
raw = sys.stdin.read()
items = [s.strip() for s in raw.split('|') if s.strip()]
print(json.dumps(items))
" 2>/dev/null || echo "[]")
        metadata=$(echo "$metadata" | jq --argjson c "$criteria_json" '. + {done_criteria: $c}' 2>/dev/null || echo "$metadata")
    fi
    if [ -n "$risks_flag" ]; then
        # wv-cccf70: a value outside the enum used to be accepted silently and
        # store nothing; wv-c0c51e: 'critical' was accepted and stored although
        # the contract (and so the Delta v2 sidecar) does not admit it. The
        # enum is the contract's, through the one validator.
        validate_risk_level "$risks_flag" "--risks" || return 1
        metadata=$(echo "$metadata" | jq --arg r "$risks_flag" '. + {risks: [], risk_level: $r}' 2>/dev/null || echo "$metadata")
    fi
    if [ "$standalone" = true ]; then
        metadata=$(echo "$metadata" | jq '. + {standalone: true}' 2>/dev/null || echo "$metadata")
    fi
    # wv-734186: verification-method/verification-evidence were only ever
    # askable at wv done close time -- "what would count as done" is worth
    # answering before starting, not discovered as a fresh question once
    # the work is already finished. --verification-plan is deliberately a
    # SEPARATE field from the close-time verification_method/
    # verification_evidence (which report what actually happened) -- it
    # records the upfront intent, and pre-close-verification.sh's own
    # rejection hint surfaces it back at close time as a reminder.
    if [ -n "$verification_plan" ]; then
        metadata=$(echo "$metadata" | jq --arg vp "$verification_plan" '. + {verification_plan: $vp}' 2>/dev/null || echo "$metadata")
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
    validate_metadata_risk_level "$metadata" "--metadata" || return 1
    validate_metadata_canonical_numbers "$metadata" "--metadata" || return 1

    # Guard the direct create-and-claim path. `wv work` and the pre-claim hook
    # already require claim-ready metadata; direct `wv add --status=active`
    # should not bypass that gate unless the caller explicitly forces it.
    if [ "$status" = "active" ]; then
        local has_done_criteria has_risks
        has_done_criteria=$(echo "$metadata" | jq -r '
            if has("done_criteria") | not then "false"
            elif (.done_criteria | type) == "array" then (if (.done_criteria | length) > 0 then "true" else "false" end)
            elif (.done_criteria | type) == "string" then (if ((.done_criteria | gsub("^\\s+|\\s+$"; "")) | length) > 0 then "true" else "false" end)
            else "false"
            end
        ' 2>/dev/null || echo "false")
        has_risks=$(echo "$metadata" | jq -r 'has("risks")' 2>/dev/null || echo "false")

        # Evaluated under --force too, so an override is recorded rather than silent.
        if { [ "$has_done_criteria" != "true" ] || [ "$has_risks" != "true" ]; } && [ "$force" = "true" ]; then
            wv_policy_verdict active_add_requires_claim_readiness allow yes --force \
                "created active without claim-ready metadata"
        elif [ "$has_done_criteria" != "true" ] || [ "$has_risks" != "true" ]; then
            wv_policy_verdict active_add_requires_claim_readiness deny yes "" \
                "an active node without done criteria and risks cannot be claimed honestly"
            echo -e "${RED}Error: direct active add requires claim-ready metadata${NC}" >&2
            if [ "$has_done_criteria" != "true" ]; then
                echo -e "${CYAN}  Missing: done_criteria${NC}" >&2
            fi
            if [ "$has_risks" != "true" ]; then
                echo -e "${CYAN}  Missing: risks${NC}" >&2
            fi
            echo -e "${CYAN}  Use: wv add \"...\" --status=active --criteria=\"c1|c2\" --risks=low${NC}" >&2
            echo -e "${CYAN}  Or:  wv add \"...\" && wv work <id>${NC}" >&2
            echo -e "${CYAN}  Use --force only for intentional low-level setup or tests${NC}" >&2
            return 1
        else
            wv_policy_verdict active_add_requires_claim_readiness allow no "" "created active with done criteria and risks"
        fi
    else
        wv_policy_verdict active_add_requires_claim_readiness allow no "" "not created active"
    fi

    # Orphan prevention: require --parent when active epics exist (skip with --force).
    # Runs before the node is created so a rejected `wv add` never prints a
    # confirmation for an id that gets rolled back (an agent parsing stdout would
    # otherwise record an id that no longer exists).
    # Evaluated under --force/--standalone too: an override is recorded as a
    # bypassed allow, so a counted campaign sees it rather than silence.
    if [ -z "$parent" ]; then
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
            if [ -n "$active_epics" ] && [ "$force" = "true" ]; then
                local orphan_bypass="--force"
                [ "$standalone" = "true" ] && orphan_bypass="--standalone"
                wv_policy_verdict orphan_prevention allow yes "$orphan_bypass" \
                    "created without a parent while an epic is open"
            elif [ -n "$active_epics" ]; then
                local epic_list
                epic_list=$(echo "$active_epics" | tr '\n' ' ' | sed 's/ $//')
                echo -e "${RED}Error: --parent required when active epics exist (use --force or --standalone to override)${NC}" >&2
                echo -e "${CYAN}  Active epic(s): $epic_list${NC}" >&2
                # A gate that leaves no trace cannot be measured. The emitter adds
                # the envelope and owns evidence-mode failure, so this call site
                # supplies only what it alone knows -- and does NOT discard the
                # result: a verdict that could not be written is the one event a
                # counted campaign cannot do without.
                wv_policy_verdict orphan_prevention deny yes "" \
                    "a non-epic node created with no parent while an epic is open orphans it"
                echo -e "${CYAN}  Usage: wv add \"...\" --parent=<epic-id>${NC}" >&2
                # Combined preflight: report every other unmet gate now, not on retry
                if [ -z "$alias" ]; then
                    echo -e "${CYAN}  Also missing: --alias=<short-name> (required at claim time)${NC}" >&2
                fi
                return 1
            fi
            [ -n "$active_epics" ] || wv_policy_verdict orphan_prevention allow no "" "no open epic to orphan it from"
            # No active epics — just warn about missing alias
            if [ -z "$alias" ] && [ "$force" != "true" ]; then
                echo -e "${YELLOW}⚠ No alias — use --alias=<name>${NC}" >&2
            fi
        else
            wv_policy_verdict orphan_prevention allow no "" "an epic needs no parent"
        fi
    else
        wv_policy_verdict orphan_prevention allow no "" "created under a parent"
    fi

    # Dedup check: refuse if similar non-done nodes exist (overridden by --force,
    # which is recorded; not applied with --parent). Child nodes naturally share
    # vocabulary with their parent — skip for decomposition.
    if [ -z "$parent" ]; then
        local dedup_bypass=""
        [ "$force" = "true" ] && dedup_bypass="--force"
        [ "$standalone" = "true" ] && dedup_bypass="--standalone"
        if ! _add_dedup_check "$text" "" "$dedup_bypass"; then
            return 1
        fi
    else
        wv_policy_verdict add_duplicate_check allow no "" "not applied to a decomposition child"
    fi

    local id
    if [ -n "$reconstruct_id" ]; then
        # Reconstruction, not creation. The id comes from a commit trailer whose
        # node the graph no longer has, so the checks are the inverse of the
        # usual ones: the format must be a real node id (an ALIAS is not
        # reconstructible and validate_id would resolve one against a live row),
        # and the id must NOT already exist. Overwriting a live node here would
        # turn a recovery into the second loss.
        if [[ ! "$reconstruct_id" =~ ^wv-[a-f0-9]{4,6}$ ]]; then
            wv_policy_refusal input_validation "--id is not a node id"
            echo -e "${RED}Error: --id must be a node id of the form wv-XXXXXX, not an alias ('$reconstruct_id')${NC}" >&2
            return 1
        fi
        local existing
        existing=$(db_query "SELECT status FROM nodes WHERE id='$(sql_escape "$reconstruct_id")';" 2>/dev/null || echo "")
        if [ -n "$existing" ]; then
            wv_policy_verdict reconstruct_never_overwrites deny yes "" \
                "reconstructing an id that still exists would overwrite a live node"
            echo -e "${RED}Error: $reconstruct_id already exists (status: $existing) — refusing to overwrite${NC}" >&2
            echo -e "${YELLOW}  --id reconstructs a node the graph has LOST. A live id is not lost.${NC}" >&2
            echo -e "${YELLOW}  Inspect it with: wv show $reconstruct_id${NC}" >&2
            return 1
        fi
        wv_policy_verdict reconstruct_never_overwrites allow no "" "the id is lost, not live"
        id="$reconstruct_id"
    else
        wv_policy_verdict reconstruct_never_overwrites allow no "" "a new id, nothing to overwrite"
        id=$(generate_id)
    fi
    local original_text="$text"
    local original_metadata="$metadata"

    # Escape single quotes in text and metadata. wv-360528: $text and $metadata
    # are SQL-escaped IN PLACE for the INSERT below, so every later reader must
    # use the original_* copies. Anything echoed to the user or handed to gh
    # that reads the mutated variable prints doubled apostrophes.
    text="${text//\'/\'\'}"
    metadata="${metadata//\'/\'\'}"

    local alias_sql="NULL"
    if [ -n "$alias" ]; then
        alias_sql="'$(sql_escape "$alias")'"
    fi
    db_query "INSERT INTO nodes (id, text, status, metadata, alias) VALUES ('$id', '$text', '$status', '$metadata', $alias_sql);"

    # Stamp promoted_at on finding nodes (cannot use SQL trigger — virtual column +
    # warp session trigger interaction crashes SQLite 3.46)
    db_query "UPDATE nodes SET metadata = json_patch(COALESCE(metadata,'{}'), json_object('promoted_at', strftime('%Y-%m-%dT%H:%M:%SZ', 'now')))
              WHERE id = '$id'
                AND json_extract(metadata, '$.type') = 'finding'
                AND json_extract(metadata, '$.promoted_at') IS NULL;" 2>/dev/null || true

    # The creation line moved below the durability gate (wv-18841c) so it cannot
    # announce a node that failed to persist. It stays ahead of the id on stdout.

    # Link to parent if --parent provided
    if [ -n "$parent" ]; then
        cmd_link "$id" "$parent" --type=implements 2>/dev/null
        echo -e "${GREEN}✓${NC} Linked to parent $parent" >&2
    fi

    # Creating a node directly in active status IS a claim (Pattern B: WorkClaimed
    # event) — mirror cmd_work so the first edit is not hard-blocked in discover phase.
    if [ "$status" = "active" ]; then
        local add_agent_id
        add_agent_id="$(sql_escape "$(resolve_agent_id)")"
        db_query "UPDATE nodes
            SET metadata = json_set(COALESCE(metadata,'{}'), '\$.claimed_by', '$add_agent_id')
            WHERE id = '$id';" 2>/dev/null || true
        set_primary_node "$id"
        wv_set_phase "execute"
    fi

    # Auto-unblock cascade when created with --status=done
    if [ "$status" = "done" ]; then
        _do_unblock_cascade "$id"
    fi

    # Create matching GitHub issue if --gh flag is set
    if [ "$create_gh" = true ] && command -v gh >/dev/null 2>&1; then
        # wv-360528: the unescaped copies — the escaped $text became the GitHub
        # issue title verbatim, and the escaped $metadata was re-escaped inside
        # the helper before its UPDATE, doubling apostrophes in stored metadata.
        _add_create_gh_issue "$id" "$original_text" "$original_metadata" "$alias"
    fi

    # Durability gate (wv-18841c), after the parent link, the claim and the
    # GitHub issue so it covers every mutation rather than only the INSERT.
    # Unforced on purpose: within the throttle window auto_sync legitimately
    # skips and reports success, and a skip is not a failure to announce.
    persist_or_refuse "node $id" || return 1

    if [ -n "$alias" ]; then
        echo -e "${GREEN}✓${NC} $id ($alias): $original_text" >&2
    else
        echo -e "${GREEN}✓${NC} $id: $original_text" >&2
    fi

    if [ "$format" = "json" ]; then
        jq -n --arg id "$id" --arg text "$original_text" --arg status "$status" \
            '{"id": $id, "text": $text, "status": $status}'
    else
        echo "$id"
    fi
}

# ═══════════════════════════════════════════════════════════════════════════
# Graph-native memory commands
# ═══════════════════════════════════════════════════════════════════════════

_memory_usage() {
    cat >&2 <<'EOF'
Usage:
  wv remember <text> [--kind=project] [--scope=repo] [--source-agent=name] [--supersedes=<id>] [--json]
  wv memory recall [--agent=current|all|name] [--json]
      # --agent is caller provenance only; recall is agent-agnostic and never filters.
      # The resolved caller is echoed on stderr; stdout is the same memory set for every agent.
  wv memory render [--agent=all|current|claude|claude-memory|copilot|codex|codex-memory|agents|workflow] [--base-dir=DIR] [--path=PATH] [--json]
  wv memory scan --source=claude|codex|copilot|all [--repo-root=DIR] [--json]
  wv memory import --source=claude --path=DIR [--repo-root=DIR] [--json]
  wv memory import --source=codex [--path=DB] [--repo-root=DIR] [--json]
  wv memory crystallize [--dry-run|--apply-reviewed] [--repo-root=DIR] [--json]
EOF
}

_memory_operating_agent() {
    if [ -n "${WV_OPERATING_AGENT:-}" ]; then
        echo "$WV_OPERATING_AGENT"
    elif [ -n "${WV_AGENT_NAME:-}" ]; then
        echo "$WV_AGENT_NAME"
    elif [ -n "${CODEX_THREAD_ID:-}" ] || [ "${CODEX_CI:-}" = "1" ]; then
        echo "codex"
    elif [ "${COPILOT_AGENT:-}" = "1" ]; then
        echo "copilot"
    elif [ -n "${CLAUDE_PROJECT_DIR:-}" ] || [ -n "${CLAUDE_CODE_SSE_PORT:-}" ]; then
        echo "claude"
    elif command -v resolve_runtime_label >/dev/null 2>&1; then
        resolve_runtime_label 2>/dev/null || echo "native"
    else
        echo "native"
    fi
}

_memory_resolve_agent() {
    local agent="${1:-current}"
    if [ "$agent" = "current" ]; then
        _memory_operating_agent
    else
        echo "$agent"
    fi
}

_memory_recall_json() {
    db_query_json_v2 "
        SELECT id, text, status, metadata
        FROM nodes
        WHERE json_extract(metadata, '\$.type') = 'memory'
          AND COALESCE(json_extract(metadata, '\$.mem_status'), 'active') = 'active'
        ORDER BY created_at ASC, id ASC;
    "
}

_memory_markdown_block() {
    local entries="$1"
    printf '%s\n' "$entries" | jq -r '
        [
            "<!-- ── BEGIN WEAVE:MEMORY ── managed by wv memory render, do not edit manually -->",
            "## WEAVE:MEMORY",
            "",
            "Authority: weave graph. Capture records dynamic agent provenance, but recall is agent-agnostic. Lifecycle field: metadata.mem_status. Recall: `wv memory recall --agent=all --json`. Capture: `wv remember <text>`.",
            "",
            (if length == 0 then "_No active graph memory._" else (.[] | "- [`\(.id)`] \(.text) (verified: \(.metadata.verified_at // "unknown"))") end),
            "<!-- ── END WEAVE:MEMORY ── -->"
        ] | .[]
    '
}

_memory_render_markdown_file() {
    local entries="$1" path="$2"
    local target_dir tmp block
    target_dir=$(dirname "$path")
    mkdir -p "$target_dir"
    block=$(_memory_markdown_block "$entries") || return 1
    tmp=$(mktemp "$target_dir/.weave-memory.XXXXXX")
    if [ -f "$path" ]; then
        python3 - "$path" "$tmp" "$block" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
tmp = pathlib.Path(sys.argv[2])
block = sys.argv[3]
start = "<!-- ── BEGIN WEAVE:MEMORY ──"
end = "<!-- ── END WEAVE:MEMORY ── -->"
text = path.read_text()
if start in text and end in text:
    prefix = text.split(start, 1)[0]
    suffix = text.split(end, 1)[1]
    tmp.write_text(prefix + block + suffix)
else:
    sep = "" if text.endswith("\n") else "\n"
    tmp.write_text(text + sep + "\n" + block + "\n")
PY
    else
        printf '%s\n' "$block" > "$tmp"
    fi
    mv "$tmp" "$path"
}

# AGENTS.md is the universal instructions file and, in a consumer repository,
# the user's own (wv-6ef83b; never written by the projector since 04feaa432).
# So the agents projection opts in by marker: it refreshes an existing
# WEAVE:MEMORY block and otherwise leaves the file alone, never creating or
# appending one. Returns 3 when skipped so the caller does not report a render.
_memory_render_marked_only() {
    local entries="$1" path="$2"
    if [ -f "$path" ] && grep -qF -- "<!-- ── BEGIN WEAVE:MEMORY ──" "$path" \
        && grep -qF -- "<!-- ── END WEAVE:MEMORY ── -->" "$path"; then
        _memory_render_markdown_file "$entries" "$path"
        return
    fi
    return 3
}

_memory_render_codex_json() {
    local entries="$1" path="$2"
    local target_dir tmp
    target_dir=$(dirname "$path")
    mkdir -p "$target_dir"
    if [ ! -f "$path" ]; then
        printf '%s\n' '{"schema":"weave.codex.v1"}' > "$path"
    fi
    tmp=$(mktemp "$target_dir/.weave-memory.XXXXXX")
    if ! jq --argjson entries "$entries" '
        . + {
            memory: {
                authority: "weave-graph",
                lifecycle_field: "metadata.mem_status",
                policy: "codex-local memory is evidence; weave graph is authority",
                recall: {
                    command: "./scripts/wv memory recall --agent=all --json",
                    fallback: "$HOME/.local/bin/wv memory recall --agent=all --json"
                },
                capture: {
                    command: "./scripts/wv remember --json",
                    fallback: "$HOME/.local/bin/wv remember --json"
                },
                scan: {
                    command: "./scripts/wv memory scan --source=codex --json",
                    fallback: "$HOME/.local/bin/wv memory scan --source=codex --json"
                },
                import: {
                    command: "./scripts/wv memory import --source=codex --json",
                    fallback: "$HOME/.local/bin/wv memory import --source=codex --json"
                },
                crystallize: {
                    command: "./scripts/wv memory crystallize --json",
                    fallback: "$HOME/.local/bin/wv memory crystallize --json"
                },
                entries: $entries
            }
        }
    ' "$path" > "$tmp"; then
        rm -f "$tmp"
        echo -e "${RED}Error: failed to render memory into $path${NC}" >&2
        return 1
    fi
    mv "$tmp" "$path"
}

_memory_projection_path() {
    local projection="$1" base_dir="$2"
    case "$projection" in
        claude) echo "$base_dir/CLAUDE.md" ;;
        claude-memory) echo "$base_dir/.claude/MEMORY.md" ;;
        codex) echo "$base_dir/.codex/weave.json" ;;
        codex-memory) echo "$base_dir/.codex/MEMORY.md" ;;
        copilot) echo "$base_dir/.github/copilot-instructions.md" ;;
        agents) echo "$base_dir/AGENTS.md" ;;
        workflow) echo "$base_dir/WORKFLOW.md" ;;
        *) return 1 ;;
    esac
}

_memory_render_projection() {
    local projection="$1" entries="$2" path="$3"
    case "$projection" in
        codex) _memory_render_codex_json "$entries" "$path" ;;
        claude|claude-memory|codex-memory|copilot|workflow) _memory_render_markdown_file "$entries" "$path" ;;
        agents) _memory_render_marked_only "$entries" "$path" ;;
        *)
            echo -e "${RED}Error: unsupported memory projection '$projection'${NC}" >&2
            return 1
            ;;
    esac
}

_memory_repo_slug() {
    local repo_root="$1"
    printf '%s' "$repo_root" | tr '/' '-'
}

_memory_file_hash() {
    sha256sum "$1" 2>/dev/null | awk '{print $1}'
}

_memory_scan_claude() {
    local repo_root="$1"
    local slug project_dir
    slug=$(_memory_repo_slug "$repo_root")
    project_dir="$HOME/.claude/projects/$slug"
    if [ ! -d "$project_dir" ]; then
        echo '[]'
        return 0
    fi
    find "$project_dir" -type f \( -path "*/memory/*.md" -o -name "MEMORY.md" -o -name "*.jsonl" \) -print 2>/dev/null \
        | sort \
        | jq -Rn --arg repo_root "$repo_root" '
            [inputs | {
                source_agent: "claude",
                source_kind: (if test("\\.md$") then "memory_file" else "session" end),
                source_path: .,
                repo_root: $repo_root
            }]
        '
}

_memory_scan_codex() {
    local repo_root="$1"
    local codex_dir="$HOME/.codex"
    if [ ! -d "$codex_dir" ]; then
        echo '[]'
        return 0
    fi
    local observations='[]' repo_thread_ids='[]' db table cols rows row rollout memrows

    # state_*.sqlite is the repo-scoped index: thread rows carry cwd and
    # rollout_path. Only rows whose cwd matches this repo are evidence for this
    # graph; unrelated Codex threads stay out of the observation stream.
    while IFS= read -r db; do
        [ -s "$db" ] || continue
        while IFS= read -r table; do
            [ -n "$table" ] || continue
            cols=$(sqlite3 "$db" "PRAGMA table_info('$table');" 2>/dev/null | awk -F'|' '{print $2}' | tr '\n' ' ')
            case " $cols " in
                *" cwd "*)
                    rows=$(sqlite3 -json "$db" "
                        SELECT rowid, *
                        FROM '$table'
                        WHERE cwd = '$(sql_escape "$repo_root")';
                    " 2>/dev/null || echo '[]')
                    observations=$(jq -nc \
                        --argjson obs "$observations" \
                        --argjson rows "${rows:-[]}" \
                        --arg source_path "$db" \
                        --arg repo_root "$repo_root" \
                        '$obs + ($rows | map({
                            source_agent: "codex",
                            source_kind: "thread_db",
                            source_path: $source_path,
                            source_session: ((.id // .thread_id // .conversation_id // .rowid // "") | tostring),
                            title: (.title // null),
                            memory_mode: (.memory_mode // null),
                            rollout_path: (.rollout_path // null),
                            repo_root: $repo_root
                        }))')
                    repo_thread_ids=$(jq -nc \
                        --argjson ids "$repo_thread_ids" \
                        --argjson rows "${rows:-[]}" \
                        '($ids + ($rows | map((.id // .thread_id // .conversation_id // "") | tostring) | map(select(length > 0)))) | unique')
                    while IFS= read -r row; do
                        rollout=$(printf '%s' "$row" | jq -r '.rollout_path // empty')
                        [ -n "$rollout" ] && [ -f "$rollout" ] || continue
                        observations=$(jq -nc \
                            --argjson obs "$observations" \
                            --arg source_path "$rollout" \
                            --arg repo_root "$repo_root" \
                            '$obs + [{
                                source_agent: "codex",
                                source_kind: "rollout",
                                source_path: $source_path,
                                repo_root: $repo_root
                            }]')
                    done < <(printf '%s\n' "$rows" | jq -c '.[]?')
                    ;;
            esac
        done < <(sqlite3 "$db" "SELECT name FROM sqlite_master WHERE type='table';" 2>/dev/null | sort)
    done < <(find "$codex_dir" -maxdepth 1 -type f -name "state_*.sqlite" -print 2>/dev/null | sort)

    # memories_*.sqlite stores Codex's own memory pipeline artifacts. Import only
    # rows from stage1_outputs when present and keep them as evidence, not active
    # graph memory.
    while IFS= read -r db; do
        [ -s "$db" ] || continue
        if sqlite3 "$db" "SELECT name FROM sqlite_master WHERE type='table' AND name='stage1_outputs';" 2>/dev/null | grep -qx stage1_outputs; then
            cols=$(sqlite3 "$db" "PRAGMA table_info('stage1_outputs');" 2>/dev/null | awk -F'|' '{print $2}' | tr '\n' ' ')
            case " $cols " in
                *" cwd "*)
                    memrows=$(sqlite3 -json "$db" "
                        SELECT rowid, *
                        FROM stage1_outputs
                        WHERE cwd = '$(sql_escape "$repo_root")';
                    " 2>/dev/null || echo '[]')
                    ;;
                *" thread_id "*)
                    memrows=$(sqlite3 -json "$db" "SELECT rowid, * FROM stage1_outputs;" 2>/dev/null \
                        | jq -c --argjson ids "$repo_thread_ids" '[.[] | select((.thread_id // "" | tostring) as $t | $ids | index($t))]' 2>/dev/null || echo '[]')
                    ;;
                *)
                    # No repo identity in this table shape. Skip rather than
                    # importing cross-repo Codex memory as evidence for this graph.
                    memrows='[]'
                    ;;
            esac
            observations=$(jq -nc \
                --argjson obs "$observations" \
                --argjson rows "${memrows:-[]}" \
                --arg source_path "$db" \
                --arg repo_root "$repo_root" \
                '$obs + ($rows | map({
                    source_agent: "codex",
                    source_kind: "memory_db",
                    source_path: $source_path,
                    source_session: ((.job_id // .thread_id // .rowid // "") | tostring),
                    excerpt: ((.output // .text // .content // .summary // .memory // null) | if . == null then null else tostring end),
                    repo_root: $repo_root
                }))')
        fi
    done < <(find "$codex_dir" -maxdepth 1 -type f -name "memories_*.sqlite" -print 2>/dev/null | sort)

    printf '%s\n' "$observations"
}

_memory_scan_copilot() {
    local repo_root="$1"
    local storage_dir="$HOME/.config/Code/User/workspaceStorage"
    if [ ! -d "$storage_dir" ]; then
        echo '[]'
        return 0
    fi
    local observations='[]' wsdir wsjson files
    while IFS= read -r wsjson; do
        [ -f "$wsjson" ] || continue
        if ! jq -r '.. | strings' "$wsjson" 2>/dev/null | sed 's#^file://##' | grep -Fxq -- "$repo_root"; then
            continue
        fi
        wsdir=$(dirname "$wsjson")
        observations=$(jq -nc \
            --argjson obs "$observations" \
            --arg source_path "$wsjson" \
            --arg repo_root "$repo_root" \
            '$obs + [{
                source_agent: "copilot",
                source_kind: "workspace",
                source_path: $source_path,
                repo_root: $repo_root
            }]')
        files=$(find "$wsdir" -type f \( -path "*/chatSessions/*.jsonl" -o -path "*/chatEditingSessions/*/state.json" \) -print 2>/dev/null | sort)
        if [ -n "$files" ]; then
            observations=$(printf '%s\n' "$files" | jq -Rn \
                --argjson obs "$observations" \
                --arg repo_root "$repo_root" \
                '$obs + [inputs | {
                    source_agent: "copilot",
                    source_kind: (if test("chatSessions/.*\\.jsonl$") then "chat" else "editing_state" end),
                    source_path: .,
                    repo_root: $repo_root
                }]')
        fi
    done < <(find "$storage_dir" -mindepth 2 -maxdepth 2 -type f -name "workspace.json" -print 2>/dev/null | sort)
    printf '%s\n' "$observations"
}

_memory_scan_sources() {
    local source="$1" repo_root="$2"
    case "$source" in
        claude) _memory_scan_claude "$repo_root" ;;
        codex) _memory_scan_codex "$repo_root" ;;
        copilot) _memory_scan_copilot "$repo_root" ;;
        all)
            jq -s 'add' \
                <(_memory_scan_claude "$repo_root") \
                <(_memory_scan_codex "$repo_root") \
                <(_memory_scan_copilot "$repo_root")
            ;;
        *)
            echo -e "${RED}Error: unsupported memory scan source '$source'${NC}" >&2
            return 1
            ;;
    esac
}

_memory_import_claude_dir() {
    local path="$1" repo_root="$2" format="$3"
    if [ ! -d "$path" ]; then
        echo -e "${RED}Error: Claude memory import path not found: $path${NC}" >&2
        return 1
    fi
    db_ensure
    db_migrate_fts5 2>/dev/null || true

    local imported='[]' skipped='[]' file text id hash metadata text_sql metadata_sql
    while IFS= read -r file; do
        [ -f "$file" ] || continue
        text=$(sed '/^#/d; /^$/d' "$file" | head -20 | tr '\n' ' ' | sed 's/[[:space:]][[:space:]]*/ /g; s/^ //; s/ $//')
        [ -n "$text" ] || text=$(basename "$file")
        hash=$(_memory_file_hash "$file")
        # Idempotency: skip if a memory node with this source_hash already exists.
        if [ -n "$(db_query "SELECT 1 FROM nodes WHERE json_extract(metadata,'\$.source_hash')='$hash' LIMIT 1;" 2>/dev/null)" ]; then
            skipped=$(printf '%s\n' "$skipped" | jq --arg path "$file" '. + [{source_path: $path}]')
            continue
        fi
        id=$(generate_id)
        metadata=$(jq -nc \
            --arg repo_root "$repo_root" \
            --arg source_path "$file" \
            --arg source_hash "$hash" \
            '{
                type: "memory",
                kind: "project",
                scope: "repo",
                mem_status: "candidate",
                source_agent: "claude",
                source_kind: "memory_file",
                source_path: $source_path,
                source_hash: $source_hash,
                repo_root: $repo_root,
                observed_at: (now | strftime("%Y-%m-%dT%H:%M:%SZ"))
            }')
        text_sql=$(sql_escape "$text")
        metadata_sql=$(sql_escape "$metadata")
        db_query "INSERT INTO nodes (id, text, status, metadata) VALUES ('$id', '$text_sql', 'done', '$metadata_sql');"
        imported=$(printf '%s\n' "$imported" | jq --arg id "$id" --arg path "$file" '. + [{id: $id, source_path: $path}]')
    done < <(find "$path" -maxdepth 1 -type f -name "*.md" -print 2>/dev/null | sort)

    if [ "$format" = "json" ]; then
        jq -n --argjson imported "$imported" --argjson skipped "$skipped" \
            '{imported: $imported, count: ($imported | length), skipped: ($skipped | length)}'
    else
        printf '%s\n' "$imported" | jq -r '.[] | "✓ Imported \(.source_path) -> \(.id)"'
        local n_skipped; n_skipped=$(printf '%s\n' "$skipped" | jq 'length')
        [ "$n_skipped" -gt 0 ] && echo "⏭  Skipped $n_skipped already-imported file(s) (source_hash match)"
    fi
    auto_sync_or_warn
}

_memory_import_codex() {
    local path="$1" repo_root="$2" format="$3"
    db_ensure
    db_migrate_fts5 2>/dev/null || true

    local observations imported='[]' skipped='[]'
    observations=$(_memory_scan_codex "$repo_root") || return 1
    if [ -n "$path" ]; then
        observations=$(printf '%s\n' "$observations" | jq --arg path "$path" '[.[] | select(.source_path == $path)]')
    fi

    local obs text source_path source_session hash id metadata text_sql metadata_sql
    while IFS= read -r obs; do
        [ -n "$obs" ] || continue
        text=$(printf '%s\n' "$obs" | jq -r '.excerpt // empty' | head -20 | tr '\n' ' ' | sed 's/[[:space:]][[:space:]]*/ /g; s/^ //; s/ $//')
        [ -n "$text" ] || continue
        source_path=$(printf '%s\n' "$obs" | jq -r '.source_path // ""')
        source_session=$(printf '%s\n' "$obs" | jq -r '.source_session // ""')
        hash=$(printf '%s' "$repo_root|$source_path|$source_session|$text" | sha256sum | awk '{print $1}')
        # Idempotency: skip if a memory node with this source_hash already exists.
        if [ -n "$(db_query "SELECT 1 FROM nodes WHERE json_extract(metadata,'\$.source_hash')='$hash' LIMIT 1;" 2>/dev/null)" ]; then
            skipped=$(printf '%s\n' "$skipped" | jq --arg path "$source_path" '. + [{source_path: $path}]')
            continue
        fi
        id=$(generate_id)
        metadata=$(jq -nc \
            --arg repo_root "$repo_root" \
            --arg source_path "$source_path" \
            --arg source_session "$source_session" \
            --arg source_hash "$hash" \
            '{
                type: "memory",
                kind: "project",
                scope: "repo",
                mem_status: "candidate",
                source_agent: "codex",
                source_kind: "memory_db",
                source_path: $source_path,
                source_session: $source_session,
                source_hash: $source_hash,
                repo_root: $repo_root,
                observed_at: (now | strftime("%Y-%m-%dT%H:%M:%SZ"))
            }')
        text_sql=$(sql_escape "$text")
        metadata_sql=$(sql_escape "$metadata")
        db_query "INSERT INTO nodes (id, text, status, metadata) VALUES ('$id', '$text_sql', 'done', '$metadata_sql');"
        imported=$(printf '%s\n' "$imported" | jq --arg id "$id" --arg path "$source_path" --arg session "$source_session" '. + [{id: $id, source_path: $path, source_session: $session}]')
    done < <(printf '%s\n' "$observations" | jq -c '.[] | select(.source_agent == "codex" and .source_kind == "memory_db")')

    if [ "$format" = "json" ]; then
        jq -n --argjson imported "$imported" --argjson skipped "$skipped" \
            '{imported: $imported, count: ($imported | length), skipped: ($skipped | length)}'
    else
        printf '%s\n' "$imported" | jq -r '.[] | "✓ Imported \(.source_path) -> \(.id)"'
        local n_skipped; n_skipped=$(printf '%s\n' "$skipped" | jq 'length')
        [ "$n_skipped" -gt 0 ] && echo "⏭  Skipped $n_skipped already-imported row(s) (source_hash match)"
    fi
    auto_sync_or_warn
}

# ── S4 crystallization ───────────────────────────────────────────────────────
# Group candidate memory, deduplicate, verify references, mark stale/superseded/
# contradicted, and promote reviewed candidates. Conservative + deterministic:
# fuzzy (FTS) overlap is reported only; status changes come from deterministic
# signals (exact source_hash, missing path/flag, explicit reviewed flag).

_memory_candidates_json() {
    db_query_json_v2 "
        SELECT id, text, metadata
        FROM nodes
        WHERE json_extract(metadata, '\$.type') = 'memory'
          AND json_extract(metadata, '\$.mem_status') = 'candidate'
        ORDER BY created_at ASC, id ASC;
    "
}

# Up to 3 FTS terms (>4 chars), sanitized for fts5 MATCH. Reuses the wv-done
# learning-overlap extraction so dedup behaves consistently across surfaces.
# Terms are taken positionally (first three words over four characters) and
# AND-ed by FTS5. Selecting the LONGEST words instead was tried and reverted:
# it optimises for distinctiveness within one memory, but dedup needs terms
# likely to appear in BOTH records, and the change silently stopped detecting a
# genuine opposite-polarity contradiction whose shared vocabulary sat early in
# each text. The false-positive guards live in the caller instead.
_memory_fts_terms() {
    echo "$1" | tr -cs '[:alnum:]' ' ' \
        | awk '{for(i=1;i<=NF;i++) if(length($i)>4){print $i;c++;if(c>=3)exit}}' \
        | sed 's/[(){}*:^~"]//g' | tr '\n' ' '
}

# Sets _cr_dup_id, _cr_dup_kind, _cr_contradicts for one candidate.
# Tier 1 (deterministic): exact source_hash collision with another memory node.
# Tier 2 (fuzzy): FTS overlap vs learnings/findings/active memory; opposite
# polarity flags a contradiction.
_memory_crystallize_dedup_one() {
    local id="$1" text="$2" hash="$3"
    _cr_dup_id=""; _cr_dup_kind=""; _cr_contradicts=""
    if [ -n "$hash" ] && [ "$hash" != "null" ]; then
        # Only an EARLIER-INSERTED same-hash node supersedes this one (rowid is
        # monotonic with insertion; created_at ties at second granularity and id
        # is random) so identical re-imports collapse onto the first, never mutually.
        local hmatch
        hmatch=$(db_query "
            SELECT n2.id FROM nodes n2, nodes self
            WHERE self.id = '$id' AND n2.id != self.id
              AND json_extract(n2.metadata,'\$.type')='memory'
              AND json_extract(n2.metadata,'\$.source_hash')='$hash'
              AND n2.rowid < self.rowid
            LIMIT 1;" 2>/dev/null || true)
        if [ -n "$hmatch" ]; then
            _cr_dup_id="$hmatch"; _cr_dup_kind="source_hash"
            return 0
        fi
    fi
    local terms term_count
    terms=$(_memory_fts_terms "$text")
    term_count=$(printf '%s\n' "$terms" | tr ' ' '\n' | grep -c '[^[:space:]]' || true)
    # Terms are AND-ed by FTS5, so three of them is a real conjunction while one
    # or two is close to a single shared noun -- exactly the "shares only the
    # site name" false merge the finding recorded. Below three, propose nothing.
    if [ -z "$terms" ] || [ "${term_count:-0}" -lt 3 ]; then
        return 0
    fi
    # Carry the candidate's own memory kind into the comparison: a feedback note
    # and a project note that happen to share vocabulary are not the same entry,
    # and proposing a merge across them misfiles the one a reader goes looking
    # for. Kind is only compared against other MEMORY nodes; a learning or
    # finding is a different class of record and is matched on terms alone.
    local cand_kind
    cand_kind=$(db_query "SELECT COALESCE(json_extract(metadata,'\$.kind'),'') FROM nodes WHERE id='$id';" 2>/dev/null || true)
    local cand_kind_esc
    cand_kind_esc=$(printf '%s' "$cand_kind" | sed "s/'/''/g")
    local fmatch
    # ORDER BY rank (bm25) so the proposal is the BEST match and is stable --
    # a bare LIMIT 1 returned whichever row SQLite produced first, so the same
    # candidate could name a different target between runs.
    fmatch=$(db_query "
        SELECT f.id FROM nodes_fts f
        JOIN nodes n ON n.id = f.id
        WHERE nodes_fts MATCH '$terms'
          AND f.id != '$id'
          AND ( json_extract(n.metadata,'\$.learning') IS NOT NULL
                OR json_extract(n.metadata,'\$.type')='finding'
                OR ( json_extract(n.metadata,'\$.type')='memory'
                     AND COALESCE(json_extract(n.metadata,'\$.mem_status'),'active')='active'
                     AND COALESCE(json_extract(n.metadata,'\$.kind'),'') = '$cand_kind_esc' ) )
        ORDER BY rank
        LIMIT 1;" 2>/dev/null || true)
    if [ -n "$fmatch" ]; then
        _cr_dup_id="$fmatch"; _cr_dup_kind="fts_overlap"
        local other npol opol
        # The opposing claim lives in metadata.learning (learnings/findings) or in
        # the node text column (remember/import memory). Prefer learning, fall back.
        other=$(db_query_json "SELECT text, metadata FROM nodes WHERE id='$fmatch';" 2>/dev/null \
            | jq -r '.[0] | (try (.metadata | fromjson | .learning) catch null) as $l
                     | (if $l and ($l | length) > 0 then $l else (.text // "") end)' 2>/dev/null || echo "")
        npol=$(_done_polarity "$text")
        opol=$(_done_polarity "$other")
        if [ "$npol" != "0" ] && [ "$opol" != "0" ] && [ "$npol" != "$opol" ]; then
            _cr_contradicts="$fmatch"
        fi
    fi
    return 0
}

# Sets _cr_stale_reason for one candidate (mark-only, never deletes). Verifies
# file-path tokens exist under the repo and that referenced --flags appear in the
# live command surface. Static lookup only — no command execution.
#
# Conservative path detection: a token only counts as a repo-path reference if it
# has BOTH a path separator AND a known source extension. This skips prose slash-
# phrases ("offset/limit", "commit/sync/push", "read/write") and bare basename
# mentions ("wv-config.sh") that real memory text is full of. Existence is checked
# repo-wide by basename so a moved/relocated file is not falsely marked stale —
# only flag when confident it is a path AND confident it is absent.
_memory_crystallize_verify_one() {
    local text="$1" repo_root="$2"
    _cr_stale_reason=""
    local tok base
    for tok in $(echo "$text" | grep -oE '[A-Za-z0-9_.-]+/[A-Za-z0-9_./-]*\.(sh|md|py|json|sql|ya?ml|toml|cfg|txt|db)' 2>/dev/null || true); do
        tok="${tok%[.,;:]}"
        base="${tok##*/}"
        [ -n "$base" ] || continue
        if [ ! -e "$repo_root/$tok" ] && [ ! -e "$tok" ] \
           && [ -z "$(find "$repo_root" -name "$base" -not -path '*/.git/*' -print -quit 2>/dev/null)" ]; then
            _cr_stale_reason="missing path: $tok"
            return 0
        fi
    done
    # Flags are only checked when they sit on a line that also invokes `wv`.
    # A memory quoting `uv sync --all-extras` or the gcloud installer's
    # --path-update is describing ANOTHER tool, and marking it stale because wv
    # has no such flag is a false positive that demotes a correct memory
    # (Finding E mechanism 1).
    #
    # Resolution is against WV_LIB_DIR -- wv's own code, wherever it is
    # installed -- not $repo_root/scripts. That directory only holds wv's
    # source when the repository being crystallized IS memory-system; in any
    # consumer repo it holds that project's scripts, so EVERY wv flag read as
    # unknown and every memory quoting a wv command was marked stale.
    local _cr_flag_surface="${WV_LIB_DIR:-}"
    if [ ! -d "$_cr_flag_surface" ]; then
        _cr_flag_surface="$repo_root/scripts"
    fi
    local flag wv_lines
    wv_lines=$(printf '%s\n' "$text" | grep -E '(^|[^a-zA-Z0-9_-])wv[ 	]' || true)
    if [ -n "$wv_lines" ]; then
        for flag in $(printf '%s\n' "$wv_lines" | grep -oE '\-\-[a-z][a-z-]+' | sort -u || true); do
            if ! grep -rqF -- "$flag" "$_cr_flag_surface" 2>/dev/null; then
                _cr_stale_reason="unknown flag: $flag"
                return 0
            fi
        done
    fi
    return 0
}

# Write a metadata patch onto a node (merges keys, re-escapes once).
_memory_patch_metadata() {
    local id="$1" patch="$2" merged msql
    merged=$(db_query_json "SELECT metadata FROM nodes WHERE id='$id';" 2>/dev/null \
        | jq -c --argjson patch "$patch" '(.[0].metadata // "{}" | fromjson) * $patch')
    msql=$(sql_escape "$merged")
    db_query "UPDATE nodes SET metadata='$msql', updated_at=CURRENT_TIMESTAMP WHERE id='$id';"
}

# Record a semantic edge between two memory/finding nodes (registered types only).
# edges.context is JSON for every writer: readers apply json() to it, and a
# plain string made the E5 causal identity query fail (wv-031d08).
_memory_crystallize_edge() {
    local source="$1" target="$2" type="$3" context_sql
    # A supersedes edge runs old -> new, so its sentence reads target-first
    # ("<new> supersedes <old>"), as wv remember --supersedes words it.
    context_sql=$(sql_escape "$(jq -nc --arg s "$source" --arg t "$target" --arg ty "$type" \
        '{summary: (if $ty == "supersedes" then ($t + " supersedes " + $s) else ($s + " " + $ty + " " + $t) end),
          source: "wv memory crystallize"}')")
    db_query "INSERT OR IGNORE INTO edges (source, target, type, weight, context, created_at)
        VALUES ('$source', '$target', '$type', 1.0, '$context_sql', CURRENT_TIMESTAMP);" 2>/dev/null || true
}

# Create a finding node for an unresolved contradiction between a candidate and
# an existing memory/learning/finding.
_memory_crystallize_finding() {
    local cand="$1" other="$2" id metadata text_sql metadata_sql
    id=$(generate_id)
    metadata=$(jq -nc --arg cand "$cand" --arg other "$other" \
        '{
            type: "finding",
            finding: {
                violation_type: "memory_contradiction",
                root_cause: ("candidate memory " + $cand + " contradicts " + $other),
                proposed_fix: "review both claims; supersede or correct the stale one before promotion",
                confidence: "low",
                fixable: false
            }
        }')
    text_sql=$(sql_escape "Finding: candidate memory $cand contradicts $other (opposite polarity)")
    metadata_sql=$(sql_escape "$metadata")
    db_query "INSERT INTO nodes (id, text, status, metadata) VALUES ('$id', '$text_sql', 'todo', '$metadata_sql');"
    _memory_crystallize_edge "$cand" "$other" "contradicts"
    echo "$id"
}

cmd_remember() {
    local text=""
    local kind="project"
    local scope="repo"
    local source_agent=""
    local format="text"
    local supersedes=""

    while [ $# -gt 0 ]; do
        case "$1" in
            --kind=*) kind="${1#*=}" ;;
            --supersedes=*) supersedes="${1#*=}" ;;
            --scope=*) scope="${1#*=}" ;;
            --source-agent=*) source_agent="${1#*=}" ;;
            --json) format="json" ;;
            --help|-h)
                _memory_usage
                return 0
                ;;
            --*)
                echo -e "${RED}Error: unknown option $1${NC}" >&2
                _memory_usage
                return 1
                ;;
            *)
                if [ -z "$text" ]; then
                    text="$1"
                else
                    text="$text $1"
                fi
                ;;
        esac
        shift
    done

    if [ -z "$text" ]; then
        echo -e "${RED}Error: memory text required${NC}" >&2
        _memory_usage
        return 1
    fi

    if [ -z "$source_agent" ]; then
        source_agent=$(_memory_operating_agent)
    fi

    db_ensure
    db_migrate_fts5 2>/dev/null || true

    # --supersedes=<id> (wv-ffaf3e): a changed claim is a new memory, never an
    # edit. The old one is kept as mem_status=superseded with superseded_by, a
    # tombstone pointing at its successor; render shows only active memory.
    # Only an active memory can be superseded, so a chain has one live head.
    local old_meta=""
    if [ -n "$supersedes" ]; then
        if ! validate_id "$supersedes" 2>/dev/null; then
            echo -e "${RED}Error: --supersedes needs a node id, got '$supersedes'${NC}" >&2
            return 1
        fi
        old_meta=$(db_query_json "SELECT metadata FROM nodes WHERE id='$supersedes';" 2>/dev/null \
            | jq -c '.[0].metadata // empty | fromjson' 2>/dev/null || true)
        if [ -z "$old_meta" ] || [ "$(jq -r '.type // ""' <<< "$old_meta")" != "memory" ]; then
            echo -e "${RED}Error: $supersedes is not a memory node${NC}" >&2
            return 1
        fi
        if [ "$(jq -r '.mem_status // "active"' <<< "$old_meta")" != "active" ]; then
            echo -e "${RED}Error: $supersedes is $(jq -r '.mem_status' <<< "$old_meta"), not active; supersede the live memory in its chain${NC}" >&2
            return 1
        fi
    fi

    local id metadata text_sql metadata_sql now
    id=$(generate_id)
    now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    metadata=$(jq -nc \
        --arg kind "$kind" \
        --arg scope "$scope" \
        --arg source_agent "$source_agent" \
        --arg now "$now" \
        --arg supersedes "$supersedes" \
        '{
            type: "memory",
            kind: $kind,
            scope: $scope,
            mem_status: "active",
            source_agent: $source_agent,
            source_kind: "remember",
            verified_at: $now
        } + (if $supersedes != "" then {supersedes: $supersedes} else {} end)')
    text_sql=$(sql_escape "$text")
    metadata_sql=$(sql_escape "$metadata")

    if [ -z "$supersedes" ]; then
        db_query "INSERT INTO nodes (id, text, status, metadata) VALUES ('$id', '$text_sql', 'done', '$metadata_sql');"
    else
        # One transaction: successor, edge and tombstone land together or not
        # at all. Edge direction follows the registry: target supersedes source.
        local old_sql edge_context_sql
        old_sql=$(sql_escape "$(jq -c --arg new "$id" --arg now "$now" \
            '. + {mem_status: "superseded", superseded_by: $new, superseded_at: $now}' <<< "$old_meta")")
        # JSON like every other edge writer (wv-031d08).
        edge_context_sql=$(sql_escape "$(jq -nc --arg old "$supersedes" --arg new "$id" \
            '{summary: ($new + " supersedes " + $old), source: "wv remember --supersedes"}')")
        db_query "BEGIN IMMEDIATE;
            INSERT INTO nodes (id, text, status, metadata) VALUES ('$id', '$text_sql', 'done', '$metadata_sql');
            INSERT OR IGNORE INTO edges (source, target, type, weight, context, created_at)
                VALUES ('$supersedes', '$id', 'supersedes', 1.0, '$edge_context_sql', CURRENT_TIMESTAMP);
            UPDATE nodes SET metadata='$old_sql', updated_at=CURRENT_TIMESTAMP WHERE id='$supersedes';
            COMMIT;"
    fi

    if [ "$format" = "json" ]; then
        db_query_json_v2 "SELECT id, text, status, metadata FROM nodes WHERE id='$id';" | jq '.[0]'
    else
        echo -e "${GREEN}✓${NC} Remembered $id${supersedes:+ (supersedes $supersedes)}"
    fi

    auto_sync_or_warn
}

cmd_memory() {
    local subcmd="${1:-}"
    shift || true

    case "$subcmd" in
        recall)
            local format="text"
            local agent="current"
            while [ $# -gt 0 ]; do
                case "$1" in
                    --agent=*) agent="${1#*=}" ;;
                    --json) format="json" ;;
                    --help|-h)
                        _memory_usage
                        return 0
                        ;;
                    *)
                        echo -e "${RED}Error: unknown option $1${NC}" >&2
                        _memory_usage
                        return 1
                        ;;
                esac
                shift
            done
            agent=$(_memory_resolve_agent "$agent")
            local memories
            memories=$(_memory_recall_json)
            # --agent is caller/provenance context, never a filter: recall is
            # agent-agnostic and returns the same active graph memory set for
            # every agent value. Report the resolved caller on stderr so the flag
            # is observable, without changing the machine-readable stdout contract
            # (the rendered .codex/weave.json recall command and the recall tests
            # parse the bare JSON array). See wv-55ba1d (F2).
            printf 'recall caller=%s (agent-agnostic; --agent never filters)\n' "$agent" >&2
            if [ "$format" = "json" ]; then
                printf '%s\n' "$memories"
            else
                printf '%s\n' "$memories" | jq -r '.[] | "\(.id): \(.text)"'
            fi
            ;;
        render)
            local agent="all"
            local path=""
            local path_supplied=false
            local base_dir="."
            local format="text"
            while [ $# -gt 0 ]; do
                case "$1" in
                    --agent=*) agent="${1#*=}" ;;
                    --base-dir=*) base_dir="${1#*=}" ;;
                    --path=*) path="${1#*=}"; path_supplied=true ;;
                    --json) format="json" ;;
                    --help|-h)
                        _memory_usage
                        return 0
                        ;;
                    *)
                        echo -e "${RED}Error: unknown option $1${NC}" >&2
                        _memory_usage
                        return 1
                        ;;
                esac
                shift
            done
            local raw_agent="$agent"
            agent=$(_memory_resolve_agent "$agent")

            local projections=()
            case "$agent" in
                all|native|container) projections=(claude claude-memory codex codex-memory copilot agents) ;;
                claude) projections=(claude) ;;
                claude-memory) projections=(claude-memory) ;;
                codex) projections=(codex) ;;
                codex-memory) projections=(codex-memory) ;;
                copilot) projections=(copilot) ;;
                agents) projections=(agents) ;;
                workflow) projections=(workflow) ;;
                *)
                    # When --agent=current resolves to a label with no dedicated
                    # projection (custom WV_OPERATING_AGENT/WV_AGENT_NAME, a subagent
                    # name, or a future harness), render the full agnostic set rather
                    # than failing — recall already tolerates unknown agents, so render
                    # must not be stricter. An explicit unknown --agent=<name> is still
                    # a hard error (typo guard). See wv-872543 (F3).
                    if [ "$raw_agent" = "current" ]; then
                        projections=(claude claude-memory codex codex-memory copilot agents)
                    else
                        echo -e "${RED}Error: unsupported memory projection '$agent'${NC}" >&2
                        echo "Supported projections: all, current, claude, claude-memory, copilot, codex, codex-memory, agents, workflow" >&2
                        return 1
                    fi
                    ;;
            esac
            if [ "$path_supplied" = true ] && [ "${#projections[@]}" -ne 1 ]; then
                echo -e "${RED}Error: --path can only be used with a single projection${NC}" >&2
                return 1
            fi

            local entries rendered_paths='[]' projection target_path
            entries=$(_memory_recall_json)
            for projection in "${projections[@]}"; do
                if [ "$path_supplied" = true ]; then
                    target_path="$path"
                else
                    target_path=$(_memory_projection_path "$projection" "$base_dir") || return 1
                fi
                local _render_rc=0
                _memory_render_projection "$projection" "$entries" "$target_path" || _render_rc=$?
                # 3 = marker-gated projection skipped (AGENTS.md without its block)
                [ "$_render_rc" -eq 3 ] && continue
                [ "$_render_rc" -eq 0 ] || return 1
                rendered_paths=$(printf '%s\n' "$rendered_paths" | jq --arg projection "$projection" --arg path "$target_path" '. + [{projection: $projection, path: $path}]')
            done

            if [ "$format" = "json" ]; then
                jq -n --arg agent "$agent" --argjson paths "$rendered_paths" --argjson entries "$entries" \
                    '{projection: $agent, paths: $paths, path: ($paths[0].path // null), entries: ($entries | length)}'
            else
                printf '%s\n' "$rendered_paths" | jq -r '.[] | "✓ Rendered graph memory to \(.path)"'
            fi
            ;;
        scan)
            local source="all"
            local repo_root
            repo_root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
            local format="text"
            while [ $# -gt 0 ]; do
                case "$1" in
                    --source=*) source="${1#*=}" ;;
                    --repo-root=*) repo_root="${1#*=}" ;;
                    --json) format="json" ;;
                    --help|-h)
                        _memory_usage
                        return 0
                        ;;
                    *)
                        echo -e "${RED}Error: unknown option $1${NC}" >&2
                        _memory_usage
                        return 1
                        ;;
                esac
                shift
            done
            local observations
            observations=$(_memory_scan_sources "$source" "$repo_root") || return 1
            if [ "$format" = "json" ]; then
                printf '%s\n' "$observations"
            else
                printf '%s\n' "$observations" | jq -r '.[] | "\(.source_agent): \(.source_path)"'
            fi
            ;;
        import)
            local source="" path="" repo_root
            repo_root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
            local format="text"
            while [ $# -gt 0 ]; do
                case "$1" in
                    --source=*) source="${1#*=}" ;;
                    --path=*) path="${1#*=}" ;;
                    --repo-root=*) repo_root="${1#*=}" ;;
                    --json) format="json" ;;
                    --help|-h)
                        _memory_usage
                        return 0
                        ;;
                    *)
                        echo -e "${RED}Error: unknown option $1${NC}" >&2
                        _memory_usage
                        return 1
                        ;;
                esac
                shift
            done
            case "$source" in
                claude)
                    if [ -z "$path" ]; then
                        echo -e "${RED}Error: --path required for Claude memory import${NC}" >&2
                        return 1
                    fi
                    _memory_import_claude_dir "$path" "$repo_root" "$format"
                    ;;
                codex)
                    _memory_import_codex "$path" "$repo_root" "$format"
                    ;;
                *)
                    echo -e "${RED}Error: memory import supports --source=claude|codex${NC}" >&2
                    return 1
                    ;;
            esac
            ;;
        crystallize)
            local mode="dry-run"
            local format="text"
            local repo_root
            repo_root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
            while [ $# -gt 0 ]; do
                case "$1" in
                    --dry-run) mode="dry-run" ;;
                    --apply-reviewed) mode="apply-reviewed" ;;
                    --repo-root=*) repo_root="${1#*=}" ;;
                    --json) format="json" ;;
                    --help|-h)
                        _memory_usage
                        return 0
                        ;;
                    *)
                        echo -e "${RED}Error: unknown option $1${NC}" >&2
                        _memory_usage
                        return 1
                        ;;
                esac
                shift
            done
            db_ensure
            db_migrate_fts5 2>/dev/null || true

            local candidates report='[]'
            local cid ctext chash creviewed action now
            candidates=$(_memory_candidates_json)
            now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

            # Read candidate rows into an array first so the db_query/sqlite3 calls
            # inside the loop body cannot consume the feeding fd (1-iteration bug).
            local cand_rows=() line
            mapfile -t cand_rows < <(printf '%s' "$candidates" | jq -r '.[] | [.id, (.text // "" | gsub("\t";" ")), (.metadata.source_hash // ""), ((.metadata.reviewed // false) | tostring)] | @tsv')
            for line in "${cand_rows[@]}"; do
                IFS=$'\t' read -r cid ctext chash creviewed <<<"$line"
                [ -n "$cid" ] || continue
                _memory_crystallize_dedup_one "$cid" "$ctext" "$chash"
                _memory_crystallize_verify_one "$ctext" "$repo_root"

                # Deterministic signals win; fuzzy overlap is advisory only.
                action="keep"
                if [ -n "$_cr_stale_reason" ]; then
                    action="stale"
                elif [ "$_cr_dup_kind" = "source_hash" ]; then
                    action="superseded"
                elif [ -n "$_cr_contradicts" ]; then
                    action="contradicts"
                elif [ "$creviewed" = "true" ]; then
                    action="promote"
                elif [ -n "$_cr_dup_id" ]; then
                    action="overlap"
                fi

                local finding_id=""
                if [ "$mode" = "apply-reviewed" ]; then
                    case "$action" in
                        stale)
                            _memory_patch_metadata "$cid" "$(jq -nc --arg r "$_cr_stale_reason" '{mem_status:"stale", stale_reason:$r}')"
                            ;;
                        superseded)
                            _memory_patch_metadata "$cid" "$(jq -nc --arg s "$_cr_dup_id" '{mem_status:"superseded", superseded_by:$s}')"
                            # Registry: supersedes means the TARGET replaces the source,
                            # so the superseded candidate is the source - as wv remember
                            # --supersedes writes it (old -> new). This read the other
                            # way round (wv-fc6fc2).
                            _memory_crystallize_edge "$cid" "$_cr_dup_id" "supersedes"
                            ;;
                        contradicts)
                            finding_id=$(_memory_crystallize_finding "$cid" "$_cr_contradicts")
                            ;;
                        promote)
                            _memory_patch_metadata "$cid" "$(jq -nc --arg t "$now" '{mem_status:"active", verified_at:$t}')"
                            ;;
                    esac
                fi

                report=$(jq -nc --argjson r "$report" \
                    --arg id "$cid" --arg action "$action" \
                    --arg dup "$_cr_dup_id" --arg dupk "$_cr_dup_kind" \
                    --arg contra "$_cr_contradicts" --arg stale "$_cr_stale_reason" \
                    --arg reviewed "$creviewed" --arg finding "$finding_id" \
                    '$r + [{
                        id: $id,
                        action: $action,
                        reviewed: ($reviewed == "true"),
                        duplicate_of: (if $dup == "" then null else $dup end),
                        dup_kind: (if $dupk == "" then null else $dupk end),
                        contradicts: (if $contra == "" then null else $contra end),
                        stale_reason: (if $stale == "" then null else $stale end),
                        finding: (if $finding == "" then null else $finding end)
                    } | with_entries(select(.value != null))]')
            done

            if [ "$mode" = "apply-reviewed" ]; then
                auto_sync_or_warn
            fi

            if [ "$format" = "json" ]; then
                jq -n --arg mode "$mode" --argjson report "$report" \
                    '{mode: $mode, candidates: ($report | length), results: $report}'
            else
                printf '%s\n' "$report" | jq -r '.[] | "\(.action)\t\(.id)\(if .stale_reason then "  ("+.stale_reason+")" elif .duplicate_of then "  (->"+.duplicate_of+")" else "" end)"'
                printf '%s candidate(s), mode=%s\n' "$(printf '%s' "$report" | jq 'length')" "$mode"
            fi
            ;;
        --help|-h|"")
            _memory_usage
            [ -n "$subcmd" ] || return 1
            ;;
        *)
            echo -e "${RED}Error: unknown memory subcommand $subcmd${NC}" >&2
            _memory_usage
            return 1
            ;;
    esac
}

# ═══════════════════════════════════════════════════════════════════════════
# _node_commit_shas — Find recent commits attributed to a node ID
# _store_node_commits — Persist attributed commits onto node metadata
# _aggregate_epic_commits — Collect child commits onto an epic node
# ═══════════════════════════════════════════════════════════════════════════

_node_commit_shas() {
    local id="$1"
    local raw_shas
    raw_shas=$(git log --format="%H" --grep="Weave-ID: $id" --since="90 days ago" 2>/dev/null | head -20)
    if [ -z "$raw_shas" ]; then
        raw_shas=$(git log --format="%H" --grep="$id" --since="90 days ago" 2>/dev/null | head -20)
    fi
    [ -z "$raw_shas" ] && return 0

    local sha subject regular_shas="" checkpoint_shas=""
    while IFS= read -r sha; do
        [ -z "$sha" ] && continue
        subject=$(git log -1 --format="%s" "$sha" 2>/dev/null || echo "")
        case "$subject" in
            chore\(weave\):\ auto-checkpoint*|chore\(weave\):\ sync\ state*|chore\(weave\):\ session-start\ state*)
                checkpoint_shas="${checkpoint_shas}${sha}\n"
                ;;
            *)
                regular_shas="${regular_shas}${sha}\n"
                ;;
        esac
    done <<< "$raw_shas"

    printf '%b%b' "$regular_shas" "$checkpoint_shas" | sed '/^$/d'
}

_store_node_commits() {
    local id="$1"
    local shas shas_json primary_sha
    shas=$(_node_commit_shas "$id")
    [ -z "$shas" ] && return 0
    local cur_meta
    cur_meta=$(_done_read_metadata "$id")

    local existing_primary
    existing_primary=$(echo "$cur_meta" | jq -r '.commit // empty' 2>/dev/null || echo "")
    if [ -n "$existing_primary" ] && grep -qx -- "$existing_primary" <<< "$shas"; then
        primary_sha="$existing_primary"
    else
        primary_sha=$(printf '%s\n' "$shas" | head -1)
    fi
    shas=$(printf '%s\n%s\n' "$primary_sha" "$shas" | awk 'NF && !seen[$0]++')
    shas_json=$(printf '%s\n' "$shas" | jq -R . | jq -s . 2>/dev/null || echo "[]")
    [ "$shas_json" = "[]" ] && return 0

    local patch_json
    patch_json=$(jq -cn --arg primary "$primary_sha" --argjson s "$shas_json" '{commit: $primary, commits: $s}' 2>/dev/null || echo "")
    [ -z "$patch_json" ] && return 0
    patch_json="${patch_json//\'/\'\'}"
    db_query "UPDATE nodes SET metadata=json_patch(COALESCE(metadata, '{}'), '$patch_json') WHERE id='$(sql_escape "$id")';"
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
    # Prevention (wv-fc4ac2): the union is copied out of CHILD metadata, which is
    # the one place a stale SHA can enter an aggregate — a child ref that was
    # amended, reset or gc'd since its close would otherwise be re-acquired by
    # the epic on every sync, which is why hand-removing it from the epic alone
    # never held (wv-99893f kept re-acquiring 61b9fcab from wv-f1aec5).
    # _store_node_commits needs no such filter: its SHAs come straight from
    # `git log` over HEAD, so they are live by construction.
    # Fails open when git cannot answer; `wv commit-refs` reports what survives.
    if declare -f _commit_refs_keep_live >/dev/null 2>&1; then
        all_shas=$(_commit_refs_keep_live "$all_shas")
    fi
    { [ -z "$all_shas" ] || [ "$all_shas" = "[]" ]; } && return 0
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

# _done_refresh_file_metrics — Sync brain.db file_metrics from quality.db for
# paths already tracked in node_files before the status UPDATE.
#
# node_files is populated via explicit 'wv touch <path>' calls (or direct
# sqlite3 inserts in tests). The proposal's auto-population-via-git-diff is
# deferred — diff attribution proved noisy in mixed hot-zone environments.
#
# Skipped when WV_REQUIRE_QUALITY=0 (test/legacy bypass).
# Fails loudly if node_files is non-empty and quality.db is unavailable.
# _is_quality_exempt — returns 0 (true) if path matches any quality_exempt pattern.
# Patterns with trailing '/' match directory prefix; others match exactly (LIKE without wildcards).
_is_quality_exempt() {
    local path="$1"
    local result
    result=$(db_query "SELECT 1 FROM quality_exempt WHERE
        ('$( echo "$path" | sed "s/'/''/g" )' LIKE
            CASE WHEN path_pattern LIKE '%/'
                 THEN path_pattern || '%'
                 ELSE path_pattern
            END
        ) LIMIT 1;" 2>/dev/null || echo "")
    [ -n "$result" ]
}

# Return the auditable completion scope when one was explicitly set, otherwise
# preserve the legacy behavior of checking every historically attributed file.
_done_quality_paths() {
    local id="$1"
    local scope_json="${2:-}"
    local scope_clause=""
    if [ -n "$scope_json" ]; then
        scope_clause="AND path IN (SELECT value FROM json_each('$(sql_escape "$scope_json")'))"
    fi
    db_query "SELECT path FROM node_files WHERE node_id='$(sql_escape "$id")' $scope_clause;" 2>/dev/null || echo ""
}

_done_refresh_file_metrics() {
    local id="$1"
    local scope_json="${2:-}"

    # Read paths tracked for this node
    local paths_raw
    paths_raw=$(_done_quality_paths "$id" "$scope_json")
    if [ -z "$paths_raw" ]; then
        wv_policy_verdict close_requires_quality_evidence allow no "" "the node tracks no files to judge"
        return 0
    fi

    # The bypass is recorded once there is something it skips. Whether the
    # evidence was actually missing is not evaluated, so the invariant is unknown.
    if [ "${WV_REQUIRE_QUALITY:-1}" = "0" ]; then
        wv_policy_verdict close_requires_quality_evidence allow unknown WV_REQUIRE_QUALITY=0 \
            "quality evidence not required for this close"
        return 0
    fi

    # quality.db must exist when node_files is non-empty
    local quality_db="$WV_HOT_ZONE/quality.db"
    if [ ! -f "$quality_db" ]; then
        wv_policy_verdict close_requires_quality_evidence deny yes "" "no quality database to judge the close"
        echo -e "${RED}Error: quality.db not found at $quality_db${NC}" >&2
        echo -e "  Run 'wv quality scan' before closing nodes that touch tracked files." >&2
        echo -e "  Set WV_REQUIRE_QUALITY=0 to bypass (test/legacy environments only)." >&2
        return 1
    fi

    # Must have at least one scan
    local latest_scan
    latest_scan=$(sqlite3 -batch -cmd ".timeout 3000" "$quality_db" \
        "SELECT id FROM scan_meta ORDER BY id DESC LIMIT 1;" 2>/dev/null || echo "")
    if [ -z "$latest_scan" ]; then
        wv_policy_verdict close_requires_quality_evidence deny yes "" "no quality scan to judge the close"
        echo -e "${RED}Error: quality.db has no scan data — run 'wv quality scan' first${NC}" >&2
        echo -e "  Set WV_REQUIRE_QUALITY=0 to bypass (test/legacy environments only)." >&2
        return 1
    fi

    # Upsert mccabe_max + language from quality.db into brain.db for each tracked path.
    # Source: MAX(fn_cc:*) per-function CC from file_metrics (Python AST / bash heuristic).
    # language derived from extension: py/sh/ts → per-language threshold; '' → fallback.
    local path
    while IFS= read -r path; do
        [ -z "$path" ] && continue
        _is_quality_exempt "$path" && continue
        local path_esc mccabe_val lang upsert_err upsert_rc
        path_esc=$(echo "$path" | sed "s/'/''/g")
        case "$path" in
            *.py)       lang="py" ;;
            *.sh)       lang="sh" ;;
            *.ts|*.tsx) lang="ts" ;;
            *)          lang=""   ;;
        esac
        mccabe_val=$(sqlite3 -batch -cmd ".timeout 3000" "$quality_db" \
            "SELECT COALESCE(CAST(MAX(value) AS INTEGER), 0) FROM file_metrics WHERE path='$path_esc' AND scan_id=$latest_scan AND metric LIKE 'fn_cc:%';" 2>/dev/null || echo "")
        [ -z "$mccabe_val" ] && mccabe_val=0
        upsert_err=$(db_query "INSERT INTO file_metrics(path, mccabe_max, language) VALUES('$path_esc', $mccabe_val, '$lang')
            ON CONFLICT(path) DO UPDATE SET mccabe_max = excluded.mccabe_max, language = excluded.language;" 2>&1)
        upsert_rc=$?
        if [ $upsert_rc -ne 0 ]; then
            echo -e "${RED}Error: failed to refresh file_metrics for '$path': $upsert_err${NC}" >&2
            return 1
        fi
    done <<< "$paths_raw"
    wv_policy_verdict close_requires_quality_evidence allow no "" "a quality scan covers the tracked files"
}

# _done_refresh_trend_signals — Sync brain.db file_trend from quality.db for
# paths tracked in node_files. Reads complexity_trend history and writes
# 'deteriorating'/'stable'/'refactored' direction per path.
#
# Called after _done_refresh_file_metrics (quality.db existence already verified).
# Skipped when WV_REQUIRE_QUALITY=0 or node_files is empty.
# Non-blocking: missing trend data defaults to 'stable' rather than failing.
_done_refresh_trend_signals() {
    local id="$1"
    local scope_json="${2:-}"

    [ "${WV_REQUIRE_QUALITY:-1}" = "0" ] && return 0

    local paths_raw
    paths_raw=$(_done_quality_paths "$id" "$scope_json")
    [ -z "$paths_raw" ] && return 0

    local quality_db="$WV_HOT_ZONE/quality.db"
    [ ! -f "$quality_db" ] && return 0

    local path
    while IFS= read -r path; do
        [ -z "$path" ] && continue
        local path_esc direction upsert_err upsert_rc
        path_esc=$(echo "$path" | sed "s/'/''/g")
        direction=$(sqlite3 -batch -cmd ".timeout 3000" "$quality_db" \
            "SELECT complexity FROM complexity_trend WHERE path='$path_esc' ORDER BY scan_id ASC;" \
            2>/dev/null | python3 -c "
import sys
vals=[float(l.strip()) for l in sys.stdin if l.strip()]
if len(vals)<2: print('stable'); exit()
n=len(vals); xm=(n-1)/2.0; ym=sum(vals)/n
num=sum((i-xm)*(v-ym) for i,v in enumerate(vals))
den=sum((i-xm)**2 for i in range(n))
if den==0 or ym==0: print('stable'); exit()
s=(num/den)/ym
print('deteriorating' if s>0.03 else ('refactored' if s<-0.03 else 'stable'))
" 2>/dev/null || echo "stable")
        upsert_err=$(db_query "INSERT INTO file_trend(path, direction) VALUES('$path_esc', '$direction')
            ON CONFLICT(path) DO UPDATE SET direction = excluded.direction;" 2>&1)
        upsert_rc=$?
        if [ $upsert_rc -ne 0 ]; then
            echo -e "${RED}Error: failed to refresh file_trend for '$path': $upsert_err${NC}" >&2
            return 1
        fi
    done <<< "$paths_raw"
}

# _done_refresh_test_status — Populate file_test_status from the test_results
# ledger for each path tracked in node_files, before the status flip (P6b).
#
# Per path P: resolve its suites via _impact_suites_for_files (the ONE shared
# path->suite resolver, also used by pre-commit — never a second copy), then for
# each suite look up the ledger row keyed (suite, P). Compare the row's stored
# fingerprint to P's CURRENT fingerprint (_test_file_fingerprint, the same pure
# function the producer used):
#   match + exit 0  -> green   (fresh pass)
#   match + exit !=0 -> red     (fresh fail)
#   no match         -> stale   (file changed since the recorded run)
#   mapped + no row  -> stale   (required evidence is absent)
#   no map           -> unknown (non-blocking — no suite is required)
# Aggregate across suites with precedence red > stale > green > unknown.
#
# Best-effort by design: ALWAYS returns 0. The test gate is inert by default
# (test_gate=0); when block mode is enabled, mapped paths without complete
# evidence are written as stale and rejected by the policy trigger. Quality.db
# is NOT required — this reads brain.db only.
_done_refresh_test_status() {
    local id="$1"
    local scope_json="${2:-}"

    # Honors the shared done-refresh bypass. This reads brain.db (not quality.db),
    # but reusing WV_REQUIRE_QUALITY=0 keeps one test/legacy escape hatch for the
    # whole refresh chain and lets trigger tests seed file_test_status directly
    # without this recompute clobbering it.
    [ "${WV_REQUIRE_QUALITY:-1}" = "0" ] && return 0

    local paths_raw
    paths_raw=$(_done_quality_paths "$id" "$scope_json")
    [ -z "$paths_raw" ] && return 0

    # Asked once: does git run a Weave pre-push gate here (heavy suites deferred)?
    local deferral_on=0
    command -v wv_prepush_gate_installed >/dev/null 2>&1 && wv_prepush_gate_installed && deferral_on=1

    local path
    while IFS= read -r path; do
        [ -z "$path" ] && continue
        # A path outside the repository (older attributions recorded memory and
        # scratch files absolute) has no test map entry that could ever be run,
        # so it gets no verdict rather than a permanent "stale" (wv-67c7b6).
        case "$path" in /*) continue ;; esac
        local path_esc cur_fp state
        path_esc=$(sql_escape "$path")
        cur_fp=$(_test_file_fingerprint "$path")

        # Resolve suites for this path via the shared resolver (JSON -> names),
        # keeping which are push-tier ([heavy], wv-862ac0). tests/run-all.sh is
        # the meta-runner the gates skip and never record (wv-gate-pool.sh), so
        # requiring its row made every file routed to it stale forever.
        local suites suites_json heavy_suites
        suites_json=$(_impact_suites_for_files "$path" 2>/dev/null || echo '[]')
        suites=$(jq -r '.[].name | select(. != "tests/run-all.sh")' <<< "$suites_json" 2>/dev/null || echo "")
        heavy_suites=" $(jq -r '[.[] | select(.tier == "heavy") | .name] | join(" ")' <<< "$suites_json" 2>/dev/null) "

        if [ -n "$suites" ]; then
            # A mapped path starts stale and becomes green only if every required
            # suite has a fresh passing row. This makes an absent/wiped ledger or
            # a partial multi-suite result fail closed when test_gate=block.
            state="green"
        else
            state="unknown"
        fi
        local suite row_fp row_exit suite_state
        for suite in $suites; do
            row_fp=$(db_query "SELECT fingerprint FROM test_results WHERE suite='$(sql_escape "$suite")' AND path='$path_esc' LIMIT 1;" 2>/dev/null || echo "")
            if [ -z "$row_fp" ]; then
                suite_state="stale"
            else
                row_exit=$(db_query "SELECT exit_code FROM test_results WHERE suite='$(sql_escape "$suite")' AND path='$path_esc' LIMIT 1;" 2>/dev/null || echo "")
            fi
            if [ -n "$row_fp" ] && [ "$row_fp" = "$cur_fp" ]; then
                if [ "$row_exit" = "0" ]; then suite_state="green"; else suite_state="red"; fi
            elif [ -n "$row_fp" ]; then
                suite_state="stale"
            fi
            # A push-tier suite runs at git push, not at commit (wv-862ac0), so
            # when that gate is installed its missing or outdated row means
            # "owed at push", not "stale": the push is refused until it is green
            # for this content. Without the gate it is required here as before.
            # A red row for the current content stays red (ultrareview #4575).
            if [ "$suite_state" = "stale" ] && [ "$deferral_on" = "1" ] \
                && [[ "$heavy_suites" == *" $suite "* ]]; then
                suite_state="deferred"
            fi
            # Precedence: red > stale > deferred > green > unknown.
            case "$suite_state" in
                red)      state="red" ;;
                stale)    [ "$state" != "red" ] && state="stale" ;;
                deferred) { [ "$state" = "green" ] || [ "$state" = "unknown" ]; } && state="deferred" ;;
                green)    { [ "$state" = "unknown" ]; } && state="green" ;;
            esac
        done

        db_query "INSERT INTO file_test_status(path, state) VALUES('$path_esc', '$state')
            ON CONFLICT(path) DO UPDATE SET state = excluded.state;" >/dev/null 2>&1 || true
    done <<< "$paths_raw"
    return 0
}

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

# Enum sourced from wv-validate.sh (FINDING_VIOLATION_TYPES) — do not duplicate here.
_FINDING_VIOLATION_TYPES="$FINDING_VIOLATION_TYPES"

_finding_missing_fields() {
    local meta_json="${1:-{}}"
    echo "$meta_json" | jq -r --arg valid_types "$_FINDING_VIOLATION_TYPES" '
        (.finding // {}) as $finding |
        ($valid_types | split(" ")) as $enum |
        [
            # violation_type: required + enum-validated
            (if (($finding.violation_type // null) | type) == "string"
                and (($finding.violation_type | gsub("^\\s+|\\s+$"; "")) | length) > 0
                and ($enum | index($finding.violation_type)) != null
             then empty
             elif (($finding.violation_type // null) | type) == "string"
                and (($finding.violation_type | gsub("^\\s+|\\s+$"; "")) | length) > 0
             then "finding.violation_type (invalid enum: \($finding.violation_type))"
             else "finding.violation_type"
             end),
            # root_cause, proposed_fix, confidence, fixable: optional — validate only if present
            (if ($finding | has("root_cause")) and
                ((($finding.root_cause // null) | type) != "string" or (($finding.root_cause | gsub("^\\s+|\\s+$"; "")) | length) == 0)
             then "finding.root_cause (present but empty/invalid)" else empty end),
            (if ($finding | has("proposed_fix")) and
                ((($finding.proposed_fix // null) | type) != "string" or (($finding.proposed_fix | gsub("^\\s+|\\s+$"; "")) | length) == 0)
             then "finding.proposed_fix (present but empty/invalid)" else empty end),
            (if ($finding | has("confidence")) and
                (["high", "medium", "low"] | index(($finding.confidence // "") | tostring)) == null
             then "finding.confidence (must be high|medium|low)" else empty end),
            (if ($finding | has("fixable")) and ($finding.fixable | type) != "boolean"
             then "finding.fixable (must be boolean)" else empty end)
        ] | .[]?
    ' 2>/dev/null
}

_done_require_finding_metadata() {
    local id="$1" meta_json="$2"
    local node_type
    node_type=$(echo "$meta_json" | jq -r '.type // "task"' 2>/dev/null || echo "task")
    if [ "$node_type" != "finding" ]; then
        wv_policy_verdict finding_close_requires_violation_type allow no "" "not a finding"
        return 0
    fi

    local missing_fields
    missing_fields=$(_finding_missing_fields "$meta_json" | paste -sd ', ' - || true)
    if [ -z "$missing_fields" ]; then
        wv_policy_verdict finding_close_requires_violation_type allow no "" "the finding carries a catalogued violation type"
        return 0
    fi

    wv_policy_verdict finding_close_requires_violation_type deny yes "" \
        "a finding without a catalogued violation_type cannot be promoted or coached"
    echo -e "${RED}Error: finding node requires violation_type before close${NC}" >&2
    echo -e "  Missing or invalid: $missing_fields" >&2
    echo -e "  Enum values: $_FINDING_VIOLATION_TYPES" >&2
    echo -e "  Minimal: wv update $id --metadata='{\"finding\":{\"violation_type\":\"repo:hygiene\"}}'" >&2
    echo -e "  Full:    wv update $id --metadata='{\"finding\":{\"violation_type\":\"repo:hygiene\",\"root_cause\":\"...\",\"proposed_fix\":\"...\",\"confidence\":\"high\",\"fixable\":true}}'" >&2
    return 1
}

_done_read_option_file() {
    local flag_name="$1"
    local file_path="$2"

    if [ -z "$file_path" ]; then
        echo -e "${RED}Error: $flag_name requires a file path${NC}" >&2
        return 1
    fi
    if [ ! -r "$file_path" ]; then
        echo -e "${RED}Error: cannot read $flag_name file: $file_path${NC}" >&2
        return 1
    fi

    cat -- "$file_path"
}

_done_can_prompt_overlap() { # predicate
    [ "${WV_NONINTERACTIVE:-0}" != "1" ] && [ -z "${CI:-}" ] && [ -t 0 ] && [ -t 2 ]
}

# Polarity = sign(positive_verbs - negative_verbs).
# Returns: 1 (mostly positive recommendation), -1 (mostly negative/avoidance), 0 (mixed/neutral).
# Used to detect contradictions between an FTS5-matched pair of learnings: same topic
# (FTS5 already validated overlap) but opposite polarity = candidate contradiction.
_done_polarity() {
    local text="$1"
    local pos neg
    pos=$(echo "$text" | grep -oiE '\b(use|prefer|enable|require|always|must|should|adopt|keep|do)\b' | wc -l)
    neg=$(echo "$text" | grep -oiE '\b(avoid|never|disable|forbid|don.?t|do not|must not|should not|cannot|stop|drop|remove|deprecate)\b' | wc -l)
    if [ "$pos" -gt "$neg" ]; then echo 1
    elif [ "$neg" -gt "$pos" ]; then echo -1
    else echo 0
    fi
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
    local id="$1" learning="$2" acknowledge_overlap="${3:-0}" no_overlap_check="${4:-0}"
    local _overlap_spoke=false
    local explicit_decision="${5:-}" explicit_pattern="${6:-}" explicit_pitfall="${7:-}"
    _done_skip_learning=false
    _done_pending_close=false

    # FTS5 dedup check: prompt if a similar learning already exists.
    # Skip entirely for explicit opt-out and non-interactive agent/script flows.
    local search_terms
    search_terms=$(echo "$learning" | tr -cs '[:alnum:]' ' ' | \
        awk '{for(i=1;i<=NF;i++) if(length($i)>4) {print $i; c++; if(c>=3) exit}}')
    if [ "$no_overlap_check" = "0" ] && [ "${WV_NONINTERACTIVE:-0}" != "1" ] && [ -n "$search_terms" ]; then
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
            # Contradiction check: pull matched learning, compare polarity.
            local matched_learning new_pol old_pol contradiction
            matched_learning=$(db_query_json "SELECT metadata FROM nodes WHERE id='$fts_match';" 2>/dev/null \
                | jq -r '.[0].metadata | if . and . != "" then (. | fromjson | .learning // "") else "" end' 2>/dev/null || echo "")
            new_pol=$(_done_polarity "$learning")
            old_pol=$(_done_polarity "$matched_learning")
            contradiction=false
            if [ "$new_pol" != "0" ] && [ "$old_pol" != "0" ] && [ "$new_pol" != "$old_pol" ]; then
                contradiction=true
            fi

            # Advisory whatever the caller does next: overlap is a quality
            # heuristic that never blocks a close, so it is recorded, not denied.
            _overlap_spoke=true
            wv_policy_verdict learning_overlap_advisory advisory unknown "" \
                "learning overlaps $fts_match$([ "$contradiction" = true ] && printf ' with opposite polarity')"
            if [ "$contradiction" = true ]; then
                echo -e "${RED}⚠ Learning may CONTRADICT $fts_match (opposite polarity)${NC}" >&2
            else
                echo -e "${YELLOW}⚠ Learning may overlap with $fts_match${NC}" >&2
            fi
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
                local cur_meta new_meta jq_filter
                cur_meta=$(_done_read_metadata "$id")
                if [ "$contradiction" = true ]; then
                    jq_filter='. + {learning_overlap_noted: $overlap_id, learning_contradiction_noted: $overlap_id}'
                else
                    jq_filter='. + {learning_overlap_noted: $overlap_id}'
                fi
                new_meta=$(echo "$cur_meta" | jq \
                    --arg overlap_id "$fts_match" \
                    "$jq_filter" 2>/dev/null || echo "$cur_meta")
                new_meta="${new_meta//\'/\'\'}"
                db_query "UPDATE nodes SET metadata='$new_meta', updated_at=CURRENT_TIMESTAMP WHERE id='$id';"
                if [ "$contradiction" = true ]; then
                    echo -e "${RED}  → Contradiction noted in metadata (learning_contradiction_noted: $fts_match), proceeding.${NC}" >&2
                else
                    echo -e "${YELLOW}  → Overlap noted in metadata (learning_overlap_noted: $fts_match), proceeding.${NC}" >&2
                fi
            fi
        fi
    fi

    [ "${_overlap_spoke:-false}" = true ] ||
        wv_policy_verdict learning_overlap_advisory allow no "" "no overlapping learning found"

    if [ "$_done_skip_learning" = true ] || [ "$_done_pending_close" = true ]; then
        return 0
    fi

    # Merge learning into node metadata, parsing inline markers into top-level keys
    local cur_meta
    cur_meta=$(_done_read_metadata "$id")
    # Pre-normalize: lowercase structured markers and convert ; separators → | for jq 1.5 compat
    # (jq 1.6 named captures and case-insensitive flags not available on all platforms)
    local norm_learning
    norm_learning=$(printf '%s\n' "$learning" \
        | sed -e 's/;[[:space:]]*[Dd][Ee][Cc][Ii][Ss][Ii][Oo][Nn]:/| decision:/g' \
              -e 's/;[[:space:]]*[Pp][Aa][Tt][Tt][Ee][Rr][Nn]:/| pattern:/g' \
              -e 's/;[[:space:]]*[Pp][Ii][Tt][Ff][Aa][Ll][Ll]:/| pitfall:/g' \
              -e 's/[Dd][Ee][Cc][Ii][Ss][Ii][Oo][Nn]:/decision:/g' \
              -e 's/[Pp][Aa][Tt][Tt][Ee][Rr][Nn]:/pattern:/g' \
              -e 's/[Pp][Ii][Tt][Ff][Aa][Ll][Ll]:/pitfall:/g' 2>/dev/null) || norm_learning="$learning"
    local new_meta
    new_meta=$(echo "$cur_meta" | jq \
        --arg l "$norm_learning" \
        --arg raw "$learning" \
        --arg decision "$explicit_decision" \
        --arg pattern "$explicit_pattern" \
        --arg pitfall "$explicit_pitfall" '
        ($l | until(test("\\|\\s*\\|") | not; gsub("\\|\\s*\\|"; "|"))) as $norm |
        (if ($norm | test("^(decision|pattern|pitfall):")) then
          ($norm | split(" | ") | map(select(length > 0) | gsub("^\\s+|\\s+$"; "")) | map(select(length > 0)) | reduce .[] as $seg (
            {};
            if ($seg | test("^decision:")) then .decision = ($seg | sub("^decision:\\s*"; ""))
            elif ($seg | test("^pattern:")) then .pattern = ($seg | sub("^pattern:\\s*"; ""))
            elif ($seg | test("^pitfall:")) then .pitfall = ($seg | sub("^pitfall:\\s*"; ""))
            else
              if .pitfall then .pitfall = .pitfall + " | " + $seg
              elif .pattern then .pattern = .pattern + " | " + $seg
              elif .decision then .decision = .decision + " | " + $seg
              else .
              end
            end
          )) as $parsed |
          . + ($parsed | to_entries | map(select(.value != null and .value != "")) | from_entries)
        else
          . + {learning: $raw}
        end) |
        . + ({decision: $decision, pattern: $pattern, pitfall: $pitfall}
            | with_entries(select(.value != "")))
    ') || new_meta=$(echo "$cur_meta" | jq --arg l "$learning" '. + {learning: $l}' 2>/dev/null) || new_meta="$cur_meta"
    new_meta="${new_meta//\'/\'\'}"
    db_query "UPDATE nodes SET metadata='$new_meta', updated_at=CURRENT_TIMESTAMP WHERE id='$id';"
    score_learning "$id" 2>/dev/null || true

    # wv-18b8f5 (external code review round 3 re-audit): the parse above
    # only splits on a LITERAL ' | ' -- a learning that mentions two or more
    # of decision:/pattern:/pitfall: without ever using '|' to separate them
    # silently collapses everything into whichever marker appeared first
    # (see the jq filter above: split(" | ") on a string with no '|' yields
    # one segment, so only the FIRST marker's branch of the reduce ever
    # fires). The dropped markers become invisible prose with no error --
    # in particular, an embedded pitfall: that never became its own
    # metadata key is invisible to 'wv audit-pitfalls', which only indexes
    # the top-level key. Detected independently of the parse above (2+
    # distinct markers present, but no '|' anywhere to separate them) so
    # this warns even if the jq parse itself is later rewritten.
    local _marker_count=0
    [[ "$learning" == *[Dd][Ee][Cc][Ii][Ss][Ii][Oo][Nn]:* ]] && _marker_count=$((_marker_count + 1))
    [[ "$learning" == *[Pp][Aa][Tt][Tt][Ee][Rr][Nn]:* ]] && _marker_count=$((_marker_count + 1))
    [[ "$learning" == *[Pp][Ii][Tt][Ff][Aa][Ll][Ll]:* ]] && _marker_count=$((_marker_count + 1))
    if [ "$_marker_count" -ge 2 ] && [[ "$learning" != *"|"* ]]; then
        echo -e "${YELLOW}Warning: this learning mentions $_marker_count of decision:/pattern:/pitfall: with no '|' between them.${NC}" >&2
        echo -e "${YELLOW}  Only the FIRST marker was captured as a structured field -- the rest is embedded prose that audit-pitfalls and other category-based reads will never see.${NC}" >&2
        echo -e "${YELLOW}  Fix now: wv update $id --metadata='{\"pattern\":\"...\",\"pitfall\":\"...\"}' to split them out explicitly.${NC}" >&2
    fi

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

    local gh_state
    gh_state=$(gh issue view "$gh_num" --repo "$repo" --json state -q '.state' 2>/dev/null || echo "")
    if [ "$gh_state" = "OPEN" ]; then
        if gh issue close "$gh_num" --repo "$repo" --comment "$comment" >/dev/null 2>&1; then
            echo -e "${GREEN}✓${NC} Closed GitHub issue #$gh_num" >&2
        else
            echo -e "${YELLOW}Warning: could not close GitHub issue #$gh_num${NC}" >&2
        fi
    fi

    # Refresh parent epic body (checkboxes + Mermaid) after child close
    _refresh_parent_gh "$id"
}

# Append completion record to trails.md (legacy breadcrumbs.md if not yet migrated).
# Args: $1=id
_done_write_trail() {
    local id="$1"

    if [ -z "${WEAVE_DIR:-}" ]; then
        return 0
    fi

    # Skip for custom DB paths (test isolation) — same guard as auto_sync.
    # A caller-supplied WV_DB means the active graph is not this repo's graph;
    # closing a scratch node must not append to the repo's trails.md
    # (codex finding 2026-06-12: temp-graph wv done dirtied repo trail state).
    [ -n "${WV_DB_CUSTOM:-}" ] && return 0

    # Prefer trails.md; only append to the legacy file if it still exists and
    # trails.md does not (cmd_load migrates it on the next load).
    local breadcrumb_file="$WEAVE_DIR/trails.md"
    if [ ! -f "$breadcrumb_file" ] && [ -f "$WEAVE_DIR/breadcrumbs.md" ]; then
        breadcrumb_file="$WEAVE_DIR/breadcrumbs.md"
    fi
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

# _done_close_txn <id> <status-guard> <proposed-metadata-expr> [set-clause]
#
# The close as one write transaction: evaluate the close receipt
# (_policy_close_receipt_sql), then apply the UPDATE only when the receipt allows.
# BEGIN IMMEDIATE holds the write lock from the evaluation to the commit, so no
# threshold, exemption or metric can move between the decision and the close it
# governs. Prints "receipt:<json>" when a clause denied, else one
# "bypass:<json>" per clause the close passed only through quality_exempt
# (_policy_close_bypass_sql), then "changes:<n>". The nodes_policy_check trigger
# still guards the UPDATE, as a backstop only.
#
# Every path that sets status='done' closes through here (wv done, update,
# quick, resolve), so none reaches the trigger without a receipt (wv-957fc8).
# set-clause is the caller's full SET list and must set status='done' and, when
# it changes metadata, the same expression passed as proposed-metadata-expr.
_done_close_txn() {
    local id="$1" guard="$2" proposed="$3" set="${4:-}" id_esc
    id_esc=$(sql_escape "$id")
    [ -n "$set" ] || set="status='done', metadata = $proposed, updated_at = CURRENT_TIMESTAMP"
    db_query "BEGIN IMMEDIATE;
        SELECT 'from:' || status FROM nodes WHERE id='$id_esc';
        CREATE TEMP TABLE close_receipt AS $(_policy_close_receipt_sql "$id_esc" "$proposed");
        SELECT 'receipt:' || receipt FROM temp.close_receipt WHERE receipt IS NOT NULL;
        SELECT 'bypass:' || bypass FROM ($(_policy_close_bypass_sql "$id_esc" "$proposed"))
        WHERE NOT EXISTS (SELECT 1 FROM temp.close_receipt WHERE receipt IS NOT NULL);
        UPDATE nodes
        SET $set
        WHERE id='$id_esc' $guard
          AND NOT EXISTS (SELECT 1 FROM temp.close_receipt WHERE receipt IS NOT NULL);
        SELECT 'changes:' || changes();
        COMMIT;" 2>&1
}

# _done_policy_race_seam check|apply — test-only (WV_TEST_MODE=1 +
# WV_TEST_POLICY_RACE=1, tests/wv-test-hooks.registry): loosen every
# close-policy input after the close transaction has decided and before the
# decision is reported. A report that re-derived the verdict from live policy
# state would now name a different clause, or none. "check" validates the value
# before the close runs, so an unrecognised one fails every close rather than
# only the ones that reach the report.
_done_policy_race_seam() {
    [ -n "${WV_TEST_POLICY_RACE:-}" ] || return 0
    if [ "${WV_TEST_MODE:-}" != "1" ]; then
        [ "$1" = "check" ] && echo "wv done: WV_TEST_POLICY_RACE is set but WV_TEST_MODE=1 is not — ignoring it" >&2
        return 0
    fi
    if [ "$WV_TEST_POLICY_RACE" != "1" ]; then
        echo -e "${RED}Error: WV_TEST_POLICY_RACE='${WV_TEST_POLICY_RACE}' is not a recognised value (1)${NC}" >&2
        return 1
    fi
    [ "$1" = "apply" ] || return 0
    db_query "UPDATE policy_thresholds SET value = 1e9 WHERE key LIKE 'mccabe_max%';
        UPDATE policy_thresholds SET value = 0 WHERE key IN ('trend_deteriorating', 'test_gate');
        INSERT OR IGNORE INTO quality_exempt(path_pattern, reason) VALUES ('%', 'WV_TEST_POLICY_RACE');" >/dev/null
}

# _done_record_policy_receipt <id> <receipt-json>
#
# Record a denying close receipt as the call's verdict, then print the
# human-facing GraphPolicyViolation payload from the same receipt. Nothing here
# queries policy state: the receipt already names the clause and the values it
# was decided on, and a malformed completion scope is input validation rather
# than a policy decision. Returns nonzero when the evidence could not be written.
_done_record_policy_receipt() {
    local id="$1" receipt="$2" rule clause reason rc=0
    rule=$(jq -r '.rule' <<< "$receipt")
    clause=$(jq -c '.clause' <<< "$receipt")
    reason=$(jq -r '.clause.reason // ""' <<< "$receipt")
    case "$rule" in
        completion_scope_integrity)
            if [ "$reason" = "malformed_scope" ]; then
                wv_policy_refusal input_validation "the completion scope has no usable shape" || rc=1
            else
                wv_policy_verdict completion_scope_integrity deny yes "" "$reason" "$clause" || rc=1
            fi ;;
        close_complexity_ceiling)
            wv_policy_verdict close_complexity_ceiling deny no "" "" "$clause" || rc=1 ;;
        close_trend_not_deteriorating)
            wv_policy_verdict close_trend_not_deteriorating deny no "" "" "$clause" || rc=1 ;;
        close_tests_not_red)
            wv_policy_verdict close_tests_not_red deny no "" "" "$clause" || rc=1 ;;
        *)
            wv_policy_refusal infrastructure_failure "the close receipt names no declared rule" || rc=1 ;;
    esac
    echo "GraphPolicyViolation: $(jq -c --arg id "$id" \
        '{error: "GraphPolicyViolation", node_id: $id} + (.clause | del(.reason))
         + (if .clause.reason then {detail: .clause.reason} else {} end)' <<< "$receipt")" >&2
    # wv-6657dd: cmd_done resyncs the policy tables before the close, so a block
    # on a config-exempt path should be impossible; if one slips through anyway,
    # name the drift instead of reporting stale policy as real debt.
    local path
    path=$(jq -r '.clause.path // ""' <<< "$receipt")
    if [ -n "$path" ] && _quality_conf_declares_exempt "$path"; then
        echo -e "${YELLOW}  advisory: $path is exempt in ${WEAVE_DIR}/quality.conf but the enforced quality_exempt table is stale — run 'wv load' to resync${NC}" >&2
    fi
    return "$rc"
}

# _done_close <id> <status-guard> <proposed-metadata-expr> [set-clause]
# Run the close transaction and classify its outcome: a denying receipt, the
# trigger backstop firing (the receipt and trigger disagreed), any other
# database failure, or a node that changed state first.
_done_close() {
    local id="$1" guard="$2" proposed="$3" set="${4:-}" out rc receipt
    _done_policy_race_seam check || return 1
    out=$(_done_close_txn "$id" "$guard" "$proposed" "$set")
    rc=$?
    _done_policy_race_seam apply
    receipt=$(sed -n 's/^receipt://p' <<< "$out")
    if [ -n "$receipt" ]; then
        _done_record_policy_receipt "$id" "$receipt"
        return 1
    fi
    if [ "$rc" -ne 0 ]; then
        if grep -q "GraphPolicyViolation" <<< "$out"; then
            wv_policy_refusal infrastructure_failure "the policy trigger refused a close its receipt allowed"
        fi
        echo "$out" >&2
        return 1
    fi
    if [ "$(sed -n 's/^changes://p' <<< "$out")" != "1" ]; then
        wv_policy_refusal expected_conflict "node changed state between the checks and the close"
        echo -e "${RED}Error: node $id changed state before completion; audit was not written${NC}" >&2
        return 1
    fi
    # The close has committed, so a failed bypass write cannot undo it: evidence
    # mode fails the call closed inside the emitter, and outside it the caller
    # must still finish the close it made.
    local bypass bypassed=""
    while IFS= read -r bypass; do
        [ -n "$bypass" ] || continue
        _done_record_policy_bypass "$bypass"
        bypassed+=" $(jq -r '.rule' <<< "$bypass")"
    done < <(sed -n 's/^bypass://p' <<< "$out")
    # Every clause the receipt judged, and did not see bypassed, let the close
    # through; say so, or the close is never countable (wv-15422b). The
    # receipt only judges active -> done, so any other close did not engage it.
    if [ "$(sed -n 's/^from://p' <<< "$out")" = "active" ]; then
        _close_rules_passed "$bypassed"
    else
        _close_rules_not_engaged "not an active-to-done transition"
    fi
    return 0
}

# _close_rules_passed <bypassed-rules> — the receipt judged the close and no
# clause denied it; a clause already recorded as bypassed is not repeated.
_close_rules_passed() {
    [[ " $1 " == *" close_complexity_ceiling "* ]] ||
        wv_policy_verdict close_complexity_ceiling allow no "" "no touched file over its complexity ceiling"
    [[ " $1 " == *" close_trend_not_deteriorating "* ]] ||
        wv_policy_verdict close_trend_not_deteriorating allow no "" "no touched file on a gated deteriorating trend"
    [[ " $1 " == *" close_tests_not_red "* ]] ||
        wv_policy_verdict close_tests_not_red allow no "" "no touched file with a gated red or stale test"
    wv_policy_verdict completion_scope_integrity allow no "" "the completion scope, if any, is valid"
}

# _close_rules_not_engaged <why> — a call whose operation can close a node
# (update, bulk-update, quick, resolve, ...) but did not perform an
# active-to-done close in this call. The close rules examined it and had
# nothing to refuse; recorded so the call can be countable (wv-15422b).
_close_rules_not_engaged() {
    wv_policy_verdict close_complexity_ceiling allow no "" "$1"
    wv_policy_verdict close_trend_not_deteriorating allow no "" "$1"
    wv_policy_verdict close_tests_not_red allow no "" "$1"
    wv_policy_verdict completion_scope_integrity allow no "" "$1"
}

# _done_record_policy_bypass <bypass-json>
#
# Record a close that a clause would have denied but for quality_exempt as that
# rule's allow, with the exempt pattern as its bypass (wv-ef00f7), the way a
# command gate records its override flag. Only called once the close committed,
# so the allow names a close that happened.
_done_record_policy_bypass() {
    local rule bypass clause
    rule=$(jq -r '.rule' <<< "$1")
    bypass=$(jq -r '.bypass' <<< "$1")
    clause=$(jq -c '.clause' <<< "$1")
    case "$rule" in
        close_complexity_ceiling)
            wv_policy_verdict close_complexity_ceiling allow no "$bypass" "" "$clause" ;;
        close_trend_not_deteriorating)
            wv_policy_verdict close_trend_not_deteriorating allow no "$bypass" "" "$clause" ;;
        close_tests_not_red)
            wv_policy_verdict close_tests_not_red allow no "$bypass" "" "$clause" ;;
        *)
            wv_policy_refusal infrastructure_failure "the close bypass names no declared rule" ;;
    esac
}

# _done_parse_args <args...> — cmd_done's flags into its locals (dynamic scope).
_done_parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --reason=*) reason="${1#*=}" ;;
            --learning=*) learning="${1#*=}" ;;
            --decision=*) decision="${1#*=}" ;;
            --pattern=*) pattern="${1#*=}" ;;
            --pitfall=*) pitfall="${1#*=}" ;;
            --learning-file=*) learning_file="${1#*=}" ;;
            --no-warn) no_warn=1 ;;
            --skip-verification) skip_verification=1 ;;
            --acknowledge-overlap) acknowledge_overlap=1 ;;
            --no-overlap-check) no_overlap_check=1 ;;
            --json) format="json" ;;
            --verification-method=*) verification_method="${1#*=}" ;;
            --verification-evidence=*) verification_evidence="${1#*=}" ;;
            --verification-evidence-file=*) verification_evidence_file="${1#*=}" ;;
            --no-gh) no_gh=1 ;;
            --allowed-tools=*) allowed_tools_raw="${1#--allowed-tools=}" ;;
            --completion-files=*) completion_files_raw="${1#*=}"; completion_files_set=1 ;;
            *) _wv_reject_arg "done" "$1"; return 1 ;;
        esac
        shift
    done
}

# _done_resolve_learning — read the option files and compose the structured
# learning from --decision/--pattern/--pitfall, into cmd_done's locals.
_done_resolve_learning() {
    if [ -n "$learning_file" ]; then
        local _raw_learning
        _raw_learning=$(_done_read_option_file "--learning-file" "$learning_file") || return 1
        # Newline-delimited structured form → pipe-delimited for existing parser
        if grep -qE '^(decision|pattern|pitfall):' <<< "$_raw_learning"; then
            local _ld _lp _lf
            _ld=$(echo "$_raw_learning" | grep '^decision:' | head -1 | sed 's/^decision:[[:space:]]*//')
            _lp=$(echo "$_raw_learning" | grep '^pattern:'  | head -1 | sed 's/^pattern:[[:space:]]*//')
            _lf=$(echo "$_raw_learning" | grep '^pitfall:'  | head -1 | sed 's/^pitfall:[[:space:]]*//')
            learning=""
            [ -n "$_ld" ] && learning="decision: $_ld"
            [ -n "$_lp" ] && learning="${learning:+$learning | }pattern: $_lp"
            [ -n "$_lf" ] && learning="${learning:+$learning | }pitfall: $_lf"
        else
            learning="$_raw_learning"
        fi
    fi
    if [ -n "$verification_evidence_file" ]; then
        verification_evidence=$(_done_read_option_file "--verification-evidence-file" "$verification_evidence_file") || return 1
    fi

    # Explicit learning fields are first-class inputs. Build the structured
    # form for flags-only closes so the existing overlap and hygiene checks run,
    # then let the explicit values override any same-named inline marker.
    if [ -z "$learning" ] && { [ -n "$decision" ] || [ -n "$pattern" ] || [ -n "$pitfall" ]; }; then
        [ -n "$decision" ] && learning="decision: $decision"
        [ -n "$pattern" ] && learning="${learning:+$learning | }pattern: $pattern"
        [ -n "$pitfall" ] && learning="${learning:+$learning | }pitfall: $pitfall"
    fi
    return 0
}

# _done_check_node — the node exists, is not already done, and is active when a
# completion scope is given; sets cmd_done's node_status.
_done_check_node() {
    # Verify node exists
    local exists
    exists=$(db_query "SELECT COUNT(*) FROM nodes WHERE id='$id';")
    if [ "$exists" = "0" ]; then
        wv_policy_refusal input_validation "close names a node that does not exist"
        echo -e "${RED}Error: node $id not found${NC}" >&2
        return 1
    fi
    node_status=$(db_query "SELECT status FROM nodes WHERE id='$id';")
    if [ "$node_status" = "done" ]; then
        wv_policy_refusal expected_conflict "node already closed"
        echo -e "${RED}Error: node $id is already done; completion audit was not changed${NC}" >&2
        return 1
    fi
    if [ "$completion_files_set" = "1" ] && [ "$node_status" != "active" ]; then
        wv_policy_refusal input_validation "--completion-files on a node that is not active"
        echo -e "${RED}Error: --completion-files requires an active node (current: $node_status)${NC}" >&2
        return 1
    fi
    return 0
}

# _done_build_scope — validate --completion-files and build cmd_done's
# scope_json/scope_object/scope_esc.
_done_build_scope() {
    # A completion scope narrows quality policy only; node_files remains an
    # append-only impact history. Require canonical repo-relative paths and
    # existing attribution before durably recording the audited scope.
    if [ "$completion_files_set" = "1" ]; then
        scope_json='[]'
        local scope_path scope_count
        IFS=',' read -ra _done_scope_parts <<< "$completion_files_raw"
        for scope_path in "${_done_scope_parts[@]}"; do
            if [ -z "$scope_path" ] || [[ "$scope_path" = /* ]] || [[ "$scope_path" = ./* ]] ||
               [[ "$scope_path" = */ ]] || [[ "$scope_path" = *//* ]] ||
               [[ "/$scope_path/" = */./* ]] || [[ "/$scope_path/" = */../* ]]; then
                wv_policy_refusal input_validation "--completion-files path is not normalized and repo-relative"
                echo -e "${RED}Error: --completion-files requires nonempty normalized repo-relative paths (invalid: '$scope_path')${NC}" >&2
                return 1
            fi
            scope_count=$(db_query "SELECT COUNT(*) FROM node_files WHERE node_id='$id' AND path='$(sql_escape "$scope_path")';" 2>/dev/null || echo 0)
            if [ "$scope_count" = "0" ]; then
                wv_policy_verdict completion_scope_integrity deny yes "" \
                    "completion scoped to a file the node never touched"
                echo -e "${RED}Error: completion file '$scope_path' is not attributed to node $id${NC}" >&2
                return 1
            fi
            scope_json=$(jq -c --arg p "$scope_path" '. + [$p] | unique' <<< "$scope_json")
        done
        [ "$(jq 'length' <<< "$scope_json")" -gt 0 ] || { echo -e "${RED}Error: --completion-files cannot be empty${NC}" >&2; return 1; }
        scope_object=$(jq -cn --argjson files "$scope_json" --arg set_at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" --arg attempt_id "$(date +%s%N)-$$-$RANDOM" '{files:$files,set_at:$set_at,attempt_id:$attempt_id}')
        scope_esc=$(sql_escape "$scope_object")
    fi
    return 0
}

# _done_write_verification — persist inline --verification-* metadata before
# the close, so the pre-close hook sees it on any re-check.
_done_write_verification() {
    # Write inline verification metadata immediately so the pre-close hook
    # sees it on any subsequent re-check (and for auditability).
    if [ -n "$verification_method" ] || [ -n "$verification_evidence" ]; then
        local ver_json ver_json_esc
        ver_json=$(jq -n \
            --arg m "$verification_method" \
            --arg e "$verification_evidence" \
            '{verification_method: $m, verification_evidence: $e} | with_entries(select(.value != ""))')
        ver_json_esc="${ver_json//\'/\'\'}"
        if ! db_query "UPDATE nodes
            SET metadata = json_patch(COALESCE(metadata,'{}'), json('$ver_json_esc'))
            WHERE id='$id';"; then
            echo -e "${RED}Error: failed to write verification metadata for $id — node not closed${NC}" >&2
            return 1
        fi
    fi
    return 0
}

# _done_gate_pending — close_awaits_human_verification: returns 2 while the node
# waits for human verification, unless --acknowledge-overlap; may restore the
# pending learning into cmd_done's learning.
_done_gate_pending() {
    local pending_reason pending_resume_cmd
    pending_reason=$(echo "$node_meta" | jq -r '.pending_close.reason // empty' 2>/dev/null || echo "")
    pending_resume_cmd=$(echo "$node_meta" | jq -r '.pending_close.resume_command // empty' 2>/dev/null || echo "")
    if [ -n "$pending_reason" ] && [ "$acknowledge_overlap" = "1" ]; then
        wv_policy_verdict close_awaits_human_verification allow yes --acknowledge-overlap \
            "closed while waiting for human verification"
    elif [ -n "$pending_reason" ]; then
        wv_policy_verdict close_awaits_human_verification deny yes "" \
            "the node is waiting for human verification"
        echo -e "${YELLOW}⚠ Node $id is waiting for human verification before close${NC}" >&2
        if [ -n "$pending_resume_cmd" ]; then
            echo -e "${YELLOW}  Resume with: $pending_resume_cmd${NC}" >&2
        fi
        return 2
    fi
    [ -n "$pending_reason" ] ||
        wv_policy_verdict close_awaits_human_verification allow no "" "not waiting for human verification"
    if [ "$acknowledge_overlap" = "1" ] && [ -z "$learning" ]; then
        learning=$(echo "$node_meta" | jq -r '.pending_close.learning // empty' 2>/dev/null || echo "")
    fi
    return 0
}

# _done_gate_learning — close_requires_learning, recording which bypass (if any)
# let a learning-less close through.
_done_gate_learning() {
    # Require --learning or --skip-verification for closure quality
    # Bypass: WV_REQUIRE_LEARNING=0 (for tests), --no-warn (for recovery/internal)
    # A close with no learning records which bypass let it through.
    if [ -z "$learning" ]; then
        local learning_bypass=""
        if [ "$skip_verification" != "0" ]; then learning_bypass="--skip-verification"
        elif [ "$no_warn" != "0" ]; then learning_bypass="--no-warn"
        elif [ "${WV_REQUIRE_LEARNING:-1}" != "1" ]; then learning_bypass="WV_REQUIRE_LEARNING=0"
        fi
        [ -n "$learning_bypass" ] && wv_policy_verdict close_requires_learning allow no "$learning_bypass" \
            "closed without a learning"
    else
        wv_policy_verdict close_requires_learning allow no "" "the close records a learning"
    fi
    if [ "${WV_REQUIRE_LEARNING:-1}" = "1" ] && [ -z "$learning" ] && [ "$skip_verification" = "0" ] && [ "$no_warn" = "0" ]; then
        wv_policy_verdict close_requires_learning deny no "" "a close records what the next session would get wrong"
        echo -e "${RED}Error: --learning=\"...\" or --skip-verification required${NC}" >&2
        echo -e "  Capture what future sessions would get wrong without this:" >&2
        echo -e "  wv done $id --learning=\"...\" --verification-method=\"make check\" --verification-evidence=\"N passed\"" >&2
        echo -e "  wv done $id --skip-verification  # for trivial work" >&2
        return 1
    fi
    return 0
}

# _done_warn_childless_epic — advisory for an epic closed with no implements children.
_done_warn_childless_epic() {
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
    return 0
}

# _done_apply_learning_and_tools — store the learning (returns 2 when overlap
# parks the close as pending) and any --allowed-tools.
_done_apply_learning_and_tools() {
    # Store learning in metadata if provided
    if [ -n "$learning" ]; then
        # Strip ANSI escape codes (color sequences leak from terminal output)
        learning=$(printf '%s' "$learning" | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g')
        _done_store_learning "$id" "$learning" "$acknowledge_overlap" "$no_overlap_check" \
            "$decision" "$pattern" "$pitfall"
        if [ "$_done_pending_close" = true ]; then
            return 2
        fi
    else
        wv_policy_verdict learning_overlap_advisory allow no "" "no learning to compare"
    fi

    # Write allowed_tools to metadata if supplied at close time
    if [ -n "$allowed_tools_raw" ]; then
        local tools_json
        tools_json=$(_parse_allowed_tools "$allowed_tools_raw")
        if [ -n "$tools_json" ]; then
            local tools_esc="${tools_json//\'/\'\'}"
            db_query "UPDATE nodes SET metadata=json_set(COALESCE(metadata,'{}'), '\$.allowed_tools', json('$tools_esc')), updated_at=CURRENT_TIMESTAMP WHERE id='$(sql_escape "$id")';" 2>/dev/null || true
        fi
    fi
    return 0
}

# _done_report — the close's JSON or text report, including the stored learning keys.
_done_report() {
    local historical_files policy_files scope_mode
    historical_files=$(db_query "SELECT COUNT(*) FROM node_files WHERE node_id='$(sql_escape "$id")';" 2>/dev/null || echo 0)
    policy_files="$historical_files"
    scope_mode="legacy"
    if [ "$completion_files_set" = "1" ]; then
        policy_files=$(jq 'length' <<< "$scope_json")
        scope_mode="explicit"
    fi

    if [ "$format" = "json" ]; then
        local text
        text=$(db_query "SELECT text FROM nodes WHERE id='$id';")
        jq -n --arg id "$id" --arg text "$text" --arg status "done" \
            --arg scope_mode "$scope_mode" --argjson historical_files "$historical_files" --argjson policy_files "$policy_files" \
            '{"id": $id, "text": $text, "status": $status, "completion_scope": {"mode": $scope_mode, "historical_files": $historical_files, "policy_files": $policy_files}}'
    else
        echo -e "${GREEN}✓${NC} Closed: $id"
        echo "  Completion scope: $scope_mode ($policy_files policy / $historical_files historical files)"
        # Show what learning was actually stored — makes silent loss immediately visible
        if [ -n "$learning" ]; then
            local _l_meta _l_keys _l_hygiene
            _l_meta=$(db_query "SELECT metadata FROM nodes WHERE id='$id';" 2>/dev/null || echo "{}")
            _l_keys=$(echo "$_l_meta" | jq -r '
                [ (if .decision then "decision" else empty end),
                  (if .pattern  then "pattern"  else empty end),
                  (if .pitfall  then "pitfall"  else empty end),
                  (if .learning then "learning" else empty end)
                ] | join(", ")
            ' 2>/dev/null || echo "")
            _l_hygiene=$(echo "$_l_meta" | jq -r '.learning_hygiene // empty' 2>/dev/null || echo "")
            if [ -n "$_l_keys" ]; then
                if [ -n "$_l_hygiene" ]; then
                    echo "  Learning saved: $_l_keys (hygiene: $_l_hygiene)"
                else
                    echo "  Learning saved: $_l_keys"
                fi
            else
                echo -e "${YELLOW}  ⚠ Learning was not saved${NC}" >&2
            fi
        fi
    fi
}

# _done_post_close_advisories — write-time validation, the test_gate=warn
# advisory and open findings; sets the closing phase between them.
_done_post_close_advisories() {
    # Write-time validation warnings (stderr; suppress for --skip-verification / --json / --no-warn)
    if [ "$no_warn" != "1" ] && [ "${WV_NO_WARN:-0}" != "1" ] && [ "$skip_verification" != "1" ] && [ "$format" != "json" ]; then
        validate_on_done "$id"
    fi

    # Test-correctness advisory (P6c, test_gate=warn). At test_gate=1 the trigger
    # does NOT abort (it only fires at >=2); surface red/stale touched files as a
    # non-blocking warning so the soft level still has teeth. The query honors
    # quality_exempt and node-type exemptions (mirroring the trigger's block clause);
    # the standard suppression flags silence it. block (>=2) already hard-blocked
    # above, so this only adds signal at the warn level.
    if [ "$no_warn" != "1" ] && [ "${WV_NO_WARN:-0}" != "1" ] && [ "$skip_verification" != "1" ] && [ "$format" != "json" ]; then
        local _tg_level
        _tg_level=$(db_query "SELECT CAST(value AS INTEGER) FROM policy_thresholds WHERE key='test_gate';" 2>/dev/null || echo "0")
        if [ "${_tg_level:-0}" = "1" ]; then
            local _tg_bad
            _tg_bad=$(db_query "
                SELECT nf.path || ' (' || fts.state || ')'
                FROM node_files nf
                JOIN nodes n ON n.id=nf.node_id
                JOIN file_test_status fts ON fts.path = nf.path
                WHERE nf.node_id='$(sql_escape "$id")'
                  AND (json_type(n.metadata, '\$.completion_scope.files') IS NULL
                       OR nf.path IN (SELECT value FROM json_each(n.metadata, '\$.completion_scope.files')))
                  AND fts.state IN ('red','stale')
                  AND COALESCE((SELECT json_extract(metadata, '\$.type') FROM nodes WHERE id='$(sql_escape "$id")'), '') NOT IN ('finding','epic','session_history')
                  AND NOT EXISTS (
                      SELECT 1 FROM quality_exempt qe
                      WHERE nf.path LIKE CASE WHEN qe.path_pattern LIKE '%/' THEN qe.path_pattern || '%' ELSE qe.path_pattern END
                  );
            " 2>/dev/null || true)
            if [ -n "$_tg_bad" ]; then
                echo -e "${YELLOW}  ⚠ Test correctness (test_gate=warn) — touched files without a fresh green result:${NC}" >&2
                while IFS= read -r _p; do
                    [ -n "$_p" ] && echo -e "    ${YELLOW}·${NC} $_p" >&2
                done <<< "$_tg_bad"
                echo -e "    ${YELLOW}Re-run the mapped suite(s), or set test_gate=block to enforce.${NC}" >&2
            fi
        fi
    fi

    wv_set_phase "closing"

    # Advisory: open finding nodes that reference this node as source_node.
    # Emitted on close so the author can triage while context is fresh.
    if [ "$format" != "json" ] && [ "${WV_NO_WARN:-0}" != "1" ]; then
        local _open_findings
        _open_findings=$(db_query "
            SELECT id || ' — ' || substr(text, 1, 60)
            FROM nodes
            WHERE json_extract(metadata, '\$.source_node') = '$id'
              AND json_extract(metadata, '\$.type') = 'finding'
              AND status != 'done';
        " 2>/dev/null || true)
        if [ -n "$_open_findings" ]; then
            echo -e "${YELLOW}  ⚠ Open findings referencing this node — review or close:${NC}" >&2
            while IFS= read -r _f; do
                echo -e "    ${YELLOW}·${NC} $_f" >&2
            done <<< "$_open_findings"
        fi
    fi
}

# _done_commit_close — the close itself: status, released claim, completion
# scope, primary, commit aggregation and the unblock cascade.
_done_commit_close() {
    # === Close: update status, release claim, clear primary, aggregate commits ===
    local completion_metadata_expr="json_remove(COALESCE(metadata,'{}'), '$.claimed_by', '$.pending_close', '$.needs_human_verification', '$.completion_scope')"
    if [ "$completion_files_set" = "1" ]; then
        completion_metadata_expr="json_set(json_remove(COALESCE(metadata,'{}'), '$.claimed_by', '$.pending_close', '$.needs_human_verification'), '$.completion_scope', json('$scope_esc'))"
    fi
    if [ "${_WV_SHIP_DURABLE_CLOSE:-0}" = "1" ]; then
        completion_metadata_expr="json_set($completion_metadata_expr, '$.ship_pending', json('true'), '$.ship_pending_mode', 'post_close')"
    fi
    local done_status_guard="AND status='$(sql_escape "$node_status")'"
    _done_close "$id" "$done_status_guard" "$completion_metadata_expr" || return 1

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
    return 0
}

# _done_post_close_notify — GitHub issue close, context cache and progress notification.
_done_post_close_notify() {
    # === Post-close: GH issue, cache, notifications, trails ===
    [ "$no_gh" = "0" ] && _done_close_gh_issue "$id"

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
}

cmd_done() {
    local id="${1:-}"
    local reason=""
    local learning=""
    local decision=""
    local pattern=""
    local pitfall=""
    local learning_file=""
    local no_warn=0
    local skip_verification=0
    local acknowledge_overlap=0
    local no_overlap_check=0
    local format="text"
    local verification_method=""
    local verification_evidence=""
    local verification_evidence_file=""
    local no_gh=0
    local allowed_tools_raw=""
    local completion_files_raw=""
    local completion_files_set=0

    shift || true
    _done_parse_args "$@" || return 1

    _done_resolve_learning || return 1

    if [ -z "$id" ]; then
        echo -e "${RED}Error: node ID required${NC}" >&2
        return 1
    fi

    # Validate ID format (SQL injection prevention)
    validate_id "$id" || return 1

    # wv-6657dd: the quality gate is a SQL trigger reading the quality_exempt
    # and policy_thresholds TABLES, which only _load_quality_config writes. Sync
    # them from .weave/quality.conf before the close can fire that trigger, so
    # the gate enforces the committed policy rather than whatever was loaded
    # last. Cheap: two file hashes, and a reload only when they changed.
    _ensure_quality_config_fresh 2>/dev/null || true

    local node_status
    _done_check_node || return 1

    local scope_json="" scope_object="" scope_esc=""
    _done_build_scope || return 1

    _done_write_verification || return 1

    local node_meta
    node_meta=$(_done_read_metadata "$id")
    _done_gate_pending || return $?

    _done_require_finding_metadata "$id" "$node_meta" || return 1

    _done_gate_learning || return 1

    _done_warn_childless_epic

    _done_apply_learning_and_tools || return $?

    # Refresh file_metrics and trend signals from quality.db before the gate UPDATE.
    _done_refresh_file_metrics "$id" "$scope_json" || return 1
    _done_refresh_trend_signals "$id" "$scope_json" || return 1
    # Refresh test-correctness status from the ledger (best-effort; never blocks).
    _done_refresh_test_status "$id" "$scope_json" || true

    _done_commit_close || return 1

    # Durability gate (wv-18841c). Every mutation this closure makes to the graph
    # is above this line; everything below reports it or acts on it. Refusing
    # here is what keeps the GitHub issue open, the trail unwritten and the
    # "✓ Closed" line unprinted when the closure did not reach state.sql — a
    # closed issue over a vanished closure is worse than no closure at all.
    persist_or_refuse "$id" --force || return 1

    _done_report

    _done_post_close_advisories

    _done_post_close_notify

    _done_write_trail "$id"
    # Second persist, for the post-close writes only (cache invalidation, the
    # unblock cascade's own rows). The closure itself was already gated above,
    # so a failure here cannot make a reported closure a lie — it warns.
    auto_sync_or_warn --force
}

# ═══════════════════════════════════════════════════════════════════════════
# cmd_batch_done — Close multiple nodes at once
# ═══════════════════════════════════════════════════════════════════════════

cmd_batch_done() {
    local learning=""
    local no_warn=0
    local no_gh=0
    local ids=()

    while [ $# -gt 0 ]; do
        case "$1" in
            --learning=*) learning="${1#*=}" ;;
            --no-warn) no_warn=1 ;;
            --no-gh) no_gh=1 ;;
            wv-*) ids+=("$1") ;;
        esac
        shift
    done

    if [ ${#ids[@]} -eq 0 ]; then
        echo -e "${RED}Error: at least one node ID required${NC}" >&2
        echo "Usage: wv batch-done <id1> <id2> ... [--learning=\"...\"] [--no-warn] [--no-gh]" >&2
        return 1
    fi

    local closed=0 failed=0
    for id in "${ids[@]}"; do
        local args=("$id")
        [ -n "$learning" ] && args+=("--learning=$learning")
        [ "$no_warn" = "1" ] && args+=("--no-warn")
        [ "$no_gh" = "1" ] && args+=("--no-gh")

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

    # Read JSON from stdin. The terminal check alone let an inherited idle pipe
    # through to a `cat` that never returns (wv-f541e1).
    #
    # stdin_has_input answers "a read will not block", and EOF satisfies that,
    # so an empty or whitespace-only stream still arrives here. Emptiness is the
    # caller's question, not the probe's: jq emits no value for empty input and
    # exits 0, so the array check below passed, `count` came back empty, and
    # `[ "" -eq 0 ]` raised an integer error while the command still reported
    # success (wv-2c5615).
    local input=""
    if stdin_has_input; then
        input=$(cat)
    fi
    if [[ -z "${input//[[:space:]]/}" ]]; then
        echo -e "${RED}Error: no input on stdin${NC}" >&2
        echo "Usage: echo '[{\"id\":\"wv-xxxxxx\",\"alias\":\"test\"}]' | wv bulk-update" >&2
        return 1
    fi

    # Validate JSON array
    if ! echo "$input" | jq 'if type == "array" then . else error("not an array") end' >/dev/null 2>&1; then
        echo -e "${RED}Error: stdin must be a JSON array${NC}" >&2
        return 1
    fi

    local count
    count=$(echo "$input" | jq 'length' 2>/dev/null)
    # A non-numeric length is not a countable array, whatever jq exited with —
    # comparing it arithmetically is what produced the bogus integer error.
    if [[ ! "$count" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}Error: stdin must be a JSON array${NC}" >&2
        return 1
    fi
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
            resolved=$(db_query "SELECT id FROM nodes WHERE alias='$(sql_escape "$item_id")' ORDER BY CASE WHEN status='done' THEN 1 ELSE 0 END LIMIT 1;")
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
            resolved=$(db_query "SELECT id FROM nodes WHERE alias='$(sql_escape "$item_id")' ORDER BY CASE WHEN status='done' THEN 1 ELSE 0 END LIMIT 1;")
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
                if ! validate_metadata_key "$key"; then
                    echo -e "${RED}Skipping invalid key '$key' for $item_id${NC}" >&2
                    continue
                fi
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

    auto_sync_or_warn
}

# ═══════════════════════════════════════════════════════════════════════════
# cmd_work — Claim a node and set up subagent context inheritance
# ═══════════════════════════════════════════════════════════════════════════

# _work_claim_failed <id> <format> <detail> — a claim that did not persist is an
# infrastructure failure, not a policy decision or a lost race: record it as such
# and say so, with no success banner and a nonzero exit (wv-03d775).
_work_claim_failed() {
    local id="$1" format="$2" detail="$3"
    wv_policy_refusal infrastructure_failure "claim did not persist: $detail"
    if [ "$format" = "json" ]; then
        jq -n --arg id "$id" --arg detail "$detail" \
            '{"ok": false, "error": "claim_not_persisted", "detail": $detail, "id": $id}' >&2
    else
        echo -e "${RED}✗ $id was not claimed: $detail${NC}" >&2
    fi
}

cmd_work() {
    # Check for incomplete operations before claiming new work
    # Auto-clear if the stale operation is >30 minutes old (likely a failed sync from a prior session)
    if journal_has_incomplete 2>/dev/null; then
        if journal_clear_stale 2>/dev/null; then
            echo -e "${CYAN}ℹ Cleared stale operation marker (>30 min old)${NC}" >&2
        else
            echo -e "${YELLOW}⚠ Incomplete operation detected — run 'wv recover' first${NC}" >&2
        fi
    fi

    local id="${1:-}"
    local quiet=false
    local force=false
    local reopen=false
    local format="text"
    local allowed_tools_raw=""

    shift || true
    while [ $# -gt 0 ]; do
        case "$1" in
            --quiet|-q) quiet=true ;;
            --force|-f) force=true ;;
            --reopen)   reopen=true ;;
            --json)     format="json" ;;
            --allowed-tools=*) allowed_tools_raw="${1#--allowed-tools=}" ;;
            *) _wv_reject_arg work "$1"; return 1 ;;
        esac
        shift
    done

    if [ -z "$id" ]; then
        wv_policy_refusal input_validation "claim names no node"
        echo -e "${RED}Error: node ID required${NC}" >&2
        echo "Usage: wv work <id> [--quiet] [--force] [--reopen] [--json] [--allowed-tools=t1,t2,...]" >&2
        echo "" >&2
        echo "Claims a node and sets WV_ACTIVE for subagent context inheritance." >&2
        echo "Use --force to override a stale claim from another agent." >&2
        echo "Use --reopen to explicitly move a done node back to active tracked work." >&2
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
        wv_policy_refusal input_validation "claim names a node that does not exist"
        echo -e "${RED}Error: node $id not found${NC}" >&2
        return 1
    fi

    # Reservation guard (wv-0060db). A reserved node is the measured task for a
    # counted capture: fixing it as ordinary work consumes the slot and cannot
    # be undone, which is what happened to wv-5850d4 on 2026-08-17. The node
    # already carried that warning in metadata and nothing read it.
    #
    # Deliberately NOT bypassed by --force. --force is the routine way to take a
    # node another agent has claimed, so if it also cleared reservations the
    # guard would be off in exactly the situation it is written for. The
    # override is separate and explicit, and it names the capture in the log.
    local _reserved _reserved_slot _reserved_note
    _reserved=$(db_query "SELECT COALESCE(json_extract(metadata, '\$.e5_reserved'), json_extract(metadata, '\$.reserved'), '') FROM nodes WHERE id='$id';" 2>/dev/null | tr -d '[:space:]')
    if [ "$_reserved" = "1" ] || [ "$_reserved" = "true" ]; then
        if [ "${WV_ALLOW_RESERVED:-0}" != "1" ]; then
            _reserved_slot=$(db_query "SELECT COALESCE(json_extract(metadata, '\$.e5_slot'), 'unnamed') FROM nodes WHERE id='$id';" 2>/dev/null)
            _reserved_note=$(db_query "SELECT COALESCE(json_extract(metadata, '\$.reservation_note'), json_extract(metadata, '\$.RESERVED_DO_NOT_FIX'), '') FROM nodes WHERE id='$id';" 2>/dev/null)
            wv_policy_verdict reserved_slot_claim deny yes "" \
                "claiming a reserved node as ordinary work consumes its capture slot"
            echo -e "${RED}Error: $id is RESERVED for counted capture slot ${_reserved_slot} — refusing to claim${NC}" >&2
            [ -n "$_reserved_note" ] && echo -e "${YELLOW}  $_reserved_note${NC}" >&2
            echo -e "${YELLOW}  Fixing it as ordinary work consumes the slot and cannot be undone.${NC}" >&2
            echo -e "${YELLOW}  If this IS the counted capture: WV_ALLOW_RESERVED=1 wv work $id${NC}" >&2
            echo -e "${YELLOW}  --force does not bypass a reservation.${NC}" >&2
            return 1
        fi
        wv_policy_verdict reserved_slot_claim allow yes WV_ALLOW_RESERVED=1 \
            "reserved node claimed for its counted capture"
        echo -e "${YELLOW}⚠ Claiming RESERVED node $id under WV_ALLOW_RESERVED=1 — this consumes its capture slot${NC}" >&2
    else
        wv_policy_verdict reserved_slot_claim allow no "" "not a reserved node"
    fi

    local current_status
    current_status=$(db_query "SELECT status FROM nodes WHERE id='$id';" 2>/dev/null | tr -d '[:space:]')
    if [ "$current_status" = "done" ] && [ "$reopen" = true ]; then
        wv_policy_verdict reopen_requires_explicit_intent allow yes --reopen "done node reopened explicitly"
    elif [ "$current_status" = "done" ]; then
        wv_policy_verdict reopen_requires_explicit_intent deny yes "" "a claim would silently reopen a done node"
        echo -e "${RED}Error: node $id is done; use 'wv work $id --reopen' to explicitly reopen it${NC}" >&2
        return 1
    else
        wv_policy_verdict reopen_requires_explicit_intent allow no "" "not a done node"
    fi

    # Resolve agent identity (strip quotes for SQL safety)
    local agent_id
    agent_id="$(sql_escape "$(resolve_agent_id)")"

    # Atomic CAS claim: succeeds only if unclaimed or already claimed by this agent.
    # A write that fails or rolls back (an FTS trigger error, a locked database)
    # must not be reported as a claim (wv-03d775): only a numeric changes() from
    # a query that succeeded is a result, and success is re-read from the row.
    local claim_changes
    if ! claim_changes=$(db_query "
        UPDATE nodes
        SET metadata = json_set(COALESCE(metadata,'{}'), '$.claimed_by', '$agent_id'),
            status = 'active',
            updated_at = CURRENT_TIMESTAMP
        WHERE id = '$id'
          AND (json_extract(metadata, '$.claimed_by') IS NULL
               OR json_extract(metadata, '$.claimed_by') = '$agent_id');
        SELECT changes();
    ") || [[ ! "$claim_changes" =~ ^[0-9]+$ ]]; then
        _work_claim_failed "$id" "$format" "the claim write failed"
        return 1
    fi

    if [ "$claim_changes" != "0" ]; then
        wv_policy_verdict claim_ownership allow no "" "unclaimed, or already this agent's"
    else
        # Claim lost — another agent holds it
        local holder
        holder=$(db_query "SELECT json_extract(metadata, '$.claimed_by') FROM nodes WHERE id='$id';")
        if [ "$force" = true ]; then
            wv_policy_verdict claim_ownership allow yes --force "took over a claim held by another agent"
            [ "$format" != "json" ] && echo -e "${YELLOW}⚠ Overriding stale claim held by: $holder${NC}" >&2
            if ! db_query "UPDATE nodes
                SET metadata = json_set(COALESCE(metadata,'{}'), '$.claimed_by', '$agent_id'),
                    status = 'active',
                    updated_at = CURRENT_TIMESTAMP
                WHERE id = '$id';"; then
                _work_claim_failed "$id" "$format" "the forced claim write failed"
                return 1
            fi
        else
            # The CAS cannot tell a live holder from a race this call just lost,
            # so the refusal is a conflict, not a counterweight decision.
            wv_policy_refusal expected_conflict "claim lost: another agent holds the node"
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

    # Report a claim only once the row says so.
    local persisted
    persisted=$(db_query "SELECT status || '|' || COALESCE(json_extract(metadata, '$.claimed_by'), '')
        FROM nodes WHERE id='$id';" 2>/dev/null) || persisted=""
    if [ "$persisted" != "active|$agent_id" ]; then
        _work_claim_failed "$id" "$format" "the node did not persist as active and claimed (found: ${persisted:-nothing})"
        return 1
    fi

    set_primary_node "$id"
    wv_set_phase "execute"

    if [ "$current_status" = "done" ]; then
        db_query "UPDATE nodes
            SET metadata = json_set(COALESCE(metadata,'{}'),
                    '\$.reopened_at', strftime('%Y-%m-%dT%H:%M:%SZ', 'now'),
                    '\$.reopened_by_work', json('true')),
                updated_at = CURRENT_TIMESTAMP
            WHERE id = '$id';" 2>/dev/null || true
        if [ -n "${WV_CALL_LOG:-}" ]; then
            printf '{"ts":%s,"cmd":"wv work","event":"reopen_done_node","node_id":"%s","source":"shell"}\n' \
                "$(date +%s.%6N)" "$id" >> "$WV_CALL_LOG" 2>/dev/null || true
        fi
    fi

    # Write allowed_tools to metadata if supplied
    if [ -n "$allowed_tools_raw" ]; then
        local tools_json
        tools_json=$(_parse_allowed_tools "$allowed_tools_raw")
        if [ -n "$tools_json" ]; then
            local tools_esc="${tools_json//\'/\'\'}"
            db_query "UPDATE nodes SET metadata=json_set(COALESCE(metadata,'{}'), '\$.allowed_tools', json('$tools_esc')), updated_at=CURRENT_TIMESTAMP WHERE id='$(sql_escape "$id")';" 2>/dev/null || true
        fi
    fi

    if [ "$format" = "json" ]; then
        # Structured output for runtime consumption
        local text
        text=$(db_query "SELECT text FROM nodes WHERE id='$id';")
        local reopened_json=false
        [ "$current_status" = "done" ] && reopened_json=true
        jq -n --arg id "$id" --arg text "$text" --arg status "active" --argjson reopened "$reopened_json" \
            '{"id": $id, "text": $text, "status": $status, "reopened": $reopened}'
        return 0
    fi

    if [ "$quiet" = true ]; then
        # Machine-readable output for eval
        echo "export WV_ACTIVE=$id"
    else
        # Human-readable output
        local text
        text=$(db_query "SELECT text FROM nodes WHERE id='$id';")
        if [ "$current_status" = "done" ]; then
            echo -e "${GREEN}✓${NC} Reopened: $id"
        else
            echo -e "${GREEN}✓${NC} Claimed: $id"
        fi
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
        # Suppressed when node text already contains actionable verbs — well-specified tasks
        # don't need this hint because the description IS the acceptance criteria.
        local has_criteria
        has_criteria=$(db_query "
            SELECT COUNT(*) FROM nodes WHERE id='$id'
            AND json_extract(metadata, '\$.done_criteria') IS NOT NULL;
        " 2>/dev/null || echo "0")
        if [ "$has_criteria" = "0" ]; then
            local node_text node_text_lower has_verb verb
            node_text=$(db_query "SELECT text FROM nodes WHERE id='$id';" 2>/dev/null || echo "")
            node_text_lower=$(echo "$node_text" | tr '[:upper:]' '[:lower:]')
            has_verb=false
            for verb in add implement test wire extend fix update create build remove delete refactor extract migrate resolve write setup; do
                if [[ "$node_text_lower" == *"$verb"* ]]; then
                    has_verb=true
                    break
                fi
            done
            if [ "$has_verb" = false ]; then
                echo ""
                echo -e "${YELLOW}  Hint: No done_criteria set. Define acceptance criteria:${NC}" >&2
                echo -e "${YELLOW}    wv update $id --metadata='{\"done_criteria\":\"tests pass, docs updated\"}'${NC}" >&2
            fi
        fi
    fi

    # Live progress notification to GitHub
    gh_notify "$id" "work"
}

# ─── _ready_enrich_impact ────────────────────────────────────────────────────
# Enriches a JSON array of ready nodes with a per-node "impact" key.
# Calls `wv impact --json <id>` once per node; failures produce a null stub.
_ready_enrich_impact() {
    local nodes_json="$1"
    local -a ids
    mapfile -t ids < <(printf '%s' "$nodes_json" | jq -r '.[].id' 2>/dev/null)
    if [ ${#ids[@]} -eq 0 ]; then
        echo "$nodes_json"
        return
    fi
    local impact_arr='[]'
    for nid in "${ids[@]}"; do
        local imp
        imp=$("$WV_CLI" impact --json "$nid" 2>/dev/null || echo 'null')
        impact_arr=$(printf '%s' "$impact_arr" | jq --argjson x "$imp" '. + [$x]' 2>/dev/null || echo "$impact_arr")
    done
    printf '%s' "$nodes_json" | jq --argjson impacts "$impact_arr" \
        '[range(length) as $i | .[$i] + {impact: $impacts[$i]}]' 2>/dev/null || echo "$nodes_json"
}

# ═══════════════════════════════════════════════════════════════════════════
# cmd_ready — Show nodes ready to work on
# ═══════════════════════════════════════════════════════════════════════════

cmd_ready() {
    local format="text"
    local count_only=false
    local show_all=false
    local subtree_id=""
    local show_findings=false
    local mode_arg=""
    local with_impact=false

    while [ $# -gt 0 ]; do
        case "$1" in
            --json)        format="json" ;;
            --json-v2)     format="json-v2" ;;
            --count)       count_only=true ;;
            --all)         show_all=true ;;
            --subtree=*)   subtree_id="${1#--subtree=}" ;;
            --subtree)     shift; subtree_id="${1:-}" ;;
            --findings)    show_findings=true ;;
            --mode=*)      mode_arg="${1#--mode=}" ;;
            --with-impact) with_impact=true ;;
        esac
        shift
    done
    local mode
    mode=$(wv_resolve_mode "$mode_arg")

    # Auto-suppress findings digest in agent/non-tty contexts unless explicitly requested
    if [ "$format" = "json" ] || { [ ! -t 1 ] && [ "$show_findings" = false ]; } || { [ "${WV_AGENT:-0}" = "1" ] && [ "$show_findings" = false ]; }; then
        show_findings=false
    fi

    # Agent identity for claim filtering (same default as cmd_work)
    local agent_id
    agent_id="$(sql_escape "$(resolve_agent_id)")"

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

    # Ready = todo status AND not a special non-work node (surfaced separately) AND
    # not blocked by the UNIFIED signal (status/deferral/edge). wv_blocking_reason
    # is the single source shared with cmd_context so a metadata-deferred node cannot
    # look ready here while the runtime sees it blocked — or vice versa (wv-f752a5).
    # Reserved nodes are not ready work. A reservation says "this node is the
    # measured task for a counted capture; fixing it as ordinary work consumes
    # the slot" -- and until now that lived only as prose in metadata that
    # nothing read, while the node sat in ready looking like an easy win. That
    # is exactly how wv-5850d4 was consumed on 2026-08-17 (wv-0060db).
    # --all still shows them, so the reservation hides work without losing it.
    local reserved_pred="COALESCE(json_extract(n.metadata, '\$.e5_reserved'), json_extract(n.metadata, '\$.reserved'), 0) IN (1, 'true')"
    local ready_where="
        n.status = 'todo'
        AND COALESCE(json_extract(n.metadata, '\$.type'), '') NOT IN ('finding', 'memory')
        AND ($(wv_blocking_reason n)) IS NULL
    "
    local reserved_filter=""
    if [ "$show_all" = false ]; then
        reserved_filter=" AND NOT ($reserved_pred)"
    fi
    ready_where="$ready_where $reserved_filter"

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

    # Relevance boost (B1): re-rank ready nodes whose metadata.touched_files
    # overlaps the per-session recent-edits ring. Boosted nodes float to top.
    # Falls back to default ordering when ring is empty or unreadable.
    local _rel_expr="0"
    local _rel_order="n.created_at ASC, n.id ASC"
    local _ring_file
    local _repo_root _repo_hash
    _repo_root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
    _repo_hash=$(echo "$_repo_root" | md5sum 2>/dev/null | cut -c1-8 || echo "default")
    [ -z "$_repo_hash" ] && _repo_hash="default"
    _ring_file="${WV_TOUCHED_DIR:-/dev/shm/weave/${_repo_hash}}/recent-edits.txt"
    if [ -f "$_ring_file" ]; then
        local _items=() _line _esc
        while IFS= read -r _line; do
            [ -z "$_line" ] && continue
            _esc="${_line//\'/\'\'}"
            _items+=("'${_esc}'")
        done < "$_ring_file"
        if [ ${#_items[@]} -gt 0 ]; then
            local _in_clause
            _in_clause=$(IFS=,; echo "${_items[*]}")
            _rel_expr="(SELECT COUNT(*) FROM json_each(COALESCE(json_extract(n.metadata, '\$.touched_files'), '[]')) WHERE value IN ($_in_clause))"
            _rel_order="$_rel_expr DESC, n.created_at ASC, n.id ASC"
        fi
    fi

    # Mode-based row limit for text output (json always returns full set)
    local _mode_limit=""
    case "$mode" in
        bootstrap) _mode_limit="LIMIT 5" ;;
        discover)  _mode_limit="LIMIT 5" ;;
        execute)   _mode_limit="" ;;
        full)      _mode_limit="" ;;
    esac

    if [ "$format" = "json-v2" ]; then
        local results
        results=$(db_query_json_v2 "$subtree_cte SELECT n.id, n.text, n.status, n.metadata FROM nodes n $subtree_join WHERE $ready_where $claim_filter ORDER BY $_rel_order;")
        [ -z "$results" ] && results="[]"
        if [ "$with_impact" = true ]; then
            results=$(_ready_enrich_impact "$results")
        fi
        echo "$results"
    elif [ "$format" = "json" ]; then
        local results
        results=$(db_query_json "$subtree_cte SELECT n.id, n.text, n.status, n.metadata FROM nodes n $subtree_join WHERE $ready_where $claim_filter ORDER BY $_rel_order;")
        [ -z "$results" ] && results="[]"
        if [ "$with_impact" = true ]; then
            results=$(_ready_enrich_impact "$results")
        fi
        echo "$results"
    else
        # Total ready (unlimited) so a truncated text view can announce "showing N of M"
        # instead of silently capping at LIMIT 5 (bootstrap/discover mode) — keeps the
        # printed rows honest against bootstrap/--count, which always report the full set.
        local _ready_total
        _ready_total=$(db_query "$subtree_cte SELECT COUNT(*) FROM nodes n $subtree_join WHERE $ready_where $claim_filter;" 2>/dev/null || echo "0")
        db_query "$subtree_cte SELECT n.id, n.text, json_extract(n.metadata, '$.claimed_by'), $_rel_expr AS rel FROM nodes n $subtree_join WHERE $ready_where $claim_filter ORDER BY $_rel_order $_mode_limit;" \
        | while IFS='|' read -r id text claimed_by rel; do
            local rel_marker=""
            if [ -n "$rel" ] && [ "$rel" -gt 0 ] 2>/dev/null; then
                rel_marker=" ${GREEN}[touched ${rel}]${NC}"
            fi
            if [ -n "$claimed_by" ]; then
                echo -e "${CYAN}$id${NC}: $text${rel_marker} ${YELLOW}(claimed: $claimed_by)${NC}"
            else
                echo -e "${CYAN}$id${NC}: $text${rel_marker}"
            fi
            if [ "$with_impact" = true ]; then
                local _imp_json _imp_summary
                _imp_json=$("$WV_CLI" impact --json "$id" 2>/dev/null || echo '{}')
                _imp_summary=$(printf '%s' "$_imp_json" | jq -r '.summary // empty' 2>/dev/null)
                if [ -n "$_imp_summary" ]; then
                    echo -e "  ${DIM}impact: $_imp_summary${NC}"
                fi
            fi
        done

        # Truncation notice: when a mode limit hid ready rows, say so explicitly.
        if [ -n "$_mode_limit" ]; then
            local _limit_n="${_mode_limit##*LIMIT }"
            if [ "$_ready_total" -gt "$_limit_n" ] 2>/dev/null; then
                echo -e "${DIM}  … showing ${_limit_n} of ${_ready_total} ready (use 'wv ready --json' or execute mode for all)${NC}"
            fi
        fi

        # Reservation notice. Hiding reserved work SILENTLY would trade one
        # invisible hazard for another: the operator running a counted capture
        # needs to know the slot is there, and everyone else needs to know why
        # the count does not match --all.
        if [ "$show_all" = false ]; then
            local _reserved_n
            _reserved_n=$(db_query "$subtree_cte SELECT COUNT(*) FROM nodes n $subtree_join WHERE n.status='todo' AND ($reserved_pred);" 2>/dev/null || echo "0")
            if [ "${_reserved_n:-0}" -gt 0 ] 2>/dev/null; then
                echo -e "${DIM}  ${_reserved_n} reserved node(s) hidden (counted-capture slots; 'wv ready --all' to see them)${NC}"
            fi
        fi

        # Findings to implement: opt-in via --findings flag (or tty default)
        if [ "$show_findings" = true ]; then
            local finding_rows
            finding_rows=$(db_query "
                SELECT n.id,
                       json_extract(n.metadata, '$.finding.confidence') AS confidence,
                       json_extract(n.metadata, '$.finding.violation_type') AS violation_type,
                       n.text,
                       n.status
                FROM nodes n
                WHERE json_extract(n.metadata, '$.type') = 'finding'
                  AND json_extract(n.metadata, '$.finding.fixable') = 1
                  AND n.status != 'done'
                  AND NOT EXISTS (
                      SELECT 1 FROM edges e
                      JOIN nodes t ON e.source = t.id
                      WHERE e.target = n.id AND e.type = 'resolves' AND t.status != 'done'
                  )
                ORDER BY n.created_at ASC;
            ")
            if [ -n "$finding_rows" ]; then
                echo ""
                echo -e "${YELLOW}── Findings to implement ──────────────────────────────────────${NC}"
                while IFS='|' read -r fid confidence violation_type ftext fstatus; do
                    local conf_label="${confidence:-?}"
                    local vtype="${violation_type:-unknown}"
                    local display _tw
                    _tw=$(tput cols 2>/dev/null || echo 120)
                    display=$(echo "$ftext" | sed 's/^Finding: //' | cut -c1-$((_tw - 6)))
                    echo -e "  ${CYAN}$fid${NC} [${fstatus}] conf=${conf_label}  ${vtype}"
                    echo -e "    $display"
                done <<< "$finding_rows"
                echo -e "${YELLOW}───────────────────────────────────────────────────────────────${NC}"
                echo -e "  Use ${CYAN}wv findings list --detail${NC} for the coaching projection."
                # The bounded coaching projection, from the one renderer every
                # surface shares. Only findings carrying promoted occurrences
                # produce a block, so this is silent until canonical promotion
                # has actually run -- the digest above is unchanged either way.
                local _ready_ids
                _ready_ids=$(printf '%s\n' "$finding_rows" | cut -d'|' -f1 | paste -sd, -)
                if [ -n "$_ready_ids" ]; then
                    _wv_findings_python coaching --embed --node-ids="$_ready_ids" --limit=2 2>/dev/null || true
                fi
            fi
        fi

        # Stale active marker: nodes claimed >24h ago and never closed.
        # Suppressed in bootstrap mode (counts only); shown in discover/execute/full.
        if [ "$mode" != "bootstrap" ]; then
            local stale_rows
            stale_rows=$(db_query "
                SELECT n.id,
                       n.text,
                       CAST((julianday('now') - julianday(n.updated_at)) AS INTEGER) AS days_old
                FROM nodes n
                WHERE n.status = 'active'
                  AND datetime(n.updated_at) < datetime('now', '-24 hours')
                ORDER BY n.updated_at ASC;
            " 2>/dev/null)
            if [ -n "$stale_rows" ]; then
                echo ""
                echo -e "${YELLOW}── Stale active (>24h) ────────────────────────────────────────${NC}"
                while IFS='|' read -r sid stext sdays; do
                    [ -z "$sid" ] && continue
                    echo -e "  ${CYAN}$sid${NC} ${YELLOW}[stale ${sdays}d]${NC} $stext"
                done <<< "$stale_rows"
            fi
        fi
    fi
}

# ═══════════════════════════════════════════════════════════════════════════
# cmd_list — List nodes with filtering
# ═══════════════════════════════════════════════════════════════════════════

cmd_list() {
    local status_filter=""
    local priority_filter=""
    local type_filter=""
    local claimed_by_filter=""
    local claimed_by_set=false
    local format="text"
    local all=false
    local limit_val=""
    local mode_arg=""

    while [ $# -gt 0 ]; do
        case "$1" in
            --status=*) status_filter="${1#*=}" ;;
            --priority=*) priority_filter="${1#*=}" ;;
            --type=*) type_filter="${1#*=}" ;;
            --claimed-by=*) claimed_by_filter="${1#*=}"; claimed_by_set=true ;;
            --limit=*) limit_val="${1#*=}" ;;
            --json)    format="json" ;;
            --json-v2) format="json-v2" ;;
            --all) all=true ;;
            --mode=*) mode_arg="${1#*=}" ;;
        esac
        shift
    done
    local mode
    mode=$(wv_resolve_mode "$mode_arg")

    # Validate limit (must be a positive integer)
    if [ -n "$limit_val" ]; then
        if ! [[ "$limit_val" =~ ^[0-9]+$ ]] || [ "$limit_val" -lt 1 ]; then
            echo -e "${RED}Error: --limit must be a positive integer${NC}" >&2
            return 1
        fi
    fi

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

    if [ "$claimed_by_filter" = "current" ]; then
        claimed_by_filter=$(resolve_agent_id)
    elif [ "$claimed_by_set" = true ] && [ -z "$claimed_by_filter" ]; then
        echo -e "${RED}Error: --claimed-by requires an agent ID or 'current'${NC}" >&2
        return 1
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

    if [ -n "$claimed_by_filter" ]; then
        local claimed_by_escaped
        claimed_by_escaped=$(sql_escape "$claimed_by_filter")
        if [ -n "$filters" ]; then
            filters="$filters AND json_extract(metadata, '$.claimed_by') = '$claimed_by_escaped'"
        else
            filters="json_extract(metadata, '$.claimed_by') = '$claimed_by_escaped'"
        fi
    fi

    if [ -n "$filters" ]; then
        where_clause="WHERE $filters"
    fi

    # Default cap: prevents unbounded dumps regardless of mode.
    # Claude Code bash tool allocates a pseudo-tty, so mode=execute without an explicit
    # Cap: active/todo/etc → 50; done → 100; explicit --limit or --all bypass.
    # --status=done previously had no cap; agents calling wv list --status=done dumped
    # all 500+ done nodes. Cap it too; --all still bypasses for intentional full dumps.
    local _LIST_DEFAULT_LIMIT=50
    local _LIST_DONE_LIMIT=100
    local limit_clause=""
    local capped=false
    if [ -n "$limit_val" ]; then
        limit_clause="LIMIT $limit_val"
    elif [ "$all" = true ]; then
        limit_clause=""
    elif [ "$status_filter" = "done" ]; then
        limit_clause="LIMIT $_LIST_DONE_LIMIT"
        capped=true
    else
        limit_clause="LIMIT $_LIST_DEFAULT_LIMIT"
        capped=true
    fi

    # Always-on alternatives footer (stderr): every wv list call reminds the agent
    # of cheaper targeted readers. Previously only fired when hitting the cap —
    # that meant low-node repos never saw the hint even though call frequency was high.
    # The cap bounds output, not knowledge (wv-e174eb): an agent enumerating
    # before wv add has to learn that rows are hidden and how many, or it files
    # a duplicate of a node it never saw. The total counts matching rows, not
    # returned ones, and the remedy keeps the same filters -- --all would also
    # pull in every done node.
    _list_footer() {
        local count="$1" hit_cap="$2" total=""
        if [ "$hit_cap" = true ]; then
            total=$(db_query "SELECT COUNT(*) FROM nodes $where_clause;" 2>/dev/null || echo "")
            if ! [[ "$total" =~ ^[0-9]+$ ]]; then
                echo "(showing $count — more may be hidden; rerun with a larger --limit=N)" >&2
            elif [ "$total" -gt "$count" ]; then
                echo "(showing $count of $total matching — $((total - count)) hidden; rerun with --limit=$total to see them)" >&2
            fi
            if ! [[ "$total" =~ ^[0-9]+$ ]] || [ "$total" -gt "$count" ]; then
                echo "(a capped list is not evidence a node is absent — before wv add, run wv search \"<topic>\")" >&2
            fi
        fi
        echo "(targeted reads: wv ready | wv query <preds> | wv search <topic>)" >&2
    }

    if [ "$format" = "json-v2" ]; then
        local results
        results=$(db_query_json_v2 "SELECT id, text, status, metadata, alias FROM nodes $where_clause ORDER BY priority DESC, created_at DESC, id ASC $limit_clause;")
        [ -z "$results" ] && echo "[]" || echo "$results"
        local json_count cap_n="$_LIST_DEFAULT_LIMIT"
        [ "$status_filter" = "done" ] && cap_n="$_LIST_DONE_LIMIT"
        json_count=$(printf '%s' "${results:-[]}" | jq 'length' 2>/dev/null || echo 0)
        local hit_cap=false
        [ "$capped" = true ] && [ "$json_count" -ge "$cap_n" ] 2>/dev/null && hit_cap=true
        _list_footer "$json_count" "$hit_cap" "$cap_n"
    elif [ "$format" = "json" ]; then
        local results
        results=$(db_query_json "SELECT id, text, status, metadata, alias, created_at, updated_at FROM nodes $where_clause ORDER BY priority DESC, created_at DESC, id ASC $limit_clause;")
        [ -z "$results" ] && echo "[]" || echo "$results"
        local json_count cap_n="$_LIST_DEFAULT_LIMIT"
        [ "$status_filter" = "done" ] && cap_n="$_LIST_DONE_LIMIT"
        json_count=$(printf '%s' "${results:-[]}" | jq 'length' 2>/dev/null || echo 0)
        local hit_cap=false
        [ "$capped" = true ] && [ "$json_count" -ge "$cap_n" ] 2>/dev/null && hit_cap=true
        _list_footer "$json_count" "$hit_cap" "$cap_n"
    else
        # Text mode: exclude metadata to avoid multiline JSON breaking pipe-delimited parsing
        local row_count=0
        while IFS='|' read -r id text status; do
            local color="$NC"
            case "$status" in
                active) color="$GREEN" ;;
                blocked) color="$RED" ;;
                todo) color="$CYAN" ;;
                done) color="$YELLOW" ;;
            esac
            echo -e "${color}[$status]${NC} $id: $text"
            row_count=$((row_count + 1))
        done < <(db_query "SELECT id, text, status FROM nodes $where_clause ORDER BY priority DESC, created_at DESC, id ASC $limit_clause;")
        local cap_n="$_LIST_DEFAULT_LIMIT"
        [ "$status_filter" = "done" ] && cap_n="$_LIST_DONE_LIMIT"
        local hit_cap=false
        [ "$capped" = true ] && [ "$row_count" -ge "$cap_n" ] && hit_cap=true
        _list_footer "$row_count" "$hit_cap" "$cap_n"
    fi
}

# ═══════════════════════════════════════════════════════════════════════════
# cmd_show — Show node details
# ═══════════════════════════════════════════════════════════════════════════

# _render_trails — render metadata.trails[] for `wv show` (S2). Shows the latest
# entry as the headline capsule, flags it "stale — verify" when it predates the
# current session start (epoch in .session_snapshot), and collapses older entries
# into a one-line newest-first path summary. No-op when there are no trails.
_render_trails() {
    local metadata="$1"
    local n
    n=$(echo "$metadata" | jq -r '(.trails // []) | length' 2>/dev/null || echo 0)
    [[ "$n" =~ ^[0-9]+$ ]] || n=0
    [ "$n" -gt 0 ] || return 0

    local latest goal state next_step blocking at
    latest=$(echo "$metadata" | jq -c '.trails[-1]' 2>/dev/null)
    goal=$(echo "$latest" | jq -r '.goal // empty' 2>/dev/null)
    state=$(echo "$latest" | jq -r '.state // empty' 2>/dev/null)
    next_step=$(echo "$latest" | jq -r '.next // empty' 2>/dev/null)
    blocking=$(echo "$latest" | jq -r '.blocking // empty' 2>/dev/null)
    at=$(echo "$latest" | jq -r '.at // empty' 2>/dev/null)

    # Staleness: flag when the latest entry predates the current session start.
    local stale=""
    local snapshot="$WV_HOT_ZONE/.session_snapshot"
    if [ -n "$at" ] && [ -f "$snapshot" ]; then
        local start_ts entry_ts
        IFS=$'\t' read -r start_ts _ < "$snapshot"
        entry_ts=$(date -d "$at" +%s 2>/dev/null || echo "")
        if [ -n "$entry_ts" ] && [[ "$start_ts" =~ ^[0-9]+$ ]] && [ "$entry_ts" -lt "$start_ts" ]; then
            stale="  ${YELLOW}⚠ stale — verify${NC}"
        fi
    fi

    echo -e "${CYAN}Trail:${NC}    ${goal}${stale}"
    [ -n "$state" ]     && echo -e "          state: $state"
    [ -n "$next_step" ] && echo -e "          next:  $next_step"
    [ -n "$blocking" ]  && echo -e "          blocking: $blocking"
    if [ "$n" -gt 1 ]; then
        local older
        older=$(echo "$metadata" | jq -r '.trails[:-1] | reverse | map(.goal // "(no goal)") | join("; ")' 2>/dev/null)
        echo -e "          ${CYAN}path ($((n - 1)) earlier):${NC} $older"
    fi
}

cmd_show() {
    local id="${1:-}"
    local format="text"
    local mode_arg=""

    shift || true
    while [ $# -gt 0 ]; do
        case "$1" in
            --json)    format="json" ;;
            --json-v2) format="json-v2" ;;
            --mode=*)  mode_arg="${1#--mode=}" ;;
        esac
        shift
    done
    local mode
    mode=$(wv_resolve_mode "$mode_arg")
    
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

    if [ "$format" = "json-v2" ]; then
        local _result
        _result=$(db_query_json_v2 "$query")
        if [ "$mode" = "bootstrap" ] || [ "$mode" = "discover" ]; then
            echo "$_result" | jq '[.[] | del(.metadata.current_intent)]'
        else
            echo "$_result"
        fi
    elif [ "$format" = "json" ]; then
        db_query_json "$query" | jq -c '.[0] // empty'
    else
        # Use unit separator — node text can contain '|'
        db_ensure
        sqlite3 -batch -cmd ".timeout 5000" -separator $'\x1f' "$WV_DB" "$query" | while IFS=$'\x1f' read -r id text status metadata created updated node_alias; do
            echo -e "${CYAN}ID:${NC}       $id"
            [ -n "$node_alias" ] && echo -e "${CYAN}Alias:${NC}    $node_alias"
            echo -e "${CYAN}Text:${NC}     $text"
            echo -e "${CYAN}Status:${NC}   $status"

            if [ "$mode" = "bootstrap" ]; then
                # bootstrap: id + text + status only (already printed above)
                true
            elif [ "$mode" = "discover" ]; then
                # discover: + intent (if set) + learning if present
                local _intent _learning
                _intent=$(echo "$metadata" | jq -r '.current_intent // empty' 2>/dev/null)
                [ -n "$_intent" ] && echo -e "${CYAN}Intent:${NC}   $_intent"
                _learning=$(echo "$metadata" | jq -r '.learning // empty' 2>/dev/null)
                if [ -n "$_learning" ]; then
                    echo -e "${CYAN}Learning:${NC} $_learning"
                fi
                _render_trails "$metadata"
            else
                # execute / full: full metadata + timestamps
                local _intent
                _intent=$(echo "$metadata" | jq -r '.current_intent // empty' 2>/dev/null)
                [ -n "$_intent" ] && echo -e "${CYAN}Intent:${NC}   $_intent"
                echo -e "${CYAN}Metadata:${NC} $metadata"
                echo -e "${CYAN}Created:${NC}  $created"
                echo -e "${CYAN}Updated:${NC}  $updated"
                _render_trails "$metadata"
            fi
        done
        
        # Show blocking relationships, split by whether they still block.
        # This listed every blocks edge regardless of status, so a node whose
        # blockers had all closed still rendered a full "Blocked by:" list while
        # `wv context` reported blocked=false with an empty blocker array. Two
        # surfaces disagreeing about the same node is how stale release
        # bookkeeping gets read as current. The satisfied edges are history
        # worth keeping, so they are shown under their own heading rather than
        # hidden.
        local open_blockers satisfied_blockers
        open_blockers=$(db_query "SELECT source FROM edges e WHERE e.target='$id' AND e.type='blocks' AND EXISTS (SELECT 1 FROM nodes n WHERE n.id=e.source AND n.status != 'done');")
        satisfied_blockers=$(db_query "SELECT source FROM edges e WHERE e.target='$id' AND e.type='blocks' AND EXISTS (SELECT 1 FROM nodes n WHERE n.id=e.source AND n.status = 'done');")
        if [ -n "$open_blockers" ]; then
            echo -e "${CYAN}Blocked by:${NC}"
            echo "$open_blockers" | while read -r blocker_id; do
                local blocker_text=$(db_query "SELECT text FROM nodes WHERE id='$blocker_id';")
                echo "  - $blocker_id: $blocker_text"
            done
        fi
        if [ -n "$satisfied_blockers" ]; then
            echo -e "${CYAN}Blockers cleared:${NC}"
            echo "$satisfied_blockers" | while read -r blocker_id; do
                local blocker_text=$(db_query "SELECT text FROM nodes WHERE id='$blocker_id';")
                echo "  - $blocker_id: $blocker_text"
            done
        fi
        return 0
    fi
}

# ═══════════════════════════════════════════════════════════════════════════
# cmd_status — Compact status for context injection
# ═══════════════════════════════════════════════════════════════════════════

cmd_status() {
    local format="text"
    local mode_arg=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --json)    format="json" ;;
            --mode=*)  mode_arg="${1#--mode=}" ;;
        esac
        shift
    done
    local mode
    mode=$(wv_resolve_mode "$mode_arg")

    # Compact status for context injection (~50 tokens)
    local active=$(db_query "SELECT COUNT(*) FROM nodes WHERE status='active';")
    local ready=$(cmd_ready --count)
    local blocked=$(db_query "SELECT COUNT(*) FROM nodes WHERE status='blocked';")
    local pending_close=$(db_query "SELECT COUNT(*) FROM nodes WHERE json_extract(metadata, '$.needs_human_verification') = 1;")
    local stale=$(db_query "SELECT COUNT(*) FROM nodes WHERE status='active' AND datetime(updated_at) < datetime('now', '-24 hours');")
    : "${stale:=0}"

    # Sync-state: compare DB mtime vs last successful `wv sync --gh` timestamp
    local needs_sync="false"
    local last_sync_at=0
    local stamp_file="$WV_HOT_ZONE/.last_gh_sync"
    if [ -f "$stamp_file" ]; then
        last_sync_at=$(cat "$stamp_file" 2>/dev/null || echo "0")
        # Compare MUTATION COUNTERS, not timestamps and not the file mtime.
        # mtime measures access (SQLite journals on reads), and a timestamp
        # clock cannot see a DELETE -- unlinking the newest edge moved
        # MAX(updated_at) backwards, so an unsynced deletion read as synced.
        local seq_file="$WV_HOT_ZONE/.last_gh_sync_seq"
        local synced_seq now_seq
        synced_seq=$(cat "$seq_file" 2>/dev/null || echo "")
        now_seq=$(wv_mutation_seq "$WV_DB" 2>/dev/null || echo "")
        case "$synced_seq" in ''|*[!0-9]*) synced_seq="" ;; esac
        case "$now_seq" in ''|*[!0-9]*) now_seq="" ;; esac
        if [ -n "$synced_seq" ] && [ -n "$now_seq" ]; then
            [ "$now_seq" -gt "$synced_seq" ] && needs_sync="true"
        else
            # No counter recorded yet (a sync predating this, or an unreadable
            # graph): report needs_sync rather than claiming synced on no
            # evidence. The next sync records one and this self-heals.
            needs_sync="true"
        fi
    else
        needs_sync="true"
    fi

    local git_pending_json git_sync_pending git_sync_state git_sync_action git_sync_reason git_sync_hint
    git_pending_json=$(_detect_git_pending 2>/dev/null || echo '{}')
    git_sync_pending=$(echo "$git_pending_json" | jq -r '.pending // false' 2>/dev/null || echo "false")
    git_sync_state=$(echo "$git_pending_json" | jq -r '.state // "clean"' 2>/dev/null || echo "clean")
    git_sync_action=$(echo "$git_pending_json" | jq -r '.action // "none"' 2>/dev/null || echo "none")
    git_sync_reason=$(echo "$git_pending_json" | jq -r '.reason // "clean"' 2>/dev/null || echo "clean")
    git_sync_hint=$(echo "$git_pending_json" | jq -r '.hint // "no action required"' 2>/dev/null || echo "no action required")

    if [ "$format" = "json" ]; then
        local primary_id="" primary_text=""
        if [ "${active:-0}" -gt 0 ]; then
            primary_id=$(get_primary_node 2>/dev/null || true)
            if [ -n "$primary_id" ]; then
                local pstatus
                pstatus=$(db_query "SELECT status FROM nodes WHERE id='$primary_id';" 2>/dev/null)
                if [ "$pstatus" = "active" ]; then
                    primary_text=$(db_query "SELECT text FROM nodes WHERE id='$primary_id';")
                else
                    primary_id=""
                fi
            fi
            if [ -z "$primary_id" ]; then
                primary_id=$(db_query "SELECT id FROM nodes WHERE status='active' LIMIT 1;")
                primary_text=$(db_query "SELECT text FROM nodes WHERE status='active' LIMIT 1;")
            fi
        fi
        jq -n \
            --argjson active "${active:-0}" \
            --argjson ready "${ready:-0}" \
            --argjson blocked "${blocked:-0}" \
            --argjson pending_close "${pending_close:-0}" \
            --argjson stale "${stale:-0}" \
            --argjson needs_sync "$needs_sync" \
            --argjson last_sync_at "$last_sync_at" \
                        --argjson git_sync_pending "$git_sync_pending" \
                        --arg git_sync_state "$git_sync_state" \
                        --arg git_sync_action "$git_sync_action" \
                        --arg git_sync_reason "$git_sync_reason" \
                        --arg git_sync_hint "$git_sync_hint" \
            --arg primary_id "$primary_id" \
            --arg primary_text "$primary_text" \
            '{active:$active, ready:$ready, blocked:$blocked,
              pending_close:$pending_close, stale:$stale,
              needs_sync:$needs_sync,
              last_sync_at:$last_sync_at,
                            git_sync_pending:$git_sync_pending,
                            git_sync_state:$git_sync_state,
                            git_sync_action:$git_sync_action,
                            git_sync_reason:$git_sync_reason,
                            git_sync_hint:$git_sync_hint,
              current: (if $primary_id != "" then {id:$primary_id, text:$primary_text} else null end)}'
        return 0
    fi

    local active_label="$active active"
    if [ "${stale:-0}" -gt 0 ] 2>/dev/null; then
        active_label="$active active ($stale stale)"
    fi

    # bootstrap: counts only — no current node
    if [ "$mode" = "bootstrap" ]; then
        echo "Work: $active_label, $ready ready, $blocked blocked."
        return 0
    fi

    if [ "${pending_close:-0}" -gt 0 ] 2>/dev/null; then
        echo "Work: $active_label, $ready ready, $blocked blocked. $pending_close pending-close."
    else
        echo "Work: $active_label, $ready ready, $blocked blocked."
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

    # full: append sync state
    if [ "$mode" = "full" ]; then
        echo "needs_sync: $needs_sync | last_sync_at: $last_sync_at"
        if [ "$git_sync_pending" = "true" ]; then
            echo "git_sync: $git_sync_state | action: $git_sync_action | reason: $git_sync_reason"
            echo "git_hint: $git_sync_hint"
        fi
    elif [ "$git_sync_pending" = "true" ]; then
        echo "git_sync: $git_sync_state | action: $git_sync_action | reason: $git_sync_reason"
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

cmd_update_help() {
    cat <<EOF
Usage: wv update <id> [options]

Update fields on an existing node.
Done nodes cannot be reopened with update; use 'wv work <id> --reopen'.

Options (a value starting with -- needs the = form; an unknown argument is
an error, and nothing is written):
  --status=<status>, --status <status>      Set status
  --text=<text>, --text <text>              Replace node text
  --alias=<alias>, --alias <alias>          Set alias (empty string clears it)
  --metadata=<json>, --metadata <json>      Merge JSON into metadata
  --metadata-file=<path>, --metadata-file <path>
                                            Read metadata JSON from file ('-' reads stdin)
  --remove-key=<key>, --remove-key <key>    Remove one metadata key
  --echo                                    Print the updated node as JSON

Examples:
  wv update wv-a1b2 --status=active
  wv update wv-a1b2 --metadata '{"priority":1}'
  wv update wv-a1b2 --metadata-file /tmp/node-meta.json
  cat /tmp/node-meta.json | wv update wv-a1b2 --metadata-file -
EOF
}

read_update_metadata_source() {
    local source_path="$1"

    if [ "$source_path" = "-" ]; then
        cat
        return $?
    fi

    if [ ! -f "$source_path" ]; then
        echo -e "${RED}Error: metadata file not found: $source_path${NC}" >&2
        echo "Hint: use --metadata '{\"key\":\"value\"}' for inline JSON or point --metadata-file at an existing file." >&2
        return 1
    fi

    cat -- "$source_path"
}

validate_update_metadata_json() {
    local metadata_payload="$1"
    local metadata_source="$2"
    local jq_error=""

    if ! jq_error=$(printf '%s' "$metadata_payload" | jq -e '.' 2>&1 >/dev/null); then
        echo -e "${RED}Error: invalid JSON in ${metadata_source}${NC}" >&2
        if [ -n "$jq_error" ]; then
            echo "$jq_error" >&2
        fi
        echo "Hint: use --metadata '{\"key\":\"value\"}' for inline JSON or --metadata-file <path> to avoid shell quoting issues." >&2
        return 1
    fi

    validate_metadata_risk_level "$metadata_payload" "$metadata_source" || return 1
    validate_metadata_canonical_numbers "$metadata_payload" "$metadata_source" || return 1

    # Write-time enum guard: reject an explicitly-set off-enum finding.violation_type.
    # Close-time validation alone let invalid findings persist in the graph
    # (wv-43f077 historical:tooling, wv-f51319 measurement-gap — wv-01c378). Only fires
    # when violation_type is being set, so incremental updates are unaffected.
    local _wt_vt
    _wt_vt=$(printf '%s' "$metadata_payload" | jq -r '.finding.violation_type // empty' 2>/dev/null || echo "")
    if [ -n "$_wt_vt" ]; then
        case " $FINDING_VIOLATION_TYPES " in
            *" $_wt_vt "*) ;;
            *)
                echo -e "${RED}Error: invalid finding.violation_type '$_wt_vt' in ${metadata_source}${NC}" >&2
                echo "  Valid: $FINDING_VIOLATION_TYPES" >&2
                return 1
                ;;
        esac
    fi
}

cmd_update() {
    local id="${1:-}"
    shift || true
    
    if [ -z "$id" ]; then
        echo -e "${RED}Error: node ID required${NC}" >&2
        echo "Run 'wv update --help' for usage." >&2
        return 1
    fi

    if [ "$id" = "--help" ] || [ "$id" = "-h" ]; then
        cmd_update_help
        return 0
    fi

    # Validate ID format (SQL injection prevention)
    validate_id "$id" || return 1
    
    local updates=""
    local proposed_metadata="metadata"
    local echo_mode=false
    local metadata_supplied=false
    while [ $# -gt 0 ]; do
        case "$1" in
            --help|-h)
                cmd_update_help
                return 0
                ;;
            --echo) echo_mode=true ;;
            # Space-separated forms (wv-51605f): rewrite to the =-form and
            # re-dispatch, so both forms share one validation path. A value that
            # itself starts with -- is taken only in the =-form, so a missing
            # value cannot swallow the next option.
            --status|--text|--alias|--remove-key)
                if [ $# -lt 2 ] || [[ "$2" == --* ]]; then
                    echo -e "${RED}Error: $1 requires a value${NC}" >&2
                    echo "Use $1 <value> or $1=<value>." >&2
                    return 1
                fi
                local _opt="$1"
                shift
                set -- "$_opt=$1" "${@:2}"
                continue
                ;;
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
                if [ "$metadata_supplied" = true ]; then
                    echo -e "${RED}Error: metadata specified more than once${NC}" >&2
                    echo "Use exactly one of --metadata or --metadata-file." >&2
                    return 1
                fi
                validate_update_metadata_json "$metadata" "--metadata" || return 1
                # Merge atomically via SQL json_patch (RFC 7396) — applies the new
                # JSON as a merge patch to the row's current metadata in a single
                # UPDATE. COALESCE handles NULL. Parity with the --remove-key path
                # above (which uses json_remove). Previous implementation shelled out
                # to jq with a silent "|| echo $metadata" fallback that overwrote the
                # stored metadata when jq failed for any reason.
                local metadata_esc="${metadata//\'/\'\'}"
                updates="${updates}metadata=json_patch(COALESCE(metadata, '{}'), '$metadata_esc'),"
                proposed_metadata="json_patch(COALESCE(metadata, '{}'), '$metadata_esc')"
                metadata_supplied=true
                ;;
            --metadata)
                if [ "$metadata_supplied" = true ]; then
                    echo -e "${RED}Error: metadata specified more than once${NC}" >&2
                    echo "Use exactly one of --metadata or --metadata-file." >&2
                    return 1
                fi
                shift
                if [ $# -eq 0 ]; then
                    echo -e "${RED}Error: --metadata requires a JSON argument${NC}" >&2
                    echo "Hint: use --metadata '{\"key\":\"value\"}' or --metadata-file <path>." >&2
                    return 1
                fi
                local metadata="$1"
                validate_update_metadata_json "$metadata" "--metadata" || return 1
                local metadata_esc="${metadata//\'/\'\'}"
                updates="${updates}metadata=json_patch(COALESCE(metadata, '{}'), '$metadata_esc'),"
                proposed_metadata="json_patch(COALESCE(metadata, '{}'), '$metadata_esc')"
                metadata_supplied=true
                ;;
            --metadata-file=*)
                if [ "$metadata_supplied" = true ]; then
                    echo -e "${RED}Error: metadata specified more than once${NC}" >&2
                    echo "Use exactly one of --metadata or --metadata-file." >&2
                    return 1
                fi
                local metadata_file="${1#*=}"
                local metadata=""
                metadata=$(read_update_metadata_source "$metadata_file") || return 1
                validate_update_metadata_json "$metadata" "--metadata-file" || return 1
                local metadata_esc="${metadata//\'/\'\'}"
                updates="${updates}metadata=json_patch(COALESCE(metadata, '{}'), '$metadata_esc'),"
                proposed_metadata="json_patch(COALESCE(metadata, '{}'), '$metadata_esc')"
                metadata_supplied=true
                ;;
            --metadata-file)
                if [ "$metadata_supplied" = true ]; then
                    echo -e "${RED}Error: metadata specified more than once${NC}" >&2
                    echo "Use exactly one of --metadata or --metadata-file." >&2
                    return 1
                fi
                shift
                if [ $# -eq 0 ]; then
                    echo -e "${RED}Error: --metadata-file requires a path${NC}" >&2
                    echo "Hint: use --metadata-file /path/to/metadata.json or --metadata-file - for stdin." >&2
                    return 1
                fi
                local metadata_file="$1"
                local metadata=""
                metadata=$(read_update_metadata_source "$metadata_file") || return 1
                validate_update_metadata_json "$metadata" "--metadata-file" || return 1
                local metadata_esc="${metadata//\'/\'\'}"
                updates="${updates}metadata=json_patch(COALESCE(metadata, '{}'), '$metadata_esc'),"
                proposed_metadata="json_patch(COALESCE(metadata, '{}'), '$metadata_esc')"
                metadata_supplied=true
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
                validate_metadata_key "$remove_key" || return 1
                # Use json_remove to atomically remove a single metadata key
                db_query "UPDATE nodes SET metadata = json_remove(metadata, '\$.${remove_key}'), updated_at=CURRENT_TIMESTAMP WHERE id='$id';"
                # Metadata carries criteria, learnings, and handoff state. Persist
                # it immediately: a throttled sync can otherwise leave the change
                # only in the hot-zone DB, absent from state.sql and deltas.
                if ! auto_sync --force; then
                    echo -e "${RED}Error: metadata key was removed locally, but portable sync failed; resolve the error and run 'wv sync'${NC}" >&2
                    return 1
                fi
                echo -e "${GREEN}✓${NC} Removed metadata key '${remove_key}' from $id"
                return 0
                ;;
            *)
                # No silent drops (wv-51605f): an argument the parser does not
                # consume fails the command before anything is written.
                echo -e "${RED}Error: unknown argument '$1' for wv update${NC}" >&2
                echo "Run 'wv update --help' for usage." >&2
                return 1
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

    # Pattern E: done-node reopen is an explicit work claim, not a generic update.
    if [[ "$updates" == *"status='active'"* ]]; then
        local _cur_status
        _cur_status=$(db_query "SELECT status FROM nodes WHERE id='$id';" 2>/dev/null | tr -d '[:space:]') || true
        if [[ "$_cur_status" == "done" ]]; then
            wv_policy_verdict reopen_requires_explicit_intent deny yes "" "an update would silently reopen a done node"
            echo -e "${RED}Error: cannot reopen a done node with update; use 'wv work $id --reopen'${NC}" >&2
            return 1
        fi
        wv_policy_verdict reopen_requires_explicit_intent allow no "" "not a done node"
    else
        wv_policy_verdict reopen_requires_explicit_intent allow no "" "the update does not set active"
    fi

    # A close through update is still a close: it is judged by the same receipt
    # as wv done, in the same transaction as the write (wv-957fc8).
    if [[ "$updates" == *"status='done'"* ]]; then
        _done_close "$id" "" "$proposed_metadata" "$updates" || return 1
    else
        _close_rules_not_engaged "the update does not close the node"
        db_query "UPDATE nodes SET $updates WHERE id='$id';"
    fi

    # Every update can change the context payload (status, text, alias, or
    # metadata). Do not leave a same-session runtime consumer with stale state.
    invalidate_context_cache "$id"

    # Auto-unblock cascade when status changed to done
    if [[ "$updates" == *"status='done'"* ]]; then
        _do_unblock_cascade "$id"
    fi

    # Stamp promoted_at on finding nodes that lack it (cannot use a SQL trigger —
    # virtual column + warp session trigger interaction crashes SQLite 3.46)
    if [ "$metadata_supplied" = true ]; then
        db_query "UPDATE nodes SET metadata = json_patch(COALESCE(metadata,'{}'), json_object('promoted_at', strftime('%Y-%m-%dT%H:%M:%SZ', 'now')))
                  WHERE id = '$id'
                    AND json_extract(metadata, '$.type') = 'finding'
                    AND json_extract(metadata, '$.promoted_at') IS NULL;" 2>/dev/null || true
    fi

    # Metadata carries criteria, learnings, and handoff state. Persist explicit
    # metadata updates immediately so a commit made inside the normal sync
    # throttle window cannot omit them from the portable graph artifacts.
    if [ "$metadata_supplied" = true ]; then
        if ! auto_sync --force; then
            echo -e "${RED}Error: metadata was updated locally, but portable sync failed; resolve the error and run 'wv sync'${NC}" >&2
            return 1
        fi
    else
        auto_sync_or_warn
    fi

    # Report success only after durability-critical metadata persistence passes.
    # --echo returns the updated node as JSON (avoids a follow-up show call).
    if [ "$echo_mode" = true ]; then
        db_query_json_v2 "SELECT id, text, status, metadata FROM nodes WHERE id='$id';"
    else
        echo -e "${GREEN}✓${NC} Updated: $id"
    fi
}

# ═══════════════════════════════════════════════════════════════════════════
# cmd_touch — Fire-and-forget metadata write (silent on success)
# Like cmd_update but produces NO stdout. Designed for per-turn intent-setting.
# ═══════════════════════════════════════════════════════════════════════════

cmd_touch() {
    local id="${1:-}"
    shift || true
    
    if [ -z "$id" ]; then
        echo "Error: node ID required" >&2
        return 1
    fi

    validate_id "$id" || return 1
    
    local metadata=""
    local intent=""
    local -a files_list=()
    while [ $# -gt 0 ]; do
        case "$1" in
            --metadata=*) metadata="${1#--metadata=}" ;;
            --intent=*)   intent="${1#--intent=}" ;;
            --files=*)
                # Comma-separated list of repo-relative file paths to attribute
                IFS=',' read -ra _tf_arr <<< "${1#--files=}"
                for _tf in "${_tf_arr[@]}"; do
                    [ -n "$_tf" ] && files_list+=("$_tf")
                done
                ;;
            *) _wv_reject_arg touch "$1"; return 1 ;;
        esac
        shift
    done

    # --intent is sugar for --metadata='{"current_intent":"..."}'
    if [ -n "$intent" ]; then
        local intent_esc="${intent//\"/\\\"}"
        if [ -n "$metadata" ]; then
            # Merge intent into provided metadata
            metadata=$(echo "$metadata" | jq --arg i "$intent_esc" '. + {current_intent: $i}' 2>/dev/null || echo "{\"current_intent\":\"$intent_esc\"}")
        else
            metadata="{\"current_intent\":\"$intent_esc\"}"
        fi
    fi

    if [ -z "$metadata" ] && [ "${#files_list[@]}" -eq 0 ]; then
        echo "Error: --metadata=JSON, --intent=TEXT, or --files=PATH required" >&2
        return 1
    fi

    if [ -n "$metadata" ]; then
        # Validate JSON
        if ! echo "$metadata" | jq '.' >/dev/null 2>&1; then
            echo "Error: invalid JSON in --metadata" >&2
            return 1
        fi
        validate_metadata_risk_level "$metadata" "--metadata" || return 1
        validate_metadata_canonical_numbers "$metadata" "--metadata" || return 1

        local metadata_esc="${metadata//\'/\'\'}"
        db_query "UPDATE nodes SET metadata=json_patch(COALESCE(metadata, '{}'), '$metadata_esc'), updated_at=CURRENT_TIMESTAMP WHERE id='$id';"
        invalidate_context_cache "$id"
    fi

    # --files: insert repo-relative paths into node_files for impact attribution
    if [ "${#files_list[@]}" -gt 0 ]; then
        local id_esc="${id//\'/\'\'}"
        for _fpath in "${files_list[@]}"; do
            local _fesc="${_fpath//\'/\'\'}"
            db_query "INSERT OR IGNORE INTO node_files(node_id, path) VALUES ('$id_esc', '$_fesc');" 2>/dev/null || true
        done
    fi
    # No stdout — fire-and-forget. Zero token cost.
}


# ═══════════════════════════════════════════════════════════════════════════
# cmd_allowed_tools — Read metadata.allowed_tools for a node
# ═══════════════════════════════════════════════════════════════════════════

cmd_allowed_tools() {
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
        echo "Error: node ID required" >&2
        echo "Usage: wv allowed-tools <node_id> [--json]" >&2
        return 1
    fi

    validate_id "$id" || return 1

    local exists
    exists=$(db_query "SELECT COUNT(*) FROM nodes WHERE id='$(sql_escape "$id")';" 2>/dev/null || echo "0")
    if [ "$exists" = "0" ]; then
        echo -e "${RED}Error: node $id not found${NC}" >&2
        return 1
    fi

    local tools_raw
    tools_raw=$(db_query "SELECT json_extract(metadata, '\$.allowed_tools') FROM nodes WHERE id='$(sql_escape "$id")';" 2>/dev/null || echo "")

    if [ "$format" = "json" ]; then
        if [ -z "$tools_raw" ] || [ "$tools_raw" = "null" ]; then
            echo "null"
        else
            echo "$tools_raw"
        fi
    else
        if [ -z "$tools_raw" ] || [ "$tools_raw" = "null" ]; then
            echo "(no allowed_tools set — all gated tools permitted)"
        else
            echo "$tools_raw" | jq -r '.[]?' 2>/dev/null || echo "$tools_raw"
        fi
    fi
}

# _parse_allowed_tools — Convert comma-separated tool list to JSON array string.
# Returns "" if input is empty, so callers can skip the update.
_parse_allowed_tools() {
    local raw="${1:-}"
    [ -z "$raw" ] && return 0
    echo "$raw" | tr ',' '\n' | jq -Rc . | jq -sc .
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
            --*) _wv_reject_arg quick "$1"; return 1 ;;
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
    validate_metadata_risk_level "$metadata" "--metadata" || return 1
    validate_metadata_canonical_numbers "$metadata" "--metadata" || return 1

    if ! _add_dedup_check "$text" "Use 'wv add \"...\" --force' for intentional repeat work"; then
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
            # Commit only what the caller staged. `git add -u` used to stage
            # every tracked modification, so running `wv quick` mid-edit swept
            # unrelated in-progress work into a commit whose message described
            # this node's defect (wv-1aca2c). Unstaged work is left alone.
            local has_staged has_unstaged
            has_staged=$(git -C "$git_root" diff --cached --quiet 2>/dev/null; echo $?)
            has_unstaged=$(git -C "$git_root" diff --quiet 2>/dev/null; echo $?)

            if [ "$has_staged" != "0" ]; then
                if git -C "$git_root" commit -m "$text"; then
                    committed=true
                    echo -e "${GREEN}✓${NC} Committed staged changes" >&2
                    if [ "$has_unstaged" != "0" ]; then
                        echo -e "${YELLOW}⚠${NC} Unstaged changes were left uncommitted" >&2
                    fi
                else
                    # A failed commit must not close the node: the work is not
                    # recorded, and a closed node hides that from the next session.
                    echo -e "${RED}Error: commit failed — $id is left ACTIVE${NC}" >&2
                    echo -e "${YELLOW}  Resolve the commit, then close it: wv done $id${NC}" >&2
                    cmd_sync 2>/dev/null || true
                    echo "$id"
                    return 1
                fi
            elif [ "$has_unstaged" != "0" ]; then
                echo -e "${YELLOW}⊘${NC} Nothing staged — unstaged changes left untouched; stage them first to commit" >&2
            else
                echo -e "${YELLOW}⊘${NC} No changes to commit" >&2
            fi
        fi
    fi

    # Step 3: Close the node + unblock cascade. The close is judged by the same
    # receipt as wv done (wv-957fc8); a denied close leaves the node active,
    # like a failed commit, rather than closing past the gate.
    if ! _done_close "$id" "" "metadata" "status = 'done'"; then
        echo -e "${RED}Error: close was refused — $id is left ACTIVE${NC}" >&2
        cmd_sync 2>/dev/null || true
        echo "$id"
        return 1
    fi
    _do_unblock_cascade "$id"
    echo -e "${GREEN}✓${NC} $id (quick-closed)" >&2
    echo "$id"

    # Step 4: Sync .weave/ state
    cmd_sync 2>/dev/null || true
}

# ═══════════════════════════════════════════════════════════════════════════
# cmd_ship — Done + sync in one command (local completion)
# ═══════════════════════════════════════════════════════════════════════════

_ship_needs_gh() {
    local id="$1"
    local gh_flag="$2"

    if [ "$gh_flag" = true ]; then
        return 0
    fi

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
    [ -n "$gh_found" ]
}

_ship_sync_without_commit() {
    local previous_skip="${_WV_SKIP_SYNC_COMMIT:-}"
    local previous_skip_set="${_WV_SKIP_SYNC_COMMIT+x}"
    local rc=0
    export _WV_SKIP_SYNC_COMMIT=1
    cmd_sync "$@" || rc=$?
    if [ -n "$previous_skip_set" ]; then
        export _WV_SKIP_SYNC_COMMIT="$previous_skip"
    else
        unset _WV_SKIP_SYNC_COMMIT
    fi
    return "$rc"
}

_ship_mark_pending() {
    local id="$1"
    local mode="$2"
    local changed
    changed=$(db_query "UPDATE nodes
        SET metadata = json_set(COALESCE(metadata,'{}'),
            '$.ship_pending', json('true'),
            '$.ship_pending_mode', '$(sql_escape "$mode")')
        WHERE id = '$(sql_escape "$id")' AND status != 'done';
        SELECT changes();") || return $?
    [ "$changed" = "1" ]
}

_ship_clear_pending_durable() {
    local id="$1"
    local previous_mode mode_present marker_present rc=0
    previous_mode=$(db_query "SELECT COALESCE(json_extract(metadata, '$.ship_pending_mode'), '')
        FROM nodes WHERE id = '$(sql_escape "$id")';" 2>/dev/null || echo "legacy")
    mode_present=$(db_query "SELECT CASE WHEN json_type(metadata, '$.ship_pending_mode') IS NULL THEN 0 ELSE 1 END
        FROM nodes WHERE id = '$(sql_escape "$id")';" 2>/dev/null || echo "0")
    marker_present=$(db_query "SELECT CASE WHEN json_type(metadata, '$.ship_pending') IS NULL THEN 0 ELSE 1 END
        FROM nodes WHERE id = '$(sql_escape "$id")';" 2>/dev/null || echo "0")
    db_query "UPDATE nodes
        SET metadata = json_remove(COALESCE(metadata,'{}'), '$.ship_pending', '$.ship_pending_mode')
        WHERE id = '$(sql_escape "$id")';" >/dev/null || return 1
    _ship_sync_without_commit || rc=$?
    if [ "$rc" -ne 0 ]; then
        if [ "$marker_present" = "1" ] && [ "$mode_present" = "1" ]; then
            db_query "UPDATE nodes
                SET metadata = json_set(COALESCE(metadata,'{}'),
                    '$.ship_pending', json('true'),
                    '$.ship_pending_mode', '$(sql_escape "$previous_mode")')
                WHERE id = '$(sql_escape "$id")';" >/dev/null 2>&1 || true
        elif [ "$marker_present" = "1" ]; then
            db_query "UPDATE nodes
                SET metadata = json_set(COALESCE(metadata,'{}'), '$.ship_pending', json('true'))
                WHERE id = '$(sql_escape "$id")';" >/dev/null 2>&1 || true
        elif [ "$mode_present" = "1" ]; then
            db_query "UPDATE nodes
                SET metadata = json_set(COALESCE(metadata,'{}'), '$.ship_pending_mode', '$(sql_escape "$previous_mode")')
                WHERE id = '$(sql_escape "$id")';" >/dev/null 2>&1 || true
        fi
        return "$rc"
    fi
}

_ship_run() {
    local id="$1"
    local learning="$2"
    local learning_file="$3"
    local gh_flag="$4"
    local skip_verification="$5"
    local no_overlap_check="$6"
    local verification_method="$7"
    local verification_evidence="$8"
    local verification_evidence_file="$9"
    local no_gh="${10:-false}"
    local decision="${11:-}"
    local pattern="${12:-}"
    local pitfall="${13:-}"

    # Validate ID format
    validate_id "$id" || return 1

    # Reject incomplete input before creating any durable protocol state.
    if [ -z "$learning" ] && [ -z "$learning_file" ] && [ -z "$decision" ] &&
       [ -z "$pattern" ] && [ -z "$pitfall" ] && [ "$skip_verification" != true ]; then
        # The bypass path is recorded by cmd_done, which ship delegates to.
        wv_policy_verdict close_requires_learning deny no "" "a close records what the next session would get wrong"
        echo -e "${RED}Error: --learning=\"...\", --learning-file=PATH, or --skip-verification required${NC}" >&2
        echo "Usage: wv ship <id> --learning=\"decision: ... | pattern: ... | pitfall: ...\"" >&2
        return 1
    fi
    local ship_status
    ship_status=$(db_query "SELECT status FROM nodes WHERE id='$(sql_escape "$id")';" 2>/dev/null)
    if [ -z "$ship_status" ] || [ "$ship_status" = "done" ]; then
        if [ -z "$ship_status" ]; then
            wv_policy_refusal input_validation "ship names a node that does not exist"
        else
            wv_policy_refusal expected_conflict "node already closed"
        fi
        echo -e "${RED}Error: ship requires an existing non-done node${NC}" >&2
        return 1
    fi

    # Auto-detect GH sync need before journaling
    local needs_gh=false
    if [ "$no_gh" != true ] && _ship_needs_gh "$id" "$gh_flag"; then
        needs_gh=true
    fi

    # Begin journaled operation
    if ! journal_begin "ship" "{\"id\":\"$id\",\"gh\":$needs_gh}" "persist_intent"; then
        unset _WV_IN_JOURNAL _WV_CURRENT_OP_ID _WV_CURRENT_OP_TYPE
        return 1
    fi

    # Persist intent before close can change node state. The explicit journal
    # phase avoids an unrecoverable begin-with-no-pending-step crash window.
    journal_step 1 "persist_intent" "{\"id\":\"$id\"}" || return $?
    if ! _ship_mark_pending "$id" "pre_close" || ! _ship_sync_without_commit; then
        return 1
    fi
    journal_complete 1 || return $?

    # Step 2: Close the node
    journal_step 2 "done" "{\"id\":\"$id\"}" || return $?
    local done_rc=0
    local done_args=("$id")
    if [ -n "$learning" ]; then
        done_args+=("--learning=$learning")
    fi
    if [ -n "$learning_file" ]; then
        done_args+=("--learning-file=$learning_file")
    fi
    [ -n "$decision" ] && done_args+=("--decision=$decision")
    [ -n "$pattern" ] && done_args+=("--pattern=$pattern")
    [ -n "$pitfall" ] && done_args+=("--pitfall=$pitfall")
    if [ -n "$verification_method" ]; then
        done_args+=("--verification-method=$verification_method")
    fi
    if [ -n "$verification_evidence" ]; then
        done_args+=("--verification-evidence=$verification_evidence")
    fi
    if [ -n "$verification_evidence_file" ]; then
        done_args+=("--verification-evidence-file=$verification_evidence_file")
    fi
    if [ "$no_overlap_check" = true ]; then
        done_args+=("--no-overlap-check")
    fi
    if [ "$no_gh" = true ]; then
        done_args+=("--no-gh")
    fi

    local previous_ship_close="${_WV_SHIP_DURABLE_CLOSE:-}"
    local previous_ship_close_set="${_WV_SHIP_DURABLE_CLOSE+x}"
    export _WV_SHIP_DURABLE_CLOSE=1
    if [ -n "$learning" ] || [ -n "$learning_file" ] || [ -n "$decision" ] ||
       [ -n "$pattern" ] || [ -n "$pitfall" ]; then
        cmd_done "${done_args[@]}" || done_rc=$?
    elif [ "$skip_verification" = true ]; then
        done_args+=("--skip-verification")
        cmd_done "${done_args[@]}" || done_rc=$?
    fi
    if [ -n "$previous_ship_close_set" ]; then
        export _WV_SHIP_DURABLE_CLOSE="$previous_ship_close"
    else
        unset _WV_SHIP_DURABLE_CLOSE
    fi
    if [ "$done_rc" -eq 2 ]; then
        _ship_clear_pending_durable || return $?
        journal_end
        journal_clean
        return 2
    elif [ "$done_rc" -ne 0 ]; then
        return "$done_rc"
    fi
    journal_complete 2 || return $?

    # Step 3: Sync to disk (with GH if needed)
    journal_step 3 "sync" "{\"gh\":$needs_gh}" || return $?
    local sync_rc=0
    if [ "$needs_gh" = true ]; then
        echo -e "${CYAN}ℹ${NC} GitHub-linked node detected — syncing with --gh --mode=fast"
        _ship_sync_without_commit --gh --mode=fast --node="$id" || sync_rc=$?
    else
        _ship_sync_without_commit || sync_rc=$?
    fi
    [ "$sync_rc" -eq 0 ] || return "$sync_rc"
    journal_complete 3 || return $?

    # Marker clearance is itself durable before the journal can complete.
    # Remote sync may still be pending — surfaced via status/doctor/recover.
    journal_step 4 "clear_pending" "{\"id\":\"$id\"}" || return $?
    _ship_clear_pending_durable "$id" || return $?
    journal_complete 4 || return $?
    journal_end || return $?
    journal_clean || return $?
}

cmd_ship() {
    # Check for incomplete operations before starting a new ship
    if journal_has_incomplete 2>/dev/null; then
        echo -e "${YELLOW}⚠ Recovering incomplete operation before shipping...${NC}" >&2
        cmd_recover --auto || return $?
    fi

    local id="${1:-}"
    local learning=""
    local learning_file=""
    local decision=""
    local pattern=""
    local pitfall=""
    local gh_flag=false
    local skip_verification=false
    local no_overlap_check=false
    local verification_method=""
    local verification_evidence=""
    local verification_evidence_file=""

    shift || true
    while [ $# -gt 0 ]; do
        case "$1" in
            --learning=*) learning="${1#*=}" ;;
            --learning-file=*) learning_file="${1#*=}" ;;
            --decision=*) decision="${1#*=}" ;;
            --pattern=*) pattern="${1#*=}" ;;
            --pitfall=*) pitfall="${1#*=}" ;;
            --gh) gh_flag=true ;;
            --skip-verification) skip_verification=true ;;
            --no-overlap-check) no_overlap_check=true ;;
            --verification-method=*) verification_method="${1#*=}" ;;
            --verification-evidence=*) verification_evidence="${1#*=}" ;;
            --verification-evidence-file=*) verification_evidence_file="${1#*=}" ;;
            # GitHub sync is opt-in (--gh), so --no-gh restates the default;
            # callers pass it, and refusing it would break them (wv-86a96a).
            --no-gh) gh_flag=false ;;
            *) _wv_reject_arg ship "$1"; return 1 ;;
        esac
        shift
    done

    if [ -z "$id" ]; then
        echo -e "${RED}Error: node ID required${NC}" >&2
        echo "Usage: wv ship <id> [--learning=\"...\"] [--gh] [--no-overlap-check]" >&2
        return 1
    fi

    _ship_run "$id" "$learning" "$learning_file" "$gh_flag" "$skip_verification" "$no_overlap_check" \
        "$verification_method" "$verification_evidence" "$verification_evidence_file" false \
        "$decision" "$pattern" "$pitfall"
}

cmd_ship_agent() {
    local id="${1:-}"
    local learning=""
    local learning_file=""
    local gh_flag=false
    local skip_verification=false
    local no_overlap_check=false
    local verification_method=""
    local verification_evidence=""
    local verification_evidence_file=""
    local no_gh=false
    local format="json"

    shift || true
    while [ $# -gt 0 ]; do
        case "$1" in
            --learning=*) learning="${1#*=}" ;;
            --learning-file=*) learning_file="${1#*=}" ;;
            --gh) gh_flag=true ;;
            --no-gh) no_gh=true ;;
            --skip-verification) skip_verification=true ;;
            --no-overlap-check) no_overlap_check=true ;;
            --verification-method=*|--verify-method=*) verification_method="${1#*=}" ;;
            --verification-evidence=*|--verify-evidence=*) verification_evidence="${1#*=}" ;;
            --verification-evidence-file=*|--verify-evidence-file=*) verification_evidence_file="${1#*=}" ;;
            --json) format="json" ;;
            --help|-h)
                echo "Usage: wv ship-agent <id> [--learning=\"...\"|--learning-file=PATH] [--verification-method=\"...\"|--verify-method=\"...\"] [--verification-evidence=\"...\"|--verify-evidence=\"...\"|--verification-evidence-file=PATH] [--gh] [--no-gh] [--skip-verification] [--no-overlap-check] [--json]" >&2
                return 0
                ;;
        esac
        shift
    done

    if [ -z "$id" ]; then
        echo -e "${RED}Error: node ID required${NC}" >&2
        echo "Usage: wv ship-agent <id> [--learning=\"...\"|--learning-file=PATH] [--json]" >&2
        return 1
    fi

    local doctor_json doctor_rc=0
    doctor_json=$(cmd_doctor --agent --json 2>/dev/null) || doctor_rc=$?

    local prev_noninteractive="${WV_NONINTERACTIVE:-}"
    local prev_agent_mode="${WV_AGENT_MODE:-}"
    export WV_NONINTERACTIVE=1
    export WV_AGENT_MODE=1

    # Backfill node_files from git history (for surfaces without PostToolUse hooks,
    # e.g. Codex CLI and VS Code Copilot). No-op when node_files already populated.
    local _sa_created_at
    _sa_created_at=$(db_query "SELECT created_at FROM nodes WHERE id='$(sql_escape "$id")';" 2>/dev/null || echo "")
    if [ -n "$_sa_created_at" ] && command -v git >/dev/null 2>&1; then
        local _sa_git_root
        _sa_git_root=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
        if [ -n "$_sa_git_root" ]; then
            local _sa_changed
            _sa_changed=$(git log --name-only --format="" --diff-filter=AMR \
                --since="$_sa_created_at" HEAD 2>/dev/null \
                | grep -v '^$' | sort -u || true)
            if [ -n "$_sa_changed" ]; then
                local _sa_id_esc="${id//\'/\'\'}"
                while IFS= read -r _sa_path; do
                    local _sa_pe="${_sa_path//\'/\'\'}"
                    db_query "INSERT OR IGNORE INTO node_files(node_id, path) VALUES ('$_sa_id_esc', '$_sa_pe');" 2>/dev/null || true
                done <<< "$_sa_changed"
            fi
        fi
    fi

    local ship_output ship_rc=0
    ship_output=$(_ship_run "$id" "$learning" "$learning_file" "$gh_flag" "$skip_verification" \
        "$no_overlap_check" "$verification_method" "$verification_evidence" \
        "$verification_evidence_file" "$no_gh" "" "" "" 2>&1) || ship_rc=$?

    if [ -n "$prev_noninteractive" ]; then
        export WV_NONINTERACTIVE="$prev_noninteractive"
    else
        unset WV_NONINTERACTIVE
    fi
    if [ -n "$prev_agent_mode" ]; then
        export WV_AGENT_MODE="$prev_agent_mode"
    else
        unset WV_AGENT_MODE
    fi

    local node_json="null"
    node_json=$(db_query_json_v2 "SELECT id, text, status, metadata FROM nodes WHERE id='$id';" 2>/dev/null | jq '.[0] // null' 2>/dev/null || echo 'null')

    if [ "$format" = "json" ]; then
        local result_status="shipped"
        if [ "$doctor_rc" -ne 0 ]; then
            result_status="doctor_failed"
        elif [ "$ship_rc" -eq 2 ]; then
            result_status="pending_close"
        elif [ "$ship_rc" -ne 0 ]; then
            result_status="ship_failed"
        fi

        jq -n \
            --arg status "$result_status" \
            --arg node_id "$id" \
            --arg ship_output "$ship_output" \
            --argjson doctor "$doctor_json" \
            --argjson ship_rc "$ship_rc" \
            --argjson doctor_rc "$doctor_rc" \
            --argjson node "$node_json" \
            '{
                status: $status,
                node_id: $node_id,
                noninteractive: true,
                agent_mode: true,
                doctor: $doctor,
                ship_exit_code: $ship_rc,
                doctor_exit_code: $doctor_rc,
                node: $node,
                ship_output: $ship_output
            }'
        if [ "$doctor_rc" -ne 0 ]; then
            return "$doctor_rc"
        fi
        return "$ship_rc"
    fi

    if [ "$doctor_rc" -ne 0 ]; then
        echo "$doctor_json"
        return "$doctor_rc"
    fi
    printf '%s\n' "$ship_output"
    return "$ship_rc"
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
        wv_policy_refusal input_validation "delete names a node that does not exist"
        echo -e "${RED}Error: node $id not found${NC}" >&2
        return 1
    fi

    # Check for children (nodes that implement this one)
    local children
    children=$(db_query "SELECT source FROM edges WHERE target='$id' AND type='implements';")
    if [ -n "$children" ] && [ "$force" = "true" ]; then
        wv_policy_verdict delete_preserves_children allow yes --force "deleted a node with children, orphaning them"
    elif [ -n "$children" ]; then
        local child_count
        child_count=$(echo "$children" | wc -l)
        wv_policy_verdict delete_preserves_children deny yes "" "deleting a node with children orphans them"
        echo -e "${RED}Error: node $id has $child_count child node(s):${NC}" >&2
        echo "$children" | while read -r child_id; do
            local child_text
            child_text=$(db_query "SELECT COALESCE(alias, substr(text,1,50)) FROM nodes WHERE id='$child_id';")
            echo -e "  ${CYAN}$child_id${NC}: $child_text" >&2
        done
        echo -e "${YELLOW}Use --force to delete anyway (children will be orphaned)${NC}" >&2
        return 1
    else
        wv_policy_verdict delete_preserves_children allow no "" "the node has no children"
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
        if [ -n "$gh_num" ] && [ "$gh_num" != "null" ]; then
            local _dry_owner_count
            # CAST: gh_issue is stored as a JSON number; a bare INTEGER never
            # equals a TEXT literal in SQLite, so compare as TEXT on both sides.
            _dry_owner_count=$(db_query "SELECT COUNT(*) FROM nodes WHERE id<>'$id' AND CAST(json_extract(metadata,'$.gh_issue') AS TEXT)='$gh_num';" 2>/dev/null || echo "0")
            if [ "${_dry_owner_count:-0}" -gt 0 ]; then
                echo "  GitHub issue: #$gh_num (would NOT be closed — $((${_dry_owner_count:-0})) other node(s) still map this issue)"
            else
                echo "  GitHub issue: #$gh_num (would be closed)"
            fi
        fi
        return 0
    fi

    # Begin journaled operation
    journal_begin "delete" "{\"id\":\"$id\",\"gh_issue\":\"${gh_num:-}\"}"

    # Step 1: SQLite delete (archive + edges + node)
    journal_step 1 "sqlite_delete" "{\"id\":\"$id\"}"

    # Archive node to JSONL before deletion, but not from a DB foreign to
    # WEAVE_DIR (a WV_DB override with WEAVE_DIR from the working directory):
    # that DB is not this repository's graph, and its rows do not belong in the
    # repository's recovery archive (wv-5d5ef2, wv-7ab3cd).
    if ! _wv_db_foreign_to_weave_dir; then
        local archive_dir="$WEAVE_DIR/archive"
        local archive_file="$archive_dir/$(date +%Y-%m-%d).jsonl"
        mkdir -p "$archive_dir"
        db_query_json "SELECT * FROM nodes WHERE id='$id'" | jq -c '.[]' >> "$archive_file" 2>/dev/null || true
    fi

    # Collect connected nodes for cache invalidation
    local affected_nodes="$id"
    local connected
    connected=$(db_query "SELECT DISTINCT source FROM edges WHERE target='$id' UNION SELECT DISTINCT target FROM edges WHERE source='$id';" | tr '\n' ' ')
    affected_nodes="$affected_nodes $connected"

    # Capture lineage BEFORE the DELETEs so the deletion tombstones carry the
    # highest lineage each row held (wv-0d5e07).
    local _del_agent _del_tombs
    _del_agent="$(resolve_agent_id 2>/dev/null || echo unknown)"
    _del_tombs=$(db_capture_tombstones "$id")

    # Delete edges first (no ON DELETE CASCADE)
    db_query "DELETE FROM edges WHERE source='$id' OR target='$id';"
    db_query "DELETE FROM node_files WHERE node_id='$id';"
    # Delete node
    db_query "DELETE FROM nodes WHERE id='$id';"

    echo -e "${GREEN}✓${NC} Deleted: $id ($node_text)"
    [ "$edge_count" -gt 0 ] && echo "  Removed $edge_count edge(s)"

    journal_complete 1

    # Record cross-machine deletion tombstones + re-dump state.sql immediately
    # (D-3/D-4 fix, wv-0d5e07). auto_sync is throttled and may not fire, leaving
    # state.sql stale with the deleted node; wv load would then resurrect it. The
    # tombstone rows (node + every incident edge) travel in state.sql and let each
    # clone's _reconcile_tombstones drop the row again if the delta back-catalog
    # replays its creation. tombstones has no _warp trigger so this stays local
    # (delete is non-propagating), like the .prune_epoch it replaces.
    db_write_tombstones "$_del_agent" <<< "$_del_tombs"
    _redump_state_after_removal 1 || true

    # Step 2: Close matching GitHub issue if linked and no other node still owns it
    if [ "$close_gh" = "true" ] && [ -n "$gh_num" ] && [ "$gh_num" != "null" ]; then
        journal_step 2 "gh_close" "{\"issue\":$gh_num}"
        local _gh_owner_count
        # CAST: see dry-run survivor query above — integer-stored gh_issue
        # never matches a TEXT literal without the cast.
        _gh_owner_count=$(db_query "SELECT COUNT(*) FROM nodes WHERE id<>'$id' AND CAST(json_extract(metadata,'$.gh_issue') AS TEXT)='$gh_num';" 2>/dev/null || echo "0")
        if [ "${_gh_owner_count:-0}" -gt 0 ]; then
            echo -e "${YELLOW}ℹ${NC} Skipped closing GitHub issue #$gh_num — ${_gh_owner_count} other node(s) still map this issue" >&2
        elif command -v gh >/dev/null 2>&1; then
            local repo
            repo=$(gh repo view --json nameWithOwner -q '.nameWithOwner' 2>/dev/null || echo "")
            if [ -n "$repo" ]; then
                local _del_gh_state
                _del_gh_state=$(gh issue view "$gh_num" --repo "$repo" --json state -q '.state' 2>/dev/null || echo "")
                if [ "$_del_gh_state" = "OPEN" ]; then
                    gh issue close "$gh_num" --repo "$repo" --comment "Deleted from Weave graph (node \`$id\`)" 2>/dev/null && \
                        echo -e "${GREEN}✓${NC} Closed GitHub issue #$gh_num" >&2 || \
                        echo -e "${YELLOW}Warning: Could not close GitHub issue #$gh_num${NC}" >&2
                fi
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

    auto_sync_or_warn
}
