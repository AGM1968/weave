#!/bin/bash
# wv-session-start.sh -- the SessionStart work every host runs, behind
# `wv hook dispatch --event=SessionStart` (agnostic-cutover S4a, wv-a523de).
#
# Ported from .claude/hooks/session-start-context.sh, which is now a thin Claude
# adapter, and folded with context-guard.sh's compact policy line, so Codex's
# .codex/hooks.json reaches the same crash detection, shrink guard, phase reset
# and context as Claude Code. Sourced by wv-cmd-hook.sh after wv-hook-common.sh
# and _hc_refresh; scripts/wv has already loaded wv-config.sh (wv_set_phase)
# and wv-checkpoint-ci.sh (the graph-state staging helpers).
#
# Run exactly once per session start. A second run in the same session reads
# the first run's sentinel as a crash, which is why Claude registers a single
# SessionStart hook rather than two that each did part of this.

# _ss_last_prompt <transcript_dir> -- the last prompt of the most recent
# transcript there, best-effort (empty on any failure or unknown format).
_ss_last_prompt() {
    local dir="$1" recent
    [ -d "$dir" ] || return 0
    recent=$(ls -t "$dir"/*.jsonl 2>/dev/null | head -1)
    [ -n "$recent" ] || return 0
    python3 - "$recent" 2>/dev/null <<'PYEOF' || true
import json, sys
last_prompt = ""
last_user = ""
for line in open(sys.argv[1]):
    try:
        d = json.loads(line)
        if d.get("type") == "last-prompt":
            last_prompt = d.get("lastPrompt", "")
        elif d.get("role") == "user":
            content = d.get("message", {}).get("content", "")
            if isinstance(content, list):
                for c in content:
                    if isinstance(c, dict) and c.get("type") == "text":
                        t = c.get("text", "").strip()
                        if t and not t.startswith("<"):
                            last_user = t[:120]
    except Exception:
        pass
print((last_prompt or last_user)[:120])
PYEOF
}

# _ss_summary_line -- the compact one-liner context-guard.sh used to print:
# counts, the context load policy (wv context-policy, wv-f757a4) and the primary
# node. Counts and the primary node come from wv status --json, never from its
# text (wv-a84f42): a scrape that misses prints an empty graph, not an error. A
# status that cannot be read says so. A second line carries the policy's
# directives as context-policy states them (wv-eb061d).
_ss_summary_line() {
    local policy="unknown" policy_json directives status_json work
    policy_json=$("$WV" context-policy --json 2>/dev/null) || policy_json=""
    policy=$(jq -r '.policy // "unknown"' <<< "$policy_json" 2>/dev/null) || policy="unknown"
    [ -n "$policy" ] || policy="unknown"
    directives=$(jq -r '(.directives.text // []) | join(" ")' <<< "$policy_json" 2>/dev/null) || directives=""
    status_json=$("$WV" status --json 2>/dev/null) || status_json=""
    work=$(jq -er --arg policy "$policy" \
        '"\(.active) active, \(.ready) ready, \(.blocked) blocked | policy=\($policy) | current=\(.current.id // "none")"' \
        <<< "$status_json" 2>/dev/null) \
        || work="status unavailable (wv status --json failed) | policy=${policy} | current=unknown"
    printf 'Weave: %s\n' "$work"
    [ -z "$directives" ] || printf 'Context policy %s: %s\n' "$policy" "$directives"
}

# _ss_stamp_begin -- the SessionStart completion stamp (wv-ca3ffe), when
# wv-hook-common is loaded. Helpers keep wv_session_start_context's branch
# count inside the mccabe_max_sh policy.
_ss_stamp_begin() {
    declare -F wv_hook_run_begin >/dev/null || return 0
    wv_hook_run_begin SessionStart
}

# _ss_own_file <hot_zone> <name> -- this session's session-scoped file
# (wv_session_file), or the flat name when the runtime helper is absent.
_ss_own_file() {
    if declare -F wv_session_file >/dev/null; then
        wv_session_file "$1" "$2"
    else
        printf '%s/.session_%s\n' "$1" "$2"
    fi
}

# _ss_previous_session <hot_zone> <project_dir> <own_sentinel> -- collect how
# the previous session ended (wv-4efe06), per session (wv-9a867a). Sets
# _SS_HAD_SENTINEL, _SS_SENTINEL_TS, _SS_HB, _SS_STOP_TS, _SS_STOP_OUTCOME and
# _SS_LIVE_PEER. A sentinel is a session that has not run SessionEnd. This
# session's own is its previous run (a resume after a crash). Another
# session's, while a harness process is working in this checkout, may belong to
# that live peer: it is reported as a peer and none of its files are touched.
# With no live peer, other sessions' sentinels are ended sessions: the newest
# is labelled, and all of their files are removed.
_ss_previous_session() {
    local hz="$1" project="$2" own="$3" s m newest="" newest_m=-1 suffix
    local -a ended=()
    _SS_HAD_SENTINEL=false _SS_SENTINEL_TS="unknown" _SS_HB=0 _SS_STOP_TS=0 _SS_STOP_OUTCOME="" _SS_LIVE_PEER=""
    if declare -F _wv_concurrent_session >/dev/null; then
        _SS_LIVE_PEER=$(_wv_concurrent_session "$project" 2>/dev/null) || _SS_LIVE_PEER=""
    fi
    for s in "$hz"/.session_sentinel "$hz"/.session_sentinel.*; do
        [ -f "$s" ] || continue
        if [ "$s" != "$own" ]; then
            [ -z "$_SS_LIVE_PEER" ] || continue
            ended+=("$s")
        fi
        m=$(wv_stat mtime "$s" || echo 0)
        if [ "$m" -ge "$newest_m" ]; then newest="$s"; newest_m="$m"; fi
    done
    if [ -n "$newest" ]; then
        suffix="${newest#"$hz"/.session_sentinel}"
        _SS_HAD_SENTINEL=true
        _SS_SENTINEL_TS=$(jq -r '.ts // "unknown"' "$newest" 2>/dev/null || echo "unknown")
        _SS_HB=$(cat "$hz/.session_heartbeat$suffix" 2>/dev/null || echo 0)
        read -r _SS_STOP_TS _SS_STOP_OUTCOME < "$hz/.session_laststop$suffix" 2>/dev/null || true
        [[ "$_SS_HB" =~ ^[0-9]+$ ]] || _SS_HB=0
        [[ "${_SS_STOP_TS:-}" =~ ^[0-9]+$ ]] || _SS_STOP_TS=0
    fi
    for s in ${ended[@]+"${ended[@]}"}; do
        suffix="${s#"$hz"/.session_sentinel}"
        rm -f "$s" "$hz/.session_heartbeat$suffix" "$hz/.session_laststop$suffix" 2>/dev/null || true
    done
    rm -f "$(_ss_own_file "$hz" heartbeat)" "$(_ss_own_file "$hz" laststop)" 2>/dev/null || true
}

# _ss_unfinished_hooks_note <hot_zone> -- one line, newline-terminated, when
# lifecycle hooks started and never finished in the last 7 days (wv-ca3ffe): a
# host timeout or a kill cuts a hook short without telling anyone (wv-a32e69).
_ss_unfinished_hooks_note() {
    declare -F wv_hook_unfinished_runs >/dev/null || return 0
    local unfinished
    unfinished=$(wv_hook_unfinished_runs "$1" | awk '{printf "%s%s x%s", (NR > 1 ? ", " : ""), $1, $2}')
    [ -n "$unfinished" ] || return 0
    printf 'Hooks: unfinished lifecycle runs in the last 7 days: %s (cut short by a host timeout or a kill); see wv doctor.\n' "$unfinished"
}

# _ss_commit_snapshot <project_dir> -- commit graph state written during
# session start; its body is a subshell, so exit leaves only the helper. Split out of
# wv_session_start_context to keep its branch count inside mccabe_max_sh.
_ss_commit_snapshot() {
    (
        set +e
        cd "$1" 2>/dev/null || exit 0
        # wv-822bea/wv-179c49: hijack guard, same rule as auto_checkpoint/cmd_sync
        # in wv-cmd-data.sh — refuse to commit if the caller pre-staged anything
        # outside graph state, so a session-start checkpoint never silently absorbs
        # (and, worse, [skip-ci-marks) unrelated in-progress work. wv-2e6341: only
        # graph state is staged, so .weave/ configuration such as test-map.conf
        # stays in the tree for a commit that runs its gates. Without the helpers
        # (lib not found) nothing is committed rather than all of .weave/.
        command -v wv_stage_graph_state >/dev/null 2>&1 || exit 0
        # wv-99d4d2: the fourth self-made commit. WV_AUTO_CHECKPOINT=0 and the
        # hold file stop it as they stop auto_checkpoint, sync's final commit
        # and the lifecycle checkpoint (wv-fbbdff). A hook runs in the
        # harness's environment, so here the hold file is the switch that holds.
        # wv-checkpoint-ci.sh defines it beside wv_stage_graph_state, checked above.
        wv_auto_commit_enabled "$PWD" || exit 0
        if [ "${WV_CHECKPOINT_ALL:-0}" != "1" ]; then
            local prestaged
            # A failed listing is not "nothing staged" (wv-9c6ae1).
            prestaged=$(wv_staged_non_graph_state "$PWD") || exit 0
            [ -n "$prestaged" ] && exit 0
        fi
        wv_stage_graph_state "$PWD" 2>/dev/null
        if ! git diff --cached --quiet -- .weave/ 2>/dev/null; then
            # wv-e937f8: see session-end-sync.sh's identical comment. wv-179c49:
            # fail toward NOT skipping CI when the marker helper is unavailable
            # or fails — the old " [skip ci]" fallback here defaulted to the
            # unsafe direction on the exact failure mode this exists to prevent.
            local skip_ci
            skip_ci=$(command -v wv_checkpoint_ci_marker >/dev/null 2>&1 \
                && wv_checkpoint_ci_marker "$PWD" || echo "")
            WV_AUTO_CHECKPOINT_ACTIVE=1 git commit -m "chore(weave): session-start state${skip_ci}" >/dev/null 2>&1
        fi
    )
}

# The code-search index lives in the hot zone by design and is never serialised
# to .weave/, so a reboot or a fresh zone leaves it empty and wv search --code
# finds nothing until it is rebuilt (wv-ecbe60). Session start rebuilds it
# detached and never waits. Skipped inside a counted E5 window (WV_WORKFLOW_ID),
# under test suites unless WV_SESSION_INDEX=1, and when WV_SESSION_INDEX=0.

# _ss_code_index_mode <project_dir> <hot_zone> -- what to build, as
# "<state> <mode> <head>": state empty|stale, mode fts|embed. Prints nothing
# when the index is populated and was built for HEAD, or must not be built here.
# Empty builds without embeddings (BM25, seconds); stale rebuilds in the mode it
# was built in, so a refresh never strips embeddings.
_ss_code_index_mode() {
    local head built state mode
    [ "${WV_SESSION_INDEX:-}" != 0 ] && [ -z "${WV_WORKFLOW_ID:-}" ] || return 0
    [ -z "${WV_TEST_SUITE:-}" ] || [ "${WV_SESSION_INDEX:-}" = 1 ] || return 0
    head=$(git -C "$1" rev-parse HEAD 2>/dev/null) || return 0
    # empty: no chunks; stale: chunks but no definition table (an index made
    # before wv-35b5bd), rebuilt rather than reported current; built: both.
    built=$(sqlite3 "${WV_DB:-$2/brain.db}" "SELECT CASE WHEN NOT EXISTS(SELECT 1 FROM chunks) THEN 'empty'
        WHEN NOT EXISTS(SELECT 1 FROM sqlite_master WHERE type='table' AND name='code_symbols') THEN 'stale'
        ELSE 'built' END, CASE WHEN EXISTS(SELECT 1 FROM chunks WHERE embedding IS NOT NULL) THEN 'embed' ELSE 'fts' END;" 2>/dev/null) || return 0
    state=${built%%|*} mode=${built#*|}
    if [ "$state" = built ]; then
        [ "$(cat "$2/.code_index_head" 2>/dev/null)" != "$head" ] || return 0
        state=stale
    fi
    printf '%s %s %s\n' "$state" "$mode" "$head"
}

# _ss_code_index_launch <project_dir> <hot_zone> <mode> <head> -- start the
# build detached; 1 when another build holds the lock. A build killed mid-run
# leaves its lock: one older than ten minutes is stale.
_ss_code_index_launch() {
    local lock="$2/.code_index.lock" no_embed=--no-embed
    find "$lock" -maxdepth 0 -type d -mmin +10 -exec rmdir {} \; 2>/dev/null || true
    mkdir "$lock" 2>/dev/null || return 1
    [ "$3" = embed ] && no_embed=""
    (
        trap 'rmdir "$lock" 2>/dev/null' EXIT
        # shellcheck disable=SC2086  # an empty $no_embed is no argument
        "$WV" index "$1" $no_embed --json > "$2/.code_index.log" 2>&1 \
            && printf '%s\n' "$4" > "$2/.code_index_head"
    ) </dev/null >/dev/null 2>&1 &
    disown 2>/dev/null || true
}

# _ss_code_index_refresh <project_dir> <hot_zone> -- one line, newline-terminated,
# when the code-search index needs (re)building, after starting that build.
_ss_code_index_refresh() {
    local state mode head
    read -r state mode head < <(_ss_code_index_mode "$1" "$2") || return 0
    _ss_code_index_launch "$1" "$2" "$mode" "$head" || return 0
    if [ "$state" = stale ]; then
        printf 'Code index: out of date (older HEAD or no definition table); refreshing in the background.\n'
    else
        printf 'Code index: empty in this hot zone; building it in the background (BM25, a few seconds), then wv search --code works.\n'
    fi
}

# wv_session_start_context <payload_json> -- run session start and print the
# context text for the host to inject. Never fails: hook infrastructure fails open.
wv_session_start_context() {
    local payload="${1:-}"
    local project_dir="${WV_PROJECT_DIR:-$_HC_PROJECT_DIR}"
    local repo_hash="${_HC_REPO_HASH}" hot_zone="${_HC_HOT_ZONE}"
    local sentinel
    sentinel=$(_ss_own_file "$hot_zone" sentinel)

    # ── Clear stale bash-dedup locks from the previous session ──
    # A lock still in this session's own directory at SessionStart is orphaned
    # (crash, hard-block with no PostToolUse, or a resumed session killed), so
    # it is cleared. Another live session's locks are its own (wv-da7c28): only
    # those older than any lock's lifetime (TTL 600s, grace 120s) are pruned.
    local dedup_root dedup_dir
    dedup_root=$(resolve_bash_lock_dir "$repo_hash")
    dedup_dir=$(resolve_bash_lock_dir "$repo_hash" "$(hook_session_lock_key "$payload")")
    if [[ -d "$dedup_root" ]] && hot_zone_check "$dedup_root" 2>/dev/null; then
        rm -f "${dedup_dir}"/*.lock 2>/dev/null || true
        find "$dedup_root" -maxdepth 2 -name '*.lock' -mmin +60 -delete 2>/dev/null || true
        find "$dedup_root" -mindepth 1 -maxdepth 1 -type d -name 's-*' -empty -delete 2>/dev/null || true
    fi

    # ── Harvest the last prompt (best-effort) ──
    # Enriches crash/reboot recovery context with conversation intent. Both hosts
    # send transcript_path; its directory holds that host's session transcripts.
    # Without one, fall back to Claude Code's per-project directory.
    local transcript_path transcript_dir last_prompt
    transcript_path=$(printf '%s' "$payload" | jq -r '.transcript_path // empty' 2>/dev/null || true)
    if [ -n "$transcript_path" ]; then
        transcript_dir=$(dirname "$transcript_path")
    else
        transcript_dir="$HOME/.claude/projects/$(printf '%s' "$project_dir" | tr '/' '-')"
    fi
    last_prompt=$(_ss_last_prompt "$transcript_dir")

    # ── Crash detection: collect the previous session's exit signals ──
    # A sentinel only says SessionEnd did not run. Two more signals say how the
    # session actually ended (wv-4efe06):
    #   .session_heartbeat  epoch of the last tool call (pre-action.sh)
    #   .session_laststop   "<epoch> stopped|blocked" for the last Stop (stop-check.sh)
    # Activity after the last recorded stop means the session died mid-turn. The
    # label itself is chosen after `wv load` below, from the graph's active nodes
    # now -- the previous session's state at exit -- not the list this sentinel
    # captured when that session STARTED, which missed a later claim and kept a
    # node closed before the end.
    local crash_warning="" had_sentinel=false
    local hb=0 stop_ts=0 stop_outcome="" sentinel_ts="unknown"
    _ss_stamp_begin
    _ss_previous_session "$hot_zone" "$project_dir" "$sentinel"
    had_sentinel="$_SS_HAD_SENTINEL" sentinel_ts="$_SS_SENTINEL_TS"
    hb="$_SS_HB" stop_ts="$_SS_STOP_TS" stop_outcome="$_SS_STOP_OUTCOME"

    # ── Write minimal sentinel BEFORE wv load (crash-during-load detectable) ──
    # A hot zone in a base another user could control is refused (wv-80be32):
    # write nothing into it, and say so; wv itself explains the refusal.
    if ! hot_zone_ensure "$hot_zone" 2>/dev/null; then
        printf 'Weave: hot zone %s refused as unsafe; run wv status for the reason and fix (wv-80be32).\n' "$hot_zone"
        return 0
    fi
    # Session epoch for stale-node detection in pre-action.sh
    date +%s > "$(_ss_own_file "$hot_zone" epoch)" 2>/dev/null || true
    wv_set_phase "discover" "$hot_zone" 2>/dev/null || true
    jq -n \
        --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --argjson pid $$ \
        '{ts: $ts, active: [], pid: $pid, phase: "loading"}' \
        > "$sentinel" 2>/dev/null || rm -f "$sentinel"

    # Ensure DB is loaded. Another session writing this hot zone holds its write
    # lock (wv-8f2df1); its graph is live and current, so the load is skipped
    # after a short wait rather than holding session start behind, say, a
    # minutes-long wv sync --gh. Exit 75 is that skip.
    local load_note="" load_rc=0
    # --if-changed: a hot zone whose load receipt matches .weave/ already holds
    # this graph, and the full rebuild (25 s of a 34 s start here) is skipped
    # (wv-4dc121). A pull, another zone's sync or an unsynced write loads in full.
    WV_ZONE_LOCK_TIMEOUT="${WV_SESSION_START_LOAD_WAIT:-5}" "$WV" load --if-changed >/dev/null 2>&1 || load_rc=$?
    [ "$load_rc" -ne 75 ] \
        || load_note="wv load skipped at session start: another wv process is writing this hot zone, so the live graph is current. Two sessions share this checkout; a second session belongs in a linked worktree (git worktree add)."

    # ── Guard: never commit a session-start snapshot that SHRINKS the committed graph ──
    # `wv load` above re-dumps .weave/ from the live hot-zone DB. If that DB is stale or
    # was wiped (reboot, or another zone's DB — before wv-b831e3 agents used
    # the /tmp zone and human shells /dev/shm/weave/*, and placement now adopts the
    # zone holding the repo's DB), the dump is smaller than HEAD and committing it
    # silently clobbers tracked work. This is exactly how the cross-harness telemetry epic
    # (wv-276c18 + 3 tasks) was lost on 2026-06-24. A session-start snapshot only ever ADDS
    # recovery trails/migrations, so a net node loss vs HEAD is always a regression signal:
    # self-heal by restoring .weave/ from HEAD and re-loading, and do NOT commit the shrink.
    local regression="" head_nodes disk_nodes
    if git -C "$project_dir" rev-parse HEAD >/dev/null 2>&1; then
        head_nodes=$(git -C "$project_dir" show HEAD:.weave/nodes.jsonl 2>/dev/null | wc -l | tr -d ' ')
        disk_nodes=$(wc -l < "$project_dir/.weave/nodes.jsonl" 2>/dev/null | tr -d ' ')
        if [ -n "$head_nodes" ] && [ -n "$disk_nodes" ] \
           && [ "$head_nodes" -gt 0 ] && [ "$disk_nodes" -lt "$head_nodes" ]; then
            regression="Weave graph regression blocked at session-start: disk dump shrank to ${disk_nodes} nodes vs ${head_nodes} at HEAD (stale/wiped hot-zone DB). Restored .weave/ from HEAD and re-loaded; snapshot NOT committed."
            ( cd "$project_dir" 2>/dev/null \
                && git checkout HEAD -- .weave/state.sql .weave/nodes.jsonl .weave/edges.jsonl ) 2>/dev/null || true
            "$WV" load >/dev/null 2>&1 || true
            "$WV" trails save --message="$regression" >/dev/null 2>&1 || true
        fi
    fi

    # Commit any .weave/ state written during session-start (crash-recovery trails,
    # migrations). Without this, the stop-hook fires on the first response with
    # "unsaved weave state" for changes the agent didn't cause. Skipped on regression
    # so a stale dump can never overwrite the committed graph.
    [ -n "$regression" ] || _ss_commit_snapshot "$project_dir" || true

    # ── Overwrite sentinel with full active node list ──
    local active_ids
    active_ids=$("$WV" list --status=active --json 2>/dev/null | jq -c '[.[].id]' 2>/dev/null || echo "[]")
    [ -n "$active_ids" ] || active_ids="[]"

    # ── Label how the previous session ended (wv-4efe06) ──
    # active_ids is the graph's state at the previous session's exit: nothing in
    # this session has claimed anything yet.
    if [ "$had_sentinel" = true ]; then
        local active alive_epoch alive crash_msg
        active=$(echo "$active_ids" | jq -r 'join(", ")' 2>/dev/null || echo "")
        # Last-known-alive: the later of the last tool call and the last stop, else
        # the sentinel's own start time (an older sentinel has neither signal).
        alive_epoch=$(( hb > stop_ts ? hb : stop_ts ))
        if [ "$alive_epoch" -gt 0 ]; then
            alive=$(wv_date_fmt -u "$alive_epoch" +%Y-%m-%dT%H:%M:%SZ || echo "$sentinel_ts")
        else
            alive="$sentinel_ts"
        fi
        if [ "$stop_ts" -eq 0 ] || [ "$hb" -gt "$stop_ts" ]; then
            # Tool activity after the last stop (or no stop at all): died mid-turn.
            if [ -n "$active" ]; then
                crash_msg="CRASH RECOVERY: previous session died mid-turn (last activity ${alive}). Active nodes: ${active}."
                [ -n "$last_prompt" ] && crash_msg="${crash_msg} Last prompt: '${last_prompt}'"
                crash_msg="${crash_msg} Review and re-claim or close active nodes."
                "$WV" trails save --message="$crash_msg" >/dev/null 2>&1 || true
                crash_warning="CRASH DETECTED: previous session died mid-turn (last activity ${alive}) with active work: ${active}."
                [ -n "$last_prompt" ] && crash_warning="${crash_warning} Last prompt: '${last_prompt}'"
                crash_warning="${crash_warning} Recovery trail saved."
            else
                crash_warning="Note: previous session died mid-turn (last activity ${alive}). No active work to recover."
            fi
        elif [ "$stop_outcome" = "blocked" ] || [ -n "$active" ]; then
            # Its last stop was refused over open work (or let through by the
            # stop-check cooldown with work still open), then it ended anyway.
            crash_warning="Note: previous session's last exit (${alive}) was blocked by open work and it ended without SessionEnd. Still active: ${active:-none}."
        else
            crash_warning="Note: previous session stopped cleanly at ${alive} and ended without SessionEnd. No active work to recover."
        fi
    fi
    # A live peer is not a crashed session (wv-9a867a): say so in place of a
    # crash label, and leave its active nodes to it.
    if [ -n "$_SS_LIVE_PEER" ]; then
        crash_warning="${crash_warning:+$crash_warning }Note: another session is live in this checkout: ${_SS_LIVE_PEER}. Its session state was left alone; active nodes it holds are its own work, not a crash. A second session needs its own worktree."
    fi
    jq -n \
        --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --slurpfile active <(printf '%s' "$active_ids") \
        --argjson pid $$ \
        '{ts: $ts, active: $active[0], pid: $pid}' \
        > "$sentinel" 2>/dev/null || rm -f "$sentinel"

    # Compressed work status (already formatted)
    local status context
    status=$("$WV" status 2>/dev/null || echo "Work: 0 active, 0 ready, 0 blocked.")
    context="$status"

    # Readiness (wv-814d33): whether the framework is known green for HEAD and which
    # open structural nodes come first, from wv bootstrap -- the same surface every
    # harness reads -- so session start adds no second evaluator. WV_RUN_CACHE=0: the
    # run cache keys on HEAD and the framework record (wv-9e14fa) but not on install
    # drift, which moves with uncommitted source edits and ./install.sh, and session
    # start is read once. Empty when the framework is green and nothing is open.
    local readiness
    readiness=$(WV_RUN_CACHE=0 "$WV" bootstrap --json 2>/dev/null \
        | jq -r '.readiness.advisories // [] | .[]' 2>/dev/null || true)
    if [ -n "$readiness" ]; then
        context="Readiness - fix before other work:
$(printf '%s\n' "$readiness" | sed 's/^/  - /')
${context}"
    fi

    if [ -n "$crash_warning" ]; then
        context="${crash_warning}
${context}"
    fi

    # Lifecycle hooks that started and never finished (wv-ca3ffe).
    context="$(_ss_unfinished_hooks_note "$hot_zone")
${context}"
    # The code-search index, rebuilt detached when empty or stale (wv-ecbe60).
    context="${context}
$(_ss_code_index_refresh "$project_dir" "$hot_zone")"
    context="${context%$'\n'}"
    context="${context#$'\n'}"

    if [ -n "$load_note" ]; then
        context="${load_note}
${context}"
    fi
    # Graph-regression warning if the shrink guard fired
    if [ -n "$regression" ]; then
        context="${regression}
${context}"
    fi

    # Secondary detection: active nodes but no sentinel at session start (reboot recovery)
    local active_count reboot_note
    active_count=$(echo "$active_ids" | jq 'length' 2>/dev/null || echo "0")
    if [ "$active_count" -gt 0 ] && [ -z "$crash_warning" ] && [ "$had_sentinel" = false ]; then
        reboot_note="Note: ${active_count} nodes marked active from a previous session."
        [ -n "$last_prompt" ] && reboot_note="${reboot_note} Last prompt: '${last_prompt}'"
        reboot_note="${reboot_note} Run 'wv recover --session' to review."
        context="${reboot_note}
${context}"
    fi

    # Health score (single line, best effort)
    # --fast: score-only cached path (wv-0d77b1); older wv versions ignore the
    # flag and fall back to a full health run, so this degrades gracefully.
    local health_json health_score health_recovery
    health_json=$("$WV" health --fast --json 2>/dev/null || echo "")
    if [ -n "$health_json" ]; then
        health_score=$(echo "$health_json" | jq -r '.score // empty' 2>/dev/null || true)
        if [ -n "$health_score" ]; then
            context="${context}
Health: ${health_score}/100"
        fi
        # A non-canonical writer-lineage verdict floors the score, but a bare 0/100
        # does not tell the session what to do about it (wv-71d076). The recovery
        # key is absent on a healthy graph and on older wv versions, so this adds a
        # line only when there is a drift to act on.
        health_recovery=$(echo "$health_json" | jq -r '.recovery // empty' 2>/dev/null || true)
        if [ -n "$health_recovery" ]; then
            context="${context}
Graph is NOT writable — wv sync and wv commit-refs cannot persist. Recover with: ${health_recovery}"
        fi
    fi

    # Surface stale trails (>24h old) so they aren't silently forgotten.
    # Prefer trails.md; fall back to the legacy breadcrumbs.md on un-migrated repos.
    local bc_file now mtime age_hours
    bc_file="${project_dir}/.weave/trails.md"
    [ -f "$bc_file" ] || bc_file="${project_dir}/.weave/breadcrumbs.md"
    if [ -f "$bc_file" ]; then
        now=$(date +%s)
        mtime=$(wv_stat mtime "$bc_file" || echo "$now")
        age_hours=$(( (now - mtime) / 3600 ))
        if [ "$age_hours" -gt 24 ]; then
            context="${context}
Trail from ${age_hours}h ago — run 'wv trails show' to review"
        fi
    fi

    # The compact line context-guard.sh printed as its own SessionStart hook:
    # first, so a host that truncates long context still shows it.
    context="$(_ss_summary_line)
${context}"

    printf '%s\n' "$context"
}
