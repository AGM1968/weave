#!/bin/bash
# wv-hook-common.sh — shared helper for Claude hook scripts
#
# Provides a single source for:
#   - hot-zone resolution (_HC_HOT_ZONE)
#   - DB path resolution (_HC_DB)
#   - session phase read with default (_HC_PHASE)
#   - DB preflight helper (_hc_db_preflight)

# Guard against double-source in nested hooks.
if [ -n "${_WV_HOOK_COMMON_LOADED:-}" ]; then
    return 0
fi
_WV_HOOK_COMMON_LOADED=1

# Tag all wv calls from hook context so wv analyze --source=hook can isolate them.
# Unconditional: the Claude Code session env carries WV_CALL_SOURCE=agent
# (settings.json), which hooks inherit — a lifecycle hook is infrastructure,
# not model-driven traffic, so it must override the inherited tag.
export WV_CALL_SOURCE=hook

_HC_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_HC_LIB_DIR/wv-resolve-runtime.sh" 2>/dev/null || true

_hc_project_dir() {
    local project_dir="${WV_PROJECT_DIR:-}"
    if [ -z "$project_dir" ]; then
        project_dir=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
    fi
    if [ -d "$project_dir" ]; then
        project_dir=$(cd "$project_dir" 2>/dev/null && pwd -P)
    fi
    printf '%s\n' "$project_dir"
}

_hc_hot_zone() {
    local project_dir="$1"
    local repo_hash
    repo_hash=$(printf '%s' "$project_dir" | md5sum | cut -c1-8)

    if type resolve_repo_hot_zone >/dev/null 2>&1; then
        resolve_repo_hot_zone "${WV_HOT_ZONE:-}" "$project_dir"
        return 0
    fi

    if [ -n "${WV_HOT_ZONE:-}" ]; then
        printf '%s\n' "$WV_HOT_ZONE"
    else
        printf '/dev/shm/weave/%s\n' "$repo_hash"
    fi
}

_hc_db_path() {
    local hot_zone="$1"

    if type resolve_db >/dev/null 2>&1; then
        resolve_db "$hot_zone"
        return 0
    fi

    if [ -n "${WV_DB:-}" ]; then
        printf '%s\n' "$WV_DB"
    else
        printf '%s/brain.db\n' "$hot_zone"
    fi
}

_hc_phase_value() {
    local hot_zone="$1"
    cat "${hot_zone}/.session_phase" 2>/dev/null || echo "execute"
}

_hc_refresh() {
    _HC_PROJECT_DIR=$(_hc_project_dir)
    _HC_REPO_HASH=$(printf '%s' "$_HC_PROJECT_DIR" | md5sum | cut -c1-8)
    _HC_HOT_ZONE=$(_hc_hot_zone "$_HC_PROJECT_DIR")
    _HC_DB=$(_hc_db_path "$_HC_HOT_ZONE")
    _HC_PHASE=$(_hc_phase_value "$_HC_HOT_ZONE")
}

# _hc_db_preflight — verify the hot-zone DB exists before attempting wv queries.
# Args: [db_path] — defaults to $_HC_DB.
# Returns:
#   0 → DB exists (or no path configured); caller continues
#   1 → DB missing; caller: exit 0
_hc_db_preflight() {
    local db_path="${1:-${_HC_DB:-}}"
    [ -n "$db_path" ] || return 0
    if [ ! -f "$db_path" ]; then return 1; fi
    return 0
}

# _hc_init_hygiene_tally — initialize edit-hygiene counters for Edit-class tools.
# Args: tool_name
# Reads globals: _HC_HOT_ZONE.
# Sets globals: _HC_TALLY_FILE, _HC_NEW_TOTAL, _HC_WITH_ACTIVE.
# Non-edit tools set all globals empty; callers use ${_HC_NEW_TOTAL:-} safely.
_hc_init_hygiene_tally() {
    local tool="$1"
    _HC_TALLY_FILE=""
    _HC_NEW_TOTAL=""
    _HC_WITH_ACTIVE=""
    if _wf_in_list "$tool" "${_WF_HOOK_EDIT_TOOLS[@]}"; then
        _HC_TALLY_FILE="${_HC_HOT_ZONE}/session-edits.json"
        local prior total with_active
        prior=$(cat "$_HC_TALLY_FILE" 2>/dev/null || echo '{}')
        total=$(echo "$prior" | jq -r '.total // 0' 2>/dev/null || echo 0)
        with_active=$(echo "$prior" | jq -r '.with_active // 0' 2>/dev/null || echo 0)
        _HC_NEW_TOTAL=$((total + 1))
        _HC_WITH_ACTIVE="$with_active"
    fi
}

# ─── PreToolUse guard functions ───────────────────────────────────────────────
# Extracted from pre-action.sh so each check is a named, testable unit.
# Callers use the return code to decide whether to exit:
#   return 0  → no issue, continue
#   return 1  → soft deny (JSON already printed to stdout); caller: exit 0
#   return 2  → hard block (message on stderr); caller: exit 2

# _hc_check_read_size — deny Read on files >500 lines when no limit is set.
# Outputs the deny JSON; returns 1 so caller can: _hc_check_read_size ... || exit 0
_hc_check_read_size() {
    local tool="$1" tool_input="$2"
    [[ "$tool" == "Read" ]] || return 0
    local file_path limit line_count
    file_path=$(printf '%s' "$tool_input" | jq -r '.file_path // empty' 2>/dev/null)
    limit=$(printf '%s' "$tool_input" | jq -r '.limit // empty' 2>/dev/null)
    [[ -n "$file_path" && -z "$limit" && -f "$file_path" ]] || return 0
    line_count=$(wc -l < "$file_path" 2>/dev/null || echo "0")
    [[ "$line_count" -gt 500 ]] || return 0
    jq -n --arg path "$file_path" --arg lines "$line_count" \
        '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":("File \($path) has \($lines) lines — too large to read whole. Grep for structure first, then read with offset+limit (e.g. limit=200). Context load policy: always grep first on files >500 lines.")}}'
    return 1
}

# _hc_check_installed_path — hard-block edits to ~/.local/bin or ~/.local/lib/weave.
# Prints an explanation to stderr; returns 2 so caller can: ... || exit $?
_hc_check_installed_path() {
    local tool="$1" tool_input="$2"
    _wf_in_list "$tool" "${_WF_HOOK_EDIT_TOOLS[@]}" || return 0
    local file_path
    # VS Code sends camelCase (filePath); Claude Code sends snake_case (file_path)
    file_path=$(printf '%s' "$tool_input" | jq -r '.file_path // .filePath // empty' 2>/dev/null)
    [[ "$file_path" =~ \.local/(bin|lib/weave) ]] || return 0
    cat >&2 <<EOF
ERROR: Editing installed copy at $file_path
Edit the SOURCE file instead:
  ~/.local/bin/wv          → scripts/wv
  ~/.local/lib/weave/lib/  → scripts/lib/
  ~/.local/lib/weave/cmd/  → scripts/cmd/
After editing source, run: ./install.sh
EOF
    return 2
}

# _hc_classify_tool — classify the tool call into enforcement categories.
# Sets globals (follow _HC_ prefix convention):
#   _HC_SHOULD_CHECK  — true if active-node enforcement should run
#   _HC_IS_EDIT_TOOL  — true if tool is an edit operation (not just a wv-done Bash call)
#   _HC_BYPASS_CMD    — true if caller should exit 0 immediately (bootstrap command)
_HC_CLASSES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# Generated at install/build time from templates/workflow-classes.conf. Kept adjacent
# to this library so source and installed hooks resolve the identical projection.
#
# This library is sourced on the LEFT of pre-action's `source ... || ... || true`
# chain, which suppresses set -e — so a missing/partial projection would NOT abort,
# it would leave the _WF_* arrays empty and SILENTLY disable all classification
# (every edit/close would fall through to allow). A counterweight must never
# self-disable silently: guard the source, and if the projection did not populate
# the classes, fall back to the canonical lists and warn. The fallback duplicates
# the manifest deliberately as a last resort; the manifest remains the source of
# truth for the normal (projection-present) path.
source "$_HC_CLASSES_DIR/wv-workflow-classes.gen.sh" 2>/dev/null || true
if [ "${#_WF_HOOK_EDIT_TOOLS[@]}" -eq 0 ]; then
    echo "wv hook: workflow-classes projection missing or empty; using built-in fallback" >&2
    _WF_BOOTSTRAP_ALLOW=( add work ready status list show sync load doctor bootstrap search context quick recover )
    _WF_CLOSE_GATED=( "done" ship )
    _WF_HOOK_EDIT_TOOLS=( Edit Write NotebookEdit mcp__ide__executeCode create_file replace_string_in_file insert_edit_into_file multi_replace_string_in_file edit_notebook_file )
    _WF_CLAUDE_EDIT_EXEMPT_PREFIXES=( "\$HOME/.claude/" )
fi

# _wf_in_list — exact membership test for generated workflow classes.
_wf_in_list() {
    local needle="$1"
    shift
    local value
    for value in "$@"; do [ "$value" = "$needle" ] && return 0; done
    return 1
}

_hc_classify_tool() {
    local tool="$1" tool_input="$2"
    _HC_SHOULD_CHECK=false
    _HC_IS_EDIT_TOOL=false
    _HC_BYPASS_CMD=false

    # Edit-class tools (Claude Code + VS Code names)
    if _wf_in_list "$tool" "${_WF_HOOK_EDIT_TOOLS[@]}"; then
        local file_path
        # VS Code sends camelCase (filePath); Claude Code sends snake_case (file_path)
        file_path=$(printf '%s' "$tool_input" | jq -r '.file_path // .filePath // empty' 2>/dev/null)
        # $HOME/.claude/ is Claude Code's own runtime/memory layer — external state,
        # not project work. Leave SHOULD_CHECK/IS_EDIT_TOOL false so the dispatcher
        # exits 0 (no node, no phase gate, no hygiene tally). NOTE: only $HOME/.claude/
        # — project-local .claude/ (hooks, settings, skills) stays governed.
        #
        # PreToolUse stays allow/deny only here (it cannot rewrite a write into a
        # graph insert). The prior "external state, do nothing" stance is NARROWLY
        # superseded for repo-scoped durable memory by capture-after-write:
        # .claude/hooks/post-memory-capture.sh (PostToolUse) imports a matching
        # $HOME/.claude/projects/<repo-slug>/memory/*.md write into the graph as a
        # mem_status=candidate node. See PROPOSAL-wv-agent-memory-substrate S5 and
        # the feedback_memory_writes_external memory.
        local exempt_prefix
        for exempt_prefix in "${_WF_CLAUDE_EDIT_EXEMPT_PREFIXES[@]}"; do
            exempt_prefix="${exempt_prefix/\$HOME/${HOME:-}}"
            [[ -n "${HOME:-}" && "$file_path" == "$exempt_prefix"* ]] && return 0
        done
        _HC_SHOULD_CHECK=true
        _HC_IS_EDIT_TOOL=true
        return 0
    fi

    # Terminal commands
    if [[ "$tool" == "Bash" || "$tool" == "run_in_terminal" ]]; then
        local cmd
        cmd=$(printf '%s' "$tool_input" | jq -r '.cmd // .command // empty' 2>/dev/null)
        # Close-class commands / wv-close → enforce active node.
        local close_command
        for close_command in "${_WF_CLOSE_GATED[@]}"; do
            [[ "$cmd" =~ wv[[:space:]]+"$close_command" ]] && {
                _HC_SHOULD_CHECK=true
                return 0
            }
        done
        if [[ "$cmd" =~ wv-close ]]; then _HC_SHOULD_CHECK=true; return 0; fi
        # Bootstrap commands — always allow (catch-22 prevention)
        local bootstrap_command
        for bootstrap_command in "${_WF_BOOTSTRAP_ALLOW[@]}"; do
            [[ "$cmd" =~ ^[[:space:]]*wv[[:space:]]+"$bootstrap_command" ]] && {
                _HC_BYPASS_CMD=true
                return 0
            }
        done
        if [[ "$cmd" =~ ^[[:space:]]*(wv-init-repo|wv[[:space:]]+--help) ]]; then _HC_BYPASS_CMD=true; return 0; fi
    fi
}

# _hc_check_phase — phase-aware enforcement gate.
# Reads globals: _HC_PHASE, _HC_IS_EDIT_TOOL, _HC_HOT_ZONE.
# Args: [new_total [with_active [edits_file]]] — hygiene tally written on early exit.
# Returns:
#   0 → execute phase; caller continues
#   1 → discover/closing, non-edit; caller: exit 0
#   2 → discover/closing, edit blocked; caller: exit 2
_hc_check_phase() {
    local new_total="${1:-}" with_active="${2:-}" edits_file="${3:-}"
    local phase="${_HC_PHASE:-execute}"
    local is_edit="${_HC_IS_EDIT_TOOL:-false}"

    if [ "$phase" != "discover" ] && [ "$phase" != "closing" ]; then
        return 0
    fi

    if [ -n "$new_total" ] && [ -n "$edits_file" ]; then
        jq -n \
            --argjson total "$new_total" \
            --argjson with_active "${with_active:-0}" \
            '{total:$total, with_active:$with_active}' \
            > "$edits_file" 2>/dev/null || true
    fi

    if [ "$is_edit" = "true" ]; then
        cat >&2 <<EOF
⚠️  File edit blocked during Weave $phase phase.

Discovery is for reading, searching, and planning only. Claim work before editing:
  wv work <id>
  wv add "<description>" --status=active --criteria="c1|c2" --risks=low

For a fresh session snapshot before picking work:
  wv bootstrap --json
EOF
        return 2
    fi

    if [ "$phase" = "closing" ]; then
        wv_set_phase "discover" "${_HC_HOT_ZONE:-}"
    fi
    return 1
}

# _hc_check_active_node — query active nodes, persist hygiene tally, block if none found.
# Sets globals: _HC_ACTIVE_NODES, _HC_ACTIVE_COUNT.
# Args: [new_total [with_active [edits_file]]] — hygiene tally written with correct with_active.
# Returns:
#   0 → active node(s) exist; caller continues
#   2 → no active node; caller: exit 2
_hc_check_active_node() {
    local new_total="${1:-}" with_active="${2:-}" edits_file="${3:-}"

    _HC_ACTIVE_NODES=$("$WV" list --status=active --json 2>/dev/null || echo "[]")
    _HC_ACTIVE_COUNT=$(echo "$_HC_ACTIVE_NODES" | jq 'length' 2>/dev/null || echo "0")

    if [ -n "$new_total" ] && [ -n "$edits_file" ]; then
        local new_with="${with_active:-0}"
        if [ "$_HC_ACTIVE_COUNT" != "0" ]; then
            new_with=$(( ${with_active:-0} + 1 ))
        fi
        jq -n \
            --argjson total "$new_total" \
            --argjson with_active "$new_with" \
            '{total:$total, with_active:$with_active}' \
            > "$edits_file" 2>/dev/null || true
    fi

    if [ "$_HC_ACTIVE_COUNT" = "0" ]; then
        cat >&2 <<EOF
⚠️  No active Weave node found (phase: execute).

Use \`/weave\` to select work before editing files:
- \`/weave\` — Show ready work
- \`/weave wv-xxxxxx\` — Claim specific node
- \`/weave "description"\` — Create new node

Useful compound helpers:
- \`wv bootstrap --json\` — Session snapshot (status + context + ready + learnings)
- \`wv quick "description"\` — Track trivial one-step work

This ensures graph-first workflow with Context Pack generation.
EOF
        return 2
    fi
    return 0
}

# _hc_check_stale_node — block if the first active node predates the current session.
# Reads globals: _HC_ACTIVE_NODES, _HC_HOT_ZONE.
# Returns:
#   0 → node is current, or epoch data unavailable; caller continues
#   2 → stale node; caller: exit 2
_hc_check_stale_node() {
    local session_epoch_file="${_HC_HOT_ZONE}/.session_epoch"
    [ -f "$session_epoch_file" ] || return 0

    local session_epoch node_updated
    session_epoch=$(cat "$session_epoch_file" 2>/dev/null || echo "0")
    node_updated=$(echo "${_HC_ACTIVE_NODES:-[]}" | jq -r '.[0].updated_at // empty' 2>/dev/null || echo "")

    [ -n "$node_updated" ] && [ -n "$session_epoch" ] && [ "$session_epoch" != "0" ] || return 0

    # updated_at comes from sqlite as a zone-less UTC stamp ("2026-06-10 11:40:00").
    # Force UTC interpretation (strip a trailing Z first) so timezones ahead of UTC
    # don't make every active node look hours-stale and falsely trip the block.
    local node_epoch stale_id stale_text
    node_epoch=$(date -d "${node_updated%Z} UTC" +%s 2>/dev/null || echo "0")
    stale_id=$(echo "${_HC_ACTIVE_NODES:-[]}" | jq -r '.[0].id' 2>/dev/null || echo "?")
    stale_text=$(echo "${_HC_ACTIVE_NODES:-[]}" | jq -r '.[0].text // "[unknown]"' 2>/dev/null || echo "[unknown]")

    if [ "$node_epoch" -gt 0 ] && [ "$node_epoch" -lt "$session_epoch" ]; then
        cat >&2 <<EOF
⚠️  Stale active node not claimed this session: $stale_id
"$stale_text"

This node was active before the current session started. Explicitly re-claim
it before editing to confirm this is the work you intend to do:
  wv work $stale_id

Or create a new node if this is different work:
  wv add "<description>" --status=active

For a fresh session snapshot before picking work:
    wv bootstrap --json
EOF
        return 2
    fi
    return 0
}

# _hc_resolve_primary_node — select the primary active node from _HC_ACTIVE_NODES.
# Reads globals: _HC_ACTIVE_COUNT, _HC_ACTIVE_NODES, _HC_HOT_ZONE.
# Sets globals: _HC_NODE_ID.
# Returns:
#   0 → node ID resolved; _HC_NODE_ID is set
#   1 → no usable node ID; caller: exit 0
_hc_resolve_primary_node() {
    _HC_NODE_ID=""
    if [ "${_HC_ACTIVE_COUNT:-0}" -gt "1" ]; then
        local primary_file="${_HC_HOT_ZONE}/primary"
        if [ -f "$primary_file" ]; then
            _HC_NODE_ID=$(cat "$primary_file" 2>/dev/null || echo "")
        fi
    fi
    if [ -z "${_HC_NODE_ID:-}" ]; then
        _HC_NODE_ID=$(echo "${_HC_ACTIVE_NODES:-[]}" | jq -r '.[0].id' 2>/dev/null || echo "")
    fi
    if [ -z "$_HC_NODE_ID" ] || [ "$_HC_NODE_ID" = "null" ]; then
        return 1
    fi
    return 0
}

# _hc_check_context_pack — retrieve Context Pack for a node; enforce first-call-only stamp.
# Args: node_id
# Reads globals: _HC_HOT_ZONE, WV.
# Sets globals: _HC_CONTEXT_PACK, _HC_CONTEXT_STAMP_HIT.
# Returns:
#   0 → context pack retrieved (check _HC_CONTEXT_STAMP_HIT for stamp hit); caller continues
#   1 → generation failed; caller: exit 1
_hc_check_context_pack() {
    local node_id="$1"
    local stamp="${_HC_HOT_ZONE}/.context_checked_${node_id}"
    _HC_CONTEXT_STAMP_HIT=false

    if [ -f "$stamp" ]; then
        _HC_CONTEXT_STAMP_HIT=true
        return 0
    fi

    _HC_CONTEXT_PACK=$("$WV" context "$node_id" --json 2>/dev/null || echo "")

    if [ -z "$_HC_CONTEXT_PACK" ]; then
        cat >&2 <<EOF
⚠️  Context Pack generation failed for node $node_id.
Check: wv show $node_id / wv status
EOF
        return 1
    fi
    return 0
}

# _hc_check_contradictions — hard-block if Context Pack reports contradictions.
# Args: node_id
# Reads globals: _HC_CONTEXT_PACK.
# Returns:
#   0 → no contradictions; caller continues
#   2 → contradictions found; caller: exit 2
_hc_check_contradictions() {
    local node_id="$1"
    local contradictions contradiction_list
    contradictions=$(echo "$_HC_CONTEXT_PACK" | jq '.contradictions | length' 2>/dev/null || echo "0")
    if [ "$contradictions" -gt "0" ]; then
        contradiction_list=$(echo "$_HC_CONTEXT_PACK" | jq -r '.contradictions[] | "  - \(.id): \(.text)"' 2>/dev/null || echo "")
        cat >&2 <<EOF
🛑 HARD STOP: Contradictions detected for node $node_id

The following nodes contradict your current work:
$contradiction_list

Resolve contradictions before proceeding:
  \`wv resolve $node_id <other-id> --winner=$node_id\` (if this approach wins)
  \`wv resolve $node_id <other-id> --merge\` (combine both approaches)
  \`wv resolve $node_id <other-id> --defer\` (defer decision, mark as related)

Cannot proceed to EXECUTE phase until contradictions are resolved.
EOF
        return 2
    fi
    return 0
}

# _hc_check_blockers — hard-block if Context Pack reports non-done blockers.
# Args: node_id
# Reads globals: _HC_CONTEXT_PACK.
# Returns:
#   0 → no blockers; caller continues
#   2 → blockers found; caller: exit 2
_hc_check_blockers() {
    local node_id="$1"
    local blockers blocker_list
    blockers=$(echo "$_HC_CONTEXT_PACK" | jq '[.blockers[] | select(.status != "done")] | length' 2>/dev/null || echo "0")
    if [ "$blockers" -gt "0" ]; then
        blocker_list=$(echo "$_HC_CONTEXT_PACK" | jq -r '.blockers[] | select(.status != "done") | "  - \(.id): \(.text)"' 2>/dev/null || echo "")
        cat >&2 <<EOF
🛑 BLOCKED: Cannot proceed with node $node_id

This node is blocked by:
$blocker_list

Complete the blocking work first, then retry.
Or unblock with: \`wv update $node_id --status=todo\` (removes blocked status)
EOF
        return 2
    fi
    return 0
}

# Initialize on source so simple hooks can consume _HC_* without extra boilerplate.
_hc_refresh
