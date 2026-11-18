#!/usr/bin/env bash
# wv-gate-hold.sh — one gate at a time per checkout (wv-c5500d).
#
# A git push started by a session that then restarted kept running its
# pre-push gate, and the restarted session started a second push over the same
# commits: both gates ran the same heavy suites side by side, doubling load on
# timing-sensitive suites, and neither result reached a session (2026-11-08).
#
# The lock is per checkout, never per identity: two sessions of any harness on
# one tree share git, the index and the gate scratch. Its key is
# $(git rev-parse --git-path weave-gate.lock), so a linked worktree has its own.
# flock(1) holds it on fd 8 for the life of the gate shell, so a dead holder
# never leaves a stale lock; without flock (macOS) a mkdir lock stands in, and
# a holder whose pid is gone, or now names another process, is cleared.
#
# Identity is recorded, not used to admit: the holder record names
# resolve_agent_id, agent_ownership_mode, the harness, pid, process start time,
# the gate kind and what it gates, and the refusal is worded by it (the
# wv-3932e5 lesson): the same session-qualified identity is told its earlier
# gate is still running; anyone else is told who holds it and to wait, never to
# stop another owner's gate.
#
# Readers (bootstrap, session start) never take the lock: they judge the record
# by pid liveness plus process start time, which defeats pid reuse.
#
# The last push's outcome is kept beside it (weave-gate-last-push.json), so a
# restarted session learns how an orphaned push ended.

[ -n "${_WV_GATE_HOLD_LOADED:-}" ] && return 0
_WV_GATE_HOLD_LOADED=1
_WV_GATE_HOLD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_WV_GATE_HOLD_MINE=""

# _wv_gate_hold_path <name> — <name> under this checkout's git dir.
_wv_gate_hold_path() {
    git rev-parse --git-path "$1" 2>/dev/null
}

# _wv_gate_hold_start <pid> — the process's start time as ps prints it, or
# nothing when no such process exists.
_wv_gate_hold_start() {
    local s
    s=$(ps -o lstart= -p "$1" 2>/dev/null) || return 1
    s=${s#"${s%%[![:space:]]*}"}
    [ -n "$s" ] || return 1
    printf '%s\n' "$s"
}

# _wv_gate_hold_alive <record-json> — true when the recorded pid is a live
# process that started when the record says.
_wv_gate_hold_alive() {
    local pid start now
    pid=$(jq -r '.pid // empty' <<< "$1" 2>/dev/null) || return 1
    start=$(jq -r '.start // empty' <<< "$1" 2>/dev/null) || return 1
    case "$pid" in ''|*[!0-9]*) return 1 ;; esac
    now=$(_wv_gate_hold_start "$pid") || return 1
    [ "$now" = "$start" ]
}

# _wv_gate_hold_identity — "<agent id>\t<ownership mode>\t<harness>", through
# the shared resolver (wv-resolve-runtime.sh), loaded beside this file when the
# hook's shell does not have it yet.
_wv_gate_hold_identity() {
    if ! declare -F resolve_agent_id >/dev/null; then
        # shellcheck source=/dev/null
        [ -r "$_WV_GATE_HOLD_DIR/wv-resolve-runtime.sh" ] && . "$_WV_GATE_HOLD_DIR/wv-resolve-runtime.sh" 2>/dev/null
    fi
    if declare -F resolve_agent_id >/dev/null; then
        printf '%s\t%s\t%s\n' "$(resolve_agent_id 2>/dev/null)" \
            "$(agent_ownership_mode 2>/dev/null)" "$(resolve_agent_harness 2>/dev/null)"
    else
        printf '%s\t%s\t%s\n' "${WV_AGENT_ID:-unknown}" actor unknown
    fi
}

# _wv_gate_hold_write <file> <json> — replace <file> whole, never half-written.
_wv_gate_hold_write() {
    local tmp="$1.$$.tmp"
    printf '%s\n' "$2" > "$tmp" 2>/dev/null && mv -f "$tmp" "$1" 2>/dev/null || { rm -f "$tmp"; return 1; }
}

# _wv_gate_hold_record <kind> <subject> — the holder record for this shell.
_wv_gate_hold_record() {
    local id mode harness start
    IFS=$'\t' read -r id mode harness < <(_wv_gate_hold_identity)
    start=$(_wv_gate_hold_start "$$") || start=""
    jq -cn --arg kind "$1" --arg subject "$2" --arg id "$id" --arg mode "$mode" \
        --arg harness "$harness" --arg pid "$$" --arg start "$start" \
        --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{kind: $kind, subject: $subject, agent_id: $id, ownership_mode: $mode,
          harness: $harness, pid: ($pid | tonumber), start: $start, started_at: $at}'
}

# _wv_gate_hold_refuse <kind> <holder-json> — the refusal, worded by identity.
_wv_gate_hold_refuse() {
    local id mode harness hid hmode hkind hpid hat hsubj
    IFS=$'\t' read -r id mode harness < <(_wv_gate_hold_identity)
    hid=$(jq -r '.agent_id // "unknown"' <<< "$2" 2>/dev/null)
    hmode=$(jq -r '.ownership_mode // "actor"' <<< "$2" 2>/dev/null)
    hkind=$(jq -r '.kind // "gate"' <<< "$2" 2>/dev/null)
    hpid=$(jq -r '.pid // "?"' <<< "$2" 2>/dev/null)
    hat=$(jq -r '.started_at // "?"' <<< "$2" 2>/dev/null)
    hsubj=$(jq -r '.subject // ""' <<< "$2" 2>/dev/null)
    if [ -z "$2" ]; then
        echo "✗ Weave $1: another Weave gate holds this checkout (no holder record yet); wait for it to finish, then re-run" >&2
    elif ! _wv_gate_hold_alive "$2"; then
        # flock is held by an open descriptor, which the gate's children
        # inherit: suites still running after their gate died hold it too.
        echo "✗ Weave $1: the $hkind gate held by $hid (pid $hpid, since $hat${hsubj:+, $hsubj}) is gone, but processes it started still hold this checkout." >&2
        echo "  Find them with: ps -eo pid,ppid,etime,cmd | grep -E 'wv-gate|tests/test-'; they release it when they exit." >&2
    elif [ "$hid" = "$id" ] && [ "$hmode" = session ] && [ "$mode" = session ]; then
        echo "✗ Weave $1: your earlier $hkind gate is still running on this checkout (pid $hpid, since $hat${hsubj:+, $hsubj})." >&2
        echo "  This session resumed or restarted while it ran. Wait for it to finish, or stop it (kill $hpid) and re-run." >&2
    else
        echo "✗ Weave $1: a $hkind gate held by $hid is running on this checkout (pid $hpid, since $hat${hsubj:+, $hsubj})." >&2
        echo "  Wait for it to finish, then re-run. Do not stop a gate another owner started." >&2
    fi
}

# wv_gate_hold_acquire <kind> <subject> — take this checkout's gate lock for
# the life of the calling shell. 0 when held (the record is written), 1 when
# another gate holds it (the refusal is printed), 0 with nothing done outside a
# git checkout.
wv_gate_hold_acquire() {
    local kind="$1" subject="${2:-}" lock rec holder dir
    lock=$(_wv_gate_hold_path weave-gate.lock) && [ -n "$lock" ] || return 0
    rec=$(_wv_gate_hold_path weave-gate.holder.json) || return 0
    if command -v flock >/dev/null 2>&1 && [ "${WV_GATE_HOLD_NO_FLOCK:-0}" != 1 ]; then
        exec 8>>"$lock" || return 0
        if ! flock -n 8; then
            exec 8>&-
            holder=$(cat "$rec" 2>/dev/null) || holder=""
            _wv_gate_hold_refuse "$kind" "$holder"
            return 1
        fi
    else
        dir="$lock.d"
        if ! mkdir "$dir" 2>/dev/null; then
            holder=$(cat "$dir/holder.json" 2>/dev/null) || holder=""
            # A holder that is gone, or whose pid now names another process,
            # leaves no lock behind: clear it once and take it.
            if [ -n "$holder" ] && ! _wv_gate_hold_alive "$holder"; then
                rm -rf "$dir" 2>/dev/null
                mkdir "$dir" 2>/dev/null || { _wv_gate_hold_refuse "$kind" ""; return 1; }
            else
                _wv_gate_hold_refuse "$kind" "$holder"
                return 1
            fi
        fi
        _wv_gate_hold_record "$kind" "$subject" > "$dir/holder.json" 2>/dev/null
        _WV_GATE_HOLD_MINE="$dir"
    fi
    _wv_gate_hold_write "$rec" "$(_wv_gate_hold_record "$kind" "$subject")" || true
    return 0
}

# wv_gate_hold_release — drop this shell's hold early (exit drops it anyway;
# the mkdir lock needs this, so the hooks call it from their exit trap).
wv_gate_hold_release() {
    local rec
    rec=$(_wv_gate_hold_path weave-gate.holder.json) || rec=""
    if [ -n "$rec" ] && [ "$(jq -r '.pid // empty' "$rec" 2>/dev/null)" = "$$" ]; then
        rm -f "$rec" 2>/dev/null
    fi
    if [ -n "$_WV_GATE_HOLD_MINE" ]; then
        rm -rf "$_WV_GATE_HOLD_MINE" 2>/dev/null
        _WV_GATE_HOLD_MINE=""
    fi
    { exec 8>&-; } 2>/dev/null
    return 0
}

# wv_gate_hold_status — the live holder's record as JSON, or nothing.
wv_gate_hold_status() {
    local rec holder
    rec=$(_wv_gate_hold_path weave-gate.holder.json) || return 0
    holder=$(cat "$rec" 2>/dev/null) || return 0
    [ -n "$holder" ] && _wv_gate_hold_alive "$holder" && printf '%s\n' "$holder"
    return 0
}

# wv_gate_hold_foreign_status [<root>] — the record of a live gate holding
# ANOTHER worktree of this repository, or nothing (wv-8abb6a). Each worktree's
# lock and record sit under its own git dir: the main worktree's in the common
# dir, a linked one's in <common>/worktrees/<name>/. wv_gate_hold_status sees
# only its own. Same liveness test (pid plus start time), so a dead holder's
# leftover record reads as nothing.
wv_gate_hold_foreign_status() {
    local root="${1:-.}" common own rec holder
    common=$(git -C "$root" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || {
        common=$(git -C "$root" rev-parse --git-common-dir 2>/dev/null) || return 0
        case "$common" in /*) ;; *) common="$(cd "$root" && pwd)/$common" ;; esac
    }
    own=$(cd "$root" 2>/dev/null && _wv_gate_hold_path weave-gate.holder.json) || own=""
    case "$own" in '' | /*) ;; *) own="$(cd "$root" && pwd)/$own" ;; esac
    own=$(realpath -m "$own" 2>/dev/null || printf '%s' "$own")
    for rec in "$common/weave-gate.holder.json" "$common"/worktrees/*/weave-gate.holder.json; do
        [ -f "$rec" ] || continue
        [ "$(realpath -m "$rec" 2>/dev/null || printf '%s' "$rec")" != "$own" ] || continue
        holder=$(cat "$rec" 2>/dev/null) || continue
        if [ -n "$holder" ] && _wv_gate_hold_alive "$holder"; then
            printf '%s\n' "$holder"
            return 0
        fi
    done
    return 0
}

# wv_gate_push_outcome <state> [detail] [exit] — record this push's state:
# running when its gate starts, passed or failed when it ends.
wv_gate_push_outcome() {
    local f prev json
    f=$(_wv_gate_hold_path weave-gate-last-push.json) && [ -n "$f" ] || return 0
    if [ "$1" = running ]; then
        json=$(_wv_gate_hold_record pre-push "${2:-}" | jq -c '. + {state: "running"}') || return 0
    else
        prev=$(cat "$f" 2>/dev/null) || prev='{}'
        json=$(jq -c --arg s "$1" --arg d "${2:-}" --arg x "${3:-}" \
            --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            '. + {state: $s, ended_at: $at} + (if $d == "" then {} else {detail: $d} end)
               + (if $x == "" then {} else {exit: ($x | tonumber? // $x)} end)' <<< "$prev" 2>/dev/null) || return 0
    fi
    _wv_gate_hold_write "$f" "$json" || true
}

# wv_gate_push_last — the last push's record as JSON, or nothing. A push still
# marked running whose gate process is gone reads as "interrupted".
wv_gate_push_last() {
    local f json
    f=$(_wv_gate_hold_path weave-gate-last-push.json) || return 0
    json=$(cat "$f" 2>/dev/null) || return 0
    [ -n "$json" ] || return 0
    if [ "$(jq -r '.state // empty' <<< "$json" 2>/dev/null)" = running ] && ! _wv_gate_hold_alive "$json"; then
        json=$(jq -c '.state = "interrupted"' <<< "$json" 2>/dev/null) || return 0
    fi
    printf '%s\n' "$json"
}
