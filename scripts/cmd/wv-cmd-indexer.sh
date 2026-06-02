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
    local _wv_pypath
    _wv_pypath=$(_wv_python_module_path weave_indexer)
    _wv_agent_python_exec_module weave_indexer "$_wv_pypath" "$@"
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
