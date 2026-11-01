#!/bin/bash
# wv-cmd-gitstate.sh — the working tree's git state as wv status, wv recover and wv doctor report it
#
# Commands: (helpers)
# Sourced by: wv entry point (autoloaded on first use)
# Dependencies: wv-config.sh, wv-checkpoint-ci.sh
#
# Moved unchanged from wv-cmd-ops.sh (wv-c153c4). wv status reached wv-cmd-ops.sh only
# through _detect_git_pending, so every suite running it was routed from ops.

_git_status_has_outside_weave_changes() {
    local status_lines="$1"
    local raw_path old_path new_path

    while IFS= read -r raw_path; do
        [ -z "$raw_path" ] && continue
        raw_path="${raw_path:3}"
        if [[ "$raw_path" == *" -> "* ]]; then
            old_path="${raw_path%% -> *}"
            new_path="${raw_path##* -> }"
            if [[ "$old_path" != .weave/* ]] || [[ "$new_path" != .weave/* ]]; then
                return 0
            fi
        elif [[ "$raw_path" != .weave/* ]]; then
            return 0
        fi
    done <<< "$status_lines"

    return 1
}

_git_commit_weave_ownership() {
    local git_root="$1"
    local sha="$2"
    local paths path

    paths=$(git -C "$git_root" diff-tree --no-commit-id --name-only -r -m "$sha" 2>/dev/null || true)
    [ -n "$paths" ] || return 2

    while IFS= read -r path; do
        [ -z "$path" ] && continue
        if [[ "$path" != .weave/* ]]; then
            return 1
        fi
    done <<< "$paths"

    return 0
}

_git_pending_hint() {
    case "$1" in
        dirty_weave)
            echo "run: git add .weave/ && git commit -m \"chore: sync Weave [skip ci]\" && git push"
            ;;
        dirty_weave_and_ahead_weave)
            echo "run: git add .weave/ && git commit -m \"chore: sync Weave [skip ci]\" && git push"
            ;;
        ahead_weave)
            echo "run: git push"
            ;;
        no_upstream)
            echo "configure an upstream before retrying recovery"
            ;;
        dirty_outside_weave)
            echo "commit or stash non-.weave changes before retrying recovery"
            ;;
        ahead_non_weave)
            echo "separate or push non-.weave commits manually before retrying recovery"
            ;;
        ahead_empty_commit)
            echo "legacy or ambiguous empty commit ahead — manual remediation required"
            ;;
        *)
            echo "no action required"
            ;;
    esac
}

_detect_git_pending() {
    local git_root upstream="" weave_dirty="" all_status="" ahead_shas=""
    local pending=false weave_dirty_bool=false outside_dirty=false
    local state="clean" action="none" reason="clean" hint="no action required"
    local ahead_count=0 has_non_weave=false has_ambiguous_empty=false sha

    git_root=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
    if [ -z "$git_root" ] || [ ! -d "$git_root/.git" ]; then
        jq -n \
            --argjson pending false \
            --arg state "clean" \
            --arg action "none" \
            --arg reason "not_repo" \
            --arg hint "no action required" \
            --arg upstream "" \
            --argjson ahead_count 0 \
            --argjson weave_dirty false \
            --argjson outside_dirty false \
            '{pending:$pending, state:$state, action:$action, reason:$reason, hint:$hint,
              upstream:$upstream, ahead_count:$ahead_count,
              weave_dirty:$weave_dirty, outside_dirty:$outside_dirty}'
        return 0
    fi

    weave_dirty=$(git -C "$git_root" status --porcelain -- .weave/ 2>/dev/null || true)
    [ -n "$weave_dirty" ] && weave_dirty_bool=true

    all_status=$(git -C "$git_root" status --porcelain 2>/dev/null || true)
    if [ -n "$all_status" ] && _git_status_has_outside_weave_changes "$all_status"; then
        outside_dirty=true
    fi

    upstream=$(git -C "$git_root" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null || echo "")
    if [ -n "$upstream" ]; then
        ahead_shas=$(git -C "$git_root" rev-list "${upstream}..HEAD" 2>/dev/null || true)
        if [ -n "$ahead_shas" ]; then
            ahead_count=$(printf '%s\n' "$ahead_shas" | sed '/^$/d' | wc -l | tr -d ' ')
        fi
    fi

    if [ "$ahead_count" -gt 0 ] 2>/dev/null; then
        while IFS= read -r sha; do
            [ -z "$sha" ] && continue
            _git_commit_weave_ownership "$git_root" "$sha"
            case $? in
                1) has_non_weave=true ;;
                2) has_ambiguous_empty=true ;;
            esac
        done <<< "$ahead_shas"
    fi

    if [ "$weave_dirty_bool" = true ] || [ "$ahead_count" -gt 0 ] 2>/dev/null; then
        pending=true
    fi

    if [ "$pending" = true ]; then
        if [ -z "$upstream" ]; then
            state="unresolvable"
            reason="no_upstream"
        elif [ "$outside_dirty" = true ]; then
            state="unresolvable"
            reason="dirty_outside_weave"
        elif [ "$has_non_weave" = true ]; then
            state="unresolvable"
            reason="ahead_non_weave"
        elif [ "$has_ambiguous_empty" = true ]; then
            state="unresolvable"
            reason="ahead_empty_commit"
        elif [ "$weave_dirty_bool" = true ]; then
            state="recoverable"
            action="commit_push"
            reason="dirty_weave"
            if [ "$ahead_count" -gt 0 ] 2>/dev/null; then
                reason="dirty_weave_and_ahead_weave"
            fi
        else
            state="recoverable"
            action="push_only"
            reason="ahead_weave"
        fi
    fi

    hint=$(_git_pending_hint "$reason")
    jq -n \
        --argjson pending "$pending" \
        --arg state "$state" \
        --arg action "$action" \
        --arg reason "$reason" \
        --arg hint "$hint" \
        --arg upstream "$upstream" \
        --argjson ahead_count "$ahead_count" \
        --argjson weave_dirty "$weave_dirty_bool" \
        --argjson outside_dirty "$outside_dirty" \
        '{pending:$pending, state:$state, action:$action, reason:$reason, hint:$hint,
          upstream:$upstream, ahead_count:$ahead_count,
          weave_dirty:$weave_dirty, outside_dirty:$outside_dirty}'
}
