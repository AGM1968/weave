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
  # Only use if that derived path has been explicitly initialised with wv-init-repo
  _DERIVED="$(cd "$(dirname "${BASH_SOURCE[1]}")/../.." && pwd)"
  if [ -d "$_DERIVED/.weave" ]; then
    WV_PROJECT_DIR="$_DERIVED"
  fi
fi
export WV_PROJECT_DIR
WV="$WV_PROJECT_DIR/scripts/wv"
# Fallback to installed binary when not in the memory-system source repo
if [ ! -x "$WV" ]; then
  WV="$HOME/.local/bin/wv"
fi
export WV
