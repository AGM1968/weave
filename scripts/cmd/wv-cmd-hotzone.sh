#!/bin/bash
# wv-cmd-hotzone.sh — hot-zone maintenance (gc, list, db, diff)
#
# Commands: hotzone
# Sourced by: wv entry point (autoloaded on first use)
# Dependencies: wv-config.sh, wv-db.sh, wv-graph-diff.sh
#
# Moved unchanged from wv-cmd-ops.sh (wv-c153c4): the commands that use these
# no longer load wv-cmd-ops.sh, so a change to doctor or bootstrap code no
# longer routes to every suite that runs them.

cmd_hotzone() {
    local subcmd="${1:-}"
    shift || true

    case "$subcmd" in
        gc)
            local dry_run=false
            while [ $# -gt 0 ]; do
                case "$1" in
                    --dry-run) dry_run=true ;;
                esac
                shift
            done

            local hot_zone hz_parent removed=0 skipped=0
            hot_zone=$(resolve_repo_hot_zone)
            hz_parent=$(dirname "$hot_zone")

            if [ ! -d "$hz_parent" ]; then
                echo "Hot-zone parent $hz_parent not found — nothing to gc."
                return 0
            fi

            local now
            now=$(date +%s)
            local d eligible=0
            for d in "$hz_parent"/*/; do
                [ -f "${d}brain.db" ] || continue
                local canon_d
                canon_d=$(canonicalize_runtime_path "${d%/}")
                local canon_hot
                canon_hot=$(canonicalize_runtime_path "$hot_zone")
                [ "$canon_d" = "$canon_hot" ] && continue

                # Orphan: no owner file, or owner dir no longer exists
                local owner=""
                owner=$(cat "${d}.repo_root" 2>/dev/null || echo "")
                local is_orphan=false
                if [ -z "$owner" ]; then
                    is_orphan=true
                elif [ ! -d "$owner" ]; then
                    is_orphan=true
                fi
                "$is_orphan" || continue

                # Age guard: skip dirs with recent writes (< 1 hour) — may be active test
                local mtime
                mtime=$(stat -c%Y "${d}brain.db" 2>/dev/null || stat -f%m "${d}brain.db" 2>/dev/null || echo 0)
                local age=$(( now - mtime ))
                if [ "$age" -lt 3600 ]; then
                    skipped=$((skipped + 1))
                    continue
                fi

                eligible=$((eligible + 1))
                if [ "$dry_run" = true ]; then
                    echo "  would remove: ${d} (owner=${owner:-none}, age=${age}s)"
                else
                    rm -rf "$d" 2>/dev/null && removed=$((removed + 1)) || true
                fi
            done

            if [ "$dry_run" = true ]; then
                echo "wv hotzone gc --dry-run: $eligible eligible orphan(s); $skipped skipped (< 1h old) under $hz_parent"
            else
                echo "wv hotzone gc: removed $removed orphan(s), skipped $skipped (< 1h old) under $hz_parent"
            fi
            if ! git rev-parse --show-toplevel >/dev/null 2>&1; then
                echo "note: not inside a git repo — the hot-zone parent resolves repo-relatively; cd into a repo to gc its family" >&2
            fi
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
            echo "  gc [--dry-run]   Remove orphan hot-zone dirs (no .repo_root or dead owner)"
            echo "  list             Show all hot-zone dirs with owner + node count"
            echo "  db               Print the resolved brain.db path (for raw sqlite3)"
            echo "  diff <db> <db>   Compare two copies of one graph, read-only (before removing either)"
            ;;
    esac
}
