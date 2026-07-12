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

    input=$(cat)
    [ -n "$input" ] || input='{}'
    tool=$(printf '%s' "$input" | jq -r '.tool_name // .tool // empty' 2>/dev/null)
    tool_input=$(printf '%s' "$input" | jq -c '.tool_input // .input // {}' 2>/dev/null || echo '{}')
    tool_succeeded=$(printf '%s' "$input" | jq -r '
        if (.tool_response | type) == "object" and (.tool_response | has("success")) then .tool_response.success
        elif (.response | type) == "object" and (.response | has("success")) then .response.success
        else true
        end' 2>/dev/null || echo true)
    if ! printf '%s' "$input" | jq -e 'type == "object"' >/dev/null 2>&1; then
        _hook_decision_json hook_error "$event" "Invalid hook JSON; failing open"
        return 0
    fi

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

cmd_hook() {
    case "${1:-}" in
        dispatch) shift; cmd_hook_dispatch "$@" ;;
        --help|-h|"")
            echo "Usage: wv hook dispatch --event=SessionStart|PreToolUse|PostToolUse|Stop [--json]" ;;
        *) echo "Error: unknown hook command '${1:-}'" >&2; return 1 ;;
    esac
}
