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

run_hook_suite() {
    _pc_suite="$1"
    _pc_cost="${2:-?}"
    # Heuristic may map to a suite that doesn't exist yet — skip rather than fail.
    [ -f "$REPO_ROOT/$_pc_suite" ] || return 0
    hook_progress "running $_pc_suite (~${_pc_cost}s)..."
    if ! GIT_CONFIG_COUNT=1 \
        GIT_CONFIG_KEY_0=core.hooksPath \
        GIT_CONFIG_VALUE_0=/dev/null \
        bash "$REPO_ROOT/$_pc_suite" </dev/null >/dev/null 2>&1; then
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

# Phase helper + enum (best effort). If unavailable, fallback writes below still work.
source "$REPO_ROOT/scripts/lib/wv-validate.sh" 2>/dev/null || true
source "$REPO_ROOT/scripts/lib/wv-config.sh" 2>/dev/null || true

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
        hook_progress "running focused pytest checks for staged Python changes..."
        if ! "$PYTHON3" -m pytest "$REPO_ROOT/tests/weave_quality" "$REPO_ROOT/tests/weave_indexer" -q --tb=short 2>&1; then
            echo "" >&2
            echo "✗ pytest tests failed — fix before committing." >&2
            exit 1
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
