#!/bin/bash
# SessionStart hook: Inject active work context
# Provides compressed Weave status at session start
# Includes crash sentinel detection (v1.16.0)

set -e

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "$HOOK_DIR/../lib/wv-resolve-project.sh" 2>/dev/null \
    || source "$HOOK_DIR/../../scripts/lib/wv-resolve-project.sh" 2>/dev/null \
    || source "${HOME}/.config/weave/lib/wv-resolve-project.sh" 2>/dev/null \
    || exit 0
source "$HOOK_DIR/../lib/wv-validate.sh" 2>/dev/null \
    || source "$HOOK_DIR/../../scripts/lib/wv-validate.sh" 2>/dev/null \
    || source "${HOME}/.config/weave/lib/wv-validate.sh" 2>/dev/null \
    || true
source "$HOOK_DIR/../lib/wv-config.sh" 2>/dev/null \
    || source "$HOOK_DIR/../../scripts/lib/wv-config.sh" 2>/dev/null \
    || source "${HOME}/.config/weave/lib/wv-config.sh" 2>/dev/null \
    || true
source "$HOOK_DIR/../lib/wv-hook-common.sh" 2>/dev/null \
    || source "$HOOK_DIR/../../scripts/lib/wv-hook-common.sh" 2>/dev/null \
    || source "${HOME}/.config/weave/lib/wv-hook-common.sh" 2>/dev/null \
    || true
source "$HOOK_DIR/../lib/wv-checkpoint-ci.sh" 2>/dev/null \
    || source "$HOOK_DIR/../../scripts/lib/wv-checkpoint-ci.sh" 2>/dev/null \
    || source "${HOME}/.config/weave/lib/wv-checkpoint-ci.sh" 2>/dev/null \
    || true
_hc_refresh

# Check if wv is available
if [ ! -x "$WV" ]; then
    echo "wv CLI not found"
    exit 0
fi

# Resolve hot zone path via shared hook helper
_SS_REPO_HASH="${_HC_REPO_HASH}"
_SS_HOT_ZONE="${_HC_HOT_ZONE}"
SENTINEL="${_SS_HOT_ZONE}/.session_sentinel"

# ── Clear stale bash-dedup locks from the previous session ────────────────────
# bash-dedup.sh uses the same repo hash to locate lock files. Any lock still
# present at SessionStart is orphaned (crash, hard-block with no PostToolUse,
# or session killed). Clear them all so this session starts with a clean slate.
_SS_DEDUP_DIR="/tmp/weave-bash-locks/${_SS_REPO_HASH}"
if [[ -d "$_SS_DEDUP_DIR" ]]; then
    rm -f "${_SS_DEDUP_DIR}"/*.lock 2>/dev/null || true
fi

# ── Harvest last prompt from most recent Claude JSONL (best-effort) ──
# Used to enrich crash/reboot recovery context with conversation intent.
_SS_LAST_PROMPT=""
_SS_CLAUDE_SLUG=$(echo "$WV_PROJECT_DIR" | tr '/' '-')
_SS_CLAUDE_DIR="$HOME/.claude/projects/${_SS_CLAUDE_SLUG}"
if [ -d "$_SS_CLAUDE_DIR" ]; then
    _SS_RECENT_JSONL=$(ls -t "$_SS_CLAUDE_DIR"/*.jsonl 2>/dev/null | head -1)
    if [ -n "$_SS_RECENT_JSONL" ]; then
        _SS_LAST_PROMPT=$(python3 - "$_SS_RECENT_JSONL" 2>/dev/null <<'PYEOF'
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
        ) || _SS_LAST_PROMPT=""
    fi
fi

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
CRASH_WARNING=""
HAD_SENTINEL=false
_SS_HB=0; _SS_STOP_TS=0; _SS_STOP_OUTCOME=""; _SS_SENTINEL_TS="unknown"
if [ -f "$SENTINEL" ]; then
    HAD_SENTINEL=true
    _SS_SENTINEL_TS=$(jq -r '.ts // "unknown"' "$SENTINEL" 2>/dev/null || echo "unknown")
    _SS_HB=$(cat "${_SS_HOT_ZONE}/.session_heartbeat" 2>/dev/null || echo 0)
    read -r _SS_STOP_TS _SS_STOP_OUTCOME < "${_SS_HOT_ZONE}/.session_laststop" 2>/dev/null || true
    [[ "$_SS_HB" =~ ^[0-9]+$ ]] || _SS_HB=0
    [[ "${_SS_STOP_TS:-}" =~ ^[0-9]+$ ]] || _SS_STOP_TS=0
fi
rm -f "${_SS_HOT_ZONE}/.session_heartbeat" "${_SS_HOT_ZONE}/.session_laststop" 2>/dev/null || true

# ── Write minimal sentinel BEFORE wv load (crash-during-load detectable) ──
mkdir -p "$_SS_HOT_ZONE" 2>/dev/null || true
# Write session epoch for stale-node detection in pre-action.sh
date +%s > "${_SS_HOT_ZONE}/.session_epoch" 2>/dev/null || true
wv_set_phase "discover" "$_SS_HOT_ZONE"
jq -n \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson pid $$ \
    '{ts: $ts, active: [], pid: $pid, phase: "loading"}' \
    > "$SENTINEL" 2>/dev/null || rm -f "$SENTINEL"

# Ensure DB is loaded
"$WV" load >/dev/null 2>&1 || true

# ── Guard: never commit a session-start snapshot that SHRINKS the committed graph ──
# `wv load` above re-dumps .weave/ from the live hot-zone DB. If that DB is stale or
# was wiped (reboot, or a different runtime's hot zone — sandboxed runtimes incl.
# Codex AND Claude Code use /tmp/weave-codex-*, native/human shells use /dev/shm/weave/*
# per is_sandboxed_runtime), the dump is smaller than HEAD and committing it
# silently clobbers tracked work. This is exactly how the cross-harness telemetry epic
# (wv-276c18 + 3 tasks) was lost on 2026-06-24. A session-start snapshot only ever ADDS
# recovery trails/migrations, so a net node loss vs HEAD is always a regression signal:
# self-heal by restoring .weave/ from HEAD and re-loading, and do NOT commit the shrink.
SS_REGRESSION=""
if git -C "$WV_PROJECT_DIR" rev-parse HEAD >/dev/null 2>&1; then
    _SS_HEAD_NODES=$(git -C "$WV_PROJECT_DIR" show HEAD:.weave/nodes.jsonl 2>/dev/null | wc -l | tr -d ' ')
    _SS_DISK_NODES=$(wc -l < "$WV_PROJECT_DIR/.weave/nodes.jsonl" 2>/dev/null | tr -d ' ')
    if [ -n "$_SS_HEAD_NODES" ] && [ -n "$_SS_DISK_NODES" ] \
       && [ "$_SS_HEAD_NODES" -gt 0 ] && [ "$_SS_DISK_NODES" -lt "$_SS_HEAD_NODES" ]; then
        SS_REGRESSION="Weave graph regression blocked at session-start: disk dump shrank to ${_SS_DISK_NODES} nodes vs ${_SS_HEAD_NODES} at HEAD (stale/wiped hot-zone DB). Restored .weave/ from HEAD and re-loaded; snapshot NOT committed."
        ( cd "$WV_PROJECT_DIR" 2>/dev/null \
            && git checkout HEAD -- .weave/state.sql .weave/nodes.jsonl .weave/edges.jsonl ) 2>/dev/null || true
        "$WV" load >/dev/null 2>&1 || true
        "$WV" trails save --message="$SS_REGRESSION" >/dev/null 2>&1 || true
    fi
fi

# Commit any .weave/ state written during session-start (crash-recovery trails,
# migrations). Without this, the stop-hook fires on the first response with
# "unsaved weave state" for changes the agent didn't cause. Skipped on regression
# so a stale dump can never overwrite the committed graph.
if [ -z "$SS_REGRESSION" ]; then
(
    set +e
    cd "$WV_PROJECT_DIR" 2>/dev/null || exit 0
    # wv-822bea/wv-179c49: hijack guard, same rule as auto_checkpoint/cmd_sync
    # in wv-cmd-data.sh — refuse to commit if the caller pre-staged anything
    # outside graph state, so a session-start checkpoint never silently absorbs
    # (and, worse, [skip-ci-marks) unrelated in-progress work. wv-2e6341: only
    # graph state is staged, so .weave/ configuration such as test-map.conf
    # stays in the tree for a commit that runs its gates. Without the helpers
    # (lib not found) nothing is committed rather than all of .weave/.
    command -v wv_stage_graph_state >/dev/null 2>&1 || exit 0
    if [ "${WV_CHECKPOINT_ALL:-0}" != "1" ]; then
        _SS_PRESTAGED=$(wv_staged_non_graph_state "$PWD")
        [ -n "$_SS_PRESTAGED" ] && exit 0
    fi
    wv_stage_graph_state "$PWD" 2>/dev/null
    if ! git diff --cached --quiet -- .weave/ 2>/dev/null; then
        # wv-e937f8: see session-end-sync.sh's identical comment. wv-179c49:
        # fail toward NOT skipping CI when the marker helper is unavailable
        # or fails — the old " [skip ci]" fallback here defaulted to the
        # unsafe direction on the exact failure mode this exists to prevent.
        _SS_SKIP_CI=$(command -v wv_checkpoint_ci_marker >/dev/null 2>&1 \
            && wv_checkpoint_ci_marker "$PWD" || echo "")
        WV_AUTO_CHECKPOINT_ACTIVE=1 git commit -m "chore(weave): session-start state${_SS_SKIP_CI}" 2>/dev/null
    fi
) || true
fi

# ── Overwrite sentinel with full active node list ──
ACTIVE_IDS=$("$WV" list --status=active --json 2>/dev/null | jq -c '[.[].id]' 2>/dev/null || echo "[]")

# ── Label how the previous session ended (wv-4efe06) ──
# ACTIVE_IDS is the graph's state at the previous session's exit: nothing in
# this session has claimed anything yet.
if [ "$HAD_SENTINEL" = true ]; then
    _SS_ACTIVE=$(echo "$ACTIVE_IDS" | jq -r 'join(", ")' 2>/dev/null || echo "")
    # Last-known-alive: the later of the last tool call and the last stop, else
    # the sentinel's own start time (an older sentinel has neither signal).
    _SS_ALIVE_EPOCH=$(( _SS_HB > _SS_STOP_TS ? _SS_HB : _SS_STOP_TS ))
    if [ "$_SS_ALIVE_EPOCH" -gt 0 ]; then
        _SS_ALIVE=$(date -u -d "@${_SS_ALIVE_EPOCH}" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
            || date -u -r "${_SS_ALIVE_EPOCH}" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "$_SS_SENTINEL_TS")
    else
        _SS_ALIVE="$_SS_SENTINEL_TS"
    fi
    if [ "$_SS_STOP_TS" -eq 0 ] || [ "$_SS_HB" -gt "$_SS_STOP_TS" ]; then
        # Tool activity after the last stop (or no stop at all): died mid-turn.
        if [ -n "$_SS_ACTIVE" ]; then
            _CRASH_MSG="CRASH RECOVERY: previous session died mid-turn (last activity ${_SS_ALIVE}). Active nodes: ${_SS_ACTIVE}."
            [ -n "$_SS_LAST_PROMPT" ] && _CRASH_MSG="${_CRASH_MSG} Last prompt: '${_SS_LAST_PROMPT}'"
            _CRASH_MSG="${_CRASH_MSG} Review and re-claim or close active nodes."
            "$WV" trails save --message="$_CRASH_MSG" >/dev/null 2>&1 || true
            CRASH_WARNING="CRASH DETECTED: previous session died mid-turn (last activity ${_SS_ALIVE}) with active work: ${_SS_ACTIVE}."
            [ -n "$_SS_LAST_PROMPT" ] && CRASH_WARNING="${CRASH_WARNING} Last prompt: '${_SS_LAST_PROMPT}'"
            CRASH_WARNING="${CRASH_WARNING} Recovery trail saved."
        else
            CRASH_WARNING="Note: previous session died mid-turn (last activity ${_SS_ALIVE}). No active work to recover."
        fi
    elif [ "$_SS_STOP_OUTCOME" = "blocked" ] || [ -n "$_SS_ACTIVE" ]; then
        # Its last stop was refused over open work (or let through by the
        # stop-check cooldown with work still open), then it ended anyway.
        CRASH_WARNING="Note: previous session's last exit (${_SS_ALIVE}) was blocked by open work and it ended without SessionEnd. Still active: ${_SS_ACTIVE:-none}."
    else
        CRASH_WARNING="Note: previous session stopped cleanly at ${_SS_ALIVE} and ended without SessionEnd. No active work to recover."
    fi
fi
jq -n \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson active "$ACTIVE_IDS" \
    --argjson pid $$ \
    '{ts: $ts, active: $active, pid: $pid}' \
    > "$SENTINEL" 2>/dev/null || rm -f "$SENTINEL"

# Get compressed work status using wv status (already formatted)
STATUS=$("$WV" status 2>/dev/null || echo "Work: 0 active, 0 ready, 0 blocked.")
CONTEXT="$STATUS"

# Readiness (wv-814d33): whether the framework is known green for HEAD and which
# open structural nodes come first, from wv bootstrap -- the same surface every
# harness reads -- so this hook adds no second evaluator. WV_RUN_CACHE=0: the
# run cache keys on HEAD and the framework record (wv-9e14fa) but not on install
# drift, which moves with uncommitted source edits and ./install.sh, and session
# start is read once. Empty when the framework is green and nothing is open.
READINESS=$(WV_RUN_CACHE=0 "$WV" bootstrap --json 2>/dev/null \
    | jq -r '.readiness.advisories // [] | .[]' 2>/dev/null || true)
if [ -n "$READINESS" ]; then
    CONTEXT="Readiness - fix before other work:
$(printf '%s\n' "$READINESS" | sed 's/^/  - /')
${CONTEXT}"
fi

# Prepend crash warning if detected
if [ -n "$CRASH_WARNING" ]; then
    CONTEXT="${CRASH_WARNING}
${CONTEXT}"
fi

# Prepend graph-regression warning if the shrink guard fired
if [ -n "$SS_REGRESSION" ]; then
    CONTEXT="${SS_REGRESSION}
${CONTEXT}"
fi

# Secondary detection: active nodes but no sentinel at session start (reboot recovery)
ACTIVE_COUNT=$(echo "$ACTIVE_IDS" | jq 'length' 2>/dev/null || echo "0")
if [ "$ACTIVE_COUNT" -gt 0 ] && [ -z "$CRASH_WARNING" ] && [ "$HAD_SENTINEL" = false ]; then
    _REBOOT_NOTE="Note: ${ACTIVE_COUNT} nodes marked active from a previous session."
    [ -n "$_SS_LAST_PROMPT" ] && _REBOOT_NOTE="${_REBOOT_NOTE} Last prompt: '${_SS_LAST_PROMPT}'"
    _REBOOT_NOTE="${_REBOOT_NOTE} Run 'wv recover --session' to review."
    CONTEXT="${_REBOOT_NOTE}
${CONTEXT}"
fi

# Append health score (single line, best effort)
# --fast: score-only cached path (wv-0d77b1); older wv versions ignore the
# flag and fall back to a full health run, so this degrades gracefully.
HEALTH_JSON=$("$WV" health --fast --json 2>/dev/null || echo "")
if [ -n "$HEALTH_JSON" ]; then
    HEALTH_SCORE=$(echo "$HEALTH_JSON" | jq -r '.score // empty' 2>/dev/null || true)
    if [ -n "$HEALTH_SCORE" ]; then
        CONTEXT="${CONTEXT}
Health: ${HEALTH_SCORE}/100"
    fi
    # A non-canonical writer-lineage verdict floors the score, but a bare 0/100
    # does not tell the session what to do about it (wv-71d076). The recovery
    # key is absent on a healthy graph and on older wv versions, so this adds a
    # line only when there is a drift to act on.
    HEALTH_RECOVERY=$(echo "$HEALTH_JSON" | jq -r '.recovery // empty' 2>/dev/null || true)
    if [ -n "$HEALTH_RECOVERY" ]; then
        CONTEXT="${CONTEXT}
Graph is NOT writable — wv sync and wv commit-refs cannot persist. Recover with: ${HEALTH_RECOVERY}"
    fi
fi

# Surface stale trails (>24h old) so they aren't silently forgotten.
# Prefer trails.md; fall back to the legacy breadcrumbs.md on un-migrated repos.
WEAVE_DIR="${WV_PROJECT_DIR}/.weave"
BC_FILE="${WEAVE_DIR}/trails.md"
[ -f "$BC_FILE" ] || BC_FILE="${WEAVE_DIR}/breadcrumbs.md"
if [ -f "$BC_FILE" ]; then
    now=$(date +%s)
    mtime=$(stat -c %Y "$BC_FILE" 2>/dev/null || stat -f %m "$BC_FILE" 2>/dev/null || echo "$now")
    age_hours=$(( (now - mtime) / 3600 ))
    if [ "$age_hours" -gt 24 ]; then
        CONTEXT="${CONTEXT}
Trail from ${age_hours}h ago — run 'wv trails show' to review"
    fi
fi

# Output as JSON — use jq for safe string encoding (handles newlines in CONTEXT)
jq -n --arg ctx "$CONTEXT" '{
    hookSpecificOutput: {
        hookEventName: "SessionStart",
        additionalContext: $ctx
    }
}'

exit 0
