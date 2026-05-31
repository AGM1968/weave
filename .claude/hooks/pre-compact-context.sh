#!/bin/bash
# PreCompact hook: Dump rich Weave context before conversation compaction.
# Output is injected into context so the model retains work state after summarization.
# Target: ~100-200 tokens (enough detail to resume, not so much it bloats).

set -e

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HOOK_DIR/../lib/wv-resolve-project.sh" 2>/dev/null || source "$HOOK_DIR/../../scripts/lib/wv-resolve-project.sh" || exit 0
source "$HOOK_DIR/../lib/wv-hook-common.sh" 2>/dev/null || source "$HOOK_DIR/../../scripts/lib/wv-hook-common.sh" 2>/dev/null || true
_hc_refresh
cd "$WV_PROJECT_DIR" 2>/dev/null || exit 0
[ -x "$WV" ] || exit 0

# Per-repo DB namespace and hot-zone stamp path from shared helper
WV_DB="${WV_DB:-${_HC_DB}}"
_PC_HOT_ZONE="${_HC_HOT_ZONE}"

# Safety commit: save in-progress code before context compaction
# Prevents work loss if session hits limits after compact
"$WV" sync 2>/dev/null || true
# Stage only .weave/ state — code changes belong in intentional feature commits.
# Using 'git add -A' here caused race conditions with state.sql across sessions.
_NOW=$(date +%s)
git add .weave/ 2>/dev/null || true
if ! git diff --cached --quiet 2>/dev/null; then
    _PC_BRANCH=$(git branch --show-current 2>/dev/null || echo "main")
    _PC_LOCAL=$(git rev-parse HEAD 2>/dev/null || echo "")
    _PC_REMOTE=$(git rev-parse "origin/$_PC_BRANCH" 2>/dev/null || echo "none")
    _PC_LAST_MSG=$(git log -1 --format='%s' 2>/dev/null || echo "")
    _PC_LAST_NW=$(git diff HEAD~1 HEAD --name-only 2>/dev/null | grep -v '^\.weave/' | grep -v '^$' || true)
    if [ "$_PC_LOCAL" != "$_PC_REMOTE" ] \
       && [[ "$_PC_LAST_MSG" =~ auto-checkpoint|sync\ state|session-start\ state|pre-compact\ checkpoint ]] \
       && [ -z "$_PC_LAST_NW" ]; then
        git commit --amend --no-edit --no-verify 2>/dev/null || \
        git commit -m "wip: pre-compact checkpoint $(date +%H:%M) [skip ci]" --no-verify 2>/dev/null || true
    else
        git commit -m "wip: pre-compact checkpoint $(date +%H:%M) [skip ci]" --no-verify 2>/dev/null || true
    fi
    echo "$_NOW" > "${_PC_HOT_ZONE}/.last_checkpoint" 2>/dev/null || true
fi

# Compact status line
STATUS=$("$WV" status 2>/dev/null) || exit 0

# Active nodes with full text (these are what we're working on right now)

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

# Breadcrumbs for active nodes (session memory capsules).
# Trails epic: read the newest entry from metadata.trails[] (append-only, newest
# is the last element), falling back to legacy metadata.breadcrumbs for nodes not
# yet migrated. json_each + ROW_NUMBER avoids the $.trails[#-1] index syntax,
# which only exists in SQLite >= 3.42 (dev/consumer machines may run older).
BREADCRUMBS=$(sqlite3 -json "$WV_DB" "
    SELECT n.id,
           COALESCE(json_extract(lt.entry, '$.goal'),     json_extract(n.metadata, '$.breadcrumbs.goal'))     as goal,
           COALESCE(json_extract(lt.entry, '$.state'),    json_extract(n.metadata, '$.breadcrumbs.state'))    as state,
           COALESCE(json_extract(lt.entry, '$.next'),     json_extract(n.metadata, '$.breadcrumbs.next'))     as next_step,
           COALESCE(json_extract(lt.entry, '$.files'),    json_extract(n.metadata, '$.breadcrumbs.files'))    as files,
           COALESCE(json_extract(lt.entry, '$.blocking'), json_extract(n.metadata, '$.breadcrumbs.blocking')) as blocking
    FROM nodes n
    LEFT JOIN (
        SELECT nodes.id AS nid, je.value AS entry,
               ROW_NUMBER() OVER (PARTITION BY nodes.id ORDER BY je.key DESC) AS rn
        FROM nodes, json_each(nodes.metadata, '$.trails') je
    ) lt ON lt.nid = n.id AND lt.rn = 1
    WHERE n.status='active'
      AND (json_extract(n.metadata, '$.trails') IS NOT NULL
           OR json_extract(n.metadata, '$.breadcrumbs') IS NOT NULL)
    ORDER BY n.updated_at DESC LIMIT 3;
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
