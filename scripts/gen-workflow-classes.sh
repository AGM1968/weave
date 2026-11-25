#!/usr/bin/env bash
# Compile workflow-classes.conf into hook and documentation projections.
# wv bash guard (wv-7257a8): bash >= 4 or a clear refusal. Identical in every executed entry point; master: scripts/lib/wv-bash-guard.sh.
_wv_bash_guard() {
    if [ -n "${WV_TEST_BASH_TOO_OLD:-}" ] && [ "${WV_TEST_MODE:-}" != 1 ]; then echo "wv: WV_TEST_BASH_TOO_OLD needs WV_TEST_MODE=1; ignoring it." >&2; fi
    if [ "${BASH_VERSINFO[0]:-0}" -ge 4 ] && ! { [ "${WV_TEST_MODE:-}" = 1 ] && [ "${WV_TEST_BASH_TOO_OLD:-}" = 1 ]; }; then
        unset WV_BASH_REEXEC
        return 0
    fi
    local b
    if [ -z "${WV_BASH_REEXEC:-}" ] && [ -f "$0" ]; then
        for b in ${WV_BASH:-} /opt/homebrew/bin/bash /usr/local/bin/bash /usr/bin/bash /bin/bash; do
            # shellcheck disable=SC2016  # the child bash expands it
            if [ -x "$b" ] && [ "$("$b" -c 'echo "${BASH_VERSINFO[0]}"' 2>/dev/null)" -ge 4 ] 2>/dev/null; then
                WV_BASH_REEXEC=1 WV_TEST_BASH_TOO_OLD='' exec "$b" "$0" "$@"
            fi
        done
    fi
    echo "wv: $0 needs bash 4 or newer but is running under bash ${BASH_VERSION:-unknown}." >&2
    echo "    On macOS /bin/bash is 3.2: install a newer one (brew install bash) or set WV_BASH to it." >&2
    exit 1
}
_wv_bash_guard "$@"
# end wv bash guard

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="$ROOT/templates/workflow-classes.conf"
GENERATED="$ROOT/scripts/lib/wv-workflow-classes.gen.sh"
WORKFLOW="$ROOT/templates/WORKFLOW.md"
CHECK_ONLY=false
[ "${1:-}" != "--check" ] || CHECK_ONLY=true

trim() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    printf '%s' "${value%"${value##*[![:space:]]}"}"
}

read_class() {
    local wanted="$1" key value
    while IFS='=' read -r key value; do
        key=$(trim "$key")
        [ "$key" = "$wanted" ] || continue
        trim "$value"
        return 0
    done < "$MANIFEST"
    return 1
}

to_array() {
    local csv="$1" item
    local -n result="$2"
    IFS=',' read -r -a result <<< "$csv"
    for item in "${!result[@]}"; do result[$item]=$(trim "${result[$item]}"); done
}

emit_generated() {
    local output="$1" item class array_name
    printf '%s\n' '# GENERATED FROM templates/workflow-classes.conf — do not edit.' > "$output"
    printf '%s\n' '# Regenerate with: scripts/gen-workflow-classes.sh' >> "$output"
    # Sourced fragment (no shebang): declare the shell so shellcheck SC2148 is satisfied,
    # and silence SC1010 for the `done` lifecycle keyword used as a literal array member.
    printf '%s\n' '# shellcheck shell=bash' >> "$output"
    printf '%s\n' '# shellcheck disable=SC1010' >> "$output"
    for class in bootstrap_allow close_gated hook_edit_tools claude_edit_exempt_prefixes; do
        array_name="_WF_${class^^}"
        printf '%s=(' "$array_name" >> "$output"
        local -n values="$class"
        for item in "${values[@]}"; do printf ' %q' "$item" >> "$output"; done
        printf ' )\n' >> "$output"
    done
}

emit_doc_block() {
    local output="$1" class label enforcement
    printf '%s\n' '<!-- BEGIN GENERATED: workflow-classes -->' > "$output"
    printf '%s\n' '## Command Classes' '' >> "$output"
    # shellcheck disable=SC2016  # backticks are Markdown code spans in the generated table
    printf '%s\n' 'This table is generated from `templates/workflow-classes.conf`. The pre-action hook uses the same compiled data.' '' >> "$output"
    printf '%s\n' '| Class | Members | Enforcement |' '| --- | --- | --- |' >> "$output"
    for class in bootstrap_allow close_gated hook_edit_tools claude_edit_exempt_prefixes; do
        local -n values="$class"
        case "$class" in
            bootstrap_allow) label='Safe lifecycle/read commands'; enforcement='Bypass pre-action active-node check' ;;
            close_gated) label='Close lifecycle commands'; enforcement='Require active-node check' ;;
            hook_edit_tools) label='Pre-action hook adapter tool names'; enforcement='Require active-node check' ;;
            claude_edit_exempt_prefixes) label='Claude Code runtime path prefixes'; enforcement='Excluded from project-work enforcement' ;;
        esac
        # shellcheck disable=SC2016  # backticks are Markdown code spans in the generated table
        printf '| %s | `%s` | %s |\n' "$label" "$(IFS=', '; echo "${values[*]}")" "$enforcement" >> "$output"
    done
    printf '%s\n' '<!-- END GENERATED: workflow-classes -->' >> "$output"
}

update_workflow() {
    local block="$1" output="$2"
    awk -v block="$block" '
        function emit_block(  line) { while ((getline line < block) > 0) print line; close(block) }
        /<!-- BEGIN GENERATED: workflow-classes -->/ { emit_block(); inserted=1; skipping=1; next }
        /<!-- END GENERATED: workflow-classes -->/ && skipping { skipping=0; next }
        /^## Commands$/ && !inserted { emit_block(); print ""; inserted=1 }
        !skipping { print }
    ' "$WORKFLOW" > "$output"
}

to_array "$(read_class bootstrap_allow)" bootstrap_allow
to_array "$(read_class close_gated)" close_gated
to_array "$(read_class hook_edit_tools)" hook_edit_tools
to_array "$(read_class claude_edit_exempt_prefixes)" claude_edit_exempt_prefixes

# Fail loudly on an empty/missing class. A missing key makes read_class return 1,
# but command-substitution failure does not trip set -e, so to_array would yield a
# silent empty array — and the drift gate (projection-vs-projection) cannot catch it
# because both sides would agree on "empty". Guard the source of truth here.
for _class in bootstrap_allow close_gated hook_edit_tools claude_edit_exempt_prefixes; do
    declare -n _arr="$_class"
    if [ "${#_arr[@]}" -eq 0 ]; then
        echo "workflow manifest: class '$_class' is empty or missing in $MANIFEST" >&2
        exit 1
    fi
    unset -n _arr
done

tmp_generated=$(mktemp)
tmp_block=$(mktemp)
tmp_workflow=$(mktemp)
trap 'rm -f "$tmp_generated" "$tmp_block" "$tmp_workflow"' EXIT
emit_generated "$tmp_generated"
emit_doc_block "$tmp_block"
update_workflow "$tmp_block" "$tmp_workflow"
if "$CHECK_ONLY"; then
    cmp -s "$tmp_generated" "$GENERATED" || { echo "workflow classes: generated hook projection is stale" >&2; exit 1; }
    cmp -s "$tmp_workflow" "$WORKFLOW" || { echo "workflow classes: WORKFLOW.md projection is stale" >&2; exit 1; }
    exit 0
fi
mv "$tmp_generated" "$GENERATED"
mv "$tmp_workflow" "$WORKFLOW"
