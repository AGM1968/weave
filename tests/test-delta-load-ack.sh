#!/usr/bin/env bash
# test-delta-load-ack.sh -- Stage B prerequisite 1 (wv-4e35c0) of
# docs/PROPOSAL-delta-retention.md: a load acknowledges only a full
# absorption, and names what it absorbed as a checkpoint (the git tree id of
# state.sql plus deltas/), not a commit.
#
# The first draft acknowledged every load. Each failure case below (a v1
# corrupt file, a v1 rollback, a v2 hard disposition, a catalog that moved
# during the load) is a load that warns and continues; against that rule
# every one of them would be acknowledged.
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
ACK="$REPO_ROOT/scripts/lib/wv-load-ack.py"

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export WV_CONFIG_DIR="$T/cfg"
export WV_AGENT_ID="ack-test"
export WV_REQUIRE_LEARNING=0
export WV_AUTO_CHECKPOINT=0
export WV_NONINTERACTIVE=1
export WV_SYNC_INTERVAL=0
mkdir -p "$WV_CONFIG_DIR"

pass=0; run=0
ok()  { echo "  ✓ $1"; pass=$((pass + 1)); run=$((run + 1)); }
bad() { echo "  ✗ $1"; run=$((run + 1)); }
check() { local msg="$1"; shift; if "$@"; then ok "$msg"; else bad "$msg"; fi; }

use() {
    export WV_PROJECT_DIR="$1" WEAVE_DIR="$1/.weave" WV_HOT_ZONE="$1/.hot"
    unset WV_DB
    mkdir -p "$WV_HOT_ZONE"; chmod 700 "$WV_HOT_ZONE"
    cd "$1" || exit 1
}
db() { echo "$WV_HOT_ZONE/brain.db"; }
add_node() { "$WV" add "$1" --criteria=c --risks=low 2>&1 | sed -nE 's/^✓ (wv-[a-f0-9]{6}): .*/\1/p' | head -1; }
ack() { python3 "$ACK" show "$(db)" 2>/dev/null; }
attempt() { sqlite3 "$(db)" "SELECT state FROM _weave_load_attempt;" 2>/dev/null; }
reasons() { sqlite3 "$(db)" "SELECT reasons FROM _weave_load_attempt;" 2>/dev/null; }
now_checkpoint() { python3 "$ACK" checkpoint "$WEAVE_DIR"; }

# git's own tree id for the load inputs of a .weave directory, through a
# scratch repository and a temporary index.
git_tree() {
    local w="$1" g="$T/gtree"
    rm -rf "$g"; git init -q "$g"
    (cd "$w" && { [ -f state.sql ] && echo state.sql; find deltas -type f 2>/dev/null; } | LC_ALL=C sort \
        | while IFS= read -r p; do printf '100644 %s\t%s\n' "$(git hash-object --no-filters "$p")" "$p"; done) \
        | (cd "$g" && GIT_INDEX_FILE="$g/idx" git update-index --index-info \
            && GIT_INDEX_FILE="$g/idx" git write-tree --missing-ok)
}

# ── checkpoint ──────────────────────────────────────────────────────────────
echo "--- checkpoint ---"
C="$T/cp"; mkdir -p "$C/.weave/deltas/2026-11-01" "$C/.weave/deltas/v2"
printf 'state\n' > "$C/.weave/state.sql"
printf 'a\n' > "$C/.weave/deltas/2026-11-01/a.sql"
printf 'b\n' > "$C/.weave/deltas/v2/b.json"
nogit=$(python3 "$ACK" checkpoint "$C/.weave")
check "outside git: equals git write-tree" test "$nogit" = "$(git_tree "$C/.weave")"
(cd "$C" && git init -q && git config user.email t@t && git config user.name t \
    && git add -A && git commit -qm c)
check "a clean tree: the same id" test "$(python3 "$ACK" checkpoint "$C/.weave")" = "$nogit"
printf 'changed\n' > "$C/.weave/deltas/2026-11-01/a.sql"
printf 'new\n' > "$C/.weave/deltas/2026-11-01/c.sql"
rm "$C/.weave/deltas/v2/b.json"
check "a dirty tree (modified, untracked, deleted): equals git write-tree" \
    test "$(python3 "$ACK" checkpoint "$C/.weave")" = "$(git_tree "$C/.weave")"

# ── fixture ─────────────────────────────────────────────────────────────────
echo "--- full load ---"
R="$T/clone"; mkdir -p "$R"; use "$R"
git init -q && git config user.email t@t && git config user.name t
"$WV" init >/dev/null 2>&1
N=$(add_node "target")
"$WV" sync >/dev/null 2>&1
"$WV" update "$N" --text="edited" >/dev/null 2>&1
"$WV" sync >/dev/null 2>&1
git add -A >/dev/null && git commit -qm fixture
"$WV" load >"$T/load.out" 2>&1
check "acknowledged" test "$(attempt)" = complete
check "...naming the checkpoint of the tree it loaded" test "$(ack)" = "$(now_checkpoint)"
check "...which is git's tree id for those inputs" test "$(ack)" = "$(git_tree "$WEAVE_DIR")"
check "...with every input listed" test "$(sqlite3 "$(db)" "SELECT COUNT(*) FROM _weave_load_ack_files;")" \
    = "$( (cd "$WEAVE_DIR" && { echo state.sql; find deltas -type f; }) | wc -l | tr -d ' ')"
check "...including the v2 sidecars" test "$(sqlite3 "$(db)" "SELECT COUNT(*) FROM _weave_load_ack_files WHERE path LIKE '%/v2/%';")" -gt 0
check "...and nothing said about it" bash -c "! grep -q 'not acknowledged' '$T/load.out'"
"$WV" update "$N" --text="edited again" >/dev/null 2>&1
"$WV" sync >/dev/null 2>&1
check "the acknowledgement never reaches state.sql" bash -c "! grep -q '_weave_load_a' '$WEAVE_DIR/state.sql'"
good=$(now_checkpoint)

# reload LABEL -- load and record the output.
reload() { "$WV" load >"$T/$1.out" 2>&1; }

# ── loads that warn and continue are not acknowledged ───────────────────────
echo "--- v1 corrupt file ---"
"$WV" load >/dev/null 2>&1
check "precondition: acknowledged before the fault" test -n "$(ack)"
printf 'this is not sql at all\n' > "$WEAVE_DIR/deltas/zz-corrupt.sql"
reload corrupt
check "the load still succeeds with its warning" grep -q "Skipped corrupt delta" "$T/corrupt.out"
check "not acknowledged" test -z "$(ack)"
check "...the attempt failed, naming the file" bash -c "test \"\$1\" = failed && grep -q 'zz-corrupt.sql' <<< \"\$2\"" _ "$(attempt)" "$(reasons)"
check "...and the load says so" grep -q "Load not acknowledged" "$T/corrupt.out"
rm -f "$WEAVE_DIR/deltas/zz-corrupt.sql"

echo "--- v1 rollback ---"
printf 'INSERT INTO no_such_table VALUES (1);\n' > "$WEAVE_DIR/deltas/zz-rollback.sql"
reload rollback
check "the load still succeeds with its warning" grep -q "Delta replay failed" "$T/rollback.out"
check "not acknowledged" test -z "$(ack)"
check "...the attempt names the rollback" grep -q "v1 replay rolled back" <<< "$(reasons)"
rm -f "$WEAVE_DIR/deltas/zz-rollback.sql"

echo "--- v2 hard disposition ---"
side=$(find "$WEAVE_DIR/deltas" -path '*/v2/*.json' -type f | LC_ALL=C sort | tail -1)
cp "$side" "$T/side.bak"
printf '{' > "$side"
reload v2
check "the load still succeeds with its warning" grep -q "Delta v2 replay aborted" "$T/v2.out"
check "not acknowledged" test -z "$(ack)"
check "...the attempt names the v2 abort" grep -q "v2 replay aborted" <<< "$(reasons)"
cp "$T/side.bak" "$side"

echo "--- recovery ---"
reload recovered
check "the faults removed: acknowledged again" test "$(attempt)" = complete
check "...at the same checkpoint as before the faults" test "$(ack)" = "$good"

# ── catalog moving under the load ───────────────────────────────────────────
echo "--- race ---"
before=$(python3 "$ACK" digest "$WEAVE_DIR")
printf -- '-- no-op\n' > "$WEAVE_DIR/deltas/zz-late.sql"
rc=0; python3 "$ACK" finish "$(db)" "$WEAVE_DIR" "$before" 2>"$T/race.err" || rc="$?"
check "a file arriving after the digest: not acknowledged" test "$rc" -eq 3 -a -z "$(ack)"
check "...the attempt says the catalog changed" grep -q "catalog changed" "$T/race.err"
rm -f "$WEAVE_DIR/deltas/zz-late.sql"
rc=0; python3 "$ACK" finish "$(db)" "$WEAVE_DIR" "" 2>/dev/null || rc="$?"
check "no digest from before the load: not acknowledged" test "$rc" -eq 3 -a -z "$(ack)"
rc=0; python3 "$ACK" finish "$(db)" "$WEAVE_DIR" "$(python3 "$ACK" digest "$WEAVE_DIR")" >/dev/null || rc="$?"
check "an unchanged catalog: acknowledged" test "$rc" -eq 0 -a "$(ack)" = "$good"

echo ""
echo "$pass/$run passed"
[ "$pass" -eq "$run" ]
