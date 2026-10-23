#!/usr/bin/env bash
# Input-keyed suite reuse (wv-cb4913, gate-latency S5).
#
# The gate reuses a suite's green result only for exact frozen execution
# inputs: protected enforcement, provisioning, tools, environment and history,
# plus the frozen conf, suite file and mode/blob of changed files. For
# a suite whose complete input scope is declared under [inputs], the changed
# files in that scope or routed to it; for any other suite, every changed
# file, since routing records which suites catch a planted break, not what a
# suite reads (wv-f0bcc4). Pinned here:
#   - a retry after a one-file fix reruns only the declared suites that file
#     is an input of, and every undeclared selected suite;
#   - reuse never serves a result for different input bytes: a staged blob
#     differing from the tested one, a staged conf edit, a moved base, a deleted
#     input (also one still on disk), a mode change, an unrouted file staged
#     beside an undeclared suite's route, or a failed run all run the suite;
#   - unstaged repairs and map edits cannot change the frozen subject;
#   - a history-independent declaration permits scoped reuse across commits;
#   - the reuse decision is one timed call, reported apart from the suites.
#
# Every wv call runs in the fixture repository with this checkout's wv, and the
# last check proves the ledger rows landed in the fixture's database.
set -uo pipefail
export WV_TEST_SUITE=1  # the user's config.env cannot log this suite's wv calls (wv-6b0f57)
export WV_CALL_SOURCE=test

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOKS="$ROOT/scripts/hooks"

run=0; pass=0
ok()  { run=$((run+1)); pass=$((pass+1)); echo "  ✓ $1"; }
bad() { run=$((run+1)); echo "  ✗ $1"; [ -n "${2:-}" ] && echo "      $2"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2], got [$3]"; fi; }
# Herestrings, not `printf | grep -q`: under pipefail grep leaving early makes
# the writer's SIGPIPE the pipeline's status (tests/test-assert-helper-safety.sh).
has()   { if grep -qF -- "$3" <<< "$2"; then ok "$1"; else bad "$1" "missing [$3] in: $(tail -5 <<< "$2")"; fi; }
hasnt() { if grep -qF -- "$3" <<< "$2"; then bad "$1" "unexpected [$3]"; else ok "$1"; fi; }

T=$(mktemp -d /tmp/wv-input-reuse-XXXXXX)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/cfg" "$T/marks"
ln -s "$ROOT/scripts/wv" "$T/bin/wv"
export PATH="$T/bin:$PATH"
# scripts/wv resolves its modules beside itself, and through a symlink that is
# $T/bin, so without this it falls back to the INSTALLED modules.
export WV_LIB_DIR="$ROOT/scripts"
export WV_HOT_ZONE="$T" WV_DB="$T/brain.db" WV_CONFIG_DIR="$T/cfg" WV_PROJECT_DIR="$T/work"
export WV_SUITE_LOG="$T/suite_runs.jsonl" WV_GATE_LOG="$T/gate_runs.jsonl"
export WV_AUTO_SYNC=0 WV_AUTO_CHECKPOINT=0 WV_REQUIRE_LEARNING=0 WV_RUN_CACHE=0
unset WV_GATE_PHASE WV_GATE_ID WV_GATE_CONTEXT WV_HOOK_REEXEC
unset GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0 GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
MARK="$T/marks"

git init -q --bare "$T/remote.git"
git init -q -b main "$T/work"
cd "$T/work" || exit 1
git config user.name "Gate Test"; git config user.email gate@example.com; git config commit.gpgsign false
git remote add origin "$T/remote.git"
mkdir -p src tests .weave
# Frozen reuse belongs to the self-hosting boundary, not consumer checkout
# mode. Carry the actual protected gate so this still exercises real hooks.
cp -R "$ROOT/scripts" scripts
# Like the gate-lane fixture, this repository owns only scripts/ enforcement;
# source-only external checks are not dependencies of these reuse controls.
jq '.enforcement = ["scripts/"] | .invoking |= map(select(startswith("scripts/")))
    | .entry_points |= with_entries(select(.key | startswith("scripts/"))) | .shared = []' \
    scripts/hooks/gate-roles.json > "$T/fixture-roles.json" &&
    cat "$T/fixture-roles.json" > scripts/hooks/gate-roles.json
# Each suite logs a run and fails when its fail-marker exists.
for s in a b u; do
    printf '#!/bin/sh\necho run >> "%s/%s"\n[ -f "%s/%s-fail" ] && { echo "✗ planted %s failure"; exit 1; }\nexit 0\n' \
        "$MARK" "$s" "$MARK" "$s" "$s" > "tests/test-$s.sh"
    chmod +x "tests/test-$s.sh"
done
cat > .weave/test-map.conf <<'EOF'
[map]
src/a.sh = tests/test-a.sh
src/b.sh = tests/test-b.sh
src/c.sh = tests/test-a.sh
tests/test-a.sh = tests/test-a.sh
tests/test-b.sh = tests/test-b.sh
src/u.sh = tests/test-u.sh
[inputs]
tests/test-a.sh = src/a.sh src/c.sh tests/test-a.sh
tests/test-b.sh = src/b.sh tests/test-b.sh
EOF
printf '#!/bin/sh\necho a\n' > src/a.sh
printf '#!/bin/sh\necho b\n' > src/b.sh
printf '#!/bin/sh\necho c\n' > src/c.sh
printf '#!/bin/sh\necho u\n' > src/u.sh
printf 'helper\n' > src/x.sh
printf 'notes\n' > README
git add -A && git -c core.hooksPath=/dev/null commit -q -m "fixture"
wv add "reuse fixture node" --status=active --force --criteria="c1|c2" --risks=low >/dev/null 2>&1

runs() { [ -f "$MARK/$1" ] && wc -l < "$MARK/$1" | tr -d ' ' || echo 0; }
reset_runs() { rm -f "$MARK/a" "$MARK/b" "$MARK/u"; }
precommit() {
    set +e
    OUT=$(bash "$HOOKS/pre-commit-weave.sh" 2>&1)
    RC=$?
    set -e
}
commit_nohook() { git -c core.hooksPath=/dev/null commit -q -m "$1"; }
state() { wv test-status --inputs --suites="$1" ${2:+"$2"} 2>/dev/null | cut -f1; }
set -e

echo "router: [inputs] declares scopes, never routes"
check "a suite file named in [inputs] still routes only to itself" "tests/test-a.sh" \
    "$(wv impact --suites --files=tests/test-a.sh 2>/dev/null | jq -r '[.[].name] | sort | join(" ")')"

echo "test-status --inputs: states and usage"
printf '#!/bin/sh\necho a2\n' > src/a.sh
check "a suite with no row is unknown" "unknown" "$(state tests/test-a.sh)"
out=$(wv test-status --inputs --suites=tests/test-a.sh,tests/test-b.sh 2>/dev/null || true)
check "one line per suite, in order" "tests/test-a.sh tests/test-b.sh" "$(cut -f3 <<< "$out" | paste -sd ' ' -)"
check "each key is a 40-hex hash" "2" "$(cut -f2 <<< "$out" | grep -cE '^[0-9a-f]{40}$')"
key_a=$(awk -F'\t' '$3 == "tests/test-a.sh" { print $2 }' <<< "$out")
wv test-record tests/test-a.sh --exit=0 --inputs-key="$key_a" >/dev/null 2>&1
check "a green row for the current key is green" "green" "$(state tests/test-a.sh)"
check "...and only for that suite" "unknown" "$(state tests/test-b.sh)"
check "the unstaged edit is not what the index holds: staged is stale" "stale" "$(state tests/test-a.sh --staged)"
wv test-record tests/test-a.sh --exit=1 --inputs-key="$key_a" >/dev/null 2>&1
check "a failed run on the current key is red" "red" "$(state tests/test-a.sh)"
set +e; wv test-status --inputs >/dev/null 2>&1; rc=$?; set -e
check "--inputs without --suites is a usage error" "2" "$rc"
for i in $(seq 1 25); do wv test-record tests/test-b.sh --exit=0 --inputs-key="k$i" >/dev/null 2>&1; done
check "the ledger keeps the newest 20 keys per suite" "20 k25" \
    "$(sqlite3 "$T/brain.db" "SELECT COUNT(*) FROM test_results WHERE suite='tests/test-b.sh' AND path LIKE '@inputs:%';") $(
       sqlite3 "$T/brain.db" "SELECT fingerprint FROM test_results WHERE suite='tests/test-b.sh' AND path LIKE '@inputs:%' ORDER BY ran_at DESC, rowid DESC LIMIT 1;")"
wv test-record tests/test-b.sh --exit=0 --inputs-key=changed-during-run >/dev/null 2>&1
check "...and records no key for a run whose inputs moved under it" "0" \
    "$(sqlite3 "$T/brain.db" "SELECT COUNT(*) FROM test_results WHERE path = '@inputs:changed-during-run';")"
sqlite3 "$T/brain.db" "DELETE FROM test_results WHERE suite='tests/test-b.sh';"
git checkout -q -- src/a.sh

echo "pre-commit: a retry after a one-file fix reruns only what that file routes to"
printf '#!/bin/sh\necho a3\n' > src/a.sh
printf '#!/bin/sh\necho b3\n' > src/b.sh
git add src/a.sh src/b.sh
touch "$MARK/b-fail"; reset_runs; precommit
check "the first attempt fails on test-b" "1" "$RC"
check "...having run test-a" "1" "$(runs a)"
has "...and times the reuse decision apart from the suites" "$OUT" "reuse check: 2 suite(s) in"
rm -f "$MARK/b-fail"
printf '#!/bin/sh\necho b4\n' > src/b.sh; git add src/b.sh
reset_runs; precommit
check "the retry passes" "0" "$RC"
check "...reusing test-a, whose inputs did not change" "0" "$(runs a)"
has "...and says so" "$OUT" "reusing fresh green result for tests/test-a.sh (exact frozen execution inputs)"
check "...and running test-b, whose input did" "1" "$(runs b)"

echo "pre-commit: reuse never serves a result for different input bytes"
reset_runs; precommit
check "an unchanged retry reuses both" "0 0" "$(runs a) $(runs b)"
printf '#!/bin/sh\necho a5\n' > src/a.sh
reset_runs; precommit
check "an unstaged edit leaves the staged bytes' green result standing" "0" "$(runs a)"
printf '# routing note\n' >> .weave/test-map.conf
reset_runs; precommit
check "an unstaged map edit cannot change frozen reuse" "0 0" "$(runs a) $(runs b)"
git add .weave/test-map.conf
reset_runs; precommit
check "a staged map edit reruns every suite" "1 1" "$(runs a) $(runs b)"
git checkout -q -- src/a.sh
reset_runs; precommit
check "restoring only checkout bytes leaves frozen results reusable" "0" "$(runs a)"
reset_runs; precommit
check "...and are reused after that" "0" "$(runs a)"
git rm -q --cached src/c.sh; rm -f src/c.sh
reset_runs; precommit
check "a deleted routed input reruns its suite, not the other" "1 0" "$(runs a) $(runs b)"
git checkout -q HEAD -- src/c.sh
# The frozen suite cannot see a deleted input left in the checkout. A new
# a.sh distinguishes this combination from the earlier deletion's green key.
printf '#!/bin/sh\necho a9\n' > src/a.sh; git add src/a.sh
git rm -q --cached src/c.sh
reset_runs; precommit
check "a deletion still on disk runs its suite" "1" "$(runs a)"
reset_runs; precommit
check "...and is reused: the frozen suite never read the checkout copy" "0" "$(runs a)"
git add src/c.sh
printf '#!/bin/sh\necho a3\n' > src/a.sh; git add src/a.sh
reset_runs; precommit
check "restoring it returns to bytes already green: reused" "0" "$(runs a)"
commit_nohook "change a and b"
# The base pins every input the changed set does not list. Commit a routed
# input (c) under a staged one (a): the changed set is {a} before and after,
# so only the base can tell the key that c's bytes moved.
printf '#!/bin/sh\necho a8\n' > src/a.sh; git add src/a.sh
reset_runs; precommit
check "test-a runs for a staged change" "1" "$(runs a)"
reset_runs; precommit
check "...and its frozen result is reused" "0" "$(runs a)"
printf '#!/bin/sh\necho c9\n' > src/c.sh
git -c core.hooksPath=/dev/null commit -q -m "c only" -- src/c.sh
check "...the commit kept a staged" "src/a.sh" "$(git diff --cached --name-only)"
reset_runs; precommit
check "no upstream: a committed input under a staged one reruns its suite" "1" "$(runs a)"
git -c core.hooksPath=/dev/null commit -q -m "a8"

echo "pre-commit: upstream routing and conservative history-bound snapshot reuse"
git -c core.hooksPath=/dev/null push -q origin main 2>/dev/null
git branch -q --set-upstream-to=origin/main main
printf '#!/bin/sh\necho a6\n' > src/a.sh; git add src/a.sh
reset_runs; precommit
check "test-a runs for its change" "1" "$(runs a)"
commit_nohook "change a on top"
printf '#!/bin/sh\necho b6\n' > src/b.sh; git add src/b.sh
printf '#!/bin/sh\necho a6\n' > src/a.sh
reset_runs; precommit
check "the next commit (b only) runs test-b" "1" "$(runs b)"
check "...and does not select test-a" "0" "$(runs a)"
check "snapshot results do not certify legacy content-only keys" "stale" "$(state tests/test-a.sh --staged)"
printf '#!/bin/sh\necho a7\n' > src/a.sh; git add src/a.sh
reset_runs; precommit
check "...and a changed scoped input reruns its suite" "1" "$(runs a)"
git checkout -q HEAD -- src/a.sh

echo "pre-commit: undeclared suites key on every changed file (wv-f0bcc4)"
# src/x.sh routes nowhere, as prose_shape.py did for test-quality.sh although
# the module that selects it imports it. Staged beside src/u.sh, it is tested
# by test-u's run, so an edit to it must rerun test-u.
printf '#!/bin/sh\necho u2\n' > src/u.sh; printf 'helper 2\n' > src/x.sh
git add src/u.sh src/x.sh
reset_runs; precommit
check "test-u runs for its route" "1" "$(runs u)"
printf 'helper 3\n' > src/x.sh; git add src/x.sh
reset_runs; precommit
check "an edit to an unrouted file staged with it reruns the undeclared suite" "1" "$(runs u)"
printf 'helper 4\n' > src/x.sh; git add src/x.sh
reset_runs; precommit
check "a second unrouted edit cannot reuse the undeclared suite" "1" "$(runs u)"
chmod +x src/a.sh; git add src/a.sh
reset_runs; precommit
check "a mode-only input change reruns its suite" "1" "$(runs a)"

echo "frozen snapshot keys have a separate ledger namespace"
python3 -I "$ROOT/scripts/lib/wv-gate-suite.py" --repo "$PWD" \
    --tree "$(git write-tree)" --base "$(git rev-parse HEAD)" \
    --describe --work "$T/description" --provenance "$T/snapshot-plan.json" tests/test-a.sh
snapshot_state() {
    wv test-status --inputs --suites=tests/test-a.sh --snapshot-plan="$T/snapshot-plan.json" | cut -f1
}
check "legacy live-checkout green cannot certify a snapshot" "stale" "$(snapshot_state)"
snapshot_key=$(jq -r '.suites["tests/test-a.sh"].key' "$T/snapshot-plan.json")
wv test-record tests/test-a.sh --inputs-key="$snapshot_key" --exit=0 >/dev/null
check "a recorded frozen key is available independently of legacy rows" "green" "$(snapshot_state)"
wv test-record tests/test-a.sh --inputs-key="$snapshot_key" --exit=1 >/dev/null
check "a failed snapshot replaces its own green result" "red" "$(snapshot_state)"
printf '{"suites":{}}\n' > "$T/snapshot-plan.json"
snapshot_rc=0
wv test-status --inputs --suites=tests/test-a.sh --snapshot-plan="$T/snapshot-plan.json" \
    > "$T/missing-plan.out" 2>&1 || snapshot_rc=$?
check "an incomplete plan refuses instead of falling back to a legacy key" "1" "$snapshot_rc"

echo "isolation"
check "ledger rows landed in the fixture's database" "yes" \
    "$( [ "$(sqlite3 "$T/brain.db" "SELECT COUNT(*) FROM test_results WHERE path LIKE '@inputs:%';" 2>/dev/null)" -gt 0 ] && echo yes || echo no)"

echo ""
echo "Results: $pass/$run passed"
[ "$pass" -eq "$run" ]
