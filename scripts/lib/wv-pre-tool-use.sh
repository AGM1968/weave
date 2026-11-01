#!/bin/bash
# wv-pre-tool-use.sh -- the PreToolUse guards, one implementation for every host
# (agnostic-cutover S4b, wv-d3fbcb).
#
# Four guards decide whether a tool call may run: the edit guard (graph-first
# before edits), the claim preflight, the close verification and the Bash
# duplicate/poller lock. Each Claude Code hook in .claude/hooks sources this
# file and calls one guard; `wv hook dispatch --event=PreToolUse` runs them in
# sequence for Codex. Claude's adapters run the guard in-process rather than
# spawning wv on every tool call (judge panel 2026-10-01, Q2 in_process).
#
# Each guard is a subshell function holding what its hook script held, so an
# `exit` decides exactly as it did there: exit 2 with the reason on stderr is a
# hard block, exit 0 with permissionDecision=deny JSON on stdout is a soft deny,
# exit 0 with no output allows. Claude Code and Codex both read those shapes.
# Variables and the cwd a guard changes stay inside it.
#
# Hook semantics, not wv's: every guard runs under `set -e` alone, as the hook
# scripts did, whatever the caller's shell options are.
#
# No side effects on source: wv-cmd-hook.sh loads it for every PreToolUse.

[ -n "${_WV_PRE_TOOL_USE_LOADED:-}" ] && return 0
_WV_PRE_TOOL_USE_LOADED=1
_PTU_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# _ptu_source <lib> -- load a library from beside this file, then from the
# installed locations. Readable is not loadable, and a copy that dies part way
# has already set its double-source guard: leaving it set makes every fallback
# return there, so the library never loads and the guard dies at its first
# _hc_* call with 127, which PreToolUse reads as ALLOW (wv-769c69).
_ptu_source() {
    local lib="$1" dir guard
    for dir in "$_PTU_LIB_DIR" "${HOME}/.config/weave/lib" "${HOME}/.local/lib/weave/lib"; do
        [ -r "$dir/$lib.sh" ] || continue
        # shellcheck source=/dev/null
        . "$dir/$lib.sh" 2>/dev/null && return 0
        while read -r guard; do unset "$guard"; done < <(compgen -v | grep -E '^_WV_[A-Z0-9_]*_LOADED$')
    done
    return 1
}

# _ptu_tag_hook -- tag the guard's own wv calls hook, keeping a test run's tag.
# Claude Code's settings export WV_CALL_SOURCE=agent and the in-process adapters
# inherit it. wv-hook-common sets the same tag when it loads, but the claim
# preflight never loaded it and the others load it with `|| true`, so each
# guard sets it itself at entry (wv-a093ea).
_ptu_tag_hook() {
    [ "${WV_CALL_SOURCE:-}" = "test" ] || export WV_CALL_SOURCE=hook
}

# _ptu_note <key> <value> -- tell a dispatch caller what a guard resolved (the
# active node it judged). A no-op unless the caller names a notes file.
_ptu_note() {
    [ -n "${_PTU_NOTES:-}" ] && printf '%s\t%s\n' "$1" "$2" >> "$_PTU_NOTES" 2>/dev/null
    return 0
}

# _ptu_terminal_payload <input> -- whether a payload is a terminal command, the
# only kind the claim and close guards judge. Codex's apply_patch also carries
# tool_input.command, holding patch text, and a patch to a note that mentions
# `wv done <id>` is not that close (wv-d3eb63). Claude Code registered those
# guards for Bash alone; a payload naming no tool is judged as before.
_ptu_terminal_payload() {
    case "$(printf '%s' "$1" | jq -r '.tool_name // empty' 2>/dev/null)" in
        ""|Bash|run_in_terminal) return 0 ;;
        *) return 1 ;;
    esac
}

# _ptu_input_paths <tool> <tool_input> -- every path a tool call names: the
# file_path/filePath/path field, plus each file header of an apply_patch patch
# (Codex), which has no path field at all. Codex sends the patch text as
# tool_input.command (codex-rs apply_patch handler, rust-v0.146.0, wv-d3eb63);
# patchText and patch are older shapes, still read.
_ptu_input_paths() {
    local tool="$1" tool_input="$2" path patch
    path=$(printf '%s' "$tool_input" | jq -r '.file_path // .filePath // .path // empty' 2>/dev/null)
    [ -z "$path" ] || printf '%s\n' "$path"

    [ "$tool" = "apply_patch" ] || return 0
    patch=$(printf '%s' "$tool_input" | jq -r '.command // .patchText // .patch // empty' 2>/dev/null)
    [ -n "$patch" ] || return 0
    printf '%s\n' "$patch" | sed -nE \
        's/^\*\*\* (Add File|Update File|Delete File|Move to): (.*)$/\2/p'
}

# ─── Edit guard (was pre-action.sh) ──────────────────────────────────────────
# Graph-first before edits: require a claimed, current, unblocked node with a
# Context Pack. Decisions live in the _hc_* helpers in wv-hook-common.sh; this
# wires them up and maps return codes onto exits.
#
# WV_PTU_RECHECK_STAMP=1 re-reads the Context Pack on a context-stamp hit
# instead of trusting the stamp. Dispatch sets it: on Codex it may be the only
# policy gate in a mixed-host session, so a stamp another host wrote is no
# authority to skip graph policy. Claude's adapter keeps the stamp, which saves
# a wv context call on every edit.
wv_ptu_edit_guard() (
    set -e; set +u; set +o pipefail
    _ptu_tag_hook
    INPUT="$1"
    TOOL=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)
    TOOL_INPUT=$(echo "$INPUT" | jq -r '.tool_input // empty' 2>/dev/null)

    # Order matters: wv-resolve-project sets the WV_PROJECT_DIR wv-resolve-runtime reads.
    _ptu_source wv-resolve-project || exit 0
    for _lib in wv-validate wv-config wv-hook-common; do _ptu_source "$_lib" || true; done
    _ptu_source wv-resolve-runtime || exit 0
    command -v _hc_refresh >/dev/null 2>&1 || { _ptu_root=$(git rev-parse --show-toplevel 2>/dev/null); _ptu_fix="wv self-update, then wv init-repo --update"; [ "$(git -C "$_ptu_root" ls-tree HEAD -- install.sh scripts/wv 2>/dev/null | wc -l)" -eq 2 ] && _ptu_fix="./install.sh"; echo "⚠ Weave guard inactive: wv-hook-common.sh could not be loaded — run $_ptu_fix (wv-376de3)" >&2; exit 0; }; _hc_refresh

    # Liveness heartbeat (wv-4efe06): the last tool call's time. Session start
    # compares it with stop-check's last stop record to tell a session that died
    # mid-turn from one that stopped and then ended without SessionEnd.
    [ -d "${_HC_HOT_ZONE:-}" ] && date +%s > "${_HC_HOT_ZONE}/.session_heartbeat" 2>/dev/null || true

    _hc_check_read_size "$TOOL" "$TOOL_INPUT" || exit 0
    # apply_patch is an edit whose paths are its patch headers: each one meets
    # the installed-copy guard, and the call classifies as an edit.
    CLASS_TOOL="$TOOL"
    if [ "$TOOL" = "apply_patch" ]; then
        CLASS_TOOL=Edit
        while IFS= read -r _path; do
            [ -n "$_path" ] || continue
            _hc_check_installed_path Edit "$(jq -cn --arg p "$_path" '{file_path:$p}')" || exit $?
        done < <(_ptu_input_paths "$TOOL" "$TOOL_INPUT")
    fi
    _hc_check_installed_path "$TOOL" "$TOOL_INPUT" || exit $?

    _hc_classify_tool "$CLASS_TOOL" "$TOOL_INPUT"
    _hc_check_payload "$INPUT" || exit $?
    [ "${_HC_BYPASS_CMD:-false}" = true ] && exit 0
    [ "${_HC_SHOULD_CHECK:-false}" = false ] && exit 0

    if [ -z "${WV_PROJECT_DIR:-}" ] || [ ! -d "${WV_PROJECT_DIR}/.weave" ] || [ ! -x "$WV" ]; then exit 0; fi

    _hc_db_preflight || exit 0
    _hc_init_hygiene_tally "$TOOL"

    PHASE_RC=0  # _hc_check_phase: 2 blocks the edit, other nonzero means stop-and-allow
    _hc_check_phase "${_HC_NEW_TOTAL:-}" "${_HC_WITH_ACTIVE:-}" "${_HC_TALLY_FILE:-}" || PHASE_RC=$?
    [ "$PHASE_RC" -eq 0 ] || { [ "$PHASE_RC" -eq 2 ] && exit 2; exit 0; }

    _hc_check_active_node "${_HC_NEW_TOTAL:-}" "${_HC_WITH_ACTIVE:-}" "${_HC_TALLY_FILE:-}" || exit $?
    _ptu_note active_node "$(echo "${_HC_ACTIVE_NODES:-[]}" | jq -r '.[0].id // empty' 2>/dev/null)"
    _hc_check_stale_node || exit $?
    _hc_resolve_primary_node || exit 0
    _ptu_note active_node "$_HC_NODE_ID"

    _hc_check_context_pack "$_HC_NODE_ID" || exit $?
    if [ "${_HC_CONTEXT_STAMP_HIT:-false}" = true ]; then
        [ "${WV_PTU_RECHECK_STAMP:-0}" = 1 ] || exit 0
        rm -f "${_HC_HOT_ZONE}/.context_checked_${_HC_NODE_ID}" 2>/dev/null || true
        _hc_check_context_pack "$_HC_NODE_ID" || exit $?
    fi
    _hc_check_contradictions "$_HC_NODE_ID" || exit $?
    _hc_check_blockers "$_HC_NODE_ID" || exit $?

    touch "${_HC_HOT_ZONE}/.context_checked_${_HC_NODE_ID}" 2>/dev/null || true
    exit 0
)

# The edit guard's adapter stops here. It is the slowest of the four Claude
# hooks, which run in parallel, so its time is the tool call's; bash parses a
# sourced file only as far as it executes, and the rest is about half the parse.
[ "${WV_PTU_EDIT_ONLY:-0}" = 1 ] && return 0

# ─── Claim preflight (was pre-claim-skills.sh) ───────────────────────────────
# Triggers on: wv work <id>, wv update <id> --status=active
wv_ptu_claim_guard() (
    set -e; set +u; set +o pipefail
    _ptu_tag_hook
    INPUT="$1"

    # Fast path: skip jq if stdin doesn't contain our trigger pattern
    case "$INPUT" in
        *"wv update"*"--status=active"*) ;;
        *"wv work"*) ;;
        *) exit 0 ;;
    esac

    _ptu_terminal_payload "$INPUT" || exit 0

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
        _ptu_source wv-resolve-project || exit 0
        _ptu_source wv-hook-observe || _hc_observe() { return 0; }
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
            # unmet one in a single answer, instead of serial discovery across retries.
            #   done_criteria missing   → required: deny (node is unplanned)
            #   alias missing           → required: deny (graph unreadable without short names)
            #   premortem/risks missing → advisory: never denies (wv-6e4798)
            # The advisory was listed among the "unmet gates" of the deny and told
            # the agent to satisfy all of them, and with no other gate unmet it
            # denied on its own on every retry: an advisory that blocked. It now
            # rides along with a deny under its own heading, or comes back as
            # context on a claim that proceeds.
            required="" advisory=""
            if [[ "$HAS_SHIP_IT" == "false" ]]; then
                required="${required}[1] done_criteria not set — run /ship-it, use --criteria= on wv add, or: wv update $NODE_ID --metadata='{\"done_criteria\":[...]}'. "
            fi
            if [[ -z "$NODE_ALIAS" ]]; then
                required="${required}[2] alias not set — graph is unreadable without short names: wv update $NODE_ID --alias=<short-name>. "
            fi
            if [[ "$HAS_PRE_MORTEM" == "false" ]]; then
                advisory="risks/premortem not set — consider /pre-mortem, or record them with --risks= on wv add or wv update $NODE_ID --metadata='{\"risks\":[...]}'."
            fi
            # Each unmet gate is its own rule's decision (wv-664b7f).
            [[ "$HAS_SHIP_IT" == "false" ]] && _hc_observe claim_requires_done_criteria deny
            [[ -z "$NODE_ALIAS" ]] && _hc_observe claim_requires_alias deny
            [[ -n "$advisory" ]] && _hc_observe claim_premortem_advisory advisory
            if [[ -n "$required" ]]; then
                reason="Claim preflight for $NODE_ID ($NODE_TEXT) — required before claiming: $required"
                reason="${reason}Satisfy these, then re-run the claim."
                [[ -n "$advisory" ]] && reason="$reason Advisory, does not block the claim: $advisory"
                [[ -n "$IMPACT_LINE" ]] && reason="$reason $IMPACT_LINE"
                jq -n --arg reason "$reason" \
                    '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":$reason}}'
                exit 0
            fi
            if [[ -n "$advisory" ]]; then
                # No decision, only context: the host's normal permission flow
                # decides the claim, and the advice reaches the agent beside it.
                context="Claim preflight advisory for $NODE_ID, not a requirement; the claim proceeds: $advisory"
                [[ -n "$IMPACT_LINE" ]] && context="$context $IMPACT_LINE"
                jq -n --arg context "$context" \
                    '{"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":$context}}'
                exit 0
            fi
        fi
    fi

    # No suggestion needed — allow silently
    exit 0
)

# ─── Close verification (was pre-close-verification.sh) ──────────────────────
# Require verification evidence before closing work. Triggers on: wv done <id>
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

wv_ptu_close_guard() (
    set -e; set +u; set +o pipefail
    _ptu_tag_hook
    INPUT="$1"

    # Fast path: skip jq if stdin doesn't contain our trigger pattern
    case "$INPUT" in
        *"wv done"*) ;;
        *"wv ship-agent"*) ;;
        *"wv ship"*) ;;
        *) exit 0 ;;
    esac

    _ptu_terminal_payload "$INPUT" || exit 0

    # Extract the command from Bash tool use.
    # Real PreToolUse payloads nest terminal commands under tool_input.{cmd,command},
    # while older tests used a top-level .command field.
    COMMAND=$(echo "$INPUT" | jq -r '.tool_input.cmd // .tool_input.command // .command // empty' 2>/dev/null)

    # Check if this is a wv done/ship/ship-agent command
    if [[ "$COMMAND" =~ wv[[:space:]](done|ship|ship-agent)[[:space:]]wv-[0-9a-f]{4,6} ]]; then
        # Extract the node ID
        NODE_ID=$(echo "$COMMAND" | grep -oP 'wv-[0-9a-f]{4,6}')

        # Anchor project resolution to the session cwd — prevents hot zone race when
        # the hook subshell's cwd doesn't match the project dir.
        _PAYLOAD_CWD=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || echo "")
        if [[ -n "$_PAYLOAD_CWD" ]] && [[ -d "$_PAYLOAD_CWD" ]]; then
            export CLAUDE_PROJECT_DIR="$_PAYLOAD_CWD"
            cd "$_PAYLOAD_CWD" 2>/dev/null || true
        fi
        _ptu_source wv-resolve-project || exit 0
        _ptu_source wv-validate || true
        # wv-822bea/wv-37e2e0: node_files (uncapped) is the authoritative
        # file-attribution table; metadata.touched_files is a capped (50-entry)
        # display copy of the same signal. Need _HC_DB to query node_files
        # directly below.
        _ptu_source wv-hook-common || true
        command -v _hc_refresh >/dev/null 2>&1 && _hc_refresh
        declare -F _hc_observe >/dev/null || _hc_observe() { return 0; }
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
            NODE_TYPE=$(echo "$NODE_META" | jq -r '.node_kind // .type // "unknown"' 2>/dev/null || echo "unknown")
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
                    _hc_observe finding_close_requires_violation_type deny
                    _VF_ERRORS=$(printf '%s' "$_VF_OUT" | jq -r '.errors | join(", ")' 2>/dev/null || echo "unknown")
                    _VF_ENUM="${FINDING_VIOLATION_TYPES:-}"
                    jq -n \
                        --arg detail "finding node requires violation_type before close. Missing or invalid: $_VF_ERRORS${_VF_ENUM:+. Enum: $_VF_ENUM}. Minimal: wv update $NODE_ID --metadata='{\"finding\":{\"violation_type\":\"repo:hygiene\"}}'" \
                        '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $detail}}'
                    exit 0
                fi
            fi

            # --skip-verification is checked BEFORE the attribution gate, not after
            # it (wv-e22386). The flag is the operator saying "this close does not
            # need the evidence path", and commit attribution is part of that path;
            # denying on attribution first made the flag unreachable for exactly the
            # closes it exists for, and the deny then advised an amend to satisfy a
            # requirement the caller had already waived.
            if [[ "$COMMAND" =~ --skip-verification ]]; then
                # The override is recorded, not silent (wv-664b7f); a trivial node
                # was never going to be asked for evidence, so there is nothing to bypass.
                [[ "$IS_TRIVIAL" == "false" ]] && _hc_observe close_requires_verification_evidence allow --skip-verification
                exit 0
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
                # wv-e48993: scope the block to files THIS node touched (Edit/Write/
                # NotebookEdit attribution captured live by wv-touched-files.sh into
                # metadata.touched_files), not every dirty file in the repo. Blocking
                # on unrelated dirt from an earlier, already-closed session forces
                # the wrong remedy -- committing foreign work under THIS node's
                # Weave-ID -- or leaving a finished node open. When touched_files is
                # empty/absent (no signal -- a non-Claude-Code session, or a node
                # older than this tracking), fall back to the prior strict behavior
                # and block on any dirt, since we can't tell foreign from own.
                #
                # wv-822bea/wv-37e2e0: metadata.touched_files is capped at 50 paths
                # (wv-touched-files.sh's WV_TOUCHED_NODE_CAP) -- a node whose 51st
                # touched file drops off the ring can fail this ownership check even
                # though that file is still genuinely its own, and the gate would
                # then treat a dirty 51st file as foreign. node_files is the same
                # attribution signal written UNCAPPED (INSERT OR IGNORE, no trim) --
                # union both so the cap only ever ADDS false-foreign risk, never
                # subtracts real ownership.
                TOUCHED_FILES=$(echo "$NODE_META" | jq -r '(.touched_files // [])[]' 2>/dev/null || true)
                NODE_FILES_DB=""
                _PCV_DB="${WV_DB:-${_HC_DB:-}}"
                if [ -n "$_PCV_DB" ] && command -v sql_escape >/dev/null 2>&1; then
                    NODE_FILES_DB=$(_agent_hook_run "node_files lookup" sqlite3 "$_PCV_DB" \
                        "SELECT path FROM node_files WHERE node_id='$(sql_escape "$NODE_ID")';" 2>/dev/null || true)
                fi
                # wv-cdafa1: inside an E5 capture window an edit's attribution
                # waits in a queue until wv done itself applies it, after this
                # guard has run. A queued path is already the node's own.
                NODE_FILES_QUEUED=""
                if [ -n "$_PCV_DB" ] && _ptu_source wv-attribution; then
                    NODE_FILES_QUEUED=$(wv_attribution_pending "$_PCV_DB" "$NODE_ID" || true)
                fi
                OWN_FILES=$(printf '%s\n%s\n%s\n' "$TOUCHED_FILES" "$NODE_FILES_DB" "$NODE_FILES_QUEUED" \
                    | sed '/^$/d' | sort -u)
                if [[ -n "$OWN_FILES" ]]; then
                    OWN_DIRTY=$(comm -12 <(printf '%s\n' "$DIRTY_FILES" | sort -u) <(printf '%s\n' "$OWN_FILES" | sort -u))
                else
                    OWN_DIRTY="$DIRTY_FILES"
                fi
                if [[ -n "$OWN_DIRTY" ]]; then
                    _hc_observe close_requires_committed_work deny
                    DIRTY_SAMPLE=$(echo "$OWN_DIRTY" | head -3 | paste -sd ', ' -)
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
                    _hc_observe close_requires_attributed_commit deny
                    jq -n \
                        --arg detail "No commit attributed to $NODE_ID. Make a commit while $NODE_ID is active so prepare-commit-msg adds the Weave-ID: $NODE_ID trailer, then retry wv done. If the work is already committed, add the trailer to a NEW commit (an empty one is fine: git commit --allow-empty) rather than amending — the earlier commit may already be pushed, and rewriting a pushed commit orphans the refs recorded against it. For a close that does not need the evidence path, use --skip-verification." \
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
                    # wv-734186: verification_method/verification_evidence were
                    # only ever askable at THIS close-time gate -- "what would
                    # count as done" was discovered as a fresh question once
                    # the work was already finished. wv add --verification-plan
                    # lets it be recorded upfront; surface it back here as a
                    # reminder if one was recorded, so answering the gate means
                    # confirming the plan rather than inventing one cold.
                    _VF_PLAN=$(echo "$NODE_META" | jq -r '.verification_plan // empty' 2>/dev/null)
                    _VF_PLAN_HINT=""
                    if [[ -n "$_VF_PLAN" ]]; then
                        _VF_PLAN_HINT=" Recorded plan: \"$_VF_PLAN\" — confirm it held and cite the evidence."
                    fi
                    # PreToolUse soft deny (exit 0 + hookSpecificOutput JSON)
                    # Schema: hookSpecificOutput.permissionDecision (current API, not deprecated top-level)
                    # "deny" is lowercase — "DENY" silently fails (original bug)
                    _hc_observe close_requires_verification_evidence deny
                    jq -n \
                        --arg node "$NODE_ID" \
                        --arg detail "Run: wv done $NODE_ID --verification-method=\"make check\" --verification-evidence=\"all tests pass\" ... — or wv update $NODE_ID --metadata='{\"verification_method\":\"...\"}' first — or --skip-verification for trivial tasks.${_VF_PLAN_HINT}" \
                        '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $detail}}'
                    exit 0
                fi
            fi
        fi
    fi

    # No issues found — allow the command to proceed
    exit 0
)

# ─── Bash duplicate and poller lock (was bash-dedup.sh) ──────────────────────
# Block duplicate long-running Bash commands.
#
# When make check / wv sync --gh / git push / etc. go to background, Claude Code
# can issue the same command again before the first finishes. This guard keeps
# a per-repo lock file to detect and deny duplicates.
#
# Lock lifecycle:
#   PreToolUse  (this guard) — creates lock atomically with phase=pending, denies if locked
#   PostToolUse (bash-dedup-post.sh) — promotes background to phase=running; clears foreground
#   SessionStart (session start) — clears all locks (cross-session stale cleanup)
#   Liveness check — pending locks expire after GRACE_PERIOD; running locks expire after TTL
#
# Dispatch runs this guard last for Codex, so a call another guard refuses never
# takes a lock, and its PostToolUse releases it (wv-594381). Codex runs every
# command in the foreground, so its locks never reach the running phase.
#
# Two-phase lock (fixes orphaned locks from hard-blocked tool calls):
#   pending — lock was created in PreToolUse but PostToolUse has not yet confirmed
#             that the tool actually ran. Expires after GRACE_PERIOD (120s).
#             Covers the window between a PreToolUse block (tool denied, PostToolUse
#             never fires) and the next attempt.
#   running — PostToolUse confirmed the tool started (background path only).
#             Expires after TTL. Foreground completions skip this state; PostToolUse
#             clears the lock directly.
#
# Why GRACE_PERIOD=120s: all foreground commands protected here complete in <90s
# (sync/push/install <60s; make check foreground ~90s). 120s gives 30s headroom.
# Background commands are promoted to "running" by PostToolUse within ~2s of
# launch, so GRACE_PERIOD is irrelevant for them.
#
# Concurrency safety: lock is acquired with set -o noclobber (atomic O_EXCL
# semantics). Two simultaneous PreToolUse calls cannot both succeed.
#
# Hook parallelism: Claude Code runs all matching PreToolUse hooks concurrently.
# If another hook hard-blocks the tool (exit 2), PostToolUse does not fire and
# the lock is orphaned. GRACE_PERIOD is the self-healing mechanism for this case.

# _first_live_bg_lock -- live background-lock scan (shared by the poller guard).
# Prints "<lock-key>|<original-cmd>" for the first running lock whose background
# task is still alive, else nothing. Liveness is the same signal the lock
# expiry uses: a running lock's task-output file still held by a process (fuser
# /lsof) means in-flight; once released the task has finished and the lock is
# treated as stale (skipped). With no task id (foreground) or no fuser/lsof,
# fall back to a generous age window so a fresh lock still reads as live.
_first_live_bg_lock() {
    local lf key phase epoch task_id cmd now age out claude_uid
    now=$(date +%s)
    claude_uid=$(id -u 2>/dev/null || echo "$UID")
    for lf in "$LOCK_DIR"/*.lock; do
        [[ -f "$lf" ]] || continue
        epoch=$(sed -n '1p' "$lf" 2>/dev/null || echo 0)
        phase=$(sed -n '2p' "$lf" 2>/dev/null || echo running)
        cmd=$(sed -n '3p'  "$lf" 2>/dev/null || echo "(unknown)")
        task_id=$(sed -n '4p' "$lf" 2>/dev/null || echo "")
        [[ "$phase" == "running" ]] || continue
        [[ "$epoch" =~ ^[0-9]+$ ]] || continue
        age=$(( now - epoch ))
        key="${lf##*/}"; key="${key%.lock}"
        if [[ "$task_id" =~ ^[a-z0-9]+$ ]]; then
            out=$(ls "/tmp/claude-${claude_uid}"/*/*/tasks/"${task_id}".output 2>/dev/null | head -1 || echo "")
            if [[ -n "$out" ]]; then
                if command -v fuser >/dev/null 2>&1; then
                    fuser "$out" >/dev/null 2>&1 || continue   # released → finished → stale
                elif command -v lsof >/dev/null 2>&1; then
                    lsof "$out" >/dev/null 2>&1 || continue
                elif [[ "$age" -ge 600 ]]; then
                    continue
                fi
                printf '%s|%s\n' "$key" "$cmd"
                return 0
            fi
        fi
        # No task id / output file gone: a recently-created running lock is
        # probably still live — use the age window.
        if [[ "$age" -lt 600 ]]; then
            printf '%s|%s\n' "$key" "$cmd"
            return 0
        fi
    done
    return 1
}

wv_ptu_dedup_guard() (
    set -e; set +u; set +o pipefail
    _ptu_tag_hook
    INPUT="$1"

    GRACE_PERIOD=120   # seconds before a pending lock is treated as stale
    SPAWN_WINDOW=10    # seconds a pending lock denies before its process can be seen

    TOOL=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)

    [[ "$TOOL" != "Bash" && "$TOOL" != "run_in_terminal" ]] && exit 0

    CMD=$(echo "$INPUT" | jq -r '.tool_input.command // .tool_input.cmd // empty' 2>/dev/null)
    [[ -z "$CMD" ]] && exit 0

    # ── Strip quoted argument regions before classifying ───────────────────────
    # A substring like `make check` inside `--learning="... make check passes ..."`
    # must NOT trigger the make-build lock — the user is writing prose into a
    # quoted argument, not invoking make. sed removes "..." and '...' regions so
    # the regexes only see the outer shell syntax. Escaped quotes are rare in the
    # commands we match; failing-closed (not matching) is safe.
    CMD_STRIPPED=$(printf '%s' "$CMD" | sed -E 's/"[^"]*"//g; s/'"'"'[^'"'"']*'"'"'//g')

    # ── Classify command and assign TTL (seconds) ──────────────────────────────
    # TTL applies to phase=running (background commands). Must reflect realistic
    # worst-case completion time for each command type. All anchors use structural
    # shell separators (^, ;, &, |, whitespace) — they are evaluated against
    # CMD_STRIPPED, so substrings inside quoted arguments cannot match.

    LOCK_KEY=""
    TTL=0

    # ── Busy-wait poller detection ─────────────────────────────────────────────
    # An `until …; do … sleep N; done` / `while …; do … sleep N; done` loop spawned
    # to watch a backgrounded task is the anti-pattern this guard closes: it is not a
    # classified expensive command, so without this check it sails past the lock and
    # busy-waits (the v1.59.1 zombie-watcher regression). Detected on CMD_STRIPPED so
    # the words "until"/"sleep" inside a quoted argument (prose) do not trigger it.
    # The deny decision is gated on an actually-live background lock below, so a
    # legitimate poll loop with nothing in flight is still allowed.
    IS_POLLER=false
    if [[ "$CMD_STRIPPED" =~ (^|[;&|[:space:]])(until|while)[[:space:]] ]] \
       && [[ "$CMD_STRIPPED" =~ (^|[;&|[:space:]])sleep[[:space:]] ]]; then
        IS_POLLER=true
    fi

    if [[ "$CMD_STRIPPED" =~ (^|[;[:space:]])(make[[:space:]]+(check|test|build)|make[[:space:]]*$) ]]; then
        LOCK_KEY="make-build"
        TTL=600      # 10 min — covers slow CI machines (local suite runs ~90s)
    elif [[ "$CMD_STRIPPED" =~ (^|[[:space:]]*[;&|]+[[:space:]]*)wv[[:space:]]+sync ]]; then
        LOCK_KEY="wv-sync"
        TTL=60       # sync completes in <15s under normal conditions
    elif [[ "$CMD_STRIPPED" =~ (^|[[:space:]]*[;&|]+[[:space:]]*)git[[:space:]]+commit ]]; then
        LOCK_KEY="git-commit"
        TTL=600      # pre-commit hook runs impact-selected test suites; p95 373s (test-core)
    elif [[ "$CMD_STRIPPED" =~ (^|[[:space:]]*[;&|]+[[:space:]]*)git[[:space:]]+push ]]; then
        LOCK_KEY="git-push"
        TTL=60       # push to remote; allow up to 60s for slow connections
    elif [[ "$CMD_STRIPPED" =~ (^|[[:space:]])\.\/install\.sh ]]; then
        LOCK_KEY="install"
        TTL=120      # first-run install can be slow; <2min in practice
    elif [[ "$CMD_STRIPPED" =~ (^|[;[:space:]])npm[[:space:]]+(run|test|build|install) ]]; then
        LOCK_KEY="npm-build"
        TTL=300      # npm install can be slow on cold cache
    elif [[ "$CMD_STRIPPED" =~ (^|[;[:space:]])poetry[[:space:]]+run[[:space:]]+pytest ]]; then
        LOCK_KEY="pytest"
        TTL=120      # test suite runs in <90s
    fi

    # A normal command with no lock key and not a poller: nothing to do.
    [[ -z "$LOCK_KEY" && "$IS_POLLER" != "true" ]] && exit 0

    # ── Portable repo hash (md5sum → md5 → sha256sum → fallback) ─────────────

    REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
    # Use echo (not printf) to match the newline convention used by all other hooks
    # and wv-config.sh — they all hash "$REPO_ROOT\n". Diverging here causes a
    # different hash and a different lock directory from the rest of the system.
    REPO_HASH=$(
        echo "$REPO_ROOT" | md5sum    2>/dev/null | cut -c1-8 ||
        echo "$REPO_ROOT" | md5       2>/dev/null | cut -c1-8 ||
        echo "$REPO_ROOT" | sha256sum 2>/dev/null | cut -c1-8 ||
        echo "default"
    )
    # Per-uid and created through the hot-zone base guard (wv-80be32).
    _ptu_source wv-resolve-runtime || exit 0
    LOCK_DIR=$(resolve_bash_lock_dir "$REPO_HASH")
    hot_zone_ensure "$LOCK_DIR" || exit 0

    # Name the rule when denying (wv-664b7f). Loaded only past the fast exits, so
    # the common allow path pays nothing for it.
    _ptu_source wv-hook-observe || _hc_observe() { return 0; }

    # ── Poller guard ────────────────────────────────────────────────────────────
    # Deny a busy-wait loop only while a tracked background task is actually live —
    # that is exactly the regression (background a commit/make, then spawn a watcher
    # loop instead of yielding for the completion notification). With nothing in
    # flight the loop is allowed, so legitimate `until cond; do sleep; done` waits
    # are unaffected.
    if [[ "$IS_POLLER" == "true" ]]; then
        _live=$(_first_live_bg_lock || true)
        if [[ -n "$_live" ]]; then
            _lkey="${_live%%|*}"
            _lcmd="${_live#*|}"
            _hc_observe no_busy_wait_polling deny
            jq -n --arg key "$_lkey" --arg prev "$_lcmd" \
                '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":("Busy-wait poller blocked: a background [\($key)] task is still running. Do not poll it with until/while+sleep — yield the turn and the harness will send a task-notification when it completes. Running: \($prev)")}}'
            exit 0
        fi
        # No live background task — allow the loop. (If it also matched a lock key,
        # the loop form is pathological for that command; we still allow without
        # taking the key lock, which is harmless.)
        exit 0
    fi

    LOCK_FILE="${LOCK_DIR}/${LOCK_KEY}.lock"
    # The lock keeps one line per field, so it stores the command's first line;
    # a multi-line command would otherwise spill into the task-id line.
    CMD_LINE1=${CMD%%$'\n'*}

    # ── Check for existing lock ────────────────────────────────────────────────
    # Lock file format (4 lines):
    #   line 1: epoch timestamp of lock creation
    #   line 2: phase — "pending" or "running"
    #   line 3: original command
    #   line 4: backgroundTaskId (set by bash-dedup-post.sh on promotion to running;
    #            empty string for foreground commands or when ID was unavailable)

    if [[ -f "$LOCK_FILE" ]]; then
        LOCK_EPOCH=$(sed -n '1p' "$LOCK_FILE" 2>/dev/null || echo "0")
        LOCK_PHASE=$(sed -n '2p' "$LOCK_FILE" 2>/dev/null || echo "running")
        PREV_CMD=$(sed -n '3p'  "$LOCK_FILE" 2>/dev/null || echo "(unknown)")
        TASK_ID=$(sed -n '4p'   "$LOCK_FILE" 2>/dev/null || echo "")
        NOW=$(date +%s)

        # Guard: treat non-integer epoch as stale
        if [[ "$LOCK_EPOCH" =~ ^[0-9]+$ ]]; then
            LOCK_AGE=$(( NOW - LOCK_EPOCH ))
        else
            LOCK_AGE=$GRACE_PERIOD  # force stale
        fi

        # Backward compat: old 2-line format has cmd on line 2 (not a phase keyword).
        # Treat any unrecognised phase as "running" (conservative: use TTL).
        if [[ "$LOCK_PHASE" != "pending" && "$LOCK_PHASE" != "running" ]]; then
            PREV_CMD="$LOCK_PHASE"  # line 2 was the cmd in old format; capture before overwrite
            LOCK_PHASE="running"
        fi

        # ── Liveness check for running locks ──────────────────────────────────
        # bash-dedup-post.sh stores the backgroundTaskId in lock line 4 on promotion.
        # Claude Code writes task output to: /tmp/claude-*/*/tasks/<taskId>.output
        # If no process has that file open (fuser/lsof), the background subprocess
        # has exited and the lock is stale — regardless of TTL.
        # Falls back to TTL if task ID unknown or fuser/lsof unavailable.
        if [[ "$LOCK_PHASE" == "running" && "$TASK_ID" =~ ^[a-z0-9]+$ ]]; then
            # Glob for the task output file — path is /tmp/claude-<uid>/<repo-slug>/<session>/tasks/<id>.output
            # Restrict to our own UID so cross-user TASK_ID collisions cannot
            # trick us into reading another user's output file (security L4).
            CLAUDE_UID=$(id -u 2>/dev/null || echo "$UID")
            OUTPUT_FILE=$(ls "/tmp/claude-${CLAUDE_UID}"/*/*/tasks/"${TASK_ID}".output 2>/dev/null | head -1 || echo "")
            if [[ -n "$OUTPUT_FILE" ]]; then
                if command -v fuser >/dev/null 2>&1; then
                    # fuser exits 1 when no process has the file open
                    fuser "$OUTPUT_FILE" >/dev/null 2>&1 || LOCK_AGE=$TTL
                elif command -v lsof >/dev/null 2>&1; then
                    lsof "$OUTPUT_FILE" >/dev/null 2>&1 || LOCK_AGE=$TTL
                fi
                # No fuser/lsof: fall through to TTL-based check
            fi
            # Output file not found: task may not have written yet (very recent launch)
            # or file was cleaned up. Fall through to TTL — safe, conservative.
        fi

        # ── Liveness check for pending locks (wv-d3af9a) ──────────────────────
        # A command another PreToolUse hook blocks (e.g. the wv done verification
        # gate) never starts, so PostToolUse never clears its pending lock, and that
        # lock denied the corrected retry and every wv sync --gh for the whole grace
        # period. A pending lock denies only while its command is really running:
        # the harness runs a tool command as `bash -c ... <command>`, so its first
        # line shows in the process table. Inside SPAWN_WINDOW an identical command
        # still denies unchecked, since two identical calls issued together arrive
        # before either process exists; a different command is checked at once, so
        # a retry corrected after a refusal is not denied for 10s (wv-5362e2).
        # ps is captured first so the search cannot match its own grep.
        _dd_reason="already running — wait for the task-notification before re-issuing"
        if [[ "$LOCK_PHASE" == "pending" ]] && { [[ "$LOCK_AGE" -ge "$SPAWN_WINDOW" ]] || [[ "$PREV_CMD" != "$CMD_LINE1" ]]; }; then
            _dd_needle=${PREV_CMD%%$'\n'*}
            _dd_needle=${_dd_needle:0:80}
            _dd_procs=$(ps -eo args= 2>/dev/null || true)
            if [[ -n "$_dd_procs" && -n "$_dd_needle" ]] && ! grep -qF -- "$_dd_needle" <<< "$_dd_procs"; then
                LOCK_AGE=$GRACE_PERIOD   # never started: stale
            fi
        elif [[ "$LOCK_PHASE" == "pending" ]]; then
            # Unchecked, so the deny must not claim the earlier call is running.
            # Constant text: the age is in the bracket, so the reason has no clock.
            _dd_reason="the identical call has not been seen running yet; if another hook refused it, it never ran, so re-issue it once the lock is ${SPAWN_WINDOW}s old"
        fi

        if [[ "$LOCK_PHASE" == "pending" ]]; then
            THRESHOLD=$GRACE_PERIOD
            PHASE_LABEL="pending, blocked or slow-start"
        else
            THRESHOLD=$TTL
            PHASE_LABEL="running"
        fi

        if [[ "$LOCK_AGE" -lt "$THRESHOLD" ]]; then
            _hc_observe no_duplicate_inflight_command deny
            jq -n --arg key "$LOCK_KEY" --arg prev "$PREV_CMD" \
                   --argjson age "$LOCK_AGE" --arg phase "$PHASE_LABEL" --arg reason "$_dd_reason" \
                '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":("Duplicate command blocked [\($key), \($age)s old, \($phase)]: \($reason). Previous: \($prev)")}}'
            exit 0
        fi
        # Lock expired or stale pending — clear before atomic acquisition
        rm -f "$LOCK_FILE"
    fi

    # ── Atomic lock acquisition (O_EXCL via noclobber — no TOCTOU) ────────────────
    # set -o noclobber makes '>' fail if the file already exists. Two concurrent
    # invocations racing here will have exactly one succeed and one fall through to
    # the "already locked" denial path.

    LOCK_CONTENT="$(date +%s)
pending
${CMD_LINE1}"

    if (set -o noclobber; printf '%s\n' "$LOCK_CONTENT" > "$LOCK_FILE") 2>/dev/null; then
        exit 0  # Lock acquired — allow command
    fi

    # Race: another invocation just acquired the lock between our check and write
    PREV_CMD=$(sed -n '3p' "$LOCK_FILE" 2>/dev/null || echo "(unknown)")
    _hc_observe no_duplicate_inflight_command deny
    jq -n --arg key "$LOCK_KEY" --arg prev "$PREV_CMD" \
        '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":("Duplicate command blocked [\($key)]: just acquired by concurrent call — wait for the task-notification. Previous: \($prev)")}}'
    exit 0
)
