#!/usr/bin/env bash
# macos-portable.sh — the suites that must pass on macOS (wv-4ccc98), run by
# .github/workflows/macos-portable.yml on push and by hand. Each suite runs in
# full; a suite that skips counts as a failure, since a skip is no coverage.
# Needs a sqlite3 with FTS5 first on PATH (macOS /usr/bin/sqlite3 has it) and a
# bash >= 4 (Homebrew's); the workflow arranges both.
set -uo pipefail
export WV_CALL_SOURCE=test
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUITES=(
    test-bash-guard.sh
    test-fts5-required.sh
    test-hot-zone-gc.sh
    test-hot-zone-base.sh
    test-hot-zone-placement.sh
    test-hot-zone-migrate.sh
    test-zone-write-lock.sh
)
failed=()
for s in "${SUITES[@]}"; do
    echo "::group::$s"
    out=$(bash "$ROOT/tests/$s" < /dev/null 2>&1); rc=$?
    printf '%s\n' "$out"
    echo "::endgroup::"
    case "$out" in
        *"skipped on"*|*SKIP*) failed+=("$s (skipped: no coverage)") ;;
        *) [ "$rc" -eq 0 ] || failed+=("$s (rc=$rc)") ;;
    esac
done
echo ""
if [ "${#failed[@]}" -eq 0 ]; then
    echo "macOS portable suites: all ${#SUITES[@]} passed"
    exit 0
fi
echo "macOS portable suites: ${#failed[@]} of ${#SUITES[@]} failed:"
printf '  - %s\n' "${failed[@]}"
exit 1
