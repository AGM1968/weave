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
export WV_TEST_SUITE=1  # the user's config.env cannot log this suite's wv calls (wv-6b0f57)

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
# A schema-qualified reference names a table BEHIND a qualifier: SQLite resolves
# `main.`, `temp.` and any alias introduced by `ATTACH DATABASE ... AS <alias>`
# as a SCHEMA, so the table is the part after the dot. Matching only up to the
# dot read the qualifier as the table and reported `main` and `pre` as unknown
# tables (wv-4fd694). Aliases are collected PER FILE, because an ATTACH in one
# script says nothing about another. An unrecognised qualifier is emitted whole
# so a typo stays a violation instead of being silently stripped.
extract_referenced() {
    local f aliases ref qualifier table
    for f in "$@"; do
        aliases=$(grep -oiE 'ATTACH[[:space:]]+DATABASE[^;]*[[:space:]]AS[[:space:]]+[a-z_][a-z0-9_]*' "$f" 2>/dev/null \
            | awk '{print tolower($NF)}' | sort -u)
        grep -vE '^[[:space:]]*(#|//|\*|--)' "$f" 2>/dev/null \
            | grep -oE '(FROM|JOIN|INTO|UPDATE)[[:space:]]+([a-z_][a-z0-9_]*\.)?[a-z_][a-z0-9_]*' \
            | awk '{print $2}' \
            | while read -r ref; do
                case "$ref" in
                    *.*)
                        qualifier=${ref%%.*}
                        table=${ref#*.}
                        if [ "$qualifier" = "main" ] || [ "$qualifier" = "temp" ] \
                            || grep -qxF -- "$qualifier" <<< "$aliases"; then
                            printf '%s\n' "$table"
                        else
                            printf '%s\n' "$ref"
                        fi
                        ;;
                    *) printf '%s\n' "$ref" ;;
                esac
            done
    done | sort -u || true
}

# Names the codebase itself declares: tables (incl. temp/virtual), renames,
# and CTEs ("name AS (").
extract_declared() {
    {
        # Declarations carry qualifiers too (`CREATE VIRTUAL TABLE temp.wv_fv`).
        # Both sides must unqualify or they agree on the wrong name: matching up
        # to the dot declared `temp` and referenced `temp`, so the real table was
        # never checked either way (wv-4fd694).
        cat "$@" 2>/dev/null \
            | grep -oE 'CREATE( TEMP| TEMPORARY)?( VIRTUAL)? TABLE( IF NOT EXISTS)? ([a-z_][a-z0-9_]*\.)?[a-z_][a-z0-9_]*' \
            | awk '{print $NF}' | sed -E 's/^[a-z_][a-z0-9_]*\.//'
        cat "$@" 2>/dev/null \
            | grep -oE 'RENAME TO ([a-z_][a-z0-9_]*\.)?[a-z_][a-z0-9_]*' \
            | awk '{print $NF}' | sed -E 's/^[a-z_][a-z0-9_]*\.//'
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

# Transient backup tables (wv-8b2c21) that scripts/weave_quality/db.py's
# stranded-backup repair creates/reads/drops via DYNAMIC SQL (backup =
# f"{table}_v9" -- never a literal CREATE TABLE/RENAME TO string this file's
# own regex-based extract_declared can match) when a prior v10 migration was
# interrupted mid-rename. Legitimate and intentional, not the invented-table
# bug shape this guard catches -- but also structurally absent from the
# known-tables set collected above: they're merged into the live tables and
# DROPPED as part of the same repair pass, so they never exist in a freshly-
# initialized quality.db either (wv-45eff1).
TRANSIENT="pattern_findings_v9
pattern_rule_runs_v9"

check_contract() {
    # $1 = file with known names (one per line), remaining args = source files.
    # Prints violations (referenced but neither known, declared, nor builtin).
    local known_file="$1"
    shift
    local declared
    declared=$(extract_declared "$@")
    extract_referenced "$@" | while read -r ref; do
        [ -z "$ref" ] && continue
        grep -qxF -- "$ref" "$known_file" && continue
        grep -qxF -- "$ref" <<< "$declared" && continue
        grep -qxF -- "$ref" <<< "$BUILTIN" && continue
        grep -qxF -- "$ref" <<< "$EXTERNAL" && continue
        grep -qxF -- "$ref" <<< "$TRANSIENT" && continue
        grep -qxF -- "$ref" <<< "$NOISE" && continue
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
        # The Python helpers beside the shell libraries declare tables the shell
        # reads (wv-load-ack.py's _weave_load_attempt, wv-2f55dd).
        find "$REPO_ROOT/scripts/lib" -maxdepth 1 -name '*.py' 2>/dev/null
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
if grep -qxF "quality_scans" <<< "$red"; then
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

# Schema qualifiers (wv-4fd694). A qualifier is not a table, but unqualifying
# must not become a way to smuggle an unknown table past the contract.
cat > "$FIXTURE" <<'EOF'
sqlite3 "$db" "ATTACH DATABASE '$pre_db' AS pre; SELECT id FROM pre.nodes;"
sqlite3 "$db" "SELECT COUNT(*) FROM main.nodes;"
sqlite3 "$db" "CREATE VIRTUAL TABLE temp.vocab USING fts5vocab(main, nodes_fts, instance);
               SELECT count(DISTINCT doc) FROM temp.vocab;"
EOF
green=$(check_contract "$KNOWN_FILE" "$FIXTURE")
if [ -z "$green" ]; then
    pass "qualified refs resolve to their table (main./temp./ATTACH alias)"
else
    fail "qualified refs resolve to their table (main./temp./ATTACH alias)" "false positives: '$green'"
fi

cat > "$FIXTURE" <<'EOF'
sqlite3 "$db" "ATTACH DATABASE '$pre_db' AS pre; SELECT id FROM pre.quality_scans;"
EOF
red=$(check_contract "$KNOWN_FILE" "$FIXTURE")
if grep -qxF "quality_scans" <<< "$red"; then
    pass "red-test: an invented table behind a known qualifier is still flagged"
else
    fail "red-test: an invented table behind a known qualifier is still flagged" "checker output: '$red'"
fi

cat > "$FIXTURE" <<'EOF'
sqlite3 "$db" "SELECT id FROM typo.nodes;"
EOF
red=$(check_contract "$KNOWN_FILE" "$FIXTURE")
if grep -qxF "typo.nodes" <<< "$red"; then
    pass "red-test: an undeclared qualifier is reported whole, not stripped"
else
    fail "red-test: an undeclared qualifier is reported whole, not stripped" "checker output: '$red'"
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
