#!/bin/bash
# wv-cmd-hotzone.sh — hot-zone maintenance (gc, list, db, diff; migrate is
# dispatched by scripts/wv from lib/wv-hotzone-migrate.sh, wv-97d68a)
#
# Commands: hotzone
# Sourced by: wv entry point (autoloaded on first use)
# Dependencies: wv-config.sh, wv-db.sh, wv-graph-diff.sh
#
# Moved unchanged from wv-cmd-ops.sh (wv-c153c4): the commands that use these
# no longer load wv-cmd-ops.sh, so a change to doctor or bootstrap code no
# longer routes to every suite that runs them.

# gc never deletes a zone on inference (wv-4ccc98). A zone whose repository is
# known to be gone moves, by same-filesystem rename, into <base>/.quarantine/,
# with a .quarantined record of where it was and when. A later gc purges a
# quarantined zone only after WV_HOTZONE_QUARANTINE_DAYS (default 7), while its
# owner is still gone and nothing has written to it since; an owner that came
# back or cannot be seen keeps it. wv hotzone restore moves one back. The
# quarantine is a dot directory, so the zone scans (gc, list, doctor) skip it.

# _hz_gc <dry-run> -- one gc pass over this repository's hot-zone family.
_hz_gc() {
    local dry_run="$1" hot_zone hz_parent canon_hot d v now moved=0 skipped=0 kept=0 eligible=0
    hot_zone=$(resolve_repo_hot_zone)
    hz_parent=$(dirname "$hot_zone")
    if [ ! -d "$hz_parent" ]; then
        echo "Hot-zone parent $hz_parent not found — nothing to gc."
        return 0
    fi
    now=$(date +%s)
    canon_hot=$(canonicalize_runtime_path "$hot_zone")
    for d in "$hz_parent"/*/; do
        d="${d%/}"
        [ -f "$d/brain.db" ] || continue
        [ "$(canonicalize_runtime_path "$d")" != "$canon_hot" ] || continue
        v=$(_hz_gc_verdict "$d" "$now")
        case "${v%%$'\t'*}" in
            kept) kept=$((kept + 1)); echo "  kept: $d/ (owner unknown: ${v#*$'\t'})" ;;
            young) skipped=$((skipped + 1)) ;;
            eligible)
                eligible=$((eligible + 1))
                if [ "$dry_run" = true ]; then
                    echo "  would quarantine: $d (owner=$(read_hot_zone_owner "$d"))"
                elif _hz_quarantine "$hz_parent" "$d" "$now"; then
                    moved=$((moved + 1))
                fi
                ;;
        esac
    done
    _hz_purge "$hz_parent" "$now" "$dry_run"
    _hz_gc_summary "$dry_run" "$hz_parent" "$eligible" "$moved" "$skipped" "$kept"
}

# _hz_gc_summary <dry-run> <base> <eligible> <moved> <skipped> <kept>
_hz_gc_summary() {
    if [ "$1" = true ]; then
        echo "wv hotzone gc --dry-run: $3 eligible orphan(s); $5 skipped (< 1h old); $6 kept (owner unknown) under $2"
    else
        echo "wv hotzone gc: quarantined $4 orphan(s), skipped $5 (< 1h old), kept $6 (owner unknown) under $2"
    fi
    git rev-parse --show-toplevel >/dev/null 2>&1 \
        || echo "note: not inside a git repo — the hot-zone parent resolves repo-relatively; cd into a repo to gc its family" >&2
}

# _hz_mtime <file> -- modification time in epoch seconds (GNU or BSD stat), 0
# when unreadable.
_hz_mtime() {
    wv_stat mtime "$1" || echo 0
}

# _hz_gc_verdict <zone> <now> -- print kept<TAB>why (owner unknown), young
# (written in the last hour), eligible (owner known gone), or live.
_hz_gc_verdict() {
    local state why
    state=$(hot_zone_owner_state "$1")
    why="${state#*$'\t'}"; state="${state%%$'\t'*}"
    if [ "$state" = unknown ]; then
        printf 'kept\t%s\n' "$why"
    elif [ "$state" != gone ]; then
        echo live
    elif [ $(( $2 - $(_hz_mtime "$1/brain.db") )) -lt 3600 ]; then
        echo young
    else
        echo eligible
    fi
}

# _hz_quarantine <base> <zone> <now> -- move the zone into <base>/.quarantine/
# by rename (same filesystem: the quarantine is inside the base) and record
# where it came from. A rename that fails leaves the zone where it was.
_hz_quarantine() {
    local q="$1/.quarantine" dest
    dest="$q/${2##*/}.$3"
    (umask 077 && mkdir -p "$q") || return 1
    if ! mv -- "$2" "$dest" 2>/dev/null; then
        echo "  could not quarantine $2 (left in place)" >&2
        return 1
    fi
    printf 'path=%s\nquarantined_at=%s\n' "$2" "$3" > "$dest/.quarantined"
    echo "  quarantined: $2 -> $dest (restore: wv hotzone restore ${dest##*/})"
}

# _hz_purge <base> <now> <dry-run> -- remove quarantined zones past the
# retention period whose owner is still gone and that nothing has written to
# since quarantine; report the others.
_hz_purge() {
    local q="$1/.quarantine" days="${WV_HOTZONE_QUARANTINE_DAYS:-7}" d at
    [ -d "$q" ] || return 0
    [[ "$days" =~ ^[0-9]+$ ]] || days=7
    for d in "$q"/*/; do
        d="${d%/}"
        [ -f "$d/.quarantined" ] || continue
        at=$(sed -n 's/^quarantined_at=//p' "$d/.quarantined")
        [[ "$at" =~ ^[0-9]+$ ]] || continue
        [ $(( $2 - at )) -ge $(( days * 86400 )) ] || continue
        _hz_purge_one "$d" "$at" "$days" "$3"
    done
}

# _hz_purge_one <quarantined zone> <quarantined_at> <days> <dry-run> -- purge
# it when its owner is still gone and nothing wrote to it since; else say why
# it stays.
_hz_purge_one() {
    local state
    state=$(hot_zone_owner_state "$1"); state="${state%%$'\t'*}"
    if [ "$state" != gone ] || [ "$(_hz_mtime "$1/brain.db")" -gt "$2" ]; then
        echo "  quarantine kept: $1 (owner $state, or written since quarantine)"
    elif [ "$4" = true ]; then
        echo "  would purge: $1 (quarantined ${3}+ days, owner still gone)"
    else
        rm -rf -- "$1" && echo "  purged: $1 (quarantined ${3}+ days, owner still gone)"
    fi
}

# _hz_restore <name|path> -- move a quarantined zone back where gc found it;
# refuse when something now occupies that path.
_hz_restore() {
    local hot_zone q src orig
    hot_zone=$(resolve_repo_hot_zone)
    q="$(dirname "$hot_zone")/.quarantine"
    src="$1"; [ -d "$src" ] || src="$q/${1##*/}"
    src="${src%/}"
    if [ ! -f "$src/.quarantined" ]; then
        echo "wv hotzone restore: no quarantined zone '$1' in $q" >&2
        return 1
    fi
    orig=$(sed -n 's/^path=//p' "$src/.quarantined")
    if [ -z "$orig" ] || [ -e "$orig" ]; then
        echo "wv hotzone restore: ${orig:-its original path} is occupied or unknown; nothing moved" >&2
        return 1
    fi
    mv -- "$src" "$orig" || return 1
    rm -f -- "$orig/.quarantined"
    echo "restored: $orig"
}

cmd_hotzone() {
    local subcmd="${1:-}"
    shift || true

    case "$subcmd" in
        gc)
            local dry_run=false
            while [ $# -gt 0 ]; do
                case "$1" in
                    --dry-run) dry_run=true ;;
                    *) _wv_reject_arg "hotzone gc" "$1"; return 1 ;;
                esac
                shift
            done
            _hz_gc "$dry_run"
            ;;
        restore)
            [ $# -eq 1 ] || { echo "Usage: wv hotzone restore <quarantined name or path>" >&2; return 1; }
            _hz_restore "$1"
            ;;
        list)
            local as_json=false
            while [ $# -gt 0 ]; do
                case "$1" in
                    --json) as_json=true ;;
                    *) _wv_reject_arg "hotzone list" "$1"; return 1 ;;  # wv-016983
                esac
                shift
            done
            local hot_zone hz_parent
            hot_zone=$(resolve_repo_hot_zone)
            hz_parent=$(dirname "$hot_zone")
            if ! git rev-parse --show-toplevel >/dev/null 2>&1; then
                echo "note: not inside a git repo — the hot-zone parent resolves repo-relatively; cd into a repo to see its family" >&2
            fi
            if [ ! -d "$hz_parent" ]; then
                if [ "$as_json" = true ]; then echo "[]"; else echo "Hot-zone parent $hz_parent not found."; fi
                return 0
            fi
            local d json_rows="" row_count=0
            for d in "$hz_parent"/*/; do
                [ -f "${d}brain.db" ] || continue
                row_count=$((row_count + 1))
                local owner=""
                owner=$(cat "${d}.repo_root" 2>/dev/null || echo "")
                local nodes=0
                nodes=$(sqlite3 "${d}brain.db" "SELECT COUNT(*) FROM nodes;" 2>/dev/null || echo "?")
                local label="live"
                if [ -z "$owner" ] || [ ! -d "$owner" ]; then
                    label="orphan"
                fi
                if [ "$as_json" = true ]; then
                    local row
                    # 'label' is a jq reserved word: jq 1.6 (dev machine apt)
                    # rejects both the bare key {label: ...} AND the variable
                    # $label; 1.7 tolerates them. Quote the key, avoid the name.
                    row=$(jq -n --arg lbl "$label" --arg path "${d%/}" --arg nodes "$nodes" --arg owner "${owner:-}" \
                        '{"label": $lbl, "path": $path, "nodes": (($nodes|tonumber?) // null), "owner": (if $owner == "" then null else $owner end)}')
                    json_rows="${json_rows:+$json_rows,}$row"
                else
                    printf '  %-10s  %s  nodes=%-4s  owner=%s\n' "$label" "${d%/}" "$nodes" "${owner:-none}"
                fi
            done
            if [ "$as_json" = true ]; then
                echo "[${json_rows}]"
            elif [ "$row_count" -eq 0 ]; then
                # Silence here looked like a defect during the v1.58 review —
                # always name the scanned parent so empty output is diagnosable.
                echo "(no hot-zone dirs under $hz_parent)" >&2
            fi
            ;;
        db|--db)
            # Print the resolved brain.db path so agents/scripts never hand-roll
            # /dev/shm vs /tmp/weave-hotzone paths in raw sqlite3 (finding wv-f752a5:
            # a guessed path errors and — in a parallel tool batch — cancels its
            # siblings). Use: DB=$(wv hotzone --db); sqlite3 "$DB" "..."
            # It takes no arguments; one was dropped without a word (wv-016983).
            if [ $# -gt 0 ]; then _wv_reject_arg "hotzone $subcmd" "$1"; return 1; fi
            local hot_zone
            hot_zone=$(resolve_repo_hot_zone)
            echo "${WV_DB:-$hot_zone/brain.db}"
            ;;
        diff)
            # Normally dispatched by scripts/wv before placement is resolved
            # (wv-757de1); reached here only when cmd_hotzone is called
            # directly. lib/wv-graph-diff.sh holds the comparison (wv-4898f7).
            wv_graph_diff "$@"
            ;;
        *)
            echo "Usage: wv hotzone <subcommand>"
            echo ""
            echo "Subcommands:"
            echo "  gc [--dry-run]   Quarantine hot-zone dirs whose repository is known to be deleted;"
            echo "                   purge quarantined ones still orphaned after the retention period"
            echo "  restore <name>   Move a quarantined hot-zone dir back to where gc found it"
            echo "  list             Show all hot-zone dirs with owner + node count"
            echo "  db               Print the resolved brain.db path (for raw sqlite3)"
            echo "  diff <db> <db>   Compare two copies of one graph, read-only (before removing either)"
            echo "  migrate [--apply] Relocate the /tmp zone to its neutral name, in a quiet window"
            ;;
    esac
}
