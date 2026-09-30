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

# _restore_generated_regions <original> <formatted> -- prints <formatted> with
# every '<!-- BEGIN GENERATED ... -->' .. '<!-- END GENERATED ... -->' region
# replaced by the same region from <original>, byte for byte. Those regions
# belong to a generator whose --check compares them exactly; prettier reflowing
# the workflow-classes block in templates/WORKFLOW.md turned make check red
# after an unrelated prose edit (wv-5af710). Exits 3 without a result if the
# regions do not pair up in order, so the caller leaves the file alone.
_restore_generated_regions() {
    awk '
        NR == FNR {
            if ($0 ~ /^<!-- BEGIN GENERATED/) { inside = 1; n++; head[n] = $0 }
            if (inside) region[n] = region[n] $0 "\n"
            if (inside && $0 ~ /^<!-- END GENERATED/) inside = 0
            next
        }
        skipping { if ($0 ~ /^<!-- END GENERATED/) skipping = 0; next }
        /^<!-- BEGIN GENERATED/ {
            k++
            if (k > n || $0 != head[k]) { bad = 1; exit }
            printf "%s", region[k]; skipping = 1; next
        }
        { print }
        END { if (bad || k != n) exit 3 }
    ' "$1" "$2"
}

# Markdown and other supported files: run prettier — only within repo root
# Guard prevents prettier from silently rewriting files outside the project
# (e.g. ~/.claude/settings.json) which could strip fields it doesn't recognise.
if [[ "$FILE_PATH" =~ \.(md|json|yaml|yml|js|ts|css|html)$ ]]; then
    REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
    if [ -n "$REPO_ROOT" ] && [[ "$FILE_PATH" == "$REPO_ROOT"/* ]]; then
        if command -v prettier &> /dev/null && [ -f "$FILE_PATH" ]; then
            if ! prettier --check "$FILE_PATH" &> /dev/null; then
                FORMATTED=$(mktemp)
                RESULT=$(mktemp)
                # Format to a temp file and write back only a complete result, in
                # place so the file keeps its mode.
                if prettier "$FILE_PATH" > "$FORMATTED" 2>/dev/null; then
                    if grep -q '^<!-- BEGIN GENERATED' "$FILE_PATH"; then
                        _restore_generated_regions "$FILE_PATH" "$FORMATTED" > "$RESULT" || : > "$RESULT"
                    else
                        cp "$FORMATTED" "$RESULT"
                    fi
                    if [ -s "$RESULT" ] && ! cmp -s "$RESULT" "$FILE_PATH"; then
                        cat "$RESULT" > "$FILE_PATH"
                    fi
                fi
                rm -f "$FORMATTED" "$RESULT"
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
