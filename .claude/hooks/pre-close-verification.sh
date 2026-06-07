#!/bin/bash
# PreToolUse hook: Require verification evidence before closing work
# Triggers on: wv done <id>

set -e

_agent_hook_mode() {
    [ "${WV_AGENT_MODE:-0}" = "1" ]
}

_agent_hook_progress() {
    _agent_hook_mode || return 0
    echo "[wv-agent-mode] pre-close: $1" >&2
}

_agent_hook_timeout_deny() {
    local stage="$1"
    local timeout_s="${WV_AGENT_HOOK_TIMEOUT:-15s}"
    jq -n \
        --arg detail "pre-close verification timed out during $stage after $timeout_s. Retry the close command, or run wv doctor --agent to inspect the agent environment." \
        '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $detail}}'
    exit 0
}

_agent_hook_run() {
    local stage="$1"
    shift

    _agent_hook_progress "$stage"
    if _agent_hook_mode && [ "${WV_AGENT_TEST_TIMEOUT_STAGE:-}" = "$stage" ]; then
        return 124
    fi
    if command -v timeout >/dev/null 2>&1; then
        timeout --foreground "${WV_AGENT_HOOK_TIMEOUT:-15s}" "$@"
    else
        "$@"
    fi
}

# Read stdin (JSON payload from Claude Code)
INPUT=$(cat)

# Fast path: skip jq if stdin doesn't contain our trigger pattern
case "$INPUT" in
    *"wv done"*) ;;
    *"wv ship-agent"*) ;;
    *"wv ship"*) ;;
    *) exit 0 ;;
esac

# Extract the command from Bash tool use.
# Real PreToolUse payloads nest terminal commands under tool_input.{cmd,command},
# while older tests used a top-level .command field.
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.cmd // .tool_input.command // .command // empty' 2>/dev/null)

# Check if this is a wv done/ship/ship-agent command
if [[ "$COMMAND" =~ wv[[:space:]](done|ship|ship-agent)[[:space:]]wv-[0-9a-f]{4,6} ]]; then
    # Extract the node ID
    NODE_ID=$(echo "$COMMAND" | grep -oP 'wv-[0-9a-f]{4,6}')

    # Get node details
    HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
    # Anchor project resolution to the session cwd — prevents hot zone race when
    # the hook subshell's cwd doesn't match the project dir.
    _PAYLOAD_CWD=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || echo "")
    if [[ -n "$_PAYLOAD_CWD" ]] && [[ -d "$_PAYLOAD_CWD" ]]; then
        export CLAUDE_PROJECT_DIR="$_PAYLOAD_CWD"
        cd "$_PAYLOAD_CWD" 2>/dev/null || true
    fi
    source "$HOOK_DIR/../lib/wv-resolve-project.sh" 2>/dev/null \
        || source "$HOOK_DIR/../../scripts/lib/wv-resolve-project.sh" 2>/dev/null \
        || source "${HOME}/.config/weave/lib/wv-resolve-project.sh" 2>/dev/null \
        || exit 0
    source "$HOOK_DIR/../lib/wv-validate.sh" 2>/dev/null \
        || source "$HOOK_DIR/../../scripts/lib/wv-validate.sh" 2>/dev/null \
        || source "${HOME}/.config/weave/lib/wv-validate.sh" 2>/dev/null \
        || true
    if [ -x "$WV" ]; then
        _agent_hook_progress "load node metadata"
        NODE_JSON=$(_agent_hook_run "node-json" "$WV" show "$NODE_ID" --json 2>/dev/null) || {
            rc=$?
            if [ "$rc" -eq 124 ]; then
                _agent_hook_timeout_deny "node metadata lookup"
            fi
            exit 0
        }
        NODE_TEXT=$(echo "$NODE_JSON" | jq -r '.text // empty' 2>/dev/null || echo "")
        NODE_META=$(echo "$NODE_JSON" | jq -r '.metadata // "{}"' 2>/dev/null || echo "{}")
        NODE_TYPE=$(echo "$NODE_META" | jq -r '.type // "unknown"' 2>/dev/null || echo "unknown")
        # Node not in local DB (e.g. command targets a remote machine via SSH) — allow passthrough.
        NODE_EXISTS=$(echo "$NODE_JSON" | jq -r '.id // empty' 2>/dev/null || echo "")
        if [[ -z "$NODE_EXISTS" ]]; then
            exit 0
        fi
        IS_TRIVIAL=false
        if [[ "$NODE_TYPE" == "trails" ]] || [[ "$NODE_TYPE" == "breadcrumbs" ]] || [[ "$NODE_TEXT" =~ ^Test ]]; then
            IS_TRIVIAL=true
        fi

        if [[ "$NODE_TYPE" == "finding" ]]; then
            # Prefer explicit WV_CLI when provided, otherwise use the resolved project-local WV.
            _VF_BIN="${WV_CLI:-$WV}"
            if [[ -z "$_VF_BIN" ]]; then
                _VF_BIN="wv"
            fi
            _VF_OUT=$("$_VF_BIN" validate-finding "$NODE_ID" 2>/dev/null || true)
            # Keep explicit false values; jq's `//` treats false as empty.
            _VF_VALID=$(printf '%s' "$_VF_OUT" | jq -r 'if has("valid") then (.valid | tostring) else "true" end' 2>/dev/null || echo "true")
            if [[ "$_VF_VALID" != "true" ]]; then
                _VF_ERRORS=$(printf '%s' "$_VF_OUT" | jq -r '.errors | join(", ")' 2>/dev/null || echo "unknown")
                _VF_ENUM="${FINDING_VIOLATION_TYPES:-}"
                jq -n \
                    --arg detail "finding node requires violation_type before close. Missing or invalid: $_VF_ERRORS${_VF_ENUM:+. Enum: $_VF_ENUM}. Minimal: wv update $NODE_ID --metadata='{\"finding\":{\"violation_type\":\"repo:hygiene\"}}'" \
                    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $detail}}'
                exit 0
            fi
        fi

        HAS_COMMIT_METADATA=$(echo "$NODE_META" | jq -r '((.commit // "") != "" or ((.commits // []) | length > 0))' 2>/dev/null || echo "false")
        if [[ "$HAS_COMMIT_METADATA" != "true" && "$IS_TRIVIAL" == "false" ]] \
            && git -C "$WV_PROJECT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
            _agent_hook_progress "check commit hygiene"
            # Refresh index to clear stat-only mtime changes (hooks touch themselves on invocation)
            git -C "$WV_PROJECT_DIR" update-index --refresh >/dev/null 2>&1 || true
            DIRTY_FILES=$(
                {
                    _agent_hook_run "git diff" git -C "$WV_PROJECT_DIR" diff --name-only 2>/dev/null || {
                        rc=$?
                        [ "$rc" -eq 124 ] && _agent_hook_timeout_deny "git diff"
                    }
                    _agent_hook_run "git diff --cached" git -C "$WV_PROJECT_DIR" diff --cached --name-only 2>/dev/null || {
                        rc=$?
                        [ "$rc" -eq 124 ] && _agent_hook_timeout_deny "git diff --cached"
                    }
                    _agent_hook_run "git ls-files" git -C "$WV_PROJECT_DIR" ls-files --others --exclude-standard 2>/dev/null || {
                        rc=$?
                        [ "$rc" -eq 124 ] && _agent_hook_timeout_deny "git ls-files"
                    }
                } | sort -u | grep -v '^$' \
                  | grep -v '^\.weave/' \
                  | grep -v '^\.claude/hooks/' \
                  | grep -v '^\.claude/skills/' \
                  | grep -v '^\.claude/agents/' || true
            )
            if [[ -n "$DIRTY_FILES" ]]; then
                DIRTY_SAMPLE=$(echo "$DIRTY_FILES" | head -3 | paste -sd ', ' -)
                jq -n \
                    --arg detail "Commit work before close. Non-.weave changes are still uncommitted: $DIRTY_SAMPLE. Run git add <files> && git commit while $NODE_ID is active, then retry wv done." \
                    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $detail}}'
                exit 0
            fi

            ATTRIBUTED_COMMITS=$(_agent_hook_run "git log Weave-ID" git -C "$WV_PROJECT_DIR" log --format="%H" --grep="Weave-ID: $NODE_ID" --since="90 days ago" 2>/dev/null | head -10) || {
                rc=$?
                [ "$rc" -eq 124 ] && _agent_hook_timeout_deny "git log Weave-ID"
            }
            if [[ -z "$ATTRIBUTED_COMMITS" ]]; then
                ATTRIBUTED_COMMITS=$(_agent_hook_run "git log node-id" git -C "$WV_PROJECT_DIR" log --format="%H" --grep="$NODE_ID" --since="90 days ago" 2>/dev/null | head -10) || {
                    rc=$?
                    [ "$rc" -eq 124 ] && _agent_hook_timeout_deny "git log node-id"
                }
            fi
            if [[ -z "$ATTRIBUTED_COMMITS" ]]; then
                jq -n \
                    --arg detail "No commit attributed to $NODE_ID. Commit before close so prepare-commit-msg can add Weave-ID: $NODE_ID, or amend the latest work commit, then retry wv done." \
                    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $detail}}'
                exit 0
            fi
        fi

        # Check for --skip-verification flag
        _agent_hook_progress "check verification inputs"
        if [[ "$COMMAND" =~ --skip-verification ]]; then
            exit 0
        fi

        # Inline verification flags satisfy the requirement without a prior wv update
        if [[ "$COMMAND" =~ --verification-method= ]] || [[ "$COMMAND" =~ --verification-evidence= ]] || [[ "$COMMAND" =~ --verification-evidence-file= ]]; then
            exit 0
        fi

        # Check if verification metadata already exists
        HAS_VERIFICATION=$(echo "$NODE_META" | jq -r 'has("verification")' 2>/dev/null || echo "false")

        # Also check old schema for backward compatibility
        HAS_LEGACY_VERIFICATION=$(echo "$NODE_META" | jq -r '(has("verification_method") or has("verification_evidence"))' 2>/dev/null || echo "false")

        # Require verification for non-trivial work
        if [[ "$HAS_VERIFICATION" == "false" && "$HAS_LEGACY_VERIFICATION" == "false" ]]; then
            if [[ "$IS_TRIVIAL" == "false" ]]; then
                # PreToolUse soft deny (exit 0 + hookSpecificOutput JSON)
                # Schema: hookSpecificOutput.permissionDecision (current API, not deprecated top-level)
                # "deny" is lowercase — "DENY" silently fails (original bug)
                jq -n \
                    --arg node "$NODE_ID" \
                    --arg detail "Run: wv done $NODE_ID --verification-method=\"make check\" --verification-evidence=\"all tests pass\" ... — or wv update $NODE_ID --metadata='{\"verification_method\":\"...\"}' first — or --skip-verification for trivial tasks." \
                    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $detail}}'
                exit 0
            fi
        fi
    fi
fi

# No issues found — allow the command to proceed
exit 0
