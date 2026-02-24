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

# Python files: run ruff
if [[ "$FILE_PATH" =~ \.py$ ]]; then
    if command -v ruff &> /dev/null && [ -f "$FILE_PATH" ]; then
        ISSUES=$(ruff check "$FILE_PATH" 2>&1 || true)
        if [ -n "$ISSUES" ] && [ "$ISSUES" != "All checks passed!" ]; then
            echo "{\"decision\": \"block\", \"reason\": \"Python lint issues found:\\n$ISSUES\"}"
            exit 1
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
