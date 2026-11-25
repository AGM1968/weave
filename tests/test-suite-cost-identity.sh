#!/usr/bin/env bash
# test-suite-cost-identity.sh — one definition of a suite's expected duration,
# keyed by the repository rather than the checkout (wv-870f67, wv-1e4c01,
# wv-f4e3d2).
#
# On 2026-11-18 a preflight in a worktree skipped tests/test-hook-common.sh,
# and the commit gate then refused on it. The durable logs keyed each row by
# basename(REPO_ROOT), so the worktree saw none of the suite's 155 runs under
# the main checkout's name, priced it 0, and preflight's quick filter dropped
# it as unmeasured. wv impact --suites priced from .weave/test-times.json, a
# second definition that only a serial run-all wrote. Now:
#   - rows are written under the repository's identity, the same from every
#     worktree, and a reader maps legacy worktree-keyed rows onto it;
#   - a repository that shares only a name prefix, or a suite's throwaway
#     repository, stays apart;
#   - wv impact --suites prices from the durable log, rounds up, and prices a
#     suite with no history null, never 0, saying so in its summary;
#   - the pool keeps that price and turns anything else into null.
# Preflight running an unmeasured suite is asserted in test-gate-preflight.sh.
export WV_CALL_SOURCE=test
set -uo pipefail
export WV_TEST_SUITE=1
export WV_RUN_CACHE=0 WV_AUTO_SYNC=0 WV_AUTO_CHECKPOINT=0
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WV="$ROOT/scripts/wv"
run=0; pass=0
ok()  { run=$((run+1)); pass=$((pass+1)); echo "  ✓ $1"; }
bad() { run=$((run+1)); echo "  ✗ $1"; [ -n "${2:-}" ] && echo "      $2"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$3] got [$2]"; fi; }
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR WV_SUITE_LOG_DEFAULT
T=$(mktemp -d /tmp/wv-suite-cost-identity-XXXXXX)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/cfg" "$T/hot"
export WV_CONFIG_DIR="$T/cfg" WV_SUITE_LOG="$T/suite_runs.jsonl" WV_GATE_LOG="$T/gate_runs.jsonl"

# A repository "costrepo", its worktree "costrepo-wt", an unrelated repository
# whose name only extends it, and one named like a suite's throwaway repo.
R="$T/costrepo"; W="$T/costrepo-wt"; X="$T/costrepo-x"; P="$T/project"
for d in "$R" "$X" "$P"; do
    git init -q "$d" && git -C "$d" config user.email t@t && git -C "$d" config user.name t
    git -C "$d" commit -q --allow-empty -m init
done
git -C "$R" worktree add -q --detach "$W" HEAD
w() { local d=$1; shift; (cd "$d" && WEAVE_DIR="$d/.weave" WV_HOT_ZONE="$T/hot/$(basename "$d")" "$WV" "$@") </dev/null; }
for d in "$R" "$W"; do w "$d" init >/dev/null 2>&1; done
mkdir -p "$W/tests" "$W/src"
printf '[map]\nsrc/a.sh = tests/test-old.sh tests/test-wt.sh tests/test-new.sh tests/test-tiny.sh\n' > "$W/.weave/test-map.conf"
: > "$W/src/a.sh"

row() {  # row <repo> <suite> <ms>
    jq -cn --arg r "$1" --arg s "$2" --argjson d "$3" \
        '{ts:"2026-11-18T00:00:00Z", repo:$r, suite:$s, files:"", exit:0, duration_ms:$d, sha:"x", clock:"monotonic"}' >> "$WV_SUITE_LOG"
}
row costrepo    tests/test-old.sh  30000   # the main checkout's name
row costrepo-wt tests/test-wt.sh   12000   # a legacy row keyed by the worktree
row costrepo-x  tests/test-old.sh  900000  # another repository, a longer name
row project     tests/test-old.sh  800000  # a suite's throwaway repository
row costrepo    tests/test-tiny.sh 400     # under a second

echo "=== one identity for every worktree ==="
id_of() { w "$1" analyze suites --json 2>/dev/null | jq -r '.repo'; }
check "the main checkout is keyed by its repository" "$(id_of "$R")" "costrepo"
check "its worktree is keyed by the same repository" "$(id_of "$W")" "costrepo"
check "an unrelated repository keeps its own name" "$(id_of "$X")" "costrepo-x"

echo "=== a worktree reads the whole repository's history ==="
runs_of() { w "$1" analyze suites --json 2>/dev/null | jq -r --arg s "$2" '[.suites[] | select(.suite == $s) | .runs] | add // 0'; }
check "the worktree sees the main checkout's runs, and no other repository's" "$(runs_of "$W" tests/test-old.sh)" "1"
check "the main checkout sees the worktree's legacy runs" "$(runs_of "$R" tests/test-wt.sh)" "1"
check "the unrelated repository does not see this one's" "$(runs_of "$X" tests/test-wt.sh)" "0"
check "the log path reported is the real log, not the filtered view" \
    "$(w "$W" analyze suites --json 2>/dev/null | jq -r '.log_path')" "$WV_SUITE_LOG"
check "wv analyze gates reads the repository's view too, naming the real logs" \
    "$(w "$W" analyze gates --json 2>/dev/null | jq -r '"\(.repo) \(.suite_log == $ENV.WV_SUITE_LOG) \(.gate_log == $ENV.WV_GATE_LOG)"')" "costrepo true true"
check "--repo names one key exactly, as before" \
    "$(w "$W" analyze suites --json --repo=costrepo-wt 2>/dev/null | jq -r '[.suites[].suite] | join(" ")')" "tests/test-wt.sh"

echo "=== rows are written under the identity ==="
w "$W" test-record tests/test-new.sh --exit=0 --duration=5000 --clock=monotonic >/dev/null 2>&1
check "a run recorded from the worktree is keyed by the repository" \
    "$(jq -r 'select(.suite == "tests/test-new.sh") | .repo' "$WV_SUITE_LOG")" "costrepo"

echo "=== wv impact --suites prices from the durable log ==="
cost() { w "$W" impact --suites --files=src/a.sh 2>/dev/null | jq -c --arg s "$1" '[.[] | select(.name == $s) | .last_cost_s][0]'; }
check "a suite measured under the main checkout's name is priced from the worktree" "$(cost tests/test-old.sh)" "30"
check "a legacy worktree-keyed row prices too" "$(cost tests/test-wt.sh)" "12"
check "a suite recorded under the identity prices" "$(cost tests/test-new.sh)" "5"
check "a sub-second suite is 1s, not unmeasured" "$(cost tests/test-tiny.sh)" "1"
: > "$WV_SUITE_LOG"
check "a suite with no history is priced null, not 0" "$(cost tests/test-old.sh)" "null"
# The summary and the suite list are printed for a node's touched files.
# wv add prints the new id alone on stdout.
nid=$(w "$W" add "cost fixture node" --standalone 2>/dev/null)
[[ "$nid" =~ ^wv-[0-9a-f]{6}$ ]] || bad "(fixture) wv add printed a node id" "got [$nid]"
w "$W" update "$nid" --metadata='{"touched_files":["src/a.sh"]}' >/dev/null 2>&1
check "...and the summary does not count it as free" \
    "$(w "$W" impact "$nid" --json 2>/dev/null | jq -r '.summary' | grep -o '~0s measured, 4 not yet measured')" "~0s measured, 4 not yet measured"
check "...nor the suite list" \
    "$(w "$W" impact "$nid" 2>/dev/null | grep -c 'tests/test-old.sh  (not yet measured)')" "1"
printf 'not json\n' > "$WV_SUITE_LOG"
check "an unreadable history leaves every suite unknown, never 0" "$(cost tests/test-old.sh)" "null"

echo "=== the pool keeps impact's price ==="
est=$(bash -c 'source "$1/scripts/lib/wv-gate-pool.sh" >/dev/null 2>&1; gate_pool_estimates "$2"' _ "$ROOT" \
    '[{"name":"a","last_cost_s":7},{"name":"b","last_cost_s":0},{"name":"c","last_cost_s":null},{"name":"d"}]')
check "a positive price is kept; 0, null and absent become null" \
    "$(jq -c 'map(.last_cost_s)' <<< "$est")" "[7,null,null,null]"
check "the pool no longer re-reads the history" \
    "$(grep -c 'analyze suites' "$ROOT/scripts/lib/wv-gate-pool.sh")" "0"

echo "=== preflight's default selection ==="
sel=$(bash -c 'hook_progress() { echo "P: $*" >&2; }; source "$1/scripts/lib/wv-gate-pool.sh" >/dev/null 2>&1; gate_pool_preflight_select "$2" 20' _ "$ROOT" \
    '[{"name":"quick","last_cost_s":5,"tier":"light"},{"name":"slow","last_cost_s":50,"tier":"light"},{"name":"new","last_cost_s":null,"tier":"light"},{"name":"bigquick","last_cost_s":9,"tier":"heavy"},{"name":"bignew","last_cost_s":null,"tier":"heavy"}]' 2>"$T/sel.err")
check "runs the quick, the light unmeasured and a quick heavy one; not the slow or the unmeasured heavy" \
    "$(jq -r '[.[].name] | join(" ")' <<< "$sel")" "quick new bigquick"
check "...naming the unmeasured light suite it runs" \
    "$(grep -c 'not yet measured, so run to learn their time: new$' "$T/sel.err")" "1"
check "...and the unmeasured heavy one it does not" \
    "$(grep -c 'heavy tier and not yet measured, so not run: bignew$' "$T/sel.err")" "1"
check "an unreadable selection is run whole, never narrowed to nothing" \
    "$(bash -c 'hook_progress() { :; }; source "$1/scripts/lib/wv-gate-pool.sh" >/dev/null 2>&1; gate_pool_preflight_select "not json" 20' _ "$ROOT")" "not json"

echo "=== no second definition remains ==="
check "nothing reads or writes .weave/test-times.json" \
    "$(grep -l 'test-times' "$ROOT/scripts/cmd/"*.sh "$ROOT/scripts/lib/"*.sh "$ROOT/scripts/hooks/"*.sh "$ROOT/tests/run-all.sh" 2>/dev/null \
        | grep -v -e 'wv-runtime-ignores.sh' -e 'wv-cmd-graph.sh' | wc -l | tr -d ' ')" "0"
check "...and impact names it only as what it replaced" \
    "$(grep -c 'test-times' "$ROOT/scripts/cmd/wv-cmd-graph.sh")" "1"

echo ""
echo "suite cost identity: $pass/$run passed"
[ "$pass" -eq "$run" ]
