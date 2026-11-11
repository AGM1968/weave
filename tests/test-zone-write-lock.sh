#!/usr/bin/env bash
# test-zone-write-lock.sh — writers and wv load exclude each other on one hot
# zone (wv-8f2df1, owner ruling 2026-11-11).
#
# wv load flushes the live graph, builds a new one from .weave/ and installs it.
# A write from another session between the flush and the install was lost:
# measured 0-3 of 40 reported writes per run, with back-to-back loads in a
# second session. Graph writers now hold a shared flock on <zone>/.write.lock
# and load/init hold it exclusively. The checks below are deterministic (a lock
# held by hand stands in for the other session), plus one race smoke run.
set -uo pipefail
export WV_CALL_SOURCE=test
export WV_TEST_SUITE=1  # the user's config.env cannot log this suite's wv calls (wv-6b0f57)
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WV="$ROOT/scripts/wv"
run=0; pass=0
ok()  { run=$((run+1)); pass=$((pass+1)); echo "  ✓ $1"; }
bad() { run=$((run+1)); echo "  ✗ $1"; [ -n "${2:-}" ] && echo "      $2"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$3] got [$2]"; fi; }

command -v flock >/dev/null 2>&1 || { echo "SKIP: no flock"; echo "Results: 0/0 passed"; exit 0; }
T=$(mktemp -d /tmp/wv-zone-lock-XXXXXX)
HOLD_PID=""
release() { [ -z "$HOLD_PID" ] || { kill "$HOLD_PID" 2>/dev/null; wait "$HOLD_PID" 2>/dev/null; }; HOLD_PID=""; }
trap 'release; rm -rf "$T"' EXIT
mkdir -p "$T/cfg"
git init -q -b main "$T/repo"
cd "$T/repo" || exit 1
# Placement as a session has it: WV_HOT_ZONE only. An explicit WV_DB turns off
# the per-write publish, which is the condition the race depends on.
unset WV_DB WV_AGENT_ID WV_SESSION_ID WV_ZONE_LOCK_HELD GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
export WV_CONFIG_DIR="$T/cfg" WV_PROJECT_DIR="$T/repo" WV_HOT_ZONE="$T/hot"
export WV_AUTO_CHECKPOINT=0 WV_REQUIRE_LEARNING=0 WV_RUN_CACHE=0
"$WV" init >/dev/null 2>&1
"$WV" add "seed" --force >/dev/null 2>&1
LOCK="$WV_HOT_ZONE/.write.lock"
DB=$("$WV" hotzone --db 2>/dev/null)
[ -f "$DB" ] || { echo "  ✗ fixture: no database at [$DB]"; exit 1; }

hold() {  # hold <-s|-x> — a process holding the zone lock until released
    # exec: the sleep IS the holder, so release's kill frees the lock even when
    # a trap stops bash exec'ing a subshell's last command (wv-b1b61e).
    ( exec 9>>"$LOCK"; flock "$1" 9; touch "$T/held"; exec sleep 300 ) & HOLD_PID=$!
    for _ in $(seq 1 100); do [ -f "$T/held" ] && break; sleep 0.1; done
    # Every check after this assumes the lock is held; one that is not would
    # pass or fail for the wrong reason.
    [ -f "$T/held" ] || { echo "  ✗ fixture: hold $1 did not acquire $LOCK in 10s"; exit 1; }
    rm -f "$T/held"
}

echo "=== a writer mid-command keeps wv load out ==="
hold -s
out=$(WV_ZONE_LOCK_TIMEOUT=1 "$WV" load 2>&1); rc=$?
check "wv load waits, then stops with 75" "$rc" "75"
check "and says the zone is in use" "$(grep -c 'hot zone is in use by another wv process' <<< "$out")" "1"
before=$(sqlite3 "$DB" "SELECT count(*) FROM nodes;")
check "a second writer is not kept out by the first" \
    "$(WV_ZONE_LOCK_TIMEOUT=1 "$WV" add "beside a writer" --force >/dev/null 2>&1; echo $?)" "0"
# A second session starting while the first writes: its load is skipped after
# a short wait, and the session is told why, instead of hanging or replacing
# the live graph.
out=$(echo '{}' | WV_SESSION_START_LOAD_WAIT=1 "$WV" hook dispatch --event=SessionStart --format=host 2>/dev/null)
check "session start skips the load and says so" "$(grep -c 'wv load skipped at session start' <<< "$out")" "1"
release

echo "=== a load in progress keeps writers out ==="
hold -x
out=$(WV_ZONE_LOCK_TIMEOUT=1 "$WV" add "during a load" --force 2>&1); rc=$?
check "a writer waits, then fails loudly" "$rc" "1"
check "and says to retry" "$(grep -c 'held the hot zone past 1s; add did not run. Retry it.' <<< "$out")" "1"
check "and wrote nothing" "$(sqlite3 "$DB" "SELECT count(*) FROM nodes;")" "$((before + 1))"
check "reads do not wait" "$(WV_ZONE_LOCK_TIMEOUT=1 "$WV" list >/dev/null 2>&1; echo $?)" "0"
check "a child of the holder does not wait on it" \
    "$(WV_ZONE_LOCK_HELD="$LOCK" WV_ZONE_LOCK_TIMEOUT=1 "$WV" add "child of the holder" --force >/dev/null 2>&1; echo $?)" "0"
release

echo "=== race smoke: writes during back-to-back loads in another session ==="
rm -f "$T/w.out"
( for i in $(seq 1 12); do
    out=$(WV_SESSION_ID=sessB "$WV" add "race $i" --force 2>&1); r=$?
    echo "$r $(grep -oE 'wv-[0-9a-f]{6}' <<< "$out" | tail -1)" >> "$T/w.out"
  done ) & WP=$!
loads=0
while kill -0 "$WP" 2>/dev/null; do WV_SESSION_ID=sessA "$WV" load >/dev/null 2>&1; loads=$((loads+1)); done
wait "$WP"
"$WV" load >/dev/null 2>&1
DB=$("$WV" hotzone --db 2>/dev/null)
lost=0; failed=0
while read -r r id; do
    if [ "$r" != 0 ] || [ -z "$id" ]; then failed=$((failed+1)); continue; fi
    [ "$(sqlite3 "$DB" "SELECT count(*) FROM nodes WHERE id='$id';")" = 1 ] || lost=$((lost+1))
done < "$T/w.out"
check "no write that reported success is lost ($loads loads ran)" "$lost" "0"
check "no write failed" "$failed" "0"

echo ""
echo "Results: $pass/$run passed"
[ "$pass" -eq "$run" ]
