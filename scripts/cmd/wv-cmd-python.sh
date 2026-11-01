#!/bin/bash
# wv-cmd-python.sh — the Python interpreter and module-path helpers the Python-backed commands share
#
# Commands: (helpers)
# Sourced by: wv entry point (autoloaded on first use)
# Dependencies: wv-resolve-runtime.sh
#
# Moved unchanged from wv-cmd-ops.sh (wv-c153c4): the commands that use these
# no longer load wv-cmd-ops.sh, so a change to doctor or bootstrap code no
# longer routes to every suite that runs them.

_bootstrap_python_command() {
    local repo_root="${REPO_ROOT:-}"

    # Resolve an existing interpreter only. Invoking a package manager here made
    # read-only agent commands mutate consumer repositories: Poetry treated any
    # pyproject.toml as its own and recreated uv-managed virtualenvs.
    if [ -n "$repo_root" ] && [ -x "$repo_root/.venv/bin/python3" ]; then
        canonicalize_runtime_path "$repo_root/.venv/bin/python3"
        return 0
    fi
    if [ -n "${CLAUDE_PROJECT_DIR:-}" ] && [ -x "${CLAUDE_PROJECT_DIR}/.venv/bin/python3" ]; then
        canonicalize_runtime_path "${CLAUDE_PROJECT_DIR}/.venv/bin/python3"
        return 0
    fi
    if [ -n "${CONDA_PREFIX:-}" ] || [ -n "${CONDA_DEFAULT_ENV:-}" ]; then
        if ! python3 -c "import sys; sys.exit(0 if sys.version_info >= (3,10) else 1)" 2>/dev/null; then
            if [ -x /usr/bin/python3 ]; then
                canonicalize_runtime_path /usr/bin/python3
                return 0
            fi
        fi
    fi
    if command -v python3 >/dev/null 2>&1; then
        canonicalize_runtime_path "$(command -v python3)"
        return 0
    fi
    if command -v python >/dev/null 2>&1; then
        canonicalize_runtime_path "$(command -v python)"
    fi
}

_wv_python_module_path() {
    local module_dir="$1"
    local _wv_pypath="${WV_LIB_DIR:-$SCRIPT_DIR}"

    if [ ! -d "$_wv_pypath/$module_dir" ]; then
        local _wv_real
        _wv_real=$(readlink -f "$_wv_pypath/lib/wv-config.sh" 2>/dev/null || echo "")
        if [ -n "$_wv_real" ]; then
            _wv_pypath=$(dirname "$(dirname "$_wv_real")")
        fi
    fi

    printf '%s\n' "$_wv_pypath"
}

_wv_agent_python_exec_module() {
    local module="$1"
    local pypath="$2"
    shift 2

    local python_command
    python_command=$(_bootstrap_python_command)
    if [ -z "$python_command" ]; then
        echo "wv: no usable Python found for $module" >&2
        return 127
    fi

    # PYTHONSAFEPATH: 'python -m' otherwise puts the cwd first on sys.path, so a
    # weave_* directory in the caller's project shadows the selected copy (wrong
    # copy of the tool). Honoured from 3.11; older interpreters ignore it, and
    # wv doctor's guide-validity check compares the module that actually ran.
    PYTHONSAFEPATH=1 PYTHONPATH="$pypath" "$python_command" -m "$module" "$@"
}
