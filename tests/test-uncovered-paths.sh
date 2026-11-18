#!/usr/bin/env bash
# test-uncovered-paths.sh -- staged files no test route covers are named
# beside the routed ones (wv-da768b).
#
# Owner ruling: when some staged files match a route and others match none,
# the pre-commit gate warns and names the uncovered files; it never refuses
# for that. wv impact --suites --unmatched reports the same files beside the
# suites. With nothing routed, the existing inert notice speaks instead, and
# a fully routed commit says nothing new.
#
# GIT_* is unset first: an exported GIT_DIR would point the scratch
# repositories at the real one (wv-8f1da6).

set -u
while IFS= read -r _v; do unset "$_v"; done < <(env | sed -n 's/^\(GIT_[A-Z_]*\)=.*/\1/p')
export WV_TEST_SUITE=1
export WV_CALL_SOURCE=test

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WV="$REPO_ROOT/scripts/wv"
HOOK="$REPO_ROOT/scripts/hooks/pre-commit-weave.sh"

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export WV_CONFIG_DIR="$T/cfg" WV_AGENT_ID="uncovered-test" WV_REQUIRE_LEARNING=0
export WV_AUTO_CHECKPOINT=0 WV_NONINTERACTIVE=1 WV_LIB_DIR="$REPO_ROOT/scripts"
mkdir -p "$WV_CONFIG_DIR"

pass=0; run=0
ok()  { echo "  ✓ $1"; pass=$((pass + 1)); run=$((run + 1)); }
bad() { echo "  ✗ $1"; [ -z "${2:-}" ] || echo "$2" | sed 's/^/      /'; run=$((run + 1)); }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected: $2"$'\n'"actual:   $3"; fi; }
has()   { if grep -qF -- "$2" <<< "$3"; then ok "$1"; else bad "$1" "missing: $2"$'\n'"$3"; fi; }
hasnt() { if grep -qF -- "$2" <<< "$3"; then bad "$1" "unexpected: $2"$'\n'"$3"; else ok "$1"; fi; }

# A consumer-shaped fixture: src/ routes to one suite, nothing else is mapped,
# and there is no [default] entry.
R="$T/repo"; HZ="$T/hz"
mkdir -p "$R/scripts" "$R/src" "$R/tests" "$R/.weave" "$HZ"; chmod 700 "$HZ"
ln -s "$WV" "$R/scripts/wv"
export WV_PROJECT_DIR="$R" CLAUDE_PROJECT_DIR="$R" WEAVE_DIR="$R/.weave"
export WV_HOT_ZONE="$HZ" WV_DB="$HZ/brain.db"
cd "$R" || exit 1
git init -q && git config user.email t@t && git config user.name t && git config commit.gpgsign false
"$WV" init >/dev/null 2>&1
printf '[map]\nsrc/ = tests/test-a.sh\n' > .weave/test-map.conf
printf '#!/bin/bash\nexit 0\n' > tests/test-a.sh; chmod +x tests/test-a.sh
git add -A && git -c core.hooksPath=/dev/null commit -q -m fixture
"$WV" add "uncovered fixture" --force --criteria=c --risks=low --status=active >/dev/null 2>&1

echo "=== wv impact --suites --unmatched ==="
out=$("$WV" impact --suites --unmatched --files='src/a.py,docs/x "q".md,lib/b.sh' 2>&1)
check "suites beside the unmatched files" \
    '["tests/test-a.sh"]|["docs/x \"q\".md","lib/b.sh"]' \
    "$(jq -c '[.suites[].name]' <<< "$out")|$(jq -c '.unmatched' <<< "$out")"
out=$("$WV" impact --suites --unmatched --files=src/a.py 2>&1)
check "a fully routed set has no unmatched file" '[]' "$(jq -c '.unmatched' <<< "$out")"
out=$("$WV" impact --suites --files=src/a.py,docs.md 2>&1)
check "without --unmatched the output stays the suite array" 'array' "$(jq -r 'type' <<< "$out")"
"$WV" impact --unmatched --files=src/a.py >/dev/null 2>&1
check "--unmatched without --suites is refused" 1 "$?"
printf '[map]\nsrc/ = tests/test-a.sh\n[default]\ntests/test-a.sh\n' > .weave/test-map.conf
out=$("$WV" impact --suites --unmatched --files=src/a.py,docs.md 2>&1)
check "a [default] entry covers every file" '[]' "$(jq -c '.unmatched' <<< "$out")"
git checkout -q .weave/test-map.conf

echo "=== pre-commit gate ==="
printf 'x = 1\n' > src/a.py
printf '# notes\n' > docs.md
git add src/a.py docs.md
out=$(bash "$HOOK" 2>&1); rc=$?
check "a partly routed commit passes: a warning, not a refusal" 0 "$rc"
has "names the staged file no route covers" \
    "no test route covers 1 staged file(s), so no suite tests them: docs.md" "$out"
has "the routed suite still runs" "test-a.sh" "$out"
hasnt "the routed file is not named as uncovered" "them: src/a.py" "$out"

git reset -q docs.md
out=$(bash "$HOOK" 2>&1); rc=$?
check "a fully routed commit passes" 0 "$rc"
hasnt "no uncovered-path warning when every staged file is routed" "no test route covers" "$out"

git reset -q src/a.py
for i in 1 2 3 4 5 6 7; do printf '%s\n' "$i" > "n$i.md"; done
git add src/a.py n?.md
out=$(bash "$HOOK" 2>&1); rc=$?
check "many uncovered files still pass" 0 "$rc"
has "the list is capped and counts the rest" "n5.md, and 2 more" "$out"

git reset -q
git add docs.md
out=$(bash "$HOOK" 2>&1); rc=$?
check "nothing routed passes" 0 "$rc"
has "nothing routed: the inert notice speaks" "impact gate inert" "$out"
hasnt "nothing routed: no second, uncovered-path warning" "no test route covers" "$out"

echo ""
echo "uncovered paths: $pass/$run passed"
[ "$pass" -eq "$run" ]
