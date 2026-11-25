#!/bin/bash
# wv-config.sh — Configuration, hot zone detection, colors
#
# Sourced by: wv entry point
# Dependencies: None

# python >= 3.11 first on PATH before anything wv or the pre-commit hook starts
# runs python3 (wv-892318). Beside this file; an install without it refuses.
# shellcheck source=scripts/lib/wv-python-floor.sh
source "${BASH_SOURCE[0]%/*}/wv-python-floor.sh" || { echo "wv: ${BASH_SOURCE[0]%/*}/wv-python-floor.sh is missing; reinstall Weave." >&2; exit 1; }
_wv_python_floor

# ═══════════════════════════════════════════════════════════════════════════
# Version and Paths
# ═══════════════════════════════════════════════════════════════════════════

# Read version from VERSION file (next to this script)
_WV_LIB_DIR="${WV_LIB_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
if [ -f "$_WV_LIB_DIR/lib/VERSION" ]; then
    # Builtins only (wv-2ddb44): the whole file with every whitespace character
    # removed, as cat | tr -d '[:space:]' gave, without a fork and two execs.
    WV_VERSION=""
    IFS= read -r -d '' WV_VERSION < "$_WV_LIB_DIR/lib/VERSION" || true
    WV_VERSION="${WV_VERSION//[[:space:]]/}"
else
    WV_VERSION="1.0.0"  # Fallback
fi

# wv_install_provenance_file — path to the INSTALL_PROVENANCE of the install
# actually running, or empty.
#
# Shared by wv --version and wv doctor so the two can never describe different
# installs. The resolution is not just "$WV_LIB_DIR/lib/...": honour WV_LIB_DIR
# for a RELOCATED install, but not when it points at the source checkout, where
# WV_LIB_DIR is scripts/ and reading provenance from there would describe the
# working tree rather than any installed copy.
wv_install_provenance_file() {
    local dir="${WV_LIB_DIR:-${HOME}/.local/lib/weave}"
    if [ -f "$dir/wv" ] || [ -f "$dir/../scripts/wv" ]; then
        dir="${HOME}/.local/lib/weave"
    fi
    [ -f "$dir/lib/INSTALL_PROVENANCE" ] || return 1
    printf '%s' "$dir/lib/INSTALL_PROVENANCE"
}

# wv_build_identity — the build this install came from, or empty.
#
# The release tag alone cannot tell two installs apart: this machine and the gpu
# box both reported 1.71.0-rc.12 while running different persistence code, 72
# commits apart (wv-84447f). `git describe` carries the commit and the dirty
# marker, which is exactly the distinction the tag loses.
wv_build_identity() {
    local prov
    prov=$(wv_install_provenance_file) || return 1
    local desc
    desc=$(grep -m1 '^describe=' "$prov" 2>/dev/null | cut -d= -f2-)
    [ -n "$desc" ] && [ "$desc" != "unknown" ] || return 1
    printf '%s' "$desc"
}

# SCRIPT_DIR is set by entry point, fall back if sourced directly
SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
# Reject home/root as REPO_ROOT — same boundary rule as wv-resolve-project.sh.
# git failing from ~ produces REPO_ROOT=$HOME → WEAVE_DIR=~/.weave → source_hooks_dir=~/.claude/hooks
# (caveman plugin), causing false hook-drift warnings in wv doctor.
if [ "$REPO_ROOT" = "$HOME" ] || [ "$REPO_ROOT" = "/root" ]; then
    REPO_ROOT=""
fi
# Whether the caller chose WEAVE_DIR or it follows the working directory: a
# WV_DB override writes safely only into a .weave/ chosen with it (wv-7ab3cd).
WEAVE_DIR_CUSTOM="${WEAVE_DIR:+1}"
WEAVE_DIR="${WEAVE_DIR:-${REPO_ROOT:+$REPO_ROOT/.weave}}"

# Cutover evidence, named here because two consumers need the same path before
# either writes it: the composite causal identity hashes the manifest's presence
# and bytes on every instrumented call (wv-62bb60), and wv cutover will write it
# (wv-7e17b9). Until it does, the identity records it as explicitly absent --
# absent and present hash differently, so the file appearing moves the identity
# even though nothing here yet knows what it will contain.
WV_CUTOVER_MARKER_FILE="${WV_CUTOVER_MARKER_FILE:-causal-cutover}"
WV_CUTOVER_AUTHORIZATION_FILE="${WV_CUTOVER_AUTHORIZATION_FILE:-cutover-authorization.json}"

# Side-effect-free runtime resolution helpers shared with hooks.
source "$_WV_LIB_DIR/lib/wv-resolve-runtime.sh"
REPO_ROOT=$(canonicalize_runtime_path "$REPO_ROOT")

# ═══════════════════════════════════════════════════════════════════════════
# Hot Zone Configuration
# ═══════════════════════════════════════════════════════════════════════════

# Maximum hot zone usage in MB. Default 512MB.
WV_HOT_SIZE=${WV_HOT_SIZE:-512}

# Maximum database size in bytes. Default 50MB.
WV_MAX_DB_SIZE=${WV_MAX_DB_SIZE:-52428800}

# ───────────────────────────────────────────────────────────────────────────
# Global user knobs — disk-sourced every invocation (CLI + hook-spawned)
# ───────────────────────────────────────────────────────────────────────────
# User-global opt-in knobs (e.g. WV_CALL_LOG) live in $WV_CONFIG_DIR/config.env,
# not a shell `export`. Reading from disk on every invocation means enablement
# survives reboot AND does not depend on env inheritance — a harness-spawned hook
# `wv` call reads the same file the interactive shell does, so CLI and hook paths
# can never disagree (resolves the WV_CALL_LOG env-inheritance split-brain).
# Managed via `wv config`. Safe + zero-overhead when the file is absent.
#
# Except inside a test suite (wv-6b0f57). Under WV_TEST_SUITE=1 with no
# WV_CONFIG_DIR in the environment, config.env is the user's own, and it cannot
# turn on the call log: WV_CALL_LOG keeps whatever the environment gave it, or
# stays unset. Suites exported WV_HOT_ZONE/WV_DB but not WV_CONFIG_DIR, so every
# wv call they made appended to the user's durable log (12k+ rows from temp
# repositories by 2026-10-07, enough to force a rotation). A suite that tests
# config.env-driven logging names its own config directory and is unaffected.
# Not WV_TEST_MODE: suites switch that off to test the unarmed seams, and this
# has to hold for the whole run, across the mcp and sync children that retag
# WV_CALL_SOURCE. "In the environment" means exported: the line below sets
# WV_CONFIG_DIR as a plain variable, and a suite that sources this file twice
# in one shell (test-durability.sh does) would otherwise read its own default
# back as a choice and let the user's config.env in on the second pass.
#
# An inherited WV_CALL_LOG is not always a suite's choice (wv-37c458): a hook or
# a gate that loaded the user's config.env exports its WV_CALL_LOG (set -a
# below) to every child, the suites it runs among them. Under the rule above
# such a suite kept it and wrote into the user's durable log. An environment
# WV_CALL_LOG is therefore kept only when it is neither what the user's
# config.env sets nor the default user log path; a suite that names its own
# scratch log still logs there.
_wv_cfg_from_env=""
[ -n "${WV_CONFIG_DIR:-}" ] && [[ "$(declare -p WV_CONFIG_DIR 2>/dev/null)" =~ ^declare\ -[a-zA-Z]*x ]] &&
    _wv_cfg_from_env=1
_wv_env_call_log_set="${WV_CALL_LOG+1}"
_wv_env_call_log="${WV_CALL_LOG-}"
WV_CONFIG_DIR="${WV_CONFIG_DIR:-$HOME/.config/weave}"
_wv_env_file="$WV_CONFIG_DIR/config.env"
_wv_cfg_call_log=""
if [ -f "$_wv_env_file" ]; then
    unset WV_CALL_LOG
    set -a
    # shellcheck disable=SC1090  # path is user config, resolved at runtime
    . "$_wv_env_file" 2>/dev/null || true
    set +a
    _wv_cfg_call_log="${WV_CALL_LOG-}"
    # Outside a suite the config still wins over the environment, as before.
    [ -z "${WV_CALL_LOG+1}" ] && [ -n "$_wv_env_call_log_set" ] && WV_CALL_LOG="$_wv_env_call_log"
fi
# _wv_is_user_call_log PATH — PATH is the user's own durable log: the default
# path, or what the user's own config.env (under HOME, whatever WV_CONFIG_DIR
# names) sets. Read in a subshell so nothing it sets leaks into this one.
_wv_is_user_call_log() {
    [ -n "$1" ] || return 1
    [ "$1" = "$HOME/.local/share/weave/wv_calls.jsonl" ] && return 0
    local home_cfg="$HOME/.config/weave/config.env" theirs
    [ -f "$home_cfg" ] || return 1
    # shellcheck disable=SC1090  # path is user config, resolved at runtime
    theirs=$(unset WV_CALL_LOG; . "$home_cfg" >/dev/null 2>&1; printf '%s' "${WV_CALL_LOG-}")
    [ -n "$theirs" ] && [ "$1" = "$theirs" ]
}
if [ "${WV_TEST_SUITE:-}" = "1" ]; then
    if [ -z "$_wv_cfg_from_env" ]; then
        # No chosen config dir: the user's config.env cannot turn the log on,
        # and an inherited user log is not the suite's choice.
        if [ -n "$_wv_env_call_log_set" ] \
            && [ "$_wv_env_call_log" != "$_wv_cfg_call_log" ] \
            && ! _wv_is_user_call_log "$_wv_env_call_log"; then
            WV_CALL_LOG="$_wv_env_call_log"
        else
            unset WV_CALL_LOG
        fi
    elif [ -z "$_wv_cfg_call_log" ] && [ -n "$_wv_env_call_log_set" ] \
        && _wv_is_user_call_log "$_wv_env_call_log"; then
        # A chosen config dir whose config.env sets no log: an inherited user
        # log still does not apply (the parity checker's scratch config, run by
        # a hook that loaded the user's config.env).
        unset WV_CALL_LOG
    fi
fi
unset -f _wv_is_user_call_log
unset _wv_env_file _wv_cfg_from_env _wv_env_call_log_set _wv_env_call_log _wv_cfg_call_log

# Canonical default path for the opt-in session-analysis call log. Shared by the
# `wv analyze sessions` reader and `wv config enable session-analysis` so the
# writer and reader can never imply different locations (finding wv-e754b0 O1a).
WV_CALL_LOG_DEFAULT="${WV_CALL_LOG_DEFAULT:-$HOME/.local/share/weave/wv_calls.jsonl}"

# Canonical default path for the durable suite-run history log (LL2). The tmpfs
# test_results table is current-state-only and wiped by `wv load`; this disk-backed
# append-only JSONL survives wv load + reboot so commit-time friction can be
# measured. Always-on (the writer is `wv test-record`); the PATH is overridable
# via `wv config set WV_SUITE_LOG <path>`. Reader: `wv analyze suites` (LL3).
WV_SUITE_LOG_DEFAULT="${WV_SUITE_LOG_DEFAULT:-$HOME/.local/share/weave/suite_runs.jsonl}"

# wv_session_budget_file <hot-zone> — the one location of the per-session wv
# call tally, written by .claude/hooks/wv-budget-tally.sh and read by wv health
# (wv-76bb48). The hook hardcoded /dev/shm/weave/<hash> while health read the
# hot zone, so under a sandboxed runtime (hot zone /tmp/weave-hotzone-<uid>)
# health never saw the file and scored call discipline 25/25 unearned. Beside
# session-edits.json, the other session counter health reads. WV_BUDGET_DIR
# still overrides the directory for both.
wv_session_budget_file() {
    wv_session_counter_file "${WV_BUDGET_DIR:-$1}" session-budget
}

# wv_session_edits_file <hot-zone> — the edit-discipline tally (hooks write,
# wv health reads), in the hot zone.
wv_session_edits_file() {
    wv_session_counter_file "$1" session-edits
}

# wv_session_counter_file <dir> <base> — <dir>/<base>.<digest16>.json for a
# known session, else <dir>/<base>.json. Two sessions in one checkout share the
# hot zone; one file per counter mixed their tallies and lost updates in
# read-modify-write races (wv-9a867a).
wv_session_counter_file() {
    local sid=""
    declare -F _wv_agent_session_sid >/dev/null && sid=$(_wv_agent_session_sid 2>/dev/null)
    if [ -n "$sid" ]; then
        printf '%s/%s.%s.json\n' "$1" "$2" "$sid"
    else
        printf '%s/%s.json\n' "$1" "$2"
    fi
}

_WV_ENV_OVERRIDE_HOT_ZONE=$(resolve_env_override_hot_zone)
if [ -n "$_WV_ENV_OVERRIDE_HOT_ZONE" ] && ! hot_zone_matches_repo "$_WV_ENV_OVERRIDE_HOT_ZONE" "$REPO_ROOT"; then
    _WV_ENV_OVERRIDE_OWNER=$(read_hot_zone_owner "$_WV_ENV_OVERRIDE_HOT_ZONE")
    [ -z "$_WV_ENV_OVERRIDE_OWNER" ] && [ -n "${WV_PROJECT_DIR:-}" ] && _WV_ENV_OVERRIDE_OWNER="$WV_PROJECT_DIR"

    # Fails closed (wv-5e804e, owner ruling 2026-09-29). This used to drop the
    # override and fall back to this repository's live graph, warning once per
    # shell, so every later call -- a test harness, an MCP server -- wrote the
    # live graph silently while believing it wrote the override. A caller that
    # named a database must get that database or an error, never another one.
    echo "wv: refusing to run: WV_HOT_ZONE/WV_DB names a hot zone owned by ${_WV_ENV_OVERRIDE_OWNER:-another repository}, not $REPO_ROOT" >&2
    echo "    override: $_WV_ENV_OVERRIDE_HOT_ZONE" >&2
    _wv_worktree_main=$(wv_shared_worktree_main "$REPO_ROOT" "${_WV_ENV_OVERRIDE_OWNER:-}")
    if [ -n "$_wv_worktree_main" ]; then
        # A linked worktree of the zone owner's repository (wv-ca1f94): the
        # agent usually exported the main checkout's zone to share its graph.
        echo "    this is a linked worktree of $_wv_worktree_main, and a linked worktree keeps its own" >&2
        echo "    graph (wv-d88fed): a claim in the main checkout does not admit work here. In this" >&2
        echo "    worktree: unset WV_HOT_ZONE WV_DB, then wv load, then wv work <id> (or wv add ... --status=active)" >&2
    else
        echo "    unset WV_HOT_ZONE WV_DB to use this repository's graph, or point them at a hot zone for it" >&2
    fi
    return 1 2>/dev/null || exit 1
fi

# Set up hot zone and database paths
# Per-repo namespace: hash the repo root to isolate each repo's hot zone.
# This prevents multiple repos from sharing a single brain.db on tmpfs.
# Placement is per repository (wv-b831e3): the zone already holding this
# repo's database wins, else the /tmp zone. When more than one holds one,
# resolve_hot_zone explains and fails, and wv refuses below rather than pick;
# an explicit WV_HOT_ZONE or WV_DB names the database and settles it.
_WV_PLACEMENT_CONFLICT=""
_WV_BASE_HOT_ZONE=$(resolve_hot_zone "$REPO_ROOT") || _WV_PLACEMENT_CONFLICT=1
WV_HOT_ZONE="${WV_HOT_ZONE:-$(resolve_repo_hot_zone "$_WV_BASE_HOT_ZONE" "$REPO_ROOT")}"
WV_DB_CUSTOM="${WV_DB:+1}"
WV_DB="${WV_DB:-$(resolve_db "$WV_HOT_ZONE")}"
# WV_PRIMARY_FILE stays an explicit override only: the default is resolved per
# call from this owner's directory (wv-43d6be), after a hook has adopted its
# payload's session id.
WV_PRIMARY_FILE="${WV_PRIMARY_FILE:-}"

# Fails closed before any use (wv-80be32): a hot zone inside a shared-parent
# base another user could have created first is refused, never chmodded.
if ! hot_zone_check "$WV_HOT_ZONE" || { [ -n "$WV_DB_CUSTOM" ] && ! hot_zone_check "${WV_DB%/*}"; }; then
    return 1 2>/dev/null || exit 1
fi
if [ -n "$_WV_PLACEMENT_CONFLICT" ] && [ -z "$_WV_ENV_OVERRIDE_HOT_ZONE" ]; then
    return 1 2>/dev/null || exit 1
fi

# Primary active node helpers
# The "primary" node is the one this owner most recently claimed via `wv work`.
# Stored in this owner's hot-zone directory (resolve_owner_dir), so another
# session's claim never becomes this session's primary (wv-43d6be).
set_primary_node() {
    local id="$1" file
    file=$(resolve_primary_file "$WV_HOT_ZONE") || return 0
    (umask 077 && mkdir -p "${file%/*}") 2>/dev/null || true
    echo "$id" > "$file"
}

get_primary_node() {
    local file
    file=$(resolve_primary_file "$WV_HOT_ZONE") || { echo ""; return 0; }
    [ -f "$file" ] && cat "$file" 2>/dev/null || echo ""
}

clear_primary_node() {
    rm -f "$(resolve_primary_file "$WV_HOT_ZONE")" 2>/dev/null || true
}

# ═══════════════════════════════════════════════════════════════════════════
# Colors
# ═══════════════════════════════════════════════════════════════════════════

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
DIM='\033[2m'
NC='\033[0m'

# NO_COLOR support (https://no-color.org/) + auto-detect non-tty
# Disable colors when: NO_COLOR is set, or stdout is not a terminal (pipes, captures, CI)
if [ -n "${NO_COLOR:-}" ] || [ ! -t 1 ]; then
    RED=''
    GREEN=''
    YELLOW=''
    CYAN=''
    DIM=''
    NC=''
fi

# ═══════════════════════════════════════════════════════════════════════════
# Output mode resolution
# ═══════════════════════════════════════════════════════════════════════════
#
# wv_resolve_mode [--mode=ARG]
#   Resolves the effective output mode for a command. Priority:
#     1. Explicit --mode= flag from caller (ARG, already extracted)
#     2. WV_MODE env var
#     3. Auto-detect: non-tty or WV_AGENT=1 → discover; tty → execute
#   Echoes: bootstrap | discover | execute | full
#
wv_resolve_mode() {
    local explicit="${1:-}"
    if [ -n "$explicit" ]; then
        case "$explicit" in
            bootstrap|discover|execute|full) echo "$explicit"; return ;;
        esac
    fi
    if [ -n "${WV_MODE:-}" ]; then
        case "$WV_MODE" in
            bootstrap|discover|execute|full) echo "$WV_MODE"; return ;;
        esac
    fi
    if [ ! -t 1 ] || [ "${WV_AGENT:-0}" = "1" ]; then
        echo "discover"
    else
        echo "execute"
    fi
}

# ═══════════════════════════════════════════════════════════════════════════
# RAM Detection and Pragma Selection
# ═══════════════════════════════════════════════════════════════════════════

detect_ram_mb() {
    local ram_kb=0
    if [ -f /proc/meminfo ]; then
        ram_kb=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
    elif command -v sysctl >/dev/null 2>&1; then
        ram_kb=$(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1024 ))
    fi
    echo $(( ram_kb / 1024 ))
}

select_pragmas() {
    local ram_mb
    ram_mb=$(detect_ram_mb)
    if [ -n "${WV_CACHE_SIZE:-}" ] && [ -n "${WV_MMAP_SIZE:-}" ]; then
        echo "$WV_CACHE_SIZE" "$WV_MMAP_SIZE"
    elif is_container; then
        echo "-10000" "134217728"
    elif [ "$ram_mb" -lt 2048 ] 2>/dev/null; then
        echo "-25000" "268435456"
    elif [ "$ram_mb" -lt 8192 ] 2>/dev/null; then
        echo "-50000" "1073741824"
    else
        echo "-100000" "2147483648"
    fi
}

validate_hot_size() {
    local avail_kb
    avail_kb=$(df -k "$WV_HOT_ZONE" 2>/dev/null | awk 'NR==2 {print $4}')
    [ -z "$avail_kb" ] && return
    local avail_mb=$(( avail_kb / 1024 ))
    if [ "$WV_HOT_SIZE" -gt "$avail_mb" ] 2>/dev/null; then
        WV_HOT_SIZE=$(( avail_mb * 80 / 100 ))
        echo "wv: hot zone limited to ${WV_HOT_SIZE}MB (80% of ${avail_mb}MB available)" >&2
    fi
}

# wv_set_phase — write this owner's .session_phase with enum validation.
# Usage: wv_set_phase <phase> [<hot-zone-dir>]
# Valid values sourced from PHASE_VALUES in wv-validate.sh. The file lives in
# the owner's directory (resolve_phase_file), never the shared hot-zone root
# (wv-43d6be). No-op if the hot zone is unavailable or the session cannot be
# verified.
wv_set_phase() {
    local phase="$1"
    local hot_zone="${2:-${WV_HOT_ZONE:-}}"
    local valid=false
    local p
    for p in ${PHASE_VALUES:-discover execute closing}; do
        [ "$phase" = "$p" ] && valid=true && break
    done
    if [ "$valid" = false ]; then
        echo "wv_set_phase: invalid phase '$phase' (valid: ${PHASE_VALUES:-discover execute closing})" >&2
        return 1
    fi
    [ -n "$hot_zone" ] || return 0
    local file
    file=$(resolve_phase_file "$hot_zone") || return 0
    (umask 077 && mkdir -p "${file%/*}") 2>/dev/null || true
    printf '%s' "$phase" > "$file" 2>/dev/null || true
}

# _wv_source_drift — fast, cross-agent check: do edited Weave source files
# (scripts/cmd|lib/*.sh, scripts/wv, .claude/hooks/*.sh)
# differ from their installed copies? Echoes the drifted basenames (space-
# separated) and returns 0 if any drift, 1 if clean. No-op (returns 1) in
# consumer repos that have no source-path pointer. Because every harness —
# Claude, Codex, Copilot — drives the same `wv` CLI and git pre-commit, this one
# helper backs both bootstrap and pre-commit drift advisories. Installation
# is explicit; source admission does not update the installed runtime.
# _wv_drift_cmp <source> <installed> — append the source's name to the caller's
# $drifted when the installed copy is missing or differs. One comparison for
# every source class (ultrareview #4574), so a change to how drift is judged
# cannot reach some classes and not others.
_wv_drift_cmp() {
    # cmp, not two md5sum digests: with no md5sum both were empty, so every
    # stale copy read as current (wv-7d7d41).
    [ -f "$2" ] && cmp -s -- "$1" "$2" || drifted="${drifted:+$drifted }$(basename "$1")"
}

_wv_source_drift() {
    local cfg="${WV_CONFIG_DIR:-$HOME/.config/weave}"
    local src_pointer="$cfg/source-path"
    [ -f "$src_pointer" ] || return 1
    local src_root; src_root=$(cat "$src_pointer" 2>/dev/null || echo "")
    [ -n "$src_root" ] && [ -d "$src_root/scripts" ] || return 1
    local lib_dir="$HOME/.local/lib/weave"
    local drifted="" src rel installed
    for src in "$src_root/scripts/cmd/"*.sh "$src_root/scripts/lib/"*.sh \
               "$src_root/scripts/wv"; do
        [ -f "$src" ] || continue
        rel="${src#"$src_root/scripts/"}"
        installed="$lib_dir/$rel"
        [ "$rel" = "wv" ] && installed="$HOME/.local/bin/wv"
        _wv_drift_cmp "$src" "$installed"
    done
    # Git-hook sources (wv-ff2fb1): install.sh copies them to $lib_dir/hooks/,
    # which wv init-repo --update vendors to consumers. Report edited hooks
    # too, so source drift stays visible until an explicit installation.
    for src in "$src_root/scripts/hooks/"*-weave.sh; do
        [ -f "$src" ] || continue
        installed="$lib_dir/hooks/$(basename "$src")"
        _wv_drift_cmp "$src" "$installed"
    done
    if [ -d "$src_root/.claude/hooks" ] && [ -d "$cfg/hooks" ]; then
        for src in "$src_root/.claude/hooks/"*.sh; do
            [ -f "$src" ] || continue
            installed="$cfg/hooks/$(basename "$src")"
            _wv_drift_cmp "$src" "$installed"
        done
    fi
    [ -n "$drifted" ] || return 1
    printf '%s' "$drifted"
    return 0
}

# _wv_concurrent_session — detection-only guard for wv-fa566a: a second LIVE
# agent process (not a crash artifact) with a cwd inside this repo can edit or
# delete working-tree files with no coordination — scripts/lib/wv-config.sh
# was deleted twice in one session this way. .weave/ has cross-agent guards
# (wv-b767ff, wv-66aa00); the working tree itself does not.
#
# Two backends, one rule (wv-655a34): /proc where the kernel has it (Linux),
# else ps and lsof, which macOS ships. Before, a host without /proc returned
# 1, so a second session there read a live peer's per-session sentinel and
# heartbeat as an ended session's and removed them (the hazard wv-9a867a fixed
# on Linux). Only when neither is available does it return 1 unjudged.
# Excludes the caller's own ancestor chain: the harness driving THIS session
# (e.g. a "claude" process) commonly has its own cwd inside the repo too, and
# is not a distinct concurrent session.
# Echoes a description and returns 0 on a hit; returns 1 when clean, 2 on a
# bad WV_TEST_PEER_SCAN.
_wv_concurrent_session() {
    local repo_root="$1" backend
    [ -n "$repo_root" ] || return 1
    backend=$(_wv_peer_scan_backend) || return 2
    case "$backend" in
        proc) _wv_concurrent_session_proc "$repo_root" ;;
        ps) _wv_concurrent_session_ps "$repo_root" ;;
        *) return 1 ;;
    esac
}

# _wv_peer_scan_backend — proc, ps or none. Under WV_TEST_MODE=1,
# WV_TEST_PEER_SCAN=ps forces the ps/lsof backend so Linux runs it too; set
# without WV_TEST_MODE=1 it is ignored with a warning, and any other value is
# an error (tests/wv-test-hooks.registry).
_wv_peer_scan_backend() {
    local forced="${WV_TEST_PEER_SCAN:-}"
    if [ -n "$forced" ]; then
        if [ "${WV_TEST_MODE:-}" != "1" ]; then
            echo "wv: WV_TEST_PEER_SCAN is set but WV_TEST_MODE=1 is not; ignoring it." >&2
            forced=""
        elif [ "$forced" != ps ]; then
            echo "wv: WV_TEST_PEER_SCAN='$forced' is not a backend (only 'ps')." >&2
            return 1
        fi
    fi
    if [ "$forced" = ps ]; then
        echo ps
    elif [ -d /proc/self ]; then
        echo proc
    elif command -v ps >/dev/null 2>&1 && command -v lsof >/dev/null 2>&1; then
        echo ps
    else
        echo none
    fi
}

# _wv_concurrent_session_ps <repo-root> — the scan through ps and lsof: the
# same agent-name rule on each process's command basename (macOS ps prints
# the executable path), then, for a match only, its cwd from lsof, compared
# canonically (macOS /tmp and /var are links into /private).
_wv_concurrent_session_ps() {
    local repo_root self_chain=" $$ " walk="$$" hops=0 pid comm name cwd cmd
    repo_root=$(cd "$1" 2>/dev/null && pwd -P) || repo_root="$1"
    while [ -n "$walk" ] && [ "$walk" != "1" ] && [ "$hops" -lt 30 ]; do
        walk=$(ps -o ppid= -p "$walk" 2>/dev/null) || walk=""
        walk="${walk//[[:space:]]/}"
        [ -n "$walk" ] || break
        self_chain="${self_chain}${walk} "
        hops=$((hops + 1))
    done
    while read -r pid comm; do
        [ -n "$pid" ] || continue
        case "$self_chain" in *" $pid "*) continue ;; esac
        name="${comm##*/}"
        _wv_agent_name_match "$name" || continue
        cwd=$(lsof -a -d cwd -Fn -p "$pid" 2>/dev/null | sed -n 's/^n//p' | head -n 1)
        [ -n "$cwd" ] || continue
        cwd=$(cd "$cwd" 2>/dev/null && pwd -P) || continue
        case "$cwd" in "$repo_root") ;; "$repo_root"/*) ;; *) continue ;; esac
        cmd=$(ps -o args= -p "$pid" 2>/dev/null) || cmd=""
        [ -n "$cmd" ] || cmd="$name"
        printf 'another live agent process (pid %s: %s) has a working directory inside this repo -- working-tree edits are not coordinated between sessions (wv-fa566a)' \
            "$pid" "$(printf '%s' "$cmd" | cut -c1-80)"
        return 0
    done < <(ps -A -o pid= -o comm= 2>/dev/null)
    _wv_copilot_lock_peer "$1" "$self_chain"
}

# _wv_concurrent_session_proc <repo-root> — the /proc scan (Linux).
_wv_concurrent_session_proc() {
    local repo_root="$1"
    local self_chain=" $$ " walk="$$" hops=0
    while [ -n "$walk" ] && [ "$walk" != "1" ] && [ "$hops" -lt 30 ]; do
        walk=$(awk -F: '/^PPid:/{gsub(/[ \t]/,"",$2); print $2}' "/proc/$walk/status" 2>/dev/null)
        [ -n "$walk" ] || break
        self_chain="${self_chain}${walk} "
        hops=$((hops + 1))
    done

    local pid_dir pid cwd comm exe cmd
    for pid_dir in /proc/[0-9]*; do
        pid="${pid_dir#/proc/}"
        case "$self_chain" in *" $pid "*) continue ;; esac
        cwd=$(readlink -f "$pid_dir/cwd" 2>/dev/null) || continue
        [ -n "$cwd" ] || continue
        case "$cwd" in "$repo_root") ;; "$repo_root"/*) ;; *) continue ;; esac
        # Match the executable name (/proc/<pid>/comm), not the full cmdline —
        # cmdline substring matching false-positived on an unrelated bash
        # subprocess whose command referenced a ~/.claude/ path. comm is
        # truncated to 15 chars by the kernel, so match by prefix. pi and amp
        # are exact (observed comm `pi`, `amp` on 2026-11-04, wv-d09cee): a
        # prefix would catch pip/ping/pipewire. AI_AGENT in environ is not a
        # usable signal — the harness sets it for its children, not itself,
        # so it would flag this session's own non-ancestor shells.
        # The exe basename is checked too (wv-e6a111): Copilot CLI's main
        # thread renames itself, so its comm is `MainThread` while its exe is
        # .../copilot. readlink fails on other users' processes; comm alone
        # then decides, as before.
        comm=$(cat "$pid_dir/comm" 2>/dev/null)
        exe=$(_wv_exe_basename "$pid")
        _wv_agent_name_match "$comm" || _wv_agent_name_match "$exe" || continue
        cmd=$(tr '\0' ' ' < "$pid_dir/cmdline" 2>/dev/null)
        [ -n "$cmd" ] || cmd="${comm:-$exe}"
        printf 'another live agent process (pid %s: %s) has a working directory inside this repo -- working-tree edits are not coordinated between sessions (wv-fa566a)' \
            "$pid" "$(printf '%s' "$cmd" | cut -c1-80)"
        return 0
    done
    _wv_copilot_lock_peer "$repo_root" "$self_chain"
}

# _wv_agent_name_match <name> — the agent-name rule applied to both comm and
# the exe basename. comm is truncated to 15 chars, so codex/claude/copilot
# match by prefix; pi and amp stay exact so pip, ping and pipewire never match.
_wv_agent_name_match() {
    case "$1" in
        codex*|claude*|copilot*|pi|amp) return 0 ;;
    esac
    return 1
}

# _wv_exe_basename <pid> — basename of /proc/<pid>/exe, without the
# " (deleted)" suffix the kernel adds after the binary is replaced (an
# auto-update); empty when unreadable.
_wv_exe_basename() {
    local exe
    exe=$(readlink "/proc/$1/exe" 2>/dev/null) || return 0
    exe="${exe% (deleted)}"
    printf '%s' "${exe##*/}"
}

# _wv_copilot_lock_peer <repo_root> <self_chain> — wv-e6a111: VS Code's
# Copilot runtime works in a repo while its process cwd stays $HOME (the
# workspace arrives over --stdio), so the cwd scan above cannot see it.
# Both Copilot clients (CLI: client_name github/cli; VS Code:
# vscode-agent-host) hold ${COPILOT_HOME:-~/.copilot}/session-state/<id>/
# inuse.<pid>.lock next to a workspace.yaml naming cwd and git_root.
# A lock counts only when its pid is live, outside the caller's chain, runs
# an exe named copilot or copilot-runtime, started no later than the lock was
# written (a dead session's lock whose pid was reused is older than the new
# process), and its workspace.yaml names this repo. Locks without a
# workspace.yaml are skipped. Echoes a description and returns 0 on a hit.
_wv_copilot_lock_peer() {
    local repo_root="$1" self_chain="$2"
    local state_dir="${COPILOT_HOME:-$HOME/.copilot}/session-state"
    [ -d "$state_dir" ] || return 1
    local btime tck lock pid start ws client line val
    btime=$(awk '/^btime /{print $2}' /proc/stat 2>/dev/null)
    tck=$(getconf CLK_TCK 2>/dev/null)
    [ -n "$btime" ] && [ -n "$tck" ] || return 1
    for lock in "$state_dir"/*/inuse.*.lock; do
        [ -f "$lock" ] || continue
        pid="${lock##*/inuse.}"
        pid="${pid%.lock}"
        case "$pid" in '' | *[!0-9]*) continue ;; esac
        case "$self_chain" in *" $pid "*) continue ;; esac
        case "$(_wv_exe_basename "$pid")" in copilot | copilot-runtime) ;; *) continue ;; esac
        # Field 22 of /proc/<pid>/stat is the start time in ticks since boot.
        # comm (field 2) may hold spaces or ')', so strip through the last
        # ") "; field 22 is then the 20th.
        start=$(sed 's/^.*) //' "/proc/$pid/stat" 2>/dev/null | awk '{print $20}')
        [ -n "$start" ] || continue
        [ "$(wv_stat mtime "$lock" || echo 0)" -ge $((btime + start / tck)) ] || continue
        ws="${lock%/*}/workspace.yaml"
        [ -f "$ws" ] || continue
        client=$(awk -F': *' '$1=="client_name"{print $2; exit}' "$ws" 2>/dev/null)
        while IFS= read -r line; do
            case "$line" in cwd:* | git_root:*) ;; *) continue ;; esac
            val="${line#*:}"
            val="${val# }"
            val="${val#\"}"
            val="${val%\"}"
            case "$val" in
                "$repo_root" | "$repo_root"/*)
                    printf 'another live agent session (pid %s: %s, Copilot session %s) is working inside this repo -- working-tree edits are not coordinated between sessions (wv-fa566a)' \
                        "$pid" "${client:-copilot}" "$(basename "${lock%/*}")"
                    return 0
                    ;;
            esac
        done <"$ws"
    done
    return 1
}
