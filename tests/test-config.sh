#!/bin/bash
# Suite-driven wv calls are tagged test so call-stats retro reads can exclude them.
export WV_CALL_SOURCE=test
# test-config.sh — Tests for `wv config`, the durable-knob front door, the honest
# session-analysis reader (O1a), and the doctor verification-gate checks (O2).
# Covers finding wv-e754b0 onboarding fixes.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WV="$REPO_ROOT/scripts/wv"

TESTS_RUN=0
TESTS_PASSED=0
RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'

assert_contains() {
    local haystack="$1" needle="$2" msg="${3:-contains}"
    if echo "$haystack" | grep -qF "$needle"; then
        echo -e "  ${GREEN}✓${NC} $msg"; TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}✗${NC} $msg"; echo "    expected to contain: '$needle'"; echo "    actual: '$haystack'"
    fi
    TESTS_RUN=$((TESTS_RUN + 1))
}

assert_not_contains() {
    local haystack="$1" needle="$2" msg="${3:-not contains}"
    if ! echo "$haystack" | grep -qF "$needle"; then
        echo -e "  ${GREEN}✓${NC} $msg"; TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}✗${NC} $msg"; echo "    expected NOT to contain: '$needle'"; echo "    actual: '$haystack'"
    fi
    TESTS_RUN=$((TESTS_RUN + 1))
}

assert_eq() {
    local expected="$1" actual="$2" msg="${3:-equals}"
    if [ "$expected" = "$actual" ]; then
        echo -e "  ${GREEN}✓${NC} $msg"; TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}✗${NC} $msg"; echo "    expected: '$expected'"; echo "    actual:   '$actual'"
    fi
    TESTS_RUN=$((TESTS_RUN + 1))
}

# ── Isolated environment ────────────────────────────────────────────────────
TEST_DIR=$(mktemp -d)
TMPCFG=$(mktemp -d)
export WV_CONFIG_DIR="$TMPCFG"
export WV_HOT_ZONE="$TEST_DIR/hz"
export WV_DB="$TEST_DIR/hz/brain.db"
mkdir -p "$WV_HOT_ZONE"
cleanup() { cd /tmp; rm -rf "$TEST_DIR" "$TMPCFG"; }
trap cleanup EXIT

cd "$TEST_DIR"
git init -q
git commit -q --allow-empty -m init 2>/dev/null || true

echo ""
echo "═══════════════════════════════════════════════════════════════════════════"
echo "  wv config — durable knobs, honest reader, doctor verification"
echo "═══════════════════════════════════════════════════════════════════════════"
echo ""

# ── session-analysis knob (config.env) ──────────────────────────────────────
out=$("$WV" config enable session-analysis 2>&1)
assert_contains "$out" "session-analysis enabled" "enable session-analysis reports success"
assert_contains "$(cat "$TMPCFG/config.env")" 'WV_CALL_LOG=' "config.env has WV_CALL_LOG"

# Re-enable must not duplicate the assignment.
"$WV" config enable session-analysis >/dev/null 2>&1
count=$(grep -c '^WV_CALL_LOG=' "$TMPCFG/config.env")
assert_eq "1" "$count" "re-enable does not duplicate WV_CALL_LOG"

# get reflects the disk value on a fresh invocation (proves disk-sourcing).
got=$("$WV" config get WV_CALL_LOG 2>&1)
assert_contains "$got" "wv_calls.jsonl" "config get returns disk-sourced value"

# disable removes it.
"$WV" config disable session-analysis >/dev/null 2>&1
assert_eq "0" "$(grep -c '^WV_CALL_LOG=' "$TMPCFG/config.env")" "disable removes WV_CALL_LOG"

# arbitrary set/get + invalid-key rejection.
"$WV" config set WV_DELTA_RETAIN_DAYS 14 >/dev/null 2>&1
assert_eq "14" "$("$WV" config get WV_DELTA_RETAIN_DAYS 2>&1)" "set/get round-trips a custom knob"
bad=$("$WV" config set notavar 1 2>&1 || true)
assert_contains "$bad" "invalid key" "set rejects a non-WV_ key"

bad_cfg="$TEST_DIR/not-a-dir"
printf 'occupied\n' > "$bad_cfg"
bad=$(WV_CONFIG_DIR="$bad_cfg" "$WV" config enable session-analysis 2>&1 || true)
assert_contains "$bad" "cannot create config directory" "enable session-analysis reports config directory failure"
assert_not_contains "$bad" "session-analysis enabled" "enable session-analysis does not report success after config failure"

# ── verification gate (durable quality.conf [thresholds]) ───────────────────
"$WV" config enable test-gate warn >/dev/null 2>&1
conf="$TEST_DIR/.weave/quality.conf"
assert_contains "$(cat "$conf")" "test_gate = 1" "enable test-gate warn writes [thresholds] test_gate=1"

# Upsert to block — must not duplicate the key.
"$WV" config enable test-gate block >/dev/null 2>&1
assert_eq "1" "$(grep -c 'test_gate' "$conf")" "upsert to block keeps a single test_gate line"
assert_contains "$(cat "$conf")" "test_gate = 2" "test-gate block sets test_gate=2"

# An [exempt] entry must survive a later threshold write.
printf '[exempt]\nvendor/\n' >> "$conf"
"$WV" config disable test-gate >/dev/null 2>&1
assert_contains "$(cat "$conf")" "vendor/" "[exempt] section preserved across threshold edits"
assert_contains "$(cat "$conf")" "test_gate = 0" "disable test-gate sets test_gate=0"

# ── O1a: honest session-analysis reader ─────────────────────────────────────
# Knob unset + log file missing -> instrumentation reported as disabled, not a
# phantom "no call log at <default>". Force the default path to a missing file.
out=$(env -u WV_CALL_LOG WV_CALL_LOG_DEFAULT="$TEST_DIR/absent.jsonl" "$WV" analyze sessions --call-stats 2>&1 || true)
assert_contains "$out" "instrumentation disabled" "reader reports OFF when knob unset + no file"
assert_not_contains "$out" "no call log found" "reader does not imply a phantom default path when OFF"

# ── O2: doctor verification-gate checks ─────────────────────────────────────
# Gate off (default) -> a verification-gate line is surfaced; durability/test-map
# lines are suppressed (nothing actionable).
sqlite3 "$WV_DB" "INSERT OR REPLACE INTO policy_thresholds(key,value) VALUES('test_gate',0);" 2>/dev/null || true
out=$("$WV" doctor 2>&1 || true)
assert_contains "$out" "verification gate" "doctor surfaces the verification gate"

# Gate set in the tmpfs DB only (no quality.conf) -> session-only WARN.
rm -f "$conf"
sqlite3 "$WV_DB" "INSERT OR REPLACE INTO policy_thresholds(key,value) VALUES('test_gate',1);" 2>/dev/null || true
out=$("$WV" doctor 2>&1 || true)
assert_contains "$out" "session-only" "doctor warns when gate is in DB but not durable"

echo ""
echo "═══════════════════════════════════════════════════════════════════════════"
echo -e "Results: $TESTS_PASSED/$TESTS_RUN passed"
if [ "$TESTS_PASSED" -eq "$TESTS_RUN" ]; then
    echo -e "${GREEN}All tests passed!${NC}"; exit 0
else
    echo -e "${RED}Some tests failed.${NC}"; exit 1
fi
