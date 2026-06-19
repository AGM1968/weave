#!/bin/bash
# PostToolUse hook: capture-by-mechanism for repo-scoped Claude memory writes.
#
# When Claude writes a project memory file under
#   $HOME/.claude/projects/<repo-slug>/memory/*.md
# this hook proves the write belongs to THIS repo, then either records an
# advisory (default, dry) or imports it into the graph as a mem_status=candidate
# node (opt-in via WV_MEMORY_CAPTURE=1). It never promotes to active recall and
# never rewrites the write — PreToolUse stays allow/deny only; capture is a
# post-write import (PROPOSAL-wv-agent-memory-substrate S5).
#
# Repo-scope proof (resolves wv-4109ef path-key mismatch): the slug is derived
# from the LIVE repo root (tr '/' '-'), not a hardcoded key, so ~/Projects vs
# ~/Documents checkouts each match only their own Claude memory path.

set -euo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "$HOOK_DIR/../lib/wv-resolve-project.sh" 2>/dev/null \
    || source "$HOOK_DIR/../../scripts/lib/wv-resolve-project.sh" 2>/dev/null \
    || source "${HOME}/.config/weave/lib/wv-resolve-project.sh" 2>/dev/null \
    || exit 0
source "$HOOK_DIR/../lib/wv-hook-common.sh" 2>/dev/null \
    || source "$HOOK_DIR/../../scripts/lib/wv-hook-common.sh" 2>/dev/null \
    || source "${HOME}/.config/weave/lib/wv-hook-common.sh" 2>/dev/null \
    || true
_hc_refresh 2>/dev/null || true

INPUT=$(cat)
TOOL=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)
case "$TOOL" in
    Edit|Write|NotebookEdit) ;;
    *) exit 0 ;;
esac

# Skip on tool failure (jq `// true` collapses explicit false → true, so test
# explicit equality).
if echo "$INPUT" | jq -e '.tool_response.success == false' >/dev/null 2>&1; then
    exit 0
fi

FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // .tool_input.filePath // .tool_input.path // ""' 2>/dev/null)
[ -z "$FILE_PATH" ] && exit 0

# Only repo-scoped Claude *memory* markdown files are capture sources.
case "$FILE_PATH" in
    "$HOME"/.claude/projects/*/memory/*.md) ;;
    *) exit 0 ;;
esac

# Resolve the live repo root, rejecting $HOME (hook may fire from ~).
REPO_ROOT="${WV_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
if [ -z "$REPO_ROOT" ] || [ "$REPO_ROOT" = "$HOME" ] || [ "$REPO_ROOT" = "/root" ]; then
    exit 0
fi

# Repo-scope PROOF: the written path's slug segment must equal slug(REPO_ROOT).
REPO_SLUG=$(printf '%s' "$REPO_ROOT" | tr '/' '-')
PATH_SLUG="${FILE_PATH#"$HOME"/.claude/projects/}"
PATH_SLUG="${PATH_SLUG%%/memory/*}"
if [ "$PATH_SLUG" != "$REPO_SLUG" ]; then
    # A different repo's Claude memory — not ours to import.
    exit 0
fi

MEMORY_DIR="${FILE_PATH%/*}"

# Default is dry: record an advisory the agent/operator can act on, no graph
# write. Opt in with WV_MEMORY_CAPTURE=1 to import as candidate.
if [ "${WV_MEMORY_CAPTURE:-0}" != "1" ]; then
    ADVISORY_DIR="${_HC_HOT_ZONE:-${WV_HOT_ZONE:-/tmp}}"
    mkdir -p "$ADVISORY_DIR" 2>/dev/null || exit 0
    printf '%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$MEMORY_DIR" \
        >> "$ADVISORY_DIR/memory-capture-pending.tsv" 2>/dev/null || true
    cat <<JSON
{"additionalContext": "Repo-scoped Claude memory write detected ($MEMORY_DIR). Graph is the durable authority — import with: wv memory import --source=claude --path='$MEMORY_DIR'. Set WV_MEMORY_CAPTURE=1 to auto-import as candidates."}
JSON
    exit 0
fi

# Opt-in import: create mem_status=candidate nodes (never active recall).
WV_BIN=""
for cand in "$REPO_ROOT/scripts/wv" "$HOME/.local/bin/wv" "$(command -v wv 2>/dev/null || true)"; do
    if [ -n "$cand" ] && [ -x "$cand" ]; then WV_BIN="$cand"; break; fi
done
[ -z "$WV_BIN" ] && exit 0

"$WV_BIN" memory import --source=claude --path="$MEMORY_DIR" --repo-root="$REPO_ROOT" >/dev/null 2>&1 || true
exit 0
