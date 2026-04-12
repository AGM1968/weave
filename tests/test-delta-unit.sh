#!/bin/bash
# test-delta-unit.sh — Unit tests for wv-delta.sh changeset logic
#
# Tests the SQL-generating-SQL layer directly: triggers, changeset output,
# alias pre-clear, timestamp propagation, no-op detection, fail-fast replay.
# No wv CLI invocations — sources wv-delta.sh directly.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$REPO_ROOT/scripts/lib/wv-delta.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

TESTS_RUN=0
TESTS_PASSED=0

ok() {
    TESTS_RUN=$(( TESTS_RUN + 1 ))
    TESTS_PASSED=$(( TESTS_PASSED + 1 ))
    echo -e "  ${GREEN}✓${NC} $1"
}

fail() {
    TESTS_RUN=$(( TESTS_RUN + 1 ))
    echo -e "  ${RED}✗${NC} $1 — $2"
}

# ─── Helpers ────────────────────────────────────────────────────────────────

make_db() {
    local db
    db=$(mktemp /tmp/delta-unit-XXXXXX.db)
    sqlite3 "$db" "
CREATE TABLE nodes(
    id TEXT PRIMARY KEY,
    text TEXT,
    status TEXT DEFAULT 'ready',
    metadata TEXT DEFAULT '{}',
    alias TEXT UNIQUE,
    created_at INTEGER DEFAULT (strftime('%s','now')),
    updated_at INTEGER DEFAULT (strftime('%s','now'))
);
CREATE TABLE edges(
    source TEXT,
    target TEXT,
    type TEXT,
    weight REAL,
    context TEXT,
    created_at INTEGER DEFAULT (strftime('%s','now')),
    PRIMARY KEY(source, target, type)
);"
    wv_delta_init "$db"
    echo "$db"
}

make_recv() {
    # Receiver DB: same schema, no triggers needed (receives replayed SQL)
    local r
    r=$(mktemp /tmp/delta-recv-XXXXXX.db)
    sqlite3 "$r" "
CREATE TABLE nodes(
    id TEXT PRIMARY KEY,
    text TEXT,
    status TEXT DEFAULT 'ready',
    metadata TEXT DEFAULT '{}',
    alias TEXT UNIQUE,
    created_at INTEGER DEFAULT (strftime('%s','now')),
    updated_at INTEGER DEFAULT (strftime('%s','now'))
);
CREATE TABLE edges(
    source TEXT,
    target TEXT,
    type TEXT,
    weight REAL,
    context TEXT,
    created_at INTEGER DEFAULT (strftime('%s','now')),
    PRIMARY KEY(source, target, type)
);"
    echo "$r"
}

# ─── Tests ───────────────────────────────────────────────────────────────────

echo "Delta unit tests"
echo "────────────────────────────────────────"

DB=$(make_db)

# T1: NULL alias INSERT — no pre-clear emitted
sqlite3 "$DB" "INSERT INTO nodes(id,text,alias) VALUES('wv-0001','task one',NULL);"
CS=$(wv_delta_changeset "$DB")
echo "$CS" | grep -q 'UPDATE nodes SET alias=NULL' \
    && fail "T1: NULL alias" "pre-clear emitted for NULL alias" \
    || ok "T1: NULL alias INSERT — no pre-clear emitted"
wv_delta_reset "$DB"

# T2: Non-NULL alias INSERT — pre-clear emitted
sqlite3 "$DB" "INSERT INTO nodes(id,text,alias) VALUES('wv-0002','task two','mytask');"
CS=$(wv_delta_changeset "$DB")
echo "$CS" | grep -q "UPDATE nodes SET alias=NULL WHERE alias='mytask' AND id!='wv-0002'" \
    && ok "T2: non-NULL alias INSERT — pre-clear emitted" \
    || fail "T2: alias pre-clear" "not found in: $CS"
wv_delta_reset "$DB"

# T3: Alias conflict — receiver node loses alias, incoming node takes it
RECV=$(make_recv)
sqlite3 "$RECV" "INSERT INTO nodes(id,text,alias) VALUES('wv-9999','old holder','shared');"
sqlite3 "$DB" "INSERT INTO nodes(id,text,alias) VALUES('wv-0003','new owner','shared');"
CS=$(wv_delta_changeset "$DB")
sqlite3 "$RECV" "$CS"
a_old=$(sqlite3 "$RECV" "SELECT COALESCE(alias,'NULL') FROM nodes WHERE id='wv-9999';")
a_new=$(sqlite3 "$RECV" "SELECT alias FROM nodes WHERE id='wv-0003';")
[ "$a_old" = "NULL" ] && [ "$a_new" = "shared" ] \
    && ok "T3: alias conflict — existing node cleared, incoming takes alias" \
    || fail "T3: alias conflict" "9999.alias='$a_old' 0003.alias='$a_new'"
rm -f "$RECV"
wv_delta_reset "$DB"

# T4: Timestamps propagate through INSERT changeset
sqlite3 "$DB" "INSERT INTO nodes(id,text,created_at,updated_at) VALUES('wv-0004','ts node',1700000000,1700000001);"
CS=$(wv_delta_changeset "$DB")
echo "$CS" | grep -q '1700000000' && echo "$CS" | grep -q '1700000001' \
    && ok "T4: INSERT changeset carries created_at + updated_at" \
    || fail "T4: timestamp propagation" "not found in: $CS"
wv_delta_reset "$DB"

# T5: Node DELETE emits correct statement
sqlite3 "$DB" "DELETE FROM nodes WHERE id='wv-0004';"
CS=$(wv_delta_changeset "$DB")
echo "$CS" | grep -q "DELETE FROM nodes WHERE id='wv-0004'" \
    && ok "T5: node DELETE emits correct statement" \
    || fail "T5: node DELETE" "not found: $CS"
wv_delta_reset "$DB"

# T6: No-op UPDATE (only updated_at changes) emits SQL comment
sqlite3 "$DB" "INSERT INTO nodes(id,text,status) VALUES('wv-0005','stable','ready');"
wv_delta_reset "$DB"
sqlite3 "$DB" "UPDATE nodes SET status='ready' WHERE id='wv-0005';"
CS=$(wv_delta_changeset "$DB")
echo "$CS" | grep -q '^-- no-op UPDATE' \
    && ok "T6: no-op UPDATE emits -- no-op comment" \
    || fail "T6: no-op UPDATE" "expected comment, got: $CS"
wv_delta_reset "$DB"

# T7: NULL→value UPDATE is included in diff
sqlite3 "$DB" "INSERT INTO nodes(id,text,alias) VALUES('wv-0006','null alias',NULL);"
wv_delta_reset "$DB"
sqlite3 "$DB" "UPDATE nodes SET alias='newalias' WHERE id='wv-0006';"
CS=$(wv_delta_changeset "$DB")
echo "$CS" | grep -q "alias='newalias'" \
    && ok "T7: NULL→value UPDATE included in diff" \
    || fail "T7: NULL→value" "not in changeset: $CS"
wv_delta_reset "$DB"

# T8: value→NULL UPDATE is included in diff
sqlite3 "$DB" "UPDATE nodes SET alias=NULL WHERE id='wv-0006';"
CS=$(wv_delta_changeset "$DB")
echo "$CS" | grep -q 'alias=NULL' \
    && ok "T8: value→NULL UPDATE included in diff" \
    || fail "T8: value→NULL" "not in changeset: $CS"
wv_delta_reset "$DB"

# T9: Edge DELETE — source:target:type colon-split parses correctly
sqlite3 "$DB" "INSERT INTO edges(source,target,type) VALUES('wv-0001','wv-0002','blocks');"
wv_delta_reset "$DB"
sqlite3 "$DB" "DELETE FROM edges WHERE source='wv-0001' AND target='wv-0002' AND type='blocks';"
CS=$(wv_delta_changeset "$DB")
echo "$CS" | grep -q "DELETE FROM edges WHERE source='wv-0001' AND target='wv-0002' AND type='blocks'" \
    && ok "T9: edge DELETE colon-split parses correctly" \
    || fail "T9: edge DELETE" "bad parse: $CS"
wv_delta_reset "$DB"

# T10a: Edge INSERT ON CONFLICT — receiver with existing edge gets weight updated
RECV=$(make_recv)
sqlite3 "$RECV" "INSERT INTO edges(source,target,type,weight) VALUES('wv-a','wv-b','blocks',0.5);"
sqlite3 "$DB" "INSERT INTO edges(source,target,type,weight,context) VALUES('wv-a','wv-b','blocks',1.0,'ctx1');"
CS=$(wv_delta_changeset "$DB")
sqlite3 "$RECV" "$CS"
count=$(sqlite3 "$RECV" "SELECT COUNT(*) FROM edges WHERE source='wv-a' AND target='wv-b' AND type='blocks';")
weight=$(sqlite3 "$RECV" "SELECT weight FROM edges WHERE source='wv-a' AND target='wv-b' AND type='blocks';")
[ "$count" = "1" ] && [ "$weight" = "1.0" ] \
    && ok "T10a: edge INSERT ON CONFLICT — 1 row, weight updated to 1.0" \
    || fail "T10a: edge ON CONFLICT" "count=$count weight=$weight"
rm -f "$RECV"
wv_delta_reset "$DB"

# T10b: Edge UPDATE changeset propagates weight change
RECV=$(make_recv)
sqlite3 "$DB" "INSERT INTO edges(source,target,type,weight) VALUES('wv-a','wv-b','implements',1.0);"
CS=$(wv_delta_changeset "$DB")
sqlite3 "$RECV" "$CS"
wv_delta_reset "$DB"
sqlite3 "$DB" "UPDATE edges SET weight=2.5 WHERE source='wv-a' AND target='wv-b' AND type='implements';"
CS2=$(wv_delta_changeset "$DB")
sqlite3 "$RECV" "$CS2"
weight=$(sqlite3 "$RECV" "SELECT weight FROM edges WHERE source='wv-a' AND target='wv-b' AND type='implements';")
[ "$weight" = "2.5" ] \
    && ok "T10b: edge UPDATE changeset — weight propagated to 2.5" \
    || fail "T10b: edge UPDATE" "weight=$weight CS2=$CS2"
rm -f "$RECV"
wv_delta_reset "$DB"

# T10c: Edge UPDATE no-op (same weight/context) emits comment
sqlite3 "$DB" "INSERT INTO edges(source,target,type,weight) VALUES('wv-c','wv-d','blocks',1.0);"
wv_delta_reset "$DB"
sqlite3 "$DB" "UPDATE edges SET weight=1.0 WHERE source='wv-c' AND target='wv-d' AND type='blocks';"
CS=$(wv_delta_changeset "$DB")
echo "$CS" | grep -q '^-- no-op UPDATE on edge' \
    && ok "T10c: edge UPDATE no-op emits comment" \
    || fail "T10c: edge no-op" "expected comment, got: $CS"
wv_delta_reset "$DB"

# T11: wv_delta_reset clears all pending changes
sqlite3 "$DB" "INSERT INTO nodes(id,text) VALUES('wv-0007','reset test');"
wv_delta_reset "$DB"
CS=$(wv_delta_changeset "$DB")
[ -z "$CS" ] \
    && ok "T11: reset — changeset empty after wv_delta_reset" \
    || fail "T11: reset" "expected empty changeset, got: $CS"

# T12a: Fail-fast replay — bad delta aborts transaction, DB unchanged
REPLAY_DB=$(make_db)
BAD_DELTA=$(mktemp /tmp/bad-XXXXXX.sql)
printf ".bail on\nBEGIN;\nINSERT INTO nodes(id,text) VALUES('wv-new','new node');\nINSERT INTO nonexistent_table VALUES(1);\nCOMMIT;\n" \
    > "$BAD_DELTA"
sqlite3 "$REPLAY_DB" < "$BAD_DELTA" 2>/dev/null || true
count_new=$(sqlite3 "$REPLAY_DB" "SELECT COUNT(*) FROM nodes WHERE id='wv-new';")
[ "$count_new" = "0" ] \
    && ok "T12a: fail-fast — rolled back, wv-new not in DB" \
    || fail "T12a: fail-fast rollback" "wv-new count=$count_new"

# T12b: Fail-fast — manifest not written after sqlite3 failure
MANIFEST=$(mktemp /tmp/manifest-XXXXXX)
if sqlite3 "$REPLAY_DB" < "$BAD_DELTA" 2>/dev/null; then
    echo "applied:$BAD_DELTA" >> "$MANIFEST"
fi
[ ! -s "$MANIFEST" ] \
    && ok "T12b: fail-fast — manifest empty after failure" \
    || fail "T12b: manifest not written" "manifest non-empty: $(cat "$MANIFEST")"
rm -f "$BAD_DELTA" "$REPLAY_DB" "$MANIFEST"

rm -f "$DB"

# ─── Summary ─────────────────────────────────────────────────────────────────

echo ""
echo "════════════════════════════════════════"
echo "Results: $TESTS_PASSED/$TESTS_RUN passed"
if [ "$TESTS_PASSED" -eq "$TESTS_RUN" ]; then
    echo -e "${GREEN}ALL TESTS PASSED${NC}"
else
    echo -e "${RED}SOME TESTS FAILED${NC}"
    exit 1
fi
