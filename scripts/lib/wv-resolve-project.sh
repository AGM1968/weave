#!/bin/bash
# Resolve WV_PROJECT_DIR portably. Source this from hooks.
# Fallback chain: $WV_PROJECT_DIR → git → $CLAUDE_PROJECT_DIR → BASH_SOURCE caller

if [ -z "${WV_PROJECT_DIR:-}" ]; then
  WV_PROJECT_DIR=$(git rev-parse --show-toplevel 2>/dev/null) || true
fi
if [ -z "${WV_PROJECT_DIR:-}" ] && [ -n "${CLAUDE_PROJECT_DIR:-}" ]; then
  WV_PROJECT_DIR="$CLAUDE_PROJECT_DIR"
fi
# Safety: reject home directory as project root — it has no .git and any .weave/
# there is a materialization bug. Hooks firing from ~ must not pollute ~/.weave/.
if [ "${WV_PROJECT_DIR:-}" = "$HOME" ] || [ "${WV_PROJECT_DIR:-}" = "/root" ]; then
  WV_PROJECT_DIR=""
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
# No wv in the project: pair these hooks with the CLI of the tree this resolver
# came from -- scripts/lib/../wv in a source checkout -- before the installed
# binary. Falling straight back to ~/.local/bin/wv made hooks run from a
# checkout against a fixture project exercise INSTALLED code, so a source fix
# never reached four suites and a source regression could pass (wv-706439).
# An installed resolver (~/.config/weave/lib, ~/.local/lib/weave/lib) has no
# sibling wv and still falls through to the installed binary.
if [ ! -x "$WV" ]; then
  _rp_tree_wv="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)/wv"
  if [ -x "$_rp_tree_wv" ] && [ -f "$_rp_tree_wv" ]; then
    WV="$_rp_tree_wv"
  else
    WV="$HOME/.local/bin/wv"
  fi
  unset _rp_tree_wv
fi
export WV
