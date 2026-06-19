#!/bin/bash
# Suite-driven wv calls are tagged test so call-stats retro reads can exclude them.
export WV_CALL_SOURCE=test
# test-schema-contract.sh — SQL-vs-schema drift guard (wv-0eb81a)
#
# Every table identifier referenced in SQL strings across bash/Python/TS must
# exist in a database the codebase actually creates (brain.db, quality.db,
# ast cache) or be declared in-code (CTE, temp table, RENAME TO). Catches
# invented-table bugs like the bootstrap-agent quality_scans probe (wv-031d20)
# at CI time instead of in a sandbox audit.
# Weave-ID: wv-0eb81a

set -e

# Sandbox shells omit user tool dirs (poetry lives in ~/.local/bin); same
# fallback as scripts/wv and the Makefile, needed for direct execution.
export PATH="$PATH:$HOME/.local/bin:$HOME/.cargo/bin"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WV="$REPO_ROOT/scripts/wv"

TESTS_RUN=0
TESTS_PASSED=0

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

pass() {
    echo -e "  ${GREEN}✓${NC} $1"
    TESTS_PASSED=$((TESTS_PASSED + 1))
    TESTS_RUN=$((TESTS_RUN + 1))
}

fail() {
    echo -e "  ${RED}✗${NC} $1"
    [ -n "${2:-}" ] && echo "    $2"
    TESTS_RUN=$((TESTS_RUN + 1))
}

# ═══════════════════════════════════════════════════════════════════════════
# Extraction helpers — shared by the live check and the red-test fixtures
# ═══════════════════════════════════════════════════════════════════════════

# Table identifiers referenced by SQL keywords. Comment lines are dropped:
# prose like "UPDATE is best-effort" otherwise extracts English words.
# Uppercase keywords + lowercase identifiers match this codebase's SQL style
# (and skip Python's lowercase "from x import").
extract_referenced() {
    cat "$@" 2>/dev/null \
        | grep -vE '^[[:space:]]*(#|//|\*|--)' \
        | grep -oE '(FROM|JOIN|INTO|UPDATE)[[:space:]]+[a-z_][a-z0-9_]*' \
        | awk '{print $2}' | sort -u || true
}

# Names the codebase itself declares: tables (incl. temp/virtual), renames,
# and CTEs ("name AS (").
extract_declared() {
    {
        cat "$@" 2>/dev/null \
            | grep -oE 'CREATE( TEMP| TEMPORARY)?( VIRTUAL)? TABLE( IF NOT EXISTS)? [a-z_][a-z0-9_]*' \
            | awk '{print $NF}'
        cat "$@" 2>/dev/null \
            | grep -oE 'RENAME TO [a-z_][a-z0-9_]*' \
            | awk '{print $3}'
        cat "$@" 2>/dev/null \
            | grep -oE '[a-z_][a-z0-9_]*(\([a-z0-9_, ]*\))?[[:space:]]+AS[[:space:]]*\(' \
            | sed -E 's/\(.*//' | awk '{print $1}'
    } | sort -u || true
}

# English words extracted from prose embedded in strings/heredocs (e.g.
# "a raw sqlite3 UPDATE is session-only"). No real table will carry these.
NOISE="is
on
to
so
that
the"

# Built-in / virtual surfaces that exist without a CREATE statement.
BUILTIN="sqlite_master
sqlite_temp_master
sqlite_sequence
sqlite_schema
pragma_table_info
pragma_table_list
json_each
json_tree
dbstat"

# External tables owned by another harness's database that the codebase reads
# but never creates. The memory scan/import path queries Codex's
# ~/.codex/memories_*.sqlite (stage1_outputs), always gated by a sqlite_master
# existence probe before use, so a missing table degrades gracefully rather
# than erroring. These are intentional foreign-schema references, not the
# invented-table bug shape this guard catches.
EXTERNAL="stage1_outputs"

check_contract() {
    # $1 = file with known names (one per line), remaining args = source files.
    # Prints violations (referenced but neither known, declared, nor builtin).
    local known_file="$1"
    shift
    local declared
    declared=$(extract_declared "$@")
    extract_referenced "$@" | while read -r ref; do
        [ -z "$ref" ] && continue
        grep -qxF "$ref" "$known_file" && continue
        echo "$declared" | grep -qxF "$ref" && continue
        echo "$BUILTIN" | grep -qxF "$ref" && continue
        echo "$EXTERNAL" | grep -qxF "$ref" && continue
        echo "$NOISE" | grep -qxF "$ref" && continue
        echo "$ref"
    done
}

# ═══════════════════════════════════════════════════════════════════════════
# Setup — fresh DBs from the canonical initialization code
# ═══════════════════════════════════════════════════════════════════════════

echo ""
echo "═══════════════════════════════════════════════════════════════════════════"
echo "  SQL-vs-schema contract (referenced tables must exist)"
echo "═══════════════════════════════════════════════════════════════════════════"
echo ""

TEST_DIR=$(mktemp -d)
trap 'cd /tmp && rm -rf "$TEST_DIR"' EXIT
export WV_HOT_ZONE="$TEST_DIR/hz"
export WV_DB="$WV_HOT_ZONE/brain.db"
mkdir -p "$WV_HOT_ZONE"
cd "$TEST_DIR" && git init -q

"$WV" status >/dev/null 2>&1 || true
if [ -f "$WV_DB" ] && sqlite3 "$WV_DB" "SELECT 1 FROM nodes LIMIT 0;" >/dev/null 2>&1; then
    pass "fresh brain.db created from canonical db_init"
else
    fail "fresh brain.db created from canonical db_init" "wv status did not initialize $WV_DB"
fi

(cd "$REPO_ROOT" && PYTHONPATH="$REPO_ROOT/scripts" poetry run python -c "
from weave_quality.db import init_db
conn = init_db('$WV_HOT_ZONE')
conn.close()
") >/dev/null 2>&1 || true
if [ -f "$WV_HOT_ZONE/quality.db" ] && sqlite3 "$WV_HOT_ZONE/quality.db" "SELECT 1 FROM scan_meta LIMIT 0;" >/dev/null 2>&1; then
    pass "fresh quality.db created from canonical init_db"
else
    fail "fresh quality.db created from canonical init_db" "weave_quality.db.init_db did not produce quality.db"
fi

KNOWN_FILE="$TEST_DIR/known_tables"
{
    sqlite3 "$WV_DB" "SELECT name FROM sqlite_master;" 2>/dev/null
    sqlite3 "$WV_HOT_ZONE/quality.db" "SELECT name FROM sqlite_master;" 2>/dev/null
} | sort -u > "$KNOWN_FILE"

if grep -qxF "nodes" "$KNOWN_FILE" && grep -qxF "scan_meta" "$KNOWN_FILE"; then
    pass "known-tables set contains both schemas (nodes + scan_meta)"
else
    fail "known-tables set contains both schemas (nodes + scan_meta)" "$(wc -l < "$KNOWN_FILE") names collected"
fi

# ═══════════════════════════════════════════════════════════════════════════
# The contract — every referenced table must be known/declared/builtin
# ═══════════════════════════════════════════════════════════════════════════

SOURCES=()
while IFS= read -r f; do SOURCES+=("$f"); done < <(
    {
        echo "$REPO_ROOT/scripts/wv"
        find "$REPO_ROOT/scripts/cmd" "$REPO_ROOT/scripts/lib" "$REPO_ROOT/scripts/hooks" \
             "$REPO_ROOT/.claude/hooks" -name '*.sh' 2>/dev/null
        find "$REPO_ROOT/scripts/weave_quality" "$REPO_ROOT/scripts/weave_gh" \
             "$REPO_ROOT/scripts/weave_search" "$REPO_ROOT/scripts/weave_indexer" \
             -name '*.py' 2>/dev/null
        find "$REPO_ROOT/mcp/src" -name '*.ts' ! -name '*.test.ts' 2>/dev/null
    } | sort
)

if [ "${#SOURCES[@]}" -gt 20 ]; then
    pass "source sweep covers bash+python+ts (${#SOURCES[@]} files)"
else
    fail "source sweep covers bash+python+ts (${#SOURCES[@]} files)" "expected >20 files"
fi

violations=$(check_contract "$KNOWN_FILE" "${SOURCES[@]}")
if [ -z "$violations" ]; then
    pass "no SQL reference to a nonexistent table"
else
    fail "no SQL reference to a nonexistent table" "unknown tables: $(echo "$violations" | tr '\n' ' ')"
fi

# ═══════════════════════════════════════════════════════════════════════════
# Red-tests — the checker must catch the historical bug shape
# ═══════════════════════════════════════════════════════════════════════════

FIXTURE="$TEST_DIR/fixture.sh"
cat > "$FIXTURE" <<'EOF'
count=$(sqlite3 "$db" "SELECT COUNT(*) FROM quality_scans;")
EOF
red=$(check_contract "$KNOWN_FILE" "$FIXTURE")
if echo "$red" | grep -qxF "quality_scans"; then
    pass "red-test: invented table quality_scans is flagged (wv-031d20 bug shape)"
else
    fail "red-test: invented table quality_scans is flagged (wv-031d20 bug shape)" "checker output: '$red'"
fi

cat > "$FIXTURE" <<'EOF'
count=$(sqlite3 "$db" "SELECT COUNT(*) FROM nodes;")
latest=$(sqlite3 "$qdb" "SELECT id FROM scan_meta ORDER BY id DESC LIMIT 1;")
EOF
green=$(check_contract "$KNOWN_FILE" "$FIXTURE")
if [ -z "$green" ]; then
    pass "red-test control: real tables (nodes, scan_meta) pass clean"
else
    fail "red-test control: real tables (nodes, scan_meta) pass clean" "false positives: '$green'"
fi

# ═══════════════════════════════════════════════════════════════════════════
# Summary
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "═══════════════════════════════════════════════════════════════════════════"
echo -e "Results: $TESTS_PASSED/$TESTS_RUN passed"
if [ "$TESTS_PASSED" -eq "$TESTS_RUN" ]; then
    echo -e "${GREEN}All tests passed!${NC}"
    exit 0
else
    echo -e "${RED}Some tests failed.${NC}"
    exit 1
fi
