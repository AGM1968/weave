#!/bin/bash
# Post-edit hook: Run linters and formatters on edited files
# - Python files: ruff (lint)
# - Markdown files: prettier (auto-format)
# - Other files: prettier (auto-format if supported)
# Triggered by PostToolUse on Edit/Write

set -e

# Read JSON input
INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // ""')
# VS Code sends camelCase (filePath), Claude Code sends snake_case (file_path)
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // .tool_input.filePath // .tool_input.path // ""')

# Skip linting if the tool call itself failed (tool_response.success = false).
# PostToolUseFailure fires for hard failures; this guards soft/partial failures.
# Use jq -e equality: 'jq -r ".x // true"' collapses explicit boolean false to
# true (alternative-operator semantics on falsey values).
if echo "$INPUT" | jq -e '.tool_response.success == false' >/dev/null 2>&1; then
    exit 0
fi

# Python files: run ruff
if [[ "$FILE_PATH" =~ \.py$ ]]; then
    if command -v ruff &> /dev/null && [ -f "$FILE_PATH" ]; then
        ISSUES=$(ruff check "$FILE_PATH" 2>&1 || true)
        if [ -n "$ISSUES" ] && [ "$ISSUES" != "All checks passed!" ]; then
            echo "{\"additionalContext\": \"Ruff lint issues in $FILE_PATH:\\n$ISSUES\"}"
            exit 0
        fi
    fi
    # Also run mypy on the containing module directory
    if command -v python3 &> /dev/null; then
        # Identify enclosing Python module (scripts/weave_quality, scripts/weave_gh, etc.)
        MODULE_DIR=""
        case "$FILE_PATH" in
            */weave_quality/*) MODULE_DIR="scripts/weave_quality" ;;
            */weave_gh/*)     MODULE_DIR="scripts/weave_gh" ;;
            tests/*)          MODULE_DIR="tests" ;;
        esac
        if [ -n "$MODULE_DIR" ]; then
            REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "$(pwd)")
            MYPY_OUT=$(cd "$REPO_ROOT" && python3 -m mypy "$MODULE_DIR" --ignore-missing-imports --no-error-summary 2>&1 || true)
            if echo "$MYPY_OUT" | grep -q "error:"; then
                echo "{\"additionalContext\": \"mypy type errors in $MODULE_DIR:\\n$MYPY_OUT\"}"
                exit 0
            fi
        fi
    fi
    exit 0
fi

# Markdown and other supported files: run prettier — only within repo root
# Guard prevents prettier from silently rewriting files outside the project
# (e.g. ~/.claude/settings.json) which could strip fields it doesn't recognise.
if [[ "$FILE_PATH" =~ \.(md|json|yaml|yml|js|ts|css|html)$ ]]; then
    REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
    if [ -n "$REPO_ROOT" ] && [[ "$FILE_PATH" == "$REPO_ROOT"/* ]]; then
        if command -v prettier &> /dev/null && [ -f "$FILE_PATH" ]; then
            if ! prettier --check "$FILE_PATH" &> /dev/null; then
                prettier --write "$FILE_PATH" &> /dev/null || true
            fi
        fi
    fi
    exit 0
fi

# Shell/hook source edits: editing these without ./install.sh leaves the installed
# copy stale, which fails the pre-commit drift gate ~3min in. Nudge immediately —
# proactive L2 reminder (the cross-agent net is the pre-commit self-heal + the
# bootstrap advisory; this is the cheap Claude-side win where the path is free).
case "$FILE_PATH" in
    */scripts/*.sh|*/scripts/wv|*/.claude/hooks/*.sh)
        REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
        if [ -n "$REPO_ROOT" ] && [ -x "$REPO_ROOT/install.sh" ]; then
            echo "{\"additionalContext\": \"Edited installed source ($FILE_PATH) — run ./install.sh before committing, or wv doctor / the pre-commit drift gate will report 'hook drift (stale)'.\"}"
            exit 0
        fi
        ;;
esac

exit 0
