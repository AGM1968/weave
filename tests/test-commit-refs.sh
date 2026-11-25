#!/bin/bash
# Suite-driven wv calls are tagged test so call-stats retro reads can exclude them.
export WV_CALL_SOURCE=test
# test-commit-refs.sh — Tests for `wv commit-refs` and the aggregation-time
# prevention filter that stops stale child SHAs being re-acquired by an epic.
# Weave-ID: wv-fc4ac2

set -e
export WV_TEST_SUITE=1  # the user's config.env cannot log this suite's wv calls (wv-6b0f57)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WV="$REPO_ROOT/scripts/wv"

TEST_DIR=$(mktemp -d)
export WV_HOT_ZONE="$TEST_DIR/hot"
export WV_DB="$TEST_DIR/hot/brain.db"
export WV_REQUIRE_LEARNING=0
export WEAVE_DIR="$TEST_DIR/.weave"
export WV_PROJECT_DIR="$TEST_DIR"
export WV_AGENT_ID="test-commit-refs-agent"
mkdir -p "$WV_HOT_ZONE" "$WEAVE_DIR"

TESTS_RUN=0
TESTS_PASSED=0
TESTS_XFAIL=0

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

GIT=(git -c commit.gpgsign=false -c user.name='Weave test' -c user.email='weave-test@example.invalid')

assert_equals() {
    local expected="$1" actual="$2" msg="${3:-assertion}"
    if [ "$expected" = "$actual" ]; then
        echo -e "  ${GREEN}✓${NC} $msg"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}✗${NC} $msg"
        echo "    Expected: '$expected'"
        echo "    Actual:   '$actual'"
    fi
    TESTS_RUN=$((TESTS_RUN + 1))
}

assert_contains() {
    local haystack="$1" needle="$2" msg="${3:-contains}"
    if [[ "$haystack" == *"$needle"* ]]; then
        echo -e "  ${GREEN}✓${NC} $msg"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}✗${NC} $msg"
        echo "    Missing:  '$needle'"
        echo "    Haystack: '${haystack:0:400}'"
    fi
    TESTS_RUN=$((TESTS_RUN + 1))
}

# Build a clone with an "origin" so the sweep has a real pushed ref to test
# reachability against, instead of falling back to degraded mode.
setup_repo() {
    rm -rf "$TEST_DIR/origin" "$TEST_DIR/work" "$WV_HOT_ZONE" "$WEAVE_DIR"
    mkdir -p "$WV_HOT_ZONE" "$WEAVE_DIR"
    "${GIT[@]}" init -q --bare "$TEST_DIR/origin"
    "${GIT[@]}" init -q -b main "$TEST_DIR/work"
    cd "$TEST_DIR/work"
    echo seed > seed.txt
    "${GIT[@]}" add seed.txt
    "${GIT[@]}" commit -qm "seed"
    "${GIT[@]}" remote add origin "$TEST_DIR/origin"
    "${GIT[@]}" push -q -u origin main
    rm -f "$WV_DB" "$WV_DB-wal" "$WV_DB-shm"
    $WV init >/dev/null 2>&1
}

# Record a SHA on a node the way `wv done` does, without depending on the
# close path: these tests are about how refs are CLASSIFIED once recorded.
record_ref() {
    local id="$1" sha="$2"
    sqlite3 "$WV_DB" "UPDATE nodes SET metadata = json_set(COALESCE(NULLIF(metadata,''), '{}'), '\$.commit', '$sha', '\$.commits', json_array('$sha')) WHERE id='$id';"
}

echo "═══════════════════════════════════════════════════════════════════════════"
echo "wv commit-refs — provenance sweep"
echo "═══════════════════════════════════════════════════════════════════════════"

# ── A pushed commit is reachable ───────────────────────────────────────────
setup_repo
NODE=$($WV add "task: recorded commit" 2>/dev/null | tail -1)
echo one > one.txt
"${GIT[@]}" add one.txt
"${GIT[@]}" commit -qm "work: one"
"${GIT[@]}" push -q origin main
SHA_PUSHED=$("${GIT[@]}" rev-parse HEAD)
record_ref "$NODE" "$SHA_PUSHED"

OUT=$($WV commit-refs --json 2>/dev/null)
assert_equals "1" "$(echo "$OUT" | jq -r '.totals.reachable')" "pushed commit classified reachable"
assert_equals "0" "$(echo "$OUT" | jq -r '.totals.orphaned')" "pushed commit is not an orphan"
assert_equals "main" "$(echo "$OUT" | jq -r '.pushed_ref' | sed 's|origin/||')" "pushed ref resolved from upstream"

# ── An amended commit is unreachable ───────────────────────────────────────
# Amending strips the recorded commit out from under the node: the object
# survives in the object database but no ref reaches it any more. This is the
# exact mechanism that produced the wv-55d2de population, so it is recorded
# BEFORE the push — a SHA already on origin stays reachable through the remote
# tracking ref no matter what the local branch does afterwards.
setup_repo
NODE=$($WV add "task: amended commit" 2>/dev/null | tail -1)
echo one > one.txt
"${GIT[@]}" add one.txt
"${GIT[@]}" commit -qm "work: one"
SHA_PUSHED=$("${GIT[@]}" rev-parse HEAD)
record_ref "$NODE" "$SHA_PUSHED"
"${GIT[@]}" commit -q --amend -m "work: one (amended)"
"${GIT[@]}" push -q origin main
OUT=$($WV commit-refs --json 2>/dev/null)
assert_equals "1" "$(echo "$OUT" | jq -r '.totals.unreachable')" "amended commit reported unreachable"
assert_equals "1" "$(echo "$OUT" | jq -r '.totals.orphaned')" "amended commit counts as orphaned"
assert_equals "1" "$(echo "$OUT" | jq -r '.totals.orphaned_nodes')" "the owning node is reported"
assert_equals "$NODE" "$(echo "$OUT" | jq -r '.refs[0].node')" "orphan row names the node"
assert_equals "$SHA_PUSHED" "$(echo "$OUT" | jq -r '.refs[0].ref')" "orphan row names the stale SHA"

TEXT=$($WV commit-refs 2>/dev/null)
assert_contains "$TEXT" "unreachable" "text report lists the class"
assert_contains "$TEXT" "$NODE" "text report lists the node"

# ── a failed kind classification counts orphans, it does not erase them ────
# Regression (release review 3): the classifier's fallback emptied the kinds
# file, so all three counters read 0 while orphans were present -- the exact
# shape of a clean sweep. The one number that would have shown a real
# provenance loss was the number the failure erased. On failure the whole
# population is charged to unknown instead, and the three kinds must always
# reconcile with the orphan total.
K_OUT=$(echo "$OUT" | jq -r '[.totals.orphaned_checkpoint, .totals.orphaned_regular, .totals.orphaned_unknown] | @tsv')
K_SUM=$(echo "$OUT" | jq -r '.totals.orphaned_checkpoint + .totals.orphaned_regular + .totals.orphaned_unknown')
assert_equals "$(echo "$OUT" | jq -r '.totals.orphaned')" "$K_SUM" "kind counts reconcile with the orphan total on a healthy classification"

FAIL_OUT=$(WV_TEST_MODE=1 WV_TEST_FAIL_ORPHAN_KINDS=1 $WV commit-refs --json 2>/dev/null)
assert_equals "1" "$(echo "$FAIL_OUT" | jq -r '.totals.orphaned')" "the orphan is still reported when classification fails"
assert_equals "1" "$(echo "$FAIL_OUT" | jq -r '.totals.orphaned_unknown')" "a failed classification charges the orphan to unknown"
FAIL_SUM=$(echo "$FAIL_OUT" | jq -r '.totals.orphaned_checkpoint + .totals.orphaned_regular + .totals.orphaned_unknown')
assert_equals "1" "$FAIL_SUM" "kind counts still reconcile with the orphan total after a failed classification"
FAIL_WARN=$(WV_TEST_MODE=1 WV_TEST_FAIL_ORPHAN_KINDS=1 $WV commit-refs --json 2>&1 >/dev/null)
assert_contains "$FAIL_WARN" "could not classify orphan refs" "a failed classification is announced, not swallowed"

# ── the orphan-classifier hook is gated and validated on every path ─────────
# Regression (release review 5): validation sat INSIDE the orphans-present
# branch, so an unrecognised value was accepted silently on a clean sweep --
# the ordinary case. "Unknown values are rejected" held only when the data
# happened to exercise the path.

# 1. Without the master opt-in, a VALID value is inert: the real classifier
#    runs, so the orphan is classified rather than forced to unknown, and no
#    failure notice is printed.
INERT_OUT=$(env -u WV_TEST_MODE WV_TEST_FAIL_ORPHAN_KINDS=1 $WV commit-refs --json 2>/dev/null)
INERT_ERR=$(env -u WV_TEST_MODE WV_TEST_FAIL_ORPHAN_KINDS=1 $WV commit-refs --json 2>&1 >/dev/null)
assert_equals "0" "$(echo "$INERT_OUT" | jq -r '.totals.orphaned_unknown')" \
    "a valid classifier value without WV_TEST_MODE=1 leaves classification real"
case "$INERT_ERR" in
    *"could not classify orphan refs"*) INERT_FORCED=forced ;;
    *)                                  INERT_FORCED=real ;;
esac
assert_equals "real" "$INERT_FORCED" \
    "a valid classifier value without WV_TEST_MODE=1 forces no failure"

# 2. With test mode, an invalid value is rejected while orphans ARE present.
INVALID_RC=0
WV_TEST_MODE=1 WV_TEST_FAIL_ORPHAN_KINDS=typo $WV commit-refs --json >/dev/null 2>&1 || INVALID_RC=$?
assert_equals "1" "$INVALID_RC" "an invalid classifier value is rejected when orphans are present"

# 3. And on a sweep with NO orphans -- the branch that used to skip validation.
setup_repo
NO_ORPHAN_RC=0
CLEAN_OUT=$($WV commit-refs --json 2>/dev/null)
assert_equals "0" "$(echo "$CLEAN_OUT" | jq -r '.totals.orphaned')" "the clean fixture really has no orphans"
WV_TEST_MODE=1 WV_TEST_FAIL_ORPHAN_KINDS=typo $WV commit-refs --json >/dev/null 2>&1 || NO_ORPHAN_RC=$?
assert_equals "1" "$NO_ORPHAN_RC" "an invalid classifier value is rejected when there are no orphans"

# ── missing is a distinct class from unreachable ───────────────────────────
setup_repo
NODE=$($WV add "task: vanished commit" 2>/dev/null | tail -1)
record_ref "$NODE" "0123456789012345678901234567890123456789"
OUT=$($WV commit-refs --json 2>/dev/null)
assert_equals "1" "$(echo "$OUT" | jq -r '.totals.missing')" "absent object classified missing"
assert_equals "0" "$(echo "$OUT" | jq -r '.totals.unreachable')" "absent object is not counted as unreachable"

# ── unpushed local work is pending, not an orphan ──────────────────────────
setup_repo
NODE=$($WV add "task: local commit" 2>/dev/null | tail -1)
echo two > two.txt
"${GIT[@]}" add two.txt
"${GIT[@]}" commit -qm "work: two (unpushed)"
record_ref "$NODE" "$("${GIT[@]}" rev-parse HEAD)"
OUT=$($WV commit-refs --json 2>/dev/null)
assert_equals "1" "$(echo "$OUT" | jq -r '.totals.pending')" "unpushed commit classified pending"
assert_equals "0" "$(echo "$OUT" | jq -r '.totals.orphaned')" "unpushed commit is NOT an orphan"

# Pushing it turns pending into reachable — the classes are not sticky labels.
"${GIT[@]}" push -q origin main
OUT=$($WV commit-refs --json 2>/dev/null)
assert_equals "1" "$(echo "$OUT" | jq -r '.totals.reachable')" "pushing reclassifies pending as reachable"

# ── abbreviated refs resolve rather than reading as missing ────────────────
setup_repo
NODE=$($WV add "task: short ref" 2>/dev/null | tail -1)
echo three > three.txt
"${GIT[@]}" add three.txt
"${GIT[@]}" commit -qm "work: three"
"${GIT[@]}" push -q origin main
SHORT=$("${GIT[@]}" rev-parse --short=8 HEAD)
record_ref "$NODE" "$SHORT"
OUT=$($WV commit-refs --json 2>/dev/null)
assert_equals "1" "$(echo "$OUT" | jq -r '.totals.reachable')" "abbreviated ref resolves to a reachable commit"
assert_equals "0" "$(echo "$OUT" | jq -r '.refs | length')" "no orphan row for a live abbreviated ref"
# --all reports the ref in the form the node RECORDS it, not the resolved OID:
# a prune matching on the resolved form would not match the stored string.
ALL=$($WV commit-refs --all --json 2>/dev/null)
assert_equals "$SHORT" "$(echo "$ALL" | jq -r '.refs[0].ref')" "--all reports the recorded (abbreviated) form"
TEXT=$($WV commit-refs 2>/dev/null)
case "$TEXT" in *"wv commit-refs --prune"*) HINT=offered ;; *) HINT=none ;; esac
assert_equals "none" "$HINT" "no prune is offered when nothing is orphaned"

# ── each orphan says why it is one (wv-6d53ec) ─────────────────────────────
# The sweep offered --prune for 68 refs it never explained (rc.14 consumer
# audit K7), so an amend's churn could not be told from a provenance loss.
# Dates are pinned: the replacement match is second-precise.
setup_repo
at() { GIT_AUTHOR_DATE="$1 +0000" GIT_COMMITTER_DATE="$1 +0000" "${GIT[@]}" "${@:2}"; }
N_AM=$($WV add "task: amended" 2>/dev/null | tail -1)
N_RB=$($WV add "task: rebased" 2>/dev/null | tail -1)
N_RS=$($WV add "task: reset" 2>/dev/null | tail -1)
N_DR=$($WV add "task: dropped" 2>/dev/null | tail -1)
N_MS=$($WV add "task: missing" 2>/dev/null | tail -1)
N_BL=$($WV add "task: blob" 2>/dev/null | tail -1)
echo a > a.txt; "${GIT[@]}" add a.txt
at 1700000001 commit -qm "work: a"
record_ref "$N_AM" "$("${GIT[@]}" rev-parse HEAD)"
# An amend keeps the author date and the parent; only the committer moves.
GIT_COMMITTER_DATE="1700000002 +0000" "${GIT[@]}" commit -q --amend -m "work: a, reworded"
SHA_AM_NOW=$("${GIT[@]}" rev-parse --short=9 HEAD)
echo b > b.txt; "${GIT[@]}" add b.txt
at 1700000010 commit -qm "work: b"
SHA_RB=$("${GIT[@]}" rev-parse HEAD)
record_ref "$N_RB" "$SHA_RB"
"${GIT[@]}" reset -q --hard HEAD~1
echo c > c.txt; "${GIT[@]}" add c.txt
at 1700000011 commit -qm "work: c"
# A cherry-pick keeps the author, author date and subject on a new parent.
GIT_COMMITTER_DATE="1700000012 +0000" "${GIT[@]}" cherry-pick "$SHA_RB" >/dev/null
SHA_RB_NOW=$("${GIT[@]}" rev-parse --short=9 HEAD)
echo d > d.txt; "${GIT[@]}" add d.txt
at 1700000020 commit -qm "work: d"
record_ref "$N_RS" "$("${GIT[@]}" rev-parse HEAD)"
"${GIT[@]}" reset -q --hard HEAD~1
# commit-tree writes no reflog entry: nothing at all reaches this commit. It
# shares its author date with the reachable "work: c": author and date alone
# would call it rebased; its parent and subject say it was replaced by nothing.
record_ref "$N_DR" "$(echo "work: e" | at 1700000011 commit-tree "HEAD^{tree}" -p HEAD)"
record_ref "$N_MS" "0123456789012345678901234567890123456789"
record_ref "$N_BL" "$(echo blob | "${GIT[@]}" hash-object -w --stdin)"
"${GIT[@]}" push -q origin main

OUT=$($WV commit-refs --json 2>/dev/null)
reason_of() { echo "$OUT" | jq -r --arg n "$1" '[.refs[] | select(.node == $n)][0] | "\(.reason) | \(.why)"'; }
assert_equals "amended | amended: now $SHA_AM_NOW" "$(reason_of "$N_AM")" "an amended ref names the commit that replaced it"
assert_equals "rebased | rebased: now $SHA_RB_NOW" "$(reason_of "$N_RB")" "a rebased ref names its copy on the new parent"
assert_contains "$(reason_of "$N_RS")" "reset | dropped by a reset or rebase (still in the reflog)" "a reset ref is found in the reflog"
assert_contains "$(reason_of "$N_DR")" "dropped | no ref or reflog reaches it" "a ref nothing reaches is dropped"
assert_contains "$(reason_of "$N_MS")" "not_in_clone | not in this clone" "an absent object is not in this clone"
assert_contains "$(reason_of "$N_BL")" "not_a_commit | names a blob, not a commit" "a blob id is not a commit"
assert_equals "6" "$(echo "$OUT" | jq '[.refs[] | select(.reason)] | length')" "every orphan carries a reason"

TEXT=$($WV commit-refs 2>/dev/null)
assert_contains "$TEXT" "amended: now $SHA_AM_NOW" "the text report states why"
LAST=$(printf '%s\n' "$TEXT" | grep -v '^$' | tail -1)
assert_contains "$LAST" "wv commit-refs --prune" "prune is offered after the reasons"

DOC=$($WV doctor --json 2>/dev/null | jq -r '.checks[] | select(.check == "commit refs") | .detail')
assert_contains "$DOC" "1 amended, 1 dropped, 1 not a commit, 1 not in this clone, 1 rebased, 1 reset — inspect" \
    "doctor counts the orphans by reason before offering the prune"

echo ""
echo "═══════════════════════════════════════════════════════════════════════════"
echo "wv commit-refs --prune"
echo "═══════════════════════════════════════════════════════════════════════════"

setup_repo
NODE=$($WV add "task: prunable" 2>/dev/null | tail -1)
echo four > four.txt
"${GIT[@]}" add four.txt
"${GIT[@]}" commit -qm "work: four"
"${GIT[@]}" push -q origin main
LIVE=$("${GIT[@]}" rev-parse HEAD)
echo five > five.txt
"${GIT[@]}" add five.txt
"${GIT[@]}" commit -qm "work: five"
STALE=$("${GIT[@]}" rev-parse HEAD)
"${GIT[@]}" reset -q --hard "$LIVE"
sqlite3 "$WV_DB" "UPDATE nodes SET metadata = json_set('{}', '\$.commit', '$STALE', '\$.commits', json_array('$STALE','$LIVE')) WHERE id='$NODE';"

DRY=$($WV commit-refs --prune --dry-run 2>/dev/null)
assert_contains "$DRY" "Would prune" "dry-run announces without writing"
assert_equals "2" "$(sqlite3 "$WV_DB" "SELECT json_array_length(json_extract(metadata,'\$.commits')) FROM nodes WHERE id='$NODE';")" "dry-run leaves metadata untouched"

$WV commit-refs --prune >/dev/null 2>&1
assert_equals "1" "$(sqlite3 "$WV_DB" "SELECT json_array_length(json_extract(metadata,'\$.commits')) FROM nodes WHERE id='$NODE';")" "prune removes only the stale ref"
assert_equals "$LIVE" "$(sqlite3 "$WV_DB" "SELECT json_extract(metadata,'\$.commits[0]') FROM nodes WHERE id='$NODE';")" "the live ref survives the prune"
assert_equals "$LIVE" "$(sqlite3 "$WV_DB" "SELECT json_extract(metadata,'\$.commit') FROM nodes WHERE id='$NODE';")" "primary ref repointed to a live commit"
assert_equals "0" "$($WV commit-refs --json 2>/dev/null | jq -r '.totals.orphaned')" "sweep is clean after prune"

# Pruning the last ref must drop both keys rather than leave a dangling primary.
setup_repo
NODE=$($WV add "task: all stale" 2>/dev/null | tail -1)
record_ref "$NODE" "0123456789012345678901234567890123456789"
$WV commit-refs --prune >/dev/null 2>&1
assert_equals "" "$(sqlite3 "$WV_DB" "SELECT COALESCE(json_extract(metadata,'\$.commit'),'') FROM nodes WHERE id='$NODE';")" "primary ref removed when nothing live remains"
assert_equals "" "$(sqlite3 "$WV_DB" "SELECT COALESCE(json_extract(metadata,'\$.commits'),'') FROM nodes WHERE id='$NODE';")" "empty commits list removed rather than left as []"

# Emptying the array does not authorise removing the primary. record_ref writes
# the SAME sha to both keys, so the test above cannot distinguish "drop the
# primary because it is dead" from "drop the primary because the array emptied".
# Here the primary is LIVE and the array holds only a dead ref — the shape that
# cost three reachable refs in the wv-3ce8d9 cleanup run.
setup_repo
NODE=$($WV add "task: live primary, dead array" 2>/dev/null | tail -1)
echo eight > eight.txt
"${GIT[@]}" add eight.txt
"${GIT[@]}" commit -qm "work: eight"
"${GIT[@]}" push -q origin main
LIVE=$("${GIT[@]}" rev-parse HEAD)
sqlite3 "$WV_DB" "UPDATE nodes SET metadata = json_set('{}', '\$.commit', '$LIVE', '\$.commits', json_array('0123456789012345678901234567890123456789')) WHERE id='$NODE';"
$WV commit-refs --prune >/dev/null 2>&1
assert_equals "$LIVE" "$(sqlite3 "$WV_DB" "SELECT COALESCE(json_extract(metadata,'\$.commit'),'GONE') FROM nodes WHERE id='$NODE';")" "a live primary survives an emptied commits array"
assert_equals "" "$(sqlite3 "$WV_DB" "SELECT COALESCE(json_extract(metadata,'\$.commits'),'') FROM nodes WHERE id='$NODE';")" "the dead array is still removed"
assert_equals "0" "$($WV commit-refs --json 2>/dev/null | jq -r '.totals.orphaned')" "no orphan remains after pruning the dead array"

# ── malformed and non-SHA-1-width refs are classified, never dropped ───────
# The scan pre-filter used to require 4-40 hex characters, which silently
# DISCARDED anything else before classification: junk never surfaced, and in a
# SHA-256 repository every 64-character OID vanished, so the sweep reported
# refs:0 orphaned:0 and `wv doctor` read that as clean.
setup_repo
NODE=$($WV add "task: junk ref" 2>/dev/null | tail -1)
record_ref "$NODE" "not-a-sha"
OUT=$($WV commit-refs --json 2>/dev/null)
assert_equals "1" "$(echo "$OUT" | jq -r '.totals.refs')" "a malformed ref is still counted"
assert_equals "1" "$(echo "$OUT" | jq -r '.totals.missing')" "a malformed ref is classified missing, not dropped"
assert_equals "1" "$(echo "$OUT" | jq -r '.totals.orphaned')" "a malformed ref counts as orphaned"

setup_repo
NODE=$($WV add "task: sha256-width ref" 2>/dev/null | tail -1)
SHA256_SHAPED=$(printf 'a%.0s' $(seq 1 64))
record_ref "$NODE" "$SHA256_SHAPED"
OUT=$($WV commit-refs --json 2>/dev/null)
assert_equals "1" "$(echo "$OUT" | jq -r '.totals.refs')" "a 64-character OID reaches classification"
assert_equals "1" "$(echo "$OUT" | jq -r '.totals.missing')" "an unresolvable 64-character OID is missing, not dropped"

# A sha256 repository's real OIDs must classify as reachable, not vanish. This
# needs a self-contained environment: wv ignores a WV_DB/WV_HOT_ZONE override
# that leaked in from a different repository, so the graph and the git repo have
# to be the same repo for the sweep to see both.
rm -rf "$TEST_DIR/s256"
if "${GIT[@]}" init -q --object-format=sha256 -b main "$TEST_DIR/s256" 2>/dev/null; then
    "${GIT[@]}" init -q --bare --object-format=sha256 "$TEST_DIR/s256origin"
    (
        cd "$TEST_DIR/s256"
        echo x > x.txt
        "${GIT[@]}" add x.txt
        "${GIT[@]}" commit -qm "sha256 work"
        "${GIT[@]}" remote add origin "$TEST_DIR/s256origin"
        "${GIT[@]}" push -q -u origin main
    ) >/dev/null 2>&1
    S256_SHA=$("${GIT[@]}" -C "$TEST_DIR/s256" rev-parse HEAD)
    assert_equals "64" "${#S256_SHA}" "sha256 fixture really produced a 64-character OID"

    S256_ENV=(env -u WV_DB -u WV_DB_CUSTOM
        "WV_PROJECT_DIR=$TEST_DIR/s256" "WV_HOT_ZONE=$TEST_DIR/s256/hz"
        "WEAVE_DIR=$TEST_DIR/s256/.weave" WV_REQUIRE_LEARNING=0
        WV_AUTO_SYNC=0 WV_AGENT_ID=test-commit-refs-sha256)
    # The fixture has a remote, so wv classes it 'ambiguous' and refuses to
    # scaffold until ownership is stated. Say so explicitly rather than letting
    # init fail and the DB appear as a side effect of the first write.
    ( cd "$TEST_DIR/s256" && "${S256_ENV[@]}" $WV repo-class set owned ) >/dev/null 2>&1 || true
    ( cd "$TEST_DIR/s256" && "${S256_ENV[@]}" $WV init ) >/dev/null 2>&1 || true
    S256_NODE=$( ( cd "$TEST_DIR/s256" && "${S256_ENV[@]}" $WV add "task: sha256 ref" ) 2>/dev/null | tail -1)
    sqlite3 "$TEST_DIR/s256/hz/brain.db" \
        "UPDATE nodes SET metadata = json_set('{}', '\$.commit', '$S256_SHA', '\$.commits', json_array('$S256_SHA')) WHERE id='$S256_NODE';"

    OUT=$( ( cd "$TEST_DIR/s256" && "${S256_ENV[@]}" $WV commit-refs --json ) 2>/dev/null)
    assert_equals "1" "$(echo "$OUT" | jq -r '.totals.refs')" "a real sha256 OID reaches classification"
    assert_equals "1" "$(echo "$OUT" | jq -r '.totals.reachable')" "a real sha256 OID is classified reachable"
    assert_equals "0" "$(echo "$OUT" | jq -r '.totals.orphaned')" "a real sha256 OID is not an orphan"
    rm -rf "$TEST_DIR/s256" "$TEST_DIR/s256origin"
    cd "$TEST_DIR/work"
else
    echo -e "  ${YELLOW}-${NC} sha256 object format unsupported by this git — real-OID case skipped"
    rm -rf "$TEST_DIR/s256"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════════════"
echo "Prune is atomic and persisted"
echo "═══════════════════════════════════════════════════════════════════════════"

# The prune used to be a SELECT into jq and back, rewriting the whole metadata
# object from a value read moments earlier: a concurrent write to any other key
# was reverted, and updated_at never moved.
setup_repo
NODE=$($WV add "task: concurrent metadata" 2>/dev/null | tail -1)
sqlite3 "$WV_DB" "UPDATE nodes SET metadata = json_set('{}', '\$.commit', '0123456789012345678901234567890123456789', '\$.commits', json_array('0123456789012345678901234567890123456789'), '\$.claimed_by', 'other-agent'), updated_at='2000-01-01 00:00:00' WHERE id='$NODE';"
$WV commit-refs --prune >/dev/null 2>&1
assert_equals "other-agent" "$(sqlite3 "$WV_DB" "SELECT COALESCE(json_extract(metadata,'\$.claimed_by'),'GONE') FROM nodes WHERE id='$NODE';")" "prune preserves unrelated metadata keys"
assert_equals "" "$(sqlite3 "$WV_DB" "SELECT COALESCE(json_extract(metadata,'\$.commit'),'') FROM nodes WHERE id='$NODE';")" "prune still removes the stale primary"
NEWER=$(sqlite3 "$WV_DB" "SELECT CASE WHEN updated_at > '2000-01-01 00:00:00' THEN 'advanced' ELSE 'stale' END FROM nodes WHERE id='$NODE';")
assert_equals "advanced" "$NEWER" "prune advances updated_at"

# ── a prune that is not persisted has not happened ─────────────────────────
# state.sql is the load authority. The first version of --prune wrote only to
# the hot DB and printed success, so the next `wv load` restored every ref it
# had just removed. This needs its own environment: the suite-wide WV_DB sets
# WV_DB_CUSTOM, which disables auto_sync entirely, so the shared fixture cannot
# see this class of bug at all.
rm -rf "$TEST_DIR/persist"
mkdir -p "$TEST_DIR/persist"
"${GIT[@]}" init -q -b main "$TEST_DIR/persist"
(
    cd "$TEST_DIR/persist"
    echo seed > seed.txt
    "${GIT[@]}" add seed.txt
    "${GIT[@]}" commit -qm seed
) >/dev/null 2>&1

P_ENV=(env -u WV_DB -u WV_DB_CUSTOM
    "WV_PROJECT_DIR=$TEST_DIR/persist" "WV_HOT_ZONE=$TEST_DIR/persist/hz"
    "WEAVE_DIR=$TEST_DIR/persist/.weave" WV_REQUIRE_LEARNING=0
    WV_AUTO_SYNC=1 WV_AUTO_CHECKPOINT=0 WV_AGENT_ID=test-commit-refs-persist)
( cd "$TEST_DIR/persist" && "${P_ENV[@]}" $WV init ) >/dev/null 2>&1 || true
P_NODE=$( ( cd "$TEST_DIR/persist" && "${P_ENV[@]}" $WV add "task: persist" ) 2>/dev/null | tail -1)
P_DB="$TEST_DIR/persist/hz/brain.db"
sqlite3 "$P_DB" "UPDATE nodes SET metadata = json_set('{}', '\$.commit', '0123456789012345678901234567890123456789', '\$.commits', json_array('0123456789012345678901234567890123456789')) WHERE id='$P_NODE';"
( cd "$TEST_DIR/persist" && "${P_ENV[@]}" $WV sync ) >/dev/null 2>&1 || true

# A write publishes its delta, not state.sql (wv-8595fb): the prune must leave
# a new delta naming the node.
p_deltas() { find "$TEST_DIR/persist/.weave/deltas" -name '*.sql' 2>/dev/null | sort; }
p_names() { local f; while IFS= read -r f; do [ -n "$f" ] && grep -qF -- "$1" "$f" && return 0; done; return 1; }
P_BEFORE=$(p_deltas)
( cd "$TEST_DIR/persist" && "${P_ENV[@]}" $WV commit-refs --prune ) >/dev/null 2>&1
P_NEW=$(comm -13 <(printf '%s\n' "$P_BEFORE") <(p_deltas))
if [ -n "$P_NEW" ] && p_names "$P_NODE" <<< "$P_NEW"; then
    echo -e "  ${GREEN}✓${NC} prune publishes a delta naming the node"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "  ${RED}✗${NC} prune published no delta naming the node — nothing was persisted"
fi
TESTS_RUN=$((TESTS_RUN + 1))

# The load-back is the assertion that matters: a prune the git layer never saw
# is undone the moment the hot DB is rebuilt from it.
rm -f "$P_DB" "$P_DB-wal" "$P_DB-shm"
( cd "$TEST_DIR/persist" && "${P_ENV[@]}" $WV load ) >/dev/null 2>&1 || true
P_OUT=$( ( cd "$TEST_DIR/persist" && "${P_ENV[@]}" $WV commit-refs --json ) 2>/dev/null)
assert_equals "0" "$(echo "$P_OUT" | jq -r '.totals.orphaned')" "the pruned ref does not come back after wv load"

# JSON consumers must be able to tell a persisted prune from an unpersisted one.
P_JSON=$( ( cd "$TEST_DIR/persist" && "${P_ENV[@]}" $WV commit-refs --prune --json ) 2>/dev/null)
assert_equals "nothing_to_prune" "$(echo "$P_JSON" | jq -r '.prune.persisted')" "JSON reports the prune state, not just prose"

# An ABSENT change log is not an empty one. With _warp_changes and its update
# trigger dropped, auto_sync recreated tracking only AFTER the untracked UPDATE,
# saw nothing pending, and the command reported a persistence that never
# happened. Tracking is now ensured before the mutation, and persistence is
# proved against state.sql itself.
sqlite3 "$P_DB" "UPDATE nodes SET metadata = json_set('{}', '\$.commit', '0123456789012345678901234567890123456789', '\$.commits', json_array('0123456789012345678901234567890123456789')) WHERE id='$P_NODE';"
( cd "$TEST_DIR/persist" && "${P_ENV[@]}" $WV sync ) >/dev/null 2>&1 || true
sqlite3 "$P_DB" "DROP TRIGGER IF EXISTS _warp_nodes_update; DROP TABLE IF EXISTS _warp_changes;"
P_BEFORE=$(p_deltas)
P_JSON=$( ( cd "$TEST_DIR/persist" && "${P_ENV[@]}" $WV commit-refs --prune --json ) 2>/dev/null)
P_NEW=$(comm -13 <(printf '%s\n' "$P_BEFORE") <(p_deltas))
assert_equals "true" "$(echo "$P_JSON" | jq -r '.prune.persisted')" "prune with tracking dropped still persists"
if [ -n "$P_NEW" ] && p_names "$P_NODE" <<< "$P_NEW"; then
    echo -e "  ${GREEN}✓${NC} a delta really carries the prune with tracking dropped"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "  ${RED}✗${NC} claimed persistence with tracking dropped but no delta names the node"
fi
TESTS_RUN=$((TESTS_RUN + 1))

rm -rf "$TEST_DIR/persist"
cd "$TEST_DIR/work"

# ── the rows payload must not travel as an argv-sized argument ─────────────
# --argjson put the whole ref array in one argument; past ~128KB Linux rejects
# it with E2BIG, and the failure was swallowed: exit 0, empty stdout. This is
# the live-graph size, seeded directly because 2500 `wv add` calls would not be.
setup_repo
sqlite3 "$WV_DB" "
    INSERT INTO nodes (id, text, status, metadata)
    WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM seq WHERE n < 2500)
    SELECT 'wv-bulk' || printf('%05d', n), 'bulk ' || n, 'todo',
           json_object('commits', json_array(printf('%040d', n)))
    FROM seq;"
set +e
BULK_OUT=$($WV commit-refs --all --json 2>/dev/null)
BULK_RC=$?
set -e
assert_equals "0" "$BULK_RC" "--all --json exits 0 on a graph large enough to blow the old arg limit"
assert_equals "2500" "$(echo "$BULK_OUT" | jq -r '.refs | length' 2>/dev/null)" "every seeded ref is present in the JSON"
if [ "$(( $(printf '%s' "$BULK_OUT" | wc -c) ))" -gt 131072 ]; then
    echo -e "  ${GREEN}✓${NC} payload exceeds the 128KB per-argument limit that used to break it"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "  ${RED}✗${NC} payload too small to exercise the arg-limit path"
fi
TESTS_RUN=$((TESTS_RUN + 1))

# ── no composer may put a payload in argv ─────────────────────────────────
# MAX_ARG_STRLEN (131072 on Linux) applies per argument, so a --argjson payload
# past it fails execve with E2BIG before jq starts — which surfaced as empty
# stdout with exit 0 in `wv context` (f3375783) and was measured biting a
# consumer at 540 nodes. The same shape was still present in tree, impact and
# discover. This asserts the mechanism directly rather than hoping a fixture
# grows large enough to trip it.
python3 -c "import json;print(json.dumps([{'id':'wv-%06d'%i,'text':'x'*60} for i in range(2200)]))" > "$TEST_DIR/big.json" 2>/dev/null
if [ -s "$TEST_DIR/big.json" ]; then
    set +e
    jq -n --argjson big "$(cat "$TEST_DIR/big.json")" '$big|length' >/dev/null 2>&1
    argjson_rc=$?
    jq -n --slurpfile big "$TEST_DIR/big.json" '$big[0]|length' >/dev/null 2>&1
    slurp_rc=$?
    set -e
    assert_equals "0" "$slurp_rc" "a 200KB payload passes through --slurpfile"
    # macOS has no per-argument limit (MAX_ARG_STRLEN is Linux's), so there
    # the control cannot fire: a skip, not a failed test (wv-7551b6).
    if [ "$argjson_rc" -eq 0 ]; then
        echo -e "  ${YELLOW}-${NC} this platform accepts a 200KB argv entry; the E2BIG control is inert here (skipped)"
    else
        echo -e "  ${GREEN}✓${NC} the same payload through --argjson fails (E2BIG), which is why composers use files"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        TESTS_RUN=$((TESTS_RUN + 1))
    fi
fi
# The structural rule that no composer passes a payload through --argjson lives
# in tests/test-argjson-payload.sh: the grep that stood here read one module and
# only names ending in json or rows, so other modules kept the shape (wv-200d36).

echo ""
echo "═══════════════════════════════════════════════════════════════════════════"
echo "Prevention: epic aggregation does not re-acquire a stale child ref"
echo "═══════════════════════════════════════════════════════════════════════════"

# The reason cleanup has to reach the children: _aggregate_epic_commits rebuilds
# the epic's commits list from its children on every close, so an epic-only edit
# is undone on the next sync (wv-99893f kept re-acquiring 61b9fcab from
# wv-f1aec5). The filter has to reject the stale SHA at aggregation time.
setup_repo
EPIC=$($WV add "epic: parent" 2>/dev/null | tail -1)
CHILD=$($WV add "task: child" --parent="$EPIC" 2>/dev/null | tail -1)
SECOND=$($WV add "task: sibling" --parent="$EPIC" 2>/dev/null | tail -1)

echo six > six.txt
"${GIT[@]}" add six.txt
"${GIT[@]}" commit -qm "work: six"
"${GIT[@]}" push -q origin main
LIVE=$("${GIT[@]}" rev-parse HEAD)
echo seven > seven.txt
"${GIT[@]}" add seven.txt
"${GIT[@]}" commit -qm "work: seven"
STALE=$("${GIT[@]}" rev-parse HEAD)
"${GIT[@]}" reset -q --hard "$LIVE"

sqlite3 "$WV_DB" "UPDATE nodes SET metadata = json_set('{}', '\$.commits', json_array('$STALE')) WHERE id='$CHILD';"
sqlite3 "$WV_DB" "UPDATE nodes SET metadata = json_set('{}', '\$.commits', json_array('$LIVE')) WHERE id='$SECOND';"

$WV "done" "$SECOND" --skip-verification >/dev/null 2>&1 || true
EPIC_COMMITS=$(sqlite3 "$WV_DB" "SELECT COALESCE(json_extract(metadata,'\$.commits'),'[]') FROM nodes WHERE id='$EPIC';")
assert_contains "$EPIC_COMMITS" "$LIVE" "epic aggregates the live child ref"
if [[ "$EPIC_COMMITS" == *"$STALE"* ]]; then
    echo -e "  ${RED}✗${NC} epic re-acquired the stale child ref"
    TESTS_RUN=$((TESTS_RUN + 1))
else
    echo -e "  ${GREEN}✓${NC} epic does not re-acquire the stale child ref"
    TESTS_PASSED=$((TESTS_PASSED + 1))
    TESTS_RUN=$((TESTS_RUN + 1))
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════════════"
echo "Epic aggregation keeps the epic's own commits"
echo "═══════════════════════════════════════════════════════════════════════════"

# A child close replaced the epic's commits with the children's union, dropping
# the epic's own direct refs (wv-ece542 lost 13 on 2026-11-09, wv-3c1663). The
# epic keeps its own live refs; its own stale refs still go through the filter.
setup_repo
EPIC=$($WV add "epic: own commits" 2>/dev/null | tail -1)
CHILD=$($WV add "task: child" --parent="$EPIC" 2>/dev/null | tail -1)

echo own > own.txt
"${GIT[@]}" add own.txt
"${GIT[@]}" commit -qm "work: epic own"
OWN=$("${GIT[@]}" rev-parse HEAD)
echo kid > kid.txt
"${GIT[@]}" add kid.txt
"${GIT[@]}" commit -qm "work: child"
KID=$("${GIT[@]}" rev-parse HEAD)
"${GIT[@]}" push -q origin main
echo gone > gone.txt
"${GIT[@]}" add gone.txt
"${GIT[@]}" commit -qm "work: epic stale"
OWN_STALE=$("${GIT[@]}" rev-parse HEAD)
"${GIT[@]}" reset -q --hard "$KID"

sqlite3 "$WV_DB" "UPDATE nodes SET metadata = json_set(COALESCE(metadata,'{}'), '\$.commits', json_array('$OWN', '$OWN_STALE')) WHERE id='$EPIC';"
sqlite3 "$WV_DB" "UPDATE nodes SET metadata = json_set('{}', '\$.commits', json_array('$KID')) WHERE id='$CHILD';"

$WV "done" "$CHILD" --skip-verification >/dev/null 2>&1 || true
EPIC_COMMITS=$(sqlite3 "$WV_DB" "SELECT COALESCE(json_extract(metadata,'\$.commits'),'[]') FROM nodes WHERE id='$EPIC';")
assert_contains "$EPIC_COMMITS" "$OWN" "epic keeps its own commit after a child close"
assert_contains "$EPIC_COMMITS" "$KID" "epic gains the child's commit"
if [[ "$EPIC_COMMITS" == *"$OWN_STALE"* ]]; then
    echo -e "  ${RED}✗${NC} epic kept its own stale ref"
    TESTS_RUN=$((TESTS_RUN + 1))
else
    echo -e "  ${GREEN}✓${NC} epic's own stale ref is filtered"
    TESTS_PASSED=$((TESTS_PASSED + 1))
    TESTS_RUN=$((TESTS_RUN + 1))
fi

# Same class at the epic's own close: _store_node_commits wrote only the SHAs
# git log attributes to the epic, replacing the aggregated child union.
"${GIT[@]}" commit -q --allow-empty -m "work: epic close

Weave-ID: $EPIC"
CLOSE_SHA=$("${GIT[@]}" rev-parse HEAD)
$WV "done" "$EPIC" --skip-verification >/dev/null 2>&1 || true
EPIC_COMMITS=$(sqlite3 "$WV_DB" "SELECT COALESCE(json_extract(metadata,'\$.commits'),'[]') FROM nodes WHERE id='$EPIC';")
assert_contains "$EPIC_COMMITS" "$CLOSE_SHA" "epic close records its own Weave-ID commit"
assert_contains "$EPIC_COMMITS" "$KID" "epic close keeps the aggregated child commit"
assert_contains "$EPIC_COMMITS" "$OWN" "epic close keeps its earlier own commit"

echo ""
echo "═══════════════════════════════════════════════════════════════════════════"
echo "Doctor advisory"
echo "═══════════════════════════════════════════════════════════════════════════"

setup_repo
NODE=$($WV add "task: orphan for doctor" 2>/dev/null | tail -1)
record_ref "$NODE" "0123456789012345678901234567890123456789"
DOC=$($WV doctor --json 2>/dev/null || true)
CHECK=$(echo "$DOC" | jq -r '.checks[]? | select(.check == "commit refs") | .status' 2>/dev/null || echo "")
assert_equals "warn" "$CHECK" "doctor warns while orphaned refs exist"

$WV commit-refs --prune >/dev/null 2>&1
DOC=$($WV doctor --json 2>/dev/null || true)
CHECK=$(echo "$DOC" | jq -r '.checks[]? | select(.check == "commit refs") | .status' 2>/dev/null || echo "")
assert_equals "pass" "$CHECK" "doctor passes once the orphans are gone"

cd "$REPO_ROOT"
rm -rf "$TEST_DIR"

echo ""
echo "═══════════════════════════════════════════════════════════════════════════"
echo -e "Tests: $TESTS_PASSED/$TESTS_RUN passed (${TESTS_XFAIL} xfail)"
if [ "$((TESTS_PASSED + TESTS_XFAIL))" -eq "$TESTS_RUN" ]; then
    echo -e "${GREEN}All tests passed!${NC}"
    exit 0
else
    echo -e "${RED}Some tests failed.${NC}"
    exit 1
fi
