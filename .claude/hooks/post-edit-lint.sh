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
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // .tool_input.path // ""')

# Skip linting if the tool call itself failed (tool_response.success = false)
# PostToolUseFailure fires for hard failures; this guards soft/partial failures
TOOL_SUCCESS=$(echo "$INPUT" | jq -r '.tool_response.success // true' 2>/dev/null)
if [[ "$TOOL_SUCCESS" == "false" ]]; then
    exit 0
fi

# Python files: run ruff
if [[ "$FILE_PATH" =~ \.py$ ]]; then
    if command -v ruff &> /dev/null && [ -f "$FILE_PATH" ]; then
        ISSUES=$(ruff check "$FILE_PATH" 2>&1 || true)
        if [ -n "$ISSUES" ] && [ "$ISSUES" != "All checks passed!" ]; then
            echo "{\"decision\": \"block\", \"reason\": \"Python lint issues found:\\n$ISSUES\"}"
            exit 1
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
                echo "{\"decision\": \"block\", \"reason\": \"mypy type errors found:\\n$MYPY_OUT\"}"
                exit 1
            fi
        fi
    fi
    exit 0
fi

# Markdown and other supported files: run prettier
if [[ "$FILE_PATH" =~ \.(md|json|yaml|yml|js|ts|css|html)$ ]]; then
    if command -v prettier &> /dev/null && [ -f "$FILE_PATH" ]; then
        # Check if file needs formatting
        if ! prettier --check "$FILE_PATH" &> /dev/null; then
            # Auto-format the file
            prettier --write "$FILE_PATH" &> /dev/null || true
            echo "{\"decision\": \"allow\", \"message\": \"File auto-formatted with prettier\"}"
        fi
    fi
    exit 0
fi

exit 0
