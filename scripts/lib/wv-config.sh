#!/bin/bash
# wv-config.sh — Configuration, hot zone detection, colors
#
# Sourced by: wv entry point
# Dependencies: None

# ═══════════════════════════════════════════════════════════════════════════
# Version and Paths
# ═══════════════════════════════════════════════════════════════════════════

# Read version from VERSION file (next to this script)
_WV_LIB_DIR="${WV_LIB_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
if [ -f "$_WV_LIB_DIR/lib/VERSION" ]; then
    WV_VERSION=$(cat "$_WV_LIB_DIR/lib/VERSION" | tr -d '[:space:]')
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
WV_CONFIG_DIR="${WV_CONFIG_DIR:-$HOME/.config/weave}"
_wv_env_file="$WV_CONFIG_DIR/config.env"
if [ -f "$_wv_env_file" ]; then
    set -a
    # shellcheck disable=SC1090  # path is user config, resolved at runtime
    . "$_wv_env_file" 2>/dev/null || true
    set +a
fi
unset _wv_env_file

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
# hot zone, so under a sandboxed runtime (hot zone /tmp/weave-codex-<uid>)
# health never saw the file and scored call discipline 25/25 unearned. Beside
# session-edits.json, the other session counter health reads. WV_BUDGET_DIR
# still overrides the directory for both.
wv_session_budget_file() {
    printf '%s/session-budget.json\n' "${WV_BUDGET_DIR:-$1}"
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
    echo "    unset WV_HOT_ZONE WV_DB to use this repository's graph, or point them at a hot zone for it" >&2
    return 1 2>/dev/null || exit 1
fi

# Set up hot zone and database paths
# Per-repo namespace: hash the repo root to isolate each repo's hot zone.
# This prevents multiple repos from sharing a single brain.db on tmpfs.
_WV_BASE_HOT_ZONE=$(resolve_hot_zone)
WV_HOT_ZONE="${WV_HOT_ZONE:-$(resolve_repo_hot_zone "$_WV_BASE_HOT_ZONE" "$REPO_ROOT")}"
WV_DB_CUSTOM="${WV_DB:+1}"
WV_DB="${WV_DB:-$(resolve_db "$WV_HOT_ZONE")}"
WV_PRIMARY_FILE="${WV_PRIMARY_FILE:-$(resolve_primary_file "$WV_HOT_ZONE")}"

# Primary active node helpers
# The "primary" node is the most recently claimed via `wv work`.
# Stored in $WV_HOT_ZONE/primary (tmpfs, session-scoped).
set_primary_node() {
    local id="$1"
    echo "$id" > "$WV_PRIMARY_FILE"
}

get_primary_node() {
    [ -f "$WV_PRIMARY_FILE" ] && cat "$WV_PRIMARY_FILE" 2>/dev/null || echo ""
}

clear_primary_node() {
    rm -f "$WV_PRIMARY_FILE" 2>/dev/null || true
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

# wv_set_phase — write .session_phase atomically with enum validation.
# Usage: wv_set_phase <phase> [<hot-zone-dir>]
# Valid values sourced from PHASE_VALUES in wv-validate.sh.
# Falls back to no-op if hot zone unavailable.
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
    [ -n "$hot_zone" ] && printf '%s' "$phase" > "${hot_zone}/.session_phase" 2>/dev/null || true
}

# _wv_source_drift — fast, cross-agent check: do edited Weave source files
# (scripts/cmd|lib/*.sh, scripts/wv, .claude/hooks/*.sh)
# differ from their installed copies? Echoes the drifted basenames (space-
# separated) and returns 0 if any drift, 1 if clean. No-op (returns 1) in
# consumer repos that have no source-path pointer. Because every harness —
# Claude, Codex, Copilot — drives the same `wv` CLI and git pre-commit, this one
# helper backs both the bootstrap drift advisory and the pre-commit self-heal,
# so the "run ./install.sh after editing source" signal is agent-agnostic.
# _wv_drift_cmp <source> <installed> — append the source's name to the caller's
# $drifted when the installed copy is missing or differs. One comparison for
# every source class (ultrareview #4574), so a change to how drift is judged
# cannot reach some classes and not others.
_wv_drift_cmp() {
    local sm im
    sm=$(md5sum "$1" 2>/dev/null | awk '{print $1}')
    im=$(md5sum "$2" 2>/dev/null | awk '{print $1}')
    [ -f "$2" ] && [ "$sm" = "$im" ] || drifted="${drifted:+$drifted }$(basename "$1")"
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
    # which wv init-repo --update vendors to consumers. Without this an edited
    # hook never triggered the pre-commit self-heal, and consumers received the
    # stale copy until someone ran ./install.sh by hand.
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
# Linux-only (/proc); silently no-ops elsewhere (return 1) since this is
# advisory, not a blocking gate. Excludes the caller's own ancestor chain —
# the harness driving THIS session (e.g. a "claude" process) commonly has its
# own cwd inside the repo too, and is not a distinct concurrent session.
# Echoes a description and returns 0 on a hit; returns 1 when clean.
_wv_concurrent_session() {
    local repo_root="$1"
    [ -d /proc ] || return 1
    [ -n "$repo_root" ] || return 1

    local self_chain=" $$ " walk="$$" hops=0
    while [ -n "$walk" ] && [ "$walk" != "1" ] && [ "$hops" -lt 30 ]; do
        walk=$(awk -F: '/^PPid:/{gsub(/[ \t]/,"",$2); print $2}' "/proc/$walk/status" 2>/dev/null)
        [ -n "$walk" ] || break
        self_chain="${self_chain}${walk} "
        hops=$((hops + 1))
    done

    local pid_dir pid cwd comm cmd
    for pid_dir in /proc/[0-9]*; do
        pid="${pid_dir#/proc/}"
        case "$self_chain" in *" $pid "*) continue ;; esac
        cwd=$(readlink -f "$pid_dir/cwd" 2>/dev/null) || continue
        [ -n "$cwd" ] || continue
        case "$cwd" in "$repo_root") ;; "$repo_root"/*) ;; *) continue ;; esac
        # Match the executable name (/proc/<pid>/comm), not the full cmdline —
        # cmdline substring matching false-positived on an unrelated bash
        # subprocess whose command referenced a ~/.claude/ path. comm is
        # truncated to 15 chars by the kernel, so match by prefix.
        comm=$(cat "$pid_dir/comm" 2>/dev/null)
        [ -n "$comm" ] || continue
        case "$comm" in
            codex*|claude*|copilot*) ;;
            *) continue ;;
        esac
        cmd=$(tr '\0' ' ' < "$pid_dir/cmdline" 2>/dev/null)
        [ -n "$cmd" ] || cmd="$comm"
        printf 'another live agent process (pid %s: %s) has a working directory inside this repo -- working-tree edits are not coordinated between sessions (wv-fa566a)' \
            "$pid" "$(printf '%s' "$cmd" | cut -c1-80)"
        return 0
    done
    return 1
}
