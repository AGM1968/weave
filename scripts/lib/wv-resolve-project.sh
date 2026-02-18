#!/bin/bash
# Resolve WV_PROJECT_DIR portably. Source this from hooks.
# Fallback chain: $WV_PROJECT_DIR → git → $CLAUDE_PROJECT_DIR → BASH_SOURCE caller

if [ -z "$WV_PROJECT_DIR" ]; then
  WV_PROJECT_DIR=$(git rev-parse --show-toplevel 2>/dev/null) || true
fi
if [ -z "$WV_PROJECT_DIR" ] && [ -n "$CLAUDE_PROJECT_DIR" ]; then
  WV_PROJECT_DIR="$CLAUDE_PROJECT_DIR"
fi
if [ -z "$WV_PROJECT_DIR" ]; then
  # Last resort: derive from hook location (.claude/hooks/ → project root)
  WV_PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[1]}")/../.." && pwd)"
fi
export WV_PROJECT_DIR
WV="$WV_PROJECT_DIR/scripts/wv"
