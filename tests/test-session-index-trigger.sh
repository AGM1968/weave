#!/usr/bin/env bash
# test-session-index-trigger.sh — session start rebuilds an empty or stale
# code-search index in the background (wv-ecbe60).
#
# The index (brain.db chunks) lives in the hot zone by design and is never
# serialised to .weave/, so a fresh zone leaves wv search --code with nothing.
# _ss_code_index_refresh starts a detached wv index when the index is empty or
# was built for another HEAD, in the mode it was built in, and never blocks
# session start. Driven here with a stub wv that records its arguments.

set -euo pipefail
export WV_TEST_SUITE=1
export WV_CALL_SOURCE=test
unset GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0 GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
unset WV_WORKFLOW_ID WV_SESSION_INDEX

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

pass=0
run=0
ok() { echo "  ✓ $1"; pass=$((pass + 1)); run=$((run + 1)); }
bad() { echo "  ✗ $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/      /'; run=$((run + 1)); }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected: $2"$'\n'"actual:   $3"; fi; }
has() { if [[ "$3" == *"$2"* ]]; then ok "$1"; else bad "$1" "missing '$2' in: $3"; fi; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# shellcheck source=../scripts/lib/wv-session-start.sh
source "$PROJECT_ROOT/scripts/lib/wv-session-start.sh"

REPO="$TMP/repo"
git init -q "$REPO"
git -C "$REPO" -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false \
    commit -q --allow-empty -m one
HEAD1=$(git -C "$REPO" rev-parse HEAD)

# A stub wv: records its arguments, then sleeps briefly so a detached run can
# be told from a blocking one.
WV="$TMP/wv-stub"
cat > "$WV" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_LOG"
sleep "${STUB_SLEEP:-0}"
STUB
chmod +x "$WV"
export WV STUB_LOG="$TMP/calls"

new_zone() {  # new_zone <dir> [rows] [embedded] [symbols] -> a hot zone with a chunks table
    mkdir -p "$1"
    sqlite3 "$1/brain.db" "CREATE TABLE chunks (id INTEGER PRIMARY KEY, file TEXT NOT NULL,
        line_start INTEGER NOT NULL, line_end INTEGER NOT NULL, content TEXT NOT NULL, embedding BLOB);"
    if [ "${4:-1}" = 1 ]; then
        sqlite3 "$1/brain.db" "CREATE TABLE code_symbols (name TEXT, file TEXT, line INTEGER, kind TEXT);"
    fi
    if [ "${2:-0}" = 1 ]; then
        if [ "${3:-0}" = 1 ]; then
            sqlite3 "$1/brain.db" "INSERT INTO chunks(file,line_start,line_end,content,embedding) VALUES ('a.sh',1,2,'x',X'00');"
        else
            sqlite3 "$1/brain.db" "INSERT INTO chunks(file,line_start,line_end,content) VALUES ('a.sh',1,2,'x');"
        fi
    fi
}
refresh() {  # refresh <zone> -> the helper's output, with WV_DB pointing at the zone
    WV_DB="$1/brain.db" WV_SESSION_INDEX="${OPT_IN-1}" _ss_code_index_refresh "$REPO" "$1"
}
settle() {  # settle <zone> -> wait (bounded) for a started build to finish
    local i
    for i in $(seq 1 50); do [ -d "$1/.code_index.lock" ] || return 0; sleep 0.1; done
}
calls() { cat "$STUB_LOG" 2>/dev/null || true; }

echo "Session start rebuilds an empty or stale code index (wv-ecbe60)"

echo "=== empty index ==="
: > "$STUB_LOG"
new_zone "$TMP/z1"
out=$(refresh "$TMP/z1")
has "an empty index is announced" "Code index: empty in this hot zone" "$out"
settle "$TMP/z1"
check "...and built without embeddings, from the repository root" "index $REPO --no-embed --json" "$(calls)"
check "...and the HEAD it was built for is recorded" "$HEAD1" "$(cat "$TMP/z1/.code_index_head" 2>/dev/null)"

echo "=== current index ==="
: > "$STUB_LOG"
new_zone "$TMP/z2" 1
printf '%s\n' "$HEAD1" > "$TMP/z2/.code_index_head"
check "populated and built for HEAD: silent" "" "$(refresh "$TMP/z2")"
settle "$TMP/z2"
check "...and no build" "" "$(calls)"

echo "=== an index without the definition table is out of date (wv-35b5bd) ==="
: > "$STUB_LOG"
new_zone "$TMP/z8" 1 0 0
printf '%s\n' "$HEAD1" > "$TMP/z8/.code_index_head"
has "chunks for HEAD but no definition table: refreshed" "out of date" "$(refresh "$TMP/z8")"
settle "$TMP/z8"
check "...rebuilt in its mode" "index $REPO --no-embed --json" "$(calls)"

echo "=== stale index keeps its mode ==="
: > "$STUB_LOG"
new_zone "$TMP/z3" 1 1
printf 'older\n' > "$TMP/z3/.code_index_head"
has "built for another HEAD: announced as a refresh" "out of date" "$(refresh "$TMP/z3")"
settle "$TMP/z3"
check "...rebuilt with embeddings, as it was built" "index $REPO --json" "$(calls)"
: > "$STUB_LOG"
new_zone "$TMP/z4" 1 0
printf 'older\n' > "$TMP/z4/.code_index_head"
refresh "$TMP/z4" >/dev/null
settle "$TMP/z4"
check "an index built without embeddings is rebuilt without them" "index $REPO --no-embed --json" "$(calls)"

echo "=== never blocks session start ==="
: > "$STUB_LOG"
new_zone "$TMP/z5"
start=$(date +%s)
STUB_SLEEP=3 refresh "$TMP/z5" >/dev/null
check "a three-second build returns at once" "fast" "$([ $(( $(date +%s) - start )) -lt 2 ] && echo fast || echo blocked)"
check "...and a second session start while it runs starts no second build" "" "$(refresh "$TMP/z5")"
settle "$TMP/z5"; sleep 0.2
check "...one build in all" "1" "$(calls | grep -c . || true)"

echo "=== a stale lock does not block forever ==="
: > "$STUB_LOG"
new_zone "$TMP/z6"
mkdir "$TMP/z6/.code_index.lock"; python3 -I -c 'import os, sys; t = float(sys.argv[1]); os.utime(sys.argv[2], (t, t))' "$(( $(date +%s) - 1200 ))" "$TMP/z6/.code_index.lock"  # touch -d is GNU-only (wv-f6b909)
has "a lock older than ten minutes is cleared" "Code index: empty" "$(refresh "$TMP/z6")"
settle "$TMP/z6"

echo "=== skipped where it must not run ==="
: > "$STUB_LOG"
new_zone "$TMP/z7"
check "WV_SESSION_INDEX=0: nothing" "" "$(OPT_IN=0 refresh "$TMP/z7")"
check "under a test suite without opting in: nothing" "" "$(OPT_IN='' refresh "$TMP/z7")"
check "inside a counted E5 window: nothing" "" "$(WV_WORKFLOW_ID=wf refresh "$TMP/z7")"
check "outside a repository: nothing" "" "$(WV_DB="$TMP/z7/brain.db" WV_SESSION_INDEX=1 _ss_code_index_refresh "$TMP/none" "$TMP/z7")"
check "...and no build in any of those" "" "$(calls)"

echo "=== graph state untouched ==="
check "nothing is written outside the hot zone" "" "$(git -C "$REPO" status --porcelain)"

echo ""
echo "Results: $pass/$run passed"
[ "$pass" -eq "$run" ]
