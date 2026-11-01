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

# _ss_summary_line <status_line> -- the compact one-liner context-guard.sh used
# to print: counts, the context load policy (wv context-policy, wv-f757a4) and
# the primary node.
_ss_summary_line() {
    local status_line="$1" policy="unknown" active ready blocked current
    policy=$("$WV" context-policy --json 2>/dev/null | jq -r '.policy // "unknown"' 2>/dev/null) || policy="unknown"
    [ -n "$policy" ] || policy="unknown"
    active=$(printf '%s' "$status_line" | grep -oP '\d+(?= active)' || echo "0")
    ready=$(printf '%s' "$status_line" | grep -oP '\d+(?= ready)' || echo "0")
    blocked=$(printf '%s' "$status_line" | grep -oP '\d+(?= blocked)' || echo "0")
    current=$(printf '%s' "$status_line" | grep -oP '(?<=Primary: )wv-[a-f0-9]+' || echo "none")
    printf 'Weave: %s active, %s ready, %s blocked | policy=%s | current=%s\n' \
        "${active:-0}" "${ready:-0}" "${blocked:-0}" "$policy" "${current:-none}"
}

# wv_session_start_context <payload_json> -- run session start and print the
# context text for the host to inject. Never fails: hook infrastructure fails open.
wv_session_start_context() {
    local payload="${1:-}"
    local project_dir="${WV_PROJECT_DIR:-$_HC_PROJECT_DIR}"
    local repo_hash="${_HC_REPO_HASH}" hot_zone="${_HC_HOT_ZONE}"
    local sentinel="${hot_zone}/.session_sentinel"

    # ── Clear stale bash-dedup locks from the previous session ──
    # bash-dedup.sh uses the same repo hash to locate lock files. Any lock still
    # present at SessionStart is orphaned (crash, hard-block with no PostToolUse,
    # or session killed). Clear them all so this session starts with a clean slate.
    local dedup_dir
    dedup_dir=$(resolve_bash_lock_dir "$repo_hash")
    if [[ -d "$dedup_dir" ]] && hot_zone_check "$dedup_dir" 2>/dev/null; then
        rm -f "${dedup_dir}"/*.lock 2>/dev/null || true
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
    if [ -f "$sentinel" ]; then
        had_sentinel=true
        sentinel_ts=$(jq -r '.ts // "unknown"' "$sentinel" 2>/dev/null || echo "unknown")
        hb=$(cat "${hot_zone}/.session_heartbeat" 2>/dev/null || echo 0)
        read -r stop_ts stop_outcome < "${hot_zone}/.session_laststop" 2>/dev/null || true
        [[ "$hb" =~ ^[0-9]+$ ]] || hb=0
        [[ "${stop_ts:-}" =~ ^[0-9]+$ ]] || stop_ts=0
    fi
    rm -f "${hot_zone}/.session_heartbeat" "${hot_zone}/.session_laststop" 2>/dev/null || true

    # ── Write minimal sentinel BEFORE wv load (crash-during-load detectable) ──
    # A hot zone in a base another user could control is refused (wv-80be32):
    # write nothing into it, and say so; wv itself explains the refusal.
    if ! hot_zone_ensure "$hot_zone" 2>/dev/null; then
        printf 'Weave: hot zone %s refused as unsafe; run wv status for the reason and fix (wv-80be32).\n' "$hot_zone"
        return 0
    fi
    # Session epoch for stale-node detection in pre-action.sh
    date +%s > "${hot_zone}/.session_epoch" 2>/dev/null || true
    wv_set_phase "discover" "$hot_zone" 2>/dev/null || true
    jq -n \
        --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --argjson pid $$ \
        '{ts: $ts, active: [], pid: $pid, phase: "loading"}' \
        > "$sentinel" 2>/dev/null || rm -f "$sentinel"

    # Ensure DB is loaded
    "$WV" load >/dev/null 2>&1 || true

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
    if [ -z "$regression" ]; then
    (
        set +e
        cd "$project_dir" 2>/dev/null || exit 0
        # wv-822bea/wv-179c49: hijack guard, same rule as auto_checkpoint/cmd_sync
        # in wv-cmd-data.sh — refuse to commit if the caller pre-staged anything
        # outside graph state, so a session-start checkpoint never silently absorbs
        # (and, worse, [skip-ci-marks) unrelated in-progress work. wv-2e6341: only
        # graph state is staged, so .weave/ configuration such as test-map.conf
        # stays in the tree for a commit that runs its gates. Without the helpers
        # (lib not found) nothing is committed rather than all of .weave/.
        command -v wv_stage_graph_state >/dev/null 2>&1 || exit 0
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
    ) || true
    fi

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
            alive=$(date -u -d "@${alive_epoch}" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
                || date -u -r "${alive_epoch}" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "$sentinel_ts")
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
        mtime=$(stat -c %Y "$bc_file" 2>/dev/null || stat -f %m "$bc_file" 2>/dev/null || echo "$now")
        age_hours=$(( (now - mtime) / 3600 ))
        if [ "$age_hours" -gt 24 ]; then
            context="${context}
Trail from ${age_hours}h ago — run 'wv trails show' to review"
        fi
    fi

    # The compact line context-guard.sh printed as its own SessionStart hook:
    # first, so a host that truncates long context still shows it.
    context="$(_ss_summary_line "$status")
${context}"

    printf '%s\n' "$context"
}
