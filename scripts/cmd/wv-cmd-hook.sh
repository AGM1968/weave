#!/bin/bash
# wv-cmd-hook.sh -- host-neutral lifecycle hook facade.

# The PreToolUse and PostToolUse guards; side-effect free on source (wv-d3fbcb,
# wv-594381). Beside this module when it is loaded on its own, without wv's
# WV_LIB_DIR.
# shellcheck disable=SC1091
source "${WV_LIB_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/lib/wv-pre-tool-use.sh"
# shellcheck disable=SC1091
source "${WV_LIB_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/lib/wv-post-tool-use.sh"
# The Stop, SessionEnd and PreCompact implementations; side-effect free on
# source (wv-25903d).
# shellcheck disable=SC1091
source "${WV_LIB_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/lib/wv-lifecycle-end.sh"

_hook_decision_json() {
    local decision="$1" event="$2" reason="${3:-}" active_node="${4:-}"
    jq -n \
        --arg decision "$decision" \
        --arg event "$event" \
        --arg reason "$reason" \
        --arg active_node "$active_node" \
        '{decision:$decision,event:$event}
         + (if $reason == "" then {} else {reason:$reason} end)
         + (if $active_node == "" then {} else {active_node:$active_node} end)'
}

_hook_active_id() {
    "${WV:-${WV_CLI:-$SCRIPT_DIR/wv}}" list --status=active --json-v2 2>/dev/null | jq -r '.[0].id // empty' 2>/dev/null
}

_hook_input_paths() { _ptu_input_paths "$@"; }

# _hook_pre_tool_use <input> <format> — run the PreToolUse guards in
# scripts/lib/wv-pre-tool-use.sh, the implementation Claude Code's hooks call
# in-process, and report the first one that decides. Bash dedup runs last, so
# a call another guard refuses never takes its lock; PostToolUse dispatch
# releases the lock once the command has run (wv-594381).
#
# host: the deciding guard's own output and exit status, which Claude Code and
#   Codex both honour (exit 2 with the reason on stderr, or exit 0 with
#   permissionDecision=deny JSON). The --json exit 1 block is not one Codex
#   honours: it reads any exit but 0 and 2 as a failed hook (wv-5b774a).
# json: the decision JSON, with the guard's own message as the reason.
_hook_pre_tool_use() {
    local input="$1" format="$2" guard notes err out rc reason active_id
    local decided="" err_all="" faulted=false ctx ctx_all=""
    notes=$(mktemp -t wv-ptu-notes-XXXXXX)
    err=$(mktemp -t wv-ptu-err-XXXXXX)
    for guard in edit claim close dedup; do
        : > "$err"
        set +e
        out=$(_PTU_NOTES="$notes" WV_PTU_RECHECK_STAMP=1 "wv_ptu_${guard}_guard" "$input" 2>"$err")
        rc=$?
        set -e
        if [ "$rc" -eq 2 ] || printf '%s' "$out" \
            | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1; then
            decided="$guard"
            break
        fi
        [ "$rc" -eq 0 ] || faulted=true
        err_all="${err_all}$(cat "$err")"
        # A guard that does not decide may still advise, as the claim preflight
        # does for missing risks (wv-6e4798); dropping its output here lost the
        # advice for every host that reaches the guards through dispatch.
        if [ -n "$out" ]; then
            ctx=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null) || ctx=""
            [ -z "$ctx" ] || ctx_all="${ctx_all:+$ctx_all
}$ctx"
        fi
    done
    active_id=$(awk -F'\t' '$1 == "active_node" && $2 != "" { v = $2 } END { print v }' "$notes")
    rm -f "$notes"

    if [ "$format" = "host" ]; then
        if [ -n "$decided" ]; then
            cat "$err" >&2
            [ -z "$out" ] || printf '%s\n' "$out"
            rm -f "$err"
            return "$rc"
        fi
        rm -f "$err"
        [ -z "$err_all" ] || printf '%s\n' "$err_all" >&2
        [ -z "$ctx_all" ] || jq -n --arg ctx "$ctx_all" \
            '{hookSpecificOutput: {hookEventName: "PreToolUse", additionalContext: $ctx}}'
        return 0
    fi

    if [ -n "$decided" ]; then
        if [ "$rc" -eq 2 ]; then
            reason=$(sed -e 's/[[:space:]]*$//' "$err")
        else
            reason=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason // ""')
        fi
        rm -f "$err"
        _hook_decision_json block PreToolUse "$reason" "$active_id"
        return 1
    fi
    rm -f "$err"
    if [ "$faulted" = true ]; then
        # A guard that failed without deciding: the hook it replaced exited
        # nonzero, which neither host reads as a block.
        _hook_decision_json hook_error PreToolUse "$(printf '%s' "$err_all" | sed -e 's/[[:space:]]*$//')" "$active_id" \
            | jq -c --arg ctx "$ctx_all" 'if $ctx == "" then . else . + {context: $ctx} end'
        return 0
    fi
    if [ -n "$ctx_all" ]; then
        _hook_decision_json allow PreToolUse "" "$active_id" | jq -c --arg ctx "$ctx_all" '. + {context: $ctx}'
        return 0
    fi
    _hook_decision_json allow PreToolUse "" "$active_id"
}

cmd_hook_dispatch() {
    local event="" input active_id format="json" vscode=false
    while [ $# -gt 0 ]; do
        case "$1" in
            --event=*) event="${1#*=}" ;;
            --json) ;;
            # host: what Claude Code and Codex both read: hookSpecificOutput for
            # SessionStart and PostToolUse, the guard's own exit and output for
            # PreToolUse, {"decision":"block"} with exit 0 for Stop, the snapshot
            # as plain text for PreCompact, nothing for SessionEnd.
            # VS Code Local shares the tool decisions but requires a nested
            # Stop decision and JSON (not plain text) for PreCompact.
            --format=json|--format=host|--format=vscode) format="${1#*=}" ;;
            --help|-h)
                echo "Usage: wv hook dispatch --event=SessionStart|PreToolUse|PostToolUse|Stop|SessionEnd|PreCompact [--json] [--format=json|host|vscode]"
                return 0 ;;
            *) echo "Error: unknown hook dispatch option '$1'" >&2; return 1 ;;
        esac
        shift
    done
    case "$event" in SessionStart|PreToolUse|PostToolUse|Stop|SessionEnd|PreCompact) ;; *)
        echo "Error: --event must be SessionStart, PreToolUse, PostToolUse, Stop, SessionEnd, or PreCompact" >&2; return 1 ;;
    esac
    if [ "$format" = vscode ]; then
        vscode=true
        format=host
    fi

    # Infrastructure fault (no jq): fail open — this is a tooling problem, not a
    # policy decision, and _hook_decision_json itself needs jq.
    if ! command -v jq >/dev/null 2>&1; then
        printf '{"decision":"hook_error","event":"%s","reason":"jq unavailable; failing open (infrastructure fault)"}\n' "$(wv_json_escape "$event")"
        return 0
    fi

    input=$(cat)
    local raw_input_empty=false
    if [ -z "$input" ]; then
        # Documented affordance: empty stdin means a manual/test invocation, not a
        # host event — keep the safe no-op path (see PROPOSAL-codex-hooks-rust-dispatch).
        raw_input_empty=true
        input='{}'
    fi
    if [ "$event" = "PreToolUse" ]; then
        if [ "$raw_input_empty" = true ]; then
            [ "$format" = "host" ] || _hook_decision_json allow "$event"
            return 0
        fi
        # The guards judge the payload themselves, a malformed one included:
        # the edit guard fails it closed (wv-692c2d).
        local ptu_rc=0
        _hook_pre_tool_use "$input" "$format" || ptu_rc=$?
        return "$ptu_rc"
    fi
    if ! printf '%s' "$input" | jq -e 'type == "object"' >/dev/null 2>&1; then
        # Advisory and lifecycle events fail open on a malformed payload; the
        # mutation-gating event (PreToolUse) failed it closed above.
        _hook_decision_json hook_error "$event" "Invalid hook JSON; failing open"
        return 0
    fi

    case "$event" in
        SessionStart)
            # Resolved from WV_LIB_DIR in dev and installed layouts.
            # shellcheck disable=SC1091
            source "$WV_LIB_DIR/lib/wv-hook-common.sh"
            _hc_refresh
            local context=""
            if [ "$raw_input_empty" = true ]; then
                # Manual invocation: stamp the epoch PreToolUse's stale-node check
                # compares against and reset phase, nothing more -- no sentinel,
                # no load, no commit.
                date +%s > "${_HC_HOT_ZONE}/.session_epoch" 2>/dev/null || true
                wv_set_phase "discover" "${_HC_HOT_ZONE}" 2>/dev/null || true
            else
                # A host session start: the one implementation every host runs
                # (wv-a523de), including the epoch stamp and phase reset.
                # shellcheck disable=SC1091
                source "$WV_LIB_DIR/lib/wv-session-start.sh"
                context=$(wv_session_start_context "$input")
            fi
            active_id=$(_hook_active_id)
            if [ "$format" = "host" ]; then
                jq -n --arg ctx "$context" \
                    '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}}'
            elif [ -n "$context" ]; then
                _hook_decision_json allow "$event" "" "$active_id" | jq --arg ctx "$context" '. + {context: $ctx}'
            else
                _hook_decision_json allow "$event" "" "$active_id"
            fi
            ;;
        PostToolUse)
            local ptu_out ptu_ctx ptu_all="" ptu_guard
            # Attribution, the dedup lock release, the wv budget tally, the
            # linter and memory capture: the guards Claude Code's PostToolUse
            # hooks call in-process (wv-594381). A guard's failure is not the
            # tool call's, so each one fails open.
            for ptu_guard in touched dedup_release budget lint memory; do
                ptu_out=$("wv_potu_${ptu_guard}_guard" "$input" 2>/dev/null) || true
                ptu_ctx=$(printf '%s' "$ptu_out" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null) || ptu_ctx=""
                [ -z "$ptu_ctx" ] || ptu_all="${ptu_all:+$ptu_all
}$ptu_ctx"
            done
            active_id=$(_hook_active_id)
            if [ "$format" = "host" ]; then
                [ -z "$ptu_all" ] || _potu_context "$ptu_all"
            elif [ -n "$ptu_all" ]; then
                _hook_decision_json allow "$event" "" "$active_id" | jq --arg ctx "$ptu_all" '. + {context: $ctx}'
            else
                _hook_decision_json allow "$event" "" "$active_id"
            fi
            ;;
        Stop)
            # The guard Claude Code's stop-check.sh calls in-process (wv-25903d):
            # its block is {"decision":"block"} with exit 0, the shape Codex
            # honours, where --json's exit 1 reads as a failed hook (wv-5b774a).
            # Its soft warnings go to stderr on both formats.
            local stop_out stop_reason
            stop_out=$(wv_stop_guard "$input") || true
            if [ "$format" = "host" ]; then
                if [ -n "$stop_out" ]; then
                    if [ "$vscode" = true ]; then
                        printf '%s' "$stop_out" | jq '{hookSpecificOutput: ({hookEventName: "Stop"} + .)}'
                    else
                        printf '%s\n' "$stop_out"
                    fi
                fi
                return 0
            fi
            stop_reason=$(printf '%s' "$stop_out" | jq -r 'select(.decision == "block") | .reason // empty' 2>/dev/null) || stop_reason=""
            if [ -n "$stop_reason" ]; then
                _hook_decision_json block "$event" "$stop_reason" "$(_hook_active_id)"
                return 1
            fi
            _hook_decision_json allow "$event"
            ;;
        SessionEnd|PreCompact)
            # Empty stdin is a manual invocation (see above): no prune, sync,
            # commit or push for it.
            if [ "$raw_input_empty" = true ]; then
                [ "$format" = "host" ] || _hook_decision_json allow "$event"
                return 0
            fi
            # Each function loads wv-hook-common and the staging helpers itself.
            if [ "$event" = "SessionEnd" ]; then
                # Neither host lets SessionEnd block, so it only reports.
                wv_session_end_sync "$input" || true
                [ "$format" = "host" ] || _hook_decision_json allow "$event"
            else
                local snapshot
                snapshot=$(wv_pre_compact_context "$input") || true
                if [ "$vscode" = true ]; then
                    [ -z "$snapshot" ] || jq -n --arg message "$snapshot" '{systemMessage: $message}'
                elif [ "$format" = "host" ]; then
                    [ -z "$snapshot" ] || printf '%s\n' "$snapshot"
                else
                    _hook_decision_json allow "$event" | jq --arg ctx "$snapshot" '. + {context: $ctx}'
                fi
            fi
            ;;
    esac
}

# cmd_hook_normalize — pure normalization of a raw host event into the semantic
# event contract (E3, docs/RUST-E3-HARNESS-NORMALIZATION.md). Reads the raw host
# payload from stdin; emits weave.hook-normalize.v1 JSON. A function of
# (host, event, payload) only: no filesystem, graph, or hot-zone access — policy
# checks belong to dispatch, not normalization. Malformed required fields fail
# closed (exit 2) rather than downgrading a mutation to inspect.
_hook_normalize_fail() {
    local host="$1" event="$2" reason_code="$3" detail="$4"
    jq -n --arg host "$host" --arg event "$event" --arg rc "$reason_code" --arg detail "$detail" \
        '{schema:"weave.hook-normalize.v1",host:$host,raw_event_kind:$event,
          decision:"fail_closed",reason_code:$rc,detail:$detail}'
    return 2
}

_hook_normalize_emit() {
    local host="$1" event="$2" operation="$3" path_scope="$4" actor="$5" repo_identity="$6" worktree_identity="$7"
    local target destructive shared fail_posture capabilities
    case "$operation" in
        edit_file)         target=working_tree; destructive=true;  shared=false; fail_posture=fail_closed; capabilities='["working_tree_edit"]' ;;
        commit)            target=git;          destructive=true;  shared=true;  fail_posture=fail_closed; capabilities='["git_commit"]' ;;
        close_node)        target=graph;        destructive=true;  shared=true;  fail_posture=fail_closed; capabilities='["node_close"]' ;;
        update_node)       target=graph;        destructive=true;  shared=true;  fail_posture=fail_closed; capabilities='["graph_update"]' ;;
        session_lifecycle) target=graph;        destructive=false; shared=false; fail_posture=advisory;    capabilities='[]' ;;
        inspect|*)         target=unknown;      destructive=false; shared=false; fail_posture=advisory;    capabilities='[]' ;;
    esac
    jq -n \
        --arg host "$host" --arg event "$event" --arg operation "$operation" \
        --arg target "$target" --argjson destructive "$destructive" --argjson shared "$shared" \
        --arg path_scope "$path_scope" --arg actor "$actor" \
        --arg repo_identity "$repo_identity" --arg worktree_identity "$worktree_identity" \
        --arg fail_posture "$fail_posture" --argjson capabilities "$capabilities" \
        '{schema:"weave.hook-normalize.v1",host:$host,raw_event_kind:$event,
          normalized:{operation:$operation,target:$target,destructive:$destructive,shared:$shared,
                      path_scope:$path_scope,actor_provenance:$actor,
                      repository_identity:$repo_identity,worktree_identity:$worktree_identity,
                      fail_posture:$fail_posture,capabilities:$capabilities}}'
}

# _hook_classify_command — map a terminal command line to a semantic operation.
_hook_classify_command() {
    local cmd="$1" sub
    if [[ "$cmd" =~ git[[:space:]]+commit ]]; then echo commit; return; fi
    if [[ "$cmd" =~ wv-close ]]; then echo close_node; return; fi
    for sub in "${_WF_CLOSE_GATED[@]}"; do
        [[ "$cmd" =~ wv[[:space:]]+"$sub" ]] && { echo close_node; return; }
    done
    if [[ "$cmd" =~ wv[[:space:]]+(add|update|touch|link|work|quick|block|resolve|archive) ]]; then
        echo update_node; return
    fi
    echo inspect
}

cmd_hook_normalize() {
    local host="" event="" input
    while [ $# -gt 0 ]; do
        case "$1" in
            --host=*) host="${1#*=}" ;;
            --event=*) event="${1#*=}" ;;
            --json) ;;
            --help|-h)
                echo "Usage: wv hook normalize --host=claude|codex|mcp|cli --event=<raw event> [--json]"
                echo "Raw event vocabulary: claude/codex: SessionStart|PreToolUse|PostToolUse|Stop; cli: cli_invocation; mcp: mcp_tool_call"
                return 0 ;;
            *) echo "Error: unknown hook normalize option '$1'" >&2; return 1 ;;
        esac
        shift
    done
    case "$host" in
        claude|codex)
            case "$event" in SessionStart|PreToolUse|PostToolUse|Stop) ;; *)
                echo "Error: host $host does not declare raw event '${event:-}'" >&2; return 1 ;;
            esac ;;
        cli)
            [ "$event" = "cli_invocation" ] || { echo "Error: host cli declares only cli_invocation" >&2; return 1; } ;;
        mcp)
            [ "$event" = "mcp_tool_call" ] || { echo "Error: host mcp declares only mcp_tool_call" >&2; return 1; } ;;
        *) echo "Error: --host must be claude, codex, mcp, or cli" >&2; return 1 ;;
    esac

    local _WF_HOOK_EDIT_TOOLS=() _WF_CLOSE_GATED=()
    # shellcheck disable=SC1091
    source "$WV_LIB_DIR/lib/wv-workflow-classes.gen.sh" 2>/dev/null || true
    if [ "${#_WF_HOOK_EDIT_TOOLS[@]}" -eq 0 ]; then
        _WF_HOOK_EDIT_TOOLS=( Edit Write NotebookEdit mcp__ide__executeCode create_file replace_string_in_file insert_edit_into_file multi_replace_string_in_file edit_notebook_file )
        _WF_CLOSE_GATED=( "done" ship )
    fi
    if ! declare -F _wf_in_list >/dev/null; then
        _wf_in_list() {
            local needle="$1"; shift
            local value
            for value in "$@"; do [ "$value" = "$needle" ] && return 0; done
            return 1
        }
    fi

    input=$(cat)
    if ! printf '%s' "$input" | jq -e 'type == "object"' >/dev/null 2>&1; then
        _hook_normalize_fail "$host" "$event" invalid_required_field "payload must be a JSON object"
        return 2
    fi

    local session_field actor repo_identity worktree_identity
    case "$host" in
        claude) session_field=session_id ;;
        codex)  session_field=thread_id ;;
        *)      session_field="" ;;
    esac
    if [ -n "$session_field" ] && [ -n "$(printf '%s' "$input" | jq -r ".${session_field} // empty")" ]; then
        actor=harness_actor
    else
        case "$host" in cli) actor=process_actor ;; mcp) actor=tool_actor ;; *) actor=unknown ;; esac
    fi
    if [ -n "$(printf '%s' "$input" | jq -r '.repository_id // .cwd // empty')" ]; then
        repo_identity=known
    else
        repo_identity=unknown
    fi
    if [ -n "$(printf '%s' "$input" | jq -r '.worktree_id // .cwd // empty')" ]; then
        worktree_identity=known
    else
        worktree_identity=unknown
    fi

    case "$event" in
        SessionStart|Stop)
            _hook_normalize_emit "$host" "$event" session_lifecycle repository_wide "$actor" "$repo_identity" "$worktree_identity"
            return 0 ;;
        cli_invocation)
            local argv_ok subcommand operation
            argv_ok=$(printf '%s' "$input" | jq -r 'if (.argv | type) == "array" and (.argv | length) > 0 and all(.argv[]; type == "string" and length > 0) then "ok" elif has("argv") then "invalid" else "missing" end')
            case "$argv_ok" in
                missing) _hook_normalize_fail "$host" "$event" missing_required_field "argv is required"; return 2 ;;
                invalid) _hook_normalize_fail "$host" "$event" invalid_required_field "argv must be a non-empty array of non-empty strings"; return 2 ;;
            esac
            subcommand=$(printf '%s' "$input" | jq -r '.argv[1] // empty')
            operation=$(_hook_classify_command "wv ${subcommand}")
            _hook_normalize_emit "$host" "$event" "$operation" repository_wide process_actor "$repo_identity" "$worktree_identity"
            return 0 ;;
        mcp_tool_call)
            local mcp_tool operation
            mcp_tool=$(printf '%s' "$input" | jq -r 'if (.tool | type) == "string" and (.tool | length) > 0 then .tool else empty end')
            if [ -z "$mcp_tool" ]; then
                _hook_normalize_fail "$host" "$event" missing_required_field "tool is required"
                return 2
            fi
            case "$mcp_tool" in
                weave_done|weave_batch_done|weave_ship) operation=close_node ;;
                weave_add|weave_update|weave_touch|weave_link|weave_unlink|weave_block|weave_unarchive) operation=update_node ;;
                *) operation=inspect ;;
            esac
            _hook_normalize_emit "$host" "$event" "$operation" repository_wide tool_actor "$repo_identity" "$worktree_identity"
            return 0 ;;
    esac

    # PreToolUse / PostToolUse
    local tool tool_input_type tool_input operation path_scope
    tool=$(printf '%s' "$input" | jq -r 'if (.tool_name // .tool | type) == "string" and ((.tool_name // .tool) | length) > 0 then (.tool_name // .tool) else empty end')
    if [ -z "$tool" ]; then
        _hook_normalize_fail "$host" "$event" missing_required_field "tool_name is required"
        return 2
    fi
    tool_input_type=$(printf '%s' "$input" | jq -r '(.tool_input // .input) | type')
    if [ "$tool_input_type" != "object" ] && [ "$tool_input_type" != "null" ]; then
        _hook_normalize_fail "$host" "$event" invalid_required_field "tool_input must be an object"
        return 2
    fi
    tool_input=$(printf '%s' "$input" | jq -c '.tool_input // .input // {}')

    if _wf_in_list "$tool" "${_WF_HOOK_EDIT_TOOLS[@]}" || [ "$tool" = "apply_patch" ]; then
        operation=edit_file
        if [ -n "$(_hook_input_paths "$tool" "$tool_input" | head -1)" ]; then
            path_scope=known
        else
            path_scope=unknown
        fi
    elif [ "$tool" = "Bash" ] || [ "$tool" = "run_in_terminal" ]; then
        local cmd
        cmd=$(printf '%s' "$tool_input" | jq -r '.cmd // .command // empty')
        if [ -z "$cmd" ]; then
            _hook_normalize_fail "$host" "$event" invalid_required_field "terminal command is required"
            return 2
        fi
        operation=$(_hook_classify_command "$cmd")
        path_scope=repository_wide
    else
        operation=inspect
        path_scope=repository_wide
    fi
    _hook_normalize_emit "$host" "$event" "$operation" "$path_scope" "$actor" "$repo_identity" "$worktree_identity"
}

cmd_hook() {
    case "${1:-}" in
        dispatch) shift; cmd_hook_dispatch "$@" ;;
        normalize) shift; cmd_hook_normalize "$@" ;;
        --help|-h|"")
            echo "Usage: wv hook dispatch --event=SessionStart|PreToolUse|PostToolUse|Stop|SessionEnd|PreCompact [--json]"
            echo "       wv hook normalize --host=claude|codex|mcp|cli --event=<raw event> [--json]" ;;
        *) echo "Error: unknown hook command '${1:-}'" >&2; return 1 ;;
    esac
}
