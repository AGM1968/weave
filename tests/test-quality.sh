#!/usr/bin/env bash
# test-quality.sh -- Test wv quality scan and reset commands (Sprint 3)
#
# Tests: wv quality scan, wv quality scan --json, wv quality reset,
#        wv quality help, incremental scan, unknown subcommand
#
# Exit codes:
#   0 - All tests passed
#   1 - One or more tests failed

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WV="$PROJECT_ROOT/scripts/wv"

# Test environment
TEST_DIR="/tmp/wv-quality-test-$$"
export WV_HOT_ZONE="$TEST_DIR"
export WV_DB="$TEST_DIR/brain.db"

cleanup() {
    cd /tmp
    if [ -d "$TEST_DIR" ]; then
        rm -rf "$TEST_DIR"
    fi
}
trap cleanup EXIT

setup_test_env() {
    rm -rf "$TEST_DIR"
    mkdir -p "$TEST_DIR/.weave"
    cd "$TEST_DIR"
    # Need git repo for quality scanner
    git init -q
    git config user.email "test@test.com"
    git config user.name "Test"
}

# Create sample source files for scanning
create_sample_files() {
    # Python file with some complexity
    cat > "$TEST_DIR/sample.py" <<'PYEOF'
import os
import sys

class Calculator:
    """A simple calculator."""

    def __init__(self):
        self.history = []

    def add(self, a, b):
        if a < 0 or b < 0:
            raise ValueError("Negative")
        result = a + b
        self.history.append(result)
        return result

    def divide(self, a, b):
        if b == 0:
            raise ZeroDivisionError("Cannot divide by zero")
        return a / b

def main():
    calc = Calculator()
    for i in range(10):
        if i % 2 == 0:
            calc.add(i, i + 1)
        else:
            calc.divide(i, 1)

if __name__ == "__main__":
    main()
PYEOF

    # Bash file with functions
    cat > "$TEST_DIR/helper.sh" <<'SHEOF'
#!/bin/bash
# Helper script

setup() {
    local dir="$1"
    if [ -z "$dir" ]; then
        echo "Error: no dir" >&2
        return 1
    fi
    mkdir -p "$dir"
}

cleanup() {
    local dir="$1"
    if [ -d "$dir" ]; then
        rm -rf "$dir"
    fi
}

main() {
    local action="${1:-}"
    case "$action" in
        setup)   setup "$2" ;;
        cleanup) cleanup "$2" ;;
        *)       echo "Unknown: $action" >&2; return 1 ;;
    esac
}

main "$@"
SHEOF
    chmod +x "$TEST_DIR/helper.sh"

    # Commit so git metrics work
    git add -A
    git commit -q -m "Initial commit with sample files"
}

# ---------------------------------------------------------------------------
# Test helpers
# ---------------------------------------------------------------------------

assert_equals() {
    local expected="$1" actual="$2" message="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [ "$expected" = "$actual" ]; then
        echo -e "${GREEN}✓${NC} $message"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}✗${NC} $message"
        echo "  Expected: $expected"
        echo "  Actual:   $actual"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

strip_ansi() {
    sed 's/\x1b\[[0-9;]*m//g'
}

assert_contains() {
    local haystack="$1" needle="$2" message="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if echo "$haystack" | strip_ansi | grep -qF "$needle"; then
        echo -e "${GREEN}✓${NC} $message"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}✗${NC} $message"
        echo "  Expected to find: $needle"
        echo "  In: $(echo "$haystack" | strip_ansi | head -5)"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

assert_not_contains() {
    local haystack="$1" needle="$2" message="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if ! echo "$haystack" | strip_ansi | grep -qF "$needle"; then
        echo -e "${GREEN}✓${NC} $message"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}✗${NC} $message"
        echo "  Expected NOT to find: $needle"
        echo "  In: $(echo "$haystack" | strip_ansi | head -5)"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

assert_success() {
    local message="$1"; shift
    TESTS_RUN=$((TESTS_RUN + 1))
    if "$@" >/dev/null 2>&1; then
        echo -e "${GREEN}✓${NC} $message"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}✗${NC} $message"
        echo "  Command failed: $*"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

assert_fails() {
    local message="$1"; shift
    TESTS_RUN=$((TESTS_RUN + 1))
    if ! "$@" >/dev/null 2>&1; then
        echo -e "${GREEN}✓${NC} $message"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}✗${NC} $message"
        echo "  Command should have failed: $*"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

assert_json_field() {
    local json="$1" field="$2" expected="$3" message="$4"
    local actual
    actual=$(echo "$json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('$field',''))" 2>/dev/null || echo "PARSE_ERROR")
    assert_equals "$expected" "$actual" "$message"
}

assert_json_field_gt() {
    local json="$1" field="$2" threshold="$3" message="$4"
    local actual
    actual=$(echo "$json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('$field',0))" 2>/dev/null || echo "0")
    TESTS_RUN=$((TESTS_RUN + 1))
    if python3 -c "exit(0 if $actual > $threshold else 1)" 2>/dev/null; then
        echo -e "${GREEN}✓${NC} $message"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}✗${NC} $message"
        echo "  Expected $field > $threshold, got: $actual"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

# ═══════════════════════════════════════════════════════════════════════════
# TESTS
# ═══════════════════════════════════════════════════════════════════════════

echo -e "${YELLOW}=== wv quality tests (Sprint 3) ===${NC}"
echo ""

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------
echo -e "${YELLOW}--- Setup ---${NC}"
setup_test_env
# Init wv brain.db so wv dispatcher works
"$WV" init -q 2>/dev/null || true
create_sample_files

# ---------------------------------------------------------------------------
# Test: wv quality help
# ---------------------------------------------------------------------------
echo -e "${YELLOW}--- Help ---${NC}"

test_help_output() {
    local out
    out=$("$WV" quality help 2>&1) || true
    assert_contains "$out" "Usage:" "quality help shows usage"
    assert_contains "$out" "scan" "quality help mentions scan"
    assert_contains "$out" "reset" "quality help mentions reset"
    assert_contains "$out" "hotspots" "quality help mentions hotspots"
}
test_help_output

test_help_flags() {
    local out
    out=$("$WV" quality -h 2>&1) || true
    assert_contains "$out" "scan" "-h flag shows help"
    out=$("$WV" quality --help 2>&1) || true
    assert_contains "$out" "scan" "--help flag shows help"
}
test_help_flags

# ---------------------------------------------------------------------------
# Test: wv quality scan --json (first scan, all files changed)
# ---------------------------------------------------------------------------
echo -e "${YELLOW}--- Scan (JSON) ---${NC}"

test_scan_json_first_run() {
    local out
    out=$("$WV" quality scan --json 2>/dev/null)

    # Must be valid JSON
    assert_success "scan --json produces valid JSON" python3 -c "import json; json.loads('$out')"

    # Check required fields
    assert_json_field "$out" "scan_id" "1" "scan_id is 1 for first scan"
    assert_json_field_gt "$out" "files_scanned" "0" "files_scanned > 0"
    assert_json_field_gt "$out" "files_changed" "0" "files_changed > 0 on first scan"
    assert_json_field_gt "$out" "duration_ms" "0" "duration_ms > 0"

    # git_head should be a hex string
    local head
    head=$(echo "$out" | python3 -c "import sys,json; print(json.load(sys.stdin).get('git_head',''))" 2>/dev/null)
    TESTS_RUN=$((TESTS_RUN + 1))
    if echo "$head" | grep -qE '^[0-9a-f]{7,40}$'; then
        echo -e "${GREEN}✓${NC} git_head is a valid hex SHA"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}✗${NC} git_head is a valid hex SHA"
        echo "  Got: $head"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi

    # Languages should include python and bash
    local langs
    langs=$(echo "$out" | python3 -c "import sys,json; d=json.load(sys.stdin); print(','.join(sorted(d.get('languages',{}).keys())))" 2>/dev/null)
    assert_contains "$langs" "python" "languages includes python"
    assert_contains "$langs" "bash" "languages includes bash"

    # quality_score should exist (0-100)
    local score
    score=$(echo "$out" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('quality_score','MISSING'))" 2>/dev/null)
    TESTS_RUN=$((TESTS_RUN + 1))
    if python3 -c "s=$score; exit(0 if 0 <= s <= 100 else 1)" 2>/dev/null; then
        echo -e "${GREEN}✓${NC} quality_score in range 0-100 ($score)"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}✗${NC} quality_score in range 0-100"
        echo "  Got: $score"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}
test_scan_json_first_run

# ---------------------------------------------------------------------------
# Test: wv quality scan (stderr output)
# ---------------------------------------------------------------------------
echo -e "${YELLOW}--- Scan (stderr) ---${NC}"

test_scan_stderr() {
    local out
    out=$("$WV" quality scan 2>&1 1>/dev/null) || true
    assert_contains "$out" "Scanning" "stderr shows Scanning message"
    assert_contains "$out" "Duration:" "stderr shows Duration"
    assert_contains "$out" "Hotspots:" "stderr shows Hotspots"
    assert_contains "$out" "Quality score:" "stderr shows Quality score"
}
test_scan_stderr

# ---------------------------------------------------------------------------
# Test: Incremental scan (second run, nothing changed)
# ---------------------------------------------------------------------------
echo -e "${YELLOW}--- Incremental scan ---${NC}"

test_incremental_scan() {
    local out
    out=$("$WV" quality scan --json 2>/dev/null)

    # files_changed should be 0 since nothing changed
    assert_json_field "$out" "files_changed" "0" "incremental scan: files_changed is 0"

    # files_scanned should still be > 0
    assert_json_field_gt "$out" "files_scanned" "0" "incremental scan: files_scanned still > 0"
}
test_incremental_scan

# ---------------------------------------------------------------------------
# Test: Incremental scan detects file change
# ---------------------------------------------------------------------------
echo -e "${YELLOW}--- Incremental scan after edit ---${NC}"

test_incremental_after_edit() {
    # Modify a file
    echo "# New comment" >> "$TEST_DIR/sample.py"
    git add -A && git commit -q -m "Edit sample.py"

    local out
    out=$("$WV" quality scan --json 2>/dev/null)

    # files_changed should be > 0 now
    assert_json_field_gt "$out" "files_changed" "0" "files_changed > 0 after editing sample.py"
}
test_incremental_after_edit

# ---------------------------------------------------------------------------
# Test: wv quality scan with explicit path
# ---------------------------------------------------------------------------
echo -e "${YELLOW}--- Scan with explicit path ---${NC}"

test_scan_explicit_path() {
    local out
    out=$("$WV" quality scan "$TEST_DIR" --json 2>/dev/null)

    assert_json_field_gt "$out" "files_scanned" "0" "scan with explicit path finds files"
}
test_scan_explicit_path

# ---------------------------------------------------------------------------
# Test: wv quality reset
# ---------------------------------------------------------------------------
echo -e "${YELLOW}--- Reset ---${NC}"

test_reset() {
    # Ensure quality.db exists after previous scans
    local qdb="$WV_HOT_ZONE/quality.db"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [ -f "$qdb" ]; then
        echo -e "${GREEN}✓${NC} quality.db exists before reset"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}✗${NC} quality.db exists before reset"
        echo "  Not found at: $qdb"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi

    # Reset
    local out
    out=$("$WV" quality reset 2>&1)
    assert_contains "$out" "Deleted" "reset output says Deleted"

    # DB should be gone
    TESTS_RUN=$((TESTS_RUN + 1))
    if [ ! -f "$qdb" ]; then
        echo -e "${GREEN}✓${NC} quality.db removed after reset"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}✗${NC} quality.db removed after reset"
        echo "  Still exists at: $qdb"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}
test_reset

# ---------------------------------------------------------------------------
# Test: wv quality reset when no DB exists
# ---------------------------------------------------------------------------
echo -e "${YELLOW}--- Reset (no DB) ---${NC}"

test_reset_no_db() {
    local out
    out=$("$WV" quality reset 2>&1)
    assert_contains "$out" "No quality.db" "reset with no DB says so"
}
test_reset_no_db

# ---------------------------------------------------------------------------
# Test: Scan after reset (full rescan)
# ---------------------------------------------------------------------------
echo -e "${YELLOW}--- Scan after reset ---${NC}"

test_scan_after_reset() {
    local out
    out=$("$WV" quality scan --json 2>/dev/null)

    # Should be a fresh scan (scan_id resets)
    assert_json_field "$out" "scan_id" "1" "scan_id is 1 after reset"
    assert_json_field_gt "$out" "files_changed" "0" "files_changed > 0 after reset (full rescan)"
}
test_scan_after_reset

# ---------------------------------------------------------------------------
# Test: Unknown subcommand
# ---------------------------------------------------------------------------
echo -e "${YELLOW}--- Error handling ---${NC}"

test_unknown_subcommand() {
    assert_fails "unknown subcommand fails" "$WV" quality bogus
}
test_unknown_subcommand

# ---------------------------------------------------------------------------
# Test: Sprint 4 stubs return error
# ---------------------------------------------------------------------------
test_sprint4_stubs() {
    assert_fails "hotspots stub fails" "$WV" quality hotspots
    assert_fails "diff stub fails" "$WV" quality diff
    assert_fails "promote stub fails" "$WV" quality promote
}
test_sprint4_stubs

# ═══════════════════════════════════════════════════════════════════════════
# Results
# ═══════════════════════════════════════════════════════════════════════════

echo ""
echo -e "${YELLOW}=== Results ===${NC}"
echo -e "Tests: $TESTS_RUN | Passed: ${GREEN}$TESTS_PASSED${NC} | Failed: ${RED}$TESTS_FAILED${NC}"

if [ "$TESTS_FAILED" -eq 0 ]; then
    echo -e "${GREEN}ALL TESTS PASSED${NC}"
    exit 0
else
    echo -e "${RED}$TESTS_FAILED TESTS FAILED${NC}"
    exit 1
fi
