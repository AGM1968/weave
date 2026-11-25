#!/bin/bash
# wv-resolve-runtime.sh — side-effect-free runtime resolution helpers
#
# Source-only contract:
# - Do not add top-level commands, path setup, mkdir, echo, or set statements.
# - Do not read WV_HOT_ZONE or WV_DB at source time.
# - Keep process-local memoization inside is_container().

# Hash commands macOS lacks or keeps off a short PATH (wv-7d7d41): macOS 26
# ships md5sum and sha256sum only in /sbin, older macOS has md5 and shasum
# only. Every caller of `md5sum`/`sha256sum` in a shell that sourced this file
# gets the same output format ("<hex>  <name>", "-" for stdin) from whichever
# exists, so a repository hash keyed on it is the same on every platform.
# _wv_hash_cmd <md5|sha256> sets _WV_HASH_CMD to a command that prints that
# format, or fails; for xargs, which cannot call a function.
_wv_hash_cmd() {
    local bin="$1sum" d
    _WV_HASH_CMD=()
    if d=$(type -P "$bin"); then _WV_HASH_CMD=("$d"); return 0; fi
    for d in /sbin /usr/sbin; do [ -x "$d/$bin" ] && { _WV_HASH_CMD=("$d/$bin"); return 0; }; done
    case "$1" in
        sha256) d=$(type -P shasum) && { _WV_HASH_CMD=("$d" -a 256); return 0; } ;;
        md5) d=$(type -P md5) && { _WV_HASH_CMD=(_wv_md5_bsd "$d"); return 0; } ;;
    esac
    return 1
}
# BSD md5 prints the bare digest with -q; this adds md5sum's name column.
_wv_md5_bsd() {
    local md5="$1" h f; shift
    [ "${1:-}" != -- ] || shift
    if [ "$#" -eq 0 ]; then h=$("$md5" -q) || return 1; printf '%s  -\n' "$h"; return 0; fi
    for f in "$@"; do
        if [ "$f" = - ]; then h=$("$md5" -q) || return 1; else h=$("$md5" -q -- "$f") || return 1; fi
        printf '%s  %s\n' "$h" "$f"
    done
}
_wv_hash() {
    local algo="$1" _WV_HASH_CMD; shift
    _wv_hash_cmd "$algo" || { echo "${algo}sum: command not found" >&2; return 127; }
    "${_WV_HASH_CMD[@]}" "$@"
}
# Stand-ins take md5sum's arguments, even where this file calls them with none.
# shellcheck disable=SC2120
md5sum() { _wv_hash md5 "$@"; }
# shellcheck disable=SC2120
sha256sum() { _wv_hash sha256 "$@"; }

# wv_rename_new <src> <dst> -- rename src to dst, which must not exist: the
# guard GNU mv -T gives against moving into an existing directory, on any mv
# (BSD mv has no -T, wv-0bcb09).
wv_rename_new() {
    if [ -e "$2" ] || [ -L "$2" ]; then echo "rename: $2 already exists" >&2; return 1; fi
    mv -- "$1" "$2"
}

# Portable realpath forms (wv-e7426f): macOS realpath takes only -q, so GNU's
# -e, -m and --relative-to are spelled with plain realpath, which resolves an
# existing path fully on both.
# wv_realpath_existing <path> -- canonical path of something that exists (GNU -e).
wv_realpath_existing() {
    [ -e "$1" ] || return 1
    realpath -- "$1" 2>/dev/null
}
# wv_realpath_missing <path> -- canonical path whose tail may not exist yet
# (GNU -m): the longest existing ancestor resolved, the rest appended as given.
wv_realpath_missing() {
    local p="$1" rest="" head
    case "$p" in /*) ;; *) p="$PWD/$p" ;; esac
    while [ ! -e "$p" ] && [ ! -L "$p" ]; do
        rest="/${p##*/}$rest"
        p=${p%/*}
        [ -n "$p" ] || { p=/; break; }
    done
    head=$(realpath -- "$p" 2>/dev/null) || return 1
    [ "$head" != / ] || head=""
    printf '%s%s\n' "$head" "$rest"
}
# wv_relpath <root> <path> -- path relative to root ("." for root itself);
# fails when path is not under root, where GNU would print ../.
wv_relpath() {
    local root path
    root=$(wv_realpath_missing "$1") || return 1
    path=$(wv_realpath_missing "$2") || return 1
    if [ "$path" = "$root" ]; then echo .; return 0; fi
    case "$path" in "${root%/}"/*) printf '%s\n' "${path#"${root%/}"/}" ;; *) return 1 ;; esac
}

# wv_stat <mtime|size|dev|ino> <path> -- one numeric field of <path> itself
# (links not followed) from GNU stat -c or BSD stat -f (wv-372560). Prints
# nothing and fails when neither gives a number: on Linux `stat -f` is the
# file-system form, so its output is checked, never trusted.
wv_stat() {
    local gnu bsd out
    case "$1" in
        mtime) gnu=%Y bsd=%m ;; size) gnu=%s bsd=%z ;;
        dev) gnu=%d bsd=%d ;; ino) gnu=%i bsd=%i ;; *) return 2 ;;
    esac
    out=$(stat -c "$gnu" -- "$2" 2>/dev/null) && [[ "$out" =~ ^[0-9]+$ ]] \
        || out=$(stat -f "$bsd" -- "$2" 2>/dev/null) || return 1
    [[ "$out" =~ ^[0-9]+$ ]] || return 1
    printf '%s\n' "$out"
}

# wv_now <ns|ms|us> [<var>] -- the wall clock now: nanoseconds, milliseconds,
# or "<seconds>.<microseconds>" (wv-99f296). BSD date prints %N as a literal N
# and exits 0, so date's answer is checked; when it is not a number the
# reading comes from _wv_clock_ns: bash's EPOCHREALTIME, else python3. Fails
# when no clock answers. date is asked first, in the caller's format, so a test's date stub
# still steers the reading. Durations belong to wv-clock.sh; this is for ids,
# stamps and wall-clock timers.
_wv_clock_ns() {
    if [[ "${EPOCHREALTIME:-}" =~ ^([0-9]+)[.,]([0-9]{6})$ ]]; then
        printf '%s%s000\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
        return 0
    fi
    python3 -I -S -c 'import time; print(time.time_ns())' 2>/dev/null
}
# _wv_clock_as <ns|ms|us> -- a _wv_clock_ns reading in wv_now's units.
_wv_clock_as() {
    local t
    t=$(_wv_clock_ns) && [[ "$t" =~ ^[0-9]{19,}$ ]] || return 1
    case "$1" in
        ns) printf '%s\n' "$t" ;;
        ms) printf '%s\n' "${t:0:${#t}-6}" ;;
        us) printf '%s.%s\n' "${t:0:${#t}-9}" "${t:${#t}-9:6}" ;;
    esac
}
wv_now() {
    local _wn_fmt _wn_t
    case "$1" in ns) _wn_fmt=+%s%N ;; ms) _wn_fmt=+%s%3N ;; us) _wn_fmt=+%s.%6N ;; *) return 2 ;; esac
    _wn_t=$(date "$_wn_fmt" 2>/dev/null)
    [[ "$_wn_t" =~ ^[0-9]{13,}(\.[0-9]{6})?$ ]] || _wn_t=$(_wv_clock_as "$1") || return 1
    if [ -n "${2:-}" ]; then printf -v "$2" '%s' "$_wn_t"; else printf '%s\n' "$_wn_t"; fi
}

# wv_date_epoch <stamp> -- epoch seconds of a UTC stamp: YYYY-MM-DD, with an
# optional " HH:MM[:SS]" or "THH:MM[:SS]", fractional seconds, and a trailing
# Z or +00:00; or "@<epoch>" (wv-e1ee87). Zone-less stamps are UTC, as sqlite
# writes them. GNU date -d or BSD date -j -f; fails on anything else rather
# than answering 0, which reads as "very old".
wv_date_epoch() {
    local s="$1" out
    if [[ "$s" =~ ^@([0-9]+)$ ]]; then printf '%s\n' "${BASH_REMATCH[1]}"; return 0; fi
    s=${s%Z}; s=${s%+00:00}; s=${s/T/ }
    [[ "$s" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2})(\ ([0-9]{2}:[0-9]{2})(:([0-9]{2})(\.[0-9]+)?)?)?$ ]] || return 1
    s="${BASH_REMATCH[1]} ${BASH_REMATCH[3]:-00:00}:${BASH_REMATCH[5]:-00}"
    out=$(date -u -d "$s" +%s 2>/dev/null) && [[ "$out" =~ ^-?[0-9]+$ ]] \
        || out=$(date -j -u -f '%Y-%m-%d %H:%M:%S' "$s" +%s 2>/dev/null) || return 1
    [[ "$out" =~ ^-?[0-9]+$ ]] || return 1
    printf '%s\n' "$out"
}

# wv_date_fmt [-u] <epoch> <+format> -- format epoch seconds with GNU date -d @
# or BSD date -r (wv-e1ee87); -u for UTC, else local time. Fails, printing
# nothing, when neither accepts it.
wv_date_fmt() {
    local u=()
    [ "$1" != -u ] || { u=(-u); shift; }
    [[ "$1" =~ ^[0-9]+$ ]] || return 1
    date "${u[@]}" -d "@$1" "$2" 2>/dev/null || date "${u[@]}" -r "$1" "$2" 2>/dev/null
}

# wv_bound [--group] <duration> <command...> -- run <command> with a deadline,
# one mechanism on every host (owner ruling on wv-ea88cd, 2026-11-22: the
# deadline is Weave's policy everywhere; stopping a stage is a platform trait
# Weave absorbs). perl forks the command; at the deadline it sends TERM, then
# KILL after one second, and the call returns 124, as timeout(1) does.
# <duration> is seconds, fractions allowed, with an optional s, m or h.
# Without --group only the command is signalled and it stays in the caller's
# process group, keeping the terminal's signals (timeout --foreground). With
# --group it runs in a group of its own and the whole group is signalled, so
# a child holding a lock or the caller's output pipe goes with it. Without
# perl, timeout(1) with the same semantics; with neither it refuses with 125
# rather than run unbounded. Otherwise the command's own status (128+N when
# a signal ended it).
wv_bound() {
    local group=0 d secs
    [ "${1:-}" != --group ] || { group=1; shift; }
    d="${1:-}"; shift || true
    if [[ "$d" =~ ^([0-9]+([.][0-9]+)?)([smh]?)$ ]]; then
        case "${BASH_REMATCH[3]}" in
            m) secs=$(awk -v n="${BASH_REMATCH[1]}" 'BEGIN{print n*60}') ;;
            h) secs=$(awk -v n="${BASH_REMATCH[1]}" 'BEGIN{print n*3600}') ;;
            *) secs="${BASH_REMATCH[1]}" ;;
        esac
    else
        echo "wv_bound: '$d' is not a duration" >&2
        return 125
    fi
    [ "$#" -gt 0 ] || { echo "wv_bound: no command" >&2; return 125; }
    if command -v perl >/dev/null 2>&1; then
        perl -MPOSIX -MTime::HiRes=alarm,sleep -e '
            my ($t, $grp) = (shift, shift);
            my $pid = fork;
            defined $pid or exit 125;
            if (!$pid) { POSIX::setpgid(0, 0) if $grp; exec @ARGV or exit 127; }
            my $tgt = $grp ? -$pid : $pid;
            # perl restarts a blocking waitpid after a handler, so the
            # escalation lives in the handler: TERM at the deadline, KILL one
            # second later if the command ignored it.
            my $expired = 0;
            $SIG{ALRM} = sub {
                if ($expired) { kill "KILL", $tgt; return; }
                $expired = 1; kill "TERM", $tgt; alarm 1;
            };
            alarm $t;
            waitpid($pid, 0);
            alarm 0;
            exit 124 if $expired;
            my $s = $?;
            exit(($s & 127) ? 128 + ($s & 127) : $s >> 8);
        ' "$secs" "$group" "$@"
        return "$?"
    fi
    if command -v timeout >/dev/null 2>&1; then
        local rc=0
        if [ "$group" -eq 1 ]; then timeout -k 1 "$secs" "$@" || rc=$?
        else timeout --foreground -k 1 "$secs" "$@" || rc=$?; fi
        [ "$rc" -ne 137 ] || rc=124
        return "$rc"
    fi
    echo "wv_bound: no perl and no timeout(1); refusing to run '$1' unbounded" >&2
    return 125
}

# Check if a path has enough free space (in KB)
check_free_space() { # predicate
    local path="$1"
    local min_kb="${2:-${WV_MIN_SHM:-102400}}"
    local avail_kb
    avail_kb=$(df -k "$path" 2>/dev/null | awk 'NR==2 {print $4}')
    [ -n "$avail_kb" ] && [ "$avail_kb" -ge "$min_kb" ] 2>/dev/null
}

# Detect if running inside a container
is_container() {
    if [ -z "${_WV_CONTAINER:-}" ]; then
        if [ -f /.dockerenv ] || [ -f /run/.containerenv ] \
            || grep -qE 'docker|containerd|podman' /proc/1/cgroup 2>/dev/null \
            || [ -n "${CI:-}" ]; then
            _WV_CONTAINER=yes
        else
            _WV_CONTAINER=no
        fi
    fi
    [ "${_WV_CONTAINER:-no}" = "yes" ]
}

is_sandboxed_runtime() {
    # RUNTIME-CLASS axis (not identity): is this an agent harness shell? A
    # deliberate OR across harnesses, read by resolve_runtime_label. It no longer
    # decides hot-zone placement: resolve_hot_zone adopts the zone holding the
    # repository's database, else the /tmp zone, for every process (wv-b831e3).
    # CLAUDECODE=1 is Claude Code's marker in every process it starts;
    # CLAUDE_CODE_SSE_PORT is set only with an IDE attached (wv-50640a), so it
    # is kept as an alias (wv-21698b). For agent identity (claimed_by, delta
    # provenance) use resolve_agent_id, which keeps the harnesses distinct.
    [ -n "${CODEX_THREAD_ID:-}" ] || [ "${CODEX_CI:-}" = "1" ] \
        || [ "${COPILOT_AGENT:-}" = "1" ] || [ "${COPILOT_CLI:-}" = "1" ] || [ "${CLAUDECODE:-}" = "1" ] \
        || [ -n "${CLAUDE_CODE_SSE_PORT:-}" ]
}

# Backward-compatible alias — the name conflated placement with the Codex harness;
# callers should migrate to is_sandboxed_runtime(). (wv-727175)
is_codex_runtime() {
    is_sandboxed_runtime
}

# Detect the acting agent HARNESS for identity (claimed_by / delta provenance).
# Distinct from is_sandboxed_runtime(): that is a single OR for hot-zone placement;
# this distinguishes harnesses and refuses to silently guess when markers collide.
# Canonical implementation — see docs/AGENT-IDENTITY-CONTRACT.md for the full
# contract (precedence rule, identity format, and the python/MCP parity obligations).
#
# Returns claude | codex | copilot | human, or the label AI_AGENT names
# (_wv_ai_agent_label: pi, amp, any future harness that sets it).
# Memoized per process (_WV_AGENT_HARNESS) so the ambiguity diagnostic warns once.
#
# Ambiguity: a harness that launches another (e.g. a Codex shell spawned from a
# Claude session) inherits the parent's markers, so >1 can be present. We cannot
# infer nesting order from env, so we emit a diagnostic and fall back to a fixed
# precedence — correctness in that case comes from an explicit WV_AGENT_ID.
# Precedence: copilot > claude > codex. Originally codex was ranked above claude
# on the theory that CLAUDE_CODE_SSE_PORT leaks into a Codex child process spawned
# from a Claude session. In practice the observed failure ran the other way: a
# genuine top-level Claude Code session carried a stray Codex marker and got
# mislabeled codex-<host>-<user>, corrupting claimed_by/delta provenance and
# silently dropping GitHub assignee sync (wv-4d4c96). Claude now wins the
# claude/codex tie; copilot's marker (COPILOT_AGENT=1) is set by neither Claude
# nor Codex and has no known leak vector, so it keeps top precedence.
#
# Claude Code's marker is CLAUDECODE=1, which it sets in every process it starts.
# CLAUDE_CODE_SSE_PORT is NOT an identity marker (wv-08d7f9): a terminal with the
# Claude IDE integration exports it to everything it starts, so Codex, pi and
# Amp launched there carried it and resolved as an unverified claude session,
# refused every ownership change. A real Claude Code process always has
# CLAUDECODE=1. is_sandboxed_runtime (placement class) still reads it.
#
# AI_AGENT is the neutral marker (wv-08d7f9, owner decision 2026-11-04): the
# innermost agent sets it (Claude Code, pi and Amp observed; Codex does not),
# overwriting an inherited value, so in a tie it ranks above claude and codex,
# whose markers leak to children. copilot keeps top precedence.
#
# Copilot CLI (wv-6781d7, observed on 1.0.112) sets COPILOT_CLI=1 in its tool
# shell and hooks, never COPILOT_AGENT. Every process it starts inherits it, as
# with CLAUDECODE, so it ranks with the leaking markers: after AI_AGENT, before
# claude. Claude Code started from a Copilot CLI shell still resolves claude.
resolve_agent_harness() {
    if [ -n "${_WV_AGENT_HARNESS:-}" ]; then
        printf '%s\n' "$_WV_AGENT_HARNESS"
        return 0
    fi

    local present="" ai
    ai=$(_wv_ai_agent_label)
    [ "${COPILOT_AGENT:-}" = "1" ] && present="${present} copilot"
    case " $present " in *" $ai "*) ;; *) [ -z "$ai" ] || present="${present} ${ai}" ;; esac
    case " $present " in *" copilot "*) ;; *)
        [ "${COPILOT_CLI:-}" = "1" ] && present="${present} copilot" ;; esac
    case " $present " in *" claude "*) ;; *)
        [ "${CLAUDECODE:-}" = "1" ] && present="${present} claude" ;; esac
    case " $present " in *" codex "*) ;; *)
        { [ -n "${CODEX_THREAD_ID:-}" ] || [ "${CODEX_CI:-}" = "1" ]; } && present="${present} codex" ;; esac
    # Session-variable fallback (wv-55a24d): an Amp or pi process that does not
    # export AI_AGENT still carries its own session variable. Counted last, and
    # only when AI_AGENT names no harness: AI_AGENT is set by the innermost
    # agent and stays decisive, so Claude Code inside Amp is not made ambiguous.
    # Alone it names the harness; beside an inherited marker it does not win,
    # but the diagnostic names it instead of the parent winning silently.
    if [ -z "$ai" ]; then
        [ -n "${AMP_CURRENT_THREAD_ID:-}" ] && present="${present} amp"
        [ -n "${PI_SESSION_ID:-}" ] && present="${present} pi"
    fi
    present="${present# }"

    local result
    local n=0
    [ -n "$present" ] && n=$(printf '%s\n' "$present" | wc -w)
    if [ "$n" -eq 0 ]; then
        result="human"
    elif [ "$n" -eq 1 ]; then
        result="$present"
    else
        # present is built in precedence order:
        # copilot > AI_AGENT > copilot (COPILOT_CLI) > claude > codex > amp/pi
        # session variable.
        local host user suggested
        result="${present%% *}"
        host=$(hostname 2>/dev/null || echo "host")
        user=$(whoami 2>/dev/null || echo "user")
        suggested="${result}-${host}-${user}"
        printf 'wv: ambiguous agent markers (%s); using %s precedence. Set WV_AGENT_ID=%s to make identity explicit.\n' "$present" "$result" "$suggested" >&2
    fi

    _WV_AGENT_HARNESS="$result"
    printf '%s\n' "$result"
}

# _wv_ai_agent_label — the harness label AI_AGENT names, or nothing. Claude
# Code's versioned value (claude-code_<version>_agent) keeps its existing label
# claude; any other value is lowercased and reduced to [a-z0-9], at most 24
# characters, so it is filename- and claimed_by-safe (pi, amp). A value that
# reduces to nothing, or to human, names no harness.
_wv_ai_agent_label() {
    # C locale: lowercase ASCII only and match ranges byte by byte, so a
    # non-ASCII character is dropped exactly as the MCP mirror drops it.
    local LC_ALL=C v="${AI_AGENT:-}"
    v="${v,,}"
    case "$v" in
        claude-code*) printf 'claude\n'; return 0 ;;
    esac
    v="${v//[^a-z0-9]/}"
    v="${v:0:24}"
    case "$v" in ""|human) return 0 ;; esac
    printf '%s\n' "$v"
}

# Built-in defaults: the session-id variable of a harness observed to carry one
# in its shell and hook processes (S0 probe, wv-280f9e; hook probe on
# wv-99978b; pi and Amp tool processes, docs/findings/harness-env-probe-2026-11-04).
# Prints the variable NAME or nothing. This table is a convenience,
# not the contract: any host supplies a session through WV_SESSION_ID.
# Copilot CLI's tool shell carries COPILOT_AGENT_SESSION_ID, the sessionId its
# hook payloads carry (wv-6781d7, 1.0.112); its hooks get the payload only. It
# applies only with COPILOT_CLI=1: a COPILOT_AGENT=1 process was not observed
# with it, and naming an absent variable would refuse that session ownership.
_wv_session_var_for() {
    case "$1" in
        claude) printf 'CLAUDE_CODE_SESSION_ID\n' ;;
        codex)  printf 'CODEX_THREAD_ID\n' ;;
        pi)     printf 'PI_SESSION_ID\n' ;;
        amp)    printf 'AMP_CURRENT_THREAD_ID\n' ;;
        copilot) [ "${COPILOT_CLI:-}" != "1" ] || printf 'COPILOT_AGENT_SESSION_ID\n' ;;
    esac
}

# _wv_session_source — the variable that carries this process's session id:
# WV_SESSION_ID when it is set (the harness-agnostic channel: Amp, Copilot, a
# wrapper or a script exports it, no Weave change needed), else the harness's
# built-in default. Prints nothing when no session channel applies, so the
# identity stays actor-owned. A set-but-empty WV_SESSION_ID still names the
# channel: the session is declared and unverifiable, which fails closed.
_wv_session_source() {
    if [ -n "${WV_SESSION_ID+x}" ]; then
        printf 'WV_SESSION_ID\n'
    else
        _wv_session_var_for "$(resolve_agent_harness)"
    fi
}

# Resolve a stable identity for claimed_by and delta filenames
# (docs/AGENT-IDENTITY-CONTRACT.md §3):
#   1. explicit WV_AGENT_ID, verbatim         (always wins)
#   2. <harness>-<host>-<user>-h<digest16>    when a session channel applies
#      (_wv_session_source: WV_SESSION_ID, else the harness default) and
#      WV_SESSION_IDENTITY is not 0 (owner ruling 2026-11-03, wv-99978b):
#      digest16 is the first 16 hex of sha256 over the WHOLE verbatim session
#      id (owner ruling 2026-11-04, wv-24d57b): a prefix of the id is never
#      used, since a UUIDv7's prefix is its timestamp. Bounded and
#      filename-safe, and its prefix is the coarse id below.
#   3. <harness>-<host>-<user>                otherwise (no session channel, or
#      WV_SESSION_IDENTITY=0), so a human shell never collapses onto an agent.
# A session channel that applies but is unset or empty gets the coarse id
# here, for provenance only, and
# agent_identity_unverified succeeds; ownership changes go through
# require_agent_id, which refuses it. Always returns 0: callers assign it under
# set -e, and a nonzero status would abort sync or the cache key.
resolve_agent_id() {
    # Memoized per process (_WV_AGENT_ID_RESOLVED): identity is constant within a
    # process and this sits on the run-cache key hot path.
    if [ -n "${_WV_AGENT_ID_RESOLVED:-}" ]; then
        printf '%s\n' "$_WV_AGENT_ID_RESOLVED"
        return 0
    fi
    local id sid
    if [ -n "${WV_AGENT_ID:-}" ]; then
        id="$WV_AGENT_ID"
    else
        local host user
        host=$(hostname 2>/dev/null || echo "host")
        user=$(whoami 2>/dev/null || echo "user")
        id="$(resolve_agent_harness)-${host}-${user}"
        _wv_session_sid_compute
        sid="$_WV_SESSION_SID"
        [ -z "$sid" ] || id="${id}-h${sid}"
    fi
    _WV_AGENT_ID_RESOLVED="$id"
    printf '%s\n' "$id"
}

# _wv_session_sid_compute — sets _WV_SESSION_RAW (the verbatim session id, or
# empty when session identity does not apply, the channel carries none, or the
# id has no [A-Za-z0-9] character) and
# _WV_SESSION_SID (first 16 hex of sha256 over that whole id, owner ruling
# 2026-11-04, wv-24d57b: a prefix is never used, since a UUIDv7's prefix is its
# timestamp). With an id but no hasher, _WV_SESSION_SID stays empty and
# _WV_SESSION_NOHASH=1: the identity is unverified and ownership is refused,
# never a truncation fallback. Runs in the caller's shell (no command
# substitution) so the result is memoized on the raw id, which a hook may change
# by adopting its payload's.
_wv_session_sid_compute() {
    _WV_SESSION_RAW=""
    if [ -z "${WV_AGENT_ID:-}" ] && [ "${WV_SESSION_IDENTITY:-1}" != "0" ]; then
        local var
        if [ -n "${WV_SESSION_ID+x}" ]; then var=WV_SESSION_ID
        else var=$(_wv_session_var_for "$(resolve_agent_harness)"); fi
        [ -z "$var" ] || _WV_SESSION_RAW="${!var:-}"
        # An id with no [A-Za-z0-9] at all (empty, or only punctuation) is
        # malformed: unverified, as before the digest (wv-24d57b).
        [[ "$_WV_SESSION_RAW" =~ [A-Za-z0-9] ]] || _WV_SESSION_RAW=""
    fi
    [ "${_WV_SESSION_SID_FOR-x}" != "$_WV_SESSION_RAW" ] || return 0
    _WV_SESSION_SID_FOR="$_WV_SESSION_RAW"; _WV_SESSION_SID=""; _WV_SESSION_NOHASH=0
    [ -n "$_WV_SESSION_RAW" ] || return 0
    local out=""
    out=$(printf '%s' "$_WV_SESSION_RAW" | sha256sum 2>/dev/null) || out=""
    out="${out%% *}"
    if [[ "$out" =~ ^[0-9a-f]{64}$ ]]; then _WV_SESSION_SID="${out:0:16}"; else _WV_SESSION_NOHASH=1; fi
}

# _wv_agent_session_sid — prints the session part (digest16), or nothing.
_wv_agent_session_sid() {
    _wv_session_sid_compute
    [ -z "$_WV_SESSION_SID" ] || printf '%s\n' "$_WV_SESSION_SID"
}

# wv_session_file <hot_zone> <name> — this session's own copy of a
# session-scoped hot-zone file (epoch, heartbeat, laststop, sentinel):
# .session_<name>.<digest16> when the session is known, else the flat
# .session_<name>. Two sessions in one checkout share the hot zone, and one
# flat file let the second's start overwrite the first's state (wv-9a867a).
wv_session_file() {
    local sid
    _wv_session_sid_compute
    sid="$_WV_SESSION_SID"
    if [ -n "$sid" ]; then
        printf '%s/.session_%s.%s\n' "$1" "$2" "$sid"
    else
        printf '%s/.session_%s\n' "$1" "$2"
    fi
}

# resolve_agent_legacy_session_id — the -s<sid12> identity this session had
# before wv-24d57b (the id reduced to [A-Za-z0-9], first 12). Used only so an
# explicit `wv work --continue` can adopt this session's own pre-change claim,
# never to admit anything. Prints nothing when session identity does not apply.
resolve_agent_legacy_session_id() {
    _wv_session_sid_compute
    local raw="${_WV_SESSION_RAW//[^A-Za-z0-9]/}"
    [ -n "$raw" ] || return 0
    printf '%s-s%s\n' "$(resolve_agent_coarse_id)" "${raw:0:12}"
}

# agent_identity_unverified — succeeds when session identity applies (no
# WV_AGENT_ID, WV_SESSION_IDENTITY not 0, a session channel) but the channel's
# variable is unset or empty, or no sha256 hasher can digest it.
agent_identity_unverified() {
    [ -z "${WV_AGENT_ID:-}" ] && [ "${WV_SESSION_IDENTITY:-1}" != "0" ] || return 1
    [ -n "$(_wv_session_source)" ] || return 1
    _wv_session_sid_compute
    [ -z "$_WV_SESSION_SID" ]
}

# agent_ownership_mode — "session" when the identity carries a verified session
# part, else "actor": WV_AGENT_ID, WV_SESSION_IDENTITY=0, or no session channel
# (a human shell, a host that exports nothing). An actor-owned claim is shared
# by every session of that actor, so output labels it rather than implying
# isolation (wv-b2996f).
agent_ownership_mode() {
    _wv_session_sid_compute
    if [ -n "$_WV_SESSION_SID" ]; then printf 'session\n'; else printf 'actor\n'; fi
}

# The coarse actor id (<harness>-<host>-<user>, or WV_AGENT_ID) — what claims
# written before session identity hold. Used only to recognise them for an
# explicit `wv work --continue`, never to adopt them automatically.
resolve_agent_coarse_id() {
    if [ -n "${WV_AGENT_ID:-}" ]; then
        printf '%s\n' "$WV_AGENT_ID"
        return 0
    fi
    printf '%s-%s-%s\n' "$(resolve_agent_harness)" \
        "$(hostname 2>/dev/null || echo host)" "$(whoami 2>/dev/null || echo user)"
}

# wv_adopt_hook_session_id <payload> — when the harness has a built-in session
# variable but the hook process lacks it, and WV_SESSION_ID is unset, export
# the payload's session_id (Claude Code, and Copilot CLI with PascalCase
# events), thread_id (Codex) or sessionId (Copilot CLI's own format) as WV_SESSION_ID,
# the neutral channel, so a hook resolves the same owner as the shell (owner
# ruling 2026-11-04, wv-43d6be). Every hook entry calls it before it resolves
# an owner. An id already in the environment always wins.
# A harness with no built-in variable is left alone: its shell is
# session-qualified only through an exported WV_SESSION_ID, which its hooks
# inherit, and adopting here would make the hook a different owner.
wv_adopt_hook_session_id() {
    [ -z "${WV_SESSION_ID+x}" ] || return 0
    local var sid
    var=$(_wv_session_var_for "$(resolve_agent_harness 2>/dev/null)")
    [ -n "$var" ] || return 0
    [ -z "${!var:-}" ] || return 0
    sid=$(printf '%s' "$1" | jq -r '(.session_id // .thread_id // .sessionId // empty) | strings' 2>/dev/null) || return 0
    [ -n "$sid" ] || return 0
    export WV_SESSION_ID="$sid"
    _WV_AGENT_ID_RESOLVED=""
}

# require_agent_id — the identity for an OWNERSHIP change (claim, active add,
# commit admission, claim-scoped stop guard). Fails closed (rc 1, nothing on
# stdout) when resolve_agent_id cannot verify the session, instead of letting a
# session become a different owner mid-work (wv-99978b).
require_agent_id() {
    if agent_identity_unverified; then
        local harness var
        harness=$(resolve_agent_harness)
        var=$(_wv_session_source)
        if [ "${_WV_SESSION_NOHASH:-0}" = 1 ]; then
            printf 'wv: cannot verify this %s session: no sha256 hasher (sha256sum or shasum) can digest %s, so ownership is refused.\n' \
                "$harness" "${var:-its session id}" >&2
        else
            printf 'wv: cannot verify this %s session: %s is unset or empty, so ownership is refused.\n' \
                "$harness" "${var:-its session id}" >&2
        fi
        printf '  Fix: export the session id as WV_SESSION_ID, set WV_AGENT_ID=<stable id>, or WV_SESSION_IDENTITY=0 for actor-owned identity.\n' >&2
        return 1
    fi
    resolve_agent_id
}

resolve_runtime_label() {
    if is_sandboxed_runtime; then
        echo "codex"
    elif is_container; then
        echo "container"
    else
        echo "native"
    fi
}

canonicalize_runtime_path() {
    local path="$1"
    [ -z "$path" ] && return 0

    if [ -d "$path" ]; then
        (cd "$path" 2>/dev/null && pwd -P) || echo "$path"
    elif [ -e "$path" ]; then
        local path_dir path_base
        path_dir=$(dirname "$path")
        path_base=$(basename "$path")
        local canonical_dir
        canonical_dir=$( (cd "$path_dir" 2>/dev/null && pwd -P) || echo "$path_dir" )
        echo "${canonical_dir}/${path_base}"
    else
        echo "$path"
    fi
}

resolve_env_override_hot_zone() {
    if [ -n "${WV_HOT_ZONE:-}" ]; then
        echo "$WV_HOT_ZONE"
    elif [ -n "${WV_DB:-}" ]; then
        dirname "$WV_DB"
    fi
}

resolve_hot_zone_owner_file() {
    local hot_zone="$1"
    [ -n "$hot_zone" ] && echo "${hot_zone}/.repo_root" || true
}

# wv_shared_worktree_main <dir> <other-dir> — when the two directories are
# checkouts of one repository (the same git common dir) and <dir> is a linked
# worktree, print the main checkout; else print nothing. A linked worktree keeps
# its own graph (owner ruling wv-d88fed), so the refusals that send an agent
# back to "the" graph name the main checkout and say so (wv-ca1f94).
wv_shared_worktree_main() {
    local dir="$1" other="$2" common other_common gd
    [ -n "$dir" ] && [ -n "$other" ] && [ -d "$dir" ] && [ -d "$other" ] || return 0
    common=$(git -C "$dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 0
    other_common=$(git -C "$other" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 0
    [ "$common" = "$other_common" ] || return 0
    gd=$(git -C "$dir" rev-parse --path-format=absolute --absolute-git-dir 2>/dev/null) || return 0
    [ "$gd" != "$common" ] || return 0
    git -C "$dir" worktree list --porcelain 2>/dev/null | sed -n '1s/^worktree //p'
}

read_hot_zone_owner() {
    local hot_zone="$1"
    local owner_file
    owner_file=$(resolve_hot_zone_owner_file "$hot_zone")
    [ -n "$owner_file" ] || return 0
    [ -f "$owner_file" ] || return 0
    cat "$owner_file" 2>/dev/null || echo ""
}

# hot_zone_owner_state <hot-zone dir> — print "live", "gone" or "unknown" and,
# after a tab, why: whether the repository that owns a hot-zone directory is
# known to be deleted (wv-4ccc98). The one predicate behind wv hotzone gc and
# doctor's orphan check, which delete or advise deleting on it. A hot zone can
# hold writes no repository holds yet (node_files before a snapshot, wv-64178f;
# a store a failed sync could not publish), so an owner that cannot be seen is
# unknown, never gone:
#   - no .repo_root: unknown (wv init leaves a zone unstamped until a later
#     command names its owner, wv-29e416);
#   - the owner path is a directory: live;
#   - absent, and its parent directory is present and lists entries: gone (the
#     repository itself was removed from a filesystem that is there);
#   - absent under a temporary root (/tmp, /var/tmp, /dev/shm, $TMPDIR) with
#     the whole scratch tree gone: gone;
#   - anything else (a parent missing or empty, as an unmounted disk leaves
#     it; an unreadable parent): unknown.
# _hz_tmpdir_base <var> -- the temporary root named by $<var> (TMPDIR, TEMP),
# default /tmp, without a trailing slash: macOS sets TMPDIR to
# /var/folders/.../T/, and a join kept the slash, so zone paths read
# .../T//weave-<uid> and failed every prefix check (wv-4ccc98).
_hz_tmpdir_base() {
    local t="${!1:-/tmp}"
    t="${t%/}"
    printf '%s\n' "${t:-/}"
}

hot_zone_owner_state() {
    local owner parent tmp
    owner=$(read_hot_zone_owner "$1")
    owner="${owner%/}"
    if [ -z "$owner" ]; then
        printf 'unknown\tno owner recorded (.repo_root)\n'
    elif [ -d "$owner" ]; then
        printf 'live\t%s\n' "$owner"
    elif [ -e "$owner" ] || [ -L "$owner" ]; then
        printf 'unknown\t%s exists but is not a directory\n' "$owner"
    else
        parent="${owner%/*}"
        if [ -n "$parent" ] && [ -d "$parent" ] && [ -r "$parent" ] && [ -n "$(ls -A -- "$parent" 2>/dev/null)" ]; then
            printf 'gone\t%s removed from %s\n' "$owner" "$parent"
            return 0
        fi
        # Each root as written and canonical: .repo_root holds the canonical
        # path, and on macOS /tmp and $TMPDIR (/var/folders/...) resolve
        # under /private (wv-4ccc98).
        for tmp in /tmp /var/tmp /dev/shm "$(_hz_tmpdir_base TMPDIR)"; do
            case "$owner" in
                "$tmp"/*|"$(canonicalize_runtime_path "$tmp")"/*)
                    printf 'gone\t%s was under %s and is gone\n' "$owner" "$tmp"; return 0 ;;
            esac
        done
        printf 'unknown\t%s not found, and %s is missing or empty (an unmounted disk?)\n' "$owner" "${parent:-/}"
    fi
}

# hot_zone_rebuild_advice [<hot-zone dir>] — the one recovery command printed
# when a hot zone must be rebuilt from .weave/ (wv-4ccc98). It moves the zone
# aside instead of deleting it: the states that call for a rebuild (a lineage
# schema sync cannot stamp, a failed delta publish) are exactly the ones in
# which the zone holds writes no repository has yet, and node_files rows reach
# disk only in a snapshot (wv-64178f). It names the resolved path, since a
# user's shell has no WV_HOT_ZONE.
hot_zone_rebuild_advice() {
    local hz="${1:-${WV_HOT_ZONE:-}}" aside
    hz="${hz%/}"
    if [ -z "$hz" ]; then
        echo "move this repository's hot zone (the directory of wv hotzone db) aside, wv load, then wv hotzone diff the old brain.db against the new one and carry over what only the old copy holds"
        return 0
    fi
    aside="${hz}.broken-$(date +%Y%m%d%H%M%S)"
    # shellcheck disable=SC2016  # $(wv hotzone db) is for the user's shell to run
    printf 'mv %s %s && wv load; then wv hotzone diff %s "$(wv hotzone db)" and carry over what only the old copy holds before removing it\n' \
        "$hz" "$aside" "$aside/brain.db"
}

hot_zone_matches_repo() {
    local hot_zone="$1"
    local repo_root="$2"
    local owner=""

    [ -z "$hot_zone" ] && return 0
    if [ -z "$repo_root" ]; then
        repo_root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
    fi
    repo_root=$(canonicalize_runtime_path "$repo_root")

    owner=$(read_hot_zone_owner "$hot_zone")
    # No owner file → unknown; treat as matching (new or test hot zone).
    # Do NOT fall back to WV_PROJECT_DIR here — that made every ownerless hot zone
    # appear to match the current repo, preventing leaked-override detection when the
    # hot zone had an owner file pointing to a different repo but WV_PROJECT_DIR was set.
    [ -z "$owner" ] && return 0

    owner=$(canonicalize_runtime_path "$owner")
    [ "$owner" = "$repo_root" ]
}

# ── Hot-zone base safety (wv-80be32) ─────────────────────────────────────────
# Every base resolve_hot_zone can return sits in a world-writable sticky
# directory (/tmp, /dev/shm, macOS $TMPDIR), so another local user can create
# it first. Whoever controls the base can swap the per-repo directory inside it
# for one holding their own brain.db. A base is usable only when it is a real
# directory owned by this uid with no group or other write. Once it is, the
# sticky parent stops others renaming or deleting it, and only this uid can
# change its entries, so the per-repo leaf needs no check of its own.
# hot_zone_ensure is the one function here that creates anything; it acts
# only when called (the source-only contract above is about source time).

# ── The /tmp zone's two names (wv-95bddf, wv-97d68a) ─────────────────────────
# The /tmp zone is named /tmp/weave-hotzone-<uid>: it names the storage, not an
# agent. Its old name, /tmp/weave-codex-<uid>, made two investigations read it
# as a Codex-only zone.
# Created fresh (owner decision 2026-11-19, wv-97d68a), the neutral name is the
# real directory and the legacy name a symlink to it: a fence, never used as a
# base. Releases from rc.14 read that layout; an older binary refuses the
# symlinked base (wv-80be32) or, older still, follows it into the same
# directory, so none can make a second populated zone.
# The earlier layout, a real legacy directory with the neutral name a symlink
# to it (owner decision 2026-10-05), is still adopted as it stands: rc.14 to
# rc.18 create it, and nothing here moves live storage. wv hotzone migrate
# (lib/wv-hotzone-migrate.sh) relocates it, by hand, in a quiet window.
# Beside a real legacy directory the neutral directory comes first only when it
# alone holds databases: otherwise the legacy directory stays the authority,
# and a new repository lands there rather than making a second populated zone.
# Both names as separate directories that both hold databases is refused: that
# is two sets of graphs, and nothing here picks.

# _hot_zone_tmp_names — set _HZ_NEUTRAL and _HZ_LEGACY, the /tmp zone's two
# names. Under WV_TEST_MODE=1, WV_TEST_HOT_ZONE_ROOT (an absolute path)
# prefixes them and the other zones (_HZ_ROOT) so tests can populate them
# without touching live ones.
_hot_zone_tmp_names() {
    _HZ_ROOT=""
    if [ -n "${WV_TEST_HOT_ZONE_ROOT:-}" ]; then
        if [ "${WV_TEST_MODE:-}" = "1" ] && [ "${WV_TEST_HOT_ZONE_ROOT:0:1}" = "/" ]; then
            _HZ_ROOT="${WV_TEST_HOT_ZONE_ROOT%/}"
        elif [ -z "${_HZ_TEST_ROOT_WARNED:-}" ]; then
            _HZ_TEST_ROOT_WARNED=1
            echo "wv: WV_TEST_HOT_ZONE_ROOT needs WV_TEST_MODE=1 and an absolute path; ignoring it." >&2
        fi
    fi
    _HZ_NEUTRAL="${_HZ_ROOT}/tmp/weave-hotzone-${UID}"
    _HZ_LEGACY="${_HZ_ROOT}/tmp/weave-codex-${UID}"
}

# _hot_zone_populated <dir> — true when <dir> holds a non-empty */brain.db.
_hot_zone_populated() {
    local db
    for db in "$1"/*/brain.db; do
        [ -s "$db" ] && return 0
    done
    return 1
}

# _hot_zone_linux_zones — set _HZ_ZONES to the Linux hot zones placement picks
# from (wv-b831e3): first the /tmp zone every process uses by default, then the
# adopt-only legacy zones, which are used only while one already holds a repo's
# database. The /tmp zone is listed under the name that reaches its physical
# directory (see above); _HZ_TMP_CONFLICT is set when its two names are
# separate directories that both hold databases.
_hot_zone_linux_zones() {
    _hot_zone_tmp_names
    _HZ_TMP_CONFLICT=""
    if [ -L "$_HZ_NEUTRAL" ]; then
        # The alias: one zone under two names. hot_zone_check verifies it.
        _HZ_ZONES=("$_HZ_NEUTRAL")
    elif [ -e "$_HZ_NEUTRAL" ]; then
        if [ -d "$_HZ_LEGACY" ] && [ ! -L "$_HZ_LEGACY" ]; then
            if ! _hot_zone_populated "$_HZ_NEUTRAL"; then
                # The legacy directory stays the authority (wv-6f2eed).
                _HZ_ZONES=("$_HZ_LEGACY" "$_HZ_NEUTRAL")
            else
                _HZ_ZONES=("$_HZ_NEUTRAL" "$_HZ_LEGACY")
                _hot_zone_populated "$_HZ_LEGACY" && _HZ_TMP_CONFLICT=1
            fi
        else
            _HZ_ZONES=("$_HZ_NEUTRAL")
        fi
    elif [ -e "$_HZ_LEGACY" ] && [ ! -L "$_HZ_LEGACY" ]; then
        # Only the legacy name: hot_zone_ensure adds the alias on first use.
        _HZ_ZONES=("$_HZ_LEGACY")
    else
        # Neither, or only a legacy fence link whose directory is gone:
        # hot_zone_ensure creates the neutral directory and the fence link.
        _HZ_ZONES=("$_HZ_NEUTRAL")
    fi
    _HZ_ZONES+=("${_HZ_ROOT}/dev/shm/weave" "${_HZ_ROOT}/tmp/weave-${UID}")
}

# _hot_zone_inventory <dir> [<other dir>] — print one line per populated
# */brain.db in <dir>: the hash directory and the repository its .repo_root
# names, marked when <other dir> holds a copy of the same repository, since two
# copies may have diverged and need reconciling, not just syncing (wv-a73141).
_hot_zone_inventory() {
    local db dir owner mark
    for db in "$1"/*/brain.db; do
        [ -s "$db" ] || continue
        dir="${db%/brain.db}"
        owner=$(read_hot_zone_owner "$dir")
        mark=""
        [ -n "${2:-}" ] && [ -s "$2/${dir##*/}/brain.db" ] && mark="  [IN BOTH ZONES: reconcile, step 3]"
        echo "      ${dir}  (${owner:-repository unknown})${mark}"
    done
}

# _hot_zone_pair <base> — set _HZ_ALIAS_TARGET to the legacy directory when
# <base> is the neutral name (the one symlink target it may have, the layout
# rc.14 to rc.18 create), and _HZ_ALIAS_NAME to the zone's other name, which
# hot_zone_ensure links to <base> when it is absent: the legacy fence link
# beside the neutral directory (wv-97d68a), or the neutral alias beside a
# legacy directory. Both empty for any other base.
_hot_zone_pair() {
    local base="${1%/}"
    _HZ_ALIAS_TARGET=""
    _HZ_ALIAS_NAME=""
    _hot_zone_tmp_names
    case "$base" in
        "$_HZ_NEUTRAL") _HZ_ALIAS_TARGET="$_HZ_LEGACY"; _HZ_ALIAS_NAME="$_HZ_LEGACY" ;;
        "$_HZ_LEGACY") _HZ_ALIAS_NAME="$_HZ_NEUTRAL" ;;
        "/tmp/weave-hotzone-${UID}") _HZ_ALIAS_TARGET="/tmp/weave-codex-${UID}"
            _HZ_ALIAS_NAME="/tmp/weave-codex-${UID}" ;;
        "/tmp/weave-codex-${UID}") _HZ_ALIAS_NAME="/tmp/weave-hotzone-${UID}" ;;
    esac
}

# _hot_zone_bases — set _HZ_BASES to every base directory resolve_hot_zone can
# return that lives in a shared parent, plus the bash-dedup lock base
# (resolve_bash_lock_dir). No forks: wv runs this on every call.
# Under WV_TEST_MODE=1, WV_TEST_HOT_ZONE_BASE (an absolute path) adds one base
# so tests can drive the guard without touching a live one; it can only add,
# never remove. Set without WV_TEST_MODE=1, or relative, it is ignored with a
# warning, once per process (tests/wv-test-hooks.registry).
_hot_zone_bases() {
    _HZ_BASES=("/tmp/weave-hotzone-${UID}" "/tmp/weave-codex-${UID}" "/tmp/weave-${UID}"
        "/dev/shm/weave" "/tmp/weave-bash-locks-${UID}")
    if [ -n "${WV_TEST_HOT_ZONE_ROOT:-}" ]; then
        _hot_zone_tmp_names
        _HZ_BASES+=("$_HZ_NEUTRAL" "$_HZ_LEGACY" "${_HZ_ROOT}/dev/shm/weave"
            "${_HZ_ROOT}/tmp/weave-${UID}" "${_HZ_ROOT}/tmp/weave-bash-locks-${UID}")
    fi
    case "${OSTYPE:-}" in
        # The live temp-directory zone, and under a test root the zone
        # resolve_hot_zone now places there (wv-19572f).
        darwin*) _HZ_BASES+=("$(_hz_tmpdir_base TMPDIR)/weave-${UID}")
            [ -z "${WV_TEST_HOT_ZONE_ROOT:-}" ] || [ -z "${_HZ_ROOT:-}" ] || _HZ_BASES+=("${_HZ_ROOT}$(_hz_tmpdir_base TMPDIR)/weave-${UID}") ;;
        msys*|cygwin*|win32*)
            [ -z "${WV_TEST_HOT_ZONE_ROOT:-}" ] || [ -z "${_HZ_ROOT:-}" ] || _HZ_BASES+=("${_HZ_ROOT}$(_hz_tmpdir_base TEMP)/weave-${UID}") ;;
    esac
    [ -n "${WV_TEST_HOT_ZONE_BASE:-}" ] || return 0
    if [ "${WV_TEST_MODE:-}" = "1" ] && [ "${WV_TEST_HOT_ZONE_BASE:0:1}" = "/" ]; then
        _HZ_BASES+=("$WV_TEST_HOT_ZONE_BASE")
    elif [ -z "${_HZ_TEST_BASE_WARNED:-}" ]; then
        _HZ_TEST_BASE_WARNED=1
        if [ "${WV_TEST_MODE:-}" != "1" ]; then
            echo "wv: WV_TEST_HOT_ZONE_BASE is set but WV_TEST_MODE=1 is not; ignoring it." >&2
        else
            echo "wv: WV_TEST_HOT_ZONE_BASE='${WV_TEST_HOT_ZONE_BASE}' is not an absolute path; ignoring it." >&2
        fi
    fi
}

# hot_zone_known_bases — print _HZ_BASES, one per line.
hot_zone_known_bases() {
    _hot_zone_bases
    printf '%s\n' "${_HZ_BASES[@]}"
}

# hot_zone_guarded_base <path> — print the known shared-parent base <path> is
# or lies under, else nothing. Applies whether the path was resolved or named
# by WV_HOT_ZONE: a path inside a shared base is unsafe either way.
hot_zone_guarded_base() {
    local path="${1%/}" candidate
    [ -n "$path" ] || return 0
    _hot_zone_bases
    for candidate in "${_HZ_BASES[@]}"; do
        candidate="${candidate%/}"
        if [ "$path" = "$candidate" ] || [ "${path#"$candidate"/}" != "$path" ]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
}

# resolve_bash_lock_dir <repo-hash> [<session-key>] — the bash-dedup lock
# directory for a repo, and within it for one session when <session-key> is
# given (wv-da7c28): sessions on one repository run their hooks from the same
# project directory, so a repo-only key let one session's running commit deny
# another's, with a notification the denied session never receives. A call that
# names no session keeps the repository's shared directory.
# Per uid and guarded like a hot-zone base: the uid-less /tmp/weave-bash-locks
# it replaces could be created first by another user (wv-80be32).
# Under WV_TEST_MODE=1 an absolute WV_TEST_HOT_ZONE_ROOT prefixes it, as it
# prefixes every hot zone: a suite isolated by the root no longer reads or
# clears a live session's in-flight locks (wv-b3cb72).
resolve_bash_lock_dir() {
    local base="/tmp/weave-bash-locks-${UID}"
    if [ -n "${WV_TEST_HOT_ZONE_ROOT:-}" ]; then
        _hot_zone_tmp_names
        base="${_HZ_ROOT}${base}"
    fi
    if [ -n "${2:-}" ]; then
        printf '%s/%s/s-%s\n' "$base" "$1" "$2"
    else
        printf '%s/%s\n' "$base" "$1"
    fi
}

# hook_session_lock_key <payload> — the session a hook call belongs to, as a
# directory-safe name for resolve_bash_lock_dir: the payload's session_id
# (Claude Code, Copilot CLI), thread_id (Codex) or sessionId, else
# WV_SESSION_ID, else nothing (wv-da7c28).
hook_session_lock_key() {
    local sid
    sid=$(printf '%s' "${1:-}" | jq -r '(.session_id // .thread_id // .sessionId // empty) | strings' 2>/dev/null) || sid=""
    [ -n "$sid" ] || sid="${WV_SESSION_ID:-}"
    sid=${sid//[^A-Za-z0-9_-]/}
    printf '%s\n' "${sid:0:64}"
}

# _hot_zone_owner_mode <path> — print "<uid> <octal mode>" of <path> itself,
# never of a symlink's target (stat does not follow links by default).
_hot_zone_owner_mode() {
    local out
    out=$(stat -c '%u %a' -- "$1" 2>/dev/null) && [[ "$out" =~ ^[0-9]+\ [0-7]+$ ]] \
        || out=$(stat -f '%u %Lp' -- "$1" 2>/dev/null) || return 1
    [[ "$out" =~ ^[0-9]+\ [0-7]+$ ]] || return 1
    printf '%s\n' "$out"
}

# hot_zone_dir_problem <path> [<alias-target>] — print why <path> may not be a
# hot-zone base, or nothing when it may. An absent path is not a problem: the
# caller creates it. A symlink is refused unless <alias-target> is given, the
# link is this uid's, it points exactly at <alias-target>, and the target
# passes the same check (the one alias a rename migration may leave, wv-95bddf).
# An absent target is, like an absent path, for hot_zone_ensure to create: a
# removed legacy directory must not leave the neutral name unusable.
hot_zone_dir_problem() {
    local path="$1" alias_target="${2:-}" meta owner mode target
    if [ -L "$path" ]; then
        if [ -z "$alias_target" ]; then
            echo "is a symlink"
            return 0
        fi
        meta=$(_hot_zone_owner_mode "$path")
        owner="${meta%% *}"
        if [ "$owner" != "$UID" ]; then
            echo "is a symlink owned by uid ${owner:-unknown}, not ${UID}"
            return 0
        fi
        target=$(readlink -- "$path" 2>/dev/null)
        if [ "$target" != "$alias_target" ]; then
            echo "is a symlink to ${target:-nothing}, not ${alias_target}"
            return 0
        fi
        [ -e "$alias_target" ] || [ -L "$alias_target" ] || return 0
        if [ -L "$alias_target" ]; then
            echo "is a symlink to ${alias_target}, which is not a real directory"
            return 0
        fi
        meta=$(hot_zone_dir_problem "$alias_target")
        [ -n "$meta" ] && echo "is a symlink to ${alias_target}, which ${meta}"
        return 0
    fi
    [ -e "$path" ] || return 0
    if [ ! -d "$path" ]; then
        echo "is not a directory"
        return 0
    fi
    meta=$(_hot_zone_owner_mode "$path")
    owner="${meta%% *}"
    mode="${meta##* }"
    if [ -z "$meta" ] || ! [[ "$mode" =~ ^[0-7]+$ ]]; then
        echo "could not be inspected"
    elif [ "$owner" != "$UID" ]; then
        echo "is owned by uid ${owner}, not ${UID}"
    elif (( 8#$mode & 8#022 )); then
        echo "is writable by group or others (mode ${mode})"
    fi
}

# hot_zone_report_problem <base> <problem> — explain a refused base on stderr.
hot_zone_report_problem() {
    local base="$1" problem="$2"
    echo "wv: refusing to use hot-zone base ${base}: it ${problem}." >&2
    echo "    Another local user who controls it could swap this repository's graph for theirs (wv-80be32)." >&2
    case "$problem" in
        "is writable by group or others"*)
            echo "    It is yours: run  chmod go-w '${base}'  and retry." >&2 ;;
        *)
            echo "    Remove it as its owner or root, or set WV_HOT_ZONE to a private directory." >&2 ;;
    esac
}

# hot_zone_check <hot-zone> — return 1, after explaining, when the hot zone's
# guarded base exists and fails hot_zone_dir_problem. One stat per call.
hot_zone_check() {
    local base problem
    base=$(hot_zone_guarded_base "$1")
    [ -n "$base" ] || return 0
    _hot_zone_pair "$base"
    problem=$(hot_zone_dir_problem "$base" "$_HZ_ALIAS_TARGET")
    [ -z "$problem" ] && return 0
    hot_zone_report_problem "$base" "$problem"
    return 1
}

# _hot_zone_symlink <target> <name> — create <name> -> <target>, never following
# or entering whatever <name> already is (wv-5cd5a4). The callers check that
# <name> is absent first, but another process can create it in between, and a
# plain ln -s then treats the new alias (a link to a directory) as a destination
# directory: two first uses racing left legacy/weave-codex-<uid> -> legacy.
# -n refuses to follow an existing link and GNU -T an existing directory, so a
# loser fails with EEXIST and its caller judges what is there instead.
_hot_zone_symlink() {
    case "${OSTYPE:-}" in
        linux*) ln -snT -- "$1" "$2" 2>/dev/null ;;
        *) ln -sn -- "$1" "$2" 2>/dev/null ;;
    esac
}

# _hot_zone_mkdir <path> [<alias-target>] — create one directory, mode 700,
# and verify what is there afterwards without following links. A path that
# already exists, or that another process creates first, gets the same
# verification. <alias-target> (the legacy name when <path> is the neutral
# one, wv-95bddf) is the one symlink target an existing <path> may have; a
# neutral alias that outlived its legacy directory is replaced by the real
# directory (wv-97d68a), which is what an absent neutral name becomes too.
_hot_zone_mkdir() {
    local path="$1" alias_target="${2:-}"
    if [ -n "$alias_target" ] && [ -L "$path" ] && [ ! -e "$alias_target" ] && [ ! -L "$alias_target" ] \
        && [ "$(readlink -- "$path")" = "$alias_target" ]; then
        # The alias reaches nothing: drop the link, not anything it named.
        rm -f -- "$path" 2>/dev/null || true
    fi
    if [ ! -e "$path" ] && [ ! -L "$path" ]; then
        ( umask 077 && mkdir -- "$path" ) 2>/dev/null || true
    fi
    if [ ! -e "$path" ] && [ ! -L "$path" ]; then
        echo "could not be created"
        return 0
    fi
    hot_zone_dir_problem "$path" "$alias_target"
}

# _hot_zone_test_tmpdir_parent <base> — under WV_TEST_MODE=1 with a test root,
# create the parent of the prefixed temp-directory zone (<root>$TMPDIR on
# macOS, <root>$TEMP on Windows) inside that root. A guarded base is made
# with a plain mkdir because its parent is a shared system directory that
# exists; under a test root that parent is the root plus the whole $TMPDIR
# path, which no suite should have to spell (wv-19572f). Nothing else, and
# nothing outside the test root, is ever created here.
_hot_zone_test_tmpdir_parent() {
    [ "${WV_TEST_MODE:-}" = "1" ] && [ -n "${WV_TEST_HOT_ZONE_ROOT:-}" ] && [ -n "${_HZ_ROOT:-}" ] || return 0
    local t=""
    case "${OSTYPE:-}" in
        darwin*) t=$(_hz_tmpdir_base TMPDIR) ;;
        msys*|cygwin*|win32*) t=$(_hz_tmpdir_base TEMP) ;;
    esac
    # The temp-directory zone, or the bash-dedup lock base (wv-b3cb72), whose
    # parent <root>/tmp a suite that never made the Linux zones may not have.
    if { [ -n "$t" ] && [ "$1" = "${_HZ_ROOT}${t}/weave-${UID}" ]; } \
        || [ "$1" = "${_HZ_ROOT}/tmp/weave-bash-locks-${UID}" ]; then
        [ -d "${1%/*}" ] || ( umask 077 && mkdir -p -- "${1%/*}" ) 2>/dev/null || true
    fi
}

# hot_zone_ensure <path> — create <path> for use. Under a guarded base, the
# base and the per-repo directory below it are each created with mkdir under
# umask 077 and verified without following links; anything deeper is inside a
# verified directory of ours and is created 700 in one step. Any failure is
# explained and returns 1, and nothing is chmodded. Outside a guarded base (a
# WV_HOT_ZONE the caller chose), <path> is created 700 as before.
hot_zone_ensure() {
    local path="${1%/}" base rest leaf problem
    [ -n "$path" ] || return 1
    base=$(hot_zone_guarded_base "$path")
    if [ -z "$base" ]; then
        # An explicit status: a bare return in a function called from a trap
        # (wv_finalize on EXIT) returns the status from before the trap.
        ( umask 077 && mkdir -p -- "$path" )
        return $?
    fi
    _hot_zone_pair "$base"
    _hot_zone_test_tmpdir_parent "$base"
    problem=$(_hot_zone_mkdir "$base" "$_HZ_ALIAS_TARGET")
    if [ -n "$problem" ]; then
        hot_zone_report_problem "$base" "$problem"
        return 1
    fi
    # The zone's other name absent: link it here. Beside the neutral directory
    # it is the legacy fence link (wv-97d68a); beside a legacy directory, the
    # neutral alias. Best effort; whatever is there instead, including a link
    # another process created first, is judged when it is resolved. A neutral
    # alias never gets a link here: its legacy directory exists.
    if [ -n "$_HZ_ALIAS_NAME" ] && [ ! -e "$_HZ_ALIAS_NAME" ] && [ ! -L "$_HZ_ALIAS_NAME" ]; then
        _hot_zone_symlink "$base" "$_HZ_ALIAS_NAME" || true
    fi
    [ "$path" = "$base" ] && return 0
    rest="${path#"$base"/}"
    leaf="${base}/${rest%%/*}"
    problem=$(_hot_zone_mkdir "$leaf")
    if [ -n "$problem" ]; then
        echo "wv: refusing to use hot zone ${leaf}: it ${problem} (wv-80be32)." >&2
        return 1
    fi
    [ "$path" = "$leaf" ] && return 0
    ( umask 077 && mkdir -p -- "$path" )
}

# _hot_zone_repo_hash <repo-root> — the per-repo directory name. Must match
# weave_gh/data.py _repo_hash: md5 of the path plus echo's newline.
_hot_zone_repo_hash() {
    echo "$1" | md5sum | cut -c1-8
}

# resolve_hot_zone [<repo-root>] — print the hot-zone base for this process.
#
# Linux placement (owner ruling 2026-10-06, wv-b831e3): the zone already
# holding a non-empty brain.db for this repository is the authority, whichever
# zone that is. When none does, every process -- human shell, agent, container
# -- uses the /tmp zone. Which process starts first after a boot no longer
# decides, and neither does an agent marker. When more than one zone holds
# one, this explains on stderr, still prints the /tmp zone (hooks keep a path
# for their session files), and returns 1; wv refuses to run on that.
# Without a repository root, the /tmp zone. Which of the /tmp zone's two names
# is printed, and when its two names are refused, is set out above
# _hot_zone_tmp_names (wv-95bddf).
resolve_hot_zone() {
    if [ -n "${WV_HOT_ZONE:-}" ]; then
        echo "${WV_HOT_ZONE}"
        return 0
    fi

    local repo_root="${1:-}" uid="${UID}"
    local weave_dir="${WEAVE_DIR:-${WV_PROJECT_DIR:-$PWD}/.weave}"
    # The test root prefixes the temp-directory zone too, as it prefixes the
    # Linux zones: without it a suite on macOS or Windows that isolates its
    # zones still resolved the per-user zone a live session uses (wv-19572f).
    case "${OSTYPE:-}" in
        linux*) ;;
        darwin*)
            _hot_zone_tmp_names
            echo "${_HZ_ROOT}$(_hz_tmpdir_base TMPDIR)/weave-${uid}"
            return 0 ;;
        msys*|cygwin*|win32*)
            _hot_zone_tmp_names
            echo "${_HZ_ROOT}$(_hz_tmpdir_base TEMP)/weave-${uid}"
            return 0 ;;
        *)
            echo "$weave_dir"
            return 0 ;;
    esac

    _hot_zone_linux_zones
    local default_zone="${_HZ_ZONES[0]}"
    if [ -z "$repo_root" ] || [ "$repo_root" = "/" ]; then
        echo "$default_zone"
        return 0
    fi
    if [ -n "$_HZ_TMP_CONFLICT" ]; then
        {
            echo "wv: refusing to choose a hot zone: ${_HZ_NEUTRAL} and ${_HZ_LEGACY} are separate directories and both hold databases (wv-95bddf)."
            echo "    Until a relocation, the neutral name may only be a symlink to the legacy directory. Databases found:"
            _hot_zone_inventory "$_HZ_NEUTRAL" "$_HZ_LEGACY"
            _hot_zone_inventory "$_HZ_LEGACY" "$_HZ_NEUTRAL"
            echo "    Remove nothing yet: each may be the only copy of its repository's graph, and they need not be this repository's."
            echo "    1. Stop every wv process and agent session on this host."
            echo "    2. Back up every database listed, outside both zones: sqlite3 <brain.db> \".backup '<file>'\" (never cp)."
            echo "    3. A repository in both zones has two copies that may have diverged, and syncing both does not merge"
            echo "       them (wv-a73141). Run wv hotzone diff <legacy copy> <neutral copy>, carry every change the legacy"
            echo "       copy lacks into it with WV_HOT_ZONE=<legacy hash dir> wv ...; rerun it until every difference left is one you chose to drop."
            echo "    4. In each repository listed, run WV_HOT_ZONE=<its hash dir, the legacy one if in both> wv sync."
            echo "    5. Only then remove ${_HZ_NEUTRAL}; the legacy directory stays the authority, and wv load rebuilds"
            echo "       the rest from .weave/. The backups are the way back if a step went wrong."
        } >&2
        echo "$default_zone"
        return 1
    fi
    local repo_hash zone
    local -a holders=()
    repo_hash=$(_hot_zone_repo_hash "$repo_root")
    for zone in "${_HZ_ZONES[@]}"; do
        [ -s "${zone}/${repo_hash}/brain.db" ] && holders+=("$zone")
    done
    case "${#holders[@]}" in
        0) echo "$default_zone" ;;
        1) echo "${holders[0]}" ;;
        *)
            echo "wv: refusing to choose a database: ${repo_root} has one in more than one hot zone (wv-b831e3):" >&2
            for zone in "${holders[@]}"; do
                echo "    ${zone}/${repo_hash}/brain.db" >&2
            done
            {
                echo "    Remove nothing yet: the copies may have diverged, and syncing both does not merge them (wv-a73141)."
                echo "    1. Stop every wv process and agent session on this host."
                echo "    2. Back up each, outside every zone: sqlite3 <brain.db> \".backup '<file>'\" (never cp)."
                echo "    3. Run wv hotzone diff <copy you keep> <other copy>; carry every change the kept copy lacks into it"
                echo "       with WV_HOT_ZONE=<zone>/${repo_hash} wv ...; rerun it until every difference left is one you chose to drop."
                echo "    4. WV_HOT_ZONE=<zone of the kept copy>/${repo_hash} wv sync, then remove the other <zone>/${repo_hash}."
            } >&2
            echo "$default_zone"
            return 1 ;;
    esac
}

# shellcheck disable=SC2120  # optional positional override args; callers use env-var defaults
resolve_repo_hot_zone() {
    if [ -n "${WV_HOT_ZONE:-}" ]; then
        echo "$WV_HOT_ZONE"
        return
    fi

    local base_hot_zone="${1:-}"
    local repo_root="${2:-${WV_PROJECT_DIR:-}}"
    local rc=0

    if [ -z "$repo_root" ]; then
        repo_root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
        # Reject home dir — same boundary as wv-config.sh.
        if [ "$repo_root" = "$HOME" ] || [ "$repo_root" = "/root" ]; then
            repo_root=""
        fi
    fi
    if [ -z "$base_hot_zone" ]; then
        # Placement is per repository (wv-b831e3); a conflict is passed on.
        base_hot_zone=$(resolve_hot_zone "$repo_root") || rc=$?
    fi

    if [ -n "$repo_root" ] && [ "$repo_root" != "/" ]; then
        echo "${base_hot_zone}/$(_hot_zone_repo_hash "$repo_root")"
    else
        echo "$base_hot_zone"
    fi
    return "$rc"
}

resolve_unix_clock_parts() {
    local _ucp_ns
    if wv_now ns _ucp_ns; then
        printf '%s %s\n' "${_ucp_ns:0:${#_ucp_ns}-9}" "${_ucp_ns:${#_ucp_ns}-9}"
        return 0
    fi
    printf '%s %09d\n' "$(date +%s 2>/dev/null || echo 0)" 0
}

resolve_delta_filename_prefix() {
    local outvar="${1:-}"
    local clock_parts epoch_sec epoch_subsec stamp_key prefix

    clock_parts=$(resolve_unix_clock_parts)
    epoch_sec="${clock_parts%% *}"
    epoch_subsec="${clock_parts##* }"
    stamp_key="${epoch_sec}-${epoch_subsec}"

    if [ "${_WV_DELTA_STAMP_KEY:-}" = "$stamp_key" ]; then
        _WV_DELTA_STAMP_SEQ=$(( ${_WV_DELTA_STAMP_SEQ:-0} + 1 ))
    else
        _WV_DELTA_STAMP_KEY="$stamp_key"
        _WV_DELTA_STAMP_SEQ=0
    fi

    printf -v prefix '%010d-%09d-%06d' \
        "$epoch_sec" "$((10#$epoch_subsec))" "${_WV_DELTA_STAMP_SEQ:-0}"
    if [ -n "$outvar" ]; then
        printf -v "$outvar" '%s' "$prefix"
    else
        printf '%s\n' "$prefix"
    fi
}

resolve_db() {
    if [ -n "${WV_DB:-}" ]; then
        echo "$WV_DB"
        return
    fi

    local hot_zone="${1:-}"
    if [ -z "$hot_zone" ]; then
        hot_zone=$(resolve_repo_hot_zone)
    fi
    echo "${hot_zone}/brain.db"
}

# resolve_owner_dir — the hot-zone directory for this owner's session-local
# state: primary node, phase and context stamps (owner ruling 2026-11-04,
# wv-43d6be). Two sessions in one checkout share the hot zone and its database
# but never this directory. Keyed by the resolved agent id made filename-safe,
# so WV_AGENT_ID, session identity and actor-owned identity all key it. When
# the session cannot be verified it prints a directory no verified owner uses
# and returns 1: readers find nothing there and writers skip it.
resolve_owner_dir() {
    local hot_zone="${1:-}" key
    if [ -z "$hot_zone" ]; then
        hot_zone=$(resolve_repo_hot_zone)
    fi
    if agent_identity_unverified; then
        printf '%s/owners/_unverified\n' "$hot_zone"
        return 1
    fi
    key=$(resolve_agent_id)
    key="${key//[^A-Za-z0-9._-]/_}"
    case "$key" in "" | . | .. | _unverified) key="_${key}" ;; esac
    printf '%s/owners/%s\n' "$hot_zone" "$key"
}

# The three session-local files below print their path and return 1 when the
# session cannot be verified (the path is then under owners/_unverified, never
# written). Callers create the parent directory before writing.

resolve_primary_file() {
    if [ -n "${WV_PRIMARY_FILE:-}" ]; then
        echo "$WV_PRIMARY_FILE"
        return 0
    fi
    local dir rc=0
    dir=$(resolve_owner_dir "${1:-}") || rc=1
    echo "${dir}/primary"
    return "$rc"
}

# resolve_phase_file — this owner's session phase file (never the hot-zone
# root, which every session shares).
resolve_phase_file() {
    local dir rc=0
    dir=$(resolve_owner_dir "${1:-}") || rc=1
    echo "${dir}/.session_phase"
    return "$rc"
}

# resolve_context_stamp <node-id> [hot-zone] — this owner's first-call stamp for
# a node's Context Pack; another session's stamp never satisfies it.
resolve_context_stamp() {
    local dir rc=0
    dir=$(resolve_owner_dir "${2:-}") || rc=1
    echo "${dir}/.context_checked_${1}"
    return "$rc"
}

resolve_active_primary() {
    local db_path="${1:-}"
    local hot_zone="${2:-}"
    local primary_file="${3:-}"
    local primary_id=""
    local fallback_id=""

    if [ -z "$hot_zone" ]; then
        hot_zone=$(resolve_repo_hot_zone)
    fi
    if [ -z "$db_path" ]; then
        db_path=$(resolve_db "$hot_zone")
    fi
    if [ -z "$primary_file" ]; then
        primary_file=$(resolve_primary_file "$hot_zone")
    fi
    [ -f "$db_path" ] || return 0
    # Only this owner's claims count (wv-43d6be): an unverifiable session has
    # no primary, and another session's active node is never this one's.
    local owner
    owner=$(require_agent_id 2>/dev/null) || return 0
    owner=${owner//\'/\'\'}

    if [ -f "$primary_file" ]; then
        primary_id=$(cat "$primary_file" 2>/dev/null || echo "")
        if [ -n "$primary_id" ]; then
            local escaped_primary
            escaped_primary=${primary_id//\'/\'\'}
            local primary_status
            primary_status=$(sqlite3 "$db_path" "SELECT status FROM nodes WHERE id='${escaped_primary}' AND json_extract(metadata, '\$.claimed_by')='${owner}' LIMIT 1;" 2>/dev/null || echo "")
            if [ "$primary_status" = "active" ]; then
                echo "$primary_id"
                return 0
            fi
            rm -f "$primary_file" 2>/dev/null || true
        fi
    fi

    # The fallback is this owner's newest claim, never another session's.
    fallback_id=$(sqlite3 "$db_path" "SELECT id FROM nodes WHERE status='active' AND json_extract(metadata, '\$.claimed_by')='${owner}' ORDER BY updated_at DESC LIMIT 1;" 2>/dev/null || echo "")
    [ -n "$fallback_id" ] && echo "$fallback_id"
    return 0
}

is_attribution_tool() {
    case "${1:-}" in
        Edit|Write|NotebookEdit|create_file|replace_string_in_file|insert_edit_into_file|multi_replace_string_in_file|edit_notebook_file)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# Backward-compatible alias while callers migrate to resolve_hot_zone().
detect_hot_zone() {
    resolve_hot_zone
}
