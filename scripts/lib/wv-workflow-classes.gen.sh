# GENERATED FROM templates/workflow-classes.conf — do not edit.
# Regenerate with: scripts/gen-workflow-classes.sh
# shellcheck shell=bash
# shellcheck disable=SC1010
_WF_BOOTSTRAP_ALLOW=( add work ready status list show sync load doctor bootstrap search context quick recover )
_WF_CLOSE_GATED=( done ship )
_WF_HOOK_EDIT_TOOLS=( Edit Write NotebookEdit mcp__ide__executeCode create_file replace_string_in_file insert_edit_into_file multi_replace_string_in_file edit_notebook_file )
_WF_CLAUDE_EDIT_EXEMPT_PREFIXES=( \$HOME/.claude/ )
