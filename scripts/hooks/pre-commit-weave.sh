#!/usr/bin/env bash
# Weave pre-commit hook: require active node before committing code changes
#
# Enforces the "track ALL work in Weave" rule from AGENTS.md.
# Allows .weave/-only commits and WIP checkpoints through.
#
# Skip with: git commit --no-verify (or WV_SKIP_PRECOMMIT=1)

hook_progress() {
    [ "${WV_HOOK_PROGRESS:-1}" = "0" ] && return 0
    printf '%s\n' "Weave pre-commit: $1" >&2
}

# hook_duration_ms <start_nanos> — wall-clock milliseconds elapsed since a
# `date +%s%N` timestamp (LL1). Returns 0 when nanosecond `date` is unavailable
# (literal "N" output) or the start is the 0 sentinel, so a ledger row never
# carries a bogus negative/garbage cost.
hook_duration_ms() {
    local _t0="$1" _t1 _d
    _t1=$(date +%s%N 2>/dev/null || echo 0)
    case "$_t0" in ''|*[!0-9]*) echo 0; return 0 ;; esac
    case "$_t1" in ''|*[!0-9]*) echo 0; return 0 ;; esac
    [ "$_t0" = "0" ] && { echo 0; return 0; }
    _d=$(( (_t1 - _t0) / 1000000 ))
    [ "$_d" -lt 0 ] && _d=0
    echo "$_d"
}

run_hook_suite() {
    _pc_suite="$1"
    _pc_cost="${2:-?}"
    # Heuristic may map to a suite that doesn't exist yet — skip rather than fail.
    [ -f "$REPO_ROOT/$_pc_suite" ] || return 0
    hook_progress "running $_pc_suite (~${_pc_cost}s)..."
    _pc_t0=$(date +%s%N 2>/dev/null || echo 0)
    GIT_CONFIG_COUNT=1 \
        GIT_CONFIG_KEY_0=core.hooksPath \
        GIT_CONFIG_VALUE_0=/dev/null \
        WV_CALL_SOURCE=test \
        bash "$REPO_ROOT/$_pc_suite" </dev/null >/dev/null 2>&1
    _pc_rc=$?
    _pc_dur=$(hook_duration_ms "$_pc_t0")
    # Record the outcome in the verification ledger (P6a) with its wall-clock cost
    # (LL1). Best-effort — a recording failure must never block the commit. Keyed on
    # the staged files' fingerprint.
    "$WV" test-record "$_pc_suite" --files="${_pc_files_csv:-}" --exit="$_pc_rc" --duration="$_pc_dur" >/dev/null 2>&1 || true
    if [ "$_pc_rc" -ne 0 ]; then
        echo "" >&2
        echo "✗ $_pc_suite failed — run manually to see details:" >&2
        echo "  bash $_pc_suite" >&2
        echo "" >&2
        exit 1
    fi
}

# Prevent recursive hook execution when this hook launches test suites that
# perform their own git commits.
[ "${WV_PRECOMMIT_RUNNING:-0}" = "1" ] && exit 0

# Allow explicit bypass
[ "${WV_SKIP_PRECOMMIT:-0}" = "1" ] && exit 0

# Find wv
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || exit 0)
WV="$(command -v wv 2>/dev/null || echo "$REPO_ROOT/scripts/wv")"
[ ! -x "$WV" ] && exit 0

# Phase helper + enum (best effort). Resolve the lib dir like the wv binary does:
# repo-local scripts/lib/ (source checkout) first, then the installed location.
# Consumer repos run the installed binary and have NO scripts/lib/, so without
# this fallback wv_set_phase + validators silently vanish and the hook degrades
# to its weakest path — wrong phase resolution, no phase reset (finding wv-e754b0 O3).
_PC_LIB_DIR=""
for _pc_cand in "$REPO_ROOT/scripts/lib" "$HOME/.local/lib/weave/lib"; do
    if [ -f "$_pc_cand/wv-config.sh" ]; then _PC_LIB_DIR="$_pc_cand"; break; fi
done
if [ -n "$_PC_LIB_DIR" ]; then
    source "$_PC_LIB_DIR/wv-validate.sh" 2>/dev/null || true
    source "$_PC_LIB_DIR/wv-config.sh" 2>/dev/null || true
fi

# Check what's being committed — if only .weave/ files, always allow
STAGED_FILES=$(git diff --cached --name-only 2>/dev/null)
[ -z "$STAGED_FILES" ] && exit 0

NON_WEAVE_FILES=$(echo "$STAGED_FILES" | grep -v '^\.weave/' || true)
[ -z "$NON_WEAVE_FILES" ] && exit 0

# Allow auto-checkpoint WIP commits (contain [skip ci] in message)
# The commit message file isn't available in pre-commit, so check env
# Auto-checkpoint sets WV_AUTO_CHECKPOINT_ACTIVE=1
[ "${WV_AUTO_CHECKPOINT_ACTIVE:-0}" = "1" ] && exit 0

# Allow formatting/style-only commits (whitespace-only diff)
if [ "${WV_STYLE_COMMIT:-0}" = "1" ]; then
    exit 0
fi
# If staged diff is whitespace-only, allow without active node
WS_DIFF=$(git diff --cached -w --stat 2>/dev/null)
FULL_DIFF=$(git diff --cached --stat 2>/dev/null)
if [ -z "$WS_DIFF" ] && [ -n "$FULL_DIFF" ]; then
    echo "ℹ Whitespace-only change — allowing without active node" >&2
    exit 0
fi

# ── Self-heal install drift (cross-agent) ──
# Editing weave source (scripts/*.sh, .claude/hooks/*.sh) without reinstalling
# leaves the installed copies stale, which the drift gate only catches ~3min into
# the test suite. Reinstall up front so no harness — Claude, Codex, Copilot —
# eats that late failure. Only acts in the dev repo (install.sh present).
if command -v _wv_source_drift >/dev/null 2>&1; then
    if _pc_drift=$(_wv_source_drift); then
        _pc_src=$(cat "${WV_CONFIG_DIR:-$HOME/.config/weave}/source-path" 2>/dev/null || echo "")
        if [ -n "$_pc_src" ] && [ -x "$_pc_src/install.sh" ]; then
            echo "Weave pre-commit: install drift ($_pc_drift) — self-healing via ./install.sh..." >&2
            # Self-heal must install to the REAL machine location regardless of
            # who/what triggered this hook. A test harness's exported isolation
            # vars (e.g. tests/test-hooks.sh sets WV_LIB_DIR=<repo>/scripts to
            # sandbox its own fixtures) leak into this subshell and previously
            # redirected the MCP build into a stray, untracked scripts/mcp/ tree
            # instead of ~/.local/lib/weave/mcp (found via wv-fa566a follow-up).
            if ( unset WV_LIB_DIR WV_CONFIG_DIR WV_HOT_ZONE WV_DB WV_PROJECT_DIR; cd "$_pc_src" && ./install.sh ) >/dev/null 2>&1; then
                echo "Weave pre-commit: install drift healed." >&2
            else
                echo "Weave pre-commit: ./install.sh failed — run it manually before committing." >&2
            fi
        fi
    fi
fi

# Run ruff linter on staged Python files (added/modified only — skip deletions)
STAGED_PY_FILES=$(git diff --cached --name-only --diff-filter=AM 2>/dev/null | grep '\.py$' | grep -v '^\.weave/' || true)
if [ -n "$STAGED_PY_FILES" ]; then
    if command -v ruff > /dev/null 2>&1; then
        hook_progress "running ruff on staged Python files..."
        # shellcheck disable=SC2086
        RUFF_OUT=$(ruff check $STAGED_PY_FILES 2>&1 || true)
        if [ -n "$RUFF_OUT" ] && [ "$RUFF_OUT" != "All checks passed!" ]; then
            echo "" >&2
            echo "✗ ruff lint errors in staged files:" >&2
            echo "$RUFF_OUT" >&2
            echo "" >&2
            echo "  Fix with: ruff check --fix <file>  (then re-stage)" >&2
            echo "" >&2
            exit 1
        fi
    fi

    if [ -f "$REPO_ROOT/.venv/bin/python3" ]; then
        PYTHON3="$REPO_ROOT/.venv/bin/python3"
    else
        PYTHON3=$(command -v python3 2>/dev/null || echo "")
    fi
    if [ -n "$PYTHON3" ] && "$PYTHON3" -c "import pytest" >/dev/null 2>&1; then
        _pc_pytest_dirs=""
        for _pc_dir in "$REPO_ROOT/tests/weave_quality" "$REPO_ROOT/tests/weave_indexer"; do
            [ -d "$_pc_dir" ] && _pc_pytest_dirs="${_pc_pytest_dirs}${_pc_pytest_dirs:+ }$_pc_dir"
        done
        if [ -n "$_pc_pytest_dirs" ]; then
            hook_progress "running focused pytest checks for staged Python changes..."
            # shellcheck disable=SC2086
            if ! "$PYTHON3" -m pytest $_pc_pytest_dirs -q --tb=short 2>&1; then
                echo "" >&2
                echo "✗ pytest tests failed — fix before committing." >&2
                exit 1
            fi
        fi
    fi
fi

# Run fast shell workflow suites determined by wv impact --suites.
# Mapping is driven by .weave/test-map.conf + naming-convention heuristics.
# tests/run-all.sh is a meta-runner — skip it.
_pc_files_csv=$(printf '%s\n' "$NON_WEAVE_FILES" | paste -sd ',' -)
if [ -n "$_pc_files_csv" ]; then
    _pc_suites_json=$("$WV" impact --suites --files="$_pc_files_csv" 2>/dev/null || echo '[]')
    _pc_suite_count=$(printf '%s' "$_pc_suites_json" | jq 'length' 2>/dev/null || echo 0)
    if [ "${_pc_suite_count:-0}" -gt 0 ]; then
        _pc_selected=$(printf '%s' "$_pc_suites_json" | jq -r '[.[].name] | join(", ")' 2>/dev/null || echo "")
        _pc_selected_cost=$(printf '%s' "$_pc_suites_json" | jq '[.[].last_cost_s] | add // 0' 2>/dev/null || echo 0)
        hook_progress "impact-selected shell suites: $_pc_selected (~${_pc_selected_cost}s)"
        while IFS=$'\t' read -r _pc_suite _pc_cost; do
            [ "$_pc_suite" = "tests/run-all.sh" ] && continue
            run_hook_suite "$_pc_suite" "$_pc_cost"
        done < <(printf '%s' "$_pc_suites_json" | jq -r '.[] | [.name, (.last_cost_s|tostring)] | join("\t")' 2>/dev/null)
    else
        # No suite matched any staged source file — the impact gate is inert for
        # this commit. Surface it so silent test-map rot becomes visible instead
        # of passing as if it were gated (add a glob/prefix or [default] entry to
        # .weave/test-map.conf, or run wv test-config to scaffold one).
        _pc_unmapped_count=$(printf '%s\n' "$NON_WEAVE_FILES" | grep -c . 2>/dev/null || echo 0)
        echo "⚠ impact gate inert: $_pc_unmapped_count staged file(s) matched no .weave/test-map.conf entry — no suite ran." >&2
        echo "  Add a glob/prefix/[default] entry (e.g. 'src/ = tests/...') so the gate covers them." >&2
    fi
fi

# Phase-aware enforcement: allow commits in discover and closing phases.
# discover = exploring before claiming; closing = recording just-closed work.
# execute  = substantive work in progress (enforce active node).
# closing is bounded: after one commit (the wv-sync .weave/ commit), reset to
# discover so subsequent work requires a node claim before the next commit.
_PC_REPO_HASH=$(echo "$REPO_ROOT" | md5sum | cut -c1-8)
_PC_HOT_ZONE="${WV_HOT_ZONE:-/dev/shm/weave/${_PC_REPO_HASH}}"
_PC_PHASE=$(cat "${_PC_HOT_ZONE}/.session_phase" 2>/dev/null || echo "execute")

if [ "$_PC_PHASE" = "closing" ]; then
    wv_set_phase "discover" "$_PC_HOT_ZONE" || true
    exit 0
fi

# Check for active Weave nodes (execute phase only)
hook_progress "checking for an active Weave node..."
ACTIVE_COUNT=$("$WV" list --status=active --json 2>/dev/null | jq 'length' 2>/dev/null || echo "0")

if [ "$ACTIVE_COUNT" = "0" ] || [ -z "$ACTIVE_COUNT" ]; then
    cat >&2 << 'EOF'

╔══════════════════════════════════════════════════════════════╗
║  ⚠  No active Weave node — commit blocked                    ║
║                                                              ║
║  Every code change must be tracked. Either:                  ║
║    wv work <id>         # claim an existing task             ║
║    wv add "..." --gh    # create + track new work            ║
║                                                              ║
║  Then retry your commit.                                     ║
║                                                              ║
║  Bypass: git commit --no-verify                              ║
║          WV_SKIP_PRECOMMIT=1 git commit                      ║
╚══════════════════════════════════════════════════════════════╝

EOF
    exit 1
fi

exit 0
