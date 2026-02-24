#!/bin/bash
# PreCompact hook: Dump rich Weave context before conversation compaction.
# Output is injected into context so the model retains work state after summarization.
# Target: ~100-200 tokens (enough detail to resume, not so much it bloats).

set -e

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HOOK_DIR/../../scripts/lib/wv-resolve-project.sh" || exit 0
cd "$WV_PROJECT_DIR" 2>/dev/null || exit 0
[ -x "$WV" ] || exit 0

# Safety commit: save in-progress code before context compaction
# Prevents work loss if session hits limits after compact
"$WV" sync 2>/dev/null || true
# Stage only .weave/ state — code changes belong in intentional feature commits.
# Using 'git add -A' here caused race conditions with state.sql across sessions.
git add .weave/ 2>/dev/null || true
if ! git diff --cached --quiet 2>/dev/null; then
    git commit -m "wip: pre-compact checkpoint $(date +%H:%M) [skip ci]" --no-verify 2>/dev/null || true
fi

# Compact status line
STATUS=$("$WV" status 2>/dev/null) || exit 0

# Active nodes with full text (these are what we're working on right now)
# Per-repo DB namespace: derive from git root hash
_REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
_REPO_HASH=$(echo "$_REPO_ROOT" | md5sum | cut -c1-8)
WV_DB="${WV_DB:-/dev/shm/weave/${_REPO_HASH}/brain.db}"

ACTIVE=$(sqlite3 -json "$WV_DB" "
    SELECT id, text, json_extract(metadata, '$.type') as type
    FROM nodes WHERE status='active'
    ORDER BY updated_at DESC LIMIT 5;
" 2>/dev/null | jq -c '.' 2>/dev/null) || ACTIVE="[]"

# Blocked nodes and what blocks them
BLOCKED=$(sqlite3 -json "$WV_DB" "
    SELECT n.id, n.text,
           group_concat(e.source, ',') as blocked_by
    FROM nodes n
    JOIN edges e ON e.target = n.id AND e.type = 'blocks'
    JOIN nodes blocker ON e.source = blocker.id AND blocker.status != 'done'
    WHERE n.status = 'blocked'
    GROUP BY n.id
    LIMIT 5;
" 2>/dev/null | jq -c '.' 2>/dev/null) || BLOCKED="[]"

# Ready count
READY=$("$WV" ready --count 2>/dev/null) || READY="0"

# Recent learnings (last 3, if any)
LEARNINGS=$(sqlite3 -json "$WV_DB" "
    SELECT id,
           json_extract(metadata, '$.decision') as decision,
           json_extract(metadata, '$.pattern') as pattern,
           json_extract(metadata, '$.pitfall') as pitfall
    FROM nodes
    WHERE json_extract(metadata, '$.decision') IS NOT NULL
       OR json_extract(metadata, '$.pattern') IS NOT NULL
       OR json_extract(metadata, '$.pitfall') IS NOT NULL
    ORDER BY updated_at DESC LIMIT 3;
" 2>/dev/null | jq -c '.' 2>/dev/null) || LEARNINGS="[]"

# Breadcrumbs for active nodes (session memory capsules)
BREADCRUMBS=$(sqlite3 -json "$WV_DB" "
    SELECT id,
           json_extract(metadata, '$.breadcrumbs.goal') as goal,
           json_extract(metadata, '$.breadcrumbs.state') as state,
           json_extract(metadata, '$.breadcrumbs.next') as next_step,
           json_extract(metadata, '$.breadcrumbs.files') as files,
           json_extract(metadata, '$.breadcrumbs.blocking') as blocking
    FROM nodes
    WHERE status='active'
      AND json_extract(metadata, '$.breadcrumbs') IS NOT NULL
    ORDER BY updated_at DESC LIMIT 3;
" 2>/dev/null | jq -c '.' 2>/dev/null) || BREADCRUMBS="[]"

# Output as structured context
cat <<EOF
Weave state (pre-compact snapshot):
$STATUS
Active: $ACTIVE
Blocked: $BLOCKED
Ready: $READY
Learnings: $LEARNINGS
Breadcrumbs: $BREADCRUMBS
EOF
