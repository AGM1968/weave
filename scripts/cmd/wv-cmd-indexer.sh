#!/bin/bash
# wv-cmd-indexer.sh — wv index: chunk code files and store in brain.db
#
# Commands: index
# Sourced by: wv entry point (after lib modules)
# Dependencies: wv-config.sh, wv-db.sh
#
# This is the 8th cmd module. It wraps the weave_indexer Python module
# using the same PYTHONPATH bootstrap pattern as wv-cmd-quality.sh.

# ═══════════════════════════════════════════════════════════════════════════
# _wv_indexer_python — Invoke the weave_indexer Python module
# ═══════════════════════════════════════════════════════════════════════════

_wv_indexer_python() {
    local _wv_pypath="${WV_LIB_DIR:-$SCRIPT_DIR}"
    if [ ! -d "$_wv_pypath/weave_indexer" ]; then
        local _wv_real
        _wv_real=$(readlink -f "$_wv_pypath/lib/wv-config.sh" 2>/dev/null || echo "")
        if [ -n "$_wv_real" ]; then
            _wv_pypath=$(dirname "$(dirname "$_wv_real")")
        fi
    fi

    # Prefer a venv Python that has model2vec (embedding support).
    # Fallback chain: scripts-sibling .venv → CLAUDE_PROJECT_DIR .venv → conda bypass → python3
    local _wv_python3=python3
    local _scripts_parent
    _scripts_parent=$(dirname "$_wv_pypath")
    if [ -x "$_scripts_parent/.venv/bin/python3" ]; then
        _wv_python3="$_scripts_parent/.venv/bin/python3"
    elif [ -n "${CLAUDE_PROJECT_DIR:-}" ] && [ -x "${CLAUDE_PROJECT_DIR}/.venv/bin/python3" ]; then
        _wv_python3="${CLAUDE_PROJECT_DIR}/.venv/bin/python3"
    elif [ -n "${CONDA_PREFIX:-}" ] || [ -n "${CONDA_DEFAULT_ENV:-}" ]; then
        if ! python3 -c "import sys; sys.exit(0 if sys.version_info >= (3,10) else 1)" 2>/dev/null; then
            [ -x /usr/bin/python3 ] && _wv_python3=/usr/bin/python3
        fi
    fi

    PYTHONPATH="$_wv_pypath" "$_wv_python3" -m weave_indexer "$@"
}

# ═══════════════════════════════════════════════════════════════════════════
# cmd_index — Index code files into brain.db chunks table
# ═══════════════════════════════════════════════════════════════════════════

cmd_index() {
    local path=""
    local extra_args=()
    local json_out=0

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json) json_out=1; extra_args+=("--json") ;;
            --help|-h)
                echo "Usage: wv index [path] [--ext=.py,.ts] [--chunk-size=N] [--no-embed] [--json]"
                echo ""
                echo "  Chunk code files and store in brain.db for FTS search and semantic search."
                echo "  path         Root directory to index (default: WV_HOT_ZONE or .)"
                echo "  --ext        Comma-separated extensions (default: .py .ts .js .sh .go .rs .md)"
                echo "  --chunk-size Lines per chunk (default: 50)"
                echo "  --overlap    Overlap lines between chunks (default: 10)"
                echo "  --model      Embedding model (default: minishlab/potion-code-16M)"
                echo "  --no-embed   Skip embeddings, populate FTS content only"
                echo "  --json       Machine-readable output"
                return 0
                ;;
            --*) extra_args+=("$1") ;;
            *)
                if [ -z "$path" ]; then
                    path="$1"
                else
                    extra_args+=("$1")
                fi
                ;;
        esac
        shift
    done

    db_ensure

    local py_args=()
    [ -n "$path" ] && py_args+=("$path")
    py_args+=("--db=${WV_DB}")
    py_args+=("${extra_args[@]+"${extra_args[@]}"}")

    _wv_indexer_python "${py_args[@]}"
}
