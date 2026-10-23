#!/usr/bin/env bash
# Suite-driven wv calls are tagged test so call-stats retro reads can exclude them.
export WV_CALL_SOURCE=test
# test-consumer-shellcheck.sh — vendored shell files must pass a CONSUMER's lint
#
# Source: wv-f9e88c. wv init-repo copies .claude/hooks/*.sh, a skill's extra
# scripts (.claude/skills/<skill>/*.sh) and, for a vendoring consumer,
# scripts/hooks/*-weave.sh and the test-impacted template into the consumer's
# own tree, where its pre-commit hook shellchecks them under
# DEFAULT rules. This repository's .shellcheckrc disables SC2034 and SC2155 and
# does not ship, so `make check` could never see what a consumer sees: rc.13
# shipped post-edit-lint.sh with an unused TOOL_NAME, and every consumer commit
# staging it was refused with SC2034.
#
# Judged with --norc at warning severity, the shape a consumer's gate applies.
# A planted unused variable must fail the same check, so a pass is not vacuous.

set -euo pipefail
export WV_TEST_SUITE=1  # the user's config.env cannot log this suite's wv calls (wv-6b0f57)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

pass=0
run=0
ok() { echo "  ✓ $1"; pass=$((pass + 1)); run=$((run + 1)); }
bad() { echo "  ✗ $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/      /'; run=$((run + 1)); }

echo "Vendored shell files pass shellcheck under consumer rules (wv-f9e88c)"

if ! command -v shellcheck >/dev/null 2>&1; then
    echo "  - shellcheck not installed; nothing to judge"
    echo "Results: 0/0 passed"
    exit 0
fi

consumer_lint() { shellcheck --norc --severity=warning --shell=bash "$1"; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
# shellcheck disable=SC2016  # writes a planted script whose $(date) must stay literal
printf '#!/bin/bash\nset -e\nUNUSED=$(date)\necho done\n' > "$TMP/planted.sh"
if consumer_lint "$TMP/planted.sh" >/dev/null 2>&1; then
    bad "control: a planted unused variable fails consumer rules"
else
    ok "control: a planted unused variable fails consumer rules"
fi

shopt -s nullglob
files=("$PROJECT_ROOT"/.claude/hooks/*.sh "$PROJECT_ROOT"/.claude/skills/*/*.sh
       "$PROJECT_ROOT"/scripts/hooks/*-weave.sh "$PROJECT_ROOT"/templates/*.sh.template)
shopt -u nullglob
[ "${#files[@]}" -gt 0 ] && ok "found ${#files[@]} vendored shell file(s) to judge" \
    || bad "found vendored shell files to judge"

for f in "${files[@]}"; do
    rel=${f#"$PROJECT_ROOT"/}
    if out=$(consumer_lint "$f" 2>&1); then
        ok "$rel"
    else
        bad "$rel" "$(grep -E '^In |SC[0-9]+' <<< "$out" | sed -n '1,6p')"
    fi
done

echo ""
echo "Results: $pass/$run passed"
[ "$pass" -eq "$run" ]
