#!/bin/bash
# Sync Weave nodes ↔ GitHub Issues (bidirectional)
#
# Weave → GitHub:
#   1. Creates GitHub issues for nodes that don't have GH counterparts
#   2. Closes GitHub issues when corresponding nodes are done
#   3. Reopens GitHub issues when corresponding nodes are still open
#
# GitHub → Weave:
#   4. Creates Weave nodes for GitHub issues not yet tracked
#   5. Marks Weave nodes done when corresponding GH issues are closed
#
# Exclusions:
#   - Nodes with metadata.type = "test" are skipped (test artifacts)
#   - Nodes with metadata.no_sync = true are skipped (local-only)
#
# Matching: metadata.gh_issue first, then node ID in issue body

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WV="$SCRIPT_DIR/wv"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo "🔄 Syncing Weave ↔ GitHub..."

# Project config
REPO=$(gh repo view --json nameWithOwner -q '.nameWithOwner' 2>/dev/null || echo "")
if [ -z "$REPO" ]; then
    echo -e "${RED}Error: could not detect GitHub repo${NC}" >&2
    exit 1
fi
echo "   Repo: $REPO"

# Repo URL for commit links
REPO_URL=$(gh repo view --json url -q '.url' 2>/dev/null || echo "")

# Build a markdown commit links section for a given node ID
# Usage: build_commit_links <node_id>
# Sets COMMIT_LINKS variable
build_commit_links() {
    local node_id="$1"
    COMMIT_LINKS=""

    local shas
    shas=$(git log --format="%H" --grep="Weave-ID: $node_id" --since="90 days ago" 2>/dev/null | head -10)
    if [ -z "$shas" ]; then
        shas=$(git log --format="%H" --grep="$node_id" --since="90 days ago" 2>/dev/null | head -10)
    fi

    if [ -n "$shas" ]; then
        COMMIT_LINKS="

**Commits:**"
        for sha in $shas; do
            local short=$(echo "$sha" | cut -c1-7)
            local subj=$(git log --format="%s" -1 "$sha" 2>/dev/null)
            if [ -n "$REPO_URL" ]; then
                COMMIT_LINKS="$COMMIT_LINKS
- [\`$short\`]($REPO_URL/commit/$sha) $subj"
            else
                COMMIT_LINKS="$COMMIT_LINKS
- \`$short\` $subj"
            fi
        done
    fi
}

# Ensure labels exist (create missing ones silently)
ensure_label() {
    local name="$1" color="$2" desc="$3"
    gh label create "$name" --repo "$REPO" --color "$color" --description "$desc" 2>/dev/null || true
}

ensure_label "P1" "d73a4a" "Priority 1 (critical)"
ensure_label "P2" "e4e669" "Priority 2 (normal)"
ensure_label "P3" "0e8a16" "Priority 3 (low)"
ensure_label "P4" "c5def5" "Priority 4 (backlog)"
ensure_label "task" "1d76db" "General task"
ensure_label "weave-synced" "bfdadc" "Synced from/to Weave"

# Counters
CREATED_GH=0
CLOSED_GH=0
REOPENED_GH=0
CREATED_WV=0
CLOSED_WV=0
ALREADY_SYNCED=0
SKIPPED=0

# Function to get priority label
get_priority_label() {
    case $1 in
        0|1) echo "P1" ;;
        2) echo "P2" ;;
        3) echo "P3" ;;
        4) echo "P4" ;;
        *) echo "P2" ;;
    esac
}

# Function to get issue type label from metadata
get_type_label() {
    case "$1" in
        bug) echo "bug" ;;
        feature) echo "enhancement" ;;
        *) echo "task" ;;
    esac
}

# ═══════════════════════════════════════════════════════════════════════════
# Fetch both sides
# ═══════════════════════════════════════════════════════════════════════════

echo "📋 Fetching Weave nodes..."
NODES_JSON=$("$WV" list --all --json 2>/dev/null || echo "[]")
NODES_COUNT=$(echo "$NODES_JSON" | jq 'length')
echo "   Found $NODES_COUNT nodes"

echo "📋 Fetching GitHub issues..."
GH_ISSUES=$(gh issue list --repo "$REPO" --state all --limit 200 --json number,title,state,body,labels 2>/dev/null || echo "[]")
GH_COUNT=$(echo "$GH_ISSUES" | jq 'length')
echo "   Found $GH_COUNT GitHub issues"

echo ""

# ═══════════════════════════════════════════════════════════════════════════
# Phase 1: Weave → GitHub
# ═══════════════════════════════════════════════════════════════════════════

echo "🔍 Phase 1: Weave → GitHub..."

while read -r node; do
    NODE_ID=$(echo "$node" | jq -r '.id')
    TEXT=$(echo "$node" | jq -r '.text')
    STATUS=$(echo "$node" | jq -r '.status')
    METADATA_RAW=$(echo "$node" | jq -r '.metadata // "{}"')

    # Parse metadata — may contain invalid JSON escapes (e.g. \! from stored regex).
    # Try jq parse; on failure, fall back to empty object for safe field extraction.
    METADATA=$(echo "$METADATA_RAW" | jq '.' 2>/dev/null) || METADATA="{}"
    if [[ "$METADATA" != "{"* ]]; then
        METADATA="{}"
    fi

    PRIORITY=$(echo "$METADATA" | jq -r '.priority // 2' 2>/dev/null || echo "2")
    TYPE=$(echo "$METADATA" | jq -r '.type // "task"' 2>/dev/null || echo "task")
    DESC=$(echo "$METADATA" | jq -r '.description // ""' 2>/dev/null || echo "")
    GH_REF=$(echo "$METADATA" | jq -r '.gh_issue // empty' 2>/dev/null || echo "")
    NO_SYNC=$(echo "$METADATA" | jq -r '.no_sync // false' 2>/dev/null || echo "false")

    # Skip test nodes and nodes marked no_sync
    if [ "$TYPE" = "test" ] || [ "$NO_SYNC" = "true" ]; then
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    # Match: metadata.gh_issue first
    GH_MATCH=""
    if [ -n "$GH_REF" ] && [ "$GH_REF" != "null" ]; then
        GH_MATCH="$GH_REF"
    fi

    # Fallback: search by node ID in issue body
    if [ -z "$GH_MATCH" ]; then
        GH_MATCH=$(echo "$GH_ISSUES" | jq -r --arg id "$NODE_ID" '
            .[] | select(.body // "" | contains($id)) | .number' | head -1)
    fi

    if [ -z "$GH_MATCH" ] || [ "$GH_MATCH" = "null" ]; then
        # No GitHub issue exists — create one for any non-skipped node
        if [ "$STATUS" = "todo" ] || [ "$STATUS" = "active" ] || [ "$STATUS" = "done" ]; then
            # Dedup guard: skip if a GH issue with the exact same title already exists
            EXISTING_NUM=$(echo "$GH_ISSUES" | jq -r --arg title "$TEXT" \
                '.[] | select(.title == $title) | .number' 2>/dev/null | head -1)
            if [ -n "$EXISTING_NUM" ] && [ "$EXISTING_NUM" != "null" ]; then
                echo -e "${YELLOW}  ⏭ Skipping $NODE_ID — GH #$EXISTING_NUM already has same title${NC}"
                # Backfill the gh_issue reference
                UPDATED_METADATA=$(echo "$METADATA" | jq --arg gh "$EXISTING_NUM" '. + {gh_issue: ($gh | tonumber)}' 2>/dev/null) || UPDATED_METADATA=""
                if [ -n "$UPDATED_METADATA" ]; then
                    "$WV" update "$NODE_ID" --metadata="$UPDATED_METADATA" >/dev/null 2>&1 || true
                fi
                ALREADY_SYNCED=$((ALREADY_SYNCED + 1))
                continue
            fi

            PRIORITY_LABEL=$(get_priority_label "$PRIORITY")
            TYPE_LABEL=$(get_type_label "$TYPE")

            echo -e "${GREEN}  ➕ Creating GH issue: $NODE_ID — $TEXT${NC}"

            BODY="**Weave ID**: \`$NODE_ID\`

$DESC

---
*Synced from Weave*"

            # Create issue, adding labels individually to avoid comma parsing issues
            NEW_GH=$(gh issue create --repo "$REPO" \
                --title "$TEXT" \
                --body "$BODY" \
                --label "$TYPE_LABEL" \
                --label "$PRIORITY_LABEL" \
                --label "weave-synced" 2>&1 || echo "")

            if echo "$NEW_GH" | grep -qE 'https://'; then
                NEW_GH_NUM=$(echo "$NEW_GH" | grep -oE '[0-9]+$')
                echo -e "     ${GREEN}✓ Created: #$NEW_GH_NUM${NC}"

                # Add newly-created issue to in-memory list to prevent duplicates in same run
                NEW_ISSUE_JSON=$(jq -n \
                    --arg num "$NEW_GH_NUM" \
                    --arg title "$TEXT" \
                    --arg body "$BODY" \
                    --arg state "OPEN" \
                    '{number: ($num | tonumber), title: $title, body: $body, state: $state, labels: []}')
                GH_ISSUES=$(echo "$GH_ISSUES" | jq --argjson new "$NEW_ISSUE_JSON" '. + [$new]')

                UPDATED_METADATA=$(echo "$METADATA" | jq --arg gh "$NEW_GH_NUM" '. + {gh_issue: ($gh | tonumber)}' 2>/dev/null) || UPDATED_METADATA=""
                if [ -n "$UPDATED_METADATA" ]; then
                    "$WV" update "$NODE_ID" --metadata="$UPDATED_METADATA" >/dev/null 2>&1 || true
                fi

                CREATED_GH=$((CREATED_GH + 1))

                # If node is already done, immediately close the GH issue with learnings
                if [ "$STATUS" = "done" ]; then
                    CLOSE_COMMENT="Completed. Weave node \`$NODE_ID\` closed."
                    L_DECISION=$(echo "$METADATA" | jq -r '.decision // empty' 2>/dev/null)
                    L_PATTERN=$(echo "$METADATA" | jq -r '.pattern // empty' 2>/dev/null)
                    L_PITFALL=$(echo "$METADATA" | jq -r '.pitfall // empty' 2>/dev/null)

                    if [ -n "$L_DECISION" ] || [ -n "$L_PATTERN" ] || [ -n "$L_PITFALL" ]; then
                        CLOSE_COMMENT="$CLOSE_COMMENT

**Learnings:**"
                        [ -n "$L_DECISION" ] && CLOSE_COMMENT="$CLOSE_COMMENT
- **Decision:** $L_DECISION"
                        [ -n "$L_PATTERN" ] && CLOSE_COMMENT="$CLOSE_COMMENT
- **Pattern:** $L_PATTERN"
                        [ -n "$L_PITFALL" ] && CLOSE_COMMENT="$CLOSE_COMMENT
- **Pitfall:** $L_PITFALL"
                    fi

                    build_commit_links "$NODE_ID"
                    CLOSE_COMMENT="$CLOSE_COMMENT$COMMIT_LINKS"

                    gh issue close "$NEW_GH_NUM" --repo "$REPO" \
                        --comment "$CLOSE_COMMENT" 2>/dev/null || true
                    echo -e "     ${YELLOW}🔒 Immediately closed (node already done)${NC}"
                    CLOSED_GH=$((CLOSED_GH + 1))
                fi
            else
                echo -e "     ${RED}✗ Failed: $NEW_GH${NC}"
            fi
        else
            SKIPPED=$((SKIPPED + 1))
        fi
    else
        # GitHub issue exists — sync status
        GH_STATE=$(echo "$GH_ISSUES" | jq -r --arg num "$GH_MATCH" \
            '.[] | select(.number == ($num | tonumber)) | .state')

        if [ "$STATUS" = "done" ] && [ "$GH_STATE" = "OPEN" ]; then
            echo -e "${YELLOW}  🔒 Closing GH #$GH_MATCH (node $NODE_ID is done)${NC}"

            # Build close comment with learnings from metadata
            CLOSE_COMMENT="Completed. Weave node \`$NODE_ID\` closed."
            L_DECISION=$(echo "$METADATA" | jq -r '.decision // empty' 2>/dev/null)
            L_PATTERN=$(echo "$METADATA" | jq -r '.pattern // empty' 2>/dev/null)
            L_PITFALL=$(echo "$METADATA" | jq -r '.pitfall // empty' 2>/dev/null)

            if [ -n "$L_DECISION" ] || [ -n "$L_PATTERN" ] || [ -n "$L_PITFALL" ]; then
                CLOSE_COMMENT="$CLOSE_COMMENT

**Learnings:**"
                [ -n "$L_DECISION" ] && CLOSE_COMMENT="$CLOSE_COMMENT
- **Decision:** $L_DECISION"
                [ -n "$L_PATTERN" ] && CLOSE_COMMENT="$CLOSE_COMMENT
- **Pattern:** $L_PATTERN"
                [ -n "$L_PITFALL" ] && CLOSE_COMMENT="$CLOSE_COMMENT
- **Pitfall:** $L_PITFALL"
            fi

            build_commit_links "$NODE_ID"
            CLOSE_COMMENT="$CLOSE_COMMENT$COMMIT_LINKS"

            gh issue close "$GH_MATCH" --repo "$REPO" \
                --comment "$CLOSE_COMMENT" 2>/dev/null || true
            CLOSED_GH=$((CLOSED_GH + 1))
        elif [ "$STATUS" != "done" ] && [ "$GH_STATE" = "CLOSED" ]; then
            echo -e "${BLUE}  🔓 Reopening GH #$GH_MATCH (node $NODE_ID is still open)${NC}"
            gh issue reopen "$GH_MATCH" --repo "$REPO" \
                --comment "Reopening — Weave node \`$NODE_ID\` is still open." 2>/dev/null || true
            REOPENED_GH=$((REOPENED_GH + 1))
        else
            ALREADY_SYNCED=$((ALREADY_SYNCED + 1))
        fi

        # Backfill metadata if matched by body search
        if [ -z "$GH_REF" ] || [ "$GH_REF" = "null" ]; then
            UPDATED_METADATA=$(echo "$METADATA" | jq --arg gh "$GH_MATCH" '. + {gh_issue: ($gh | tonumber)}' 2>/dev/null) || UPDATED_METADATA=""
            if [ -n "$UPDATED_METADATA" ]; then
                "$WV" update "$NODE_ID" --metadata="$UPDATED_METADATA" >/dev/null 2>&1 || true
            fi
        fi
    fi
done < <(echo "$NODES_JSON" | jq -c '.[]' 2>/dev/null)

# ═══════════════════════════════════════════════════════════════════════════
# Phase 2: GitHub → Weave
# ═══════════════════════════════════════════════════════════════════════════

echo ""
echo "🔍 Phase 2: GitHub → Weave..."

# Re-fetch nodes after phase 1 updates
NODES_JSON=$("$WV" list --all --json 2>/dev/null || echo "[]")

# Build set of GH issue numbers already tracked in Weave
TRACKED_GH_NUMS=$(echo "$NODES_JSON" | jq -r '.[].metadata' 2>/dev/null \
    | jq -r '.gh_issue // empty' 2>/dev/null \
    | sort -u)

# Also collect node IDs for body-matching
NODE_IDS=$(echo "$NODES_JSON" | jq -r '.[].id' 2>/dev/null)

while read -r issue; do
    GH_NUM=$(echo "$issue" | jq -r '.number')
    GH_TITLE=$(echo "$issue" | jq -r '.title')
    GH_STATE=$(echo "$issue" | jq -r '.state')
    GH_BODY=$(echo "$issue" | jq -r '.body // ""')

    # Skip if already tracked by metadata.gh_issue
    if echo "$TRACKED_GH_NUMS" | grep -qx "$GH_NUM"; then
        continue
    fi

    # Skip if issue body contains a known node ID (already linked)
    BODY_MATCH=false
    for nid in $NODE_IDS; do
        if echo "$GH_BODY" | grep -q "$nid"; then
            BODY_MATCH=true
            break
        fi
    done
    if [ "$BODY_MATCH" = true ]; then
        continue
    fi

    # New GH issue not in Weave — create a node
    if [ "$GH_STATE" = "OPEN" ]; then
        echo -e "${GREEN}  ➕ Creating Weave node for GH #$GH_NUM — $GH_TITLE${NC}"

        NEW_ID=$("$WV" add "$GH_TITLE" --metadata="{\"gh_issue\":$GH_NUM,\"source\":\"github\"}" --standalone 2>/dev/null | tail -1)

        if [ -n "$NEW_ID" ]; then
            echo -e "     ${GREEN}✓ Created: $NEW_ID${NC}"
            CREATED_WV=$((CREATED_WV + 1))
        fi
    elif [ "$GH_STATE" = "CLOSED" ]; then
        # Closed GH issue with no Weave node — skip (don't import old closed issues)
        SKIPPED=$((SKIPPED + 1))
    fi
done < <(echo "$GH_ISSUES" | jq -c '.[]' 2>/dev/null)

# ═══════════════════════════════════════════════════════════════════════════
# Phase 3: Sync closed GH issues → mark Weave nodes done
# ═══════════════════════════════════════════════════════════════════════════

echo ""
echo "🔍 Phase 3: Closed GH issues → Weave..."

# Re-fetch after phase 2
NODES_JSON=$("$WV" list --all --json 2>/dev/null || echo "[]")

while read -r node; do
    NODE_ID=$(echo "$node" | jq -r '.id')
    STATUS=$(echo "$node" | jq -r '.status')
    METADATA_RAW=$(echo "$node" | jq -r '.metadata // "{}"')
    METADATA=$(echo "$METADATA_RAW" | jq '.' 2>/dev/null) || METADATA="{}"
    if [[ "$METADATA" != "{"* ]]; then
        METADATA="{}"
    fi

    GH_REF=$(echo "$METADATA" | jq -r '.gh_issue // empty' 2>/dev/null || echo "")

    # Only check nodes that are open and have a GH reference
    if [ -n "$GH_REF" ] && [ "$GH_REF" != "null" ] && [ "$STATUS" != "done" ]; then
        GH_STATE=$(echo "$GH_ISSUES" | jq -r --arg num "$GH_REF" \
            '.[] | select(.number == ($num | tonumber)) | .state')

        if [ "$GH_STATE" = "CLOSED" ]; then
            echo -e "${YELLOW}  ✓ Closing Weave $NODE_ID (GH #$GH_REF is closed)${NC}"
            # shellcheck disable=SC1010  # 'done' is a wv subcommand, not bash keyword
            "$WV" done "$NODE_ID" 2>/dev/null || true
            CLOSED_WV=$((CLOSED_WV + 1))
        fi
    fi
done < <(echo "$NODES_JSON" | jq -c '.[]' 2>/dev/null)

# Persist
"$WV" sync >/dev/null 2>&1 || true

echo ""
echo "════════════════════════════════════════"
echo -e "${GREEN}✅ Sync complete!${NC}"
echo "   Repo: $REPO"
echo "════════════════════════════════════════"
