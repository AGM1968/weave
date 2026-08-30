#!/bin/bash
# wv-cmd-data.sh — Data management commands
#
# Commands: batch, plan, enrich-topology, sync, load, prune, clean-ghosts, commit-refs, learnings, refs, import, search, reindex, trails (alias: breadcrumbs)
# Sourced by: wv entry point (after lib modules)
# Dependencies: wv-config.sh, wv-db.sh, wv-validate.sh, wv-cache.sh

# ═══════════════════════════════════════════════════════════════════════════
# strip_unistr — Post-process SQLite .dump output for cross-version compat
# ═══════════════════════════════════════════════════════════════════════════

# SQLite >= 3.44 emits unistr('\uXXXX') in .dump for non-ASCII chars.
# Older versions (e.g. Debian 12 apt: 3.40.1) cannot load dumps containing
# unistr(). This filter converts unistr() calls to literal UTF-8 so the
# dump is loadable by any sqlite3 version >= 3.35.
strip_unistr() {
    if command -v python3 >/dev/null 2>&1; then
        python3 -c 'import sys, re
Q = chr(39)
def fix(m):
    inner = m.group(1)
    result = re.sub(r"\\u([0-9a-fA-F]{4})", lambda u: chr(int(u.group(1), 16)), inner)
    result = re.sub(r"\\U([0-9a-fA-F]{8})", lambda u: chr(int(u.group(1), 16)), result)
    # Content already has SQL-safe '"'"''"'"' escaping from sqlite3 .dump; do not re-escape
    return Q + result + Q
# Match unistr('"'"'...'"'"') including SQL-escaped '"'"''"'"' pairs inside the string
pat = re.compile(r"unistr\(" + Q + r"([^" + Q + r"]*(?:" + Q + Q + r"[^" + Q + r"]*)*)" + Q + r"\)")
sys.stdout.write(pat.sub(fix, sys.stdin.read()))
'
    else
        cat
    fi
}

# ═══════════════════════════════════════════════════════════════════════════
# dump_state_sql — Selective dump excluding FTS index (nodes + edges + file attribution)
# ═══════════════════════════════════════════════════════════════════════════

# FTS5 index is derived data rebuilt from node content in ~18ms.  The full
# .dump includes FTS internal tables (nodes_fts_data, _idx, _docsize, _config)
# which are binary BLOBs that serialize differently on every dump, defeating
# git delta compression.  At 270 nodes the FTS tables are 52MB vs 300KB for
# the actual data — a 99.5% overhead committed on every sync.
#
# _warp_changes is also excluded: it is a transient tracker table populated by
# triggers and cleared after every successful sync. Including it in state.sql
# caused stale tracker rows to be reimported on wv load, which made
# wv_delta_has_changes return true immediately after a fresh load even though
# no local changes had been made. The table is recreated empty by wv_delta_init
# on every load; triggers are reinstalled at the same time.
#
# This function dumps only the semantic data tables and the schema preamble needed
# to reconstruct the database. FTS is rebuilt on load via db_rebuild_fts.
# Delta tracking is reinstalled on load via wv_delta_init.
dump_state_sql() {
    local db="$1" outfile="$2"
    {
        sqlite3 -cmd ".timeout 5000" "$db" ".dump nodes" 2>/dev/null
        sqlite3 -cmd ".timeout 5000" "$db" ".dump edges" 2>/dev/null
        sqlite3 -cmd ".timeout 5000" "$db" ".dump node_files" 2>/dev/null
    } | strip_unistr > "$outfile"
}

# Human pattern-finding dispositions are the only non-rebuildable quality.db
# content. Keep them in a union-mergeable JSONL projection; scan findings and
# recurrence counters remain hot-zone-only and are rediscovered from source.
_quality_adjudications_export() {
    local quality_db="$WV_HOT_ZONE/quality.db"
    [ -f "$quality_db" ] || return 0
    _wv_quality_python --hot-zone "$WV_HOT_ZONE" \
        adjudications-export "$WEAVE_DIR/quality-adjudications.jsonl"
}

_quality_adjudications_import() {
    local projection="$WEAVE_DIR/quality-adjudications.jsonl"
    [ -f "$projection" ] || return 0
    _wv_quality_python --hot-zone "$WV_HOT_ZONE" adjudications-import "$projection"
}

# ═══════════════════════════════════════════════════════════════════════════
# auto_sync — Throttled auto-persist after mutating commands
# ═══════════════════════════════════════════════════════════════════════════

# Auto-sync interval in seconds (default 60). Set WV_AUTO_SYNC=0 to disable.
WV_SYNC_INTERVAL="${WV_SYNC_INTERVAL:-60}"
WV_AUTO_SYNC="${WV_AUTO_SYNC:-1}"
# Auto-checkpoint: WIP git commit after sync. Set WV_AUTO_CHECKPOINT=0 to disable.
WV_AUTO_CHECKPOINT="${WV_AUTO_CHECKPOINT:-1}"
# Checkpoint interval in seconds (default 600 = 10 min).
# Rate-limits git commits across auto_sync, explicit sync, and hook paths.
# Set to 0 for aggressive commits (original behavior).
WV_CHECKPOINT_INTERVAL="${WV_CHECKPOINT_INTERVAL:-600}"

# _delta_compact — delete delta files older than WV_DELTA_RETAIN_DAYS (default 30).
# SAFETY: only call manually (via `wv compact`) when all agents have loaded the
# latest state. Auto-running after auto_sync is unsafe: state.sql uses merge=ours,
# so a remote agent with an older state.sql can no longer replay compacted deltas.
# Returns count of deleted files via echo (so callers can log it).
_delta_compact() {
    local weave_dir="$1"
    local now="${2:-$(date +%s)}"
    local retain_days="${WV_DELTA_RETAIN_DAYS:-30}"
    [ "$retain_days" -eq 0 ] 2>/dev/null && return 0
    local delta_root="$weave_dir/deltas"
    [ -d "$delta_root" ] || return 0
    local cutoff=$(( now - retain_days * 86400 ))
    local deleted=0
    while IFS= read -r delta; do
        local delta_name delta_ts
        delta_name="${delta##*/}"
        delta_ts="${delta_name%%-*}"
        if [ "$delta_ts" -lt "$cutoff" ] 2>/dev/null; then
            rm -f "$delta"
            deleted=$(( deleted + 1 ))
        fi
    done < <(find "$delta_root" -name '*.sql' 2>/dev/null)
    # Remove empty date subdirectories left behind
    find "$delta_root" -mindepth 1 -maxdepth 1 -type d -empty -delete 2>/dev/null || true
    echo "$deleted"
}

# Floor-guard: block a sync that would shrink state.sql drastically. This is the
# data-loss prevention beyond the empty (0-node) check. The 2026-06-06 sandbox
# incident dumped a partial 69-node DB over a committed 306-node state.sql: tmpfs
# /dev/shm was wiped on session restart, the reload was incomplete, and the
# auto-checkpoint then persisted the partial over the committed truth. The empty
# guard passed (69 != 0), so ~237 nodes were lost. Refuse when the new dump has
# fewer than WV_SYNC_FLOOR_RATIO (default 0.70) of the committed node count.
# Bypass with --force, WV_FORCE_SYNC=1, or WV_SYNC_FLOOR_RATIO=0.
_sync_floor_guard_ok() {
    local new_sql="$1" force="${2:-false}"
    [ "$force" = true ] && return 0
    [ "${WV_FORCE_SYNC:-0}" = "1" ] && return 0
    local ratio="${WV_SYNC_FLOOR_RATIO:-0.70}"
    case "$ratio" in 0|0.0|0.00) return 0 ;; esac
    local existing="$WEAVE_DIR/state.sql"
    [ -f "$existing" ] || return 0
    local old_n new_n floor
    old_n=$(grep -c '^INSERT INTO nodes' "$existing" 2>/dev/null || true)
    new_n=$(grep -c '^INSERT INTO nodes' "$new_sql" 2>/dev/null || true)
    old_n=${old_n:-0}
    new_n=${new_n:-0}
    [ "$old_n" -gt 0 ] || return 0
    floor=$(awk -v o="$old_n" -v r="$ratio" 'BEGIN{printf "%d", o*r}')
    if [ "$new_n" -lt "$floor" ]; then
        echo -e "${RED}✗ Sync BLOCKED (floor-guard): dump has ${new_n} nodes vs ${old_n} committed in state.sql (< ${ratio}x).${NC}" >&2
        echo -e "${YELLOW}  Refusing to overwrite .weave/state.sql — likely a wiped/partial tmpfs DB (sandbox restart).${NC}" >&2
        echo -e "${YELLOW}  Recover: run 'wv load' to rehydrate from state.sql, or restore .weave from git.${NC}" >&2
        echo -e "${YELLOW}  Intentional shrink (e.g. prune)? Override: WV_FORCE_SYNC=1 wv sync  (or 'wv sync --force').${NC}" >&2
        return 1
    fi
    return 0
}

_should_persist_weave_state() {
    # Keep existing initialized repos durable, but do not materialize .weave/
    # for empty hot-zone-only sessions in non-initialized directories.
    if [ -d "$WEAVE_DIR" ]; then
        return 0
    fi

    local node_count edge_count
    node_count=$(sqlite3 -cmd ".timeout 5000" "$WV_DB" "SELECT COUNT(*) FROM nodes WHERE json_extract(metadata, '\$.type') IS NOT 'session_history';" 2>/dev/null || echo "0")
    edge_count=$(sqlite3 -cmd ".timeout 5000" "$WV_DB" "SELECT COUNT(*) FROM edges;" 2>/dev/null || echo "0")

    [ "$node_count" -gt 0 ] || [ "$edge_count" -gt 0 ]
}

auto_sync() {
    local _force=false
    for _arg in "$@"; do [ "$_arg" = "--force" ] && _force=true; done

    # Disabled by env var
    [ "$WV_AUTO_SYNC" = "0" ] && return 0

    # Skip during journal-protected operations (ship/sync/delete manage their own sync)
    [ -n "${_WV_IN_JOURNAL:-}" ] && return 0

    # Skip for custom DB paths (test isolation)
    [ -n "$WV_DB_CUSTOM" ] && return 0

    # Check throttle: sync at most once per interval (bypassed by --force)
    local stamp_file="$WV_HOT_ZONE/.last_sync"
    local now agent_id
    now=$(date +%s)
    agent_id="$(resolve_agent_id)"
    if [ "$_force" = false ] && [ -f "$stamp_file" ]; then
        local last_sync
        last_sync=$(cat "$stamp_file" 2>/dev/null || echo "0")
        if [ $(( now - last_sync )) -lt "$WV_SYNC_INTERVAL" ]; then
            return 0  # Too soon, skip
        fi
    fi

    # O(1) change detection: if _warp_changes is empty, nothing happened since
    # the last sync — skip the dump entirely. No I/O, no git noise.
    if ! wv_delta_has_changes "$WV_DB"; then
        return 0
    fi

    if ! _should_persist_weave_state; then
        wv_delta_reset "$WV_DB"
        echo "$now" > "$stamp_file"
        return 0
    fi

    # Emit delta changeset before the full dump. The changeset captures exactly
    # what changed since the last wv_delta_reset, in causal order (by _warp_changes.id).
    # Stored as .weave/deltas/<YYYY-MM-DD>/<epoch>-<subsec>-<seq>-<agent_id>-<pid>.sql.
    # The first field stays epoch-seconds for prune compatibility; fixed-width
    # subsecond and sequence fields make same-second emissions replay deterministically.
    # Day-subdirectory prevents single-dir inode bloat over time. These files are
    # committed to git and replayed by other agents on wv load (multi-agent merge).
    # Empty files (no-op cycles) are removed immediately.
    local delta_dir="$WEAVE_DIR/deltas/$(date +%Y-%m-%d)"
    mkdir -p "$delta_dir"
    local delta_prefix
    resolve_delta_filename_prefix delta_prefix
    local delta_file="$delta_dir/${delta_prefix}-${agent_id}-$$.sql"
    if ! wv_delta_changeset "$WV_DB" > "$delta_file"; then
        rm -f "$delta_file"
        echo "wv: failed to generate portable delta" >&2
        return 1
    fi
    [ -s "$delta_file" ] || rm -f "$delta_file"
    if [ "${WV_DELTA_V2_WRITE:-0}" = "1" ]; then
        local delta_v2_dir="$delta_dir/v2"
        if ! wv_delta_v2_write_operations "$WV_DB" "$delta_v2_dir" "$agent_id" >/dev/null; then
            echo "wv: warning: Delta v2 sidecar write failed; SQL delta remains authoritative" >&2
            [ "${WV_DELTA_V2_STRICT:-0}" = "1" ] && return 1
        fi
        find "$delta_v2_dir" -type d -empty -delete 2>/dev/null || true
    fi

    # Full dump to state.sql — kept as the authoritative snapshot and audit trail.
    # Deltas complement the dump; they are not a replacement. state.sql is what
    # cmd_load uses to reconstruct the DB from scratch; deltas patch it forward.
    mkdir -p "$WEAVE_DIR"
    local tmp_sql tmp_nodes tmp_edges
    tmp_sql=$(mktemp "$WEAVE_DIR/.state.sql.XXXXXX") || return 1
    tmp_nodes=$(mktemp "$WEAVE_DIR/.nodes.jsonl.XXXXXX") || { rm -f "$tmp_sql"; return 1; }
    tmp_edges=$(mktemp "$WEAVE_DIR/.edges.jsonl.XXXXXX") || { rm -f "$tmp_sql" "$tmp_nodes"; return 1; }

    if ! dump_state_sql "$WV_DB" "$tmp_sql" || [ ! -s "$tmp_sql" ]; then
        rm -f "$tmp_sql" "$tmp_nodes" "$tmp_edges"
        echo "wv: failed to generate portable state snapshot" >&2
        return 1
    fi

    # Floor-guard: never let an auto-checkpoint persist a drastically smaller graph
    # over committed truth (the 2026-06-06 sandbox data-loss path). Skip the dump,
    # keep deltas + _warp_changes pending, leave state.sql intact. Loud on stderr.
    if ! _sync_floor_guard_ok "$tmp_sql"; then
        rm -f "$tmp_sql" "$tmp_nodes" "$tmp_edges"
        return 1
    fi

    # Second-level no-op guard: triggers can fire on no-net-change operations
    # (e.g. UPDATE that writes the same value). cmp catches these by comparing
    # the dump output directly — if state.sql is byte-identical, skip the jsonl
    # regeneration and checkpoint entirely.
    if [ -f "$WEAVE_DIR/state.sql" ] && cmp -s "$tmp_sql" "$WEAVE_DIR/state.sql"; then
        rm -f "$tmp_sql" "$tmp_nodes" "$tmp_edges"
        wv_delta_reset "$WV_DB"
        echo "$now" > "$stamp_file"
        return 0
    fi

    if ! db_query_json "SELECT * FROM nodes;" | jq -c '.[]' > "$tmp_nodes" \
        || ! db_query_json "SELECT * FROM edges;" | jq -c '.[]' > "$tmp_edges"; then
        rm -f "$tmp_sql" "$tmp_nodes" "$tmp_edges"
        echo "wv: failed to generate portable JSONL projections" >&2
        return 1
    fi

    # Publish readable projections first and the authoritative snapshot last.
    # If a move fails, retain _warp_changes so a later sync can regenerate all
    # artifacts rather than treating a partial publish as durable.
    if ! mv "$tmp_nodes" "$WEAVE_DIR/nodes.jsonl" \
        || ! mv "$tmp_edges" "$WEAVE_DIR/edges.jsonl" \
        || ! mv "$tmp_sql" "$WEAVE_DIR/state.sql"; then
        rm -f "$tmp_sql" "$tmp_nodes" "$tmp_edges"
        echo "wv: failed to publish portable graph artifacts" >&2
        return 1
    fi

    # Reset change tracking after successful persist
    wv_delta_reset "$WV_DB"

    # NOTE: _delta_compact is NOT called here. Auto-compaction is unsafe in a
    # multi-agent topology: state.sql uses merge=ours, so Agent B keeps its own
    # (older) state.sql after a pull. If Agent A compacted + committed delta
    # deletions, Agent B can no longer replay those deltas and silently loses
    # Agent A's changes. Use `wv compact` manually only when all agents have
    # loaded the latest state.

    echo "$now" > "$stamp_file"

    # Auto-checkpoint: WIP git commit (throttled separately)
    auto_checkpoint "$now"
}

# ═══════════════════════════════════════════════════════════════════════════
# auto_checkpoint — WIP git commit to prevent session data loss
# ═══════════════════════════════════════════════════════════════════════════
# Commits ONLY .weave/ state files to preserve graph state without
# swallowing code changes that belong in intentional feature commits.
# Set WV_CHECKPOINT_ALL=1 to restore old behavior (stage everything).
# Throttled independently from sync (default 5 min).

auto_checkpoint() {
    [ "$WV_AUTO_CHECKPOINT" = "0" ] && return 0

    local now="${1:-$(date +%s)}"
    local cp_stamp="$WV_HOT_ZONE/.last_checkpoint"

    # Throttle: checkpoint at most once per WV_CHECKPOINT_INTERVAL.
    # Primary: stamp file (fast, O(1)). Fallback: git log (survives reboot/new session).
    if [ -f "$cp_stamp" ]; then
        local last_cp
        last_cp=$(cat "$cp_stamp" 2>/dev/null || echo "0")
        if [ $(( now - last_cp )) -lt "$WV_CHECKPOINT_INTERVAL" ]; then
            return 0
        fi
    else
        # No stamp file (first call in session / after reboot) — check git history
        local last_git_cp
        last_git_cp=$(git log -1 --format=%ct --grep='auto-checkpoint\|pre-compact checkpoint\|sync state' 2>/dev/null || echo 0)
        if [ $(( now - last_git_cp )) -lt "$WV_CHECKPOINT_INTERVAL" ]; then
            # Recent checkpoint in git — seed stamp and skip
            echo "$last_git_cp" > "$cp_stamp"
            return 0
        fi
    fi

    # Must be in a git repo
    local git_root
    git_root=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
    [ -z "$git_root" ] && return 0

    # Write stamp BEFORE commit to prevent re-entry
    echo "$now" > "$cp_stamp"

    # Hijack guard — must run BEFORE the pull below. `git pull --autostash`
    # stashes the caller's staged files and pops them back UNSTAGED, which would
    # defeat a post-pull guard and let the checkpoint churn an in-progress manual
    # commit. So bail out here, before any index-touching op, when the caller has
    # pre-staged anything outside .weave/. Escape hatch: WV_CHECKPOINT_ALL=1.
    if [ "${WV_CHECKPOINT_ALL:-0}" != "1" ]; then
        local _git_root_guard prestaged
        _git_root_guard=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
        if [ -n "$_git_root_guard" ]; then
            prestaged=$(git -C "$_git_root_guard" diff --cached --name-only 2>/dev/null \
                | grep -v '^\.weave/' || true)
            if [ -n "$prestaged" ]; then
                {
                    echo "wv: auto-checkpoint skipped — non-.weave/ files already staged by caller:"
                    echo "$prestaged" | sed 's/^/  /'
                    echo "wv: finish your commit first, or set WV_CHECKPOINT_ALL=1 to override."
                } >&2
                return 0
            fi
        fi
    fi

    # Pull remote changes first to prevent divergence races.
    # --rebase keeps history linear; --autostash handles our dirty .weave/ files.
    # Detect rebase conflicts instead of silently swallowing — a dirty rebase
    # state makes all subsequent git operations fail cryptically.
    # Set WV_CHECKPOINT_PULL=0 to disable pull entirely (for team repos).
    if [ "${WV_CHECKPOINT_PULL:-1}" = "1" ]; then
        # Only attempt pull if a remote is configured (avoids backoff in test envs)
        if git -C "$git_root" rev-parse --verify '@{u}' >/dev/null 2>&1; then
            local attempt
            for attempt in 1 2 3 4 5; do
                if git -C "$git_root" pull --rebase --autostash --quiet >/dev/null 2>&1; then
                    break
                fi
                # Check if we're stuck in a rebase
                if [ -d "$git_root/.git/rebase-merge" ] || [ -d "$git_root/.git/rebase-apply" ]; then
                    git -C "$git_root" rebase --abort 2>/dev/null || true
                    echo "wv: auto-checkpoint pull had conflicts, aborted rebase" >&2
                    break  # Don't retry rebase conflicts — they won't self-resolve
                fi
                # Exponential backoff with jitter for contention
                [ "$attempt" -lt 5 ] && sleep $(( (2 ** attempt) + RANDOM % 3 ))
            done
        fi
    fi

    if [ "${WV_CHECKPOINT_ALL:-0}" = "1" ]; then
        # Legacy mode: stage everything (breaks intentional commits)
        git -C "$git_root" add -A >/dev/null 2>&1 || return 0
    else
        # Safe mode: only stage .weave/ graph state. The hijack guard ran earlier
        # (before the pull) so by here no caller files are staged outside .weave/.
        git -C "$git_root" add .weave/ >/dev/null 2>&1 || return 0
    fi

    # Only commit if there are staged changes
    if ! git -C "$git_root" diff --cached --quiet 2>/dev/null; then
        # Include primary Weave ID as trailer for commit-to-node tracing
        local primary
        primary=$(get_primary_node 2>/dev/null || echo "")
        local trailers=""
        # Verify primary is still active
        if [ -n "$primary" ]; then
            local pstatus
            pstatus=$(db_query "SELECT status FROM nodes WHERE id='$primary';" 2>/dev/null || echo "")
            if [ "$pstatus" != "active" ]; then
                clear_primary_node 2>/dev/null || true
                primary=""
            fi
        fi
        if [ -n "$primary" ]; then
            trailers="
Weave-ID: $primary"
        else
            # No primary set — fall back to first active node
            local first_active
            first_active=$(db_query "SELECT id FROM nodes WHERE status='active' LIMIT 1;" 2>/dev/null || echo "")
            [ -n "$first_active" ] && trailers="
Weave-ID: $first_active"
        fi

        local ts
        ts=$(date -d "@$now" '+%H:%M' 2>/dev/null || date '+%H:%M')

        # Collapse consecutive weave-auto commits: amend the previous commit when
        # it's (a) an unpushed, (b) .weave/-only checkpoint. This keeps each
        # push boundary to exactly one weave commit instead of N per session.
        local _cp_branch _cp_local _cp_remote _cp_last_msg _cp_last_nw_files
        _cp_branch=$(git -C "$git_root" branch --show-current 2>/dev/null || echo "main")
        _cp_local=$(git -C "$git_root" rev-parse HEAD 2>/dev/null || echo "")
        _cp_remote=$(git -C "$git_root" rev-parse "origin/$_cp_branch" 2>/dev/null || echo "none")
        _cp_last_msg=$(git -C "$git_root" log -1 --format='%s' 2>/dev/null || echo "")
        _cp_last_nw_files=$(git -C "$git_root" diff HEAD~1 HEAD --name-only 2>/dev/null \
            | grep -v '^\.weave/' | grep -v '^$' || true)

        # Skip-when-at-origin guard: if HEAD == remote (nothing unpushed), creating a new
        # checkpoint commit here would interleave noise before the NEXT real commit.
        # The .weave/ files are already written to disk by auto_sync; the next real commit
        # or `wv sync --gh` will include them. This prevents the pattern:
        #   origin → [noise checkpoint] → [real feature commit]
        # Unstage .weave/ so it doesn't pollute the caller's index.
        # Exception: no remote ("none") — always checkpoint in that case.
        if [ "$_cp_local" = "$_cp_remote" ] && [ "$_cp_remote" != "none" ]; then
            git -C "$git_root" reset HEAD -- .weave/ >/dev/null 2>&1 || true
            return 0
        fi

        # wv-e937f8: [skip ci] applies to the whole PUSH at its tip, not just
        # this commit's own (always .weave-only) diff -- omit it when the
        # unpushed range ahead of upstream already carries non-.weave/ work,
        # so this checkpoint landing on top doesn't silently skip CI for it.
        local _cp_skip_ci
        _cp_skip_ci=$(wv_checkpoint_ci_marker "$git_root")

        if [ "$_cp_local" != "$_cp_remote" ] \
           && [[ "$_cp_last_msg" =~ auto-checkpoint|sync\ state|session-start\ state|pre-compact\ checkpoint ]] \
           && [ -z "$_cp_last_nw_files" ]; then
            # Amend with fresh timestamp + trailers so Weave-ID stays current
            git -C "$git_root" commit --amend \
                -m "chore(weave): auto-checkpoint $ts${_cp_skip_ci}${trailers}" \
                --no-verify --quiet 2>/dev/null || \
            git -C "$git_root" commit \
                -m "chore(weave): auto-checkpoint $ts${_cp_skip_ci}${trailers}" \
                --no-verify --quiet 2>/dev/null || true
        else
            git -C "$git_root" commit \
                -m "chore(weave): auto-checkpoint $ts${_cp_skip_ci}${trailers}" \
                --no-verify --quiet 2>/dev/null || true
        fi
    fi
}

# ═══════════════════════════════════════════════════════════════════════════
# cmd_sync helpers
# ═══════════════════════════════════════════════════════════════════════════

# _sync_gh — Run bidirectional GitHub sync and re-dump state
_sync_gh() {
    local dry_run="$1"
    local mode="${2:-}"
    local focus_node="${3:-}"
    if ! command -v python3 >/dev/null 2>&1; then
        echo -e "${YELLOW}Warning: python3 not found — cannot run GH sync${NC}" >&2
        return 0
    fi
    echo ""
    local gh_args=()
    [ "$dry_run" = true ] && gh_args+=("--dry-run")
    [ -n "$mode" ] && gh_args+=("--mode=$mode")
    [ -n "$focus_node" ] && gh_args+=("--node=$focus_node")
    # Resolve weave_gh location: follow symlinks to find source dir
    local _wv_pypath="${WV_LIB_DIR:-$SCRIPT_DIR}"
    if [ ! -d "$_wv_pypath/weave_gh" ]; then
        local _wv_real
        _wv_real=$(readlink -f "$_wv_pypath/lib/wv-config.sh" 2>/dev/null || echo "")
        if [ -n "$_wv_real" ]; then
            _wv_pypath=$(dirname "$(dirname "$_wv_real")")
        fi
    fi
    # Use system python to avoid Poetry/venv conflicts with PYTHONPATH
    local _wv_python3
    if [ -n "${VIRTUAL_ENV:-}" ] && [ -x /usr/bin/python3 ]; then
        _wv_python3=/usr/bin/python3
    else
        _wv_python3=python3
    fi
    local _gh_log _gh_rc _retry_cmd
    _gh_log=$(mktemp "${TMPDIR:-/tmp}/weave-gh-sync.XXXXXX")
    # Suite-only hook: stand in for a SUCCEEDING GitHub step so the projection
    # and stamping path below can be exercised at all. Offline the real call
    # fails and this function returns early, which left the code that certifies
    # a sync with no reachable test -- exactly where a failed projection was
    # being certified as a completed sync.
    #
    # TWO gates, both required. Gating the bypass on the variable merely being
    # NONEMPTY meant WV_TEST_SYNC_STUB=typo skipped GitHub entirely: the case
    # set _gh_rc=1, and the GitHub-failure branch below returns 0, so the
    # command reported local success having never contacted GitHub. Without
    # WV_TEST_MODE=1 the hook is ignored and the real sync runs; with it, an
    # unrecognised value is an error, never a bypass.
    local _sync_stub=""
    if [ -n "${WV_TEST_SYNC_STUB:-}" ]; then
        if [ "${WV_TEST_MODE:-}" != "1" ]; then
            echo -e "${YELLOW}⚠ WV_TEST_SYNC_STUB is set but WV_TEST_MODE=1 is not — ignoring it and syncing for real.${NC}" >&2
        else
            case "${WV_TEST_SYNC_STUB}" in
                ok|fail:state|fail:nodes|fail:edges)
                    _sync_stub="${WV_TEST_SYNC_STUB}"
                    ;;
                *)
                    echo -e "${RED}Error: WV_TEST_SYNC_STUB='${WV_TEST_SYNC_STUB}' is not a recognised value (ok, fail:state, fail:nodes, fail:edges)${NC}" >&2
                    rm -f "$_gh_log"
                    return 1
                    ;;
            esac
        fi
    fi
    if [ -n "$_sync_stub" ]; then
        _gh_rc=0
    else
        PYTHONPATH="$_wv_pypath" "$_wv_python3" -m weave_gh "${gh_args[@]}" 2>&1 | tee "$_gh_log"
        _gh_rc=${PIPESTATUS[0]}
    fi
    if [ "$_gh_rc" -ne 0 ]; then
        _retry_cmd="wv sync --gh"
        [ -n "$mode" ] && _retry_cmd="$_retry_cmd --mode=$mode"
        [ -n "$focus_node" ] && _retry_cmd="$_retry_cmd --node=$focus_node"
        echo -e "${YELLOW}⚠${NC} GitHub sync did not complete; local .weave sync is complete." >&2
        echo -e "${YELLOW}  External network/API step remains pending.${NC}" >&2
        if grep -qiE 'api\.github\.com|could not detect GitHub repo|could not resolve host|connection|network|permission|ssh_config|repository' "$_gh_log" 2>/dev/null; then
            echo -e "${YELLOW}  In sandboxed agents, rerun with network/SSH approval: $_retry_cmd${NC}" >&2
        else
            echo -e "${YELLOW}  Retry after resolving the GitHub error: $_retry_cmd${NC}" >&2
        fi
        rm -f "$_gh_log"
        return 0
    fi
    rm -f "$_gh_log"

    # Read the mutation counter BEFORE the dumps, not after. Recorded
    # afterwards, a mutation landing between the dump and the record was
    # certified as synced while sitting in no dump at all -- the graph then
    # looked synced forever, since needs_sync compares against that number.
    # Read first, the recorded value can only UNDERSTATE what the snapshot
    # holds, and understating means "sync again", which is the safe direction.
    local _sync_seq_before
    _sync_seq_before=$(wv_mutation_seq "$WV_DB" 2>/dev/null || echo "")

    # GH sync modifies the in-memory DB — re-dump so git layer captures changes
    local tmp_sql2 tmp_nodes2 tmp_edges2
    tmp_sql2=$(mktemp "$WEAVE_DIR/.state.sql.XXXXXX")
    tmp_nodes2=$(mktemp "$WEAVE_DIR/.nodes.jsonl.XXXXXX")
    tmp_edges2=$(mktemp "$WEAVE_DIR/.edges.jsonl.XXXXXX")
    # Every projection must land before either stamp is written.
    #
    # These were `cmd && [ -s ] && mv || rm -f`, and the trailing `rm` SUCCEEDS
    # -- so a failed projection made the whole line exit 0 and the stamps went
    # down anyway, certifying GitHub mutations that reached no file on disk.
    # The nodes/edges forms are pipelines as well, whose status is jq's, so a
    # failed db_query_json feeding a successful jq also reported success; they
    # run under `pipefail` in a subshell now.
    #
    # `[ -s ]` guards state.sql only. An empty nodes.jsonl or edges.jsonl is a
    # legitimate projection of a graph with no rows of that kind, so requiring
    # bytes there would fail a correct sync.
    local _dump_ok=true
    if dump_state_sql "$WV_DB" "$tmp_sql2" \
        && [ "$_sync_stub" != "fail:state" ] \
        && [ -s "$tmp_sql2" ] \
        && mv "$tmp_sql2" "$WEAVE_DIR/state.sql"; then
        :
    else
        rm -f "$tmp_sql2" 2>/dev/null || true
        _dump_ok=false
    fi
    if ( set -o pipefail; db_query_json "SELECT * FROM nodes;" 2>/dev/null | jq -c '.[]' > "$tmp_nodes2" 2>/dev/null ) \
        && [ "$_sync_stub" != "fail:nodes" ] \
        && mv "$tmp_nodes2" "$WEAVE_DIR/nodes.jsonl"; then
        :
    else
        rm -f "$tmp_nodes2" 2>/dev/null || true
        _dump_ok=false
    fi
    if ( set -o pipefail; db_query_json "SELECT * FROM edges;" 2>/dev/null | jq -c '.[]' > "$tmp_edges2" 2>/dev/null ) \
        && [ "$_sync_stub" != "fail:edges" ] \
        && mv "$tmp_edges2" "$WEAVE_DIR/edges.jsonl"; then
        :
    else
        rm -f "$tmp_edges2" 2>/dev/null || true
        _dump_ok=false
    fi

    if [ "$_dump_ok" != true ]; then
        # A stamp outliving a failed projection is worse than no stamp: it
        # asserts "everything through counter N is on disk" about bytes that
        # were never written, and needs_sync then reads clean forever. Clear
        # both and fail, so the caller syncs again.
        rm -f "$WV_HOT_ZONE/.last_gh_sync" "$WV_HOT_ZONE/.last_gh_sync_seq" 2>/dev/null || true
        echo -e "${RED}Error: could not project the graph to $WEAVE_DIR after GitHub sync — sync stamps cleared, run 'wv sync --gh' again${NC}" >&2
        return 1
    fi

    # Record GH sync timestamp for visibility in `wv status --json`
    date +%s > "$WV_HOT_ZONE/.last_gh_sync" 2>/dev/null || true
    # Record the mutation counter too. A timestamp cannot answer "has the graph
    # changed since this sync": it cannot see a DELETE, and MAX(updated_at) can
    # even move backwards when the deleted row was the newest.
    #
    # Which counter gets recorded is bound to the snapshot that was actually
    # persisted. Unchanged across the dumps means the snapshot IS that graph,
    # so record the exact value; changed means the dumps raced a writer, so
    # record the pre-dump value and let the next sync settle it. Neither branch
    # can record a counter ahead of the bytes on disk.
    local _sync_seq_after _sync_seq_record
    _sync_seq_after=$(wv_mutation_seq "$WV_DB" 2>/dev/null || echo "")
    _sync_seq_record=$(wv_mutation_seq_for_snapshot "$_sync_seq_before" "$_sync_seq_after")
    if [ -n "$_sync_seq_record" ]; then
        printf '%s\n' "$_sync_seq_record" > "$WV_HOT_ZONE/.last_gh_sync_seq" 2>/dev/null || true
    else
        # No readable counter: leave no stamp rather than a wrong one. An
        # absent file already means "needs sync" downstream.
        rm -f "$WV_HOT_ZONE/.last_gh_sync_seq" 2>/dev/null || true
    fi
}

# ═══════════════════════════════════════════════════════════════════════════
# cmd_sync — Persist database to git layer
# ═══════════════════════════════════════════════════════════════════════════

cmd_sync() {
    local gh_sync=false
    local dry_run=false
    local format="text"
    local gh_mode=""
    local gh_node=""
    local force=false
    while [ $# -gt 0 ]; do
        case "$1" in
            --gh) gh_sync=true ;;
            --dry-run) dry_run=true ;;
            --force) force=true ;;
            --json) format="json" ;;
            --json-v2) format="json-v2" ;;
            --mode=*) gh_mode="${1#*=}" ;;
            --mode) shift; gh_mode="${1:-}" ;;
            --node=*) gh_node="${1#*=}" ;;
            --node) shift; gh_node="${1:-}" ;;
        esac
        shift
    done

    # Journal wrapping (only when not called from within another journal op)
    local _sync_journaled=false
    if [ -z "${_WV_IN_JOURNAL:-}" ]; then
        _sync_journaled=true
        journal_begin "sync" "{\"gh\":$gh_sync}"
    fi

    db_ensure
    if ! _should_persist_weave_state; then
        wv_delta_reset "$WV_DB"
        if [ "$format" = "json" ]; then
            jq -n '{"ok": true, "skipped": true, "reason": "empty_uninitialized"}'
        else
            echo -e "${YELLOW}Nothing to sync: graph is empty and .weave is not initialized${NC}" >&2
        fi
        if [ "$_sync_journaled" = true ]; then
            journal_end
            journal_clean
        fi
        return 0
    fi
    mkdir -p "$WEAVE_DIR"

    # Step 1: Dump to disk
    [ "$_sync_journaled" = true ] && journal_step 1 "dump"

    # Atomic sync: write to temp files, then move atomically
    local tmp_sql=$(mktemp "$WEAVE_DIR/.state.sql.XXXXXX")
    local tmp_nodes=$(mktemp "$WEAVE_DIR/.nodes.jsonl.XXXXXX")
    local tmp_edges=$(mktemp "$WEAVE_DIR/.edges.jsonl.XXXXXX")
    trap 'rm -f "$tmp_sql" "$tmp_nodes" "$tmp_edges" 2>/dev/null' EXIT

    # Selective dump: data tables only, excluding FTS index (rebuilt on load)
    dump_state_sql "$WV_DB" "$tmp_sql"

    # Guard: refuse to overwrite state.sql with an empty dump (data loss prevention)
    if [ ! -s "$tmp_sql" ]; then
        echo -e "${RED}✗${NC} Sync aborted: database dump was empty (possible lock contention)" >&2
        rm -f "$tmp_sql" "$tmp_nodes" "$tmp_edges"
        trap - EXIT
        [ "$_sync_journaled" = true ] && journal_end
        return 1
    fi

    # Floor-guard: refuse a drastic shrink (partial/wiped tmpfs over committed truth)
    if ! _sync_floor_guard_ok "$tmp_sql" "$force"; then
        rm -f "$tmp_sql" "$tmp_nodes" "$tmp_edges"
        trap - EXIT
        [ "$_sync_journaled" = true ] && journal_end
        return 1
    fi

    # Also export to JSONL for human readability
    db_query_json "SELECT * FROM nodes;" | jq -c '.[]' > "$tmp_nodes" 2>/dev/null || true
    db_query_json "SELECT * FROM edges;" | jq -c '.[]' > "$tmp_edges" 2>/dev/null || true

    # Publish human-readable projections first and state.sql last. A successful
    # state.sql rename is the durability acknowledgement used by ship/recovery.
    if ! mv "$tmp_nodes" "$WEAVE_DIR/nodes.jsonl" ||
       ! mv "$tmp_edges" "$WEAVE_DIR/edges.jsonl" ||
       ! mv "$tmp_sql" "$WEAVE_DIR/state.sql"; then
        echo -e "${RED}✗${NC} Sync aborted: failed to publish durable graph state" >&2
        rm -f "$tmp_sql" "$tmp_nodes" "$tmp_edges"
        trap - EXIT
        return 1
    fi
    if ! _quality_adjudications_export; then
        echo -e "${RED}✗${NC} Sync aborted: failed to publish quality adjudications" >&2
        return 1
    fi
    trap - EXIT

    # Guard: if anything after this point (auto_checkpoint, git, gh_sync) is
    # interrupted/killed, ensure journal_end still fires so the op isn't left
    # stuck. Cleared on normal exit before explicit journal_end call below.
    [ "$_sync_journaled" = true ] && \
        trap 'journal_end 2>/dev/null; journal_clean 2>/dev/null' EXIT

    if [ "$format" = "json" ]; then
        echo -e "${GREEN}✓${NC} Synced to $WEAVE_DIR" >&2
    else
        echo -e "${GREEN}✓${NC} Synced to $WEAVE_DIR"
    fi

    [ "$_sync_journaled" = true ] && journal_complete 1

    # Auto-checkpoint: WIP git commit after explicit sync
    # Skip when sync is called within a parent journal op (e.g. cmd_ship)
    # to prevent interleaving checkpoint commits during ship
    [ "$_sync_journaled" = true ] && auto_checkpoint "$(date +%s)"

    # Step 2: Bidirectional GitHub sync if --gh flag or WV_GH_SYNC=1
    if [ "$gh_sync" = true ] || [ "${WV_GH_SYNC:-0}" = "1" ]; then
        [ "$_sync_journaled" = true ] && journal_step 2 "gh_sync"
        # A projection failure inside _sync_gh must reach the caller's exit
        # status. Discarding it left `wv sync --gh` reporting success while it
        # had just cleared its own stamps and told the user to run again --
        # and every scripted caller read that 0 as "synced".
        if ! _sync_gh "$dry_run" "$gh_mode" "$gh_node"; then
            [ "$_sync_journaled" = true ] && journal_complete 2
            return 1
        fi
        [ "$_sync_journaled" = true ] && journal_complete 2
    fi

    # Step 3 (or 2 if no GH): Final commit — stage and commit .weave/ if dirty.
    local _sync_commit_step=3
    [ "$gh_sync" != true ] && [ "${WV_GH_SYNC:-0}" != "1" ] && _sync_commit_step=2
    [ "$_sync_journaled" = true ] && journal_step "$_sync_commit_step" "git_commit"

    # Some higher-level operations (notably D3/H3 ship) only want sync to
    # disk, not an additional local .weave commit. Keep standalone wv sync
    # behavior unchanged unless the caller opts out explicitly.
    if [ "${_WV_SKIP_SYNC_COMMIT:-0}" = "1" ]; then
        [ "$_sync_journaled" = true ] && journal_complete "$_sync_commit_step"
        if [ "$_sync_journaled" = true ]; then
            trap - EXIT
            journal_end
            journal_clean
        fi
        if [ "$format" = "json" ]; then
            jq -n --arg path "$WEAVE_DIR" --argjson gh "$gh_sync" \
                '{"ok": true, "synced_to": $path, "gh_synced": $gh}'
        fi
        return 0
    fi

    # Uses --no-verify to bypass pre-commit hook (no active node needed for .weave/-only commits).
    # Only commits if .weave/ is still dirty after auto_checkpoint (e.g., GH sync changed state).
    # Throttled: skip if auto_checkpoint already committed recently (prevents double-commit).
    local git_root
    git_root=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
    if [ -n "$git_root" ] && [ -d "$git_root/.weave" ]; then
        # Hijack guard: same rule as auto_checkpoint — if the caller pre-staged
        # anything outside .weave/, absorbing it into a generic "sync state"
        # commit would silently rewrite their intentional commit. Skip the
        # final commit and warn; .weave/ will be committed on the next sync
        # after the caller finishes their commit. Override: WV_CHECKPOINT_ALL=1.
        if [ "${WV_CHECKPOINT_ALL:-0}" != "1" ]; then
            local _sync_prestaged
            _sync_prestaged=$(git -C "$git_root" diff --cached --name-only 2>/dev/null \
                | grep -v '^\.weave/' || true)
            if [ -n "$_sync_prestaged" ]; then
                {
                    echo "wv: sync-state commit skipped — non-.weave/ files already staged by caller:"
                    echo "$_sync_prestaged" | sed 's/^/  /'
                    echo "wv: finish your commit first, or set WV_CHECKPOINT_ALL=1 to override."
                } >&2
                [ "$_sync_journaled" = true ] && journal_complete "$_sync_commit_step"
                [ "$_sync_journaled" = true ] && journal_end
                return 0
            fi
        fi
        git -C "$git_root" add .weave/ >/dev/null 2>&1 || true
        if ! git -C "$git_root" diff --cached --quiet 2>/dev/null; then
            local _sync_now _sync_branch _sync_local_head _sync_remote_head
            local _sync_last_msg _sync_last_nw_files
            _sync_now=$(date +%s)
            _sync_branch=$(git -C "$git_root" branch --show-current 2>/dev/null || echo "main")
            _sync_local_head=$(git -C "$git_root" rev-parse HEAD 2>/dev/null || echo "")
            _sync_remote_head=$(git -C "$git_root" rev-parse "origin/$_sync_branch" 2>/dev/null || echo "none")
            _sync_last_msg=$(git -C "$git_root" log -1 --format='%s' 2>/dev/null || echo "")
            _sync_last_nw_files=$(git -C "$git_root" diff HEAD~1 HEAD --name-only 2>/dev/null \
                | grep -v '^\.weave/' | grep -v '^$' || true)

            # wv-e937f8: see auto_checkpoint's identical comment above.
            local _sync_skip_ci
            _sync_skip_ci=$(wv_checkpoint_ci_marker "$git_root")

            # Amend if last commit is an unpushed weave-only checkpoint (same rule as auto_checkpoint).
            if [ "$_sync_local_head" != "$_sync_remote_head" ] \
               && [[ "$_sync_last_msg" =~ auto-checkpoint|sync\ state|session-start\ state|pre-compact\ checkpoint ]] \
               && [ -z "$_sync_last_nw_files" ]; then
                git -C "$git_root" commit --amend --no-edit \
                    --no-verify --quiet 2>/dev/null || \
                git -C "$git_root" commit \
                    -m "chore(weave): sync state${_sync_skip_ci}" \
                    --no-verify --quiet 2>/dev/null || true
            else
                git -C "$git_root" commit \
                    -m "chore(weave): sync state${_sync_skip_ci}" \
                    --no-verify --quiet 2>/dev/null || true
            fi
            # Update checkpoint stamp so auto_checkpoint respects this commit
            echo "$_sync_now" > "$WV_HOT_ZONE/.last_checkpoint" 2>/dev/null || true
        fi
    fi

    if [ "$_sync_journaled" = true ]; then
        trap - EXIT  # normal path — clear the safety trap before explicit call
        journal_complete "$_sync_commit_step"
        journal_end
        journal_clean
    fi

    if [ "$format" = "json" ]; then
        jq -n --arg path "$WEAVE_DIR" --argjson gh "$gh_sync" \
            '{"ok": true, "synced_to": $path, "gh_synced": $gh}'
    fi
}

# _load_quality_config — Populate quality_exempt + policy_thresholds from .weave/quality.conf,
# then overlay .weave/quality.local.conf (gitignored personal overrides applied second).
#
# [exempt]      each non-comment, non-blank line is a path pattern. Trailing '/' patterns match
#               directory prefixes (handled in _is_quality_exempt via LIKE). Stale file_metrics
#               rows matching a pattern are also deleted.
# [thresholds]  key = value lines override policy_thresholds defaults (INSERT OR REPLACE). This is
#               the DURABLE config seam: the brain.db is tmpfs and policy_thresholds is NOT in
#               state.sql, so without this a raw-SQL threshold change resets to defaults on the next
#               cold-start/wv load. Committing [thresholds] makes a repo's gate policy (e.g.
#               test_gate = 1) persist. Runs after migrations seed defaults, so config wins.
#               quality.local.conf is applied after quality.conf so local user preferences win.
#
# Safe to call on empty/missing config — clears quality_exempt and returns 0 (thresholds keep their
# seeded defaults when both files are absent).
# _quality_config_signature — content digest of both quality config layers.
# Content, not mtime: a git checkout can restore an older config with a fresh
# mtime, and a same-size edit can leave mtime unchanged within a filesystem's
# timestamp granularity. Missing files hash as '-' so creating or deleting one
# is itself a change.
_quality_config_signature() {
    local sig="" f
    for f in "$WEAVE_DIR/quality.conf" "$WEAVE_DIR/quality.local.conf"; do
        if [ -f "$f" ]; then
            sig="${sig}$(sha256sum "$f" 2>/dev/null | cut -d' ' -f1):"
        else
            sig="${sig}-:"
        fi
    done
    printf '%s' "$sig"
}

# _ensure_quality_config_fresh — reload quality config when the files changed.
#
# wv-6657dd: the quality gate is a SQL trigger reading the quality_exempt TABLE,
# but only _load_quality_config writes that table, and it ran solely from
# cmd_load and _config_enable_test_gate. An exemption committed to quality.conf
# after the last wv load was therefore unenforced, and wv done hard-blocked on a
# path the project had already exempted — a false GraphPolicyViolation that
# looks exactly like real debt. The stamp lives beside the DB in the hot zone,
# so a rebuilt brain.db loses it and reloads, keeping the two in step.
_ensure_quality_config_fresh() {
    [ -n "${WV_HOT_ZONE:-}" ] || return 0
    [ -n "${WV_DB:-}" ] && [ -f "$WV_DB" ] || return 0
    local stamp="$WV_HOT_ZONE/.quality_conf_sig"
    local current previous=""
    current=$(_quality_config_signature)
    [ -f "$stamp" ] && previous=$(cat "$stamp" 2>/dev/null || printf '')
    [ "$current" = "$previous" ] && return 0
    _load_quality_config || return 0
}

_load_quality_config() {
    local config_file="$WEAVE_DIR/quality.conf"
    local local_config_file="$WEAVE_DIR/quality.local.conf"

    # Always clear and repopulate so removed exemptions take effect on next load.
    sqlite3 "$WV_DB" "DELETE FROM quality_exempt;" 2>/dev/null || true

    # Layer 1: repo-committed quality.conf
    _parse_quality_conf_file "$config_file"

    # Capture committed test_gate before the local layer can override it.
    # test_gate=2 (block) is a team-wide hard gate; no individual can downgrade it via
    # their local file — mirrors --skip-verification (suppresses warn, never block).
    local committed_test_gate
    committed_test_gate=$(sqlite3 "$WV_DB" \
        "SELECT CAST(value AS INTEGER) FROM policy_thresholds WHERE key='test_gate';" 2>/dev/null || echo "")

    # Layer 2: gitignored user-per-repo override (quality.local.conf applied after so it wins)
    _parse_quality_conf_file "$local_config_file"

    # Guard: committed test_gate=2 (block) cannot be downgraded by the local layer.
    if [ "$committed_test_gate" = "2" ]; then
        sqlite3 "$WV_DB" \
            "INSERT OR REPLACE INTO policy_thresholds(key, value) VALUES('test_gate', 2);" \
            2>/dev/null || true
    fi

    # wv-6657dd: stamp what was just loaded so _ensure_quality_config_fresh can
    # tell a current table from a stale one. Written here rather than in the
    # freshness check so every load path — cmd_load, the test-gate config
    # command — leaves the stamp consistent with the table.
    if [ -n "${WV_HOT_ZONE:-}" ]; then
        _quality_config_signature > "$WV_HOT_ZONE/.quality_conf_sig" 2>/dev/null || true
    fi
}

# _quality_conf_declares_exempt — does the CONFIG (not the table) exempt this path?
#
# wv-6657dd: the safety net behind _ensure_quality_config_fresh. If a gate block
# ever survives the reload, the reporter uses this to say so plainly rather than
# presenting stale policy as real debt — the failure mode that previously cost a
# refactor of an already-exempt file. Mirrors the table's matching rule: a
# trailing '/' is a directory prefix, everything else is an exact path.
_quality_conf_declares_exempt() {
    local path="$1" file line pattern section
    [ -n "$path" ] || return 1
    for file in "$WEAVE_DIR/quality.conf" "$WEAVE_DIR/quality.local.conf"; do
        [ -f "$file" ] || continue
        section=""
        while IFS= read -r line; do
            if [[ "$line" =~ ^\[([a-z_]+)\] ]]; then
                section="${BASH_REMATCH[1]}"
                continue
            fi
            [ "$section" = "exempt" ] || continue
            pattern="${line%%#*}"
            pattern="${pattern// /}"
            [ -z "$pattern" ] && continue
            case "$pattern" in
                */) [[ "$path" == "$pattern"* ]] && return 0 ;;
                *) [ "$path" = "$pattern" ] && return 0 ;;
            esac
        done < "$file"
    done
    return 1
}

# _parse_quality_conf_file — Internal helper: parse one quality conf file into DB.
# Shared by _load_quality_config (called for quality.conf then quality.local.conf).
# Does NOT clear quality_exempt — caller is responsible for the initial clear.
_parse_quality_conf_file() {
    local file="$1"
    [ ! -f "$file" ] && return 0
    local section="" pattern
    while IFS= read -r line; do
        if [[ "$line" =~ ^\[([a-z_]+)\] ]]; then
            section="${BASH_REMATCH[1]}"
            continue
        fi
        if [ "$section" = "exempt" ]; then
            pattern="${line%%#*}"
            pattern="${pattern// /}"
            [ -z "$pattern" ] && continue
            local pat_esc
            pat_esc=$(echo "$pattern" | sed "s/'/''/g")
            sqlite3 "$WV_DB" "INSERT OR IGNORE INTO quality_exempt(path_pattern) VALUES('$pat_esc');" 2>/dev/null || true
            if [[ "$pattern" == */ ]]; then
                sqlite3 "$WV_DB" "DELETE FROM file_metrics WHERE path LIKE '${pat_esc}%';" 2>/dev/null || true
            else
                sqlite3 "$WV_DB" "DELETE FROM file_metrics WHERE path = '$pat_esc';" 2>/dev/null || true
            fi
        elif [ "$section" = "thresholds" ]; then
            local kv key val
            kv="${line%%#*}"
            key="${kv%%=*}"; key="${key// /}"
            val="${kv#*=}"; val="${val// /}"
            [ -z "$key" ] && continue
            [ "$key" = "$kv" ] && continue
            [[ "$key" =~ ^[a-z_]+$ ]] || continue
            [[ "$val" =~ ^-?[0-9]+(\.[0-9]+)?$ ]] || continue
            sqlite3 "$WV_DB" "INSERT OR REPLACE INTO policy_thresholds(key, value) VALUES('$key', $val);" 2>/dev/null || true
        fi
    done < "$file"
}

# ═══════════════════════════════════════════════════════════════════════════
# cmd_load — Load database from git layer
# ═══════════════════════════════════════════════════════════════════════════

cmd_load() {
    # Security: create hot zone 0700 so sibling users cannot read state
    # (see wv-db.sh db_init; same rationale).
    local prev_umask
    prev_umask=$(umask)
    umask 077
    mkdir -p "$WV_HOT_ZONE"
    chmod 700 "$WV_HOT_ZONE" 2>/dev/null || true
    umask "$prev_umask"

    # Pre-flight: flush live DB → state.sql before loading to prevent status
    # regression when in-session wv done closures were throttled and not yet synced.
    auto_sync --force 2>/dev/null || true

    if [ -f "$WEAVE_DIR/state.sql" ]; then
        # Atomic load: import to temp DB first, validate, then replace
        local tmp_db=$(mktemp "$WV_HOT_ZONE/.brain.db.XXXXXX")
        trap 'rm -f "$tmp_db" 2>/dev/null' EXIT

        # Import ignoring non-zero exit: sqlite3 exits 1 on benign runtime errors
        # (e.g. malformed JSON in a generated column during INSERT) even when all
        # rows are imported. Validate the DB state instead of trusting the exit code.
        strip_unistr < "$WEAVE_DIR/state.sql" | sqlite3 "$tmp_db" 2>/dev/null; true
        if sqlite3 "$tmp_db" "SELECT COUNT(*) FROM nodes;" >/dev/null 2>&1; then
            # Validate edges table exists and has data
            local edge_count
            edge_count=$(sqlite3 "$tmp_db" "SELECT COUNT(*) FROM edges;" 2>/dev/null || echo "-1")
            if [ "$edge_count" = "-1" ]; then
                echo -e "${RED}Warning: edges table missing or corrupt in state.sql${NC}" >&2
                echo -e "${YELLOW}  Graph structure may be incomplete. Run wv sync --gh to rebuild.${NC}" >&2
            elif [ "$edge_count" = "0" ]; then
                local node_count
                node_count=$(sqlite3 "$tmp_db" "SELECT COUNT(*) FROM nodes;" 2>/dev/null || echo "0")
                if [ "$node_count" -gt 2 ]; then
                    echo -e "${YELLOW}Warning: ${node_count} nodes but 0 edges — possible data loss${NC}" >&2
                    echo -e "${YELLOW}  Consider running wv sync --gh to rebuild edges.${NC}" >&2
                fi
            fi
            # Stale state guard: warn if node count drops significantly
            local new_count old_count
            new_count=$(sqlite3 "$tmp_db" "SELECT COUNT(*) FROM nodes;" 2>/dev/null || echo "0")
            old_count=$(sqlite3 "$WV_DB" "SELECT COUNT(*) FROM nodes;" 2>/dev/null || echo "0")
            if [ "$old_count" -gt 5 ] && [ "$new_count" -gt 0 ]; then
                local drop_pct=$(( (old_count - new_count) * 100 / old_count ))
                if [ "$drop_pct" -gt 50 ]; then
                    echo -e "${YELLOW}⚠ Warning: node count drops from ${old_count} → ${new_count} (${drop_pct}% loss)${NC}" >&2
                    echo -e "${YELLOW}  state.sql may be stale. Existing DB kept as backup: ${WV_DB}.bak${NC}" >&2
                    cp "$WV_DB" "${WV_DB}.bak" 2>/dev/null || true
                fi
            fi
            # Status regression guard: warn if state.sql has more active nodes than current DB
            # This catches the case where wv done closures happened after the last wv sync
            local new_active old_done new_done
            new_active=$(sqlite3 "$tmp_db" "SELECT COUNT(*) FROM nodes WHERE status='active';" 2>/dev/null || echo "0")
            old_done=$(sqlite3 "$WV_DB" "SELECT COUNT(*) FROM nodes WHERE status='done';" 2>/dev/null || echo "0")
            new_done=$(sqlite3 "$tmp_db" "SELECT COUNT(*) FROM nodes WHERE status='done';" 2>/dev/null || echo "0")
            if [ "$old_done" -gt "$new_done" ]; then
                local lost=$(( old_done - new_done ))
                echo -e "${YELLOW}⚠ Warning: state.sql has ${lost} fewer 'done' node(s) than current DB${NC}" >&2
                echo -e "${YELLOW}  Recent wv done closures may not have been synced — run wv sync before wv load${NC}" >&2
                echo -e "${YELLOW}  Current DB backed up: ${WV_DB}.bak${NC}" >&2
                cp "$WV_DB" "${WV_DB}.bak" 2>/dev/null || true
            fi

            # Validation passed, replace existing DB
            rm -f "$WV_DB" "$WV_DB-wal" "$WV_DB-shm"
            mv "$tmp_db" "$WV_DB"
            trap - EXIT
        else
            rm -f "$tmp_db"
            trap - EXIT
            echo -e "${RED}Error: state.sql is corrupt, keeping existing database${NC}" >&2
            return 1
        fi
        
        # Re-apply performance pragmas (scaled to system RAM, capped to hot zone)
        validate_hot_size
        local pragmas
        read -r WV_CACHE WV_MMAP <<< "$(select_pragmas)"
        local max_pages=$(( WV_HOT_SIZE * 256 ))
        sqlite3 "$WV_DB" <<EOF >/dev/null
PRAGMA journal_mode = WAL;
PRAGMA busy_timeout = 5000;
PRAGMA synchronous = NORMAL;
PRAGMA foreign_keys = ON;
PRAGMA cache_size = $WV_CACHE;
PRAGMA mmap_size = $WV_MMAP;
PRAGMA temp_store = MEMORY;
PRAGMA max_page_count = $max_pages;
EOF
        # Migrate old schema if needed (adds weight/context/created_at to edges)
        db_migrate_edges
        # Migrate alias column (Sprint 3)
        db_migrate_alias
        # Migrate to virtual columns (Tier 1)
        db_migrate_virtual_columns
        # Migrate quality policy tables + trigger (language-aware thresholds, exempt paths).
        # Triggers are excluded from state.sql selective dump and must be reinstalled on load.
        db_migrate_policy_tables
        db_migrate_language_trigger
        db_migrate_quality_exempt
        db_migrate_test_results
        # MUST run last among policy migrations — authoritative trigger via emitter.
        db_migrate_test_gate
        # Rebuild FTS index from node data (selective dump excludes FTS tables)
        db_rebuild_fts
        # Initialize delta change tracking on the freshly loaded DB (idempotent).
        # Triggers are not stored in state.sql (selective dump excludes them),
        # so they must be reinstalled after every load.
        wv_delta_init "$WV_DB"

        # Delta replay — multi-agent merge
        #
        # After loading state.sql (the last full snapshot from any agent), apply
        # all delta files from .weave/deltas/ in chronological order. Each delta
        # file contains INSERT OR REPLACE / DELETE statements emitted by
        # wv_delta_changeset on a previous sync cycle (by this or another agent).
        # Replaying them brings the DB forward to the union of all agents' changes.
        #
        # Ordering: files are sorted by filename. The prefix format is
        # <epoch>-<subsec>-<seq>-..., so lexical sort preserves epoch-seconds,
        # then subsecond order, then per-process same-timestamp emission order.
        # This gives deterministic same-second replay while keeping the first
        # field compatible with the prune-epoch filter below.
        #
        # FK OFF during replay: a delta from agent B may INSERT an edge that
        # references a node only present in a later-sorted delta from agent A.
        # Disabling FK constraints for the replay batch avoids false rejections.
        # PRAGMA foreign_keys is a no-op inside a transaction, so it must be
        # applied outside any transaction wrapper.
        #
        # Prune epoch filter: cmd_prune writes .weave/.prune_epoch (Unix timestamp)
        # after deleting nodes. Deltas older than that epoch contain INSERT OR REPLACE
        # statements for now-pruned nodes — replaying them would resurrect deleted
        # nodes. Skip any delta file whose epoch prefix predates the prune epoch.
        if [ -d "$WEAVE_DIR/deltas" ]; then
            local delta_files delta_count=0
            local prune_epoch=0
            if [ -f "$WEAVE_DIR/.prune_epoch" ]; then
                prune_epoch=$(cat "$WEAVE_DIR/.prune_epoch" 2>/dev/null || echo "0")
            fi
            # Applied-deltas manifest (.weave/.applied_deltas): one basename per line.
            # Keep writing it for observability, but do NOT trust it to skip replay.
            #
            # We have observed real graph regressions where state.sql and the live DB
            # fell behind deltas that the manifest effectively treated as already
            # incorporated. Full replay is idempotent by design, so correctness wins:
            # always replay every non-pruned delta on load until a stronger trust model
            # exists than mtime comparisons plus a local manifest.
            #
            # Authoritative-drop rejected (wv-c7b34e, D-4 rec-4): "drop live rows
            # absent from state.sql ∪ replayed deltas" is either a no-op or data loss.
            # The pre-flight auto_sync --force puts every live row into state.sql
            # before the rebuild, so when the flush succeeds the absent set is empty;
            # when the flush fails or is floor-guarded, the absent rows are exactly
            # the unsynced work most needing preservation. Absence is not a deletion
            # signal — deletion intent travels via tombstones (prune_epoch + immediate
            # state.sql dump in cmd_delete/cmd_prune, DELETE statements in deltas).
            local manifest="$WEAVE_DIR/.applied_deltas"
            # Truncate manifest before replay. If replay fails, the manifest stays
            # empty — guaranteeing all deltas are retried on the next wv load.
            # On success, the manifest is written post-replay with the exact delta
            # basenames replayed during this load. Truncate-before is correct: the window
            # where the manifest is empty (between truncation and successful write)
            # only matters if the process is killed mid-replay, in which case we
            # want a retry anyway.
            : > "$manifest"
            # Sort by filename (epoch prefix) for causal ordering across agents
            delta_files=$(find "$WEAVE_DIR/deltas" -name '*.sql' -printf '%f\t%p\n' 2>/dev/null | sort | cut -f2)
            if [ -n "$delta_files" ]; then
                local skipped=0 skipped_legacy=0 snapshot_max_epoch=0
                snapshot_max_epoch=$(sqlite3 "$WV_DB" "
                    SELECT COALESCE(MAX(
                        CASE
                            WHEN typeof(updated_at) IN ('integer','real') THEN CAST(updated_at AS INTEGER)
                            WHEN CAST(updated_at AS TEXT) != ''
                                 AND CAST(updated_at AS TEXT) NOT GLOB '*[^0-9]*'
                            THEN CAST(updated_at AS INTEGER)
                            ELSE CAST(strftime('%s', updated_at) AS INTEGER)
                        END
                    ), 0)
                    FROM nodes;
                " 2>/dev/null || echo "0")
                # Collect replayable delta paths into an array, then replay in a
                # single batched sqlite3 call instead of N subprocesses.
                local -a new_deltas=()
                local -a new_names=()
                while IFS= read -r delta; do
                    if [ -s "$delta" ]; then
                        # bash builtins replace basename + grep -oP subprocesses
                        local delta_name delta_ts
                        delta_name="${delta##*/}"
                        delta_ts="${delta_name%%-*}"
                        # Prune epoch filter
                        if [ "$delta_ts" -le "$prune_epoch" ] 2>/dev/null; then
                            skipped=$((skipped + 1))
                            continue
                        fi
                        # Legacy back-catalog delta guard: pre-wv-875c72 node
                        # deltas used unconditional INSERT OR REPLACE. If such a
                        # delta predates the loaded checkpoint, replaying it can
                        # revert newer state.sql. Current generated deltas use
                        # ON CONFLICT with a freshness WHERE and stay replayable.
                        if grep -qiE '^INSERT OR REPLACE INTO nodes' "$delta" 2>/dev/null \
                            && [ "${delta_ts:-0}" -le "${snapshot_max_epoch:-0}" ] 2>/dev/null; then
                            skipped_legacy=$((skipped_legacy + 1))
                            continue
                        fi
                        # Pre-validate: a valid delta has at least one replayable
                        # SQL statement. A file whose only content is comment lines
                        # is an intentional no-op — the changeset generator emits
                        # "-- no-op UPDATE on node/edge ..." (wv-delta.sh) when an
                        # UPDATE would change nothing — so it is benign and skipped
                        # silently. Only non-comment, non-blank garbage (e.g. a file
                        # truncated mid-fsync) is genuinely corrupt.
                        if ! grep -qiE "^(INSERT|UPDATE|REPLACE|DELETE|BEGIN|PRAGMA)" "$delta" 2>/dev/null; then
                            if grep -qvE '^[[:space:]]*(--.*)?$' "$delta" 2>/dev/null; then
                                echo -e "${YELLOW}⚠ Skipped corrupt delta: ${delta_name}${NC}" >&2
                            fi
                            continue
                        fi
                        new_deltas+=("$delta")
                        new_names+=("$delta_name")
                        delta_count=$((delta_count + 1))
                    fi
                done <<< "$delta_files"
                if [ "$delta_count" -gt 0 ]; then
                    # Single batched sqlite3 call: wrap FK toggle + all deltas in one
                    # transaction — per-statement auto-commit costs ~1 fsync each;
                    # a single transaction reduces N commits to 1.
                    #
                    # .bail on: abort on first error and return non-zero exit code,
                    # which rolls back the transaction and prevents partial replay.
                    # Manifest is only written after this succeeds.
                    #
                    # No FTS filter: wv_delta_changeset never emits nodes_fts or
                    # sqlite_sequence rows. Filtering multiline SQL by line prefix
                    # is unsafe against data values that start with those strings.
                    local replay_rc=0
                    {
                        echo ".bail on"
                        echo "PRAGMA foreign_keys = OFF;"
                        echo "BEGIN;"
                        cat "${new_deltas[@]}"
                        echo "COMMIT;"
                        echo "PRAGMA foreign_keys = ON;"
                    } | sqlite3 "$WV_DB" || replay_rc=$?
                    if [ "$replay_rc" -ne 0 ]; then
                        # state.sql was already imported and the DB is valid.
                        # Warn but continue — returning non-zero here would cause
                        # callers that check $? to treat a successful load as failed.
                        # Don't update manifest: failed deltas will be retried on the
                        # next wv load (manifest was truncated to empty at line 601,
                        # so all deltas re-qualify if this load fails).
                        echo -e "${YELLOW}⚠ Delta replay failed (rc=$replay_rc) — will retry on next load${NC}" >&2
                        sqlite3 "$WV_DB" "PRAGMA foreign_keys = ON;" 2>/dev/null || true
                    else
                        # Manifest written only after successful replay
                        printf '%s\n' "${new_names[@]}" >> "$manifest"
                        # Reset the change log after replay: the INSERT/UPDATE statements
                        # fired the triggers, so _warp_changes now contains every
                        # replayed operation. Without this reset, the next auto_sync
                        # would emit a delta containing all of them — snowballing the
                        # same changes across all agents indefinitely.
                        wv_delta_reset "$WV_DB"
                        # Re-derive nodes_fts AFTER replay, not only before it.
                        #
                        # db_rebuild_fts ran earlier against the state.sql import, so
                        # the index was consistent at that point. Replay then applies
                        # INSERT OR REPLACE INTO nodes. For a TEXT-PRIMARY-KEY table
                        # the rowid is implicit, so REPLACE deletes the conflicting
                        # row (new rowid) — and SQLite only fires DELETE triggers for
                        # that implicit delete when recursive_triggers is ON, which it
                        # is not (it is set nowhere in this codebase). So nodes_ad
                        # never runs, nodes_ai does, and every replaced node strands an
                        # orphaned nodes_fts entry at its old rowid.
                        #
                        # Orphans are invisible to both PRAGMA integrity_check and
                        # FTS5 'integrity-check' — they surface only later, as
                        # SQLITE_CORRUPT from the nodes_au sync trigger on ANY
                        # UPDATE to nodes, which takes out wv done graph-wide
                        # (wv-44993d 2026-08-08, again 2026-08-27; root cause wv-d2e6c6).
                        #
                        # 'rebuild' re-derives from nodes for an external-content
                        # table, so it discards orphans outright. Idempotent, and only
                        # paid when deltas actually replayed.
                        db_rebuild_fts
                        echo -e "${GREEN}✓${NC} Replayed $delta_count delta(s)" >&2
                    fi
                fi
                sqlite3 "$WV_DB" "PRAGMA foreign_keys = ON;" 2>/dev/null || true
                if [ "$skipped" -gt 0 ]; then
                    echo -e "${YELLOW}ℹ${NC} Skipped $skipped pre-prune delta(s)" >&2
                fi
                if [ "$skipped_legacy" -gt 0 ]; then
                    echo -e "${YELLOW}ℹ${NC} Skipped $skipped_legacy legacy pre-checkpoint delta(s)" >&2
                fi
            fi
        fi

        echo -e "${GREEN}✓${NC} Loaded from $WEAVE_DIR/state.sql" >&2
    else
        db_init
        # Initialize delta change tracking (idempotent)
        wv_delta_init "$WV_DB"
        echo -e "${YELLOW}No state.sql found, initialized empty database${NC}" >&2
    fi

    if ! _quality_adjudications_import; then
        echo -e "${RED}Error: failed to restore quality adjudications${NC}" >&2
        return 1
    fi

    # Seed metadata.trails[0] from any legacy metadata.breadcrumbs (trails epic D1).
    # Runs after delta replay so it also covers nodes brought in by deltas.
    # Idempotent: only acts where breadcrumbs is present and trails is absent;
    # non-destructive (the legacy breadcrumbs key is left intact for one release).
    _migrate_trails_seed

    # Rename the legacy .weave/breadcrumbs.md rendered file to trails.md (D1).
    _migrate_trails_file

    # Load quality exemptions from .weave/quality.toml (if present) into brain.db.
    _load_quality_config

    # Save session start snapshot for activity summary
    _save_session_snapshot
}

# _migrate_trails_seed — back-fill metadata.trails[] from legacy metadata.breadcrumbs.
# Set-based UPDATE (one statement, no per-node loop). json(json_extract(...))
# re-parses the extracted object so json_array embeds it as an object element,
# not a quoted string. Safe to run on every load.
_migrate_trails_seed() {
    db_query "
        UPDATE nodes
        SET metadata = json_set(metadata, '\$.trails', json_array(json(json_extract(metadata, '\$.breadcrumbs'))))
        WHERE json_extract(metadata, '\$.breadcrumbs') IS NOT NULL
          AND json_extract(metadata, '\$.trails') IS NULL;
    " 2>/dev/null || true
}

# _migrate_trails_file — rename the legacy rendered file .weave/breadcrumbs.md to
# .weave/trails.md (trails epic D1). Only acts when the legacy file exists and the
# new file does not, so it is idempotent and never clobbers a fresh trails.md.
# Guarded by _should_persist_weave_state so it never materializes WEAVE_DIR for
# uninitialized repos or hooks running from $HOME.
_migrate_trails_file() {
    _should_persist_weave_state || return 0
    local legacy="$WEAVE_DIR/breadcrumbs.md"
    local current="$WEAVE_DIR/trails.md"
    if [ -f "$legacy" ] && [ ! -f "$current" ]; then
        mv "$legacy" "$current" 2>/dev/null || true
    fi
}

# ═══════════════════════════════════════════════════════════════════════════
# cmd_clean_ghosts — Delete ghost edges referencing non-existent nodes
# ═══════════════════════════════════════════════════════════════════════════

cmd_clean_ghosts() {
    local dry_run=false

    while [ $# -gt 0 ]; do
        case "$1" in
            --dry-run) dry_run=true ;;
        esac
        shift
    done

    # Count ghost edges
    local ghost_count
    ghost_count=$(db_query "
        SELECT COUNT(*) FROM edges
        WHERE source NOT IN (SELECT id FROM nodes)
        OR target NOT IN (SELECT id FROM nodes);
    ")

    if [ "$ghost_count" -eq 0 ]; then
        echo "No ghost edges found."
        return 0
    fi

    if [ "$dry_run" = true ]; then
        echo -e "${YELLOW}Would delete $ghost_count ghost edge(s):${NC}"
        db_query "
            SELECT e.source, e.type, e.target FROM edges e
            WHERE e.source NOT IN (SELECT id FROM nodes)
            OR e.target NOT IN (SELECT id FROM nodes);
        " | while IFS='|' read -r src etype tgt; do
            echo "  $src --[$etype]--> $tgt"
        done
        return 0
    fi

    # Delete ghost edges
    db_query "
        DELETE FROM edges
        WHERE source NOT IN (SELECT id FROM nodes)
        OR target NOT IN (SELECT id FROM nodes);
    "

    echo -e "${GREEN}✓${NC} Deleted $ghost_count ghost edge(s)"
}

# ═══════════════════════════════════════════════════════════════════════════
# cmd_commit_refs — Audit metadata.commit / metadata.commits provenance refs
#
# `wv done` records the SHAs whose messages carry the node's Weave-ID
# (_store_node_commits) and unions the child SHAs onto the parent epic
# (_aggregate_epic_commits). Both read the working clone at close time, so a
# ref that is later amended, soft-reset, rebased or gc'd goes stale in place
# and nothing notices. Finding wv-55d2de measured 97 stale refs across 118
# nodes, the bulk of them auto-checkpoint commits a later checkpoint replaced.
#
# Classes are decided by reachability, not by existence alone:
#   reachable   — an ancestor of the pushed branch. Durable provenance.
#   pending     — reachable from some local ref but not yet from the pushed
#                 branch: unpushed work, or work on another branch. NOT an
#                 orphan — pushing or merging turns it into `reachable`.
#   unreachable — the object exists but no ref reaches it: superseded by an
#                 amend, reset or rebase. Orphan.
#   missing     — not in the object database at all: gc'd, or recorded in a
#                 different clone. Orphan.
#
# Auto-checkpoint commits stay recorded on purpose. While one survives it is
# real provenance, and _node_commit_shas already sorts checkpoints behind
# regular commits so the primary ref is never a checkpoint when a regular
# commit exists. They are reported as their own kind instead, so the dominant
# orphan population is visible without a second query.
# ═══════════════════════════════════════════════════════════════════════════

# _commit_refs_pushed_ref — the ref that "pushed" means for this clone.
# Prefers the configured upstream, then the conventional origin heads.
# Returns 1 when no pushed ref exists (a clone with no remote), which puts the
# sweep in degraded mode rather than reporting every local commit as an orphan.
_commit_refs_pushed_ref() {
    local up cand
    up=$(git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null || echo "")
    if [ -n "$up" ] && git rev-parse --verify --quiet "$up" >/dev/null 2>&1; then
        printf '%s\n' "$up"
        return 0
    fi
    for cand in origin/main origin/master; do
        if git rev-parse --verify --quiet "$cand" >/dev/null 2>&1; then
            printf '%s\n' "$cand"
            return 0
        fi
    done
    return 1
}

# _commit_refs_keep_live <json-array> — drop SHAs no ref reaches any more.
#
# "Live" here means reachable from ANY ref (or HEAD), not "pushed": a commit on
# an unmerged branch is real provenance and must survive. That is the same
# boundary the sweep draws between `pending` and `unreachable`, so the filter
# and the report never disagree about a given SHA.
#
# Two git calls regardless of list length — `wv done` on a large epic
# aggregates dozens of child refs, and a per-SHA merge-base/--contains probe
# turned that into a per-close pile of subprocesses.
#
# Fails OPEN: when git cannot answer at all (no git, no repo, no HEAD) the
# input is returned untouched. Silently discarding real provenance because the
# clone was unavailable is a worse outcome than carrying a stale ref, which
# `wv commit-refs` reports and `wv commit-refs --prune` removes deliberately.
_commit_refs_keep_live() {
    local shas_json="$1"
    local live_file kept

    command -v git >/dev/null 2>&1 || { printf '%s' "$shas_json"; return 0; }
    git rev-parse --git-dir >/dev/null 2>&1 || { printf '%s' "$shas_json"; return 0; }
    git rev-parse --verify --quiet HEAD >/dev/null 2>&1 || { printf '%s' "$shas_json"; return 0; }

    live_file=$(mktemp "${TMPDIR:-/tmp}/wv-live-refs.XXXXXX") || { printf '%s' "$shas_json"; return 0; }
    if ! git rev-list --all HEAD > "$live_file" 2>/dev/null; then
        rm -f "$live_file"
        printf '%s' "$shas_json"
        return 0
    fi

    # Recorded refs may be abbreviated, so each is resolved to a full OID before
    # being looked up in the reachable set.
    kept=$(printf '%s' "$shas_json" | jq -r '.[]? // empty' 2>/dev/null \
        | git cat-file --batch-check='%(objectname) %(objecttype)' --buffer 2>/dev/null \
        | paste -d' ' <(printf '%s' "$shas_json" | jq -r '.[]? // empty' 2>/dev/null) - \
        | awk -v live="$live_file" '
            BEGIN { while ((getline l < live) > 0) { L[l] = 1 } }
            NF >= 3 && $3 == "commit" && ($2 in L) { print $1 }
          ' \
        | jq -R . | jq -sc . 2>/dev/null)
    rm -f "$live_file"

    [ -n "$kept" ] || { printf '%s' "$shas_json"; return 0; }
    printf '%s' "$kept"
}

# _commit_refs_scan <workdir> <pushed_ref> — classify every recorded ref.
#
# Writes "<node_id>\t<recorded_ref>\t<class>" to <workdir>/rows. Recorded refs
# may be abbreviated (7 of them are, historically), so every ref is resolved
# through `git cat-file --batch-check` first and classified on the full OID
# while still being REPORTED in the form the node actually stores — a prune
# that matched on the resolved form would not match the stored string.
_commit_refs_scan() {
    local workdir="$1" pushed_ref="$2"

    db_query "
        SELECT n.id || char(9) || j.value
        FROM nodes n, json_each(json_extract(n.metadata, '\$.commits')) j
        WHERE json_valid(n.metadata)
          AND json_type(n.metadata, '\$.commits') = 'array'
          AND j.type = 'text'
        UNION
        SELECT n.id || char(9) || json_extract(n.metadata, '\$.commit')
        FROM nodes n
        WHERE json_valid(n.metadata)
          AND json_type(n.metadata, '\$.commit') = 'text';
    " 2>/dev/null | awk -F'\t' '
        # Structural filter ONLY. A hex-width pattern here silently DROPPED every
        # ref it could not parse: junk vanished instead of being reported missing,
        # and a SHA-256 repository (64-char OIDs) dropped every ref it had, so the
        # sweep reported refs:0 orphaned:0 and doctor read it as clean. Let git
        # decide what resolves; anything it cannot resolve is classified missing.
        # Whitespace is still excluded because cat-file and the TSV are both
        # line- and field-delimited, and a ref containing either would misalign
        # the recorded-to-resolved pairing rather than merely fail to resolve.
        NF == 2 && $2 != "" && $2 !~ /[ \t]/
    ' | sort -u > "$workdir/pairs"

    : > "$workdir/rows"
    [ -s "$workdir/pairs" ] || return 0

    cut -f2 "$workdir/pairs" | sort -u > "$workdir/refs"

    # recorded -> resolved OID (or the "missing" marker), order-preserving.
    git cat-file --batch-check='%(objectname) %(objecttype)' --buffer \
        < "$workdir/refs" > "$workdir/check" 2>/dev/null || : > "$workdir/check"
    if [ "$(wc -l < "$workdir/check")" != "$(wc -l < "$workdir/refs")" ]; then
        # cat-file could not answer for this clone; treat every ref as unresolved
        # rather than silently mis-pairing lines against each other.
        awk '{print $1 " - missing"}' "$workdir/refs" > "$workdir/resolved"
    else
        paste -d' ' "$workdir/refs" "$workdir/check" > "$workdir/resolved"
    fi

    git rev-list --all HEAD 2>/dev/null | sort -u > "$workdir/anyref"
    if [ -n "$pushed_ref" ]; then
        git rev-list "$pushed_ref" 2>/dev/null | sort -u > "$workdir/pushed"
    else
        : > "$workdir/pushed"
    fi

    awk -v resolved="$workdir/resolved" -v anyref="$workdir/anyref" -v pushed="$workdir/pushed" '
        BEGIN {
            FS = "\t"
            while ((getline line < resolved) > 0) {
                n = split(line, f, " ")
                if (n >= 3 && f[3] == "commit") { OID[f[1]] = f[2] }
                else { OID[f[1]] = "" }
            }
            while ((getline line < anyref) > 0) { A[line] = 1 }
            while ((getline line < pushed) > 0) { P[line] = 1 }
        }
        {
            oid = OID[$2]
            if (oid == "")        cls = "missing"
            else if (oid in P)    cls = "reachable"
            else if (oid in A)    cls = "pending"
            else                  cls = "unreachable"
            print $1 "\t" $2 "\t" cls
        }
    ' "$workdir/pairs" > "$workdir/rows"
}

# _commit_refs_print_detail <workdir> <rows-file> — print one line per ref,
# tagged checkpoint / regular / unknown.
#
# Subjects are resolved in ONE batched `git log --stdin` rather than a call per
# ref: `--all` over this repo's own graph is ~1900 refs, and the per-ref form
# took 21s where the batched form takes under a second.
# _commit_refs_kinds <workdir> <rows-file> — emit "<recorded_ref>\t<kind>",
# kind being checkpoint | regular | unknown. Subjects are resolved in ONE
# batched `git log --stdin`; a per-ref call took 21s over this graph.
_commit_refs_kinds() {
    local workdir="$1" src="$2"

    awk 'NF >= 3 && $3 == "commit" { print $1 "\t" $2 }' "$workdir/resolved" > "$workdir/oidmap"
    awk -F'\t' -v oidmap="$workdir/oidmap" '
        BEGIN { while ((getline line < oidmap) > 0) { split(line, f, "\t"); M[f[1]] = f[2] } }
        { if ($2 in M) print M[$2] }
    ' "$src" | sort -u > "$workdir/kind_oids"

    : > "$workdir/kind_subjects"
    if [ -s "$workdir/kind_oids" ]; then
        git log --no-walk --stdin --format='%H%x09%s' < "$workdir/kind_oids" \
            > "$workdir/kind_subjects" 2>/dev/null || : > "$workdir/kind_subjects"
    fi

    awk -F'\t' -v oidmap="$workdir/oidmap" -v subjects="$workdir/kind_subjects" '
        BEGIN {
            while ((getline line < oidmap) > 0)   { split(line, f, "\t"); M[f[1]] = f[2] }
            while ((getline line < subjects) > 0) { split(line, f, "\t"); S[f[1]] = f[2] }
        }
        {
            kind = "unknown"
            if ($2 in M) {
                subject = S[M[$2]]
                if (subject ~ /^chore\(weave\): auto-checkpoint/ ||
                    subject ~ /^chore\(weave\): sync state/ ||
                    subject ~ /^chore\(weave\): session-start state/) { kind = "checkpoint" }
                else if (subject != "") { kind = "regular" }
            }
            print $2 "\t" kind
        }
    ' "$src"
}

_commit_refs_print_detail() {
    local workdir="$1" src="$2"

    awk 'NF >= 3 && $3 == "commit" { print $1 "\t" $2 }' "$workdir/resolved" > "$workdir/oidmap"

    awk -F'\t' -v oidmap="$workdir/oidmap" '
        BEGIN { while ((getline line < oidmap) > 0) { split(line, f, "\t"); M[f[1]] = f[2] } }
        { if ($2 in M) print M[$2] }
    ' "$src" | sort -u > "$workdir/detail_oids"

    : > "$workdir/subjects"
    if [ -s "$workdir/detail_oids" ]; then
        git log --no-walk --stdin --format='%H%x09%s' < "$workdir/detail_oids" \
            > "$workdir/subjects" 2>/dev/null || : > "$workdir/subjects"
    fi

    awk -F'\t' -v oidmap="$workdir/oidmap" -v subjects="$workdir/subjects" '
        BEGIN {
            while ((getline line < oidmap) > 0)   { split(line, f, "\t"); M[f[1]] = f[2] }
            while ((getline line < subjects) > 0) { split(line, f, "\t"); S[f[1]] = f[2] }
        }
        {
            kind = "unknown"
            if ($2 in M) {
                subject = S[M[$2]]
                if (subject ~ /^chore\(weave\): auto-checkpoint/ ||
                    subject ~ /^chore\(weave\): sync state/ ||
                    subject ~ /^chore\(weave\): session-start state/) { kind = "checkpoint" }
                else if (subject != "") { kind = "regular" }
            }
            printf "  %-12s %-40s %-11s %s\n", $1, $2, $3, kind
        }
    ' "$src"
}

# _commit_refs_prune_node <id> <drop-json-array> — remove the listed refs from
# one node's metadata, repairing the primary `commit` pointer.
#
# Prunes wherever a ref is recorded, aggregating epics included. Aggregators
# regenerate `commits` from their children (_aggregate_epic_commits), so an
# epic-only edit does not persist while a child still carries the ref — this is
# why cleanup has to reach the children, and why the prevention filter in the
# aggregator is what stops the epic re-acquiring it afterwards.
# The transformation is a SINGLE UPDATE, not a SELECT into jq and back. The
# round-trip version rewrote the whole metadata object from a value read moments
# earlier, so any concurrent write to an unrelated key on the same node — a
# claim, a learning, a touch — was silently reverted by the prune, and the write
# never advanced updated_at, leaving the row looking untouched to every
# last-write-wins consumer (delta replay included).
#
# $kept is the surviving commits array, recomputed in-statement from the row's
# own metadata. SQLite has no LATERAL, so it cannot be bound once in a FROM
# subquery and reused; it is spelled out per branch instead.
_commit_refs_prune_node() {
    local id="$1" drop_json="$2"
    local id_esc drop_esc kept

    id_esc=$(sql_escape "$id")
    drop_esc="${drop_json//\'/\'\'}"
    kept="(SELECT json_group_array(je.value)
            FROM json_each(json_extract(nodes.metadata, '\$.commits')) je
            WHERE je.value NOT IN (SELECT dv.value FROM json_each('$drop_esc') dv))"

    db_query "
        UPDATE nodes SET
          metadata = CASE
            WHEN json_array_length($kept) = 0
              -- Emptying the array does NOT authorise removing the primary: a
              -- node can record a live \$.commit alongside an array holding only
              -- dead refs, and dropping it there destroyed a reachable ref (three
              -- of them, in the wv-3ce8d9 cleanup run). Remove the primary only
              -- when the primary itself is being dropped.
              THEN CASE
                     WHEN json_extract(nodes.metadata, '\$.commit')
                          IN (SELECT dv.value FROM json_each('$drop_esc') dv)
                       THEN json_remove(nodes.metadata, '\$.commits', '\$.commit')
                     ELSE json_remove(nodes.metadata, '\$.commits')
                   END
            WHEN json_extract(nodes.metadata, '\$.commit')
                 IN (SELECT dv.value FROM json_each('$drop_esc') dv)
              THEN json_set(nodes.metadata,
                     '\$.commits', json($kept),
                     '\$.commit',  json_extract($kept, '\$[0]'))
            ELSE json_set(nodes.metadata, '\$.commits', json($kept))
          END,
          updated_at = CURRENT_TIMESTAMP
        WHERE id='$id_esc';
    " || return 1
}

cmd_commit_refs() {
    # Hook VALIDATION runs before every branch, including the one taken when
    # there are no orphans at all. Sitting inside the orphans-present branch, it
    # accepted an unrecognised value silently on a clean sweep -- the ordinary
    # case -- so "unknown values are rejected" held only when the data happened
    # to exercise the path. Only the fault EXECUTION stays at the site it
    # perturbs.
    local _kinds_stub=false
    if [ -n "${WV_TEST_FAIL_ORPHAN_KINDS:-}" ]; then
        if [ "${WV_TEST_MODE:-}" != "1" ]; then
            echo "wv commit-refs: WV_TEST_FAIL_ORPHAN_KINDS is set but WV_TEST_MODE=1 is not — ignoring it" >&2
        elif [ "${WV_TEST_FAIL_ORPHAN_KINDS}" = "1" ]; then
            _kinds_stub=true
        else
            echo "wv commit-refs: WV_TEST_FAIL_ORPHAN_KINDS='${WV_TEST_FAIL_ORPHAN_KINDS}' is not a recognised value (1)" >&2
            return 1
        fi
    fi

    local format="text" prune=false dry_run=false show_all=false

    while [ $# -gt 0 ]; do
        case "$1" in
            --json)    format="json" ;;
            --prune)   prune=true ;;
            --dry-run) dry_run=true ;;
            --all)     show_all=true ;;
            --help|-h) cmd_help commit-refs; return 0 ;;
            *) echo "wv commit-refs: unknown argument: $1" >&2; return 2 ;;
        esac
        shift
    done

    if ! git rev-parse --git-dir >/dev/null 2>&1; then
        echo "wv commit-refs: not a git repository — nothing to verify refs against" >&2
        return 1
    fi

    local pushed_ref degraded=false
    pushed_ref=$(_commit_refs_pushed_ref) || { pushed_ref=""; degraded=true; }

    local workdir
    workdir=$(mktemp -d "${TMPDIR:-/tmp}/wv-commit-refs.XXXXXX") || return 1

    _commit_refs_scan "$workdir" "$pushed_ref"

    local total reachable pending unreachable missing orphan_nodes
    total=$(wc -l < "$workdir/rows" | tr -d ' ')
    reachable=$(awk -F'\t' '$3=="reachable"' "$workdir/rows" | wc -l | tr -d ' ')
    pending=$(awk -F'\t' '$3=="pending"' "$workdir/rows" | wc -l | tr -d ' ')
    unreachable=$(awk -F'\t' '$3=="unreachable"' "$workdir/rows" | wc -l | tr -d ' ')
    missing=$(awk -F'\t' '$3=="missing"' "$workdir/rows" | wc -l | tr -d ' ')

    awk -F'\t' '$3=="unreachable" || $3=="missing"' "$workdir/rows" | sort > "$workdir/orphans"
    orphan_nodes=$(cut -f1 "$workdir/orphans" | sort -u | wc -l | tr -d ' ')

    # Split the orphan population by kind. Auto-checkpoint refs are superseded
    # constantly and are the designed steady state; a REGULAR ref going
    # unreachable is a real provenance loss. Reporting one number for both let
    # expected churn sit as a permanent warning, which is how a genuine loss
    # would have gone unnoticed among it.
    local orphan_ckpt=0 orphan_reg=0 orphan_unknown=0 _kinds_rc=0
    if [ -s "$workdir/orphans" ]; then
        # Force the classifier to fail as a whole: a branch unreachable from the
        # CLI, since it only fails on an unreadable workdir it created itself,
        # and an untestable fail-open is what put that defect here. Validation
        # of the hook happened at the top of this function; only the fault
        # itself belongs here.
        _kinds_rc=0
        if [ "$_kinds_stub" = true ]; then
            : > "$workdir/orphan_kinds"
            _kinds_rc=1
        else
            _commit_refs_kinds "$workdir" "$workdir/orphans" > "$workdir/orphan_kinds" 2>/dev/null || _kinds_rc=$?
        fi
        if [ "$_kinds_rc" -ne 0 ]; then
            # Classification failed as a whole. The previous fallback emptied
            # the file, which zeroed all three counters -- so a sweep holding
            # orphans reported "0 checkpoint, 0 regular, 0 unknown", the exact
            # shape of a clean run. The one number that would have shown a
            # genuine provenance loss was the number the failure erased.
            # Attribute the whole population to unknown instead: conservative,
            # and it still says there is something here to look at.
            awk -F'\t' '{ print $2 "\tunknown" }' "$workdir/orphans" > "$workdir/orphan_kinds" 2>/dev/null \
                || : > "$workdir/orphan_kinds"
            echo "wv commit-refs: could not classify orphan refs by kind; counting them all as unknown" >&2
        fi
        orphan_ckpt=$(awk -F'\t' '$2=="checkpoint"' "$workdir/orphan_kinds" | wc -l | tr -d ' ')
        orphan_reg=$(awk -F'\t' '$2=="regular"' "$workdir/orphan_kinds" | wc -l | tr -d ' ')
        orphan_unknown=$(awk -F'\t' '$2=="unknown"' "$workdir/orphan_kinds" | wc -l | tr -d ' ')

        # Reconcile against the orphan population. Every orphan row is
        # classified into exactly one of the three kinds, so the three counts
        # must sum to the row total. A partial emission -- the classifier dying
        # mid-write, which leaves a nonzero exit AND a short file, or succeeding
        # with fewer rows than it read -- otherwise under-reports silently, the
        # same fail-open in a smaller size. Charge any shortfall to unknown.
        local orphan_rows orphan_classified
        orphan_rows=$(wc -l < "$workdir/orphans" | tr -d ' ')
        orphan_classified=$((orphan_ckpt + orphan_reg + orphan_unknown))
        if [ "${orphan_rows:-0}" -gt "$orphan_classified" ]; then
            orphan_unknown=$((orphan_unknown + orphan_rows - orphan_classified))
            echo "wv commit-refs: $((orphan_rows - orphan_classified)) orphan ref(s) could not be classified; counted as unknown" >&2
        fi
    fi

    local detail_src="$workdir/orphans"
    [ "$show_all" = true ] && { sort "$workdir/rows" > "$workdir/detail"; detail_src="$workdir/detail"; }

    # ── Prune runs BEFORE the report so the report can state what happened ────
    # (a --json consumer could not otherwise tell a persisted prune from an
    # unpersisted one: the disclosure used to be text-only.)
    local rc=0 pruned=0 failed=0 persisted=not_attempted
    if [ "$prune" = true ] && [ -s "$workdir/orphans" ] && [ "$dry_run" != true ]; then
        # Ensure change tracking EXISTS before mutating. An absent _warp_changes
        # is not an empty one: auto_sync would recreate the table after the
        # untracked UPDATE, then see no pending rows and report a clean sync
        # while state.sql never moved.
        if declare -f wv_delta_init >/dev/null 2>&1; then
            sqlite3 -cmd ".timeout 5000" "$WV_DB" "SELECT 1 FROM _warp_changes LIMIT 0;" >/dev/null 2>&1 \
                || wv_delta_init "$WV_DB" >/dev/null 2>&1 || true
        fi

        local state_file="$WEAVE_DIR/state.sql" state_before="" state_after=""
        state_before=$(md5sum "$state_file" 2>/dev/null | awk '{print $1}')

        local node drops
        while IFS= read -r node; do
            drops=$(awk -F'\t' -v n="$node" '$1==n {print $2}' "$workdir/orphans" | jq -R . | jq -sc .)
            if _commit_refs_prune_node "$node" "$drops"; then
                pruned=$((pruned + 1))
            else
                failed=$((failed + 1))
                echo "wv commit-refs: failed to prune $node" >&2
            fi
        done < <(cut -f1 "$workdir/orphans" | sort -u)

        # Persistence is proved against the AUTHORITATIVE snapshot. A drained
        # change log is not proof — with tracking absent it is vacuously empty,
        # and auto_sync returns 0 from five separate skip paths besides.
        if [ "${WV_AUTO_SYNC:-1}" = "0" ] || [ -n "${WV_DB_CUSTOM:-}" ] || [ -n "${_WV_IN_JOURNAL:-}" ]; then
            persisted=skipped
        else
            auto_sync --force >/dev/null 2>&1 || true
            state_after=$(md5sum "$state_file" 2>/dev/null | awk '{print $1}')
            if [ -n "$state_after" ] && [ "$state_before" != "$state_after" ]; then
                persisted=true
            else
                persisted=false
            fi
        fi
        { [ "$failed" -gt 0 ] || [ "$persisted" = false ]; } && rc=1
    elif [ "$prune" = true ] && [ -s "$workdir/orphans" ]; then
        persisted=dry_run
    elif [ "$prune" = true ]; then
        persisted=nothing_to_prune
    fi

    if [ "$format" = "json" ]; then
        # The rows go to jq through a FILE, never through an argv-sized argument:
        # --argjson with this repository's ~1900 refs blows the per-argument limit
        # (E2BIG), and the old form swallowed it, exiting 0 with empty stdout.
        if ! awk -F'\t' '{print $1 "\t" $2 "\t" $3}' "$detail_src" \
            | jq -R -s '
                [ split("\n")[] | select(length > 0) | split("\t")
                  | {node: .[0], ref: .[1], class: .[2]} ]' > "$workdir/refs.json" 2>/dev/null; then
            echo "wv commit-refs: failed to serialize ref rows" >&2
            rm -rf "$workdir"
            return 1
        fi
        if ! jq -n \
            --arg pushed "${pushed_ref:-}" \
            --arg persisted "$persisted" \
            --argjson degraded "$([ "$degraded" = true ] && echo true || echo false)" \
            --argjson total "${total:-0}" \
            --argjson reachable "${reachable:-0}" \
            --argjson pending "${pending:-0}" \
            --argjson unreachable "${unreachable:-0}" \
            --argjson missing "${missing:-0}" \
            --argjson orphan_nodes "${orphan_nodes:-0}" \
            --argjson orphan_ckpt "${orphan_ckpt:-0}" \
            --argjson orphan_reg "${orphan_reg:-0}" \
            --argjson orphan_unknown "${orphan_unknown:-0}" \
            --argjson pruned "${pruned:-0}" \
            --argjson prune_failed "${failed:-0}" \
            --slurpfile refs "$workdir/refs.json" \
            '{
                pushed_ref: (if $pushed == "" then null else $pushed end),
                degraded: $degraded,
                totals: {
                    refs: $total,
                    reachable: $reachable,
                    pending: $pending,
                    unreachable: $unreachable,
                    missing: $missing,
                    orphaned: ($unreachable + $missing),
                    orphaned_nodes: $orphan_nodes,
                    orphaned_checkpoint: $orphan_ckpt,
                    orphaned_regular: $orphan_reg,
                    orphaned_unknown: $orphan_unknown
                },
                prune: {
                    attempted: ($persisted != "not_attempted"),
                    nodes_pruned: $pruned,
                    nodes_failed: $prune_failed,
                    persisted: $persisted
                },
                refs: ($refs[0] // [])
            }'; then
            echo "wv commit-refs: failed to render JSON output" >&2
            rm -rf "$workdir"
            return 1
        fi
    else
        echo "Commit-ref provenance — ${total} recorded ref(s)"
        if [ "$degraded" = true ]; then
            echo -e "  ${YELLOW}⊘${NC} no pushed ref (no upstream, origin/main or origin/master) — 'pending' cannot be distinguished from 'reachable'"
        else
            echo "  pushed ref: $pushed_ref"
        fi
        echo "  reachable:   $reachable (ancestor of the pushed ref)"
        echo "  pending:     $pending (local only — not pushed yet, or on another branch)"
        echo "  unreachable: $unreachable (object exists, no ref reaches it — superseded)"
        echo "  missing:     $missing (not in this object database)"
        if [ "$((unreachable + missing))" -gt 0 ]; then
            echo -e "  ${YELLOW}⚠${NC} $((unreachable + missing)) orphaned ref(s) across $orphan_nodes node(s)"
        else
            echo -e "  ${GREEN}✓${NC} no orphaned refs"
        fi
        if [ -s "$detail_src" ]; then
            echo ""
            _commit_refs_print_detail "$workdir" "$detail_src"
        fi
    fi

    if [ "$prune" = true ] && [ "$format" = "text" ]; then
        case "$persisted" in
            nothing_to_prune)
                echo -e "\n${GREEN}✓${NC} nothing to prune" ;;
            dry_run)
                echo -e "\n${YELLOW}Would prune $((unreachable + missing)) ref(s) from $orphan_nodes node(s)${NC}" ;;
            true)
                echo -e "\n${GREEN}✓${NC} pruned orphaned refs from $pruned node(s) and persisted" ;;
            skipped)
                echo -e "\n${GREEN}✓${NC} pruned orphaned refs from $pruned node(s) (auto-sync disabled — persist with: wv sync)" ;;
        esac
        [ "$failed" -gt 0 ] && echo -e "${RED}✗${NC} $failed node(s) failed to prune"
    fi
    if [ "$persisted" = false ]; then
        echo "wv commit-refs: pruned $pruned node(s) but .weave/state.sql did not change — NOT persisted" >&2
        echo "  The hot DB is ahead of the git layer; a wv load would restore the refs. Run: wv sync" >&2
    fi

    rm -rf "$workdir"
    return "$rc"
}

# ═══════════════════════════════════════════════════════════════════════════
# cmd_compact — Prune old delta files already incorporated into state.sql
# ═══════════════════════════════════════════════════════════════════════════

cmd_compact() {
    local older_than="${WV_DELTA_RETAIN_DAYS:-30}"
    local dry_run=false
    local force=false

    while [ $# -gt 0 ]; do
        case "$1" in
            --older-than=*) older_than="${1#*=}" ;;
            --dry-run) dry_run=true ;;
            --force) force=true ;;
            *) echo "Unknown option: $1" >&2; return 1 ;;
        esac
        shift
    done

    # Strip trailing 'd' if present (e.g. --older-than=14d → 14)
    older_than="${older_than%d}"
    if ! [[ "$older_than" =~ ^[0-9]+$ ]] || [ "$older_than" -eq 0 ]; then
        echo "error: --older-than must be a positive integer (days)" >&2
        return 1
    fi

    # Coordination gate: refuse to compact while other agents hold active claims.
    # Deleting delta files that a concurrent agent hasn't replayed causes silent
    # divergence — those changes are permanently lost for that agent.
    local active_claims
    active_claims=$(db_query "SELECT COUNT(*) FROM nodes WHERE status='active' AND json_extract(metadata, '\$.claimed_by') IS NOT NULL;" 2>/dev/null || echo "0")
    if [ "$active_claims" -gt 0 ] && [ "$force" != true ]; then
        echo -e "${RED}✗${NC} $active_claims node(s) currently claimed by agents." >&2
        echo "  Active agents may not have replayed all deltas yet." >&2
        echo "  Use --force to compact anyway, or wait until all agents finish." >&2
        return 1
    fi

    echo -e "${YELLOW}⚠${NC} Only run compact when all agents have loaded the latest state." \
         "Compacted deltas cannot be replayed by agents with older state.sql." >&2

    local delta_root="$WEAVE_DIR/deltas"
    if [ ! -d "$delta_root" ]; then
        echo "No deltas directory found; nothing to compact."
        return 0
    fi

    local now
    now=$(date +%s)
    local cutoff=$(( now - older_than * 86400 ))
    local deleted=0
    local dry_list=()

    while IFS= read -r delta; do
        local delta_name delta_ts
        delta_name="${delta##*/}"
        delta_ts="${delta_name%%-*}"
        if [[ "$delta_ts" =~ ^[0-9]+$ ]] && [ "$delta_ts" -lt "$cutoff" ]; then
            if $dry_run; then
                dry_list+=("$delta")
            else
                rm -f "$delta"
                deleted=$(( deleted + 1 ))
            fi
        fi
    done < <(find "$delta_root" -name '*.sql' 2>/dev/null | sort)

    if $dry_run; then
        if [ "${#dry_list[@]}" -eq 0 ]; then
            echo "Dry run: no delta files older than ${older_than}d."
        else
            echo "Dry run: would delete ${#dry_list[@]} delta file(s) older than ${older_than}d:"
            printf '  %s\n' "${dry_list[@]}"
        fi
        return 0
    fi

    # Remove empty date subdirectories
    find "$delta_root" -mindepth 1 -maxdepth 1 -type d -empty -delete 2>/dev/null || true

    if [ "$deleted" -eq 0 ]; then
        echo "No delta files older than ${older_than}d found."
    else
        echo -e "${GREEN}✓${NC} Compacted ${deleted} delta file(s) older than ${older_than}d."
    fi
}

# ═══════════════════════════════════════════════════════════════════════════
# cmd_prune — Archive old done nodes
# ═══════════════════════════════════════════════════════════════════════════

cmd_prune() {
    local age="48 hours"
    local dry_run=false
    local orphans_only=false
    
    while [ $# -gt 0 ]; do
        case "$1" in
            --age=*) age="${1#*=}" ;;
            --dry-run) dry_run=true ;;
            --orphans-only) orphans_only=true ;;
        esac
        shift
    done
    
    # Validate age format: must be Nh or Nd (numeric hours or days)
    local age_num age_unit
    case "$age" in
        *h) age_num="${age%h}"; age_unit="hours" ;;
        *d) age_num="${age%d}"; age_unit="days" ;;
        *" hours") age_num="${age% hours}"; age_unit="hours" ;;
        *" days") age_num="${age% days}"; age_unit="days" ;;
        *)
            echo -e "${RED}Error: invalid age format '$age' (use Nh or Nd, e.g. 48h, 7d)${NC}" >&2
            return 1
            ;;
    esac

    # Validate numeric part
    if ! [[ "$age_num" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}Error: invalid age format '$age' (numeric value required)${NC}" >&2
        return 1
    fi

    # Minimum age guard: reject 0h/0d to prevent accidental mass deletion
    # (bypassed when --orphans-only: the orphan filter is its own safety constraint)
    if [ "$age_num" -eq 0 ] && [ "$orphans_only" = false ]; then
        echo -e "${RED}Error: age=0 would delete all done nodes — use a positive value${NC}" >&2
        return 1
    fi

    # Build age clause — skipped entirely for --orphans-only (no age gate needed)
    local age_clause=""
    if [ "$orphans_only" = false ]; then
        age_clause="AND updated_at < datetime('now', '-${age_num} ${age_unit}')"
    fi

    # Build orphan filter clause
    local orphan_clause=""
    if [ "$orphans_only" = true ]; then
        orphan_clause="AND id NOT IN (SELECT source FROM edges) AND id NOT IN (SELECT target FROM edges)"
    fi

    # Find candidates (skip unaddressed pitfalls — they must persist until resolved)
    local candidates=$(db_query "
        SELECT id, text, updated_at FROM nodes
        WHERE status = 'done'
        $age_clause
        $orphan_clause
        AND COALESCE(json_extract(metadata, '\$.type'), '') NOT IN ('finding', 'memory')
        AND id NOT IN (
            SELECT n.id FROM nodes n
            WHERE json_extract(n.metadata, '\$.pitfall') IS NOT NULL
            AND n.id NOT IN (
                SELECT e.target FROM edges e
                WHERE e.type IN ('addresses', 'implements', 'supersedes')
            )
        );
    ")
    
    if [ -z "$candidates" ]; then
        echo "No nodes to prune."
        return
    fi
    
    # Dedup against today's archive BEFORE dry-run so --dry-run reflects actual
    # candidates (F6 fix). Read-only here; mkdir deferred until after dry-run gate.
    local archive_dir="$WEAVE_DIR/archive"
    local archive_file="$archive_dir/$(date +%Y-%m-%d).jsonl"
    if [ -f "$archive_file" ]; then
        local already_archived
        already_archived=$(jq -r '.id' "$archive_file" 2>/dev/null | sort -u)
        if [ -n "$already_archived" ]; then
            candidates=$(echo "$candidates" | awk -F'|' -v skip="$already_archived" '
                BEGIN { n = split(skip, arr, "\n"); for (i=1;i<=n;i++) seen[arr[i]]=1 }
                { if (!seen[$1]) print }
            ')
        fi
    fi

    if [ -z "$candidates" ]; then
        echo "No new nodes to prune (all candidates already archived today)."
        return
    fi

    local count
    count=$(echo "$candidates" | wc -l)

    if [ "$dry_run" = true ]; then
        echo -e "${YELLOW}Would prune $count nodes:${NC}"
        echo "$candidates" | while IFS='|' read -r id text updated; do
            echo "  $id: $text (updated: $updated)"
        done
        return
    fi

    mkdir -p "$archive_dir"

    # Export to archive
    local ids
    ids=$(echo "$candidates" | cut -d'|' -f1 | while read -r _id; do printf '%s,' "$(sql_escape "$_id")"; done | sed 's/,$//')
    db_query_json "SELECT * FROM nodes WHERE id IN ('${ids//,/\',\'}')" | jq -c '.[]' >> "$archive_file"

    # Collect nodes affected by edge deletion for cache invalidation
    # Include: pruned nodes + any nodes connected to them
    local affected_nodes
    affected_nodes=$(echo "$candidates" | cut -d'|' -f1 | tr '\n' ' ')
    local connected_sources
    connected_sources=$(db_query "SELECT DISTINCT source FROM edges WHERE target IN ('${ids//,/\',\'}');" | tr '\n' ' ')
    local connected_targets
    connected_targets=$(db_query "SELECT DISTINCT target FROM edges WHERE source IN ('${ids//,/\',\'}');" | tr '\n' ' ')
    affected_nodes="$affected_nodes $connected_sources $connected_targets"

    # Close linked GitHub issues before deleting nodes.
    # Pre-state-check guards against spam-commenting already-closed issues (F2 fix).
    if command -v gh >/dev/null 2>&1; then
        local repo
        repo=$(gh repo view --json nameWithOwner -q '.nameWithOwner' 2>/dev/null || echo "")
        if [ -n "$repo" ]; then
            echo "$candidates" | cut -d'|' -f1 | while read -r id; do
                local gh_num
                gh_num=$(db_query "SELECT json_extract(metadata, '\$.gh_issue') FROM nodes WHERE id='$(sql_escape "$id")';" 2>/dev/null)
                if [ -n "$gh_num" ] && [ "$gh_num" != "null" ]; then
                    local gh_state
                    gh_state=$(gh issue view "$gh_num" --repo "$repo" --json state -q '.state' 2>/dev/null || echo "")
                    if [ "$gh_state" = "OPEN" ]; then
                        gh issue close "$gh_num" --repo "$repo" \
                            --comment "Pruned from Weave graph (node \`$id\` archived after ${age})." \
                            >/dev/null 2>&1 && \
                            echo -e "  ${GREEN}✓${NC} Closed GitHub issue #$gh_num ($id)" >&2 || \
                            echo -e "  ${YELLOW}⚠${NC} Could not close GitHub issue #$gh_num ($id)" >&2
                    fi
                fi
            done
        fi
    fi

    # Delete nodes and orphaned edges in a single atomic transaction.
    # DELETEs must NOT leak into delta files. Prune decisions are local:
    # a node pruned on this agent may still be active on another agent's timeline.
    # If the DELETEs were emitted as a delta and replayed on that agent, it would
    # lose nodes it is still working with. Prune is intentionally non-propagating.
    #
    # The transaction wraps both the DELETEs and the _warp_changes reset in one
    # sqlite3 invocation — no window for a concurrent auto_sync to snapshot the
    # trigger-generated rows between DELETE and reset.
    local prune_sql="BEGIN TRANSACTION;"
    while read -r id; do
        local esc_id
        esc_id="$(sql_escape "$id")"
        prune_sql+="DELETE FROM edges WHERE source='$esc_id' OR target='$esc_id';"
        prune_sql+="DELETE FROM node_files WHERE node_id='$esc_id';"
        prune_sql+="DELETE FROM nodes WHERE id='$esc_id';"
    done < <(echo "$candidates" | cut -d'|' -f1)
    prune_sql+="DELETE FROM _warp_changes;COMMIT;"
    db_query "$prune_sql"

    # Write prune epoch: the Unix timestamp of this prune run.
    # cmd_load reads this and skips any delta file whose epoch prefix is <= prune_epoch,
    # preventing old INSERT OR REPLACE deltas from resurrecting pruned nodes on reload.
    date +%s > "$WEAVE_DIR/.prune_epoch"

    # Re-dump state.sql so it no longer contains pruned nodes.
    # Without this, wv load would resurrect them from the stale snapshot.
    local tmp_sql
    tmp_sql=$(mktemp "$WEAVE_DIR/.state.sql.XXXXXX")
    if dump_state_sql "$WV_DB" "$tmp_sql" && [ -s "$tmp_sql" ]; then
        mv "$tmp_sql" "$WEAVE_DIR/state.sql"
    else
        rm -f "$tmp_sql"
    fi

    # Invalidate context cache for all affected nodes
    # shellcheck disable=SC2086  # word-split intentional — affected_nodes is space-delimited ID list
    invalidate_context_cache $affected_nodes

    echo -e "${GREEN}✓${NC} Pruned $count nodes → $archive_file"
}

# ═══════════════════════════════════════════════════════════════════════════
# _learnings_dedup — Find similar learnings via token overlap (Jaccard)
# ═══════════════════════════════════════════════════════════════════════════

_learnings_dedup() {
    local results="$1"
    local format="$2"

    if [ -z "$results" ] || [ "$results" = "[]" ]; then
        if [ "$format" = "json" ]; then echo "[]"; else echo "No learnings to compare."; fi
        return
    fi

    # Extract id + combined learning text per node into TSV
    local learning_tsv
    learning_tsv=$(echo "$results" | jq -r '.[] |
        .id as $id |
        (.metadata // "{}") |
        (if type == "string" then fromjson else . end) |
        [$id, ([.decision, .pattern, .pitfall, .learning] | map(select(. != null)) | join(" "))] |
        @tsv' 2>/dev/null)

    if [ -z "$learning_tsv" ]; then
        if [ "$format" = "json" ]; then echo "[]"; else echo "No learnings to compare."; fi
        return
    fi

    # Use awk for pairwise Jaccard similarity (>60% threshold)
    local pairs
    pairs=$(echo "$learning_tsv" | awk -F'\t' '
    {
        id[NR] = $1
        text[NR] = tolower($2)
        n = NR
    }
    END {
        for (i = 1; i <= n; i++) {
            # Tokenize text[i]
            split(text[i], toks_i, /[^a-z0-9]+/)
            delete set_i
            ni = 0
            for (t in toks_i) {
                w = toks_i[t]
                if (length(w) > 2 && !(w in set_i)) { set_i[w] = 1; ni++ }
            }

            for (j = i + 1; j <= n; j++) {
                # Tokenize text[j]
                split(text[j], toks_j, /[^a-z0-9]+/)
                delete set_j
                nj = 0
                for (t in toks_j) {
                    w = toks_j[t]
                    if (length(w) > 2 && !(w in set_j)) { set_j[w] = 1; nj++ }
                }

                # Intersection
                inter = 0
                for (w in set_i) {
                    if (w in set_j) inter++
                }

                # Jaccard = intersection / union
                union_size = ni + nj - inter
                if (union_size > 0) {
                    jaccard = inter / union_size
                    if (jaccard >= 0.6) {
                        printf "%s\t%s\t%.0f\n", id[i], id[j], jaccard * 100
                    }
                }
            }
        }
    }')

    if [ -z "$pairs" ]; then
        if [ "$format" = "json" ]; then
            echo "[]"
        else
            echo "No duplicate learnings found (threshold: 60% token overlap)."
        fi
        return
    fi

    if [ "$format" = "json" ]; then
        echo "$pairs" | awk -F'\t' '{
            printf "{\"id_a\":\"%s\",\"id_b\":\"%s\",\"similarity\":%s}\n", $1, $2, $3
        }' | jq -s '.'
    else
        echo -e "${CYAN}Potential Duplicate Learnings${NC} (≥60% token overlap)"
        echo ""
        printf "  %-10s %-10s %s\n" "Node A" "Node B" "Similarity"
        printf "  %-10s %-10s %s\n" "──────────" "──────────" "──────────"
        echo "$pairs" | while IFS=$'\t' read -r id_a id_b sim; do
            printf "  ${YELLOW}%-10s${NC} ${YELLOW}%-10s${NC} %s%%\n" "$id_a" "$id_b" "$sim"
        done
        echo ""
        echo "Review with: wv show <id>"
    fi
}

# ═══════════════════════════════════════════════════════════════════════════
# cmd_unarchive — Restore a pruned node from .weave/archive/ JSONL
# ═══════════════════════════════════════════════════════════════════════════

cmd_unarchive() {
    local node_id=""
    local dry_run=false
    local with_edges=false

    while [ $# -gt 0 ]; do
        case "$1" in
            --dry-run)     dry_run=true ;;
            --with-edges)  with_edges=true ;;
            --help|-h)
                echo "Usage: wv unarchive <id> [--dry-run] [--with-edges]"
                echo ""
                echo "  Restore a pruned node from .weave/archive/ back into the live graph."
                echo "  The most recent archive entry is used when duplicates exist."
                echo ""
                echo "  --dry-run      Show what would be restored without writing"
                echo "  --with-edges   Also reconstruct edges whose other endpoint is live"
                return 0
                ;;
            wv-*) node_id="$1" ;;
            *)
                echo -e "${RED}Error: unknown argument: $1${NC}" >&2
                echo "Usage: wv unarchive <id> [--dry-run] [--with-edges]" >&2
                return 1
                ;;
        esac
        shift
    done

    if [ -z "$node_id" ]; then
        echo -e "${RED}Error: node ID required (e.g. wv-a1b2c3)${NC}" >&2
        echo "Usage: wv unarchive <id> [--dry-run] [--with-edges]" >&2
        return 1
    fi

    local archive_dir="$WEAVE_DIR/archive"
    if [ ! -d "$archive_dir" ]; then
        echo -e "${RED}Error: no archive directory at $archive_dir${NC}" >&2
        return 1
    fi

    # Search all archive files newest-first, take the latest record for this ID
    local record
    record=$(ls -r "$archive_dir"/*.jsonl 2>/dev/null | while read -r f; do
        grep "\"id\":\"$node_id\"" "$f" 2>/dev/null | tail -1 && break
    done)

    if [ -z "$record" ]; then
        echo -e "${RED}Error: node $node_id not found in archive${NC}" >&2
        echo "  Archive: $archive_dir" >&2
        echo "  Available: $(ls "$archive_dir"/*.jsonl 2>/dev/null | wc -l) file(s)" >&2
        return 1
    fi

    # Parse fields from the archive record
    local r_text r_status r_metadata r_alias r_created r_updated
    r_text=$(     echo "$record" | jq -r '.text     // ""' 2>/dev/null)
    r_status=$(   echo "$record" | jq -r '.status   // "done"' 2>/dev/null)
    r_metadata=$( echo "$record" | jq -c '.metadata // {}' 2>/dev/null)
    r_alias=$(    echo "$record" | jq -r '.alias    // ""' 2>/dev/null)
    r_created=$(  echo "$record" | jq -r '.created_at // ""' 2>/dev/null)
    r_updated=$(  echo "$record" | jq -r '.updated_at // ""' 2>/dev/null)

    # Check if node already exists in live DB
    local existing
    existing=$(db_query "SELECT id FROM nodes WHERE id='$(sql_escape "$node_id")';" 2>/dev/null || echo "")
    if [ -n "$existing" ]; then
        echo -e "${YELLOW}Warning: node $node_id already exists in live graph — skipping${NC}" >&2
        return 0
    fi

    if [ "$dry_run" = true ]; then
        echo -e "${CYAN}[dry-run] Would restore:${NC}"
        echo "  ID:     $node_id"
        echo "  Text:   $r_text"
        echo "  Status: $r_status"
        if [ -n "$r_alias" ]; then echo "  Alias:  $r_alias"; fi
        if [ "$with_edges" = true ]; then
            local edges_count
            edges_count=$(echo "$record" | jq '.edges // [] | length' 2>/dev/null || echo "0")
            echo "  Edges:  --with-edges (live-endpoint check at restore time)"
        fi
        return 0
    fi

    # Insert the node
    local alias_val="NULL"
    [ -n "$r_alias" ] && alias_val="'$(sql_escape "$r_alias")'"
    local created_val="CURRENT_TIMESTAMP"
    [ -n "$r_created" ] && created_val="'$(sql_escape "$r_created")'"
    local updated_val="CURRENT_TIMESTAMP"
    [ -n "$r_updated" ] && updated_val="'$(sql_escape "$r_updated")'"

    local insert_sql
    insert_sql="INSERT INTO nodes (id, text, status, metadata, alias, created_at, updated_at)
        VALUES (
            '$(sql_escape "$node_id")',
            '$(sql_escape "$r_text")',
            '$(sql_escape "$r_status")',
            '$(sql_escape "$r_metadata")',
            $alias_val,
            $created_val,
            $updated_val
        );"

    if ! db_query "$insert_sql" 2>/dev/null; then
        echo -e "${RED}Error: failed to insert node $node_id${NC}" >&2
        return 1
    fi

    echo -e "${GREEN}✓${NC} Restored: $node_id — $r_text"

    if [ "$with_edges" = true ]; then
        # edges are NOT stored in the archive (archive only stores nodes)
        # this flag is reserved for future use when edge data is available
        echo -e "  ${DIM}Note: --with-edges has no effect — edge data is not stored in the archive${NC}" >&2
    fi

    echo -e "  ${DIM}Status: $r_status${NC}"
    if [ -n "$r_alias" ]; then echo -e "  ${DIM}Alias: $r_alias${NC}"; fi

    invalidate_context_cache "$node_id"
}

# ═══════════════════════════════════════════════════════════════════════════
# cmd_learnings — Show captured learnings
# ═══════════════════════════════════════════════════════════════════════════

cmd_learnings() {
    local format="text"
    local node_filter=""
    local show_graph=false
    local category_filter=""
    local grep_filter=""
    local recent_limit=""
    local min_quality=""
    local dedup=false
    local mode_arg=""
    local show_all=false

    while [ $# -gt 0 ]; do
        case "$1" in
            --json) format="json" ;;
            --node=*) node_filter="${1#*=}" ;;
            --show-graph) show_graph=true ;;
            --category=*|--cat=*) category_filter="${1#*=}" ;;
            --grep=*) grep_filter="${1#*=}" ;;
            --recent=*) recent_limit="${1#*=}" ;;
            --min-quality=*) min_quality="${1#*=}" ;;
            --dedup) dedup=true ;;
            --mode=*) mode_arg="${1#*=}" ;;
            --all) show_all=true ;;
            --stale=*)
                echo -e "${RED}Error: --stale is not supported by 'wv learnings'${NC}" >&2
                echo "Did you mean: wv findings list --stale=${1#--stale=} ?" >&2
                return 1
                ;;
            --*)
                echo -e "${RED}Error: unknown option: $1${NC}" >&2
                echo "Run 'wv help learnings' for usage." >&2
                return 1
                ;;
        esac
        shift
    done
    local mode
    mode=$(wv_resolve_mode "$mode_arg")

    # Validate category filter
    if [ -n "$category_filter" ]; then
        case "$category_filter" in
            decision|pattern|pitfall|learning) ;; # valid
            *)
                echo -e "${RED}Error: invalid category '$category_filter'${NC}" >&2
                echo "Valid categories: decision, pattern, pitfall, learning" >&2
                return 1
                ;;
        esac
    fi

    # Validate recent limit
    if [ -n "$recent_limit" ]; then
        if ! [[ "$recent_limit" =~ ^[0-9]+$ ]]; then
            echo -e "${RED}Error: --recent must be a number${NC}" >&2
            return 1
        fi
    fi

    # Build query based on filters
    local where_parts=""
    if [ -n "$category_filter" ]; then
        where_parts="json_extract(metadata, '\$.$category_filter') IS NOT NULL"
    else
        where_parts="(json_extract(metadata, '\$.decision') IS NOT NULL
           OR json_extract(metadata, '\$.pattern') IS NOT NULL
           OR json_extract(metadata, '\$.pitfall') IS NOT NULL
           OR json_extract(metadata, '\$.learning') IS NOT NULL)"
    fi

    if [ -n "$node_filter" ]; then
        where_parts="id = '$node_filter' AND $where_parts"
    fi

    if [ -n "$min_quality" ]; then
        where_parts="$where_parts AND COALESCE(json_extract(metadata, '\$.learning_hygiene'), 0) >= $min_quality"
    fi

    local limit_clause=""
    if [ -n "$recent_limit" ]; then
        limit_clause="LIMIT $recent_limit"
    fi

    local query="
        SELECT id, text, status, metadata FROM nodes
        WHERE $where_parts
        ORDER BY updated_at DESC, rowid DESC $limit_clause;
    "

    local results
    if [ "$format" = "json-v2" ]; then
        results=$(db_query_json_v2 "$query")
    else
        results=$(db_query_json "$query")
    fi

    # Apply grep filter to results (searches text, metadata values)
    if [ -n "$grep_filter" ] && [ -n "$results" ] && [ "$results" != "[]" ]; then
        results=$(echo "$results" | jq --arg pat "$grep_filter" \
            '[.[] | select((.text | ascii_downcase | test($pat; "i"))
                or (.metadata | tostring | ascii_downcase | test($pat; "i")))]' \
            2>/dev/null || echo "$results")
    fi

    # Filter junk/template learnings unless --all is specified.
    # Nodes with structured keys (decision/pattern/pitfall) but no raw learning
    # key are always kept — the junk filter only applies to the raw learning string.
    if [ "$show_all" != true ] && [ -n "$results" ] && [ "$results" != "[]" ]; then
        results=$(echo "$results" | jq '
            [.[] | select(
                ((.metadata // "{}") | if type == "string" then fromjson else . end) as $m |
                if (($m.decision // "") != "" or ($m.pattern // "") != "" or ($m.pitfall // "") != "")
                   and ($m.learning // "") == ""
                then true  # structured-only: always keep
                else
                    ($m.learning // "") |
                    (test("^closed via (gh|github) issue"; "i")
                     or test("^knowledge captured"; "i")
                     or test("^trivial fix$"; "i")
                     or test("^$")) | not
                end
            )]' 2>/dev/null || echo "$results")
    fi

    # Handle --dedup mode: find similar learnings
    if [ "$dedup" = true ]; then
        _learnings_dedup "$results" "$format"
        return
    fi

    # Agent/non-tty callers default to discover mode. Only apply an automatic
    # cap when the caller did not already request --recent, so explicit filters
    # keep their full search behavior before we trim the final result set.
    # Execute/full also get a (looser) safety cap so an interactive `wv learnings`
    # without filters cannot dump the whole corpus into the agent's context.
    local mode_limit=""
    if [ -z "$recent_limit" ]; then
        case "$mode" in
            bootstrap) mode_limit="5" ;;
            discover)  mode_limit="10" ;;
            execute|full) mode_limit="20" ;;
        esac
    fi
    if [ -n "$mode_limit" ] && [ -n "$results" ] && [ "$results" != "[]" ]; then
        results=$(echo "$results" | jq --argjson lim "$mode_limit" '.[0:$lim]' \
            2>/dev/null || echo "$results")
    fi

    if [ "$format" = "json" ] || [ "$format" = "json-v2" ]; then
        [ -z "$results" ] && echo "[]" || echo "$results"
        return
    fi

    local count
    [ -z "$results" ] && count=0 || count=$(echo "$results" | jq 'length' 2>/dev/null || echo "0")

    if [ "$count" = "0" ] || [ "$count" = "" ]; then
        echo "No learnings recorded yet."
        return
    fi

    # wv-18b8f5 (external code review round 3 re-audit): wv resolve rewrites
    # a contradicts edge into a supersedes edge (winner -> loser, wv-cmd-
    # graph.sh's cmd_resolve) and that protects wv preflight, but a
    # retracted learning kept printing verbatim here with no marker -- the
    # text is deliberately KEPT (not mutated), so it must be KEPT AND
    # LABELLED. One query up front (loser id -> winner id) covers both
    # formatters below without a per-row query in the fast text path.
    local superseded_map
    superseded_map=$(db_query_json "SELECT target AS loser, source AS winner FROM edges WHERE type='supersedes';" 2>/dev/null | \
        jq -c '[.[] | {(.loser): .winner}] | add // {}' 2>/dev/null || echo '{}')

    # Fast path: single jq call formats all output (avoids N*9 subprocess spawns)
    if [ "$show_graph" != true ]; then
        _learnings_format_text "$results" "$superseded_map"
    else
        _learnings_format_graph "$results" "$superseded_map"
    fi
}

# _learnings_format_text — Compact token-optimised output (single jq call)
# Parses inline markers (decision:/pattern:/pitfall:) from the learning field.
# Uses top-level metadata keys if present, falls back to inline parsing.
_learnings_format_text() {
    local results="$1"
    local superseded_map="${2:-{\}}"
    local _green _yellow _cyan _nc
    printf -v _green '%b' "$GREEN"
    printf -v _yellow '%b' "$YELLOW"
    printf -v _cyan '%b' "$CYAN"
    printf -v _nc '%b' "$NC"
    echo "$results" | jq -r --arg G "$_green" --arg Y "$_yellow" \
        --arg C "$_cyan" --arg N "$_nc" --argjson SUP "$superseded_map" '
        .[] |
        .id as $id | .text as $text |
        ($SUP[$id] // null) as $winner |
        ((.metadata // "{}") | if type == "string" then fromjson else . end) as $m |

        # Use top-level keys if present, else parse inline markers from learning
        ($m.decision // null) as $td |
        ($m.pattern // null) as $tp |
        ($m.pitfall // null) as $tpi |
        ($m.learning // "") as $raw |

        (if ($td or $tp or $tpi) then
          {decision: $td, pattern: $tp, pitfall: $tpi, note: null}
        elif ($raw | test("^(decision|pattern|pitfall):"; "i")) then
          ($raw | gsub(";\\s*(?<m>(decision|pattern|pitfall):)"; " | \(.m)"; "i")
               | until(test("\\|\\s*\\|") | not; gsub("\\|\\s*\\|"; "|"))) as $norm |
          ($norm | split(" | ") | map(select(length > 0) | gsub("^\\s+|\\s+$"; "")) | map(select(length > 0)) | reduce .[] as $seg (
            {};
            if ($seg | test("^decision:"; "i")) then .decision = ($seg | sub("^decision:\\s*"; ""; "i"))
            elif ($seg | test("^pattern:"; "i")) then .pattern = ($seg | sub("^pattern:\\s*"; ""; "i"))
            elif ($seg | test("^pitfall:"; "i")) then .pitfall = ($seg | sub("^pitfall:\\s*"; ""; "i"))
            else
              if .pitfall then .pitfall = .pitfall + " | " + $seg
              elif .pattern then .pattern = .pattern + " | " + $seg
              elif .decision then .decision = .decision + " | " + $seg
              else .note = ((.note // "") + (if .note then " | " else "" end) + $seg)
              end
            end
          ))
        elif ($raw | length > 0) then
          {note: $raw}
        else
          {}
        end) as $p |

        ($C + $id + $N + ": " + ($text | .[0:72])),
        (if $winner then "  " + $Y + "[SUPERSEDED by " + $winner + "]" + $N + " — retained verbatim below, not authoritative" else empty end),
        (if $p.decision then "  " + $G + "Decision:" + $N + " " + $p.decision else empty end),
        (if $p.pattern  then "  " + $G + "Pattern:"  + $N + "  " + $p.pattern  else empty end),
        (if $p.pitfall  then "  " + $Y + "Pitfall:"  + $N + "  " + $p.pitfall  else empty end),
        (if $p.note     then "  Note: " + $p.note else empty end),
        ""
    ' 2>/dev/null
}

# _learnings_format_graph — Slow path: per-row DB queries for --show-graph edges
_learnings_format_graph() {
    local results="$1"
    local superseded_map="${2:-{\}}"
    echo "$results" | jq -c '.[]' | while read -r row; do
        # Extract all fields in one jq call, parsing inline markers from learning
        eval "$(echo "$row" | jq -r '
            .id as $id | .text as $text | .status as $status |
            ((.metadata // "{}") | if type == "string" then fromjson else . end) as $m |
            ($m.decision // null) as $td |
            ($m.pattern // null) as $tp |
            ($m.pitfall // null) as $tpi |
            ($m.learning // "") as $raw |
            (if ($td or $tp or $tpi) then
              {d: ($td // ""), p: ($tp // ""), pi: ($tpi // ""), n: ""}
            elif ($raw | test("^(decision|pattern|pitfall):"; "i")) then
              ($raw | gsub(";\\s*(?<m>(decision|pattern|pitfall):)"; " | \(.m)"; "i")
                   | until(test("\\|\\s*\\|") | not; gsub("\\|\\s*\\|"; "|"))) as $norm |
              ($norm | split(" | ") | map(select(length > 0) | gsub("^\\s+|\\s+$"; "")) | map(select(length > 0)) | reduce .[] as $seg (
                {d:"",p:"",pi:"",n:""};
                if ($seg | test("^decision:"; "i")) then .d = ($seg | sub("^decision:\\s*"; ""; "i"))
                elif ($seg | test("^pattern:"; "i")) then .p = ($seg | sub("^pattern:\\s*"; ""; "i"))
                elif ($seg | test("^pitfall:"; "i")) then .pi = ($seg | sub("^pitfall:\\s*"; ""; "i"))
                else
                  if (.pi | length > 0) then .pi = .pi + " | " + $seg
                  elif (.p | length > 0) then .p = .p + " | " + $seg
                  elif (.d | length > 0) then .d = .d + " | " + $seg
                  else .n = (if (.n | length > 0) then .n + " | " else "" end) + $seg
                  end
                end
              ))
            else
              {d:"",p:"",pi:"",n:$raw}
            end) as $parsed |
            "id=" + ($id | @sh) +
            " text=" + ($text | @sh) +
            " status=" + ($status | @sh) +
            " decision=" + ($parsed.d | @sh) +
            " pattern=" + ($parsed.p | @sh) +
            " pitfall=" + ($parsed.pi | @sh) +
            " learning_note=" + ($parsed.n | @sh)
        ' 2>/dev/null)"

        echo -e "${CYAN}$id${NC}: $text"
        # wv-18b8f5: see cmd_learnings' own comment on the map this is built
        # from -- a superseded learning is retained verbatim on purpose, so
        # it must be labelled, not just kept.
        local _lg_winner
        _lg_winner=$(echo "$superseded_map" | jq -r --arg id "$id" '.[$id] // empty' 2>/dev/null)
        if [ -n "$_lg_winner" ]; then
            echo -e "  ${YELLOW}[SUPERSEDED by $_lg_winner]${NC} — retained verbatim below, not authoritative"
            local _lg_rationale
            _lg_rationale=$(db_query_json "SELECT context FROM edges WHERE type='supersedes' AND source='$_lg_winner' AND target='$id';" 2>/dev/null | \
                jq -r '.[0].context // "" | (try fromjson catch {}).reason // empty' 2>/dev/null)
            [ -n "$_lg_rationale" ] && echo "    Rationale: $_lg_rationale"
        fi
        [ -n "$decision" ] && echo -e "  ${GREEN}Decision:${NC} $decision"
        [ -n "$pattern" ]  && echo -e "  ${GREEN}Pattern:${NC}  $pattern"
        [ -n "$pitfall" ]  && echo -e "  ${YELLOW}Pitfall:${NC}  $pitfall"
        [ -n "$learning_note" ] && echo -e "  Note: $learning_note"

        # Check for addresses edges (outbound)
        local addresses_edges
        addresses_edges=$(db_query "
            SELECT target FROM edges
            WHERE source='$id' AND type='addresses'
        " 2>/dev/null || echo "")

        if [ -n "$addresses_edges" ]; then
            echo -e "  ${GREEN}Addresses:${NC}"
            echo "$addresses_edges" | while IFS= read -r target_id; do
                [ -z "$target_id" ] && continue
                local target_text target_pitfall
                target_text=$(db_query "SELECT text FROM nodes WHERE id='$target_id';" 2>/dev/null)
                target_pitfall=$(db_query_json "SELECT json(metadata) as metadata FROM nodes WHERE id='$target_id';" \
                    | jq -r '.[0].metadata | fromjson | .pitfall // empty' 2>/dev/null || echo "")
                echo "    - $target_id: $target_text"
                [ -n "$target_pitfall" ] && echo "      Pitfall: $target_pitfall"
            done
        fi

        # Check for addressed_by edges (inbound)
        local addressed_by
        addressed_by=$(db_query "
            SELECT source FROM edges
            WHERE target='$id' AND type='addresses'
        " 2>/dev/null || echo "")

        if [ -n "$addressed_by" ]; then
            echo -e "  ${GREEN}Addressed by:${NC}"
            echo "$addressed_by" | while IFS= read -r source_id; do
                [ -z "$source_id" ] && continue
                local source_text
                source_text=$(db_query "SELECT text FROM nodes WHERE id='$source_id';" 2>/dev/null)
                echo "    - $source_id: $source_text"
            done
        fi

        echo ""
    done
}

# ═══════════════════════════════════════════════════════════════════════════
# cmd_refs — Extract cross-references from text
# ═══════════════════════════════════════════════════════════════════════════

# ═══════════════════════════════════════════════════════════════════════════
# cmd_refs — Extract cross-references (decomposed into helpers)
# ═══════════════════════════════════════════════════════════════════════════

# Shared state for cmd_refs helpers
_refs_count=0
_refs_data=""

# Extract all reference types from input text into _refs_data (pipe-delimited).
# Sets _refs_count and _refs_data.
# Args: $1=input text, $2=max_refs
_refs_extract() {
    local input="$1" max_refs="$2"
    _refs_count=0
    _refs_data=""

    # 1. Weave node IDs (wv-xxxxxx) — confidence 0.9
    while IFS= read -r match; do
        [ -z "$match" ] && continue
        [ "$_refs_count" -ge "$max_refs" ] && break
        _refs_count=$((_refs_count + 1))
        _refs_data="${_refs_data}${_refs_count}|${match}|wv show ${match}|weave_id|0.9\n"
    done < <(echo "$input" | grep -oE '\bwv-[0-9a-fA-F]{4,}\b' | sort -u | head -n "$max_refs")

    # 2. GitHub issue references (gh-N or #N with lookbehind) — confidence 0.6
    while IFS= read -r match; do
        [ -z "$match" ] && continue
        [ "$_refs_count" -ge "$max_refs" ] && break
        local num
        num=$(echo "$match" | grep -oE '[0-9]+')
        _refs_count=$((_refs_count + 1))
        _refs_data="${_refs_data}${_refs_count}|${match}|gh issue view ${num}|github_issue|0.6\n"
    done < <(echo "$input" | grep -oP '(gh-[0-9]+|(?<![a-zA-Z0-9])#[0-9]+)' | sort -u | head -n "$max_refs")

    # 3. ADR/RFC references — confidence 0.6
    while IFS= read -r match; do
        [ -z "$match" ] && continue
        [ "$_refs_count" -ge "$max_refs" ] && break
        _refs_count=$((_refs_count + 1))
        _refs_data="${_refs_data}${_refs_count}|${match}|rg -l \"${match}\" docs/|adr_rfc|0.6\n"
    done < <(echo "$input" | grep -oE '\b(ADR|RFC)-[0-9]+\b' | sort -u | head -n "$max_refs")

    # 4. File path references (src/..., docs/..., scripts/..., tests/...) — confidence 0.5
    while IFS= read -r match; do
        [ -z "$match" ] && continue
        [ "$_refs_count" -ge "$max_refs" ] && break
        local clean
        clean=$(echo "$match" | sed 's/[,.:;)]*$//')
        _refs_count=$((_refs_count + 1))
        _refs_data="${_refs_data}${_refs_count}|${clean}|cat ${clean}|file_path|0.5\n"
    done < <(echo "$input" | grep -oE '\b(src|docs|scripts|tests)/[a-zA-Z0-9_/.-]+' | sort -u | head -n "$max_refs")

    # 5. Legacy bead IDs (BEAD-xxx, MEM-xxx, BD-xxx) — deprecated
    while IFS= read -r match; do
        [ -z "$match" ] && continue
        [ "$_refs_count" -ge "$max_refs" ] && break
        _refs_count=$((_refs_count + 1))
        _refs_data="${_refs_data}${_refs_count}|${match}|# Legacy bead: ${match} (deprecated)|legacy_bead|0.2\n"
    done < <(echo "$input" | grep -oE '\b(BEAD|MEM|BD)-[0-9a-zA-Z]+\b' | sort -u | head -n "$max_refs")

    # 6. "See Note N" style references — deprecated
    while IFS= read -r match; do
        [ -z "$match" ] && continue
        [ "$_refs_count" -ge "$max_refs" ] && break
        local note_id
        note_id=$(echo "$match" | grep -oE '[0-9]+')
        _refs_count=$((_refs_count + 1))
        _refs_data="${_refs_data}${_refs_count}|${match}|rg -n \"Note ${note_id}\" docs/|see_note|0.3\n"
    done < <(echo "$input" | grep -oiE 'see note [0-9]+' | sort -u | head -n "$max_refs")
}

# Create edges from --from node to detected references.
# Args: $1=from_node, $2=source_file, $3=interactive (true/false)
_refs_link() {
    local from_node="$1" source_file="$2" interactive="$3"
    local detected_at
    detected_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    # Collect affected nodes for cache invalidation (use temp file to escape subshell)
    local cache_nodes_file
    cache_nodes_file=$(mktemp)
    echo "$from_node" > "$cache_nodes_file"

    echo -e "$_refs_data" | while IFS='|' read -r num ref cmd ref_type confidence; do
        [ -z "$num" ] && continue

        # Only weave_id refs can auto-link; others need --interactive
        local target_node=""
        local auto_link=false

        if [ "$ref_type" = "weave_id" ]; then
            target_node=$(db_query "SELECT id FROM nodes WHERE id='$ref';" 2>/dev/null)
            if [ -n "$target_node" ]; then
                auto_link=true
            fi
        fi

        if [ "$auto_link" = false ] && [ "$interactive" = false ]; then
            echo -e "  ${YELLOW}Skip${NC} ${ref} [${ref_type}] — use --interactive to confirm"
            continue
        fi

        # Interactive confirmation for non-auto refs
        if [ "$auto_link" = false ] && [ "$interactive" = true ]; then
            echo -en "  Link ${ref} [${ref_type}]? (y/n/e=edit) "
            read -r answer </dev/tty
            case "$answer" in
                y|Y) ;;
                e|E)
                    echo -n "  Target node ID: "
                    read -r target_node </dev/tty
                    if [ -z "$target_node" ]; then
                        echo -e "  ${YELLOW}Skipped${NC}"
                        continue
                    fi
                    local exists
                    exists=$(db_query "SELECT COUNT(*) FROM nodes WHERE id='$target_node';" 2>/dev/null)
                    if [ "$exists" = "0" ]; then
                        echo -e "  ${RED}Node $target_node not found, skipping${NC}"
                        continue
                    fi
                    ;;
                *)
                    echo -e "  ${YELLOW}Skipped${NC}"
                    continue
                    ;;
            esac

            if [ -z "$target_node" ]; then
                echo -e "  ${YELLOW}No target node for ${ref}, skipping${NC}"
                continue
            fi
        fi

        [ -z "$target_node" ] && continue

        # Determine edge type and weight
        local edge_type="references"
        local weight="$confidence"
        case "$ref_type" in
            adr_rfc) edge_type="relates_to" ;;
        esac

        # Build context JSON
        local ctx
        ctx=$(jq -c -n \
            --arg sf "$source_file" \
            --arg pat "$ref_type" \
            --arg ref "$ref" \
            --arg det "$detected_at" \
            '{source_file: $sf, pattern: $pat, reference: $ref, detected_at: $det}')
        ctx="${ctx//\'/\'\'}"

        db_query "INSERT INTO edges (source, target, type, weight, context, created_at)
            VALUES ('$from_node', '$target_node', '$edge_type', $weight, '$ctx', CURRENT_TIMESTAMP)
            ON CONFLICT(source, target, type) DO UPDATE SET
                weight = excluded.weight,
                context = excluded.context,
                created_at = CURRENT_TIMESTAMP;"

        echo "$target_node" >> "$cache_nodes_file"
        echo -e "  ${GREEN}✓${NC} ${from_node} → ${target_node} [${edge_type}, w=${weight}]"
    done

    # Invalidate context cache for all affected nodes
    local affected_nodes
    affected_nodes=$(cat "$cache_nodes_file" | tr '\n' ' ')
    rm -f "$cache_nodes_file"
    # shellcheck disable=SC2086  # word-split intentional — affected_nodes is space-delimited ID list
    invalidate_context_cache $affected_nodes

    echo -e "${GREEN}✓${NC} Link pass complete."
}

cmd_refs() {
    local input=""
    local source_file=""
    local max_refs=10
    local output_format="text"
    local link_mode=false
    local from_node=""
    local interactive=false

    # Parse arguments: wv refs <file>, wv refs -t "text", or stdin
    while [ $# -gt 0 ]; do
        case "$1" in
            -t) shift; input="$1" ;;
            --max=*) max_refs="${1#*=}" ;;
            --output=*) output_format="${1#*=}" ;;
            --json) output_format="json" ;;
            --link) link_mode=true ;;
            --from=*) from_node="${1#*=}" ;;
            --interactive) interactive=true ;;
            *)
                if [ -f "$1" ]; then
                    source_file="$1"
                    input=$(cat "$1")
                else
                    input="$1"
                fi
                ;;
        esac
        shift
    done

    # Read from stdin if no input yet. stdin_has_input, not [ ! -t 0 ]: a
    # non-terminal fd 0 is not the same thing as input, and an inherited idle
    # pipe blocked here forever (wv-f541e1).
    if [ -z "$input" ] && stdin_has_input; then
        input=$(cat)
    fi

    if [ -z "$input" ]; then
        echo -e "${RED}Error: input required${NC}" >&2
        echo "Usage: wv refs <file> | wv refs -t \"text\" | echo text | wv refs" >&2
        return 1
    fi

    # Validate --link mode
    if [ "$link_mode" = true ] && [ -z "$from_node" ]; then
        echo -e "${RED}Error: --link requires --from=<node-id>${NC}" >&2
        return 1
    fi
    if [ "$link_mode" = true ]; then
        local from_exists
        from_exists=$(db_query "SELECT COUNT(*) FROM nodes WHERE id='$from_node';")
        if [ "$from_exists" = "0" ]; then
            echo -e "${RED}Error: source node $from_node not found${NC}" >&2
            return 1
        fi
    fi

    # Extract all reference types
    _refs_extract "$input" "$max_refs"

    # Output results
    if [ "$_refs_count" -eq 0 ]; then
        if [ "$output_format" = "json" ]; then
            echo "[]"
        else
            echo "No references found."
        fi
        return 0
    fi

    if [ "$output_format" = "json" ]; then
        echo -e "$_refs_data" | while IFS='|' read -r num ref cmd ref_type confidence; do
            [ -z "$num" ] && continue
            local resolved=""
            if [ "$ref_type" = "weave_id" ]; then
                resolved=$(db_query "SELECT id FROM nodes WHERE id='$ref';" 2>/dev/null || echo "")
            fi
            local edge_type="references"
            case "$ref_type" in
                adr_rfc) edge_type="relates_to" ;;
            esac
            jq -c -n \
                --arg reference "$ref" \
                --arg type "$ref_type" \
                --argjson confidence "$confidence" \
                --arg suggested_cmd "$cmd" \
                --arg suggested_edge_type "$edge_type" \
                --argjson suggested_weight "$confidence" \
                --arg resolved_node_id "$resolved" \
                --arg source_file "$source_file" \
                '{reference: $reference, type: $type, confidence: $confidence, suggested_cmd: $suggested_cmd, suggested_edge_type: $suggested_edge_type, suggested_weight: $suggested_weight, resolved_node_id: ($resolved_node_id | if . == "" then null else . end), source_file: ($source_file | if . == "" then null else . end)}'
        done | jq -s '.'
    else
        echo -e "${CYAN}References found (${_refs_count}):${NC}"
        echo ""
        echo -e "$_refs_data" | while IFS='|' read -r num ref cmd ref_type confidence; do
            [ -z "$num" ] && continue
            echo -e "  ${GREEN}${num}.${NC} ${ref}  ${YELLOW}[${ref_type}]${NC}"
            echo -e "     → ${CYAN}${cmd}${NC}"
            echo ""
        done
        echo -e "${CYAN}Run commands manually to follow references.${NC}"
    fi

    # --link mode: create edges from --from node to detected references
    if [ "$link_mode" = true ] && [ "$_refs_count" -gt 0 ]; then
        _refs_link "$from_node" "$source_file" "$interactive"
    fi
}

# ═══════════════════════════════════════════════════════════════════════════
# cmd_batch — Execute multiple wv commands from stdin or file
# ═══════════════════════════════════════════════════════════════════════════

cmd_batch() {
    local file=""
    local dry_run=false
    local stop_on_error=false

    while [ $# -gt 0 ]; do
        case "$1" in
            --dry-run) dry_run=true ;;
            --stop-on-error) stop_on_error=true ;;
            --*) ;;
            *) file="$1" ;;
        esac
        shift
    done

    local input_source="/dev/stdin"
    if [ -n "$file" ]; then
        if [ ! -f "$file" ]; then
            echo -e "${RED}Error: file '$file' not found${NC}" >&2
            return 1
        fi
        input_source="$file"
    elif ! stdin_has_input; then
        # Without a file the loop below reads /dev/stdin, which blocks forever
        # on a terminal or an inherited idle pipe (wv-f541e1).
        echo -e "${RED}Error: no input on stdin${NC}" >&2
        echo "Usage: wv batch <file> | wv batch < commands.txt" >&2
        return 1
    fi

    db_ensure

    local total=0
    local success=0
    local failed=0
    local skipped=0

    while IFS= read -r line; do
        # Skip blank lines and comments. Whitespace-only counts as blank: a line
        # of spaces survived `[ -z ]`, ran a bare `wv`, printed the help text and
        # was counted as a succeeded command (wv-2c5615).
        [[ -z "${line//[[:space:]]/}" ]] && continue
        [[ "$line" =~ ^[[:space:]]*# ]] && continue

        total=$((total + 1))

        if [ "$dry_run" = true ]; then
            echo "  [$total] $line"
            skipped=$((skipped + 1))
            continue
        fi

        # Parse the line as a wv command (strip leading "wv " if present)
        local cmd_line="$line"
        cmd_line="${cmd_line#wv }"

        # Execute via the main dispatch (call ourselves)
        local script_path
        script_path="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/wv"
        if bash "$script_path" $cmd_line 2>&1; then
            success=$((success + 1))
        else
            echo -e "${RED}✗ Line $total failed:${NC} $line" >&2
            failed=$((failed + 1))
            if [ "$stop_on_error" = true ]; then
                echo -e "${RED}Stopping on error (--stop-on-error)${NC}" >&2
                break
            fi
        fi
    done < "$input_source"

    # An empty stream, an empty file and a comments-only file all reached the
    # summary with nothing executed, and "0 succeeded, 0 failed (of 0)" with
    # rc 0 certified that no-op as success (wv-2c5615). Nothing ran, so nothing
    # is proven — the idle-pipe guard above only covers a stream that never
    # opens, not one that opens empty.
    if [ "$total" -eq 0 ]; then
        echo -e "${RED}Error: no commands to execute${NC}" >&2
        echo "Usage: wv batch <file> | wv batch < commands.txt" >&2
        return 1
    fi

    echo ""
    if [ "$dry_run" = true ]; then
        echo -e "${YELLOW}Dry run: $total command(s) would be executed${NC}"
    else
        echo -e "Batch complete: ${GREEN}$success succeeded${NC}, ${RED}$failed failed${NC} (of $total)"
    fi

    [ "$failed" -gt 0 ] && return 1
    return 0
}

# ═══════════════════════════════════════════════════════════════════════════
# cmd_import — Import from beads JSONL or JSON
# ═══════════════════════════════════════════════════════════════════════════

cmd_import() {
    local file="${1:-}"
    local filter=""
    local dry_run=false
    
    shift || true
    while [ $# -gt 0 ]; do
        case "$1" in
            --filter=*) filter="${1#*=}" ;;
            --dry-run) dry_run=true ;;
        esac
        shift
    done
    
    if [ -z "$file" ] || [ ! -f "$file" ]; then
        echo -e "${RED}Error: file required${NC}" >&2
        echo "Usage: wv import <file.jsonl> [--filter=\"id=xxx\"] [--dry-run]" >&2
        return 1
    fi
    
    db_ensure
    
    local imported=0
    local skipped=0
    
    # Process JSONL or JSON array
    local content
    if head -1 "$file" | grep -q '^\['; then
        # JSON array - convert to JSONL
        content=$(jq -c '.[]' "$file")
    else
        # Already JSONL
        content=$(cat "$file")
    fi
    
    # Count lines for summary
    local total=$(echo "$content" | grep -c '^' || echo 0)
    local imported=0
    
    while read -r line; do
        [ -z "$line" ] && continue
        
        # Extract fields - support both beads format and weave format
        local id text status priority created metadata

        # Try beads format first (title), then weave format (text)
        id=$(echo "$line" | jq -r '.id // empty')
        text=$(echo "$line" | jq -r '.title // .text // empty')
        priority=$(echo "$line" | jq -r '.priority // 2')
        created=$(echo "$line" | jq -r '.created_at // empty')

        # Check if this is a weave node (has .metadata field)
        local has_metadata=$(echo "$line" | jq 'has("metadata")')

        if [ "$has_metadata" = "true" ]; then
            # Weave node - preserve existing metadata and add imported_from
            local meta_type=$(echo "$line" | jq -r '.metadata | type')
            if [ "$meta_type" = "string" ]; then
                # Metadata is JSON string (from archive) - parse it
                metadata=$(echo "$line" | jq -c --arg original_id "$id" '.metadata | (fromjson? // {}) | . + {imported_from: $original_id}')
            else
                # Metadata is already object - use directly
                metadata=$(echo "$line" | jq -c --arg original_id "$id" '.metadata + {imported_from: $original_id}')
            fi

            # Preserve weave status
            status=$(echo "$line" | jq -r '.status // "todo"')
        else
            # Beads node - convert to weave format
            # Map beads status to weave status
            local bd_status=$(echo "$line" | jq -r '.status // "open"')
            case "$bd_status" in
                open) status="todo" ;;
                in_progress) status="active" ;;
                closed) status="done" ;;
                blocked) status="blocked" ;;
                *) status="todo" ;;
            esac

            # Build metadata from beads fields (compact JSON, no newlines)
            local issue_type=$(echo "$line" | jq -r '.issue_type // empty')
            local owner=$(echo "$line" | jq -r '.owner // empty')
            metadata=$(jq -c -n \
                --arg priority "$priority" \
                --arg type "$issue_type" \
                --arg owner "$owner" \
                --arg original_id "$id" \
                '{priority: ($priority | tonumber), type: $type, owner: $owner, imported_from: $original_id}')
        fi
        
        # Apply filter if specified
        if [ -n "$filter" ]; then
            local filter_key="${filter%%=*}"
            local filter_val="${filter#*=}"
            local actual_val=$(echo "$line" | jq -r ".$filter_key // empty")
            if [ "$actual_val" != "$filter_val" ]; then
                continue
            fi
        fi
        
        # Skip if empty text
        if [ -z "$text" ]; then
            continue
        fi
        
        # Generate new weave ID
        local new_id=$(generate_id)
        
        if [ "$dry_run" = true ]; then
            echo -e "${YELLOW}Would import:${NC} $id → $new_id: $text"
        else
            # Escape for SQL into separate variables — wv-360528: escaping in
            # place made the confirmation below print doubled apostrophes, the
            # same leak cmd_add had.
            local sql_text="${text//\'/\'\'}"
            local sql_metadata="${metadata//\'/\'\'}"

            db_query "INSERT OR IGNORE INTO nodes (id, text, status, metadata) VALUES ('$new_id', '$sql_text', '$status', '$sql_metadata');"
            echo -e "${GREEN}✓${NC} $id → $new_id: $text"
        fi
        
        imported=$((imported + 1))
    done <<< "$content"
    
    if [ "$dry_run" = true ]; then
        echo -e "\n${YELLOW}Dry run: would import $imported nodes${NC}"
    else
        echo -e "\n${GREEN}✓ Imported $imported nodes${NC}"
    fi
}

# ═══════════════════════════════════════════════════════════════════════════
# _build_fts_expr — Build FTS5 MATCH expression from a query string
# ═══════════════════════════════════════════════════════════════════════════
# Single-word: text:"word"  (phrase match)
# Multi-word:  text:word1 OR text:word2 OR ...  (token match, BM25 ranked)
# Strips punctuation, stopwords, and short tokens for better recall.

_build_fts_expr() {
    local raw="$1"
    # Strip characters that break FTS5 syntax (dots, parens, colons, slashes, quotes, etc.)
    local cleaned
    cleaned=$(printf '%s' "$raw" | sed 's/[^a-zA-Z0-9 ]/ /g; s/  */ /g; s/^ //; s/ $//')

    # Split into words, filter stopwords and short tokens (<3 chars)
    local words=()
    local w
    for w in $cleaned; do
        # Lowercase for matching
        local lw
        lw=$(printf '%s' "$w" | tr '[:upper:]' '[:lower:]')
        # Skip stopwords and tokens < 3 chars
        case "$lw" in
            the|and|for|with|from|into|that|this|are|was|has|have|not|but|all|can|will|its) continue ;;
        esac
        if [ ${#lw} -lt 3 ]; then continue; fi
        words+=("$lw")
    done

    if [ ${#words[@]} -eq 0 ]; then
        # Fallback: use raw query as phrase match
        local safe="${raw//\"/\"\"}"
        safe="${safe//\'/\'\'}"
        printf 'text:"%s"' "$safe"
        return
    fi

    if [ ${#words[@]} -eq 1 ]; then
        # Single word: phrase match (exact)
        printf 'text:"%s"' "${words[0]}"
        return
    fi

    # Multi-word: OR-separated token match, cap at 12 tokens to keep query fast
    local expr="" i=0
    for w in "${words[@]}"; do
        if [ $i -ge 12 ]; then break; fi
        if [ -n "$expr" ]; then expr="$expr OR "; fi
        expr="${expr}text:${w}"
        i=$((i + 1))
    done
    # Escape single quotes for SQL embedding
    expr="${expr//\'/\'\'}"
    printf '%s' "$expr"
}

# ═══════════════════════════════════════════════════════════════════════════
# _wv_search_python — Invoke the weave_search Python module (hybrid code search)
# ═══════════════════════════════════════════════════════════════════════════

_wv_search_python() {
    local _wv_pypath
    _wv_pypath=$(_wv_python_module_path weave_search)
    _wv_agent_python_exec_module weave_search "$_wv_pypath" "$@"
}

# ═══════════════════════════════════════════════════════════════════════════
# cmd_search — Full-text search nodes using FTS5; --code for chunk/code search
# ═══════════════════════════════════════════════════════════════════════════

cmd_search() {
    local query=""
    local limit=10
    local format="text"
    local status_filter=""
    local type_filter=""
    local learning_only=0
    local code_search=0
    local extra_args=()

    while [ $# -gt 0 ]; do
        case "$1" in
            --code) code_search=1 ;;
            --limit=*) limit="${1#*=}"; extra_args+=("$1") ;;
            --limit) shift; limit="$1"; extra_args+=("--limit=$limit") ;;
            --json) format="json"; extra_args+=("--json") ;;
            --json-v2) format="json-v2"; extra_args+=("--json-v2") ;;
            --status=*) status_filter="${1#*=}" ;;
            --type=*) type_filter="${1#*=}" ;;
            --learning) learning_only=1 ;;
            --mode=*|--model=*|--graph|--quality-db=*|--filter=*) extra_args+=("$1") ;;
            --filter) shift; extra_args+=("--filter=$1") ;;
            --help|-h)
                echo "Usage: wv search <query> [--limit=N] [--json|--json-v2] [--status=STATUS] [--type=TYPE] [--learning]"
                echo "       wv search --code <query> [--limit=N] [--json] [--mode=hybrid|fts|vector] [--graph] [--filter=<expr>]"
                echo ""
                echo "  Without --code: searches Weave graph nodes (FTS5 BM25)"
                echo "  With --code:    searches indexed code chunks (RRF hybrid BM25+cosine)"
                echo "  --type=TYPE:    filter by metadata.type (finding, task, epic, ...)"
                echo "  --learning:     only nodes that have captured learning content"
                echo "  --graph:        attach active Weave nodes + quality churn to results"
                echo "  --filter=EXPR:  constrain code chunks by graph edge type"
                echo "                  Supported: edge-type=<type>, edge-type!=<type>"
                echo "                  Types: blocks, implements, relates_to, addresses, contradicts, resolves"
                echo '                  Example: wv search --code "auth" --filter=edge-type=blocks'
                return 0
                ;;
            -*) echo "Unknown option: $1" >&2; return 1 ;;
            *) query="$query $1" ;;
        esac
        shift
    done

    query="${query# }"  # trim leading space

    if [ -z "$query" ]; then
        echo "Usage: wv search <query> [--limit=N] [--json] [--status=STATUS]" >&2
        echo "       wv search --code <query> [--limit=N] [--mode=hybrid|fts|vector] [--filter=<expr>]" >&2
        return 1
    fi

    # Route --code to the Python hybrid search module
    if [ "$code_search" = "1" ]; then
        # Custom WV_DB overrides may point at a minimal or foreign SQLite file.
        # Skip graph migrations in that case so code search stays read-only.
        if [ -z "$WV_DB_CUSTOM" ]; then
            db_ensure
        fi
        WV_HOT_ZONE="${WV_HOT_ZONE:-}" _wv_search_python "$query" \
            --db="${WV_DB}" --limit="$limit" "${extra_args[@]+"${extra_args[@]}"}"
        return $?
    fi

    if [ -z "$query" ]; then
        echo "Usage: wv search <query> [--limit=N] [--json] [--status=STATUS]" >&2
        return 1
    fi
    
    db_ensure

    # Ensure FTS5 table exists (migration for existing DBs)
    db_migrate_fts5

    # Auto-repair FTS5 if the index is corrupt (probe query to detect before use)
    if ! sqlite3 "$WV_DB" "SELECT 1 FROM nodes_fts WHERE nodes_fts MATCH 'test' LIMIT 1;" \
            >/dev/null 2>&1; then
        db_reindex_fts5 >/dev/null 2>&1 || true
    fi

    # Build FTS5 match expression from query.
    # Single-word queries use phrase match; multi-word queries use OR-separated
    # tokens so that "define Middleware protocol" matches nodes containing any
    # of those words (ranked by BM25 relevance).  This is critical for
    # programmatic callers like _related_learnings that pass full node text.
    local fts_expr
    fts_expr=$(_build_fts_expr "$query")
    # nodes_learning_fts uses column `learning_text`, not `text` — rewrite prefix
    local learning_fts_expr
    learning_fts_expr="${fts_expr//text:/learning_text:}"

    # Build filter clauses
    local status_clause=""
    if [ -n "$status_filter" ]; then
        local safe_status="${status_filter//\'/\'\'}"
        status_clause="AND n.status = '$safe_status'"
    fi

    local type_clause=""
    if [ -n "$type_filter" ]; then
        local safe_type="${type_filter//\'/\'\'}"
        type_clause="AND json_extract(n.metadata, '\$.type') = '$safe_type'"
    fi

    local learning_clause=""
    if [ "$learning_only" = "1" ]; then
        learning_clause="AND (
            json_extract(n.metadata, '\$.decision') IS NOT NULL OR
            json_extract(n.metadata, '\$.pattern') IS NOT NULL OR
            json_extract(n.metadata, '\$.pitfall') IS NOT NULL OR
            json_extract(n.metadata, '\$.learning') IS NOT NULL
        )"
    fi

    # FTS5 search: UNION nodes_fts (title/text) and nodes_learning_fts (decision/pattern/pitfall/learning).
    # Learning matches get 2× weight (BM25 returns negative; multiply by 2.0 makes them more negative = higher rank).
    # Deduplicate by id, keeping the best (lowest) rank per node.
    local has_learning_fts
    has_learning_fts=$(sqlite3 "$WV_DB" \
        "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='nodes_learning_fts';" 2>/dev/null || echo "0")

    # FTS5 bm25() is an auxiliary function and cannot be called inside subqueries
    # that participate in a UNION. Use the built-in `rank` hidden column instead
    # (equivalent to bm25, accessible anywhere). 2× weight for learning matches:
    # BM25 scores are negative; multiplying by 2.0 makes them more negative (higher rank).
    local sql
    if [ "${has_learning_fts:-0}" = "1" ]; then
        sql="
            SELECT id, text, status, MIN(rank) AS rank FROM (
                SELECT n.id, n.text, n.status, f.rank AS rank
                FROM nodes_fts f
                JOIN nodes n ON f.rowid = n.rowid
                WHERE nodes_fts MATCH '$fts_expr'
                $status_clause $type_clause $learning_clause
                UNION ALL
                SELECT n.id, n.text, n.status, lf.rank * 2.0 AS rank
                FROM nodes_learning_fts lf
                JOIN nodes n ON lf.rowid = n.rowid
                WHERE nodes_learning_fts MATCH '$learning_fts_expr'
                $status_clause $type_clause $learning_clause
            )
            GROUP BY id
            ORDER BY rank
            LIMIT $limit;
        "
    else
        sql="
            SELECT n.id, n.text, n.status, f.rank AS rank
            FROM nodes_fts f
            JOIN nodes n ON f.rowid = n.rowid
            WHERE nodes_fts MATCH '$fts_expr'
            $status_clause $type_clause $learning_clause
            ORDER BY rank
            LIMIT $limit;
        "
    fi

    if [ "$format" = "json" ] || [ "$format" = "json-v2" ]; then
        local json_sql
        if [ "${has_learning_fts:-0}" = "1" ]; then
            json_sql="
                SELECT id, text, status, metadata, MIN(rank) AS rank FROM (
                    SELECT n.id, n.text, n.status, n.metadata, f.rank AS rank
                    FROM nodes_fts f
                    JOIN nodes n ON f.rowid = n.rowid
                    WHERE nodes_fts MATCH '$fts_expr'
                    $status_clause $type_clause $learning_clause
                    UNION ALL
                    SELECT n.id, n.text, n.status, n.metadata, lf.rank * 2.0 AS rank
                    FROM nodes_learning_fts lf
                    JOIN nodes n ON lf.rowid = n.rowid
                    WHERE nodes_learning_fts MATCH '$learning_fts_expr'
                    $status_clause $type_clause $learning_clause
                )
                GROUP BY id
                ORDER BY rank
                LIMIT $limit;
            "
        else
            json_sql="
                SELECT n.id, n.text, n.status, n.metadata, f.rank AS rank
                FROM nodes_fts f
                JOIN nodes n ON f.rowid = n.rowid
                WHERE nodes_fts MATCH '$fts_expr'
                $status_clause $type_clause $learning_clause
                ORDER BY rank
                LIMIT $limit;
            "
        fi
        if [ "$format" = "json-v2" ]; then
            db_query_json_v2 "$json_sql"
        else
            db_query_json "$json_sql"
        fi
    else
        local results
        results=$(db_query "$sql")
        
        if [ -z "$results" ]; then
            echo "No matches found for: $query"
            return 0
        fi
        
        echo -e "${CYAN}Search results for:${NC} $query"
        echo ""
        
        local i=1
        while IFS='|' read -r id text status rank; do
            # Truncate text if too long
            local display_text="$text"
            if [ ${#display_text} -gt 60 ]; then
                display_text="${display_text:0:57}..."
            fi
            
            # Status indicator
            local status_color
            case "$status" in
                done) status_color="${GREEN}✓${NC}" ;;
                active) status_color="${YELLOW}►${NC}" ;;
                blocked|blocked-external) status_color="${RED}✗${NC}" ;;
                *) status_color="○" ;;
            esac
            
            printf "%2d. %b %b %s\n" "$i" "$status_color" "${CYAN}$id${NC}" "$display_text"
            i=$((i + 1))
        done <<< "$results"
    fi
}

# ═══════════════════════════════════════════════════════════════════════════
# cmd_reindex — Rebuild FTS5 index from scratch
# ═══════════════════════════════════════════════════════════════════════════

cmd_reindex() {
    local force=false
    
    while [ $# -gt 0 ]; do
        case "$1" in
            --force) force=true ;;
        esac
        shift
    done
    
    db_ensure
    
    echo "Rebuilding full-text search index..."
    
    # Force full rebuild by calling db_reindex_fts5
    if db_reindex_fts5; then
        local count
        count=$(db_query "SELECT COUNT(*) FROM nodes;")
        echo -e "${GREEN}✓${NC} Indexed $count nodes"
    else
        echo -e "${RED}Error: Failed to rebuild index${NC}" >&2
        return 1
    fi
}

# ═══════════════════════════════════════════════════════════════════════════
# cmd_trails — Session context dump/restore for continuity (trails epic S3).
# Canonical command is `wv trails`; `wv breadcrumbs` aliases here for one release.
# The on-disk file is .weave/trails.md; the legacy .weave/breadcrumbs.md is read
# as a fallback (and migrated by cmd_load) so existing repos keep working.
# ═══════════════════════════════════════════════════════════════════════════

cmd_trails() {
    local action="${1:-show}"
    shift || true
    local message="" entry_json="" target_id=""
    # Track which flags were *given*, not just which are non-empty: `--json=` with
    # a malformed value must be rejected, not silently treated as absent (Finding M).
    local message_given=0 json_given=0

    while [ $# -gt 0 ]; do
        case "$1" in
            --message=*|--msg=*) message="${1#*=}"; message_given=1 ;;
            --json=*) entry_json="${1#*=}"; json_given=1 ;;
            save|show|clear|capsule) action="$1" ;;
            wv-*) target_id="$1" ;;
        esac
        shift
    done

    local trail_file="$WEAVE_DIR/trails.md"
    local legacy_file="$WEAVE_DIR/breadcrumbs.md"

    # One flag name must not carry opposite contracts on sibling subcommands
    # (Finding M): --json belongs to capsule, --message to save. A flag given to
    # the wrong subcommand is an error, never a silent no-op.
    if [ "$json_given" -eq 1 ] && [ "$action" != "capsule" ]; then
        echo -e "${RED}Error: --json is only valid for 'wv trails capsule <id>'; 'wv trails $action' takes --message=\"...\"${NC}" >&2
        return 1
    fi
    if [ "$message_given" -eq 1 ] && [ "$action" != "save" ]; then
        echo -e "${RED}Error: --message is only valid for 'wv trails save'; 'wv trails $action' takes --json='{...}'${NC}" >&2
        return 1
    fi

    case "$action" in
        capsule)
            _trails_append "$target_id" "$entry_json"
            ;;
        save)
            _trails_save "$trail_file" "$message"
            ;;
        show)
            # Prefer the new file; fall back to the legacy breadcrumbs.md so a
            # repo that has not yet been migrated still shows its handoff state.
            if [ -f "$trail_file" ]; then
                cat "$trail_file"
            elif [ -f "$legacy_file" ]; then
                cat "$legacy_file"
            else
                echo "No trails found. Start a session and run: wv trails save"
            fi
            ;;
        clear)
            rm -f "$trail_file" "$legacy_file"
            echo -e "${GREEN}✓${NC} Trails cleared."
            ;;
        *)
            echo -e "${RED}Error: unknown action '$action'. Use: show, save, clear, capsule${NC}" >&2
            return 1
            ;;
    esac
}

# _trails_append — append a session-handoff capsule to a node's metadata.trails[]
# (S1 of the trails epic). Append-only: never overwrites. json_patch (used by
# `wv update --metadata`) replaces arrays atomically, so it cannot append — this
# helper does a read-modify-write. Seeds trails from any legacy
# metadata.breadcrumbs object on first append so existing capsules are preserved.
_trails_append() {
    local id="$1" entry_json="$2"

    if [ -z "$id" ]; then
        echo -e "${RED}Error: node id required (e.g. wv trails capsule wv-ab12 --json='{...}')${NC}" >&2
        return 1
    fi
    validate_id "$id" || return 1
    if ! echo "$entry_json" | jq -e 'type == "object"' >/dev/null 2>&1; then
        echo -e "${RED}Error: --json must be a JSON object${NC}" >&2
        return 1
    fi

    local cur_meta
    cur_meta=$(db_query "SELECT COALESCE(metadata,'{}') FROM nodes WHERE id='$(sql_escape "$id")';")
    if [ -z "$cur_meta" ]; then
        echo -e "${RED}Error: node $id not found${NC}" >&2
        return 1
    fi

    # Cap policy (S2): keep the last N entries so the append-only list stays
    # bounded on long-running nodes. Configurable via WV_TRAILS_CAP (default 8).
    local cap="${WV_TRAILS_CAP:-8}"
    [[ "$cap" =~ ^[0-9]+$ ]] && [ "$cap" -gt 0 ] || cap=8

    local new_meta
    new_meta=$(echo "$cur_meta" | jq -c --argjson e "$entry_json" --argjson cap "$cap" '
        # Seed trails from legacy breadcrumbs on first append, then push the entry.
        # Stamp "at" if the caller did not supply one (newest-last in storage).
        (.trails // (if .breadcrumbs then [.breadcrumbs] else [] end)) as $t
        | ($t + [ $e + (if ($e | has("at")) then {} else {at: (now | todateiso8601)} end) ]) as $all
        # Bounded growth: keep only the most recent $cap entries.
        | .trails = (if ($all | length) > $cap then $all[($all | length - $cap):] else $all end)
    ') || {
        echo -e "${RED}Error: failed to build trail entry${NC}" >&2
        return 1
    }
    new_meta="${new_meta//\'/\'\'}"
    db_query "UPDATE nodes SET metadata='$new_meta', updated_at=CURRENT_TIMESTAMP WHERE id='$(sql_escape "$id")';"

    local count
    count=$(echo "$new_meta" | jq '.trails | length' 2>/dev/null || echo "?")
    echo -e "${GREEN}✓${NC} Trail entry appended to $id ($count total)"
}

# _trails_release_lock — drop whichever lock _trails_save acquired. Only one
# mechanism is ever held, so exactly one branch applies.
_trails_release_lock() {
    local fd="$1" dir="$2"
    if [ -n "$fd" ]; then
        eval "exec ${fd}>&-" 2>/dev/null || true
    elif [ -n "$dir" ]; then
        rmdir "$dir" 2>/dev/null || true
    fi
}

# _tr_flatten — collapse a free-form value to a single line for a generated row.
#
# Node text and learning fields are author-controlled and reach these rows
# verbatim. A value carrying a NEWLINE emits extra lines into the generated
# region, so a node whose text contained "## Health" forged a section heading
# there: it satisfied a structure check that should have failed, and it ended
# the row count of the section it appeared in early, which fails the save
# outright. Every row starts with "- **", so once a value is single-line it can
# no longer begin a line with "## " or a reserved marker.
_tr_flatten() {
    printf '%s' "$1" | tr '\n\r\t' '   ' | sed -e 's/  */ /g' -e 's/^ //' -e 's/ $//'
}

_trails_save() {
    local breadcrumb_file="$1"
    local message="$2"

    # Guard: don't materialize WEAVE_DIR for empty/uninitialized repos — same
    # boundary rule as cmd_sync. Without this, hooks running from ~ create ~/.weave/.
    if ! _should_persist_weave_state; then
        return 0
    fi

    mkdir -p "$(dirname "$breadcrumb_file")"

    # ── Serialise the whole read-modify-write ────────────────────────
    # This function reads the existing notes, rebuilds the file and rewrites it.
    # Unserialised, concurrent saves each read the same prior state and the last
    # writer wins: a 20-way probe retained 1 of 20 notes. The lock is held
    # across read, build and write, and the write itself is an atomic rename so
    # no reader observes a half-written file.
    local _tr_lock="${breadcrumb_file}.lock"
    local _tr_lock_fd="" _tr_lock_dir=""
    # Fail closed: a timed-out flock must fall back to the directory lock, never
    # continue unlocked. An earlier -w 15 with `|| true` did exactly that and
    # still lost 5 of 20 concurrent notes, because each save holds the lock for
    # the graph queries below and 20 of them do not fit in 15s.
    local _tr_lock_wait="${WV_TRAILS_LOCK_WAIT:-120}"
    [[ "$_tr_lock_wait" =~ ^[0-9]+$ ]] && [ "$_tr_lock_wait" -gt 0 ] || _tr_lock_wait=120
    # Exactly ONE mechanism is used, chosen by availability before any process
    # participates. Falling back from a timed-out flock to a directory lock made
    # the two independent: the waiter took the directory lock and wrote while the
    # original flock holder was still live. A timeout is contention, not a licence
    # to proceed, so it fails and the caller retries.
    if command -v flock >/dev/null 2>&1; then
        if ! exec {_tr_lock_fd}>"$_tr_lock" 2>/dev/null; then
            echo -e "${RED}Error: cannot open trails lock $_tr_lock${NC}" >&2
            return 1
        fi
        if ! flock -w "$_tr_lock_wait" "$_tr_lock_fd" 2>/dev/null; then
            eval "exec ${_tr_lock_fd}>&-" 2>/dev/null || true
            echo -e "${RED}Error: another trails save held the lock for more than ${_tr_lock_wait}s; nothing was written${NC}" >&2
            return 1
        fi
    else
        # No flock: a directory lock, never reclaimed on timeout. Removing a lock
        # whose owner has not been proven dead evicts a live writer.
        _tr_lock_dir="${_tr_lock}.d"
        local _tr_spin=0 _tr_spin_max=$((_tr_lock_wait * 20))
        while ! mkdir "$_tr_lock_dir" 2>/dev/null; do
            _tr_spin=$((_tr_spin + 1))
            if [ "$_tr_spin" -gt "$_tr_spin_max" ]; then
                _tr_lock_dir=""
                echo -e "${RED}Error: another trails save held the lock for more than ${_tr_lock_wait}s; nothing was written${NC}" >&2
                echo -e "${YELLOW}  If no save is running, remove the stale lock: rmdir ${_tr_lock}.d${NC}" >&2
                return 1
            fi
            sleep 0.05
        done
    fi

    # ── Notes are append-only (Finding M) ────────────────────────────────────
    # Every other section of this file is regenerated from the graph, so Notes
    # holds the only content a save cannot reconstruct. Rewriting the file with
    # just the new message destroyed committed handoffs, including a session's
    # own CRASH RECOVERY note when a second save followed the first.
    # A note body is free-form markdown and may contain anything, including the
    # delimiters used here. Two rules keep that from truncating the section:
    #   - on write, any line that would collide with a reserved marker is
    #     neutralised with a single leading space (renders identically);
    #   - on read, the section ends at the LAST end marker in the file, since
    #     every generated marker is written after all note bodies.
    # Files written before the marker existed fall back to matching the
    # generated headings exactly ('## Blocked-looking note' is not one of them).
    # Completion records. `wv done` appends "## <date> — Completed <label>" to
    # the END of this file, below everything the generator writes. A save
    # regenerated the file and carried over the Notes block ALONE, so every
    # completion record was dropped -- and unlike Notes, they are not
    # reconstructable from the graph in the form they were written. A single
    # probe save in this repository destroyed 85 of them (647a6d48). They are
    # captured here and re-appended after the generated body is validated.
    local prior_completions=""
    if [ -f "$breadcrumb_file" ]; then
        prior_completions=$(awk '
            /^## [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2} (—|--) Completed / { found = 1 }
            found { print }
        ' "$breadcrumb_file" 2>/dev/null || true)
    fi

    local prior_notes=""
    if [ -f "$breadcrumb_file" ]; then
        if grep -q '^<!-- /wv-notes -->$' "$breadcrumb_file"; then
            local _end_line
            _end_line=$(grep -n '^<!-- /wv-notes -->$' "$breadcrumb_file" | tail -1 | cut -d: -f1)
            prior_notes=$(awk -v endl="$_end_line" '
                NR >= endl                 { exit }
                /^## Notes[[:space:]]*$/   { inn = 1; next }
                inn                        { print }
            ' "$breadcrumb_file" | sed -e '/./,$!d')
        else
            prior_notes=$(awk '
                /^## Notes[[:space:]]*$/                         { inn = 1; next }
                inn && /^## (Active Work|Recent Learnings|Health)$/ { inn = 0 }
                inn && /^## Ready Work \([0-9]+ unblocked\)$/     { inn = 0 }
                inn && /^## Blocked \([0-9]+\)$/                  { inn = 0 }
                inn                                              { print }
            ' "$breadcrumb_file" | sed -e '/./,$!d')
        fi
    fi
    # Notes written before this release carry no entry marker; label them so
    # they stay attributable once newer entries are stacked above.
    if [ -n "$prior_notes" ] && ! printf '%s\n' "$prior_notes" | grep -q '^<!-- wv-note -->$'; then
        prior_notes=$(printf '<!-- wv-note -->\n### (undated, saved before notes became append-only)\n\n%s' "$prior_notes")
    fi

    # Bounded growth: keep the newest N entries, the new one included. Entries
    # are counted by their generated marker, never by '### ' headings — a note
    # body may contain its own subheadings and must not be split across the cap.
    local notes_cap="${WV_TRAILS_NOTES_CAP:-20}"
    [[ "$notes_cap" =~ ^[0-9]+$ ]] && [ "$notes_cap" -gt 0 ] || notes_cap=20

    local notes_body=""
    if [ -n "$message" ]; then
        # Neutralise reserved markers appearing in the note text itself.
        local safe_message
        safe_message=$(printf '%s\n' "$message" | sed -e 's|^<!-- /wv-notes -->$| <!-- /wv-notes -->|' -e 's|^<!-- wv-note -->$| <!-- wv-note -->|')
        notes_body=$(printf '<!-- wv-note -->\n### %s\n\n%s' "$(date '+%Y-%m-%d %H:%M:%S')" "$safe_message")
    fi
    if [ -n "$prior_notes" ]; then
        local keep="$notes_cap"
        [ -n "$message" ] && keep=$((notes_cap - 1))
        local kept=""
        if [ "$keep" -gt 0 ]; then
            kept=$(printf '%s\n' "$prior_notes" | awk -v cap="$keep" '
                /^<!-- wv-note -->$/ { n++; if (n > cap) exit }
                                     { print }
            ' | sed -e '/./,$!d')
        fi
        if [ -n "$kept" ]; then
            if [ -n "$notes_body" ]; then
                notes_body=$(printf '%s\n\n%s' "$notes_body" "$kept")
            else
                notes_body="$kept"
            fi
        fi
    fi

    local _tr_tmp="${breadcrumb_file}.tmp.$$" _tr_write_rc=0
    local _TR_EOF_SENTINEL="<!-- wv-trails-complete -->"
    # GENERATE, then write ONCE. Earlier attempts keyed on the exit status of a
    # redirected group or subshell; both report only their LAST command, so an
    # earlier failed write followed by successful output still returned 0.
    # `set -e` inside the subshell does not fix it either: measured here, errexit
    # reads as ON via `$-` inside the subshell, a bare `false` runs, and
    # execution CONTINUES — bash suppresses errexit for the dynamic extent of a
    # command invoked in a condition context and subshells inherit that
    # suppression whatever they set themselves. So the status of a multi-write
    # body is not trustworthy in this codebase, by construction.
    #
    # A single write has an unambiguous status, and its byte count is checkable
    # against the content that was supposed to land. Generation failures degrade
    # to shorter content, which the length check catches.
    local _tr_body _tr_bytes
    _tr_body=$(
        _tr_sections=""
        echo "# Session Trails"
        echo ""
        echo "_Saved: $(date '+%Y-%m-%d %H:%M:%S')_"
        echo ""

        # Notes — newest entry first, older entries preserved beneath it.
        # The closing marker delimits free-form note text from the generated
        # sections below, so the next save can read it back without guessing.
        if [ -n "$notes_body" ]; then
            _tr_sections="${_tr_sections}${_tr_sections:+|}## Notes"
            echo "## Notes"
            echo ""
            printf '%s\n' "$notes_body"
            echo ""
            echo "<!-- /wv-notes -->"
            echo ""
        fi

        # Active work
        local active_nodes
        active_nodes=$(db_query_json "
            SELECT id, text, metadata FROM nodes WHERE status='active'
            ORDER BY updated_at DESC, id ASC;
        " 2>/dev/null)
        local active_count
        active_count=$(echo "$active_nodes" | jq 'length' 2>/dev/null || echo "0")
        # Same normalisation as the other three counts, replacing a ${x:-0}
        # default plus a 2>/dev/null that hid the error instead of preventing it.
        [[ "$active_count" =~ ^[0-9]+$ ]] || active_count=0

        if [ "$active_count" -gt 0 ]; then
            _tr_sections="${_tr_sections}${_tr_sections:+|}## Active Work@@$active_count"
            echo "## Active Work"
            echo ""
            echo "$active_nodes" | jq -c '.[]' | while read -r row; do
                local nid ntext ntype
                nid=$(echo "$row" | jq -r '.id')
                ntext=$(_tr_flatten "$(echo "$row" | jq -r '.text')")
                local meta_raw
                meta_raw=$(echo "$row" | jq -r '.metadata // "{}"')
                [[ "$meta_raw" != "{"* ]] && meta_raw=$(echo "$meta_raw" | jq -r '.' 2>/dev/null || echo "{}")
                ntype=$(_tr_flatten "$(echo "$meta_raw" | jq -r '.type // "task"' 2>/dev/null)")
                echo "- **$nid** ($ntype): $ntext"
            done
            echo ""
        fi

        # Ready work (unblocked)
        local ready_count
        ready_count=$(cmd_ready --count 2>/dev/null || echo "0")
        # `|| echo 0` only covers a FAILING command. cmd_ready can succeed and
        # print nothing (fresh repo), and the empty value then reaches [ -gt ]
        # as 'integer expression expected' on stderr and as a blank in Health.
        [[ "$ready_count" =~ ^[0-9]+$ ]] || ready_count=0
        if [ "$ready_count" -gt 0 ]; then
            local ready_nodes ready_shown
            ready_nodes=$(cmd_ready --json 2>/dev/null || echo "[]")
            # The heading states the TOTAL ready count while the body is capped
            # at ten rows. The manifest must record what will be EMITTED, not the
            # total, or every repo with more than ten ready nodes fails its own
            # completeness check and `wv trails save` writes nothing — which is
            # what this repository did at 19 ready. The count is still derived
            # from the data rather than from the echo succeeding, so a failed row
            # write is still detected.
            ready_shown=$(printf '%s' "$ready_nodes" | jq -c '.[]' 2>/dev/null | head -10 | wc -l | tr -d ' ')
            [[ "$ready_shown" =~ ^[0-9]+$ ]] || ready_shown=0
            _tr_sections="${_tr_sections}${_tr_sections:+|}## Ready Work ($ready_count unblocked)@@$ready_shown"
            echo "## Ready Work ($ready_count unblocked)"
            echo ""
            echo "$ready_nodes" | jq -c '.[]' 2>/dev/null | head -10 | while read -r row; do
                local nid ntext
                nid=$(echo "$row" | jq -r '.id')
                ntext=$(_tr_flatten "$(echo "$row" | jq -r '.text')")
                echo "- **$nid**: $ntext"
            done
            echo ""
        fi

        # Blocked work
        local blocked_nodes
        blocked_nodes=$(db_query_json "
            SELECT n.id, n.text FROM nodes n WHERE n.status='blocked'
            ORDER BY n.updated_at DESC, n.id ASC;
        " 2>/dev/null)
        local blocked_count
        blocked_count=$(echo "$blocked_nodes" | jq 'length' 2>/dev/null || echo "0")
        [[ "$blocked_count" =~ ^[0-9]+$ ]] || blocked_count=0
        if [ "$blocked_count" -gt 0 ]; then
            _tr_sections="${_tr_sections}${_tr_sections:+|}## Blocked ($blocked_count)@@$blocked_count"
            echo "## Blocked ($blocked_count)"
            echo ""
            echo "$blocked_nodes" | jq -c '.[]' | while read -r row; do
                local nid ntext
                nid=$(echo "$row" | jq -r '.id')
                ntext=$(_tr_flatten "$(echo "$row" | jq -r '.text')")
                # Find what blocks it
                local blockers
                blockers=$(db_query "
                    SELECT source FROM edges
                    WHERE target='$nid' AND type='blocks'
                    AND source IN (SELECT id FROM nodes WHERE status != 'done');
                " 2>/dev/null | tr '\n' ', ' | sed 's/,$//')
                blockers=$(_tr_flatten "$blockers")
                if [ -n "$blockers" ]; then
                    echo "- **$nid**: $ntext _(blocked by: $blockers)_"
                else
                    echo "- **$nid**: $ntext"
                fi
            done
            echo ""
        fi

        # Recent learnings (last 5)
        local recent_learnings
        recent_learnings=$(db_query_json "
            SELECT id, text, metadata FROM nodes
            WHERE (json_extract(metadata, '$.decision') IS NOT NULL
                OR json_extract(metadata, '$.pattern') IS NOT NULL
                OR json_extract(metadata, '$.pitfall') IS NOT NULL
                OR json_extract(metadata, '$.learning') IS NOT NULL)
            ORDER BY updated_at DESC, id ASC LIMIT 5;
        " 2>/dev/null)
        local learn_count
        learn_count=$(echo "$recent_learnings" | jq 'length' 2>/dev/null || echo "0")
        # Same shape: jq exits 0 and prints nothing when handed empty input.
        [[ "$learn_count" =~ ^[0-9]+$ ]] || learn_count=0
        if [ "$learn_count" -gt 0 ]; then
            _tr_sections="${_tr_sections}${_tr_sections:+|}## Recent Learnings@@$learn_count"
            echo "## Recent Learnings"
            echo ""
            echo "$recent_learnings" | jq -c '.[]' | while read -r row; do
                local nid meta_raw learning decision pattern pitfall
                nid=$(echo "$row" | jq -r '.id')
                meta_raw=$(echo "$row" | jq -r '.metadata // "{}"')
                [[ "$meta_raw" != "{"* ]] && meta_raw=$(echo "$meta_raw" | jq -r '.' 2>/dev/null || echo "{}")
                decision=$(echo "$meta_raw" | jq -r '.decision // empty' 2>/dev/null)
                pattern=$(echo "$meta_raw" | jq -r '.pattern // empty' 2>/dev/null)
                pitfall=$(echo "$meta_raw" | jq -r '.pitfall // empty' 2>/dev/null)
                learning=$(echo "$meta_raw" | jq -r '.learning // empty' 2>/dev/null)
                local parts=""
                [ -n "$decision" ] && parts="decision: $decision" || true
                [ -n "$pattern" ] && parts="${parts:+$parts; }pattern: $pattern" || true
                [ -n "$pitfall" ] && parts="${parts:+$parts; }pitfall: $pitfall" || true
                [ -n "$learning" ] && parts="${parts:+$parts; }note: $learning" || true
                echo "- **$nid**: $(_tr_flatten "$parts")"
            done
            echo ""
        fi

        # Health snapshot
        _tr_sections="${_tr_sections}${_tr_sections:+|}## Health"
        echo "## Health"
        echo ""
        local total active ready blocked done_c
        total=$(db_query "SELECT COUNT(*) FROM nodes;" 2>/dev/null || echo "0")
        active=$(db_query "SELECT COUNT(*) FROM nodes WHERE status='active';" 2>/dev/null || echo "0")
        blocked=$(db_query "SELECT COUNT(*) FROM nodes WHERE status='blocked';" 2>/dev/null || echo "0")
        done_c=$(db_query "SELECT COUNT(*) FROM nodes WHERE status='done';" 2>/dev/null || echo "0")
        echo "Nodes: $total total ($active active, $ready_count ready, $blocked blocked, $done_c done)"
        echo ""

        # Reserved end-of-file sentinel, written LAST. The previous check
        # grepped for `^Nodes: ` anywhere in the file, which a note body can
        # forge — notes are written before the generated sections, so a note
        # line reading "Nodes: ..." satisfied the integrity check while the
        # real generated write had failed.
        echo "$_TR_EOF_SENTINEL sections=$_tr_sections"
    )
    printf '%s\n' "$_tr_body" > "$_tr_tmp"
    _tr_write_rc=$?
    # Byte-exactness: the file must hold exactly the generated content. A short
    # write leaves fewer bytes than were generated, whatever status it reported.
    local _tr_expect
    _tr_expect=$(printf '%s\n' "$_tr_body" | wc -c 2>/dev/null || echo -1)
    _tr_bytes=$(wc -c < "$_tr_tmp" 2>/dev/null || echo 0)
    if [ "${_tr_bytes:-0}" -ne "${_tr_expect:--1}" ]; then
        _tr_write_rc=1
    fi

    # A failed write or rename must not report success. An unwritable directory
    # previously returned 0 and printed "Trails saved" with the note absent —
    # the same fail-open shape as the --json flag this fix started from.
    # Three independent conditions, because they fail for different reasons:
    #   write status  — the single write itself
    #   byte count    — a short write (checked above)
    #   structure     — content that was never GENERATED, which a byte check
    #                   cannot see: a skipped section shortens the body and the
    #                   file matches it exactly.
    # Structure is validated only in the region after the LAST `<!-- /wv-notes -->`
    # marker. Everything there is generated, so a note body cannot forge it —
    # notes are written before that marker, which is why the previous
    # `grep '^Nodes: '` over the whole file was satisfiable by a crafted note.
    # Verifies EVERY section the generator DECLARED, not just one. The generator
    # records each heading in a manifest immediately before emitting it, so a
    # heading whose write fails stays declared but absent — the middle-generation
    # failure a byte check cannot see, because a skipped heading shortens the
    # body and the file then matches that shorter body exactly. Requiring only
    # Health left every other section unguarded.
    _tr_structure_ok() {
        local f="$1" last start gen manifest sec oldifs
        last=$(tail -n 1 "$f" 2>/dev/null)
        case "$last" in "$_TR_EOF_SENTINEL sections="*) ;; *) return 1 ;; esac
        manifest=${last#"$_TR_EOF_SENTINEL sections="}
        # Health is emitted unconditionally; its absence means a truncated manifest.
        case "|$manifest|" in *"|## Health|"*) ;; *) return 1 ;; esac
        # Only the region after the LAST notes marker is generated content, so a
        # note body cannot forge a heading into it.
        start=$(grep -n '^<!-- /wv-notes -->$' "$f" 2>/dev/null | tail -n 1 | cut -d: -f1)
        if [ -n "$start" ]; then
            gen=$(tail -n "+$((start + 1))" "$f" 2>/dev/null)
        else
            gen=$(cat "$f" 2>/dev/null)
        fi
        oldifs="$IFS"
        IFS='|'
        for sec in $manifest; do
            [ -n "$sec" ] || continue
            # A manifest entry may carry the item count the DB reported for that
            # section, as `heading@@N`. Validating headings alone let a section
            # whose BODY failed to emit publish silently: the heading was there,
            # the rows were gone, and the save reported success. The count comes
            # from the query that decided to emit the section, so it is
            # independent of whatever the emission actually produced.
            local want=""
            case "$sec" in
                *"@@"*)
                    want=${sec##*@@}
                    sec=${sec%@@*}
                    ;;
            esac
            if [ -n "$want" ]; then
                local got
                got=$(printf '%s\n' "$gen" | awk -v h="$sec" '
                    $0 == h { inside = 1; next }
                    inside && /^## / { inside = 0 }
                    inside && /^- \*\*/ { n++ }
                    END { print n + 0 }
                ')
                if [ "${got:-0}" -ne "$want" ] 2>/dev/null; then
                    IFS="$oldifs"
                    return 1
                fi
            fi
            if [ "$sec" = "## Notes" ]; then
                # The Notes heading sits inside the notes block, BEFORE the
                # marker, so it cannot be found in the generated region. It is
                # checked against the whole file; forging it gains nothing,
                # since a forged Notes heading is what the notes block is for.
                grep -qxF -- "$sec" "$f" || { IFS="$oldifs"; return 1; }
            elif ! printf '%s\n' "$gen" | grep -qxF -- "$sec"; then
                IFS="$oldifs"
                return 1
            fi
        done
        IFS="$oldifs"
        return 0
    }
    if [ "$_tr_write_rc" -ne 0 ] || [ ! -s "$_tr_tmp" ] || ! _tr_structure_ok "$_tr_tmp"; then
        rm -f "$_tr_tmp" 2>/dev/null || true
        _trails_release_lock "${_tr_lock_fd:-}" "${_tr_lock_dir:-}"
        echo -e "${RED}Error: could not write $_tr_tmp; trails.md is unchanged${NC}" >&2
        return 1
    fi
    # Re-append the completion log, after validation and before the rename.
    # Order matters twice over: the generated body must still END at the
    # sentinel for the structure check to mean anything, and these records must
    # not be scanned as generated section content -- their "## <date>" lines
    # would read as section headings. Appending to the temp file keeps the
    # publish a single atomic rename.
    if [ -n "$prior_completions" ]; then
        if ! printf '\n%s\n' "$prior_completions" >> "$_tr_tmp" 2>/dev/null; then
            rm -f "$_tr_tmp" 2>/dev/null || true
            _trails_release_lock "${_tr_lock_fd:-}" "${_tr_lock_dir:-}"
            echo -e "${RED}Error: could not preserve completion records; $breadcrumb_file is unchanged${NC}" >&2
            return 1
        fi
        # A dropped record is silent data loss, so prove the count survived
        # rather than trusting the append's exit status.
        local _tr_want_c _tr_got_c
        _tr_want_c=$(printf '%s\n' "$prior_completions" | grep -c '^## [0-9]\{4\}-' || true)
        _tr_got_c=$(grep -c '^## [0-9]\{4\}-' "$_tr_tmp" 2>/dev/null || true)
        if [ "${_tr_got_c:-0}" -lt "${_tr_want_c:-0}" ]; then
            rm -f "$_tr_tmp" 2>/dev/null || true
            _trails_release_lock "${_tr_lock_fd:-}" "${_tr_lock_dir:-}"
            echo -e "${RED}Error: completion records were lost while saving; $breadcrumb_file is unchanged${NC}" >&2
            return 1
        fi
    fi

    if ! mv -f "$_tr_tmp" "$breadcrumb_file" 2>/dev/null; then
        rm -f "$_tr_tmp" 2>/dev/null || true
        _trails_release_lock "${_tr_lock_fd:-}" "${_tr_lock_dir:-}"
        echo -e "${RED}Error: could not replace $breadcrumb_file; it is unchanged${NC}" >&2
        return 1
    fi
    _trails_release_lock "${_tr_lock_fd:-}" "${_tr_lock_dir:-}"

    echo -e "${GREEN}✓${NC} Trails saved to .weave/trails.md"
}

# ═══════════════════════════════════════════════════════════════════════════
# cmd_plan — Import structured markdown into graph as epic + tasks
#
# Decomposed into:
#   _plan_show_template    — locate and output PLAN.md.template
#   _plan_parse_markdown   — extract epic title + task arrays from markdown
#   _plan_create_nodes     — create epic + task nodes, link to epic
#   _plan_inject_learnings — FTS5 lookup of related learnings for each task
#   _plan_wire_deps        — resolve (after: alias) into blocks edges
# ═══════════════════════════════════════════════════════════════════════════

# _plan_show_template — locate and print the plan template
_plan_show_template() {
    local template_path=""
    local config_dir="${WV_CONFIG_DIR:-$HOME/.config/weave}"
    if [ -f "$config_dir/PLAN.md.template" ]; then
        template_path="$config_dir/PLAN.md.template"
    elif [ -f "$WV_LIB_DIR/../templates/PLAN.md.template" ]; then
        template_path="$WV_LIB_DIR/../templates/PLAN.md.template"
    elif [ -f "$SCRIPT_DIR/../templates/PLAN.md.template" ]; then
        template_path="$SCRIPT_DIR/../templates/PLAN.md.template"
    fi
    if [ -n "$template_path" ] && [ -f "$template_path" ]; then
        cat "$template_path"
    else
        echo -e "${RED}Error: PLAN.md.template not found${NC}" >&2
        echo "  Checked: $config_dir/PLAN.md.template" >&2
        echo "  Checked: $WV_LIB_DIR/../templates/PLAN.md.template" >&2
        return 1
    fi
}

# _plan_parse_markdown — parse sprint section into parallel arrays
# Sets via nameref: _epic_title, _tasks, _task_aliases, _task_deps,
#                    _task_priorities, _task_statuses
_plan_parse_markdown() {
    local file="$1"
    local sprint="$2"

    _epic_title=""
    _tasks=()
    _task_aliases=()
    _task_deps=()
    _task_priorities=()
    _task_statuses=()

    local in_section=false

    while IFS= read -r line; do
        if [[ "$line" =~ ^###[[:space:]]+Sprint[[:space:]]+${sprint}[[:space:]]*[:—–-][[:space:]]*(.*) ]]; then
            in_section=true
            _epic_title="Sprint ${sprint}: ${BASH_REMATCH[1]}"
            continue
        fi

        if [ "$in_section" = true ]; then
            if [[ "$line" =~ ^#{2,3}[[:space:]] ]] || [[ "$line" =~ ^---+$ ]]; then
                break
            fi
        fi

        # Collect numbered items as tasks (with multi-line continuation)
        if [ "$in_section" = true ] && [[ "$line" =~ ^[0-9]+\.[[:space:]]+(.*) ]]; then
            local task_text="${BASH_REMATCH[1]}"
            local task_status="todo"
            if [[ "$task_text" == "[x] "* ]] || [[ "$task_text" == "[X] "* ]]; then
                task_text="${task_text#\[[xX]\] }"
                task_status="done"
            else
                task_text="${task_text#\[ \] }"
            fi
            local task_alias=""
            if [[ "$task_text" =~ ^\*\*([a-zA-Z0-9][a-zA-Z0-9_-]*)\*\*[[:space:]]*[—–:-][[:space:]]*(.*) ]]; then
                task_alias="${BASH_REMATCH[1]}"
                task_text="${BASH_REMATCH[2]}"
            fi
            task_text="${task_text//\*\*/}"
            local task_priority="2"
            local task_dep=""
            if [[ "$task_text" =~ \(priority:[[:space:]]*([0-9]+)\) ]]; then
                task_priority="${BASH_REMATCH[1]}"
                task_text="${task_text//${BASH_REMATCH[0]}/}"
            fi
            if [[ "$task_text" =~ \(after:[[:space:]]*([a-zA-Z0-9_-]+)\) ]]; then
                task_dep="${BASH_REMATCH[1]}"
                task_text="${task_text//${BASH_REMATCH[0]}/}"
            fi
            if [[ "$task_text" =~ \(status:[[:space:]]*(done|todo|blocked)\) ]]; then
                task_status="${BASH_REMATCH[1]}"
                task_text="${task_text//${BASH_REMATCH[0]}/}"
            fi
            task_text="${task_text%%[[:space:]]}"
            task_text="${task_text%% }"
            _tasks+=("$task_text")
            _task_aliases+=("$task_alias")
            _task_deps+=("$task_dep")
            _task_priorities+=("$task_priority")
            _task_statuses+=("$task_status")
        elif [ "$in_section" = true ] && [ ${#_tasks[@]} -gt 0 ] && [[ "$line" =~ ^[[:space:]]{3,}(.*) ]]; then
            local cont_text="${BASH_REMATCH[1]}"
            cont_text="${cont_text//\*\*/}"
            cont_text="${cont_text%%[[:space:]]}"
            if [ -n "$cont_text" ]; then
                local last_idx=$(( ${#_tasks[@]} - 1 ))
                _tasks[$last_idx]="${_tasks[$last_idx]} $cont_text"
            fi
        fi
    done < "$file"

    # Post-process: re-extract metadata tags from continuation lines
    for i in "${!_tasks[@]}"; do
        local full_text="${_tasks[$i]}"
        if [ -z "${_task_deps[$i]}" ] && [[ "$full_text" =~ \(after:[[:space:]]*([a-zA-Z0-9_-]+)\) ]]; then
            _task_deps[$i]="${BASH_REMATCH[1]}"
            _tasks[$i]="${full_text//${BASH_REMATCH[0]}/}"
        fi
        if [ "${_task_priorities[$i]}" = "2" ] && [[ "${_tasks[$i]}" =~ \(priority:[[:space:]]*([0-9]+)\) ]]; then
            _task_priorities[$i]="${BASH_REMATCH[1]}"
            _tasks[$i]="${_tasks[$i]//${BASH_REMATCH[0]}/}"
        fi
        if [[ "${_tasks[$i]}" =~ \(status:[[:space:]]*(done|todo|blocked)\) ]]; then
            _task_statuses[$i]="${BASH_REMATCH[1]}"
            _tasks[$i]="${_tasks[$i]//${BASH_REMATCH[0]}/}"
        fi
        _tasks[$i]="${_tasks[$i]%%[[:space:]]}"
        _tasks[$i]="${_tasks[$i]%% }"
    done
}

# _plan_create_nodes — create epic + task nodes, link tasks to epic
# Args: epic_title, create_gh, sprint
# Uses: _tasks, _task_aliases, _task_statuses, _task_priorities (from parse)
# Sets: _task_ids, _alias_to_id, _task_count, _fail_count, _epic_id
_plan_create_nodes() {
    local epic_title="$1"
    local create_gh="$2"
    local sprint="$3"

    local gh_flag=""
    [ "$create_gh" = true ] && gh_flag="--gh"

    local epic_output
    epic_output=$(cmd_add "Epic: $epic_title" --metadata="{\"type\":\"epic\",\"sprint\":$sprint}" $gh_flag --force 2>&1 || true)
    _epic_id=$(echo "$epic_output" | tail -1)
    if [ -z "$_epic_id" ] || [[ "$_epic_id" != wv-* ]]; then
        echo -e "${RED}Error: Failed to create epic node${NC}" >&2
        echo "$epic_output" >&2
        return 1
    fi
    echo -e "${GREEN}✓${NC} Epic: $_epic_id -- $epic_title"

    declare -gA _alias_to_id
    _task_ids=()
    _task_count=0
    _fail_count=0

    for i in "${!_tasks[@]}"; do
        local task="${_tasks[$i]}"
        local alias_flag=""
        [ -n "${_task_aliases[$i]}" ] && alias_flag="--alias=${_task_aliases[$i]}"
        local status_flag="--status=${_task_statuses[$i]}"
        local meta="{\"type\":\"task\",\"priority\":${_task_priorities[$i]}}"
        local task_id task_output
        task_output=$(cmd_add "$task" --metadata="$meta" $alias_flag $status_flag $gh_flag --force 2>&1 || true)
        task_id=$(echo "$task_output" | tail -1)
        if [ -z "$task_id" ] || [[ "$task_id" != wv-* ]]; then
            echo -e "${RED}✗ Failed:${NC} $task" >&2
            echo "$task_output" >&2
            _fail_count=$((_fail_count + 1))
            _task_ids+=("")
            continue
        fi
        cmd_link "$task_id" "$_epic_id" --type=implements 2>/dev/null
        _task_ids+=("$task_id")
        [ -n "${_task_aliases[$i]}" ] && _alias_to_id["${_task_aliases[$i]}"]="$task_id"
        local label="$task_id"
        [ -n "${_task_aliases[$i]}" ] && label="$task_id (${_task_aliases[$i]})"
        echo -e "${GREEN}✓${NC} Task: $label -- $task"
        _task_count=$((_task_count + 1))
        if [ "$create_gh" = true ]; then
            sleep 1
        fi
    done
}

# _plan_inject_learnings — FTS5 lookup of related learnings for each task
# Uses: _tasks, _task_ids (from create_nodes)
_plan_inject_learnings() {
    db_migrate_fts5 2>/dev/null || true
    local learnings_count=0

    for i in "${!_tasks[@]}"; do
        [ -z "${_task_ids[$i]}" ] && continue
        local keywords
        keywords=$(echo "${_tasks[$i]}" | tr -cs '[:alnum:]' ' ' | \
            awk '{for(j=1;j<=NF;j++) if(length($j)>4) {printf "%s ", $j; c++; if(c>=5) exit}}')
        keywords=$(echo "$keywords" | sed 's/[(){}*:^~"]//g' | xargs)
        [ -z "$keywords" ] && continue
        local kw_count
        kw_count=$(echo "$keywords" | wc -w)
        [ "$kw_count" -lt 2 ] && continue
        local fts_query
        fts_query=$(echo "$keywords" | sed 's/ / OR /g')
        local learning_ids
        learning_ids=$(db_query "
            SELECT n.id FROM nodes_fts f
            JOIN nodes n ON f.rowid = n.rowid
            WHERE nodes_fts MATCH '$fts_query'
            AND (json_extract(n.metadata, '\$.learning') IS NOT NULL
                 OR json_extract(n.metadata, '\$.pitfall') IS NOT NULL
                 OR json_extract(n.metadata, '\$.decision') IS NOT NULL)
            AND n.id != '${_task_ids[$i]}'
            LIMIT 3;
        " 2>/dev/null || true)
        if [ -n "$learning_ids" ]; then
            local ids_json
            ids_json=$(echo "$learning_ids" | jq -R -s 'split("\n") | map(select(length > 0))' 2>/dev/null || echo "[]")
            local cur_meta_raw cur_meta
            cur_meta_raw=$(db_query_json "SELECT metadata FROM nodes WHERE id='${_task_ids[$i]}';" 2>/dev/null || echo "[]")
            cur_meta=$(echo "$cur_meta_raw" | jq -r '.[0].metadata // "{}"' 2>/dev/null || echo "{}")
            if [[ "$cur_meta" != "{"* ]]; then
                cur_meta=$(echo "$cur_meta" | jq -r '.' 2>/dev/null || echo "{}")
            fi
            local new_meta
            new_meta=$(echo "$cur_meta" | jq --argjson cl "$ids_json" '. + {context_learnings: $cl}' 2>/dev/null || echo "$cur_meta")
            new_meta="${new_meta//\'/\'\'}"
            db_query "UPDATE nodes SET metadata='$new_meta' WHERE id='${_task_ids[$i]}';" 2>/dev/null
            local match_count
            match_count=$(echo "$learning_ids" | wc -l)
            learnings_count=$((learnings_count + match_count))
        fi
    done
    if [ "$learnings_count" -gt 0 ]; then
        echo -e "${CYAN}ℹ Found $learnings_count related learning(s)${NC}" >&2
    fi
}

# _plan_wire_deps — resolve (after: alias) dependencies into blocks edges
# Uses: _task_deps, _task_ids, _task_aliases, _alias_to_id (from create_nodes)
# Sets: _dep_count
_plan_wire_deps() {
    _dep_count=0

    for i in "${!_tasks[@]}"; do
        local dep="${_task_deps[$i]}"
        if [ -n "$dep" ] && [ -n "${_task_ids[$i]}" ]; then
            local dep_id="${_alias_to_id[$dep]:-}"
            if [ -z "$dep_id" ]; then
                dep_id=$(db_query "SELECT id FROM nodes WHERE alias='$(sql_escape "$dep")' ORDER BY CASE WHEN status='done' THEN 1 ELSE 0 END LIMIT 1;" 2>/dev/null)
            fi
            if [ -n "$dep_id" ]; then
                cmd_link "$dep_id" "${_task_ids[$i]}" --type=blocks 2>/dev/null
                echo -e "${CYAN}  ->  ${dep} blocks ${_task_aliases[$i]:-${_task_ids[$i]}}${NC}"
                _dep_count=$((_dep_count + 1))
            else
                echo -e "${YELLOW}Warning: dependency '${dep}' not found for task ${_task_aliases[$i]:-${_task_ids[$i]}}${NC}" >&2
            fi
        fi
    done
}

cmd_plan() {
    local file=""
    local sprint=""
    local dry_run=false
    local create_gh=false
    local show_template=false

    while [ $# -gt 0 ]; do
        case "$1" in
            --sprint=*) sprint="${1#*=}" ;;
            --dry-run)  dry_run=true ;;
            --gh)       create_gh=true ;;
            --template) show_template=true ;;
            --*)        ;; # skip unrecognized flags
            *)          file="$1" ;;
        esac
        shift
    done

    if [ "$show_template" = true ]; then
        _plan_show_template
        return $?
    fi

    if [ -z "$file" ]; then
        echo -e "${RED}Error: markdown file required${NC}" >&2
        echo "Usage: wv plan <file.md> --sprint=N [--dry-run] [--gh]" >&2
        return 1
    fi

    if [ ! -f "$file" ]; then
        echo -e "${RED}Error: file '$file' not found${NC}" >&2
        return 1
    fi

    if [ -z "$sprint" ]; then
        echo -e "${RED}Error: --sprint=N required${NC}" >&2
        echo "Usage: wv plan <file.md> --sprint=N [--dry-run] [--gh]" >&2
        return 1
    fi

    db_ensure

    # Parse markdown into arrays
    _plan_parse_markdown "$file" "$sprint"

    if [ -z "$_epic_title" ]; then
        echo -e "${RED}Error: Sprint $sprint section not found in $file${NC}" >&2
        echo "Expected: ### Sprint ${sprint}: <title>" >&2
        return 1
    fi

    if [ ${#_tasks[@]} -eq 0 ]; then
        echo -e "${YELLOW}Warning: Sprint $sprint section found but no tasks parsed${NC}" >&2
        echo "" >&2
        echo "Expected numbered list format:" >&2
        echo "  1. **alias** -- Task description (priority: 1) (after: other-alias)" >&2
        echo "  2. [x] Already completed task (marks as done)" >&2
        echo "  3. Plain task without alias or metadata" >&2
        echo "" >&2
        echo "Common issues:" >&2
        echo "  - Using bullet points (- or *) instead of numbered list (1. 2. 3.)" >&2
        echo "  - Missing space after number+period (1.Task vs 1. Task)" >&2
        echo "  - Tasks outside the ### Sprint $sprint section boundary" >&2
        return 1
    fi

    # Display parsed plan
    echo -e "${CYAN}Epic:${NC} $_epic_title"
    echo -e "${CYAN}Tasks:${NC} ${#_tasks[@]}"
    for i in "${!_tasks[@]}"; do
        local display="${_tasks[$i]}"
        [ -n "${_task_aliases[$i]}" ] && display="[${_task_aliases[$i]}] $display"
        [ "${_task_statuses[$i]}" = "done" ] && display="$display (done)"
        [ -n "${_task_deps[$i]}" ] && display="$display (after: ${_task_deps[$i]})"
        [ "${_task_priorities[$i]}" != "2" ] && display="$display (P${_task_priorities[$i]})"
        echo "  - $display"
    done

    if [ "$dry_run" = true ]; then
        echo -e "\n${YELLOW}Dry run -- no nodes created${NC}"
        return 0
    fi

    # Create nodes, inject learnings, wire dependencies
    _plan_create_nodes "$_epic_title" "$create_gh" "$sprint" || return 1
    _plan_inject_learnings

    _plan_wire_deps

    # Unblock sweep: nodes imported as done (via [x]) may have blocks edges
    # that were wired after creation — run a full sweep to fix stale blocked status
    _do_unblock_cascade

    echo ""
    echo -e "${GREEN}Created $_task_count task(s) linked to epic $_epic_id${NC}"
    if [ "$_dep_count" -gt 0 ]; then
        echo -e "${GREEN}Created $_dep_count dependency edge(s)${NC}"
    fi
    if [ "$_fail_count" -gt 0 ]; then
        echo -e "${RED}$_fail_count task(s) failed -- re-run without --gh and use 'wv sync --gh' to batch-create issues${NC}" >&2
    fi

    auto_sync 2>/dev/null || true
}

# ═══════════════════════════════════════════════════════════════════════════
# cmd_enrich_topology — Apply graph topology from JSON spec (one-command)
# ═══════════════════════════════════════════════════════════════════════════

cmd_enrich_topology() {
    local spec_file=""
    local dry_run=false
    local sync_gh=false

    if [ $# -gt 0 ] && [[ ! "$1" =~ ^-- ]]; then
        spec_file="$1"
        shift
    fi

    while [ $# -gt 0 ]; do
        case "$1" in
            --file=*) spec_file="${1#*=}" ;;
            --dry-run) dry_run=true ;;
            --sync-gh) sync_gh=true ;;
            --help|-h)
                cat <<EOF
Usage: wv enrich-topology <spec.json> [--dry-run] [--sync-gh]

Apply epic/task topology in one command from a JSON spec.

Spec keys:
  epic.id | epic.gh_issue           Canonical parent epic node
  epic.type                         Optional metadata.type update (e.g. epic)
  epic.alias                        Optional alias update for parent
  implements.ids[]                  Child node IDs to link --[implements]--> epic
  implements.gh_issues[]            Child GH issue numbers to resolve and link
  blocks.id_pairs[][]               Pairs: ["blocker_id", "blocked_id"]
  blocks.gh_pairs[][]               Pairs: [blocker_gh, blocked_gh]

Examples:
  wv enrich-topology templates/TOPOLOGY-ENRICH.json.template --dry-run
  wv enrich-topology ./topology.sprint13.json --sync-gh
EOF
                return 0
                ;;
            *)
                echo -e "${RED}Error: unknown flag '$1'${NC}" >&2
                return 1
                ;;
        esac
        shift
    done

    if [ -z "$spec_file" ]; then
        echo -e "${RED}Error: spec file required${NC}" >&2
        echo "Usage: wv enrich-topology <spec.json> [--dry-run] [--sync-gh]" >&2
        return 1
    fi
    if [ ! -f "$spec_file" ]; then
        echo -e "${RED}Error: spec file not found: $spec_file${NC}" >&2
        return 1
    fi
    if ! command -v jq >/dev/null 2>&1; then
        echo -e "${RED}Error: jq is required for enrich-topology${NC}" >&2
        return 1
    fi
    if ! jq -e . "$spec_file" >/dev/null 2>&1; then
        echo -e "${RED}Error: invalid JSON spec: $spec_file${NC}" >&2
        return 1
    fi

    db_ensure

    _resolve_id_by_gh() {
        local gh_num="$1"
        db_query "
            SELECT id FROM nodes
            WHERE CAST(json_extract(metadata, '$.gh_issue') AS INTEGER) = $gh_num
            ORDER BY updated_at DESC, id ASC
            LIMIT 1;
        " | head -n1
    }

    local epic_id epic_gh epic_type epic_alias
    epic_id=$(jq -r '.epic.id // empty' "$spec_file")
    epic_gh=$(jq -r '.epic.gh_issue // empty' "$spec_file")
    epic_type=$(jq -r '.epic.type // empty' "$spec_file")
    epic_alias=$(jq -r '.epic.alias // empty' "$spec_file")

    if [ -z "$epic_id" ] && [ -n "$epic_gh" ]; then
        epic_id=$(_resolve_id_by_gh "$epic_gh")
    fi
    if [ -z "$epic_id" ]; then
        echo -e "${RED}Error: could not resolve epic node (provide epic.id or epic.gh_issue)${NC}" >&2
        return 1
    fi
    validate_id "$epic_id" || return 1

    local action_count=0

    _run_or_echo() {
        if [ "$dry_run" = true ]; then
            echo "[dry-run] $*"
        else
            "$@"
        fi
        action_count=$((action_count + 1))
    }

    # Optional epic metadata.type merge
    if [ -n "$epic_type" ]; then
        local raw_meta merged_meta
        raw_meta=$(db_query "SELECT json(COALESCE(metadata,'{}')) FROM nodes WHERE id='$(sql_escape "$epic_id")';")
        [ -z "$raw_meta" ] && raw_meta='{}'
        merged_meta=$(printf '%s' "$raw_meta" | jq -c --arg t "$epic_type" '.type=$t')
        _run_or_echo "wv update '$epic_id' --metadata='${merged_meta}' >/dev/null"
    fi

    # Optional epic alias
    if [ -n "$epic_alias" ]; then
        _run_or_echo "wv update '$epic_id' --alias='${epic_alias}' >/dev/null"
    fi

    # implements.ids[]
    while IFS= read -r child_id; do
        [ -z "$child_id" ] && continue
        _run_or_echo "wv link '$child_id' '$epic_id' --type=implements >/dev/null"
    done < <(jq -r '.implements.ids[]? // empty' "$spec_file")

    # implements.gh_issues[]
    while IFS= read -r child_gh; do
        [ -z "$child_gh" ] && continue
        local resolved_id
        resolved_id=$(_resolve_id_by_gh "$child_gh")
        if [ -z "$resolved_id" ]; then
            echo -e "${YELLOW}Warning: could not resolve GH issue #$child_gh to node ID${NC}" >&2
            continue
        fi
        _run_or_echo "wv link '$resolved_id' '$epic_id' --type=implements >/dev/null"
    done < <(jq -r '.implements.gh_issues[]? // empty' "$spec_file")

    # blocks.id_pairs[][] — [blocker_id, blocked_id]
    while IFS=$'\t' read -r blocker_id blocked_id; do
        [ -z "$blocker_id" ] && continue
        [ -z "$blocked_id" ] && continue
        _run_or_echo "wv block '$blocked_id' --by='$blocker_id' >/dev/null"
    done < <(jq -r '.blocks.id_pairs[]? | @tsv' "$spec_file")

    # blocks.gh_pairs[][] — [blocker_gh, blocked_gh]
    while IFS=$'\t' read -r blocker_gh blocked_gh; do
        [ -z "$blocker_gh" ] && continue
        [ -z "$blocked_gh" ] && continue
        local blocker_id blocked_id
        blocker_id=$(_resolve_id_by_gh "$blocker_gh")
        blocked_id=$(_resolve_id_by_gh "$blocked_gh")
        if [ -z "$blocker_id" ] || [ -z "$blocked_id" ]; then
            echo -e "${YELLOW}Warning: could not resolve GH block pair [$blocker_gh,$blocked_gh]${NC}" >&2
            continue
        fi
        _run_or_echo "wv block '$blocked_id' --by='$blocker_id' >/dev/null"
    done < <(jq -r '.blocks.gh_pairs[]? | @tsv' "$spec_file")

    if [ "$sync_gh" = true ]; then
        if [ "$dry_run" = true ]; then
            echo "[dry-run] wv sync --gh"
        else
            cmd_sync --gh
        fi
    fi

    echo -e "${GREEN}✓${NC} Topology enrichment complete for epic $epic_id ($action_count actions)"
}
