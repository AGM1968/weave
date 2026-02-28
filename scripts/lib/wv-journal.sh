#!/bin/bash
# wv-journal.sh — Durable execution journal (append-only JSONL)
#
# Sourced by: wv entry point (after wv-config.sh)
# Dependencies: wv-config.sh (for WV_HOT_ZONE)
#
# The operation journal records multi-step operation intentions so that
# interrupted operations (crash, network error, context limit) can be
# resumed from the last completed step.
#
# Storage: $WV_HOT_ZONE/ops.journal (hot zone, lost on reboot — by design)
# Format:  One JSON line per event, grouped by op_id
#
# Lifecycle:
#   journal_begin   → creates op with step_count, sets _WV_IN_JOURNAL=1
#   journal_step    → records pending step
#   journal_complete→ records step completion
#   journal_end     → marks op complete, unsets _WV_IN_JOURNAL
#   journal_recover → detects incomplete ops, returns recovery info

# ═══════════════════════════════════════════════════════════════════════════
# Constants
# ═══════════════════════════════════════════════════════════════════════════

_WV_JOURNAL_FILE="${WV_HOT_ZONE}/ops.journal"

# ═══════════════════════════════════════════════════════════════════════════
# Internal helpers
# ═══════════════════════════════════════════════════════════════════════════

# Generate a short random operation ID (op-XXXX)
_journal_op_id() {
    printf "op-%s" "$(head -c 4 /dev/urandom | od -An -tx1 | tr -d ' \n' | head -c 8)"
}

# ISO 8601 timestamp
_journal_ts() {
    date -u +"%Y-%m-%dT%H:%M:%SZ"
}

# Append a single JSONL line to the journal file
# Args: JSON string (pre-formatted)
_journal_append() {
    local line="$1"
    # Ensure directory exists
    mkdir -p "$(dirname "$_WV_JOURNAL_FILE")" 2>/dev/null || true
    printf '%s\n' "$line" >> "$_WV_JOURNAL_FILE"
}

# ═══════════════════════════════════════════════════════════════════════════
# Public API
# ═══════════════════════════════════════════════════════════════════════════

# journal_begin <op_type> <args_json>
# Begin a journaled operation. Sets _WV_CURRENT_OP_ID and _WV_IN_JOURNAL.
#
# Args:
#   op_type    - Operation name (ship, sync, delete)
#   args_json  - JSON string of operation arguments (e.g. '{"id":"wv-1234"}')
#
# Example:
#   journal_begin "ship" '{"id":"wv-1234","gh":true}'
#
journal_begin() {
    local op_type="$1"
    local args_json="${2:-"{}"}"

    _WV_CURRENT_OP_ID=$(_journal_op_id)
    _WV_CURRENT_OP_TYPE="$op_type"
    export _WV_IN_JOURNAL=1

    _journal_append "{\"event\":\"begin\",\"op\":\"$op_type\",\"op_id\":\"$_WV_CURRENT_OP_ID\",\"args\":$args_json,\"ts\":\"$(_journal_ts)\"}"
}

# journal_step <step_num> <action> [args_json]
# Record that a step is about to execute (status=pending).
#
# Args:
#   step_num  - Step number (1-based)
#   action    - Step action name (done, sync, git_commit, git_push, etc.)
#   args_json - Optional JSON string of step-specific arguments
#
# Example:
#   journal_step 1 "done" '{"id":"wv-1234"}'
#
journal_step() {
    local step_num="$1"
    local action="$2"
    local args_json="${3:-"{}"}"

    _journal_append "{\"event\":\"step\",\"op\":\"$_WV_CURRENT_OP_TYPE\",\"op_id\":\"$_WV_CURRENT_OP_ID\",\"step\":$step_num,\"action\":\"$action\",\"status\":\"pending\",\"args\":$args_json,\"ts\":\"$(_journal_ts)\"}"
}

# journal_complete <step_num>
# Record that a step completed successfully.
#
# Args:
#   step_num - Step number that completed
#
journal_complete() {
    local step_num="$1"

    _journal_append "{\"event\":\"step\",\"op\":\"$_WV_CURRENT_OP_TYPE\",\"op_id\":\"$_WV_CURRENT_OP_ID\",\"step\":$step_num,\"status\":\"done\",\"ts\":\"$(_journal_ts)\"}"
}

# journal_end
# Mark the current operation as fully complete. Unsets _WV_IN_JOURNAL.
#
journal_end() {
    _journal_append "{\"event\":\"end\",\"op\":\"$_WV_CURRENT_OP_TYPE\",\"op_id\":\"$_WV_CURRENT_OP_ID\",\"ts\":\"$(_journal_ts)\"}"

    unset _WV_IN_JOURNAL
    unset _WV_CURRENT_OP_ID
    unset _WV_CURRENT_OP_TYPE
}

# journal_recover [--json]
# Detect incomplete operations from the journal.
# Returns info about the last incomplete op (if any).
#
# Output (default): human-readable summary
# Output (--json):  JSON object with op details and recovery steps
#
# Exit codes:
#   0 - Incomplete operation found (recovery needed)
#   1 - No incomplete operations (clean state)
#
journal_recover() {
    local json_mode=false
    [ "${1:-}" = "--json" ] && json_mode=true

    # No journal file = nothing to recover
    if [ ! -f "$_WV_JOURNAL_FILE" ] || [ ! -s "$_WV_JOURNAL_FILE" ]; then
        if [ "$json_mode" = true ]; then
            echo '{"status":"clean","message":"No journal file"}'
        fi
        return 1
    fi

    # Parse journal to find incomplete operations using jq
    # An op is incomplete if it has a "begin" but no "end" event
    local recovery_info
    recovery_info=$(jq -s -c '
        group_by(.op_id) |
        map(select(length > 0)) |
        map(select(
            (map(select(.event == "begin")) | length > 0) and
            (map(select(.event == "end")) | length == 0)
        )) |
        if length == 0 then null
        else
          # Sort by earliest begin timestamp, pick oldest incomplete op
          sort_by(map(select(.event == "begin"))[0].ts) | first | {
            op_id: (map(select(.event == "begin"))[0].op_id),
            op: (map(select(.event == "begin"))[0].op),
            args: (map(select(.event == "begin"))[0].args),
            started_at: (map(select(.event == "begin"))[0].ts),
            completed_steps: ([.[] | select(.event == "step" and .status == "done") | .step] | sort | unique),
            pending_step: ([.[] | select(.event == "step" and .status == "pending")] | last | if . then {step: .step, action: .action} else null end)
        } end
    ' "$_WV_JOURNAL_FILE" 2>/dev/null)

    # No incomplete ops
    if [ -z "$recovery_info" ] || [ "$recovery_info" = "null" ]; then
        if [ "$json_mode" = true ]; then
            echo '{"status":"clean","message":"No incomplete operations"}'
        fi
        return 1
    fi

    # Compact the recovery info (jq may have pretty-printed it)
    recovery_info=$(echo "$recovery_info" | jq -c '.')

    if [ "$json_mode" = true ]; then
        echo "{\"status\":\"incomplete\",\"operation\":$recovery_info}"
        return 0
    fi

    # Human-readable output
    local op op_id started_at pending_action pending_step
    op=$(echo "$recovery_info" | jq -r '.op')
    op_id=$(echo "$recovery_info" | jq -r '.op_id')
    started_at=$(echo "$recovery_info" | jq -r '.started_at')
    pending_step=$(echo "$recovery_info" | jq -r '.pending_step.step // "unknown"')
    pending_action=$(echo "$recovery_info" | jq -r '.pending_step.action // "unknown"')

    echo -e "${YELLOW}⚠ Incomplete operation detected${NC}"
    echo "  Operation: wv $op ($op_id)"
    echo "  Started:   $started_at"
    echo "  Stuck at:  step $pending_step ($pending_action)"

    return 0
}

# journal_clean
# Remove completed operations from the journal, keeping only incomplete ones.
# Called after successful recovery or periodically to prevent journal growth.
#
journal_clean() {
    if [ ! -f "$_WV_JOURNAL_FILE" ] || [ ! -s "$_WV_JOURNAL_FILE" ]; then
        return 0
    fi

    # Keep only events belonging to incomplete operations
    local cleaned
    cleaned=$(jq -s -c '
        group_by(.op_id) |
        map(select(
            (map(select(.event == "begin")) | length > 0) and
            (map(select(.event == "end")) | length == 0)
        )) |
        flatten | .[]
    ' "$_WV_JOURNAL_FILE" 2>/dev/null)

    if [ -z "$cleaned" ]; then
        # All ops complete — truncate
        : > "$_WV_JOURNAL_FILE"
    else
        echo "$cleaned" > "$_WV_JOURNAL_FILE"
    fi
}

# journal_has_incomplete
# Quick check: are there incomplete operations?
# Exit codes: 0 = yes (incomplete found), 1 = no (clean)
#
journal_has_incomplete() {
    if [ ! -f "$_WV_JOURNAL_FILE" ] || [ ! -s "$_WV_JOURNAL_FILE" ]; then
        return 1
    fi

    # Fast check: if last line is an "end" event, likely clean
    # (handles the common case without full jq parse)
    local last_event
    last_event=$(tail -1 "$_WV_JOURNAL_FILE" | jq -r '.event' 2>/dev/null)
    if [ "$last_event" = "end" ]; then
        # Could still have earlier incomplete ops, but unlikely — do full check
        # only if begin count != end count
        local begins ends
        begins=$(grep -c '"event":"begin"' "$_WV_JOURNAL_FILE" 2>/dev/null) || begins=0
        ends=$(grep -c '"event":"end"' "$_WV_JOURNAL_FILE" 2>/dev/null) || ends=0
        [ "$begins" -gt "$ends" ] 2>/dev/null
        return $?
    fi

    # Last event isn't "end" — check if there's any begin without matching end
    local begins ends
    begins=$(grep -c '"event":"begin"' "$_WV_JOURNAL_FILE" 2>/dev/null) || begins=0
    ends=$(grep -c '"event":"end"' "$_WV_JOURNAL_FILE" 2>/dev/null) || ends=0
    [ "$begins" -gt "$ends" ] 2>/dev/null
}
