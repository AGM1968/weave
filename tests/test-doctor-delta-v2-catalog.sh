#!/usr/bin/env bash
# Suite-driven wv calls are tagged test so call-stats retro reads can exclude them.
export WV_CALL_SOURCE=test
# test-doctor-delta-v2-catalog.sh — wv doctor's Delta v2 catalog integrity check
#
# Source: wv-99c85a item 2. wv load rolls the whole v2 batch back on the first
# hard disposition and, unless WV_DELTA_V2_STRICT=1, only warns and falls back
# to v1. One bad committed op therefore disables v2 replay on every clone on
# every load, and nothing persistent said so.
#
# Covers:
#   - no v2 ops: the check stays silent
#   - valid ops only: PASS with the op count
#   - one bad op among valid ones: FAIL naming the file and its disposition
#
# Exit codes:
#   0 - All tests passed
#   1 - Unexpected failure

set -euo pipefail
export WV_TEST_SUITE=1  # the user's config.env cannot log this suite's wv calls (wv-6b0f57)

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WV="$PROJECT_ROOT/scripts/wv"
REPLAY="$PROJECT_ROOT/scripts/lib/wv-delta-v2-replay.py"

TEST_DIR=$(mktemp -d)
export WV_CONFIG_DIR="$TEST_DIR/config"

cleanup() { cd /tmp && rm -rf "$TEST_DIR"; }
trap cleanup EXIT

mkdir -p "$TEST_DIR/repo"
cd "$TEST_DIR/repo"
git init -q
export WV_PROJECT_DIR="$TEST_DIR/repo"
export WV_HOT_ZONE="$TEST_DIR/hot"
export WEAVE_DIR="$TEST_DIR/repo/.weave"
unset WV_DB WV_DB_CUSTOM
"$WV" init >/dev/null 2>&1 || true
V2="$WEAVE_DIR/deltas/2026-09-29/v2"

# make_op <out> <weight-json> <op-id>: a hash-valid edge_create.
make_op() {
    python3 - "$REPLAY" "$1" "$2" "$3" <<'PY'
import importlib.util, json, sys

spec = importlib.util.spec_from_file_location("replay", sys.argv[1])
replay = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(replay)
op = {
    "actor_id": "agent-d",
    "actor_sequence": 3,
    "canonicalization": "weave.canonical-json.v1",
    "format": "weave.delta.v2",
    "operation_id": sys.argv[4],
    "payload": {
        "entity": {"kind": "edge", "source": "wv-a", "target": "wv-b", "type": "relates_to"},
        "lineage": {"actor": "agent-d", "seq": 3},
        "mutation": {"kind": "edge_create", "row": {
            "context": None, "created_at": "2026-09-29 00:00:00", "weight": json.loads(sys.argv[3]),
        }},
    },
}
op["operation_sha256"] = replay.sha256_text(replay.canonical(op))
with open(sys.argv[2], "w", encoding="utf-8") as fh:
    json.dump(op, fh)
PY
}

doctor_line() {
    "$WV" doctor 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | grep "delta v2 catalog" || true
}

check() {
    local label="$1" got="$2" want="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [ "$got" = "$want" ]; then
        echo -e "  ${GREEN}[PASS]${NC} $label"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}[FAIL]${NC} $label"
        echo "      want: $want"
        echo "      got:  $got"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

echo "wv doctor: Delta v2 catalog integrity (wv-99c85a)"

check "no v2 ops: the check stays silent" "$(doctor_line)" ""

mkdir -p "$V2"
make_op "$V2/000000000003-1a2b6c1e-5d4a-5b7c-9e8f-0a1b2c3d4e5f.json" '"1.0"' 1a2b6c1e-5d4a-5b7c-9e8f-0a1b2c3d4e5f
check "valid ops only: PASS with the op count" "$(doctor_line)" \
    "  ✓ delta v2 catalog: 1 op(s) pass replay validation"

make_op "$V2/000000000003-2a2b6c1e-5d4a-5b7c-9e8f-0a1b2c3d4e5f.json" '"inf"' 2a2b6c1e-5d4a-5b7c-9e8f-0a1b2c3d4e5f
check "one bad op: FAIL naming the file and its disposition" "$(doctor_line)" \
    "  ✗ delta v2 catalog: 1 of 2 op(s) fail: 000000000003-2a2b6c1e-5d4a-5b7c-9e8f-0a1b2c3d4e5f.json (integrity_failed: invalid weight value) — wv load rolls back ALL v2 replay and falls back to v1 on every clone"

echo ""
echo "Tests: $TESTS_PASSED/$TESTS_RUN passed"
[ "$TESTS_FAILED" -eq 0 ] && [ "$TESTS_RUN" -gt 0 ]
