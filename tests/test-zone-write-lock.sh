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
#
# The lock comes from scripts/lib/wv-lock.sh (wv-7faa60): flock(1), else python3
# fcntl.flock on the same fd, else refuse. The whole suite runs once per
# mechanism this host has (WV_TEST_LOCK_MECH forces it): on Linux both, on
# macOS python only, so no host skips. A last run with no mechanism checks
# that a writer refuses instead of writing unlocked.
set -uo pipefail
export WV_CALL_SOURCE=test
export WV_TEST_SUITE=1  # the user's config.env cannot log this suite's wv calls (wv-6b0f57)
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WV="$ROOT/scripts/wv"
run=0; pass=0
ok()  { run=$((run+1)); pass=$((pass+1)); echo "  ✓ $1"; }
bad() { run=$((run+1)); echo "  ✗ $1"; [ -n "${2:-}" ] && echo "      $2"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$3] got [$2]"; fi; }

if [ -z "${1:-}" ]; then
    mechs="python"; command -v flock >/dev/null 2>&1 && mechs="flock python"
    command -v python3 >/dev/null 2>&1 || mechs="${mechs/python/}"
    total_run=0; total_pass=0; rc=0
    for m in $mechs none; do
        echo "##### lock mechanism: $m"
        out=$(bash "$0" "$m" 2>&1) || rc=1
        printf '%s\n' "$out" | grep -v '^Results:'
        r=$(printf '%s\n' "$out" | sed -n 's/^Results: \([0-9]*\)\/\([0-9]*\) passed$/\1 \2/p')
        [ -n "$r" ] || { echo "  ✗ the $m run printed no result"; rc=1; continue; }
        total_pass=$((total_pass + ${r% *})); total_run=$((total_run + ${r#* }))
    done
    echo ""
    echo "Results: $total_pass/$total_run passed"
    [ "$rc" -eq 0 ] && [ "$total_pass" -eq "$total_run" ]
    exit $?
fi
export WV_TEST_MODE=1 WV_TEST_LOCK_MECH="$1"
# shellcheck disable=SC1091  # resolved from ROOT at run time
source "$ROOT/scripts/lib/wv-lock.sh"
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
if [ "$1" = none ]; then
    WV_TEST_LOCK_MECH=flock "$WV" init >/dev/null 2>&1
    command -v flock >/dev/null 2>&1 || WV_TEST_LOCK_MECH=python "$WV" init >/dev/null 2>&1
    echo "=== with no lock mechanism a writer refuses ==="
    out=$("$WV" add "unlocked" --force 2>&1); rc=$?
    check "wv add exits 1" "$rc" "1"
    check "and says no lock mechanism exists" "$(grep -c 'no file-lock mechanism' <<< "$out")" "1"
    check "and wrote nothing" "$(WV_TEST_LOCK_MECH=python "$WV" list --json 2>/dev/null | grep -c unlocked)" "0"
    echo "=== wv_lock_run with no lock mechanism (wv-7bd071) ==="
    out=$(wv_lock_run "$T/run.lock" -x 1 touch "$T/ran" 2>&1); rc=$?
    check "wv_lock_run returns 2" "$rc" "2"
    check "...without running the command" "$([ -e "$T/ran" ] && echo ran || echo not-run)" "not-run"
    echo ""
    echo "Results: $pass/$run passed"
    [ "$pass" -eq "$run" ]
    exit $?
fi
"$WV" init >/dev/null 2>&1
"$WV" add "seed" --force >/dev/null 2>&1
LOCK="$WV_HOT_ZONE/.write.lock"
DB=$("$WV" hotzone --db 2>/dev/null)
[ -f "$DB" ] || { echo "  ✗ fixture: no database at [$DB]"; exit 1; }

hold() {  # hold <-s|-x> — a process holding the zone lock until released
    # exec: the sleep IS the holder, so release's kill frees the lock even when
    # a trap stops bash exec'ing a subshell's last command (wv-b1b61e).
    ( exec 9>>"$LOCK"; wv_lock_fd 9 "$1" 10 && touch "$T/held"; exec sleep 300 ) & HOLD_PID=$!
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

echo "=== wv_lock_run: flock FILE COMMAND without flock(1) (wv-7bd071) ==="
check "it returns the command's status" "$(wv_lock_run "$T/run.lock" -x 5 sh -c 'exit 7'; echo $?)" "7"
check "it holds the lock while the command runs" \
    "$(wv_lock_run "$T/run.lock" -x 5 bash -c 'source "$1"; exec 6>>"$2"; wv_lock_fd 6 -x 0 && echo free || echo held' _ "$ROOT/scripts/lib/wv-lock.sh" "$T/run.lock")" "held"
check "...and releases it when the command ends" \
    "$(bash -c 'source "$1"; exec 6>>"$2"; wv_lock_fd 6 -x 0 && echo free || echo held' _ "$ROOT/scripts/lib/wv-lock.sh" "$T/run.lock")" "free"
LOCK_SAVE=$LOCK; LOCK="$T/run.lock"; hold -x
out=$(wv_lock_run "$T/run.lock" -x 1 touch "$T/ran" 2>&1); rc=$?
check "another holder past the wait: it returns 1" "$rc" "1"
check "...without running the command" "$([ -e "$T/ran" ] && echo ran || echo not-run)" "not-run"
check "...and says the lock was held" "$(grep -c 'was held past 1s' <<< "$out")" "1"
release; LOCK=$LOCK_SAVE
check "an unopenable lock file is refused, and stderr still works after it" \
    "$( { wv_lock_run "$T/no/such/dir/x.lock" -x 1 true; echo "rc=$?" >&2; } 2>&1 | tr '\n' ' ')" \
    "wv: cannot open the lock file $T/no/such/dir/x.lock rc=1 "
check "a wait that is not whole seconds is refused" "$(wv_lock_run "$T/run.lock" -x 1.5 true 2>/dev/null; echo $?)" "1"

echo ""
echo "Results: $pass/$run passed"
[ "$pass" -eq "$run" ]
