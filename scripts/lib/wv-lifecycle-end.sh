#!/bin/bash
# wv-lifecycle-end.sh -- the Stop, SessionEnd and PreCompact hooks, one
# implementation for every host (agnostic-cutover S4d, wv-25903d).
#
# Claude Code's stop-check.sh, session-end-sync.sh and pre-compact-context.sh
# source this file and call one function in-process, as the PostToolUse hooks
# do (S4c); `wv hook dispatch --event=Stop|SessionEnd|PreCompact` calls the
# same functions for Codex. Each function loads what it needs (the project's
# wv, wv-hook-common, the graph-state staging helpers) unless its caller has.
#
# A Stop block is {"decision":"block","reason":...} on stdout with exit 0, the
# one shape both hosts honour: Codex reads any exit but 0 and 2 as a failed
# hook and plain text as invalid output for Stop (wv-5b774a). Each function is
# a subshell holding what its hook script held, so its exits, `cd` and shell
# options are the hook's.
#
# No side effects on source.

[ -n "${_WV_LIFECYCLE_END_LOADED:-}" ] && return 0
_WV_LIFECYCLE_END_LOADED=1
_LE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# _le_install_wait -- once per process, wait (up to 10 s) while an
# ./install.sh holds $CONFIG_DIR/.install-in-progress (wv-f854f6; the lock is
# described in install.sh). The installer's own children skip it.
_le_install_wait() {
    [ -z "${WV_INSTALLING:-}" ] && [ -z "${_WV_INSTALL_WAITED:-}" ] || return 0
    _WV_INSTALL_WAITED=1
    local lock="${WV_CONFIG_DIR:-${HOME}/.config/weave}/.install-in-progress" i=0
    while [ "$i" -lt 100 ] && [ -f "$lock" ] && kill -0 "$(cat "$lock" 2>/dev/null)" 2>/dev/null; do
        sleep 0.1
        i=$((i + 1))
    done
}

# _le_source <lib> -- load a library from beside this file, then from the
# installed locations, falling through a copy that fails to load.
_le_source() {
    local lib="$1" dir guard rc
    _le_install_wait
    for dir in "$_LE_LIB_DIR" "${HOME}/.config/weave/lib" "${HOME}/.local/lib/weave/lib"; do
        [ -r "$dir/$lib.sh" ] || continue
        rc=0
        # shellcheck source=/dev/null
        . "$dir/$lib.sh" 2>/dev/null || rc=$?
        [ "$rc" -ne 0 ] || return 0
        while read -r guard; do unset "$guard"; done < <(compgen -v | grep -E '^_WV_[A-Z0-9_]*_LOADED$')
    done
    return 1
}

# _le_tag_hook -- tag the function's own wv calls hook, keeping a test run's
# tag. Set at entry, not left to wv-hook-common's side effect: that load is
# `|| true`, and a failed one leaves the inherited agent tag (wv-a093ea).
_le_tag_hook() {
    [ "${WV_CALL_SOURCE:-}" = "test" ] || export WV_CALL_SOURCE=hook
}

# _le_checkpoint_commit <label> [--no-verify] -- commit staged graph state as a
# weave-only checkpoint, amending HEAD only when it is itself an unpushed
# weave-only checkpoint: the three-guard rule of auto_checkpoint in
# wv-cmd-data.sh -- (a) unpushed (b) subject matches the checkpoint patterns
# (c) no non-.weave files. wv-822bea/wv-179c49: refuse to commit when the
# caller pre-staged anything outside graph state, so a checkpoint never absorbs
# unrelated in-progress work. wv-2e6341: only graph state is staged; .weave/
# configuration stays in the tree, and without the helpers nothing is committed.
# Prints nothing; returns 0 whether or not it committed.
_le_checkpoint_commit() {
    local message="$1" no_verify="${2:-}" skip_ci
    _le_checkpoint_may_commit || return 0
    wv_stage_graph_state "$PWD" 2>/dev/null || true
    git diff --cached --quiet 2>/dev/null && return 0
    # wv-e937f8: [skip ci] applies to the whole PUSH at its tip, not just this
    # commit's own (always .weave-only) diff -- omit it when the unpushed range
    # ahead of upstream already carries non-.weave/ work. wv-179c49: fail toward
    # NOT skipping CI when the marker helper is unavailable or fails.
    skip_ci=$(command -v wv_checkpoint_ci_marker >/dev/null 2>&1 \
        && wv_checkpoint_ci_marker "$PWD" || echo "")
    _le_checkpoint_write "$message $(date +%H:%M)${skip_ci}" "$no_verify"
    # Stamp the checkpoint so auto_checkpoint sees this commit.
    date +%s > "${_HC_HOT_ZONE:-}/.last_checkpoint" 2>/dev/null || true
}

# _le_checkpoint_may_commit -- true when a checkpoint may commit here: the
# switches allow it, the helpers are loaded, and nothing outside graph state
# is already staged (wv-c35b61, split out of _le_checkpoint_commit).
_le_checkpoint_may_commit() {
    local prestaged
    # WV_AUTO_CHECKPOINT=0 or the hold file stop this commit as they stop
    # auto_checkpoint (wv-fbbdff). The variable is read directly so it holds
    # without the helpers too; without them nothing is committed anyway.
    [ "${WV_AUTO_CHECKPOINT:-1}" != "0" ] || return 1
    if command -v wv_auto_commit_enabled >/dev/null 2>&1 && ! wv_auto_commit_enabled "$PWD"; then
        return 1
    fi
    command -v wv_stage_graph_state >/dev/null 2>&1 || return 1
    [ "${WV_CHECKPOINT_ALL:-0}" != "1" ] || return 0
    # A failed listing is not "nothing staged" (wv-9c6ae1).
    prestaged=$(wv_staged_non_graph_state "$PWD") || return 1
    [ -z "$prestaged" ]
}

# _le_checkpoint_write <subject> [--no-verify] -- commit what is staged,
# amending HEAD under the shared rule (wv-checkpoint-ci.sh): an unpushed
# weave-only checkpoint that no in-flight push is publishing (wv-13db30).
# Without the helper, never amend. A failed amend falls back to a new commit.
_le_checkpoint_write() {
    local subject="$1" no_verify="${2:-}"
    if command -v wv_checkpoint_amendable >/dev/null 2>&1 && wv_checkpoint_amendable "$PWD"; then
        # HEAD is an unpushed weave-only checkpoint -- safe to amend.
        WV_AUTO_CHECKPOINT_ACTIVE=1 git commit --amend --no-edit ${no_verify:+"$no_verify"} >/dev/null 2>&1 && return 0
    fi
    WV_AUTO_CHECKPOINT_ACTIVE=1 git commit -m "$subject" ${no_verify:+"$no_verify"} >/dev/null 2>&1 || true
}

# _sc_inflight <self> -- one line naming work in flight on this checkout that
# an open node may be waiting on, or nothing (wv-e229c8): this identity's live
# gate holder (wv_gate_hold_status, wv-c5500d), else a running git commit or
# git push whose working directory is this checkout (a gate before it takes
# the lock, or a push's network phase after it). An empty <self> (identity
# unverifiable) never matches a holder.
_sc_inflight() {
    local out
    out=$(_sc_inflight_holder "$1")
    [ -n "$out" ] || out=$(_sc_inflight_git)
    [ -n "$out" ] && printf '%s\n' "$out"
    return 0
}

# _sc_inflight_holder <self> -- this checkout's live gate holder when <self> holds it.
_sc_inflight_holder() {
    local holder
    [ -n "$1" ] || return 0
    _le_source wv-gate-hold && declare -F wv_gate_hold_status >/dev/null || return 0
    holder=$(wv_gate_hold_status 2>/dev/null)
    [ -n "$holder" ] && [ "$(jq -r '.agent_id // ""' <<< "$holder" 2>/dev/null)" = "$1" ] || return 0
    jq -r '"\(.kind // "gate") gate pid \(.pid) since \(.started_at // "?")\(if (.subject // "") == "" then "" else " (\(.subject))" end)"' <<< "$holder" 2>/dev/null
}

# _sc_inflight_git -- a running git commit or push whose cwd is this checkout.
_sc_inflight_git() {
    local top pid args cwd
    top=$(git rev-parse --show-toplevel 2>/dev/null) || return 0
    for pid in $(pgrep -x git 2>/dev/null); do
        args=$(ps -o args= -p "$pid" 2>/dev/null) || continue
        case " $args " in *" push "*|*" commit "*) ;; *) continue ;; esac
        cwd=$(readlink "/proc/$pid/cwd" 2>/dev/null || lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p')
        [ "$cwd" = "$top" ] || continue
        printf 'git pid %s: %s\n' "$pid" "$args"
        return 0
    done
}

# wv_stop_guard <input> -- the session-end guard.
#
# Hard block: an active node claimed by this agent (contract rule
#   session_end_requires_no_active_node). Decided before any soft warning: the
#   warnings used to exit first, so a dirty tree -- the likeliest state for
#   in-flight work -- let the session end with its node open (wv-fd81b5).
# Soft warn (stderr, never blocks): uncommitted changes, unsaved weave state,
#   unpushed commits.
#
# No network calls -- wv sync --gh and git push run by hand (SessionEnd does
# neither since wv-a32e69). Auto-push was removed (wv-52bf05): wv sync --gh
# has no timeout, causing
# indefinite stalls on every response when the network is slow.
wv_stop_guard() (
    set -e; set +u
    _le_tag_hook
    INPUT="$1"
    STOP_HOOK_ACTIVE=$(printf '%s' "$INPUT" | jq -r '.stop_hook_active // false' 2>/dev/null || echo false)

    # Prevent infinite loops: the host is already continuing after a block.
    [ "$STOP_HOOK_ACTIVE" = "true" ] && exit 0

    _le_source wv-resolve-project || exit 0
    _le_source wv-hook-common || true
    declare -F wv_adopt_hook_session_id >/dev/null && wv_adopt_hook_session_id "${1:-}"
    declare -F _hc_refresh >/dev/null && _hc_refresh
    declare -F wv_hook_run_begin >/dev/null && wv_hook_run_begin Stop
    cd "$WV_PROJECT_DIR" 2>/dev/null || exit 0
    _WV="${WV:-wv}"
    [ -x "$_WV" ] || command -v "$_WV" >/dev/null 2>&1 || _WV=""

    # Record every Stop and how it ended (wv-4efe06): "blocked" when this guard
    # refuses the stop, else "stopped". Session start reads it with the
    # pre-action heartbeat to tell a crash from a blocked exit from a clean stop
    # that skipped SessionEnd. An EXIT trap covers the early exits below.
    _SC_BLOCKED=false
    # shellcheck disable=SC2317  # invoked by the EXIT trap
    _sc_record_stop() {
        local rc=$? stopfile="${_HC_HOT_ZONE:-}/.session_laststop"
        declare -F wv_session_file >/dev/null && stopfile=$(wv_session_file "${_HC_HOT_ZONE:-}" laststop)
        [ -d "${_HC_HOT_ZONE:-}" ] && printf '%s %s\n' "$(date +%s)" \
            "$([ "$_SC_BLOCKED" = true ] && echo blocked || echo stopped)" > "$stopfile" 2>/dev/null
        # This trap replaces the completion stamp's (wv-ca3ffe): stamp here.
        declare -F wv_hook_run_end >/dev/null && wv_hook_run_end "$rc"
        return "$rc"
    }
    trap _sc_record_stop EXIT

    # Cooldown lock: after emitting a block, suppress re-blocking for 120s.
    # The dirty-state checks still run; only the hard block is suppressed.
    # This lets the agent make progress on sync commands without being blocked
    # on every response, while still enforcing a clean state after cooldown.
    _SC_HOT_ZONE="${_HC_HOT_ZONE}"
    _SC_LOCK="${_SC_HOT_ZONE}/.stop_check_lock"
    _SC_IN_COOLDOWN=false
    if [ -f "$_SC_LOCK" ]; then
        _sc_lock_ts=$(cat "$_SC_LOCK" 2>/dev/null || echo 0)
        if [ $(( $(date +%s) - _sc_lock_ts )) -lt 120 ]; then
            _SC_IN_COOLDOWN=true
        fi
    fi

    # Warn on active nodes that haven't been updated recently (crash/abandon
    # signal): >30 min with no update suggests a crashed or abandoned session.
    if [ -n "$_WV" ]; then
        # `list --status=active --json` (db_query_json) carries updated_at;
        # `query --format=json` (json-v2) strips timestamps for leanness.
        IDLE_NODES=$("$_WV" list --status=active --json 2>/dev/null | jq -r --argjson cutoff "$(( $(date +%s) - 1800 ))" \
            '.[] | select(.updated_at != null) | select((.updated_at | strptime("%Y-%m-%d %H:%M:%S") | mktime) < $cutoff) | "  \(.id): \(.text[:60])"' 2>/dev/null || true)
        if [ -n "$IDLE_NODES" ]; then
            echo "Note: active node(s) with no update in >30 min — possible abandoned work:" >&2
            echo "$IDLE_NODES" >&2
            echo "  Close with: wv done <id> --skip-verification" >&2
        fi
    fi

    # Active nodes claimed by THIS agent -- genuine in-flight work, the hard
    # block. Scoped by claimed_by, not a raw global count: a sandboxed Claude
    # Code session and a sandboxed Codex session on the same repo share one hot
    # zone (wv-86ea58), so an active node claimed by a DIFFERENT agent is that
    # agent's in-flight work and must not block this session from ending.
    # Unclaimed nodes still count (defensive default).
    if [ -n "$_WV" ]; then
        _SC_SELF=""
        # An unverifiable session identity leaves _SC_SELF empty, so the guard
        # counts every active node (fail closed, wv-99978b).
        if command -v require_agent_id >/dev/null 2>&1; then
            _SC_SELF=$(require_agent_id 2>/dev/null) || _SC_SELF=""
        fi
        if [ -n "$_SC_SELF" ]; then
            ACTIVE_COUNT=$("$_WV" query status=active --format=json 2>/dev/null \
                | jq --arg me "$_SC_SELF" '[.[] | select((.metadata.claimed_by // $me) == $me)] | length' 2>/dev/null || echo "0")
        else
            # Agent identity unavailable -- fall back to the global count.
            ACTIVE_COUNT=$("$_WV" query status=active --format=json 2>/dev/null | jq 'length' 2>/dev/null || echo "0")
        fi
        # A node held open while its own gate or push runs is waiting on work
        # this hook can see: allow the stop with a note naming it, and arm no
        # cooldown (wv-e229c8). The 120s cooldown is shorter than any gate, so
        # blocking here re-blocked every turn of the wait.
        _SC_INFLIGHT=""
        [ "${ACTIVE_COUNT:-0}" -gt 0 ] && _SC_INFLIGHT=$(_sc_inflight "$_SC_SELF")
        if [ -n "$_SC_INFLIGHT" ]; then
            echo "Note: $ACTIVE_COUNT active node(s) left open while work runs on this checkout: $_SC_INFLIGHT. Close with wv done once it finishes." >&2
        elif [ "${ACTIVE_COUNT:-0}" -gt 0 ]; then
            if [ "$_SC_IN_COOLDOWN" = true ]; then
                echo "Note: $ACTIVE_COUNT active node(s) — close with wv done before ending session (cooldown active)." >&2
            else
                # Not in a base another user could control (wv-80be32).
                hot_zone_ensure "$_SC_HOT_ZONE" 2>/dev/null && date +%s > "$_SC_LOCK" 2>/dev/null || true
                # wv-664b7f: hook-common loads the observer; a Stop decision says so.
                _HC_HOOK_EVENT=Stop
                declare -F _hc_observe >/dev/null && _hc_observe session_end_requires_no_active_node deny
                _SC_BLOCKED=true
                jq -n --arg reason "$ACTIVE_COUNT active node(s) still open — close with: wv done <id> --learning=\"...\" before ending session" \
                    '{decision: "block", reason: $reason}'
                exit 0
            fi
        fi
    fi

    # Uncommitted changes (excluding .weave/ -- infrastructure files
    # auto-committed by auto_checkpoint/SessionEnd, not user work).
    # One status walk serves both checks (wv-3125a9); printf '%s' adds no
    # newline, so a clean tree counts 0, not one empty line.
    PORCELAIN=$(git status --porcelain 2>/dev/null || true)
    UNCOMMITTED=$(printf '%s' "$PORCELAIN" | grep -vc '\.weave/' || true)
    if [ "$UNCOMMITTED" -gt 0 ]; then
        echo "Note: $UNCOMMITTED uncommitted change(s). Commit and push before ending your session." >&2
        exit 0
    fi

    # Dirty .weave/ state (sync not yet run). Excludes .weave/deltas/ -- delta
    # files are auto-committed by auto_checkpoint and would otherwise trigger
    # the weave-dirty warning on every response.
    WEAVE_DIRTY=$(printf '%s' "$PORCELAIN" | grep '\.weave/' | grep -vc '\.weave/deltas/' || true)
    # shellcheck disable=SC1083  # @{u} is a git refspec, not a literal brace
    AHEAD=$(git rev-list --count @{u}..HEAD 2>/dev/null || echo "0")

    if [ "$WEAVE_DIRTY" -gt 0 ] && [ "$AHEAD" -eq 0 ]; then
        # An interrupted sync leaves .weave/repair-checkpoint.json; recommend
        # --mode=repair so the resume picks up from the last node.
        if [ -f .weave/repair-checkpoint.json ]; then
            echo "Note: unsaved weave state and prior sync interrupted. Run: wv sync --gh --mode=repair && git add .weave/ && git commit -m 'chore(weave): sync state [skip ci]' && git push" >&2
        else
            echo "Note: unsaved weave state. Run: wv sync --gh && git add .weave/ && git commit -m 'chore(weave): sync state [skip ci]' && git push" >&2
        fi
        exit 0
    fi

    # Unpushed commits -- soft warn only, no network calls in the hook.
    if [ "$AHEAD" -gt 0 ]; then
        # Counted against the tracking ref, which a refused fetch or a push to
        # a URL leaves stale: commits a recorded push sent are named as such,
        # not as work to push (wv-d235b6).
        local _sc_recorded=0
        if command -v wv_push_recorded_ahead >/dev/null 2>&1; then
            _sc_recorded=$(wv_push_recorded_ahead "$PWD")
            [[ "$_sc_recorded" =~ ^[0-9]+$ ]] || _sc_recorded=0
        fi
        if [ "$_sc_recorded" -ge "$AHEAD" ] && [ "$WEAVE_DIRTY" -eq 0 ]; then
            echo "Note: the $AHEAD commit(s) ahead of the tracking ref were sent by a recorded push; the ref may be stale. Run: git fetch (after a push to a URL: git fetch <url> <branch>:refs/remotes/<remote>/<branch>)" >&2
        elif [ "$WEAVE_DIRTY" -gt 0 ]; then
            echo "Note: $AHEAD unpushed commit(s) + unsaved weave state. Run: /close-session (or wv sync --gh && git add .weave/ && git commit && git push)" >&2
        else
            echo "Note: $AHEAD unpushed commit(s). Run: git push (or /close-session)" >&2
        fi
        exit 0
    fi

    # Retro: surface call-stats when session analysis is enabled and a log exists.
    if [ -n "$_WV" ]; then
        _CALL_STATS=$("$_WV" analyze sessions --call-stats --top=3 --since-days=1 --json 2>/dev/null || true)
        if echo "$_CALL_STATS" | jq -se 'length == 1 and (.[0] | .call_stats | length > 0)' >/dev/null 2>&1; then
            _TOP_CMD=$(echo "$_CALL_STATS" | jq -r '.call_stats[0] | "\(.cmd) (\(.calls) calls, ~\(.approx_tokens|tostring) tok)"' 2>/dev/null || true)
            if [ -n "$_TOP_CMD" ]; then
                echo "Retro: top command today: $_TOP_CMD. Full report: wv analyze sessions --call-stats --since-days=1" >&2
            fi
        fi
    fi

    # Only a session with no active node of its own reaches here: clear any
    # stale cooldown lock so the next session's first block is not skipped.
    if [ "${ACTIVE_COUNT:-0}" -eq 0 ]; then
        rm -f "$_SC_LOCK" 2>/dev/null || true
    fi
    exit 0
)

# wv_session_end_sync <input> -- the local steps before exit: prune, flush
# state.sql, commit graph state, and clear the crash sentinel (v1.16.0).
#
# Only steps that finish in seconds run here (wv-a32e69, owner ruling
# 2026-11-05). The routine stopped completing: .claude/session.log, written by
# its last step, has no entry after 2026-03-10 for any end reason (/exit,
# /clear or other), the GitHub sync that ran here finished in 2 of 13 recorded
# ends and left a half-finished sync journal behind the rest, and the push ran
# the pre-push gate, which takes minutes. SessionEnd also fires on /clear, in
# the middle of a session. Syncing GitHub (wv sync --gh) and pushing belong to
# the session's own work or the operator; the graph state stays committed
# locally until then.
wv_session_end_sync() (
    set -e; set +u
    _le_tag_hook
    INPUT="$1"
    _le_source wv-resolve-project || exit 0
    _le_source wv-hook-common || true
    declare -F wv_adopt_hook_session_id >/dev/null && wv_adopt_hook_session_id "${1:-}"
    declare -F _hc_refresh >/dev/null && _hc_refresh
    declare -F wv_hook_run_begin >/dev/null && wv_hook_run_begin SessionEnd
    declare -F wv_stage_graph_state >/dev/null || _le_source wv-checkpoint-ci || true
    REASON=$(printf '%s' "$INPUT" | jq -r '.reason // "unknown"' 2>/dev/null || echo unknown)
    cd "$WV_PROJECT_DIR" 2>/dev/null || exit 0

    # No prune here (owner ruling 2026-11-09, wv-68c882). A session end used to
    # run 'wv prune --age=48h' unattended (added 2026-02-03 as housekeeping,
    # wv-1748); on 2026-11-09 it removed a 615-node backlog, including nodes live
    # work still cited, and its tombstones were lost, so every fresh load failed
    # (wv-5e5f18). It prevented no independent mistake: its only fix (wv-902612,
    # prune before sync) repaired a resurrection it caused itself. Prune is an
    # explicit command; 'wv prune' writes its tombstones and re-dumps state.sql.

    # Local state flush: a plain wv sync force-dumps the full DB, so wv load
    # on the next session (including post-reboot) does not restore stale
    # active-node status. WV_CHECKPOINT_PULL=0: the sync's auto-checkpoint
    # otherwise pulls with up to five retries and ~34 s of backoff, which an
    # unreachable remote spent in full (33 s measured), past the hook budget,
    # killing the sync inside its journal (wv-a32e69). Nothing is pushed here,
    # so nothing needs pulling.
    if [ -x "$WV" ]; then
        WV_CHECKPOINT_PULL=0 "$WV" sync >/dev/null 2>&1 || true
    fi

    # Commit .weave/ state to break the drift cycle (prevents stop-check
    # warning on dirty .weave/ from the sync/prune above).
    _le_checkpoint_commit "chore(weave): auto-checkpoint"

    echo "[$(date -Iseconds)] Session ended: $REASON" >> .claude/session.log 2>/dev/null || true

    # Clear the crash sentinel on clean shutdown. LAST: if a step above failed
    # and the stop guard blocked exit, the sentinel persists for next session.
    if declare -F wv_session_file >/dev/null; then
        rm -f "$(wv_session_file "$_HC_HOT_ZONE" sentinel)"
    else
        rm -f "${_HC_HOT_ZONE}/.session_sentinel"
    fi
    exit 0
)

# wv_pre_compact_context <input> -- commit graph state and print a compact work
# snapshot (~100-200 tokens) before conversation compaction.
wv_pre_compact_context() (
    set -e; set +u
    _le_tag_hook
    _le_source wv-resolve-project || exit 0
    _le_source wv-hook-common || true
    declare -F wv_adopt_hook_session_id >/dev/null && wv_adopt_hook_session_id "${1:-}"
    declare -F _hc_refresh >/dev/null && _hc_refresh
    declare -F wv_hook_run_begin >/dev/null && wv_hook_run_begin PreCompact
    declare -F wv_stage_graph_state >/dev/null || _le_source wv-checkpoint-ci || true
    cd "$WV_PROJECT_DIR" 2>/dev/null || exit 0
    [ -x "$WV" ] || exit 0
    local_db="${WV_DB:-${_HC_DB}}"

    # Safety commit before compaction: stage only graph state -- code changes
    # belong in intentional feature commits ('git add -A' here raced state.sql
    # across sessions).
    "$WV" sync >/dev/null 2>&1 || true
    _le_checkpoint_commit "wip: pre-compact checkpoint" --no-verify

    STATUS=$("$WV" status 2>/dev/null) || exit 0

    # Active nodes with full text: what is being worked on right now.
    ACTIVE=$(sqlite3 -json "$local_db" "
        SELECT id, text, COALESCE(json_extract(metadata, '$.node_kind'), json_extract(metadata, '$.type')) as type
        FROM nodes WHERE status='active'
        ORDER BY updated_at DESC LIMIT 5;
    " 2>/dev/null | jq -c '.' 2>/dev/null) || ACTIVE="[]"

    # Blocked nodes and what blocks them.
    BLOCKED=$(sqlite3 -json "$local_db" "
        SELECT n.id, n.text,
               group_concat(e.source, ',') as blocked_by
        FROM nodes n
        JOIN edges e ON e.target = n.id AND e.type = 'blocks'
        JOIN nodes blocker ON e.source = blocker.id AND blocker.status != 'done'
        WHERE n.status = 'blocked'
        GROUP BY n.id
        LIMIT 5;
    " 2>/dev/null | jq -c '.' 2>/dev/null) || BLOCKED="[]"

    READY=$("$WV" ready --count 2>/dev/null) || READY="0"

    # Recent learnings (last 3, if any).
    LEARNINGS=$(sqlite3 -json "$local_db" "
        SELECT id,
               json_extract(metadata, '$.decision') as decision,
               json_extract(metadata, '$.pattern') as pattern,
               json_extract(metadata, '$.pitfall') as pitfall
        FROM nodes
        WHERE json_extract(metadata, '$.decision') IS NOT NULL
           OR json_extract(metadata, '$.pattern') IS NOT NULL
           OR json_extract(metadata, '$.pitfall') IS NOT NULL
        ORDER BY updated_at DESC LIMIT 3;
    " 2>/dev/null | jq -c '.' 2>/dev/null) || LEARNINGS="[]"

    # Breadcrumbs for active nodes (session memory capsules): the newest entry
    # of metadata.trails[] (append-only, newest last), falling back to legacy
    # metadata.breadcrumbs. json_each + ROW_NUMBER avoids the $.trails[#-1]
    # index syntax, which needs SQLite >= 3.42 (dev/consumer machines may run older).
    BREADCRUMBS=$(sqlite3 -json "$local_db" "
        SELECT n.id,
               COALESCE(json_extract(lt.entry, '$.goal'),     json_extract(n.metadata, '$.breadcrumbs.goal'))     as goal,
               COALESCE(json_extract(lt.entry, '$.state'),    json_extract(n.metadata, '$.breadcrumbs.state'))    as state,
               COALESCE(json_extract(lt.entry, '$.next'),     json_extract(n.metadata, '$.breadcrumbs.next'))     as next_step,
               COALESCE(json_extract(lt.entry, '$.files'),    json_extract(n.metadata, '$.breadcrumbs.files'))    as files,
               COALESCE(json_extract(lt.entry, '$.blocking'), json_extract(n.metadata, '$.breadcrumbs.blocking')) as blocking
        FROM nodes n
        LEFT JOIN (
            SELECT nodes.id AS nid, je.value AS entry,
                   ROW_NUMBER() OVER (PARTITION BY nodes.id ORDER BY je.key DESC) AS rn
            FROM nodes, json_each(nodes.metadata, '$.trails') je
        ) lt ON lt.nid = n.id AND lt.rn = 1
        WHERE n.status='active'
          AND (json_extract(n.metadata, '$.trails') IS NOT NULL
               OR json_extract(n.metadata, '$.breadcrumbs') IS NOT NULL)
        ORDER BY n.updated_at DESC LIMIT 3;
    " 2>/dev/null | jq -c '.' 2>/dev/null) || BREADCRUMBS="[]"
    # Zero rows is empty output, not a failure, so the fallbacks above never
    # fire for it and the snapshot read 'Active: ' (wv-fea2e9).
    ACTIVE="${ACTIVE:-[]}" BLOCKED="${BLOCKED:-[]}"
    LEARNINGS="${LEARNINGS:-[]}" BREADCRUMBS="${BREADCRUMBS:-[]}"

    cat <<EOF
Weave state (pre-compact snapshot):
$STATUS
Active: $ACTIVE
Blocked: $BLOCKED
Ready: $READY
Learnings: $LEARNINGS
Breadcrumbs: $BREADCRUMBS
EOF
)
