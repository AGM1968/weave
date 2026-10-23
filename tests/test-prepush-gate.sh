#!/usr/bin/env bash
# The two-tier commit gate (wv-862ac0, gate-latency S4).
#
# A suite in the [heavy] section of .weave/test-map.conf leaves the blocking
# pre-commit gate for the pre-push gate, which runs every heavy suite any pushed
# commit selects, against the pushed tip, and refuses the push until each is
# green (owner decision 2026-09-26). Properties pinned here:
#   - [heavy] changes the tier, never the routing;
#   - pre-commit defers heavy suites ONLY when a Weave pre-push hook is
#     installed, so no suite that used to block can be skipped on the way out;
#   - pre-push runs what is owed, reruns mutable consumer checkout tools,
#     refuses red, refuses a tree or ref that is not the tip, and sees a suite
#     owed by an earlier commit even when a later one reverted the file;
#   - bootstrap readiness reports the heavy tier as clear, pending, red, green.
#
# Every wv call runs with the fixture repository as cwd and a PATH whose wv is
# this checkout's: the installed wv may predate [heavy], and a hot zone owned by
# another repository is refused as a leaked override (wv-5e804e). The last check proves
# the ledger rows landed in the fixture's DB, not the live graph.
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

T=$(mktemp -d /tmp/wv-prepush-XXXXXX)
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
# The commit gate runs suites with core.hooksPath=/dev/null in GIT_CONFIG_*;
# inherited, it points the fixture's hooks there too, and the pre-commit hook
# rightly finds no pre-push gate. The fixture states its own git config.
unset GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0 GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
MARK="$T/marks"

git init -q --bare "$T/remote.git"
git init -q -b main "$T/work"
cd "$T/work" || exit 1
git config user.name "Gate Test"; git config user.email gate@example.com; git config commit.gpgsign false
# Git's default since 2.9, set so a user config cannot hide the rename cases.
git config diff.renames true
git remote add origin "$T/remote.git"
mkdir -p src tests .weave
# Each suite logs a run and the gate base it was handed (wv-bab095), and fails
# when its fail-marker exists.
for s in light heavy; do
    printf '#!/bin/sh\necho run >> "%s/%s"\necho "${WV_GATE_BASE-unset}" > "%s/%s.base"\n[ -f "%s/%s-fail" ] && { echo "✗ planted %s failure"; exit 1; }\nexit 0\n' \
        "$MARK" "$s" "$MARK" "$s" "$MARK" "$s" "$s" > "tests/test-$s.sh"
    chmod +x "tests/test-$s.sh"
done
cat > .weave/test-map.conf <<'EOF'
[map]
src/a.sh = tests/test-light.sh tests/test-heavy.sh
src/b.sh = tests/test-light.sh
tests/test-light.sh = tests/test-light.sh
tests/test-heavy.sh = tests/test-heavy.sh
[heavy]
tests/test-heavy.sh
EOF
printf '#!/bin/sh\necho a\n' > src/a.sh
printf '#!/bin/sh\necho b\n' > src/b.sh
git add -A && git -c core.hooksPath=/dev/null commit -q -m "fixture"
git -c core.hooksPath=/dev/null push -q origin main 2>/dev/null
wv add "gate fixture node" --status=active --force --criteria="c1|c2" --risks=low >/dev/null 2>&1

runs() { [ -f "$MARK/$1" ] && wc -l < "$MARK/$1" | tr -d ' ' || echo 0; }
reset_runs() { rm -f "$MARK/light" "$MARK/heavy" "$MARK/light.base" "$MARK/heavy.base"; }
base_seen() { cat "$MARK/$1.base" 2>/dev/null || echo none; }
# prepush [ref-sha] [remote-sha] — drive the hook as git would for main.
prepush() {
    local lsha="${1:-$(git rev-parse HEAD)}" rsha="${2:-$(git rev-parse origin/main 2>/dev/null)}"
    set +e
    OUT=$(bash "$HOOKS/pre-push-weave.sh" origin "$T/remote.git" \
        < <(printf 'refs/heads/main %s refs/heads/main %s\n' "$lsha" "$rsha") 2>&1)
    RC=$?
    set -e
}
precommit() {
    set +e
    OUT=$(bash "$HOOKS/pre-commit-weave.sh" 2>&1)
    RC=$?
    set -e
}
commit_nohook() { git add -A && git -c core.hooksPath=/dev/null commit -q -m "$1"; }
set -e

echo "resolver: [heavy] is a tier, not a route"
tiers=$(wv impact --suites --files=src/a.sh 2>/dev/null | jq -r 'sort_by(.name) | map("\(.name)=\(.tier)") | join(" ")')
check "a [heavy] suite resolves as heavy, the rest as light" \
    "tests/test-heavy.sh=heavy tests/test-light.sh=light" "$tiers"
cp .weave/test-map.conf "$T/map.bak"; sed -i '/^\[heavy\]/,$d' .weave/test-map.conf
check "removing [heavy] changes no route" "tests/test-heavy.sh tests/test-light.sh" \
    "$(wv impact --suites --files=src/a.sh 2>/dev/null | jq -r '[.[].name] | sort | join(" ")')"
cp "$T/map.bak" .weave/test-map.conf

echo "pre-commit: defer only to an installed pre-push gate"
printf '#!/bin/sh\necho a2\n' > src/a.sh; git add src/a.sh
reset_runs; precommit
check "no pre-push hook: the commit gate passes" "0" "$RC"
has "...and says it runs the heavy suite itself" "$OUT" "no Weave pre-push gate installed"
check "...and does run it" "1" "$(runs heavy)"
# Present and marked but not executable: git skips it, so it is no gate to
# defer to (wv-ecae1c).
cp "$HOOKS/pre-push-weave.sh" .git/hooks/pre-push; chmod -x .git/hooks/pre-push
printf '#!/bin/sh\necho a2x\n' > src/a.sh; git add src/a.sh
reset_runs; precommit
check "non-executable pre-push hook: the commit gate passes" "0" "$RC"
has "...and runs the heavy suite itself" "$OUT" "no Weave pre-push gate installed"
check "...and does run it" "1" "$(runs heavy)"
rm -f .git/hooks/pre-push
# The hooks git runs are where core.hooksPath says, not .git/hooks.
mkdir -p "$T/custom-hooks"; cp "$HOOKS/pre-push-weave.sh" "$T/custom-hooks/pre-push"; chmod +x "$T/custom-hooks/pre-push"
git config core.hooksPath "$T/custom-hooks"
printf '#!/bin/sh\necho a2h\n' > src/a.sh; git add src/a.sh
reset_runs; precommit
check "pre-push gate under core.hooksPath: the commit gate passes" "0" "$RC"
check "...and defers the heavy suite to it" "0" "$(runs heavy)"
git config --unset core.hooksPath; rm -rf "$T/custom-hooks"
cp "$HOOKS/pre-push-weave.sh" .git/hooks/pre-push; chmod +x .git/hooks/pre-push
printf '#!/bin/sh\necho a3\n' > src/a.sh; git add src/a.sh
# An inherited WV_GATE_BASE must not reach the suites: the gate names HEAD.
reset_runs; WV_GATE_BASE=0123456789abcdef0123456789abcdef01234567 precommit
check "pre-push installed: the commit gate passes" "0" "$RC"
has "...names the deferred heavy suite" "$OUT" "deferred to the pre-push gate (heavy tier): tests/test-heavy.sh"
check "...does not run it" "0" "$(runs heavy)"
check "...still runs the light suite" "1" "$(runs light)"
check "...handing it HEAD as the gate base, not an inherited one" "$(git rev-parse HEAD)" "$(base_seen light)"
git -c core.hooksPath=/dev/null commit -q -m "change a"

echo "pre-push: the heavy tier gates the tip"
reset_runs; WV_GATE_BASE=0123456789abcdef0123456789abcdef01234567 prepush
check "an owed heavy suite runs at push and the push passes" "0" "$RC"
check "...it ran once" "1" "$(runs heavy)"
check "...with the real tip as base, not the inherited one" "$(git rev-parse HEAD)" "$(base_seen heavy)"
has "...and the hook says the tier is green" "$OUT" "heavy tier green for"
hasnt "...the light suite is not re-run at push" "$(runs light)" "1"
reset_runs; prepush
check "a retried push of the same content passes" "0" "$RC"
check "...rerunning the consumer suite despite unchanged content" "1" "$(runs heavy)"
has "...and says why" "$OUT" "checkout inputs are mutable: reuse disabled"

printf '#!/bin/sh\necho a4\n' > src/a.sh; commit_nohook "change a again"
touch "$MARK/heavy-fail"; reset_runs; prepush
check "a red heavy suite refuses the push" "1" "$RC"
has "...naming the suite" "$OUT" "tests/test-heavy.sh failed (exit 1)"
has "...and replaying its failure" "$OUT" "planted heavy failure"
rm -f "$MARK/heavy-fail"

printf '#!/bin/sh\necho dirty\n' > src/b.sh
reset_runs; prepush
check "a tracked file differing from the tip refuses the push" "1" "$RC"
has "...and names it" "$OUT" "src/b.sh"
check "...before running anything" "0" "$(runs heavy)"
git checkout -q -- src/b.sh

prepush "$(git rev-parse HEAD~1)"
check "pushing a ref that is not HEAD refuses when heavy suites are owed" "1" "$RC"
has "...and says why" "$OUT" "is not HEAD"

reset_runs; prepush
check "the fixed tip then pushes" "0" "$RC"
git -c core.hooksPath=/dev/null push -q origin main 2>/dev/null

printf '#!/bin/sh\necho b2\n' > src/b.sh; commit_nohook "change b"
reset_runs; prepush
check "a push selecting only light suites passes" "0" "$RC"
has "...without a heavy run" "$OUT" "no heavy-tier suite selected"
git -c core.hooksPath=/dev/null push -q origin main 2>/dev/null

# Owed by an earlier commit, reverted by a later one: still owed.
orig=$(cat src/a.sh)
printf '#!/bin/sh\necho a5\n' > src/a.sh; commit_nohook "touch a"
printf '%s\n' "$orig" > src/a.sh; commit_nohook "revert a"
reset_runs; prepush
# What matters is that the suite was owed at all. It runs: its input key is
# pinned to a base commit (wv-cb4913), and HEAD, the base without an upstream,
# has moved since the green run on the same bytes, so that row is not reused.
check "a suite owed by an earlier pushed commit is owed even though a later one reverted the file" \
    "1" "$(runs heavy)"
hasnt "...not dismissed as unselected" "$OUT" "no heavy-tier suite selected"
git -c core.hooksPath=/dev/null push -q origin main 2>/dev/null

echo "renames: the old path still routes (wv-29d13c)"
# Rename detection lists only the new path. src/c.sh routes nowhere, so a
# git mv of a routed file used to select nothing at either gate.
# Under a HOME whose installed lib dir holds a decoy: a hook run from this
# checkout must load the helpers beside it, never the installed copies, or a
# source fix is not what gates (the fixture repo has no scripts/lib).
DECOY="$T/decoy-home/.local/lib/weave/lib"
mkdir -p "$DECOY"
printf ':\n' > "$DECOY/wv-config.sh"
# shellcheck disable=SC2016  # writes a script whose $ expands when that script runs
printf 'wv_staged_non_graph_state() { echo "DECOY-INSTALLED-LIB" >&2; git -C "$1" diff --cached --name-only; }\n' \
    > "$DECOY/wv-checkpoint-ci.sh"
git mv src/a.sh src/c.sh
reset_runs
set +e; OUT=$(HOME="$T/decoy-home" bash "$HOOKS/pre-commit-weave.sh" 2>&1); RC=$?; set -e
hasnt "pre-commit loads the helpers beside the hook, not the installed ones" "$OUT" "DECOY-INSTALLED-LIB"
check "pre-commit: a git mv of a routed file passes" "0" "$RC"
check "...and runs the suite the old path routes to" "1" "$(runs light)"
has "...deferring the heavy one it owes" "$OUT" "deferred to the pre-push gate (heavy tier): tests/test-heavy.sh"
git -c core.hooksPath=/dev/null commit -q -m "rename a"
# Bootstrap's heavy-tier report lists the same unpushed range; without
# --no-renames it saw only src/c.sh and reported clear while pre-push owed
# test-heavy (found by the git-listing-rename-blind rule, wv-581bb0).
# The report needs an upstream; scope one to this check so later sections see
# the fixture as before. Without it the report is null and the check is vacuous.
git branch -q --set-upstream-to=origin/main main 2>/dev/null
b=$(wv bootstrap --json 2>/dev/null)
check "bootstrap: the heavy-tier report ran (precondition)" "object" "$(jq -r '.readiness.heavy_tier | type' <<< "$b")"
has "bootstrap: the unpushed rename owes the old path's heavy suite" \
    "$(jq -r '[.readiness.heavy_tier.suites[]?.suite] | join(" ")' <<< "$b")" "tests/test-heavy.sh"
git branch -q --unset-upstream main 2>/dev/null
reset_runs; prepush
hasnt "pre-push: the rename owes the old path's heavy suite" "$OUT" "no heavy-tier suite selected"
check "...which runs" "1" "$(runs heavy)"
git mv src/c.sh src/a.sh; commit_nohook "rename a back"
git -c core.hooksPath=/dev/null push -q origin main 2>/dev/null

echo "pre-push: new branch and graph-only pushes"
git checkout -q -b topic
printf '#!/bin/sh\necho a6\n' > src/a.sh; commit_nohook "topic change"
reset_runs
set +e
OUT=$(bash "$HOOKS/pre-push-weave.sh" origin "$T/remote.git" \
    < <(printf 'refs/heads/topic %s refs/heads/topic %s\n' "$(git rev-parse HEAD)" "0000000000000000000000000000000000000000") 2>&1); RC=$?
set -e
check "a new branch is gated on commits the remote lacks" "0" "$RC"
check "...running only what those commits owe" "1" "$(runs heavy)"
git checkout -q main

mkdir -p .weave/deltas; echo "-- graph" > .weave/deltas/x.sql; commit_nohook "graph only"
reset_runs; prepush
check "a graph-state-only push passes without running anything" "0" "$RC"
check "...and runs no suite" "0" "$(runs heavy)"
git -c core.hooksPath=/dev/null push -q origin main 2>/dev/null

# pushlines <remote-name> <line>... — drive the hook with explicit stdin lines.
pushlines() {
    local remote="$1"; shift
    set +e
    OUT=$(bash "$HOOKS/pre-push-weave.sh" "$remote" "$T/remote.git" 2>&1 < <(printf '%s\n' "$@"))
    RC=$?
    set -e
}
ZERO=0000000000000000000000000000000000000000

echo "pre-push: tags and several refs (ultrareview #4575)"
printf '#!/bin/sh\necho t1\n' > src/a.sh; commit_nohook "a for tags 1"
git tag -a v-old -m "older release"
printf '#!/bin/sh\necho t2\n' > src/a.sh; commit_nohook "a for tags 2"
git tag -a v-head -m "release"
reset_runs
pushlines origin "refs/tags/v-head $(git rev-parse v-head) refs/tags/v-head $ZERO"
check "an annotated tag on HEAD pushes (its tag object is peeled to the commit)" "0" "$RC"
has "...after running the heavy tier it owes" "$OUT" "heavy tier green for"
pushlines origin "refs/tags/v-old $(git rev-parse v-old) refs/tags/v-old $ZERO"
check "an annotated tag on an older commit owing heavy suites is refused" "1" "$RC"
has "...naming the tag" "$OUT" "refs/tags/v-old is not HEAD"
git checkout -q -b side origin/main
printf '#!/bin/sh\necho side\n' > src/b.sh; commit_nohook "side: light-only change"
side=$(git rev-parse HEAD)
git checkout -q main
reset_runs
pushlines origin "refs/heads/main $(git rev-parse HEAD) refs/heads/main $(git rev-parse origin/main)" \
    "refs/heads/side $side refs/heads/side $ZERO"
check "a second pushed ref that owes no heavy suite does not block the push" "0" "$RC"
hasnt "...and is not called 'not HEAD'" "$OUT" "refs/heads/side is not HEAD"
pushlines origin "refs/heads/main $(git rev-parse HEAD) refs/heads/main $(git rev-parse origin/main)" \
    "refs/tags/v-old $(git rev-parse v-old) refs/tags/v-old $ZERO"
check "two refs owing heavy suites that are not both HEAD are refused" "1" "$RC"
pushlines nosuchremote "refs/heads/main $(git rev-parse HEAD) refs/heads/main $ZERO"
has "a remote with no remote-tracking refs is reported, not guessed around" "$OUT" \
    "no remote-tracking refs for 'nosuchremote'"
git -c core.hooksPath=/dev/null push -q origin main 2>/dev/null

# From here, exercise frozen observations in a self-hosting fixture, not a
# consumer. Like the gate-lane fixture, it owns scripts/ enforcement only.
cp -R "$ROOT/scripts" scripts
jq '.enforcement = ["scripts/"] | .invoking |= map(select(startswith("scripts/")))
    | .entry_points |= with_entries(select(.key | startswith("scripts/"))) | .shared = []' \
    scripts/hooks/gate-roles.json > "$T/fixture-roles.json" &&
    cat "$T/fixture-roles.json" > scripts/hooks/gate-roles.json
commit_nohook "self-hosting observation fixture"
git -c core.hooksPath=/dev/null push -q origin main 2>/dev/null

echo "bootstrap: readiness reports the self-hosting heavy tier"
git branch -q --set-upstream-to=origin/main main 2>/dev/null
check "nothing unpushed: clear" "clear" "$(wv bootstrap --json 2>/dev/null | jq -r '.readiness.heavy_tier.state')"
printf '#!/bin/sh\necho a7\n' > src/a.sh; commit_nohook "unpushed a"
b=$(wv bootstrap --json 2>/dev/null)
check "an unpushed commit owing a heavy suite: pending" "pending" "$(jq -r '.readiness.heavy_tier.state' <<< "$b")"
has "...with an advisory" "$(jq -r '.readiness.advisories | join("\n")' <<< "$b")" "heavy tier pending for commits not on origin/main: tests/test-heavy.sh"
legacy_key=$(wv test-status --inputs --suites=tests/test-heavy.sh | cut -f2)
wv test-record tests/test-heavy.sh --inputs-key="$legacy_key" --exit=0 >/dev/null
check "legacy green alone is not a frozen observation" "pending" "$(wv bootstrap --json 2>/dev/null | jq -r '.readiness.heavy_tier.state')"
touch "$MARK/heavy-fail"; prepush; rm -f "$MARK/heavy-fail"
b=$(wv bootstrap --json 2>/dev/null)
check "after a red pre-push run: red" "red" "$(jq -r '.readiness.heavy_tier.state' <<< "$b")"
has "...with a fix-first advisory" "$(jq -r '.readiness.advisories | join("\n")' <<< "$b")" "last frozen attempt failed; fix before other work"
prepush
b=$(wv bootstrap --json 2>/dev/null)
check "after a green pre-push run: green" "green" "$(jq -r '.readiness.heavy_tier.state' <<< "$b")"
check "readiness names its observational basis" "snapshot-observation" "$(jq -r '.readiness.heavy_tier.basis' <<< "$b")"
check "readiness does not certify current execution inputs" "unverified" "$(jq -r '.readiness.heavy_tier.execution_inputs' <<< "$b")"
sqlite3 "$WV_DB" "DELETE FROM test_results WHERE path LIKE '@inputs:%';"
reset_runs; prepush
check "an observation alone cannot authorize snapshot reuse" "1" "$(runs heavy)"
check "...the suite still has to pass" "0" "$RC"
printf '# staged-only difference\n' >> src/a.sh; git add src/a.sh
git show HEAD:src/a.sh > src/a.sh
check "opposite staged/unstaged edits do not preserve observation readiness" "pending" \
    "$(wv bootstrap --json 2>/dev/null | jq -r '.readiness.heavy_tier.state')"
git reset -q HEAD -- src/a.sh
cp .weave/test-map.conf "$T/map.bak"; sed -i 's/^\[heavy\]$/  [heavy]/' .weave/test-map.conf
# The edited map is an input of the suite, so the green row no longer applies;
# what matters is that the tier is reported at all, not dropped as null.
check "an indented [heavy] header still reports the tier (N3, wv-ee5e36)" "pending" \
    "$(wv bootstrap --json 2>/dev/null | jq -r '.readiness.heavy_tier.state')"
cp "$T/map.bak" .weave/test-map.conf
git -c core.hooksPath=/dev/null commit -q --allow-empty -m "new history, same tree"
check "an unchanged tree at a new base does not inherit the observation" "pending" \
    "$(wv bootstrap --json 2>/dev/null | jq -r '.readiness.heavy_tier.state')"

echo "R2: each pushed commit owes what its own gate deferred (wv-418d4c)"
r2_map() {
    cat > .weave/test-map.conf <<'R2MAP_EOF'
[map]
src/a.sh = tests/test-light.sh tests/test-heavy.sh
src/b.sh = tests/test-light.sh
tests/test-light.sh = tests/test-light.sh
tests/test-heavy.sh = tests/test-heavy.sh
[heavy]
tests/test-heavy.sh
R2MAP_EOF
}
published() { git -c core.hooksPath=/dev/null push -q origin main 2>/dev/null; }
# A restore may leave the map as committed: an empty commit keeps set -e quiet.
r2_commit() { git add -A && git -c core.hooksPath=/dev/null commit -q --allow-empty -m "$1"; }
r2_map; r2_commit "r2 baseline map"; published
# The review's reproduction: the commit drops a's heavy route but keeps the
# [heavy] declaration; its own gate routes by both maps and defers the suite.
printf '#!/bin/sh\necho r2a\n' > src/a.sh
sed -i 's|^src/a.sh = .*|src/a.sh = tests/test-light.sh|' .weave/test-map.conf
git add -A; reset_runs; precommit
has "(control) pre-commit defers the baseline route's heavy suite" "$OUT" "deferred to the pre-push gate (heavy tier): tests/test-heavy.sh"
commit_nohook "drop a's heavy route"; reset_runs; prepush
check "pre-push runs the suite that commit deferred" "1" "$(runs heavy)"
check "...and passes" "0" "$RC"
published; r2_map; r2_commit "r2 map again"; published
# A route one pushed commit creates and a later one removes.
printf '#!/bin/sh\necho r2b\n' > src/b.sh
sed -i 's|^src/b.sh = .*|src/b.sh = tests/test-light.sh tests/test-heavy.sh|' .weave/test-map.conf
commit_nohook "route b to heavy"
sed -i 's|^src/b.sh = .*|src/b.sh = tests/test-light.sh|' .weave/test-map.conf
commit_nohook "unroute b"
reset_runs; prepush
check "a route created and then removed within the push still runs its suite" "1" "$(runs heavy)"
published
# The tip drops the whole [heavy] section after a commit that deferred.
printf '#!/bin/sh\necho r2c\n' > src/a.sh; commit_nohook "a owes heavy"
sed -i '/^\[heavy\]/,$d' .weave/test-map.conf; commit_nohook "drop the heavy section"
reset_runs; prepush
check "a tip without [heavy] still pays what an earlier pushed commit deferred" "1" "$(runs heavy)"
published; r2_map; r2_commit "r2 map restored"; published

echo "N3 (wv-ee5e36): an indented [heavy] header declares the tier, as the router reads it"
sed -i 's/^\[heavy\]$/  [heavy]/' .weave/test-map.conf; commit_nohook "indent the heavy header"; published
check "(precondition) the router reads the indented header as heavy" \
    "tests/test-heavy.sh=heavy tests/test-light.sh=light" \
    "$(wv impact --suites --files=src/a.sh 2>/dev/null | jq -r 'sort_by(.name) | map("\(.name)=\(.tier)") | join(" ")')"
printf '#!/bin/sh\necho n3\n' > src/a.sh; commit_nohook "a owes heavy under an indented header"
touch "$MARK/heavy-fail"; reset_runs; prepush
check "a failing heavy suite under an indented header refuses the push" "1" "$RC"
hasnt "...not dismissed as unselected" "$OUT" "no heavy-tier suite selected"
rm -f "$MARK/heavy-fail"
published; r2_map; r2_commit "r2 map restored"; published

echo "N4 (wv-87032c): what excuses or stands in for an owed suite is the pushed tree's"
cp tests/test-heavy.sh "$T/heavy.keep"
git rm -q tests/test-heavy.sh; printf '#!/bin/sh\necho n4\n' > src/a.sh; commit_nohook "drop the heavy suite, keep its route"
reset_runs; prepush
check "(control) a deleted heavy suite that is still routed refuses the push" "1" "$RC"
printf 'review tests/test-heavy.sh = src/\n' > .weave/test-map-retired.conf
reset_runs; prepush
check "an untracked retirement catalogue does not excuse it" "1" "$RC"
hasnt "...nor reports the suite retired" "$OUT" "absent and retired"
rm -f .weave/test-map-retired.conf; cp "$T/heavy.keep" tests/test-heavy.sh
reset_runs; prepush
check "an untracked copy of the deleted suite does not stand in for it" "1" "$RC"
check "...and is not run" "0" "$(runs heavy)"
rm -f tests/test-heavy.sh
printf 'review tests/test-heavy.sh = src/\n' > .weave/test-map-retired.conf; commit_nohook "retire the heavy suite"
reset_runs; prepush
check "(control) a retirement the pushed tree holds excuses the absence" "0" "$RC"
has "...and says so" "$OUT" "absent and retired"
published
git rm -q .weave/test-map-retired.conf; cp "$T/heavy.keep" tests/test-heavy.sh
r2_map; r2_commit "heavy suite restored"; published

echo "F2 (wv-6b31d9): a git listing that fails is an error, never an empty answer"
# A git that fails one call with status 128 and passes everything else through,
# the review's injection.
REAL_GIT=$(command -v git)
mkdir -p "$T/gitfail"
cat > "$T/gitfail/git" <<GITFAIL_EOF
#!/bin/sh
case " \$* " in *" \$(cat "$T/gitfail/when" 2>/dev/null) "*) [ -s "$T/gitfail/when" ] && exit 128 ;; esac
exec "$REAL_GIT" "\$@"
GITFAIL_EOF
chmod +x "$T/gitfail/git"
failing() { printf '%s' "$1" > "$T/gitfail/when"; }
printf '#!/bin/sh\necho f2\n' > src/a.sh; commit_nohook "a owes heavy"
touch "$MARK/heavy-fail"
failing "log --format= --name-only --no-renames"; reset_runs; PATH="$T/gitfail:$PATH" prepush
check "a failing pushed-file history listing refuses the push" "1" "$RC"
has "...as unreadable pushed files" "$OUT" "could not list the files"
check "...before running an owed suite" "0" "$(runs heavy)"
failing "rev-list --no-walk=unsorted"; reset_runs; PATH="$T/gitfail:$PATH" prepush
check "a failing commit listing for the heavy maps refuses the push" "1" "$RC"
has "...as unreadable maps" "$OUT" "could not read the test maps of the commits"
hasnt "...not as no heavy suite selected" "$OUT" "no heavy-tier suite selected"
failing ""; reset_runs; PATH="$T/gitfail:$PATH" prepush
check "(control) without the failure the owed suite runs and its failure refuses" "1" "$(runs heavy)"
rm -f "$MARK/heavy-fail"
failing "diff --name-only HEAD"; reset_runs; PATH="$T/gitfail:$PATH" prepush
check "a failing comparison with the pushed tip refuses the push" "1" "$RC"
has "...saying so" "$OUT" "could not compare the working tree with the pushed tip"
failing ""; reset_runs; PATH="$T/gitfail:$PATH" prepush
check "(control) without it the push passes" "0" "$RC"
published

echo "F3 (wv-ade029): bootstrap reports what pre-push owes, commit by commit"
printf '#!/bin/sh\necho f3\n' > src/a.sh; commit_nohook "a owes heavy (f3)"
sed -i '/^[[:space:]]*\[heavy\]/,$d' .weave/test-map.conf; commit_nohook "drop the heavy section (f3)"
b=$(wv bootstrap --json 2>/dev/null)
check "a suite an earlier unpushed commit owes is reported after a later one removes [heavy]" \
    "pending tests/test-heavy.sh" "$(jq -r '.readiness.heavy_tier | "\(.state) \([.suites[].suite] | join(","))"' <<< "$b")"
touch "$MARK/heavy-fail"; reset_runs; prepush
check "(control) pre-push owes the same suite and refuses its failure" "1" "$RC"
rm -f "$MARK/heavy-fail"; reset_runs; prepush
published; r2_map; r2_commit "f3 map restored"; published

echo "isolation"
check "ledger rows landed in the fixture's database" "yes" \
    "$([ "$(sqlite3 "$WV_DB" "SELECT COUNT(*) FROM test_results WHERE suite = 'tests/test-heavy.sh';" 2>/dev/null)" -gt 0 ] 2>/dev/null && echo yes || echo no)"
# Everything owed so far is published: what follows is a repository whose
# map has no [heavy] section, not a range that still carries deferrals.
git -c core.hooksPath=/dev/null push -q origin main 2>/dev/null
sed -i '/^\[heavy\]/,$d' .weave/test-map.conf; commit_nohook "no heavy section"
printf '#!/bin/sh\necho a8\n' > src/a.sh; commit_nohook "a without tiers"
reset_runs; prepush
check "without a [heavy] section the pre-push hook passes at once" "0" "$RC"
check "...running nothing" "0" "$(runs heavy)"
published
printf '#!/bin/sh\necho b9\n' > src/b.sh; commit_nohook "b with no tier anywhere"
check "(control) with no [heavy] in any map the unpushed commits involve, bootstrap reports no tier" "null" \
    "$(wv bootstrap --json 2>/dev/null | jq -c '.readiness.heavy_tier')"

echo ""
echo "Results: $pass/$run passed"
[ "$pass" -eq "$run" ]
