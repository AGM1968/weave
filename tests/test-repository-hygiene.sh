#!/usr/bin/env bash
# Verify local Weave runtime residue cannot enter a source commit through the
# documented `git add .weave/` graph-state workflow.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

TESTS=0
PASSED=0
FAILED=0

pass() { TESTS=$((TESTS + 1)); PASSED=$((PASSED + 1)); printf '✓ %s\n' "$1"; }
fail() { TESTS=$((TESTS + 1)); FAILED=$((FAILED + 1)); printf '✗ %s\n' "$1"; }

assert_staged() {
    local path="$1" message="$2"
    if git -C "$TMP" diff --cached --name-only | grep -qFx -- "$path"; then
        pass "$message"
    else
        fail "$message"
    fi
}

assert_not_staged() {
    local path="$1" message="$2"
    if git -C "$TMP" diff --cached --name-only | grep -qFx -- "$path"; then
        fail "$message"
    else
        pass "$message"
    fi
}

echo "=== Repository Hygiene Tests ==="

tracked_residue=$(git -C "$REPO_ROOT" ls-files | grep -E \
    '^\.weave/\.(state\.sql|nodes\.jsonl|edges\.jsonl)\.[^/]+$|^\.weave/\.prune_epoch$' || true)
if [ -z "$tracked_residue" ]; then
    pass "source tree tracks no atomic projection or prune-epoch residue"
else
    fail "source tree tracks no atomic projection or prune-epoch residue"
    printf '  %s\n' "$tracked_residue"
fi

git -C "$TMP" init -q
cp "$REPO_ROOT/.gitignore" "$TMP/.gitignore"
mkdir -p "$TMP/.weave"
printf 'canonical\n' > "$TMP/.weave/state.sql"
printf 'canonical\n' > "$TMP/.weave/nodes.jsonl"
printf 'canonical\n' > "$TMP/.weave/edges.jsonl"
printf 'temporary\n' > "$TMP/.weave/.state.sql.ABC123"
printf 'temporary\n' > "$TMP/.weave/.nodes.jsonl.ABC123"
printf 'temporary\n' > "$TMP/.weave/.edges.jsonl.ABC123"
printf '1234567890\n' > "$TMP/.weave/.prune_epoch"
git -C "$TMP" add .gitignore .weave/

assert_staged ".weave/state.sql" "canonical graph exports remain stageable"
assert_not_staged ".weave/.state.sql.ABC123" "atomic SQL snapshot is ignored"
assert_not_staged ".weave/.nodes.jsonl.ABC123" "atomic node projection is ignored"
assert_not_staged ".weave/.edges.jsonl.ABC123" "atomic edge projection is ignored"
assert_not_staged ".weave/.prune_epoch" "local prune epoch is ignored"

echo "Results: $PASSED/$TESTS passed"
[ "$FAILED" -eq 0 ]
