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

# _le_source <lib> -- load a library from beside this file, then from the
# installed locations, falling through a copy that fails to load.
_le_source() {
    local lib="$1" dir guard rc
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
    local message="$1" no_verify="${2:-}" prestaged="" skip_ci
    if ! command -v wv_stage_graph_state >/dev/null 2>&1; then
        prestaged="checkpoint helpers unavailable"
    elif [ "${WV_CHECKPOINT_ALL:-0}" != "1" ]; then
        # A failed listing is not "nothing staged" (wv-9c6ae1).
        prestaged=$(wv_staged_non_graph_state "$PWD") || prestaged="staged files could not be listed"
    fi
    [ -z "$prestaged" ] || return 0
    wv_stage_graph_state "$PWD" 2>/dev/null || true
    git diff --cached --quiet 2>/dev/null && return 0
    # wv-e937f8: [skip ci] applies to the whole PUSH at its tip, not just this
    # commit's own (always .weave-only) diff -- omit it when the unpushed range
    # ahead of upstream already carries non-.weave/ work. wv-179c49: fail toward
    # NOT skipping CI when the marker helper is unavailable or fails.
    skip_ci=$(command -v wv_checkpoint_ci_marker >/dev/null 2>&1 \
        && wv_checkpoint_ci_marker "$PWD" || echo "")
    # The shared rule (wv-checkpoint-ci.sh): an unpushed weave-only checkpoint
    # that no in-flight push is publishing (wv-13db30). Without the helper,
    # never amend.
    if command -v wv_checkpoint_amendable >/dev/null 2>&1 && wv_checkpoint_amendable "$PWD"; then
        # HEAD is an unpushed weave-only checkpoint -- safe to amend.
        WV_AUTO_CHECKPOINT_ACTIVE=1 git commit --amend --no-edit ${no_verify:+"$no_verify"} >/dev/null 2>&1 || \
            WV_AUTO_CHECKPOINT_ACTIVE=1 git commit -m "$message $(date +%H:%M)${skip_ci}" ${no_verify:+"$no_verify"} >/dev/null 2>&1 || true
    else
        WV_AUTO_CHECKPOINT_ACTIVE=1 git commit -m "$message $(date +%H:%M)${skip_ci}" ${no_verify:+"$no_verify"} >/dev/null 2>&1 || true
    fi
    # Stamp the checkpoint so auto_checkpoint sees this commit.
    date +%s > "${_HC_HOT_ZONE:-}/.last_checkpoint" 2>/dev/null || true
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
# No network calls -- wv sync / git push run in SessionEnd or by hand.
# Auto-push was removed (wv-52bf05): wv sync --gh has no timeout, causing
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
    declare -F _hc_refresh >/dev/null && _hc_refresh
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
        local rc=$?
        [ -d "${_HC_HOT_ZONE:-}" ] && printf '%s %s\n' "$(date +%s)" \
            "$([ "$_SC_BLOCKED" = true ] && echo blocked || echo stopped)" > "${_HC_HOT_ZONE}/.session_laststop" 2>/dev/null
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
        IDLE_NODES=$("$_WV" list --status=active --json 2>/dev/null | jq -r --argjson cutoff "$(date -d '30 minutes ago' +%s 2>/dev/null || date -v-30M +%s 2>/dev/null || echo 0)" \
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
        if command -v resolve_agent_id >/dev/null 2>&1; then
            _SC_SELF=$(resolve_agent_id 2>/dev/null || echo "")
        fi
        if [ -n "$_SC_SELF" ]; then
            ACTIVE_COUNT=$("$_WV" query status=active --format=json 2>/dev/null \
                | jq --arg me "$_SC_SELF" '[.[] | select((.metadata.claimed_by // $me) == $me)] | length' 2>/dev/null || echo "0")
        else
            # Agent identity unavailable -- fall back to the global count.
            ACTIVE_COUNT=$("$_WV" query status=active --format=json 2>/dev/null | jq 'length' 2>/dev/null || echo "0")
        fi
        if [ "${ACTIVE_COUNT:-0}" -gt 0 ]; then
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
    UNCOMMITTED=$(git status --porcelain 2>/dev/null | grep -vc '\.weave/' || true)
    if [ "$UNCOMMITTED" -gt 0 ]; then
        echo "Note: $UNCOMMITTED uncommitted change(s). Commit and push before ending your session." >&2
        exit 0
    fi

    # Dirty .weave/ state (sync not yet run). Excludes .weave/deltas/ -- delta
    # files are auto-committed by auto_checkpoint and would otherwise trigger
    # the weave-dirty warning on every response.
    WEAVE_DIRTY=$(git status --porcelain 2>/dev/null | grep '\.weave/' | grep -vc '\.weave/deltas/' || true)
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
        if [ "$WEAVE_DIRTY" -gt 0 ]; then
            echo "Note: $AHEAD unpushed commit(s) + unsaved weave state. Run: /close-session (or wv sync --gh && git add .weave/ && git commit && git push)" >&2
        else
            echo "Note: $AHEAD unpushed commit(s). Run: git push (or /close-session)" >&2
        fi
        exit 0
    fi

    # Retro: surface call-stats when session analysis is enabled and a log exists.
    if [ -n "$_WV" ]; then
        _CALL_STATS=$("$_WV" analyze sessions --call-stats --top=3 --since-days=1 --json 2>/dev/null || true)
        if echo "$_CALL_STATS" | jq -e '.call_stats | length > 0' >/dev/null 2>&1; then
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

# wv_session_end_sync <input> -- final sync before exit: prune, sync, commit
# graph state, push, and clear the crash sentinel (v1.16.0).
wv_session_end_sync() (
    set -e; set +u
    _le_tag_hook
    INPUT="$1"
    _le_source wv-resolve-project || exit 0
    _le_source wv-hook-common || true
    declare -F _hc_refresh >/dev/null && _hc_refresh
    declare -F wv_stage_graph_state >/dev/null || _le_source wv-checkpoint-ci || true
    REASON=$(printf '%s' "$INPUT" | jq -r '.reason // "unknown"' 2>/dev/null || echo unknown)
    cd "$WV_PROJECT_DIR" 2>/dev/null || exit 0

    # Prune before sync so the baseline captures prune state. Without this
    # ordering, pruned nodes reappear on next load (state.sql is dumped
    # pre-prune, and prune DELETEs are suppressed from deltas).
    if [ -x "$WV" ]; then
        "$WV" prune --age=48h >/dev/null 2>&1 || true
    fi

    # Sync Weave state to the git layer + GitHub issue state (best effort).
    # Fast mode is bounded to the union of impacted sets for active nodes; run
    # `wv sync --gh --mode=full` for an exhaustive reconcile.
    if [ -x "$WV" ]; then
        "$WV" sync --gh --mode=fast >/dev/null 2>&1 || true
    fi

    # Local state flush: state.sql reflects the current DB whatever the GH sync
    # did. wv sync --gh may skip nodes outside the fast-mode impacted set; a
    # plain wv sync force-dumps the full DB so wv load on the next session
    # (including post-reboot) does not restore stale active-node status.
    if [ -x "$WV" ]; then
        "$WV" sync >/dev/null 2>&1 || true
    fi

    # Commit .weave/ state to break the drift cycle (prevents stop-check
    # warning on dirty .weave/ from the sync/prune above).
    _le_checkpoint_commit "chore(weave): auto-checkpoint"

    # Push with exponential backoff (multi-agent contention). Skip when no
    # remote is configured (test environments, local-only repos).
    if git remote get-url origin >/dev/null 2>&1; then
        for _se_attempt in 1 2 3 4 5; do
            git push >/dev/null 2>&1 && break
            [ "$_se_attempt" -lt 5 ] && sleep $(( (2 ** _se_attempt) + RANDOM % 3 ))
            git pull --rebase --autostash --quiet >/dev/null 2>&1 || true
        done
    fi

    echo "[$(date -Iseconds)] Session ended: $REASON" >> .claude/session.log 2>/dev/null || true

    # Clear the crash sentinel on clean shutdown. LAST: if sync or push failed
    # and the stop guard blocked exit, the sentinel persists for next session.
    rm -f "${_HC_HOT_ZONE}/.session_sentinel"
    exit 0
)

# wv_pre_compact_context <input> -- commit graph state and print a compact work
# snapshot (~100-200 tokens) before conversation compaction.
wv_pre_compact_context() (
    set -e; set +u
    _le_tag_hook
    _le_source wv-resolve-project || exit 0
    _le_source wv-hook-common || true
    declare -F _hc_refresh >/dev/null && _hc_refresh
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
