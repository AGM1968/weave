#!/bin/bash
# wv-cmd-hook.sh -- host-neutral lifecycle hook facade.

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

_hook_input_paths() {
    local tool="$1" tool_input="$2" path patch
    path=$(printf '%s' "$tool_input" | jq -r '.file_path // .filePath // .path // empty' 2>/dev/null)
    [ -z "$path" ] || printf '%s\n' "$path"

    [ "$tool" = "apply_patch" ] || return 0
    patch=$(printf '%s' "$tool_input" | jq -r '.patchText // .patch // empty' 2>/dev/null)
    [ -n "$patch" ] || return 0
    printf '%s\n' "$patch" | sed -nE \
        's/^\*\*\* (Add File|Update File|Delete File|Move to): (.*)$/\2/p'
}

_hook_repo_relative_path() {
    local path="$1" root
    root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
    case "$path" in
        "$root"/*) printf '%s\n' "${path#"$root"/}" ;;
        *) printf '%s\n' "$path" ;;
    esac
}

# _hook_installed_path_hit — mirror _hc_check_installed_path (check #1 in the
# dispatch_hook order from docs/PROPOSAL-wv-pattern-crystallization.md), but
# scan every path _hook_input_paths can extract, including apply_patch patch
# headers which have no file_path/filePath field for _hc_check_installed_path
# to read. Requires _WF_HOOK_EDIT_TOOLS/_wf_in_list from wv-hook-common.sh.
# Prints the offending path and returns 0 on a hit; returns 1 when clean.
_hook_installed_path_hit() {
    local tool="$1" tool_input="$2" path
    _wf_in_list "$tool" "${_WF_HOOK_EDIT_TOOLS[@]}" || [ "$tool" = "apply_patch" ] || return 1
    while IFS= read -r path; do
        [ -n "$path" ] || continue
        case "$path" in
            *.local/bin/*|*.local/lib/weave/*) printf '%s\n' "$path"; return 0 ;;
        esac
    done < <(_hook_input_paths "$tool" "$tool_input")
    return 1
}

cmd_hook_dispatch() {
    local event="" input tool tool_input tool_succeeded active_id path paths_csv=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --event=*) event="${1#*=}" ;;
            --json) ;;
            --help|-h)
                echo "Usage: wv hook dispatch --event=SessionStart|PreToolUse|PostToolUse|Stop [--json]"
                return 0 ;;
            *) echo "Error: unknown hook dispatch option '$1'" >&2; return 1 ;;
        esac
        shift
    done
    case "$event" in SessionStart|PreToolUse|PostToolUse|Stop) ;; *)
        echo "Error: --event must be SessionStart, PreToolUse, PostToolUse, or Stop" >&2; return 1 ;;
    esac

    # Infrastructure fault (no jq): fail open — this is a tooling problem, not a
    # policy decision, and _hook_decision_json itself needs jq.
    if ! command -v jq >/dev/null 2>&1; then
        printf '{"decision":"hook_error","event":"%s","reason":"jq unavailable; failing open (infrastructure fault)"}\n' "$event"
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
    if ! printf '%s' "$input" | jq -e 'type == "object"' >/dev/null 2>&1; then
        # Payload malformation: for the mutation-gating event we cannot prove the
        # event is not a mutation, so fail closed (wv-692c2d). Advisory/lifecycle
        # events keep the fail-open posture.
        if [ "$event" = "PreToolUse" ]; then
            _hook_decision_json block "$event" "Malformed hook payload (invalid_required_field: payload must be a JSON object); failing closed for mutation gating"
            return 1
        fi
        _hook_decision_json hook_error "$event" "Invalid hook JSON; failing open"
        return 0
    fi
    tool=$(printf '%s' "$input" | jq -r '.tool_name // .tool // empty' 2>/dev/null)
    tool_input=$(printf '%s' "$input" | jq -c '.tool_input // .input // {}' 2>/dev/null || echo '{}')
    tool_succeeded=$(printf '%s' "$input" | jq -r '
        if (.tool_response | type) == "object" and (.tool_response | has("success")) then .tool_response.success
        elif (.response | type) == "object" and (.response | has("success")) then .response.success
        else true
        end' 2>/dev/null || echo true)

    case "$event" in
        SessionStart)
            # Resolved from WV_LIB_DIR in dev and installed layouts.
            # shellcheck disable=SC1091
            source "$WV_LIB_DIR/lib/wv-hook-common.sh"
            _hc_refresh
            # Mirrors .claude/hooks/session-start-context.sh: stamp the epoch
            # PreToolUse's stale-node check compares against, and reset phase
            # so edits require an explicit claim this session.
            date +%s > "${_HC_HOT_ZONE}/.session_epoch" 2>/dev/null || true
            wv_set_phase "discover" "${_HC_HOT_ZONE}" 2>/dev/null || true
            active_id=$(_hook_active_id)
            _hook_decision_json allow "$event" "" "$active_id"
            ;;
        PreToolUse)
            # Resolved from WV_LIB_DIR in dev and installed layouts.
            # shellcheck disable=SC1091
            source "$WV_LIB_DIR/lib/wv-hook-common.sh"
            _hc_refresh
            # _hc_refresh now guarantees WV is set (wv-dfaa75) — see its own
            # comment for why _hc_check_active_node needs this.

            # Order matches dispatch_hook in docs/PROPOSAL-wv-pattern-crystallization.md
            # (installed-path guard, then classify/should-check, then phase, then
            # active/stale node) — the same order Claude's pre-action.sh runs in.
            local installed_hit
            if installed_hit=$(_hook_installed_path_hit "$tool" "$tool_input"); then
                _hook_decision_json block "$event" "Editing installed Weave copy at $installed_hit; edit the source in scripts/ instead"
                return 1
            fi

            if [ "$tool" = "apply_patch" ]; then
                _hc_classify_tool Edit "$tool_input"
            else
                _hc_classify_tool "$tool" "$tool_input"
            fi
            if [ "${_HC_MALFORMED:-false}" = true ] && [ "$raw_input_empty" = false ]; then
                _hook_decision_json block "$event" "Malformed hook payload (${_HC_MALFORMED_REASON}); failing closed for mutation gating"
                return 1
            fi
            if [ "${_HC_BYPASS_CMD:-false}" = true ] || [ "${_HC_SHOULD_CHECK:-false}" = false ]; then
                _hook_decision_json allow "$event"
                return 0
            fi

            local phase_rc=0
            _hc_check_phase 2>/dev/null || phase_rc=$?
            if [ "$phase_rc" -eq 2 ]; then
                _hook_decision_json block "$event" "File edit blocked during Weave ${_HC_PHASE:-discover} phase; claim work with wv work <id> first"
                return 1
            elif [ "$phase_rc" -eq 1 ]; then
                _hook_decision_json allow "$event"
                return 0
            fi

            if ! _hc_check_active_node >/dev/null 2>&1; then
                _hook_decision_json block "$event" "No active Weave node for edit-class tool"
                return 1
            fi
            active_id=$(printf '%s' "${_HC_ACTIVE_NODES:-[]}" | jq -r '.[0].id // empty' 2>/dev/null)

            if ! _hc_check_stale_node 2>/dev/null; then
                _hook_decision_json block "$event" "Active Weave node $active_id predates this session; re-claim with wv work $active_id" "$active_id"
                return 1
            fi

            if ! _hc_resolve_primary_node; then
                _hook_decision_json allow "$event"
                return 0
            fi
            active_id="$_HC_NODE_ID"
            if ! _hc_check_context_pack "$active_id" >/dev/null 2>&1; then
                _hook_decision_json block "$event" "Context Pack generation failed for active Weave node $active_id" "$active_id"
                return 1
            fi
            # Unlike Claude's pre-action.sh, dispatch may be the only policy gate
            # in mixed-host sessions. A prior context stamp is not authority to
            # skip graph policy here; rehydrate and check the current graph.
            if [ "${_HC_CONTEXT_STAMP_HIT:-false}" = true ]; then
                _HC_CONTEXT_PACK=$("$WV" context "$active_id" --json 2>/dev/null || echo "")
                if [ -z "$_HC_CONTEXT_PACK" ]; then
                    _hook_decision_json block "$event" "Context Pack generation failed for active Weave node $active_id" "$active_id"
                    return 1
                fi
            fi
            if ! _hc_check_contradictions "$active_id" >/dev/null 2>&1; then
                _hook_decision_json block "$event" "Contradictions detected for active Weave node $active_id" "$active_id"
                return 1
            fi
            if ! _hc_check_blockers "$active_id" >/dev/null 2>&1; then
                _hook_decision_json block "$event" "Active Weave node $active_id is blocked by incomplete work" "$active_id"
                return 1
            fi

            _hook_decision_json allow "$event" "" "$active_id"
            ;;
        PostToolUse)
            active_id=$(_hook_active_id)
            if [ "$tool_succeeded" != "false" ] && [ -n "$active_id" ]; then
                while IFS= read -r path; do
                    [ -n "$path" ] || continue
                    path=$(_hook_repo_relative_path "$path")
                    case ",$paths_csv," in
                        *",$path,"*) ;;
                        *) paths_csv="${paths_csv:+$paths_csv,}$path" ;;
                    esac
                done < <(_hook_input_paths "$tool" "$tool_input")
                if [ -n "$paths_csv" ]; then
                    "${WV:-${WV_CLI:-$SCRIPT_DIR/wv}}" touch "$active_id" --files="$paths_csv" >/dev/null 2>&1 || true
                fi
            fi
            _hook_decision_json allow "$event" "" "$active_id"
            ;;
        Stop)
            active_id=$(_hook_active_id)
            if [ -n "$active_id" ]; then
                _hook_decision_json block "$event" "Active Weave node must be closed or explicitly deferred" "$active_id"
                return 1
            fi
            _hook_decision_json allow "$event"
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
            echo "Usage: wv hook dispatch --event=SessionStart|PreToolUse|PostToolUse|Stop [--json]"
            echo "       wv hook normalize --host=claude|codex|mcp|cli --event=<raw event> [--json]" ;;
        *) echo "Error: unknown hook command '${1:-}'" >&2; return 1 ;;
    esac
}
