#!/usr/bin/env bash
# Suite-driven wv calls are tagged test so call-stats retro reads can exclude them.
export WV_CALL_SOURCE=test
# A consumer can retire what it declared (wv-cc36c7). Once a suite is adopted in
# .weave/gate-provision.json, un-naming it or deleting the file is refused
# unless HEAD carries a retirement record for that exact change (transition
# rule 4). The refusal used to print the internal check's shell script; it now
# prints the record to commit. Driven here through adoption, an un-named suite,
# one use of its record, and deleting the declaration.
set -uo pipefail
export WV_TEST_SUITE=1  # the user's config.env cannot log this suite's wv calls (wv-6b0f57)
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT/scripts/lib"
run=0; pass=0
ok()  { run=$((run+1)); pass=$((pass+1)); echo "  ✓ $1"; }
bad() { run=$((run+1)); echo "  ✗ $1"; [ -n "${2:-}" ] && echo "      $2"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$3] got [$2]"; fi; }
TMP=$(mktemp -d /tmp/wv-provision-retirement-XXXXXX)
trap 'rm -rf "$TMP"' EXIT
unset GIT_INDEX_FILE GIT_DIR GIT_WORK_TREE GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0

R="$TMP/consumer"; mkdir -p "$R/.weave" "$R/tests"
cd "$R" || exit 1
git init -q . && git config user.email t@t && git config user.name t && git config commit.gpgsign false
commit() { git -c core.hooksPath=/dev/null commit -q -m "$1"; }
declare_suites() {  # declare_suites <suite>... — write the declaration naming them
    jq -n '{version: 3, default: {mode: "checkout"}, recipes: {}, suites: ($ARGS.positional | map({(.): {}}) | add // {})}' \
        --args "$@" > .weave/gate-provision.json
}
# judge — the gate's loader on the staged change against HEAD: prints its refusal, returns its status
judge() {
    { python3 -I "$LIB/wv-gate-suite.py" --declarations --policy "$LIB/wv-gate-provision.json" \
        --repo "$R" --tree "$(git write-tree)" --base HEAD >/dev/null; } 2>&1
}
# record_from <refusal> <file> — the printed record, filled in, written where it belongs
record_from() {
    sed -n '/^{/,/^}/p' <<< "$1" | jq '.reason = "the suite moved to CI" | .verification = "ran the remaining suite"' > "$2"
}

printf '#!/bin/sh\n' > tests/test-a.sh; printf '#!/bin/sh\n' > tests/test-b.sh
declare_suites tests/test-a.sh tests/test-b.sh
git add -A -f && commit "adopt two suites"

echo "=== un-naming an adopted suite ==="
declare_suites tests/test-a.sh; git add -f .weave/gate-provision.json
out=$(judge); rc=$?
check "un-naming an adopted suite without a record is refused" "$rc" "1"
case "$out" in *"stops declaring tests/test-b.sh"*".weave/gate-repairs/"*) ok "the refusal names the suite and where the record goes" ;;
    *) bad "the refusal names the suite and where the record goes" "$out" ;; esac
case "$out" in *"bash -c"*|*"source \""*) bad "the refusal no longer prints the check's shell script" "$out" ;;
    *) ok "the refusal no longer prints the check's shell script" ;; esac
check "the printed record names the staged bytes, not a deletion" \
    "$(sed -n '/^{/,/^}/p' <<< "$out" | jq -r '"\(.kind) \(.replacement_mode) \(.replacement | length)"')" "retirement 100644 40"
mkdir -p .weave/gate-repairs; record_from "$out" .weave/gate-repairs/retire-b.json
git stash push -q -- .weave/gate-provision.json 2>/dev/null || git restore --staged .weave/gate-provision.json
git add -f .weave/gate-repairs/retire-b.json && commit "record the retirement"
git stash pop -q 2>/dev/null; git add -f .weave/gate-provision.json
judge >/dev/null; check "with the record at HEAD the same change is admitted" "$?" "0"
commit "stop declaring test-b"

echo "=== a record is used once ==="
declare_suites tests/test-a.sh tests/test-b.sh; git add -f .weave/gate-provision.json && commit "adopt test-b again"
declare_suites tests/test-a.sh; git add -f .weave/gate-provision.json
judge >/dev/null; check "the same bytes are not admitted a second time" "$?" "1"
git restore --staged --worktree .weave/gate-provision.json

echo "=== deleting the declaration ==="
git rm -q --cached .weave/gate-provision.json; rm -f .weave/gate-provision.json
out=$(judge); rc=$?
check "deleting the declaration without a record is refused" "$rc" "1"
case "$out" in *"removes .weave/gate-provision.json"*) ok "the refusal says the file is removed" ;;
    *) bad "the refusal says the file is removed" "$out" ;; esac
check "the printed record names no replacement" \
    "$(sed -n '/^{/,/^}/p' <<< "$out" | jq -r '"\(.replacement)|\(.replacement_mode)"')" "|000000"
record_from "$out" .weave/gate-repairs/retire-all.json
git stash push -q 2>/dev/null; git add -f .weave/gate-repairs/retire-all.json && commit "record the full retirement"
git stash pop -q 2>/dev/null; git rm -q --cached .weave/gate-provision.json 2>/dev/null; rm -f .weave/gate-provision.json
judge >/dev/null; check "with its record the deletion is admitted" "$?" "0"

echo ""
echo "Results: $pass/$run passed"
[ "$pass" -eq "$run" ]
