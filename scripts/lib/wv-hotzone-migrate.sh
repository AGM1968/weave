#!/bin/bash
# wv-hotzone-migrate.sh — wv hotzone migrate (wv-97d68a)
#
# Relocates the /tmp zone from its legacy layout (a real
# /tmp/weave-codex-<uid> directory, the neutral /tmp/weave-hotzone-<uid> a
# symlink to it, as rc.14 to rc.18 create it) to the layout this release
# creates fresh: the neutral name the real directory and the legacy name a
# fence symlink to it (owner decision 2026-11-19; see the comment above
# _hot_zone_tmp_names in wv-resolve-runtime.sh).
#
# It is a maintenance operation run by hand in a quiet window, never by a hook,
# installer or other command. Without --apply it reports what it would do and
# what stops it. It moves storage only by one same-filesystem rename(2) of the
# whole directory, after the fence holds:
#   - no process of this user has a file, working directory, mapping or
#     environment value under either name (a resolved WV_DB or WV_HOT_ZONE
#     outlives placement; a live SQLite file is never moved under a process
#     that may hold it);
#   - every copy of the placement code a wv on this host could run knows the
#     neutral name (rc.14 and later); an older copy can only use the legacy one.
# Both names as separate directories that both hold databases is refused, as
# placement refuses it.
#
# Sourced by: scripts/wv, before placement is resolved, as wv hotzone diff is:
# placement refuses to run in some of the states this command repairs.
# Dependencies: wv-resolve-runtime.sh (sourced by the caller first).

_hzm_usage() {
    echo "Usage: wv hotzone migrate [--apply]"
    echo ""
    echo "Relocate the /tmp hot zone to its neutral name (wv-97d68a). Without --apply,"
    echo "report what would happen and what stops it. Run it with every wv process,"
    echo "agent session and MCP server on this host stopped, after wv sync in each"
    echo "repository."
}

# _hzm_resolver_copies — print each copy of the placement code a wv on this
# host could run: the running one, the installed one, the hook libraries'
# copy, and the copy beside every wv on PATH (a source checkout's scripts/).
_hzm_resolver_copies() {
    local cfg="${WV_CONFIG_DIR:-$HOME/.config/weave}" w d
    {
        if [ -n "${WV_LIB_DIR:-}" ]; then
            printf '%s\n' "$WV_LIB_DIR/lib/wv-resolve-runtime.sh" "$WV_LIB_DIR/weave_gh/data.py"
        fi
        printf '%s\n' "$HOME/.local/lib/weave/lib/wv-resolve-runtime.sh" \
            "$HOME/.local/lib/weave/weave_gh/data.py" "$cfg/lib/wv-resolve-runtime.sh"
        while IFS= read -r w; do
            [ -n "$w" ] || continue
            d=$(dirname -- "$(readlink -f -- "$w" 2>/dev/null || printf '%s' "$w")")
            printf '%s\n' "$d/lib/wv-resolve-runtime.sh" "$d/weave_gh/data.py"
        done <<< "$(type -ap wv 2>/dev/null)"
    } | LC_ALL=C sort -u
}

# _hzm_old_copies — print each existing placement-code copy that predates the
# neutral name (before 67f4e59f1, rc.14): such a wv can use only the legacy
# name, so relocating would split it from the zone.
_hzm_old_copies() {
    local f
    while IFS= read -r f; do
        [ -f "$f" ] || continue
        grep -qF 'weave-hotzone-' "$f" 2>/dev/null || echo "    $f"
    done <<< "$(_hzm_resolver_copies)"
}

# _hzm_path_re <path> — <path> as an extended regex matching itself literally.
_hzm_path_re() {
    printf '%s' "$1" | sed 's/[][\.*^$+?(){}|]/\\&/g'
}

# _hzm_zone_users <name> <name> — print each process of this user, other than
# this one, that has a file or working directory open under either name, maps
# a file under one, or names one in its environment. Returns 2 when /proc
# cannot be read, so the caller refuses rather than reading silence as quiet.
_hzm_zone_users() {
    local a="$1" b="$2" re hits pid
    [ -r "/proc/$$/environ" ] && [ -d "/proc/$$/fd" ] || return 2
    re="($(_hzm_path_re "$a")|$(_hzm_path_re "$b"))"
    hits=$(
        {
            find /proc/[0-9]*/fd /proc/[0-9]*/cwd /proc/[0-9]*/root -maxdepth 1 -type l \
                \( -lname "$a" -o -lname "$a/*" -o -lname "$b" -o -lname "$b/*" \) \
                -print 2>/dev/null
            grep -lE -e " ${re}(/| |\$)" /proc/[0-9]*/maps 2>/dev/null
            grep -lzE -e "(^|[=:])${re}(/|:|\$)" /proc/[0-9]*/environ 2>/dev/null
        } | sed -n 's|^/proc/\([0-9]*\)/.*|\1|p' | LC_ALL=C sort -u
    )
    for pid in $hits; do
        [ "$pid" = "$$" ] && continue
        [ -O "/proc/$pid" ] || continue
        echo "    pid $pid ($(cat "/proc/$pid/comm" 2>/dev/null || echo exited)): $(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | cut -c1-120)"
    done
}

# _hzm_is_empty <dir> — true when <dir> has no entries at all. A directory it
# cannot list is not empty: it is refused, never treated as safe to replace
# (wv-8ea297, the wv-4d45e6 class).
_hzm_is_empty() {
    local out
    out=$(ls -A -- "$1" 2>/dev/null) || return 1
    [ -z "$out" ]
}

# _hzm_refuse <why...> — record the refusal for the caller to print.
_hzm_refuse() {
    _HZM_STATE=refuse
    _HZM_WHY="$*"
}

# _hzm_classify_both <neutral> <legacy> — two real directories (placement's
# tie-break, wv-6f2eed): an empty one may go, a populated pair is refused.
_hzm_classify_both() {
    local n="$1" l="$2"
    if _hot_zone_populated "$n" && _hot_zone_populated "$l"; then
        _hzm_refuse "$n and $l are separate directories that both hold databases; reconcile them first (run wv status in a repository for the procedure)."
    elif ! _hot_zone_populated "$l"; then
        _hzm_is_empty "$l" || { _hzm_refuse "$l holds files but no database; inspect it and remove it by hand."; return; }
        _HZM_STATE=fence; _HZM_DROP="$l"
    else
        _hzm_is_empty "$n" || { _hzm_refuse "$n holds files but no database; inspect it and remove it by hand."; return; }
        _HZM_STATE=relocate; _HZM_DROP="$n"
    fi
}

# _hzm_classify_neutral_dir <neutral> <legacy> — the neutral name is a real
# directory: relocated already, missing only its fence link, or one of two.
_hzm_classify_neutral_dir() {
    local n="$1" l="$2" problem
    problem=$(hot_zone_dir_problem "$n")
    if [ -n "$problem" ]; then
        _hzm_refuse "$n $problem."
    elif [ -L "$l" ]; then
        if [ "$(readlink -- "$l")" = "$n" ]; then
            _HZM_STATE="done"
        else
            _hzm_refuse "$l is a symlink to $(readlink -- "$l"), not $n; an old wv would follow it. Remove it by hand."
        fi
    elif [ ! -e "$l" ]; then
        _HZM_STATE=fence
    elif [ -d "$l" ]; then
        _hzm_classify_both "$n" "$l"
    else
        _hzm_refuse "$l is not a directory."
    fi
}

# _hzm_classify_alias <neutral> <legacy> — the neutral name is a symlink: the
# legacy layout's alias, verified by the base guard's own predicate.
_hzm_classify_alias() {
    local n="$1" l="$2" problem
    problem=$(hot_zone_dir_problem "$n" "$l")
    if [ -n "$problem" ]; then
        _hzm_refuse "$n $problem."
    elif [ -d "$l" ]; then
        _HZM_STATE=relocate
    else
        _HZM_STATE=fence   # an alias to nothing: the next use replaces it
    fi
}

# _hzm_classify_legacy <neutral> <legacy> — no neutral name: the legacy name
# alone, as a directory to move, a fence link left without its directory, or
# nothing at all.
_hzm_classify_legacy() {
    local n="$1" l="$2" problem
    if [ -L "$l" ]; then
        [ "$(readlink -- "$l")" = "$n" ] && _HZM_STATE=fence \
            || _hzm_refuse "$l is a symlink to $(readlink -- "$l"), not $n. Remove it by hand."
    elif [ -d "$l" ]; then
        problem=$(hot_zone_dir_problem "$l")
        if [ -n "$problem" ]; then _hzm_refuse "$l $problem."; else _HZM_STATE=relocate; fi
    elif [ -e "$l" ]; then
        _hzm_refuse "$l is not a directory."
    else
        _HZM_STATE=fence   # neither: the next use creates the new layout
    fi
}

# _hzm_classify <neutral> <legacy> — set _HZM_STATE to what the zone needs:
# done (relocated, fence link in place), fence (only the link or an empty
# directory to settle; hot_zone_ensure's own work), relocate (the legacy
# directory moves), or refuse (_HZM_WHY says why). _HZM_DROP names an empty
# directory that goes first.
_hzm_classify() {
    local n="$1" l="$2"
    _HZM_STATE=""; _HZM_WHY=""; _HZM_DROP=""
    if [ -L "$n" ]; then
        _hzm_classify_alias "$n" "$l"
    elif [ -d "$n" ]; then
        _hzm_classify_neutral_dir "$n" "$l"
    elif [ -e "$n" ]; then
        _hzm_refuse "$n is not a directory."
    else
        _hzm_classify_legacy "$n" "$l"
    fi
}

# _hzm_fence <neutral> <legacy> — print what stops a move now; return 1 if any.
_hzm_fence() {
    local n="$1" l="$2" old users rc=0 _hzm_d1 _hzm_d2
    old=$(_hzm_old_copies)
    if [ -n "$old" ]; then
        echo "  Placement code that predates the neutral name (it can use only $l):"
        echo "$old"
        echo "  Update or remove each (./install.sh, or wv self-update), then rerun."
        rc=1
    fi
    users=$(_hzm_zone_users "$n" "$l") || {
        echo "  /proc cannot be read, so no process can be ruled out; nothing moves."
        return 1
    }
    if [ -n "$users" ]; then
        echo "  Processes still using the zone (stop each: wv sessions, agents, MCP servers, editors):"
        echo "$users"
        rc=1
    fi
    if [ -d "$l" ] && [ ! -L "$l" ] && { _hzm_d1=$(wv_stat dev "$l") && _hzm_d2=$(wv_stat dev "${n%/*}") && [ "$_hzm_d1" != "$_hzm_d2" ]; }; then
        echo "  $l and ${n%/*} are on different filesystems; a move would copy, not rename."
        rc=1
    fi
    return "$rc"
}

# _hzm_relocate <neutral> <legacy> — rename the legacy directory to the neutral
# name, setting a neutral alias aside first and restoring it if the rename
# fails. Prints what it did; returns 1 when nothing moved.
_hzm_relocate() {
    local n="$1" l="$2" aside=""
    if [ -L "$n" ]; then
        aside="${n}.migrate-$$"
        wv_rename_new "$n" "$aside" || { echo "  could not set the alias $n aside; nothing moved."; return 1; }
    fi
    if ! wv_rename_new "$l" "$n"; then
        [ -n "$aside" ] && wv_rename_new "$aside" "$n"
        echo "  could not rename $l to $n; nothing moved."
        return 1
    fi
    [ -n "$aside" ] && rm -f -- "$aside"
    echo "  moved $l to $n (one rename; every file kept its inode)"
}

# _hzm_apply <neutral> <legacy> — carry out _HZM_STATE.
_hzm_apply() {
    local n="$1" l="$2"
    if [ -n "$_HZM_DROP" ]; then
        rmdir -- "$_HZM_DROP" || { echo "  could not remove the empty $_HZM_DROP; nothing moved."; return 1; }
        echo "  removed the empty $_HZM_DROP"
    fi
    if [ "$_HZM_STATE" = relocate ]; then
        _hzm_relocate "$n" "$l" || return 1
    fi
    # The neutral directory and its fence link, by the one function that
    # creates zones; it also replaces an alias whose directory is gone.
    hot_zone_ensure "$n" || return 1
    if [ -L "$l" ] && [ "$(readlink -- "$l")" = "$n" ] && [ -d "$n" ] && [ ! -L "$n" ]; then
        echo "  $n is the zone; $l is its fence link"
    else
        echo "  the fence link $l could not be added; the next wv call that opens the zone adds it"
    fi
}

# _hzm_plan <neutral> <legacy> — say what _HZM_STATE will do and, when it
# moves or removes anything, check the fence. Returns 1 when refused.
_hzm_plan() {
    local n="$1" l="$2"
    if [ "$_HZM_STATE" = relocate ]; then
        echo "wv hotzone migrate: move $l to $n${_HZM_DROP:+ (removing the empty $_HZM_DROP first)}, then link $l to it."
    elif [ -n "$_HZM_DROP" ]; then
        echo "wv hotzone migrate: remove the empty $_HZM_DROP, then link $l to $n; no data moves."
    else
        echo "wv hotzone migrate: no data moves; $n becomes the zone and $l its fence link."
        return 0
    fi
    if ! _hzm_fence "$n" "$l"; then
        echo "Refused: nothing moved."
        return 1
    fi
    echo "  fence holds: no process uses the zone and every wv on this host knows $n."
}

# _hzm_args <args...> — set _HZM_APPLY; return 0 to run, 3 when there is
# nothing to run (--help, or a platform without the two names), 2 on an
# unknown argument.
_hzm_args() {
    local arg
    _HZM_APPLY=false
    for arg in "$@"; do
        case "$arg" in
            --apply) _HZM_APPLY=true ;;
            -h|--help) _hzm_usage; return 3 ;;
            *) echo "wv hotzone migrate: unknown argument '$arg'" >&2; _hzm_usage >&2; return 2 ;;
        esac
    done
    case "${OSTYPE:-}" in
        linux*) ;;
        *) echo "wv hotzone migrate: only the Linux /tmp zone has two names; nothing to do."; return 3 ;;
    esac
}

# wv_hotzone_migrate [--apply] — the command.
wv_hotzone_migrate() {
    local rc=0 n l
    _hzm_args "$@" || rc=$?
    [ "$rc" -eq 3 ] && return 0
    [ "$rc" -eq 0 ] || return "$rc"
    _hot_zone_tmp_names
    n="$_HZ_NEUTRAL"; l="$_HZ_LEGACY"
    _hzm_classify "$n" "$l"
    case "$_HZM_STATE" in
        refuse)
            echo "wv hotzone migrate: refusing: $_HZM_WHY"
            return 1 ;;
        "done")
            echo "wv hotzone migrate: nothing to do; $n is the zone and $l its fence link."
            return 0 ;;
    esac
    _hzm_plan "$n" "$l" || return 1
    if [ "$_HZM_APPLY" != true ]; then
        echo "Dry run: rerun with --apply to do it."
        return 0
    fi
    _hzm_apply "$n" "$l" || { echo "Stopped: see above."; return 1; }
    echo "Done. Check with: wv doctor"
}
