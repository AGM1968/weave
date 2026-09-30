#!/usr/bin/env bash
# Suite-driven wv calls are tagged test so call-stats retro reads can exclude them.
export WV_CALL_SOURCE=test
# Size-bounded rotation for the analytics call log.
#
# The log had no rotation, truncation or retention logic anywhere in the tree,
# so it only grew: 401MB and 649k lines on the first host to enable it, and
# every reader paid for the whole history (wv-eff01c). Rotation keeps one
# previous generation, so the bound on disk is twice WV_CALL_LOG_MAX_BYTES.
#
# WV_CONFIG_DIR is isolated in every case: config.env is sourced `set -a` and
# sets WV_CALL_LOG durably, so it would otherwise override the ambient value
# these cases depend on.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WV="$ROOT/scripts/wv"

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
run=0; pass=0
ok() { run=$((run+1)); pass=$((pass+1)); echo -e "  ${GREEN}✓${NC} $1"; }
bad() { run=$((run+1)); echo -e "  ${RED}✗${NC} $1"; [ -n "${2:-}" ] && echo "      $2"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2], got [$3]"; fi; }

TEST_DIR=$(mktemp -d /tmp/wv-callrot-XXXXXX)
trap 'chmod -R u+w "$TEST_DIR" 2>/dev/null; rm -rf "$TEST_DIR"' EXIT
mkdir -p "$TEST_DIR/config"
LOG="$TEST_DIR/calls.jsonl"

fill() { head -c "$1" /dev/zero | tr '\0' 'x' > "$LOG"; }
call() { # $1 = WV_CALL_LOG_MAX_BYTES
    env WV_CONFIG_DIR="$TEST_DIR/config" WV_CALL_LOG="$LOG" \
        WV_CALL_LOG_MAX_BYTES="$1" "$WV" --version >/dev/null 2>&1
}
rotated() { [ -f "$LOG.1" ] && echo yes || echo no; }
reset() { rm -f "$LOG" "$LOG.1"; }

echo "call log rotation"

# over the bound
reset; fill 2000; call 1000
check "rotates when the log exceeds the bound" "yes" "$(rotated)"
check "previous generation keeps the old bytes" "2000" "$(stat -c %s "$LOG.1" 2>/dev/null || echo missing)"
if [ -s "$LOG" ] && grep -q '"cmd"' <<< "$(head -1 "$LOG")"; then
    ok "new log starts fresh and takes the current row"
else
    bad "new log starts fresh and takes the current row" "log: $(head -c 60 "$LOG" 2>/dev/null)"
fi

# under the bound
reset; : > "$LOG"; call 1000000
check "does not rotate below the bound" "no" "$(rotated)"

# explicitly disabled
reset; fill 2000; call 0
check "bound of 0 disables rotation" "no" "$(rotated)"

# malformed bound is ignored rather than fatal
reset; fill 2000; call "not-a-number"
check "non-numeric bound does not rotate" "no" "$(rotated)"
reset; fill 2000
env WV_CONFIG_DIR="$TEST_DIR/config" WV_CALL_LOG="$LOG" WV_CALL_LOG_MAX_BYTES=abc \
    "$WV" --version >/dev/null 2>&1
check "non-numeric bound does not fail the command" "0" "$?"

# exactly one generation is kept
reset; fill 2000; call 1000
first_gen=$(stat -c %s "$LOG.1" 2>/dev/null)
fill 2000; call 1000
check "second rotation replaces the single previous generation" "2000" "$(stat -c %s "$LOG.1" 2>/dev/null || echo missing)"
check "only one previous generation exists" "1" "$(find "$TEST_DIR" -name 'calls.jsonl.*' | wc -l)"
[ -n "$first_gen" ] || bad "first generation was recorded" "stat failed"

# rotation is best-effort: an unwritable directory must not fail the command
reset; fill 2000
chmod a-w "$TEST_DIR"
env WV_CONFIG_DIR="$TEST_DIR/config" WV_CALL_LOG="$LOG" WV_CALL_LOG_MAX_BYTES=1000 \
    "$WV" --version >/dev/null 2>&1
rc=$?
chmod u+w "$TEST_DIR"
check "unwritable log dir does not fail the command" "0" "$rc"

echo ""
echo "  $pass/$run passed"
[ "$pass" -eq "$run" ]
