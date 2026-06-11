#!/bin/bash
# PreToolUse hook: Suggest /ship-it and /pre-mortem when claiming work
# Triggers on: wv update <id> --status=active

set -e

# Read stdin (JSON payload from Claude Code)
INPUT=$(cat)

# Fast path: skip jq if stdin doesn't contain our trigger pattern
case "$INPUT" in
    *"wv update"*"--status=active"*) ;;
    *"wv work"*) ;;
    *) exit 0 ;;
esac

# Extract the command from Bash tool use.
# Real PreToolUse payloads nest terminal commands under tool_input.{cmd,command},
# while older tests used a top-level .command field.
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.cmd // .tool_input.command // .command // empty' 2>/dev/null)

# Check if this is a claim command in either the old or current workflow.
if [[ "$COMMAND" =~ wv[[:space:]]update[[:space:]]wv-[0-9a-f]{4,6}.*--status=active ]] || \
   [[ "$COMMAND" =~ wv[[:space:]]work[[:space:]]wv-[0-9a-f]{4,6} ]]; then
    # Extract the node ID
    NODE_ID=$(echo "$COMMAND" | grep -oP 'wv-[0-9a-f]{4,6}')

    # Get node details
    HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
    source "$HOOK_DIR/../lib/wv-resolve-project.sh" 2>/dev/null \
        || source "$HOOK_DIR/../../scripts/lib/wv-resolve-project.sh" 2>/dev/null \
        || source "${HOME}/.config/weave/lib/wv-resolve-project.sh" 2>/dev/null \
        || exit 0
    if [ -x "$WV" ]; then
        # wv show --json returns a compact object (not array) for single-ID queries.
        # Fail-open when node is missing or DB is unreadable — let wv work surface errors.
        NODE_JSON=$("$WV" show "$NODE_ID" --json 2>/dev/null || true)
        if [[ -z "$NODE_JSON" ]] || [[ "$NODE_JSON" = "[]" ]]; then
            exit 0
        fi

        NODE_TEXT=$(echo "$NODE_JSON" | jq -r '.text // ""' 2>/dev/null || echo "")
        HAS_SHIP_IT=$(echo "$NODE_JSON" | jq -r '.metadata | fromjson | has("done_criteria")' 2>/dev/null || echo "false")
        # Pre-mortem analysis lands under "premortem" (the /pre-mortem skill writes it)
        # or "risks" (legacy/--risks= label). Accept either so a node that already has a
        # real premortem is not nagged for a missing static risk label (finding wv-cd5ddb).
        HAS_PRE_MORTEM=$(echo "$NODE_JSON" | jq -r '.metadata | fromjson | (has("risks") or has("premortem"))' 2>/dev/null || echo "false")
        NODE_ALIAS=$(echo "$NODE_JSON" | jq -r '.alias // ""' 2>/dev/null || echo "")

        # Impact-grounded blast radius (advisory only). Replaces the static risk-string
        # heuristic with real graph coupling from `wv impact` (PROPOSAL §10, finding
        # wv-cd5ddb). Fail-open to an empty string so the claim is never errored or blocked.
        IMPACT_LINE=""
        IMPACT_JSON=$("$WV" impact --json "$NODE_ID" 2>/dev/null || true)
        if [[ -n "$IMPACT_JSON" ]] && echo "$IMPACT_JSON" | jq -e . >/dev/null 2>&1; then
            IMPACT_LINE=$(echo "$IMPACT_JSON" | jq -r '
                (.impacted | length) as $n
                | ([.impacted[].risk_score] | max // 0) as $maxr
                | ([.impacted[] | select(.risk_score >= 0.5) | .node_id] | join(", ")) as $hi
                | ((.affected_suites // []) | join(", ")) as $suites
                | "Blast radius (wv impact): \($n) impacted, max risk_score \($maxr)"
                  + (if $hi != "" then "; high-risk: \($hi)" else "" end)
                  + (if $suites != "" then "; suites: \($suites)" else "" end)
                  + "."' 2>/dev/null || echo "")
        fi

        # Combined preflight (wv-7c28f4): evaluate ALL gates and report every
        # unmet one in a single deny, instead of serial discovery across retries.
        # Gate set and decisions are unchanged:
        #   done_criteria missing → deny (node is unplanned)
        #   alias missing         → deny (graph unreadable without short names)
        #   premortem/risks missing → advisory (deny once, proceed allowed)
        gates=""
        if [[ "$HAS_SHIP_IT" == "false" ]]; then
            gates="${gates}[1] done_criteria not set — run /ship-it, use --criteria= on wv add, or: wv update $NODE_ID --metadata='{\"done_criteria\":[...]}'. "
        fi
        if [[ -z "$NODE_ALIAS" ]]; then
            gates="${gates}[2] alias not set — graph is unreadable without short names: wv update $NODE_ID --alias=<short-name>. "
        fi
        if [[ "$HAS_PRE_MORTEM" == "false" ]]; then
            gates="${gates}[3] risks/premortem not set (advisory) — consider /pre-mortem, or --risks= on wv add; proceed if already assessed. "
        fi
        if [[ -n "$gates" ]]; then
            reason="Claim preflight for $NODE_ID ($NODE_TEXT) — unmet gates: $gates"
            reason="${reason}Satisfy all in one pass, then re-run the claim."
            [[ -n "$IMPACT_LINE" ]] && reason="$reason $IMPACT_LINE"
            jq -n --arg reason "$reason" \
                '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":$reason}}'
            exit 0
        fi
    fi
fi

# No suggestion needed — allow silently
exit 0
