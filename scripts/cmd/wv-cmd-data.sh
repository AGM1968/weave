#!/bin/bash
# wv-cmd-data.sh — Data management commands
#
# Commands: batch, plan, enrich-topology, sync, load, prune, clean-ghosts, learnings, refs, import, search, reindex, breadcrumbs
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
# dump_state_sql — Selective dump excluding FTS index (nodes + edges + meta)
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
# This function dumps only the data tables and the schema preamble needed
# to reconstruct the database. FTS is rebuilt on load via db_rebuild_fts.
# Delta tracking is reinstalled on load via wv_delta_init.
dump_state_sql() {
    local db="$1" outfile="$2"
    {
        sqlite3 -cmd ".timeout 5000" "$db" ".dump nodes" 2>/dev/null
        sqlite3 -cmd ".timeout 5000" "$db" ".dump edges" 2>/dev/null
    } | strip_unistr > "$outfile"
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
    agent_id="${WV_AGENT_ID:-$(hostname)-$(whoami)}"
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

    # Emit delta changeset before the full dump. The changeset captures exactly
    # what changed since the last wv_delta_reset, in causal order (by _warp_changes.id).
    # Stored as .weave/deltas/<YYYY-MM-DD>/<epoch>-<agent_id>.sql — one file per sync
    # cycle per agent. Day-subdirectory prevents single-dir inode bloat over time.
    # These files are committed to git and replayed by other agents on wv load
    # (multi-agent merge). Empty files (no-op cycles) are removed immediately.
    local delta_dir="$WEAVE_DIR/deltas/$(date +%Y-%m-%d)"
    mkdir -p "$delta_dir"
    # Include PID + random to guarantee uniqueness within the same second on
    # the same host — two concurrent agents with the same epoch and agent_id
    # would otherwise overwrite each other's delta file.
    local _rand=$(( RANDOM % 9999 ))
    local delta_file="$delta_dir/${now}-${agent_id}-$$-${_rand}.sql"
    wv_delta_changeset "$WV_DB" > "$delta_file" 2>/dev/null || true
    [ -s "$delta_file" ] || rm -f "$delta_file"

    # Full dump to state.sql — kept as the authoritative snapshot and audit trail.
    # Deltas complement the dump; they are not a replacement. state.sql is what
    # cmd_load uses to reconstruct the DB from scratch; deltas patch it forward.
    mkdir -p "$WEAVE_DIR"
    local tmp_sql tmp_nodes tmp_edges
    tmp_sql=$(mktemp "$WEAVE_DIR/.state.sql.XXXXXX")
    tmp_nodes=$(mktemp "$WEAVE_DIR/.nodes.jsonl.XXXXXX")
    tmp_edges=$(mktemp "$WEAVE_DIR/.edges.jsonl.XXXXXX")

    dump_state_sql "$WV_DB" "$tmp_sql"
    [ -s "$tmp_sql" ] || { rm -f "$tmp_sql" "$tmp_nodes" "$tmp_edges"; return 0; }

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

    db_query_json "SELECT * FROM nodes;" 2>/dev/null | jq -c '.[]' > "$tmp_nodes" 2>/dev/null || true
    db_query_json "SELECT * FROM edges;" 2>/dev/null | jq -c '.[]' > "$tmp_edges" 2>/dev/null || true

    mv "$tmp_sql" "$WEAVE_DIR/state.sql"
    mv "$tmp_nodes" "$WEAVE_DIR/nodes.jsonl"
    mv "$tmp_edges" "$WEAVE_DIR/edges.jsonl"

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
        # Hijack guard: if the caller pre-staged anything outside .weave/,
        # our checkpoint would absorb their intentional commit's payload
        # under a generic auto-checkpoint message. Refuse (exit 0, no commit)
        # and warn to stderr. Escape hatch: WV_CHECKPOINT_ALL=1.
        local prestaged
        prestaged=$(git -C "$git_root" diff --cached --name-only 2>/dev/null \
            | grep -v '^\.weave/' || true)
        if [ -n "$prestaged" ]; then
            {
                echo "wv: auto-checkpoint skipped — non-.weave/ files already staged by caller:"
                echo "$prestaged" | sed 's/^/  /'
                echo "wv: finish your commit first, or set WV_CHECKPOINT_ALL=1 to override."
            } >&2
            return 0
        fi
        # Safe mode: only stage .weave/ graph state
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
        git -C "$git_root" commit \
            -m "chore(weave): auto-checkpoint $ts [skip ci]${trailers}" \
            --no-verify --quiet 2>/dev/null || true
    fi
}

# ═══════════════════════════════════════════════════════════════════════════
# cmd_sync helpers
# ═══════════════════════════════════════════════════════════════════════════

# _sync_gh — Run bidirectional GitHub sync and re-dump state
_sync_gh() {
    local dry_run="$1"
    if ! command -v python3 >/dev/null 2>&1; then
        echo -e "${YELLOW}Warning: python3 not found — cannot run GH sync${NC}" >&2
        return 0
    fi
    echo ""
    local gh_args=()
    [ "$dry_run" = true ] && gh_args+=("--dry-run")
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
    PYTHONPATH="$_wv_pypath" "$_wv_python3" -m weave_gh "${gh_args[@]}"

    # GH sync modifies the in-memory DB — re-dump so git layer captures changes
    local tmp_sql2 tmp_nodes2 tmp_edges2
    tmp_sql2=$(mktemp "$WEAVE_DIR/.state.sql.XXXXXX")
    tmp_nodes2=$(mktemp "$WEAVE_DIR/.nodes.jsonl.XXXXXX")
    tmp_edges2=$(mktemp "$WEAVE_DIR/.edges.jsonl.XXXXXX")
    dump_state_sql "$WV_DB" "$tmp_sql2" && [ -s "$tmp_sql2" ] && mv "$tmp_sql2" "$WEAVE_DIR/state.sql" || rm -f "$tmp_sql2"
    db_query_json "SELECT * FROM nodes;" 2>/dev/null | jq -c '.[]' > "$tmp_nodes2" 2>/dev/null && mv "$tmp_nodes2" "$WEAVE_DIR/nodes.jsonl" || rm -f "$tmp_nodes2"
    db_query_json "SELECT * FROM edges;" 2>/dev/null | jq -c '.[]' > "$tmp_edges2" 2>/dev/null && mv "$tmp_edges2" "$WEAVE_DIR/edges.jsonl" || rm -f "$tmp_edges2"

    # Record GH sync timestamp for visibility in `wv status --json`
    date +%s > "$WV_HOT_ZONE/.last_gh_sync" 2>/dev/null || true
}

# ═══════════════════════════════════════════════════════════════════════════
# cmd_sync — Persist database to git layer
# ═══════════════════════════════════════════════════════════════════════════

cmd_sync() {
    local gh_sync=false
    local dry_run=false
    local format="text"
    while [ $# -gt 0 ]; do
        case "$1" in
            --gh) gh_sync=true ;;
            --dry-run) dry_run=true ;;
            --json) format="json" ;;
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

    # Also export to JSONL for human readability
    db_query_json "SELECT * FROM nodes;" | jq -c '.[]' > "$tmp_nodes" 2>/dev/null || true
    db_query_json "SELECT * FROM edges;" | jq -c '.[]' > "$tmp_edges" 2>/dev/null || true

    # Atomic move (prevents partial writes on interrupt)
    mv "$tmp_sql" "$WEAVE_DIR/state.sql"
    mv "$tmp_nodes" "$WEAVE_DIR/nodes.jsonl"
    mv "$tmp_edges" "$WEAVE_DIR/edges.jsonl"
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
        _sync_gh "$dry_run"
        [ "$_sync_journaled" = true ] && journal_complete 2
    fi

    # Step 3 (or 2 if no GH): Final commit — stage and commit .weave/ if dirty.
    local _sync_commit_step=3
    [ "$gh_sync" != true ] && [ "${WV_GH_SYNC:-0}" != "1" ] && _sync_commit_step=2
    [ "$_sync_journaled" = true ] && journal_step "$_sync_commit_step" "git_commit"

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
            # Check if auto_checkpoint just committed (within throttle window)
            local _sync_now _sync_last_cp _sync_elapsed
            _sync_now=$(date +%s)
            _sync_last_cp=$(git -C "$git_root" log -1 --format=%ct --grep='auto-checkpoint\|pre-compact checkpoint\|sync state' 2>/dev/null || echo 0)
            _sync_elapsed=$((_sync_now - _sync_last_cp))
            # Safe amend: only if recent checkpoint exists AND hasn't been pushed
            local _sync_branch _sync_local_head _sync_remote_head
            _sync_branch=$(git -C "$git_root" branch --show-current 2>/dev/null || echo "main")
            _sync_local_head=$(git -C "$git_root" rev-parse HEAD 2>/dev/null || echo "")
            _sync_remote_head=$(git -C "$git_root" rev-parse "origin/$_sync_branch" 2>/dev/null || echo "none")
            if [ "$_sync_elapsed" -lt "$WV_CHECKPOINT_INTERVAL" ] && [ "$WV_CHECKPOINT_INTERVAL" -gt 0 ] \
               && [ "$_sync_local_head" != "$_sync_remote_head" ]; then
                # Recent unpushed checkpoint — safe to amend
                git -C "$git_root" commit --amend --no-edit \
                    --no-verify --quiet 2>/dev/null || \
                git -C "$git_root" commit \
                    -m "chore(weave): sync state [skip ci]" \
                    --no-verify --quiet 2>/dev/null || true
            else
                git -C "$git_root" commit \
                    -m "chore(weave): sync state [skip ci]" \
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

# ═══════════════════════════════════════════════════════════════════════════
# cmd_load — Load database from git layer
# ═══════════════════════════════════════════════════════════════════════════

cmd_load() {
    mkdir -p "$WV_HOT_ZONE"

    # Pre-flight: flush live DB → state.sql before loading to prevent status
    # regression when in-session wv done closures were throttled and not yet synced.
    auto_sync --force 2>/dev/null || true

    if [ -f "$WEAVE_DIR/state.sql" ]; then
        # Atomic load: import to temp DB first, validate, then replace
        local tmp_db=$(mktemp "$WV_HOT_ZONE/.brain.db.XXXXXX")
        trap 'rm -f "$tmp_db" 2>/dev/null' EXIT

        if strip_unistr < "$WEAVE_DIR/state.sql" | sqlite3 "$tmp_db" 2>/dev/null && \
           sqlite3 "$tmp_db" "SELECT COUNT(*) FROM nodes;" >/dev/null 2>&1; then
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
        # Ordering: files are sorted by filename (<epoch>-<agent>.sql), which
        # sorts by Unix timestamp — causal order within each agent, approximate
        # causal order across agents (clock skew is acceptable; last-writer-wins
        # semantics handle conflicts at the row level).
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
                local skipped=0
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
                        # Pre-validate: a valid delta has at least one SQL keyword.
                        # Files without any SQL are corrupt (e.g. written mid-fsync).
                        if ! grep -qiE "^(INSERT|UPDATE|REPLACE|DELETE|BEGIN|PRAGMA)" "$delta" 2>/dev/null; then
                            echo -e "${YELLOW}⚠ Skipped corrupt delta: ${delta_name}${NC}" >&2
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
                        echo -e "${GREEN}✓${NC} Replayed $delta_count delta(s)" >&2
                    fi
                fi
                sqlite3 "$WV_DB" "PRAGMA foreign_keys = ON;" 2>/dev/null || true
                if [ "$skipped" -gt 0 ]; then
                    echo -e "${YELLOW}ℹ${NC} Skipped $skipped pre-prune delta(s)" >&2
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

    # Save session start snapshot for activity summary
    _save_session_snapshot
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
    
    local count=$(echo "$candidates" | wc -l)
    
    if [ "$dry_run" = true ]; then
        echo -e "${YELLOW}Would prune $count nodes:${NC}"
        echo "$candidates" | while IFS='|' read -r id text updated; do
            echo "  $id: $text (updated: $updated)"
        done
        return
    fi
    
    # Create archive directory
    local archive_dir="$WEAVE_DIR/archive"
    local archive_file="$archive_dir/$(date +%Y-%m-%d).jsonl"
    mkdir -p "$archive_dir"
    
    # Export to archive
    local ids=$(echo "$candidates" | cut -d'|' -f1 | while read -r _id; do printf '%s,' "$(sql_escape "$_id")"; done | sed 's/,$//')
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

    # Close linked GitHub issues before deleting nodes
    if command -v gh >/dev/null 2>&1; then
        local repo
        repo=$(gh repo view --json nameWithOwner -q '.nameWithOwner' 2>/dev/null || echo "")
        if [ -n "$repo" ]; then
            echo "$candidates" | cut -d'|' -f1 | while read -r id; do
                local gh_num
                gh_num=$(db_query "SELECT json_extract(metadata, '\$.gh_issue') FROM nodes WHERE id='$(sql_escape "$id")';" 2>/dev/null)
                if [ -n "$gh_num" ] && [ "$gh_num" != "null" ]; then
                    gh issue close "$gh_num" --repo "$repo" \
                        --comment "Pruned from Weave graph (node \`$id\` archived after ${age})." \
                        >/dev/null 2>&1 && \
                        echo -e "  ${GREEN}✓${NC} Closed GitHub issue #$gh_num ($id)" >&2 || \
                        echo -e "  ${YELLOW}⚠${NC} Could not close GitHub issue #$gh_num ($id)" >&2
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
        ORDER BY updated_at DESC, id ASC $limit_clause;
    "

    local results
    results=$(db_query_json "$query")

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
    local mode_limit=""
    if [ -z "$recent_limit" ]; then
        case "$mode" in
            bootstrap) mode_limit="5" ;;
            discover)  mode_limit="10" ;;
        esac
    fi
    if [ -n "$mode_limit" ] && [ -n "$results" ] && [ "$results" != "[]" ]; then
        results=$(echo "$results" | jq --argjson lim "$mode_limit" '.[0:$lim]' \
            2>/dev/null || echo "$results")
    fi

    if [ "$format" = "json" ]; then
        [ -z "$results" ] && echo "[]" || echo "$results"
        return
    fi

    local count
    [ -z "$results" ] && count=0 || count=$(echo "$results" | jq 'length' 2>/dev/null || echo "0")

    if [ "$count" = "0" ] || [ "$count" = "" ]; then
        echo "No learnings recorded yet."
        return
    fi

    # Fast path: single jq call formats all output (avoids N*9 subprocess spawns)
    if [ "$show_graph" != true ]; then
        _learnings_format_text "$results"
    else
        _learnings_format_graph "$results"
    fi
}

# _learnings_format_text — Compact token-optimised output (single jq call)
# Parses inline markers (decision:/pattern:/pitfall:) from the learning field.
# Uses top-level metadata keys if present, falls back to inline parsing.
_learnings_format_text() {
    local results="$1"
    local _green _yellow _cyan _nc
    printf -v _green '%b' "$GREEN"
    printf -v _yellow '%b' "$YELLOW"
    printf -v _cyan '%b' "$CYAN"
    printf -v _nc '%b' "$NC"
    echo "$results" | jq -r --arg G "$_green" --arg Y "$_yellow" \
        --arg C "$_cyan" --arg N "$_nc" '
        .[] |
        .id as $id | .text as $text |
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

    # Read from stdin if no input yet
    if [ -z "$input" ] && [ ! -t 0 ]; then
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
    fi

    db_ensure

    local total=0
    local success=0
    local failed=0
    local skipped=0

    while IFS= read -r line; do
        # Skip empty lines and comments
        [[ -z "$line" ]] && continue
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
                metadata=$(echo "$line" | jq -c --arg original_id "$id" '.metadata | fromjson | . + {imported_from: $original_id}')
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
            # Escape for SQL
            text="${text//\'/\'\'}"
            metadata="${metadata//\'/\'\'}"
            
            db_query "INSERT OR IGNORE INTO nodes (id, text, status, metadata) VALUES ('$new_id', '$text', '$status', '$metadata');"
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
# cmd_search — Full-text search nodes using FTS5
# ═══════════════════════════════════════════════════════════════════════════

cmd_search() {
    local query=""
    local limit=10
    local format="text"
    local status_filter=""
    
    while [ $# -gt 0 ]; do
        case "$1" in
            --limit=*) limit="${1#*=}" ;;
            --json) format="json" ;;
            --status=*) status_filter="${1#*=}" ;;
            -*) echo "Unknown option: $1" >&2; return 1 ;;
            *) query="$query $1" ;;
        esac
        shift
    done
    
    query="${query# }"  # trim leading space
    
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

    # Build status filter clause
    local status_clause=""
    if [ -n "$status_filter" ]; then
        local safe_status="${status_filter//\'/\'\'}"
        status_clause="AND n.status = '$safe_status'"
    fi

    # FTS5 search with BM25 ranking (search text column only)
    local sql="
        SELECT n.id, n.text, n.status,
               bm25(nodes_fts, 0.0, 1.0, 0.0) AS rank
        FROM nodes_fts f
        JOIN nodes n ON f.rowid = n.rowid
        WHERE nodes_fts MATCH '$fts_expr'
        $status_clause
        ORDER BY rank
        LIMIT $limit;
    "

    if [ "$format" = "json" ]; then
        # For JSON, include full metadata
        local json_sql="
            SELECT n.id, n.text, n.status, n.metadata,
                   bm25(nodes_fts, 0.0, 1.0, 0.0) AS rank
            FROM nodes_fts f
            JOIN nodes n ON f.rowid = n.rowid
            WHERE nodes_fts MATCH '$fts_expr'
            $status_clause
            ORDER BY rank
            LIMIT $limit;
        "
        db_query_json "$json_sql"
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
            
            printf "%2d. %s %s %s\n" "$i" "$status_color" "${CYAN}$id${NC}" "$display_text"
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
# cmd_breadcrumbs — Session context dump/restore for continuity
# ═══════════════════════════════════════════════════════════════════════════

cmd_breadcrumbs() {
    local action="${1:-show}"
    shift || true
    local message=""

    while [ $# -gt 0 ]; do
        case "$1" in
            --message=*|--msg=*) message="${1#*=}" ;;
            save|show|clear) action="$1" ;;
        esac
        shift
    done

    local breadcrumb_file="$WEAVE_DIR/breadcrumbs.md"

    case "$action" in
        save)
            _breadcrumbs_save "$breadcrumb_file" "$message"
            ;;
        show)
            if [ ! -f "$breadcrumb_file" ]; then
                echo "No breadcrumbs found. Start a session and run: wv breadcrumbs save"
                return 0
            fi
            cat "$breadcrumb_file"
            ;;
        clear)
            rm -f "$breadcrumb_file"
            echo -e "${GREEN}✓${NC} Breadcrumbs cleared."
            ;;
        *)
            echo -e "${RED}Error: unknown action '$action'. Use: show, save, clear${NC}" >&2
            return 1
            ;;
    esac
}

_breadcrumbs_save() {
    local breadcrumb_file="$1"
    local message="$2"

    mkdir -p "$(dirname "$breadcrumb_file")"

    {
        echo "# Session Breadcrumbs"
        echo ""
        echo "_Saved: $(date '+%Y-%m-%d %H:%M:%S')_"
        echo ""

        # Custom message
        if [ -n "$message" ]; then
            echo "## Notes"
            echo ""
            echo "$message"
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
        active_count="${active_count:-0}"

        if [ "$active_count" -gt 0 ] 2>/dev/null && [ "$active_count" != "0" ]; then
            echo "## Active Work"
            echo ""
            echo "$active_nodes" | jq -c '.[]' | while read -r row; do
                local nid ntext ntype
                nid=$(echo "$row" | jq -r '.id')
                ntext=$(echo "$row" | jq -r '.text')
                local meta_raw
                meta_raw=$(echo "$row" | jq -r '.metadata // "{}"')
                [[ "$meta_raw" != "{"* ]] && meta_raw=$(echo "$meta_raw" | jq -r '.' 2>/dev/null || echo "{}")
                ntype=$(echo "$meta_raw" | jq -r '.type // "task"' 2>/dev/null)
                echo "- **$nid** ($ntype): $ntext"
            done
            echo ""
        fi

        # Ready work (unblocked)
        local ready_count
        ready_count=$(cmd_ready --count 2>/dev/null || echo "0")
        if [ "$ready_count" -gt 0 ]; then
            echo "## Ready Work ($ready_count unblocked)"
            echo ""
            local ready_nodes
            ready_nodes=$(cmd_ready --json 2>/dev/null || echo "[]")
            echo "$ready_nodes" | jq -c '.[]' 2>/dev/null | head -10 | while read -r row; do
                local nid ntext
                nid=$(echo "$row" | jq -r '.id')
                ntext=$(echo "$row" | jq -r '.text')
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
            echo "## Blocked ($blocked_count)"
            echo ""
            echo "$blocked_nodes" | jq -c '.[]' | while read -r row; do
                local nid ntext
                nid=$(echo "$row" | jq -r '.id')
                ntext=$(echo "$row" | jq -r '.text')
                # Find what blocks it
                local blockers
                blockers=$(db_query "
                    SELECT source FROM edges
                    WHERE target='$nid' AND type='blocks'
                    AND source IN (SELECT id FROM nodes WHERE status != 'done');
                " 2>/dev/null | tr '\n' ', ' | sed 's/,$//')
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
        if [ "$learn_count" -gt 0 ] && [ "$learn_count" != "0" ]; then
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
                [ -n "$decision" ] && parts="decision: $decision"
                [ -n "$pattern" ] && parts="${parts:+$parts; }pattern: $pattern"
                [ -n "$pitfall" ] && parts="${parts:+$parts; }pitfall: $pitfall"
                [ -n "$learning" ] && parts="${parts:+$parts; }note: $learning"
                echo "- **$nid**: $parts"
            done
            echo ""
        fi

        # Health snapshot
        echo "## Health"
        echo ""
        local total active ready blocked done_c
        total=$(db_query "SELECT COUNT(*) FROM nodes;" 2>/dev/null || echo "0")
        active=$(db_query "SELECT COUNT(*) FROM nodes WHERE status='active';" 2>/dev/null || echo "0")
        blocked=$(db_query "SELECT COUNT(*) FROM nodes WHERE status='blocked';" 2>/dev/null || echo "0")
        done_c=$(db_query "SELECT COUNT(*) FROM nodes WHERE status='done';" 2>/dev/null || echo "0")
        echo "Nodes: $total total ($active active, $ready_count ready, $blocked blocked, $done_c done)"
        echo ""

    } > "$breadcrumb_file"

    echo -e "${GREEN}✓${NC} Breadcrumbs saved to .weave/breadcrumbs.md"
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
