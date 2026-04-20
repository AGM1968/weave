#!/bin/bash
# PreToolUse hook: Enforce graph-first before edits (require valid Context Pack)
# Per proposal (lines 204-208):
#   Triggers on: edit_file, create_file, wv done
#   Does NOT trigger on: read-only operations, wv add, wv show

set -e

# Read stdin (JSON payload from Claude Code)
INPUT=$(cat)

# Extract tool name and input
TOOL=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)
TOOL_INPUT=$(echo "$INPUT" | jq -r '.tool_input // empty' 2>/dev/null)

# Guard: block Read calls on large files without a limit (context load policy enforcement)
if [[ "$TOOL" == "Read" ]]; then
    FILE_PATH=$(echo "$TOOL_INPUT" | jq -r '.file_path // empty' 2>/dev/null)
    LIMIT=$(echo "$TOOL_INPUT" | jq -r '.limit // empty' 2>/dev/null)
    if [[ -n "$FILE_PATH" && -z "$LIMIT" && -f "$FILE_PATH" ]]; then
        LINE_COUNT=$(wc -l < "$FILE_PATH" 2>/dev/null || echo "0")
        if [[ "$LINE_COUNT" -gt 500 ]]; then
            jq -n --arg path "$FILE_PATH" --arg lines "$LINE_COUNT" \
                '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":("File \($path) has \($lines) lines — too large to read whole. Grep for structure first, then read with offset+limit (e.g. limit=200). Context load policy: always grep first on files >500 lines.")}}'
            exit 0
        fi
    fi
fi

# Block edits to installed copies (should edit source in scripts/ instead)
# Handles both Claude Code tool names (Edit/Write) and VS Code tool names (create_file, etc.)
if [[ "$TOOL" =~ ^(Edit|Write|create_file|replace_string_in_file|insert_edit_into_file|multi_replace_string_in_file)$ ]]; then
    # VS Code sends camelCase (filePath), Claude Code sends snake_case (file_path)
    FILE_PATH=$(echo "$TOOL_INPUT" | jq -r '.file_path // .filePath // empty' 2>/dev/null)
    if [[ "$FILE_PATH" =~ \.local/(bin|lib/weave) ]]; then
        cat >&2 <<EOF
ERROR: Editing installed copy at $FILE_PATH
Edit the SOURCE file instead:
  ~/.local/bin/wv          → scripts/wv
  ~/.local/lib/weave/lib/  → scripts/lib/
  ~/.local/lib/weave/cmd/  → scripts/cmd/
After editing source, run: ./install.sh
EOF
        exit 2
    fi
fi

# Check if this is an operation we should enforce
SHOULD_CHECK=false

# Edit operations — Claude Code names + VS Code names (matchers are ignored in VS Code,
# so all hooks fire on all tools; this filter is what actually gates enforcement)
if [[ "$TOOL" =~ ^(Edit|Write|NotebookEdit|mcp__ide__executeCode|create_file|replace_string_in_file|insert_edit_into_file|multi_replace_string_in_file|edit_notebook_file)$ ]]; then
    SHOULD_CHECK=true
fi

# Terminal commands: wv done or wv-close — Claude Code (Bash) + VS Code (run_in_terminal)
if [[ "$TOOL" == "Bash" || "$TOOL" == "run_in_terminal" ]]; then
    CMD=$(echo "$TOOL_INPUT" | jq -r '.cmd // .command // empty' 2>/dev/null)
    if [[ "$CMD" =~ (wv[[:space:]]+done|wv-close|wv[[:space:]]done) ]]; then
        SHOULD_CHECK=true
    fi
    # Bootstrapping commands: always allow even with 0 active nodes.
    # wv add/work/ready/status/list/show/sync are graph reads or node creation —
    # they cannot proceed without being allowed first (catch-22 prevention).
    if [[ "$CMD" =~ ^[[:space:]]*(wv[[:space:]]+(add|work|ready|status|list|show|sync|load|doctor)|wv-init-repo|wv[[:space:]]+--help) ]]; then
        exit 0
    fi
fi

if [ "$SHOULD_CHECK" = "false" ]; then
    exit 0
fi

# Find active node (status=active)
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HOOK_DIR/../lib/wv-resolve-project.sh" 2>/dev/null || source "$HOOK_DIR/../../scripts/lib/wv-resolve-project.sh" || exit 0

# Only enforce in projects explicitly initialised with wv-init-repo (.weave/ present)
# This prevents the hook from blocking edits in personal notes, /tmp, plain git repos, etc.
if [ -z "${WV_PROJECT_DIR:-}" ] || [ ! -d "${WV_PROJECT_DIR}/.weave" ]; then
    exit 0
fi

if [ ! -x "$WV" ]; then
    # wv not available, allow action
    exit 0
fi

# DB health pre-flight: verify hot zone DB exists before attempting wv queries
# Mirrors wv-config.sh hot zone resolution logic
_PA_REPO_HASH=$(echo "$WV_PROJECT_DIR" | md5sum | cut -c1-8)
_PA_HOT_ZONE="${WV_HOT_ZONE:-/dev/shm/weave/${_PA_REPO_HASH}}"
_PA_DB="${WV_DB:-${_PA_HOT_ZONE}/brain.db}"
if [ ! -f "$_PA_DB" ]; then
    # DB not loaded — allow action (session start hook will load it on next run)
    exit 0
fi

# Hygiene tally (C1): track Edit/Write attempts in this repo and how many had
# an active node at the gate. Read by `wv session-summary` to compute score.
# Only count true Edit-class operations (not the wv done Bash variant).
if [[ "$TOOL" =~ ^(Edit|Write|NotebookEdit|create_file|replace_string_in_file|insert_edit_into_file|multi_replace_string_in_file|edit_notebook_file)$ ]]; then
    _PA_EDITS_FILE="${_PA_HOT_ZONE}/session-edits.json"
    _PA_PRIOR=$(cat "$_PA_EDITS_FILE" 2>/dev/null || echo '{}')
    _PA_TOTAL=$(echo "$_PA_PRIOR" | jq -r '.total // 0' 2>/dev/null || echo 0)
    _PA_WITH=$(echo "$_PA_PRIOR" | jq -r '.with_active // 0' 2>/dev/null || echo 0)
    _PA_NEW_TOTAL=$((_PA_TOTAL + 1))
    # Compute with_active increment after the active check below; persist totals now.
fi

# Phase-aware enforcement: skip active-node check in discover/closing phases.
# discover = session just started, agent is exploring before claiming work.
# closing  = node just closed via wv done; allow the follow-up commit.
# execute  = node claimed, substantive work in progress (enforce active node).
# No sentinel = fall back to execute behaviour (safe default).
_PA_PHASE=$(cat "${_PA_HOT_ZONE}/.session_phase" 2>/dev/null || echo "execute")

if [ "$_PA_PHASE" = "discover" ] || [ "$_PA_PHASE" = "closing" ]; then
    # Still record the untracked edit in hygiene tally (count it, but with_active stays 0).
    if [ -n "${_PA_NEW_TOTAL:-}" ]; then
        jq -n \
            --argjson total "$_PA_NEW_TOTAL" \
            --argjson with_active "$_PA_WITH" \
            '{total:$total, with_active:$with_active}' \
            > "$_PA_EDITS_FILE" 2>/dev/null || true
    fi
    exit 0
fi

# Get active nodes (execute phase only — saves subprocess in discover/closing)
ACTIVE_NODES=$("$WV" list --status=active --json 2>/dev/null || echo "[]")
ACTIVE_COUNT=$(echo "$ACTIVE_NODES" | jq 'length' 2>/dev/null || echo "0")

# Persist hygiene tally now that ACTIVE_COUNT is known.
if [ -n "${_PA_NEW_TOTAL:-}" ]; then
    _PA_NEW_WITH="$_PA_WITH"
    [ "$ACTIVE_COUNT" != "0" ] && _PA_NEW_WITH=$((_PA_WITH + 1))
    jq -n \
        --argjson total "$_PA_NEW_TOTAL" \
        --argjson with_active "$_PA_NEW_WITH" \
        '{total:$total, with_active:$with_active}' \
        > "$_PA_EDITS_FILE" 2>/dev/null || true
fi

if [ "$ACTIVE_COUNT" = "0" ]; then
    # No active nodes, suggest using /weave to start work
    cat >&2 <<EOF
⚠️  No active Weave node found (phase: execute).

Use \`/weave\` to select work before editing files:
- \`/weave\` — Show ready work
- \`/weave wv-xxxxxx\` — Claim specific node
- \`/weave "description"\` — Create new node

This ensures graph-first workflow with Context Pack generation.
EOF
    exit 2
fi

# Stale-node check: active node must have been claimed in the current session.
# Prevents silently inheriting a node from a prior session without explicit re-claim.
SESSION_EPOCH_FILE="${_PA_HOT_ZONE}/.session_epoch"
if [ -f "$SESSION_EPOCH_FILE" ]; then
    SESSION_EPOCH=$(cat "$SESSION_EPOCH_FILE" 2>/dev/null || echo "0")
    NODE_UPDATED=$(echo "$ACTIVE_NODES" | jq -r '.[0].updated_at // empty' 2>/dev/null || echo "")
    if [ -n "$NODE_UPDATED" ] && [ -n "$SESSION_EPOCH" ] && [ "$SESSION_EPOCH" != "0" ]; then
        NODE_EPOCH=$(date -d "$NODE_UPDATED" +%s 2>/dev/null || echo "0")
        STALE_ID=$(echo "$ACTIVE_NODES" | jq -r '.[0].id' 2>/dev/null || echo "?")
        STALE_TEXT=$(echo "$ACTIVE_NODES" | jq -r '.[0].text // "[unknown]"' 2>/dev/null || echo "[unknown]")
        if [ "$NODE_EPOCH" -gt 0 ] && [ "$NODE_EPOCH" -lt "$SESSION_EPOCH" ]; then
            cat >&2 <<EOF
⚠️  Stale active node not claimed this session: $STALE_ID
"$STALE_TEXT"

This node was active before the current session started. Explicitly re-claim
it before editing to confirm this is the work you intend to do:
  wv work $STALE_ID

Or create a new node if this is different work:
  wv add "<description>" --status=active
EOF
            exit 2
        fi
    fi
fi

if [ "$ACTIVE_COUNT" -gt "1" ]; then
    # Multiple active nodes — use primary if set, otherwise warn
    PRIMARY_FILE="${WV_HOT_ZONE:-/dev/shm/weave}/primary"
    # Resolve hot zone for this repo
    if [ -z "${WV_HOT_ZONE:-}" ]; then
        _REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
        _REPO_HASH=$(echo "$_REPO_ROOT" | md5sum | cut -c1-8)
        PRIMARY_FILE="/dev/shm/weave/${_REPO_HASH}/primary"
    fi
    if [ -f "$PRIMARY_FILE" ]; then
        NODE_ID=$(cat "$PRIMARY_FILE" 2>/dev/null)
    fi
fi

# Get the active node ID (fall back to first active if no primary)
if [ -z "${NODE_ID:-}" ]; then
    NODE_ID=$(echo "$ACTIVE_NODES" | jq -r '.[0].id' 2>/dev/null)
fi

if [ -z "$NODE_ID" ] || [ "$NODE_ID" = "null" ]; then
    exit 0
fi

# Check if Context Pack has been generated (cache exists or can be generated)
# Re-use hot zone computed in DB pre-flight above
CACHE_DIR="${_PA_HOT_ZONE}/context_cache"
CACHE_FILE="$CACHE_DIR/${NODE_ID}.json"

# First-call-only: skip context check on repeat calls within a session (D2 Option C)
# The stamp is cleared by invalidate_context_cache() when edges change (block/link/done/resolve)
CHECKED_STAMP="${_PA_HOT_ZONE}/.context_checked_${NODE_ID}"
if [ -f "$CHECKED_STAMP" ]; then
    exit 0
fi

# Try to generate/retrieve Context Pack
CONTEXT_PACK=$("$WV" context "$NODE_ID" --json 2>/dev/null || echo "")

if [ -z "$CONTEXT_PACK" ]; then
    # Soft warning (exit 1) — wv context may fail due to DB contention, missing
    # wv binary, or transient errors. Agent is informed but not hard-blocked.
    cat >&2 <<EOF
⚠️  Context Pack generation failed for node $NODE_ID.
Check: wv show $NODE_ID / wv status
EOF
    exit 1
fi

# Check for contradictions
CONTRADICTIONS=$(echo "$CONTEXT_PACK" | jq '.contradictions | length' 2>/dev/null || echo "0")
if [ "$CONTRADICTIONS" -gt "0" ]; then
    CONTRADICTION_LIST=$(echo "$CONTEXT_PACK" | jq -r '.contradictions[] | "  - \(.id): \(.text)"' 2>/dev/null || echo "")
    cat >&2 <<EOF
🛑 HARD STOP: Contradictions detected for node $NODE_ID

The following nodes contradict your current work:
$CONTRADICTION_LIST

Resolve contradictions before proceeding:
  \`wv resolve $NODE_ID <other-id> --winner=$NODE_ID\` (if this approach wins)
  \`wv resolve $NODE_ID <other-id> --merge\` (combine both approaches)
  \`wv resolve $NODE_ID <other-id> --defer\` (defer decision, mark as related)

Cannot proceed to EXECUTE phase until contradictions are resolved.
EOF
    exit 2
fi

# Check for blockers (only non-done blockers count)
BLOCKERS=$(echo "$CONTEXT_PACK" | jq '[.blockers[] | select(.status != "done")] | length' 2>/dev/null || echo "0")
if [ "$BLOCKERS" -gt "0" ]; then
    BLOCKER_LIST=$(echo "$CONTEXT_PACK" | jq -r '.blockers[] | select(.status != "done") | "  - \(.id): \(.text)"' 2>/dev/null || echo "")
    cat >&2 <<EOF
🛑 BLOCKED: Cannot proceed with node $NODE_ID

This node is blocked by:
$BLOCKER_LIST

Complete the blocking work first, then retry.
Or unblock with: \`wv update $NODE_ID --status=todo\` (removes blocked status)
EOF
    exit 2
fi

# All checks passed - Context Pack is valid, no contradictions, no blockers
# Stamp this node as checked for the session (first-call-only optimization)
touch "$CHECKED_STAMP" 2>/dev/null || true
# Allow the edit to proceed
exit 0
