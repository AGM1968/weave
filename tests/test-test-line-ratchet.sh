#!/usr/bin/env bash
# test-test-line-ratchet.sh — the advisory net test-line count (wv-1163f5).
# Counts over a fixture repository's staged index: adds, deletes, a rename with
# a small edit (only the edit counts), non-test paths (ignored), a binary file
# (a file, no lines), and the over-budget prompt. The advisory never fails.
set -uo pipefail
export WV_TEST_SUITE=1
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$(cd "$SCRIPT_DIR/.." && pwd)/scripts/lib/wv-test-ratchet.sh"
# shellcheck source=scripts/lib/wv-test-ratchet.sh
source "$LIB"

pass=0 run=0
check() {
    run=$((run + 1))
    if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "  ✓ $1"
    else echo "  ✗ $1"; echo "      expected '$2', got '$3'"; fi
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE
cd "$TMP" || exit 1
git init -q . && git config user.email t@t && git config user.name t && git config commit.gpgsign false
# Rename detection must not depend on the user's diff.renames setting.
git config diff.renames false
mkdir -p tests src
lines() { local i; for ((i = 1; i <= $1; i++)); do echo "$2 line $i"; done; }
lines 40 old > tests/test-old.sh
lines 30 keep > tests/test-move.sh
lines 10 src > src/main.sh
git add -A && git commit -q -m base

echo "== nothing staged =="
check "a commit with no test path prints nothing" "" "$(wv_test_line_advisory)"
echo "x" >> src/main.sh; git add src/main.sh
check "...nor does a commit touching only non-test paths" "" "$(wv_test_line_advisory)"
git reset -q

echo "== adds, deletes, renames =="
lines 25 new > tests/test-new.sh                       # +25
git rm -q tests/test-old.sh                            # -40
git mv tests/test-move.sh tests/test-moved.sh          # rename ...
echo "one more" >> tests/test-moved.sh                 # ... +1
lines 7 py > test_util.py                              # root test_* +7
mkdir -p web; lines 5 ts > web/app.test.ts             # *.test.ts +5
lines 50 app > src/feature.sh                          # not a test path
printf '\x00\x01\x02' > tests/blob.bin                 # binary: a file, no lines
git add -A
check "count over adds, a delete, an edited rename, test_* and *.test.ts; binary and src ignored" "38 40 6" "$(wv_test_line_count)"
out=$(wv_test_line_advisory)
check "the report names the totals, net and budget" "1" \
    "$(grep -c 'test lines in this commit: +38 -40 over 6 file(s), net -2 (advisory budget +150, wv-1163f5)' <<< "$out")"
check "...and asks for no justification under budget" "0" "$(grep -c 'over the advisory budget' <<< "$out")"
git commit -q -m mixed

echo "== over budget =="
lines 200 big > tests/test-big.sh; git add -A
out=$(wv_test_line_advisory); rc=$?
check "over budget asks for a justification on the node" "1" "$(grep -c 'over the advisory budget; this commit is not refused' <<< "$out")"
check "...and still returns 0" "0" "$rc"
check "the budget follows WV_GATE_TEST_LINE_BUDGET" "0" \
    "$(WV_GATE_TEST_LINE_BUDGET=500 wv_test_line_advisory | grep -c 'over the advisory budget')"
check "...and an invalid budget falls back to 150" "1" \
    "$(WV_GATE_TEST_LINE_BUDGET=lots wv_test_line_advisory | grep -c 'advisory budget +150')"

echo "Results: $pass/$run passed"
[ "$pass" -eq "$run" ]
