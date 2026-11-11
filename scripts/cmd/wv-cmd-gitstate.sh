#!/bin/bash
# wv-cmd-gitstate.sh — the working tree's git state as wv status, wv recover and wv doctor report it
#
# Commands: (helpers)
# Sourced by: wv entry point (autoloaded on first use)
# Dependencies: wv-config.sh, wv-checkpoint-ci.sh
#
# Moved unchanged from wv-cmd-ops.sh (wv-c153c4). wv status reached wv-cmd-ops.sh only
# through _detect_git_pending, so every suite running it was routed from ops.

# _git_status_weave_split <git_root> — prints "<weave_dirty> <outside_dirty>"
# (true/false) from ONE `git status` walk (wv-3125a9). A second walk limited
# to .weave/ cost as much as the full one, since git still reads the whole
# index. -z gives each path unquoted and a rename's or copy's source as its own
# field: the text form quoted unusual names, so a .weave/ path git quoted read
# as outside .weave/, and a name holding " -> " split as a rename. Each side of
# a rename counts on its own: touching .weave/ makes .weave/ dirty, as the
# limited walk listed it (as an add or a delete), and a side outside makes the
# rest of the tree dirty.
_git_status_weave_split() {
    local -a fields
    local i=0 width path weave=false outside=false
    mapfile -d '' -t fields < <(git -C "$1" status --porcelain -z 2>/dev/null || true)
    while [ "$i" -lt "${#fields[@]}" ]; do
        # A rename or copy record is "XY <dest>" then "<source>" as the next field.
        case "${fields[i]:0:2}" in *R*|*C*) width=2 ;; *) width=1 ;; esac
        fields[i]="${fields[i]:3}"
        for path in "${fields[@]:i:width}"; do
            if [[ "$path" == .weave/* ]]; then weave=true; else outside=true; fi
        done
        i=$((i + width))
    done
    echo "$weave $outside"
}

_git_commit_weave_ownership() {
    local git_root="$1"
    local sha="$2"
    local -a paths
    local path

    # -z for the reason above: a quoted .weave/ name read as a non-.weave commit.
    mapfile -d '' -t paths < <(git -C "$git_root" diff-tree -z --no-commit-id --name-only -r -m "$sha" 2>/dev/null || true)
    [ "${#paths[@]}" -gt 0 ] || return 2

    for path in "${paths[@]}"; do
        [ -z "$path" ] && continue
        if [[ "$path" != .weave/* ]]; then
            return 1
        fi
    done

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
    local git_root upstream="" ahead_shas=""
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
              recorded_pushed:0, ref_maybe_stale:false,
              weave_dirty:$weave_dirty, outside_dirty:$outside_dirty}'
        return 0
    fi

    read -r weave_dirty_bool outside_dirty <<< "$(_git_status_weave_split "$git_root")"

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
    # A replica whose tracking ref is stale (a refused fetch, a push to a URL)
    # counts published commits as ahead (wv-d235b6). The state stands: a failed
    # push leaves the same record, so the doubt is reported, not resolved.
    local recorded_pushed=0 ref_maybe_stale=false
    if [ "$ahead_count" -gt 0 ] 2>/dev/null && command -v wv_push_recorded_ahead >/dev/null 2>&1; then
        recorded_pushed=$(wv_push_recorded_ahead "$git_root")
        [[ "$recorded_pushed" =~ ^[0-9]+$ ]] || recorded_pushed=0
    fi
    if [ "$recorded_pushed" -gt 0 ]; then
        ref_maybe_stale=true
        local refresh="git fetch, or after a push to a URL: git fetch <url> ${upstream#*/}:refs/remotes/$upstream"
        if [ "$recorded_pushed" -ge "$ahead_count" ]; then
            hint="the $ahead_count commit(s) ahead of $upstream were sent by a recorded push, so $upstream may be stale; refresh it before acting: $refresh"
        else
            hint="$hint; $recorded_pushed of the $ahead_count commit(s) ahead were sent by a recorded push, so $upstream may be stale: $refresh"
        fi
    fi
    jq -n \
        --argjson pending "$pending" \
        --arg state "$state" \
        --arg action "$action" \
        --arg reason "$reason" \
        --arg hint "$hint" \
        --arg upstream "$upstream" \
        --argjson ahead_count "$ahead_count" \
        --argjson recorded_pushed "$recorded_pushed" \
        --argjson ref_maybe_stale "$ref_maybe_stale" \
        --argjson weave_dirty "$weave_dirty_bool" \
        --argjson outside_dirty "$outside_dirty" \
        '{pending:$pending, state:$state, action:$action, reason:$reason, hint:$hint,
          upstream:$upstream, ahead_count:$ahead_count,
          recorded_pushed:$recorded_pushed, ref_maybe_stale:$ref_maybe_stale,
          weave_dirty:$weave_dirty, outside_dirty:$outside_dirty}'
}
