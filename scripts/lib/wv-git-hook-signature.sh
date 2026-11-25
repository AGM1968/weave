#!/bin/bash
# wv-git-hook-signature.sh — one definition of "this installed git hook is
# Weave's" (wv-3a7368).
#
# The installers (install.sh, and the wv-init-repo it generates) refresh a
# Weave hook and place the pre-commit module beside it; wv doctor reports the
# same hooks. Each used to carry its own test, and doctor's matched only the
# current header, so a hook the installers refreshed as Weave's was called
# custom by doctor. All of them now ask this file. install.sh loads it from
# ./scripts/lib, wv-init-repo and wv doctor from the installed lib dir. The
# merge drivers .gitattributes names are defined here too, for the same three.
#
# Defines functions only: no exports, no other sources, safe to load anywhere.

# Stable Weave signatures, any hook: the header line of each hook Weave has
# shipped, the prepare-commit-msg trailer text, and the skip knob and
# hook-common load that an older pre-commit carried before its header changed.
WV_GIT_HOOK_SIGNATURE='# Weave (pre-commit|post-commit|prepare-commit|pre-push|reference-transaction|re-projection)|Weave: append Weave-ID|WV_SKIP_PRECOMMIT|wv-hook-common'

# wv_git_hook_is_weave <file> [marker] — true when FILE is a Weave hook: it
# carries MARKER (the caller's current header, an extended regex) or any
# stable signature above. A missing file is not a Weave hook.
wv_git_hook_is_weave() {
    local file="$1" marker="${2:-}" pattern="$WV_GIT_HOOK_SIGNATURE"
    [ -f "$file" ] || return 1
    [ -n "$marker" ] && pattern="$marker|$pattern"
    grep -qE -- "$pattern" "$file" 2>/dev/null
}

# ─── Merge drivers (wv-f0b143) ───────────────────────────────────────────────
# .gitattributes routes .weave/ files to merge=ours, merge=theirs and
# merge=wv-trails. Git builds in only text, binary and union: any other name
# needs merge.<name>.driver in the clone's git config, which no clone or
# worktree inherits. Without it git falls back to a text merge without a word,
# and two copies' graph commits conflict or take the wrong side. The same
# loaders as above share one definition: install.sh registers them for the
# source checkout, wv-init-repo for every Weave repository; wv doctor and wv
# bootstrap report what is missing with one git config line that registers it,
# needing no install, no wv write and no ownership decision (wv-d24a69), and
# wv doctor --repair registers it in an owned repository. Registration and that
# line come from one table, _wv_merge_driver_value, so they cannot drift.

# _wv_sh_quote <string> — <string> as one single-quoted shell word.
_wv_sh_quote() {
    local q="'\''"
    printf "'%s'" "${1//\'/$q}"
}

# _wv_merge_driver_value <name> <trails-driver-script> — the merge.<name>.driver
# value Weave registers, or rc 1 for a driver Weave does not define (or the
# trails driver when its script is not installed).
_wv_merge_driver_value() {
    case "$1" in
        ours)      printf 'true' ;;
        theirs)    printf 'cp %%B %%A' ;;
        wv-trails) [ -f "$2" ] || return 1
                   printf 'python3 %s %%O %%A %%B' "$(_wv_sh_quote "$2")" ;;
        *)         return 1 ;;
    esac
}

# wv_register_merge_drivers <repo> <trails-driver-script> — register the
# drivers Weave's merge rules name. The trails driver is registered only when
# its script exists; returns 1 when it does not, after registering the rest.
wv_register_merge_drivers() {
    local repo="$1" trails="$2" name value
    for name in ours theirs; do
        value=$(_wv_merge_driver_value "$name" "$trails") || return 1
        git -C "$repo" config "merge.$name.driver" "$value" || return 1
    done
    value=$(_wv_merge_driver_value wv-trails "$trails") || return 1
    git -C "$repo" config merge.wv-trails.name "Weave trails: union of notes and completion records" || return 1
    git -C "$repo" config merge.wv-trails.driver "$value"
}

# wv_merge_driver_remedy <repo> <trails-driver-script> — one shell line that
# registers every driver wv_unregistered_merge_drivers names, each value
# single-quoted (an install path may hold spaces). A name Weave does not
# define, or the trails driver without its script, is named after the line
# instead of guessed at. Prints nothing when nothing is missing.
wv_merge_driver_remedy() {
    local repo="$1" trails="$2" name value line="" unknown=""
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        if value=$(_wv_merge_driver_value "$name" "$trails"); then
            line="${line:+$line && }git config merge.$name.driver $(_wv_sh_quote "$value")"
        else
            unknown="${unknown:+$unknown, }$name"
        fi
    done < <(wv_unregistered_merge_drivers "$repo")
    [ -n "$line$unknown" ] || return 0
    if [ -z "$line" ]; then
        printf 'no Weave definition for %s: install Weave (wv-update) or define merge.<name>.driver\n' "$unknown"
    elif [ -n "$unknown" ]; then
        printf '%s (no Weave definition for %s: install Weave (wv-update) or define merge.<name>.driver)\n' "$line" "$unknown"
    else
        printf '%s\n' "$line"
    fi
}

# wv_unregistered_merge_drivers <repo> — each driver a merge=<name> rule in the
# repository's .gitattributes names that is not built in and has no
# merge.<name>.driver, one per line. Read from the file, not a typed list, so a
# rule added later is covered. Prints nothing when every one is registered.
wv_unregistered_merge_drivers() {
    local repo="$1" attrs name
    attrs="$repo/.gitattributes"
    [ -f "$attrs" ] || return 0
    sed -e 's/#.*//' "$attrs" | grep -oE '(^|[[:space:]])merge=[^[:space:]]+' \
        | sed -e 's/.*merge=//' | sort -u | while IFS= read -r name; do
            case "$name" in text|binary|union) continue ;; esac
            git -C "$repo" config --get "merge.$name.driver" >/dev/null 2>&1 || printf '%s\n' "$name"
        done
}
