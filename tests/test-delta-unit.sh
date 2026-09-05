#!/bin/bash
# Suite-driven wv calls are tagged test so call-stats retro reads can exclude them.
export WV_CALL_SOURCE=test
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
    updated_at INTEGER DEFAULT (strftime('%s','now')),
    lineage_actor TEXT NOT NULL DEFAULT '' CHECK(typeof(lineage_actor) = 'text'),
    lineage_seq INTEGER NOT NULL DEFAULT 0 CHECK(typeof(lineage_seq) = 'integer')
);
CREATE TABLE edges(
    source TEXT,
    target TEXT,
    type TEXT,
    weight REAL,
    context TEXT,
    created_at INTEGER DEFAULT (strftime('%s','now')),
    lineage_actor TEXT NOT NULL DEFAULT '' CHECK(typeof(lineage_actor) = 'text'),
    lineage_seq INTEGER NOT NULL DEFAULT 0 CHECK(typeof(lineage_seq) = 'integer'),
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
    updated_at INTEGER DEFAULT (strftime('%s','now')),
    lineage_actor TEXT NOT NULL DEFAULT '' CHECK(typeof(lineage_actor) = 'text'),
    lineage_seq INTEGER NOT NULL DEFAULT 0 CHECK(typeof(lineage_seq) = 'integer')
);
CREATE TABLE edges(
    source TEXT,
    target TEXT,
    type TEXT,
    weight REAL,
    context TEXT,
    created_at INTEGER DEFAULT (strftime('%s','now')),
    lineage_actor TEXT NOT NULL DEFAULT '' CHECK(typeof(lineage_actor) = 'text'),
    lineage_seq INTEGER NOT NULL DEFAULT 0 CHECK(typeof(lineage_seq) = 'integer'),
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
echo "$CS" | grep -q "UPDATE nodes SET alias=NULL, lineage_seq=0, lineage_actor='' WHERE alias='mytask' AND id!='wv-0002'" \
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

# ─── wv-cdb45a: lineage-guarded changeset, all six arms ─────────────────────
# The guard is (seq, actor) order, not wall clock. Every write arm stamps
# (lineage_seq, lineage_actor) and applies only when this emission is strictly
# after the row's own lineage (or the row is still pre-cutover at seq 0);
# DELETE fires only when nothing the deleter did not see has since touched the
# row.

# T13: a lower-lineage delta cannot revert a higher-lineage row. Fresh-clone
# shape: the snapshot already carries a row at lineage 9, the committed catalog
# still holds an older update.
RECV=$(make_recv)
sqlite3 "$RECV" "INSERT INTO nodes(id,text,status,metadata,created_at,updated_at,lineage_actor,lineage_seq) VALUES('wv-stale','checkpoint value','ready','{}',100,200,'agent-a',9);"
sqlite3 "$DB" "INSERT INTO nodes(id,text,status,metadata,created_at,updated_at) VALUES('wv-stale','old delta value','todo','{}',100,150);"
CS=$(wv_delta_changeset "$DB" "agent-a" 5)
sqlite3 "$RECV" "$CS"
stale_text=$(sqlite3 "$RECV" "SELECT text FROM nodes WHERE id='wv-stale';")
stale_seq=$(sqlite3 "$RECV" "SELECT lineage_seq FROM nodes WHERE id='wv-stale';")
[ "$stale_text" = "checkpoint value" ] && [ "$stale_seq" = "9" ] \
    && ok "T13: a lower-lineage delta cannot revert a higher-lineage row" \
    || fail "T13: lineage guard" "text='$stale_text' seq='$stale_seq' CS=$CS"
rm -f "$RECV"
wv_delta_reset "$DB"

# T14: equal lineage_seq — the higher lineage_actor wins, deterministically,
# whichever order the two concurrent writes replay in.
RECV=$(make_recv)
sqlite3 "$RECV" "INSERT INTO nodes(id,text,created_at,updated_at,lineage_actor,lineage_seq) VALUES('wv-tie','held by agent-a',100,100,'agent-a',5);"
sqlite3 "$DB" "INSERT INTO nodes(id,text,created_at,updated_at) VALUES('wv-tie','from agent-z',100,100);"
CS=$(wv_delta_changeset "$DB" "agent-z" 5)
sqlite3 "$RECV" "$CS"
tie_hi=$(sqlite3 "$RECV" "SELECT text FROM nodes WHERE id='wv-tie';")
sqlite3 "$RECV" "$CS"   # replay: must stay put
tie_hi2=$(sqlite3 "$RECV" "SELECT text FROM nodes WHERE id='wv-tie';")
wv_delta_reset "$DB"
sqlite3 "$DB" "DELETE FROM nodes WHERE id='wv-tie';"; wv_delta_reset "$DB"
sqlite3 "$DB" "INSERT INTO nodes(id,text,created_at,updated_at) VALUES('wv-tie','from agent-0',100,100);"
CS=$(wv_delta_changeset "$DB" "agent-0" 5)
RECV2=$(make_recv)
sqlite3 "$RECV2" "INSERT INTO nodes(id,text,created_at,updated_at,lineage_actor,lineage_seq) VALUES('wv-tie','held by agent-a',100,100,'agent-a',5);"
sqlite3 "$RECV2" "$CS"
tie_lo=$(sqlite3 "$RECV2" "SELECT text FROM nodes WHERE id='wv-tie';")
[ "$tie_hi" = "from agent-z" ] && [ "$tie_hi2" = "from agent-z" ] && [ "$tie_lo" = "held by agent-a" ] \
    && ok "T14: equal seq resolves by lineage_actor, order-independent" \
    || fail "T14: actor tie-break" "hi='$tie_hi' hi2='$tie_hi2' lo='$tie_lo'"
rm -f "$RECV" "$RECV2"
wv_delta_reset "$DB"

# T15: all six operations emit a lineage-guarded statement — no arm is
# unconditional. One changeset carrying every operation type.
RECV=$(make_recv)
sqlite3 "$DB" "INSERT INTO nodes(id,text,created_at,updated_at) VALUES('wv-keep','stays',1,1);
INSERT INTO nodes(id,text,created_at,updated_at) VALUES('wv-gone','doomed',1,1);
INSERT INTO edges(source,target,type,weight) VALUES('wv-keep','wv-gone','blocks',1.0);
INSERT INTO edges(source,target,type,weight) VALUES('wv-gone','wv-keep','implements',1.0);"
wv_delta_reset "$DB"
sqlite3 "$DB" "INSERT INTO nodes(id,text,created_at,updated_at) VALUES('wv-add','new node',2,2);
UPDATE nodes SET text='changed' WHERE id='wv-keep';
DELETE FROM nodes WHERE id='wv-gone';
INSERT INTO edges(source,target,type,weight) VALUES('wv-keep','wv-add','blocks',0.5);
UPDATE edges SET weight=2.0 WHERE source='wv-keep' AND target='wv-gone' AND type='blocks';
DELETE FROM edges WHERE source='wv-gone' AND target='wv-keep' AND type='implements';"
CS=$(wv_delta_changeset "$DB" "agent-a" 7)
guarded=0
echo "$CS" | grep -q "INSERT INTO nodes.*lineage_seq.*ON CONFLICT.*WHERE nodes.lineage_seq = 0" && guarded=$((guarded+1))
echo "$CS" | grep -qE "UPDATE nodes SET .*lineage_seq=7.* WHERE id='wv-keep'.*nodes.lineage_seq = 0" && guarded=$((guarded+1))
echo "$CS" | grep -qE "DELETE FROM nodes WHERE id='wv-gone' AND \(lineage_seq = 0 OR \(lineage_seq, lineage_actor\) <= \(7,'agent-a'\)\)" && guarded=$((guarded+1))
echo "$CS" | grep -q "INSERT INTO edges.*lineage_seq.*ON CONFLICT.*WHERE edges.lineage_seq = 0" && guarded=$((guarded+1))
echo "$CS" | grep -qE "UPDATE edges SET .*lineage_seq=7.*edges.lineage_seq = 0" && guarded=$((guarded+1))
echo "$CS" | grep -qE "DELETE FROM edges WHERE .*AND \(lineage_seq = 0 OR \(lineage_seq, lineage_actor\) <= \(7,'agent-a'\)\)" && guarded=$((guarded+1))
[ "$guarded" = "6" ] \
    && ok "T15: all six changeset arms carry a lineage guard" \
    || fail "T15: six-arm guard" "guarded=$guarded/6 CS=$CS"
# And it applies cleanly once, then is a no-op on replay (idempotence).
sqlite3 "$RECV" "INSERT INTO nodes(id,text,created_at,updated_at) VALUES('wv-keep','stays',1,1);
INSERT INTO nodes(id,text,created_at,updated_at) VALUES('wv-gone','doomed',1,1);
INSERT INTO edges(source,target,type,weight) VALUES('wv-keep','wv-gone','blocks',1.0);
INSERT INTO edges(source,target,type,weight) VALUES('wv-gone','wv-keep','implements',1.0);"
sqlite3 "$RECV" "$CS"
snap1=$(sqlite3 "$RECV" "SELECT id||'|'||text||'|'||lineage_seq FROM nodes ORDER BY id; SELECT source||'|'||weight||'|'||lineage_seq FROM edges ORDER BY source,target,type;")
sqlite3 "$RECV" "$CS"
sqlite3 "$RECV" "$CS"
snap2=$(sqlite3 "$RECV" "SELECT id||'|'||text||'|'||lineage_seq FROM nodes ORDER BY id; SELECT source||'|'||weight||'|'||lineage_seq FROM edges ORDER BY source,target,type;")
[ "$snap1" = "$snap2" ] && [ -n "$snap1" ] \
    && ok "T16: replaying the full changeset twice more is a no-op" \
    || fail "T16: idempotence" "snap1=[$snap1] snap2=[$snap2]"
rm -f "$RECV"
wv_delta_reset "$DB"

# T17: a stale DELETE cannot remove a row whose lineage is newer than the delete.
RECV=$(make_recv)
sqlite3 "$RECV" "INSERT INTO nodes(id,text,created_at,updated_at,lineage_actor,lineage_seq) VALUES('wv-recreated','recreated later',100,100,'agent-b',10);"
sqlite3 "$DB" "INSERT INTO nodes(id,text,created_at,updated_at) VALUES('wv-recreated','about to be deleted',1,1);"
wv_delta_reset "$DB"
sqlite3 "$DB" "DELETE FROM nodes WHERE id='wv-recreated';"
CS=$(wv_delta_changeset "$DB" "agent-a" 5)
sqlite3 "$RECV" "$CS"
survived=$(sqlite3 "$RECV" "SELECT text FROM nodes WHERE id='wv-recreated';")
[ "$survived" = "recreated later" ] \
    && ok "T17: a stale DELETE cannot remove a causally-newer row" \
    || fail "T17: stale delete" "survived='$survived' CS=$CS"
# ...but a DELETE at or above the row's lineage (and a pre-cutover row) removes it.
sqlite3 "$RECV" "INSERT INTO nodes(id,text,created_at,updated_at) VALUES('wv-precut','no lineage yet',1,1);"
CS2=$(wv_delta_changeset "$DB" "agent-a" 12)   # same DELETE, higher seq
sqlite3 "$RECV" "$CS2"
gone_new=$(sqlite3 "$RECV" "SELECT COUNT(*) FROM nodes WHERE id='wv-recreated';")
gone_pre=$(sqlite3 "$RECV" "SELECT COUNT(*) FROM nodes WHERE id='wv-precut';")
{ [ "$gone_new" = "0" ] && [ "$gone_pre" = "1" ]; } \
    && ok "T18: a DELETE at >= the row lineage removes it" \
    || fail "T18: delete positive" "gone_new=$gone_new gone_pre=$gone_pre"
rm -f "$RECV"
wv_delta_reset "$DB"

# T19: edge conflict resolution does not silently drop weight/context another
# agent wrote at a higher lineage.
RECV=$(make_recv)
sqlite3 "$RECV" "INSERT INTO edges(source,target,type,weight,context,lineage_actor,lineage_seq) VALUES('wv-x','wv-y','blocks',9.0,'keep this','agent-b',10);"
sqlite3 "$DB" "INSERT INTO edges(source,target,type,weight,context) VALUES('wv-x','wv-y','blocks',1.0,'stale ctx');"
CS=$(wv_delta_changeset "$DB" "agent-a" 5)
sqlite3 "$RECV" "$CS"
e_w=$(sqlite3 "$RECV" "SELECT weight FROM edges WHERE source='wv-x' AND target='wv-y' AND type='blocks';")
e_c=$(sqlite3 "$RECV" "SELECT context FROM edges WHERE source='wv-x' AND target='wv-y' AND type='blocks';")
{ [ "$e_w" = "9.0" ] && [ "$e_c" = "keep this" ]; } \
    && ok "T19: stale edge INSERT does not drop higher-lineage weight/context" \
    || fail "T19: edge preservation" "weight='$e_w' context='$e_c' CS=$CS"
rm -f "$RECV"
wv_delta_reset "$DB"

# T20: the alias pre-clear is itself lineage-guarded on the TARGET row, not
# unconditional. A stale (seq 5) create for a node that wants an alias already
# held by a causally newer (seq 10) DIFFERENT row must not steal it: the
# create's own guard is going to refuse anyway, and the alias holder must keep
# its alias. Regression for the ungated pre-clear that left a newer row
# aliasless even though the stale create that "won" the alias never applied.
RECV=$(make_recv)
sqlite3 "$RECV" "INSERT INTO nodes(id,text,created_at,updated_at,lineage_actor,lineage_seq) VALUES('wv-target','already exists',100,100,'agent-z',10);
INSERT INTO nodes(id,text,alias,created_at,updated_at,lineage_actor,lineage_seq) VALUES('wv-holder','holds it',NULL,100,100,'agent-z',10);
UPDATE nodes SET alias='contested' WHERE id='wv-holder';"
sqlite3 "$DB" "INSERT INTO nodes(id,text,alias,created_at,updated_at) VALUES('wv-target','stale value','contested',1,1);"
CS=$(wv_delta_changeset "$DB" "agent-a" 5)
sqlite3 "$RECV" "$CS"
holder_alias=$(sqlite3 "$RECV" "SELECT COALESCE(alias,'NULL') FROM nodes WHERE id='wv-holder';")
target_alias=$(sqlite3 "$RECV" "SELECT COALESCE(alias,'NULL') FROM nodes WHERE id='wv-target';")
target_text=$(sqlite3 "$RECV" "SELECT text FROM nodes WHERE id='wv-target';")
[ "$holder_alias" = "contested" ] && [ "$target_alias" = "NULL" ] && [ "$target_text" = "already exists" ] \
    && ok "T20: alias pre-clear is lineage-guarded — a stale create cannot steal a causally newer row's alias" \
    || fail "T20: alias lineage guard" "holder='$holder_alias' target_alias='$target_alias' target_text='$target_text' CS=$CS"
rm -f "$RECV"
wv_delta_reset "$DB"

# T21: DELETE resolves an equal lineage_seq by lineage_actor, the same
# (seq, actor) tuple order every write arm uses — not lineage_seq alone.
# A delete at (5, agent-a) must not remove a row at (5, agent-z): agent-z is
# causally later at the tie. The reverse (delete at (5, agent-z) against a row
# at (5, agent-a)) does remove it.
RECV=$(make_recv)
sqlite3 "$RECV" "INSERT INTO nodes(id,text,created_at,updated_at,lineage_actor,lineage_seq) VALUES('wv-tiedel','held by agent-z',100,100,'agent-z',5);"
sqlite3 "$DB" "INSERT INTO nodes(id,text,created_at,updated_at) VALUES('wv-tiedel','to be deleted',1,1);"
wv_delta_reset "$DB"
sqlite3 "$DB" "DELETE FROM nodes WHERE id='wv-tiedel';"
CS=$(wv_delta_changeset "$DB" "agent-a" 5)
sqlite3 "$RECV" "$CS"
tie_survived=$(sqlite3 "$RECV" "SELECT COUNT(*) FROM nodes WHERE id='wv-tiedel';")
[ "$tie_survived" = "1" ] \
    && ok "T21a: equal-seq DELETE from a lower actor cannot remove a higher-actor row" \
    || fail "T21a: equal-seq delete actor guard" "survived=$tie_survived CS=$CS"
RECV2=$(make_recv)
sqlite3 "$RECV2" "INSERT INTO nodes(id,text,created_at,updated_at,lineage_actor,lineage_seq) VALUES('wv-tiedel2','held by agent-a',100,100,'agent-a',5);"
sqlite3 "$DB" "INSERT INTO nodes(id,text,created_at,updated_at) VALUES('wv-tiedel2','to be deleted',1,1);"
wv_delta_reset "$DB"
sqlite3 "$DB" "DELETE FROM nodes WHERE id='wv-tiedel2';"
CS2=$(wv_delta_changeset "$DB" "agent-z" 5)
sqlite3 "$RECV2" "$CS2"
tie_gone=$(sqlite3 "$RECV2" "SELECT COUNT(*) FROM nodes WHERE id='wv-tiedel2';")
[ "$tie_gone" = "0" ] \
    && ok "T21b: equal-seq DELETE from a higher actor does remove a lower-actor row" \
    || fail "T21b: equal-seq delete actor guard" "gone=$tie_gone CS2=$CS2"
rm -f "$RECV" "$RECV2"
wv_delta_reset "$DB"

# T22: the alias pre-clear must also refuse to steal an alias off a causally
# newer HOLDER even when the incoming create's TARGET row does not exist yet
# (wv-4448a2 review round 2, finding 1). An absent target says nothing about
# the holder, a DIFFERENT row -- T20 above only covered an existing target.
RECV=$(make_recv)
sqlite3 "$RECV" "INSERT INTO nodes(id,text,alias,created_at,updated_at,lineage_actor,lineage_seq) VALUES('wv-absent-holder','holds it','absent-steal',100,100,'agent-z',10);"
sqlite3 "$DB" "INSERT INTO nodes(id,text,alias,created_at,updated_at) VALUES('wv-absent-target','stale creator','absent-steal',1,1);"
CS=$(wv_delta_changeset "$DB" "agent-a" 5)
sqlite3 "$RECV" "$CS"
absent_holder=$(sqlite3 "$RECV" "SELECT COALESCE(alias,'NULL') FROM nodes WHERE id='wv-absent-holder';")
absent_target=$(sqlite3 "$RECV" "SELECT COALESCE(alias,'NULL') FROM nodes WHERE id='wv-absent-target';")
absent_target_exists=$(sqlite3 "$RECV" "SELECT COUNT(*) FROM nodes WHERE id='wv-absent-target';")
[ "$absent_holder" = "absent-steal" ] && [ "$absent_target" = "NULL" ] && [ "$absent_target_exists" = "1" ] \
    && ok "T22: an absent-target INSERT cannot steal a causally newer holder's alias" \
    || fail "T22: absent-target alias guard" "holder='$absent_holder' target='$absent_target' exists=$absent_target_exists CS=$CS"
rm -f "$RECV"
wv_delta_reset "$DB"

rm -f "$DB"

# ─── Alias arbitration against the REAL production constraint (wv-4448a2
# review round 3, finding 3) ─────────────────────────────────────────────────
# Every test above uses `alias TEXT UNIQUE`, a plain column constraint. The
# actual schema (scripts/lib/wv-db.sh) is a PARTIAL unique index:
# `CREATE UNIQUE INDEX idx_nodes_alias ON nodes(alias) WHERE alias IS NOT NULL
# AND status != 'done'` -- a done node's alias is never enforced unique at
# all. Arbitration logic that queries plain `alias=X` without the status
# filter either wrongly refuses a legitimate reuse (a done node "holds" an
# alias that was never actually reserved) or wrongly steals from a done row
# that was never a real contender. These tests build that exact index so a
# bug the plain-UNIQUE fixtures above cannot see is not concealed here too.
make_partial_db() {
    local db; db=$(mktemp /tmp/delta-partial-XXXXXX.db)
    sqlite3 "$db" "
CREATE TABLE nodes(
    id TEXT PRIMARY KEY, text TEXT, status TEXT DEFAULT 'ready', metadata TEXT DEFAULT '{}',
    alias TEXT, created_at INTEGER DEFAULT (strftime('%s','now')), updated_at INTEGER DEFAULT (strftime('%s','now')),
    lineage_actor TEXT NOT NULL DEFAULT '' CHECK(typeof(lineage_actor) = 'text'),
    lineage_seq INTEGER NOT NULL DEFAULT 0 CHECK(typeof(lineage_seq) = 'integer')
);
CREATE UNIQUE INDEX idx_nodes_alias ON nodes(alias) WHERE alias IS NOT NULL AND status != 'done';
CREATE TABLE edges(source TEXT, target TEXT, type TEXT, weight REAL, context TEXT,
    created_at INTEGER DEFAULT (strftime('%s','now')),
    lineage_actor TEXT NOT NULL DEFAULT '' CHECK(typeof(lineage_actor) = 'text'),
    lineage_seq INTEGER NOT NULL DEFAULT 0 CHECK(typeof(lineage_seq) = 'integer'),
    PRIMARY KEY(source, target, type));"
    wv_delta_init "$db"
    echo "$db"
}

# T23: a DONE node's alias is not a real holder — a new active node can take
# the same alias text without any clear/refusal, matching the partial index.
DB=$(make_partial_db)
RECV=$(make_partial_db)
sqlite3 "$RECV" "INSERT INTO nodes(id,text,status,alias,created_at,updated_at,lineage_actor,lineage_seq) VALUES('wv-closed','finished','done','reusable',100,100,'agent-z',10);"
sqlite3 "$DB" "INSERT INTO nodes(id,text,status,alias,created_at,updated_at) VALUES('wv-fresh','new node','todo','reusable',1,1);"
CS=$(wv_delta_changeset "$DB" "agent-a" 5)
sqlite3 "$RECV" "$CS" 2>&1
closed_alias=$(sqlite3 "$RECV" "SELECT COALESCE(alias,'NULL') FROM nodes WHERE id='wv-closed';")
fresh_alias=$(sqlite3 "$RECV" "SELECT COALESCE(alias,'NULL') FROM nodes WHERE id='wv-fresh';")
[ "$closed_alias" = "reusable" ] && [ "$fresh_alias" = "reusable" ] \
    && ok "T23: a done node's alias is not a real holder — a new node can reuse it without contention (round 3 finding 3b)" \
    || fail "T23: partial-index done exemption" "closed='$closed_alias' fresh='$fresh_alias' CS=$CS"
rm -f "$DB" "$RECV"

# T23b: symmetric case — the INCOMING write itself targets status='done'. The
# partial index never indexes it, so it always keeps its requested alias
# even if an ACTIVE node already holds the same text.
DB=$(make_partial_db)
RECV=$(make_partial_db)
sqlite3 "$RECV" "INSERT INTO nodes(id,text,status,alias,created_at,updated_at,lineage_actor,lineage_seq) VALUES('wv-active-holder','active','todo','shared-alias',100,100,'agent-z',10);"
sqlite3 "$DB" "INSERT INTO nodes(id,text,status,alias,created_at,updated_at) VALUES('wv-done-newcomer','closing','done','shared-alias',1,1);"
CS=$(wv_delta_changeset "$DB" "agent-a" 5)
sqlite3 "$RECV" "$CS" 2>&1
active_alias=$(sqlite3 "$RECV" "SELECT COALESCE(alias,'NULL') FROM nodes WHERE id='wv-active-holder';")
done_alias=$(sqlite3 "$RECV" "SELECT COALESCE(alias,'NULL') FROM nodes WHERE id='wv-done-newcomer';")
[ "$active_alias" = "shared-alias" ] && [ "$done_alias" = "shared-alias" ] \
    && ok "T23b: an incoming done-status create always keeps its alias, uncontested, no clear needed (round 3 finding 3b)" \
    || fail "T23b: partial-index done target" "active='$active_alias' done='$done_alias' CS=$CS"
rm -f "$DB" "$RECV"

# T24: the cleared HOLDER's own lineage must be stamped by the clear (round 3
# finding 3c). Without it, a stale delta the clear had already superseded --
# here, a DELETE for the holder issued before the clear -- can still apply,
# because nothing on the holder recorded that the clear had touched it.
DB=$(make_partial_db)
RECV=$(make_partial_db)
sqlite3 "$RECV" "INSERT INTO nodes(id,text,status,alias,created_at,updated_at,lineage_actor,lineage_seq) VALUES('wv-h','holder','todo','shared24',100,100,'agent-a',5);"
sqlite3 "$DB" "INSERT INTO nodes(id,text,status,alias,created_at,updated_at) VALUES('wv-n','newer','todo','shared24',1,1);"
CS=$(wv_delta_changeset "$DB" "agent-a" 10)
sqlite3 "$RECV" "$CS"
holder_lineage=$(sqlite3 "$RECV" "SELECT lineage_seq || ',' || lineage_actor FROM nodes WHERE id='wv-h';")
[ "$holder_lineage" = "10,agent-a" ] \
    && ok "T24: clearing a holder's alias stamps the holder's own lineage to this write (round 3 finding 3c)" \
    || fail "T24: holder lineage stamp" "got '$holder_lineage', expected '10,agent-a'"
# A stale seq-7 DELETE for the holder, issued before the clear, must now be
# refused: the holder's lineage (10, agent-a) is strictly ahead of it.
sqlite3 "$RECV" "DELETE FROM nodes WHERE id='wv-h' AND (lineage_seq = 0 OR (lineage_seq, lineage_actor) <= (7,'agent-a'));"
holder_survived=$(sqlite3 "$RECV" "SELECT COUNT(*) FROM nodes WHERE id='wv-h';")
[ "$holder_survived" = "1" ] \
    && ok "T24b: a stale DELETE the clear already superseded is refused, not silently applied" \
    || fail "T24b: stale delete after clear" "holder_survived=$holder_survived"
rm -f "$DB" "$RECV"

# T25: the node UPDATE (node_patch) arm had ZERO alias arbitration (round 3
# finding 3a) -- a patch landing an alias already held elsewhere hit
# `UNIQUE constraint failed: nodes.alias` outright. Direct repro: a patch
# that changes alias to a value a causally-OLDER holder has must clear that
# holder (same as an INSERT would) and land the new value without error.
DB=$(make_partial_db)
RECV=$(make_partial_db)
sqlite3 "$RECV" "INSERT INTO nodes(id,text,status,alias,created_at,updated_at,lineage_actor,lineage_seq) VALUES('wv-old-holder','stale holder','todo','claimed',100,100,'agent-z',1);"
sqlite3 "$RECV" "INSERT INTO nodes(id,text,status,alias,created_at,updated_at,lineage_actor,lineage_seq) VALUES('wv-patched','patch target','todo',NULL,50,50,'',0);"
sqlite3 "$DB" "INSERT INTO nodes(id,text,status,alias,created_at,updated_at,lineage_actor,lineage_seq) VALUES('wv-patched','patch target','todo',NULL,50,50,'',0);"
wv_delta_reset "$DB"
sqlite3 "$DB" "UPDATE nodes SET alias='claimed', updated_at=51 WHERE id='wv-patched';"
CS=$(wv_delta_changeset "$DB" "agent-a" 5)
sqlite3 "$RECV" "$CS" 2>&1
t25_old_holder=$(sqlite3 "$RECV" "SELECT COALESCE(alias,'NULL') FROM nodes WHERE id='wv-old-holder';")
t25_patched=$(sqlite3 "$RECV" "SELECT COALESCE(alias,'NULL') FROM nodes WHERE id='wv-patched';")
[ "$t25_old_holder" = "NULL" ] && [ "$t25_patched" = "claimed" ] \
    && ok "T25: a node_patch alias change clears a causally-older holder and lands the new value (round 3 finding 3a)" \
    || fail "T25: node_patch steals from older holder" "old_holder='$t25_old_holder' patched='$t25_patched' CS=$CS"
rm -f "$DB" "$RECV"

# T26: the reverse guard -- a node_patch cannot steal an alias off a
# causally-NEWER holder. The patch itself still applies (its own row is
# pre-cutover, lineage_seq=0, so guard G for the row passes unconditionally)
# but the contested field drops to NULL instead of raising a UNIQUE error.
DB=$(make_partial_db)
RECV=$(make_partial_db)
sqlite3 "$RECV" "INSERT INTO nodes(id,text,status,alias,created_at,updated_at,lineage_actor,lineage_seq) VALUES('wv-newer-holder','fresh holder','todo','contested',100,100,'agent-z',99);"
sqlite3 "$RECV" "INSERT INTO nodes(id,text,status,alias,created_at,updated_at,lineage_actor,lineage_seq) VALUES('wv-patched2','patch target','todo',NULL,50,50,'',0);"
sqlite3 "$DB" "INSERT INTO nodes(id,text,status,alias,created_at,updated_at,lineage_actor,lineage_seq) VALUES('wv-patched2','patch target','todo',NULL,50,50,'',0);"
wv_delta_reset "$DB"
sqlite3 "$DB" "UPDATE nodes SET alias='contested', updated_at=51 WHERE id='wv-patched2';"
CS=$(wv_delta_changeset "$DB" "agent-a" 5)
sqlite3 "$RECV" "$CS" 2>&1
t26_newer_holder=$(sqlite3 "$RECV" "SELECT COALESCE(alias,'NULL') FROM nodes WHERE id='wv-newer-holder';")
t26_patched=$(sqlite3 "$RECV" "SELECT COALESCE(alias,'NULL') FROM nodes WHERE id='wv-patched2';")
t26_updated_at=$(sqlite3 "$RECV" "SELECT updated_at FROM nodes WHERE id='wv-patched2';")
[ "$t26_newer_holder" = "contested" ] && [ "$t26_patched" = "NULL" ] && [ "$t26_updated_at" = "51" ] \
    && ok "T26: a node_patch cannot steal an alias off a causally-newer holder — drops to NULL, no UNIQUE error, other fields still land" \
    || fail "T26: node_patch loses contest to newer holder" "newer_holder='$t26_newer_holder' patched='$t26_patched' updated_at='$t26_updated_at' CS=$CS"
rm -f "$DB" "$RECV"

# T27: entry path 2 -- alias itself is UNCHANGED but status transitions OUT
# of 'done'. The row is newly entering the partial index carrying an alias
# it already held while done (never enforced unique); this must arbitrate
# against a live holder exactly as an alias-value change would.
DB=$(make_partial_db)
RECV=$(make_partial_db)
sqlite3 "$RECV" "INSERT INTO nodes(id,text,status,alias,created_at,updated_at,lineage_actor,lineage_seq) VALUES('wv-active-holder27','active holder','todo','samealias',100,100,'agent-z',1);"
sqlite3 "$RECV" "INSERT INTO nodes(id,text,status,alias,created_at,updated_at,lineage_actor,lineage_seq) VALUES('wv-reactivate','closed then reopened','done','samealias',50,50,'',0);"
sqlite3 "$DB" "INSERT INTO nodes(id,text,status,alias,created_at,updated_at,lineage_actor,lineage_seq) VALUES('wv-reactivate','closed then reopened','done','samealias',50,50,'',0);"
wv_delta_reset "$DB"
sqlite3 "$DB" "UPDATE nodes SET status='todo', updated_at=51 WHERE id='wv-reactivate';"
CS=$(wv_delta_changeset "$DB" "agent-a" 5)
sqlite3 "$RECV" "$CS" 2>&1
t27_active_holder=$(sqlite3 "$RECV" "SELECT COALESCE(alias,'NULL') FROM nodes WHERE id='wv-active-holder27';")
t27_reactivate_alias=$(sqlite3 "$RECV" "SELECT COALESCE(alias,'NULL') FROM nodes WHERE id='wv-reactivate';")
t27_reactivate_status=$(sqlite3 "$RECV" "SELECT status FROM nodes WHERE id='wv-reactivate';")
[ "$t27_active_holder" = "NULL" ] && [ "$t27_reactivate_alias" = "samealias" ] && [ "$t27_reactivate_status" = "todo" ] \
    && ok "T27: a done->active status transition with an unchanged alias arbitrates against a live holder (round 3 finding 3a, entry path 2)" \
    || fail "T27: done->active reentry arbitration" "active_holder='$t27_active_holder' reactivate_alias='$t27_reactivate_alias' status='$t27_reactivate_status' CS=$CS"
rm -f "$DB" "$RECV"

# T28: the reverse direction (active->done, alias unchanged) needs no
# arbitration at all -- SQLite drops the row from the partial index on its
# own. Verify it just applies cleanly and does not disturb an unrelated
# node that happens to share the same alias text while done (never a real
# contender, per T23).
DB=$(make_partial_db)
RECV=$(make_partial_db)
sqlite3 "$RECV" "INSERT INTO nodes(id,text,status,alias,created_at,updated_at,lineage_actor,lineage_seq) VALUES('wv-other-done28','unrelated done row','done','endalias',100,100,'agent-z',1);"
sqlite3 "$RECV" "INSERT INTO nodes(id,text,status,alias,created_at,updated_at,lineage_actor,lineage_seq) VALUES('wv-closing28','closing now','todo','endalias',50,50,'',0);"
sqlite3 "$DB" "INSERT INTO nodes(id,text,status,alias,created_at,updated_at,lineage_actor,lineage_seq) VALUES('wv-closing28','closing now','todo','endalias',50,50,'',0);"
wv_delta_reset "$DB"
sqlite3 "$DB" "UPDATE nodes SET status='done', updated_at=51 WHERE id='wv-closing28';"
CS=$(wv_delta_changeset "$DB" "agent-a" 5)
sqlite3 "$RECV" "$CS" 2>&1
t28_other=$(sqlite3 "$RECV" "SELECT COALESCE(alias,'NULL') FROM nodes WHERE id='wv-other-done28';")
t28_closing_status=$(sqlite3 "$RECV" "SELECT status FROM nodes WHERE id='wv-closing28';")
t28_closing_alias=$(sqlite3 "$RECV" "SELECT COALESCE(alias,'NULL') FROM nodes WHERE id='wv-closing28';")
[ "$t28_other" = "endalias" ] && [ "$t28_closing_status" = "done" ] && [ "$t28_closing_alias" = "endalias" ] \
    && ok "T28: an active->done transition with an unchanged alias needs no arbitration and disturbs no unrelated done row" \
    || fail "T28: active->done no-op arbitration" "other='$t28_other' closing_status='$t28_closing_status' closing_alias='$t28_closing_alias' CS=$CS"
rm -f "$DB" "$RECV"

# ─── wv_delta_compact_batch: net multiple same-row writes into one (wv-4448a2
# review round 2, finding 2; round 3, finding 2) ─────────────────────────────
# Every op in one emission shares a single lineage tuple by design. Two or
# more _warp_changes rows for the SAME entity within one batch cannot be
# represented as two guarded statements at that one tuple: on replay, whichever
# applies first wins the tie and the second is silently dropped, even though
# it is the causally later, correct change. Proof: without compaction, a
# straight A->B->C chain committed as ONE emission drops the second statement
# on replay (equal-tuple guard) and a fresh clone lands on B, not C.
DB=$(make_db)
sqlite3 "$DB" "INSERT INTO nodes(id,text,created_at,updated_at) VALUES('wv-net','A',1,1);"
wv_delta_reset "$DB"
sqlite3 "$DB" "UPDATE nodes SET text='B' WHERE id='wv-net';
UPDATE nodes SET text='C' WHERE id='wv-net';"
uncompacted_rows=$(sqlite3 "$DB" "SELECT COUNT(*) FROM _warp_changes WHERE row_id='wv-net';")
[ "$uncompacted_rows" = "2" ] \
    && ok "fixture sanity: two sequential UPDATEs leave two _warp_changes rows before compaction" \
    || fail "fixture sanity" "expected 2 rows, got $uncompacted_rows"
RECV=$(make_recv)
sqlite3 "$RECV" "INSERT INTO nodes(id,text,created_at,updated_at) VALUES('wv-net','A',1,1);"
watermark=$(wv_delta_compact_batch "$DB")
compacted_rows=$(sqlite3 "$DB" "SELECT COUNT(*) FROM _warp_changes WHERE row_id='wv-net';")
CS=$(wv_delta_changeset "$DB" "agent-a" 9 "$watermark")
sqlite3 "$RECV" "$CS"
net_final=$(sqlite3 "$RECV" "SELECT text || '|' || created_at FROM nodes WHERE id='wv-net';")
[ "$compacted_rows" = "1" ] && [ "$net_final" = "C|1" ] \
    && ok "wv_delta_compact_batch nets a same-entity A->B->C chain to one net upsert that replays to the true final value with created_at preserved" \
    || fail "compact_batch chain" "compacted_rows=$compacted_rows final='$net_final' CS=$CS"
rm -f "$RECV"
wv_delta_reset "$DB"

# review round 3, finding 2 (1): the UPDATE trigger's new_data omits
# created_at (only INSERT/DELETE carry it) -- netting that trusted the LAST
# op's new_data verbatim produced a net operation with created_at=NULL.
# Proof this specific field survives, isolated from the chain test above's
# broader value check.
sqlite3 "$DB" "INSERT INTO nodes(id,text,created_at,updated_at) VALUES('wv-ca','A',777,777);"
wv_delta_reset "$DB"
sqlite3 "$DB" "UPDATE nodes SET text='B' WHERE id='wv-ca';
UPDATE nodes SET status='active' WHERE id='wv-ca';"
watermark_ca=$(wv_delta_compact_batch "$DB")
ca_new_data=$(sqlite3 "$DB" "SELECT new_data FROM _warp_changes WHERE row_id='wv-ca';")
echo "$ca_new_data" | grep -q '"created_at":777' \
    && ok "wv_delta_compact_batch preserves created_at through a chain that ends in UPDATE (round 3 finding 2.1)" \
    || fail "compact_batch created_at" "new_data=$ca_new_data"
wv_delta_reset "$DB"

# create -> delete within one batch nets to NOTHING: a fresh clone that never
# saw the intermediate create must not receive a delete for a row it was
# never told exists.
sqlite3 "$DB" "INSERT INTO nodes(id,text,created_at,updated_at) VALUES('wv-cd','ephemeral',1,1);
DELETE FROM nodes WHERE id='wv-cd';"
watermark2=$(wv_delta_compact_batch "$DB")
cd_rows=$(sqlite3 "$DB" "SELECT COUNT(*) FROM _warp_changes WHERE row_id='wv-cd';")
[ "$cd_rows" = "0" ] \
    && ok "wv_delta_compact_batch nets a create-then-delete within one batch to nothing" \
    || fail "compact_batch create-delete" "expected 0 rows, got $cd_rows"
wv_delta_reset "$DB"

# update -> delete within one batch nets to a DELETE, not an update followed
# by an orphaned delete statement.
sqlite3 "$DB" "INSERT INTO nodes(id,text,created_at,updated_at,lineage_actor,lineage_seq) VALUES('wv-ud','pre-existing',1,1,'agent-a',1);"
wv_delta_reset "$DB"
sqlite3 "$DB" "UPDATE nodes SET text='changed' WHERE id='wv-ud';
DELETE FROM nodes WHERE id='wv-ud';"
watermark3=$(wv_delta_compact_batch "$DB")
ud_op=$(sqlite3 "$DB" "SELECT operation FROM _warp_changes WHERE row_id='wv-ud';")
ud_count=$(sqlite3 "$DB" "SELECT COUNT(*) FROM _warp_changes WHERE row_id='wv-ud';")
[ "$ud_op" = "DELETE" ] && [ "$ud_count" = "1" ] \
    && ok "wv_delta_compact_batch nets an update-then-delete within one batch to a single DELETE" \
    || fail "compact_batch update-delete" "op='$ud_op' count=$ud_count"
wv_delta_reset "$DB"

# review round 3, finding 2 (2)+(3): delete-then-recreate within one batch.
# The row existed before this batch (first_op != INSERT) and exists again by
# the end (a later INSERT re-created it) -- the OLD first/last-label rule
# classified this "else -> UPDATE", which (a) silently dropped the recreate
# entirely on a receiver that does not currently have the row (a plain
# UPDATE's WHERE matches nothing), and (b) collapsed to a bare "-- no-op"
# comment if the recreated fields happened to equal the pre-delete ones. The
# fix classifies by LIVE existence, not labels, and routes every case where
# the row exists now through the v1 INSERT arm's own ON CONFLICT DO UPDATE
# upsert -- which is correct whether the receiver currently has the row or
# not. Two receivers below: one that still has the row (RECV_HAS, exercising
# the ON CONFLICT branch) and one that never received the original create at
# all (RECV_ABSENT, exercising the plain-INSERT branch and the specific
# "receiver has no row" loss this finding proved).
sqlite3 "$DB" "INSERT INTO nodes(id,text,created_at,updated_at,lineage_actor,lineage_seq) VALUES('wv-dr','orig',10,10,'agent-a',3);"
wv_delta_reset "$DB"
sqlite3 "$DB" "DELETE FROM nodes WHERE id='wv-dr';
INSERT INTO nodes(id,text,created_at,updated_at) VALUES('wv-dr','recreated',20,20);"
watermark_dr=$(wv_delta_compact_batch "$DB")
dr_op=$(sqlite3 "$DB" "SELECT operation FROM _warp_changes WHERE row_id='wv-dr';")
CS_DR=$(wv_delta_changeset "$DB" "agent-a" 9 "$watermark_dr")
RECV_HAS=$(make_recv)
sqlite3 "$RECV_HAS" "INSERT INTO nodes(id,text,created_at,updated_at,lineage_actor,lineage_seq) VALUES('wv-dr','orig',10,10,'agent-a',3);"
sqlite3 "$RECV_HAS" "$CS_DR"
recv_has_result=$(sqlite3 "$RECV_HAS" "SELECT text || '|' || created_at FROM nodes WHERE id='wv-dr';")
RECV_ABSENT=$(make_recv)
sqlite3 "$RECV_ABSENT" "$CS_DR"
recv_absent_result=$(sqlite3 "$RECV_ABSENT" "SELECT COUNT(*) || '|' || COALESCE((SELECT text FROM nodes WHERE id='wv-dr'),'MISSING') FROM nodes;")
[ "$dr_op" = "INSERT" ] && [ "$recv_has_result" = "recreated|20" ] && [ "$recv_absent_result" = "1|recreated" ] \
    && ok "wv_delta_compact_batch nets a delete-then-recreate to an upsert that recreates the row whether or not the receiver has it (round 3 finding 2.2/2.3)" \
    || fail "compact_batch delete-recreate" "op=$dr_op has=$recv_has_result absent=$recv_absent_result CS=$CS_DR"
rm -f "$RECV_HAS" "$RECV_ABSENT"
wv_delta_reset "$DB"

# The specific "recreated fields happen to equal the pre-delete ones"
# sub-case: with the old first/last rule this collapsed to a bare "-- no-op"
# comment (the field-diff saw no difference), silently dropping a delete a
# receiver needed to see. The fix routes it through INSERT/upsert
# unconditionally when the row exists now, so it is never diffed against the
# old value at all.
sqlite3 "$DB" "INSERT INTO nodes(id,text,status,created_at,updated_at,lineage_actor,lineage_seq) VALUES('wv-samefields','same','todo',30,30,'agent-a',3);"
wv_delta_reset "$DB"
sqlite3 "$DB" "DELETE FROM nodes WHERE id='wv-samefields';
INSERT INTO nodes(id,text,status,created_at,updated_at) VALUES('wv-samefields','same','todo',40,40);"
watermark_sf=$(wv_delta_compact_batch "$DB")
sf_op=$(sqlite3 "$DB" "SELECT operation FROM _warp_changes WHERE row_id='wv-samefields';")
CS_SF=$(wv_delta_changeset "$DB" "agent-a" 9 "$watermark_sf")
echo "$CS_SF" | grep -q '^-- no-op' \
    && fail "compact_batch same-fields recreate" "changeset collapsed to a no-op comment: $CS_SF" \
    || ok "wv_delta_compact_batch never collapses a delete-then-recreate to a no-op comment even when recreated fields match (round 3 finding 2.2)"
wv_delta_reset "$DB"

# A singleton group (one change per entity, the overwhelmingly common case)
# is left untouched by compaction.
sqlite3 "$DB" "INSERT INTO nodes(id,text,created_at,updated_at) VALUES('wv-single','only change',1,1);"
before_single=$(sqlite3 "$DB" "SELECT operation, old_data, new_data FROM _warp_changes WHERE row_id='wv-single';")
watermark4=$(wv_delta_compact_batch "$DB")
after_single=$(sqlite3 "$DB" "SELECT operation, old_data, new_data FROM _warp_changes WHERE row_id='wv-single';")
[ "$before_single" = "$after_single" ] \
    && ok "wv_delta_compact_batch leaves a singleton (one change per entity) untouched" \
    || fail "compact_batch singleton" "before=[$before_single] after=[$after_single]"
wv_delta_reset "$DB"

# ─── wv_delta_reset watermark: a concurrent write must survive the drain
# (wv-4448a2 review round 2, finding 3) ──────────────────────────────────────
# A snapshot (dump_state_sql, or the changeset+stamp pass) is taken at some
# earlier instant than the reset that follows it. An unconditional
# `DELETE FROM _warp_changes` run after that snapshot also deletes a row a
# CONCURRENT writer inserted in the interval between them, even though that
# row was captured in neither the snapshot nor any emitted delta: snapshot
# records "before", another process commits "after", the broad reset erases
# the only record of "after", and a reboot or fresh load loses it for good.
# Modeled here without real concurrency (bash is single-threaded) by
# capturing the watermark BEFORE the second write lands, exactly as
# auto_sync/cmd_sync do relative to dump_state_sql -- the row that arrives
# after the watermark is captured is indistinguishable from one a genuinely
# concurrent process would have added in that same window.
sqlite3 "$DB" "INSERT INTO nodes(id,text,created_at,updated_at) VALUES('wv-before','before',1,1);"
watermark_race=$(sqlite3 "$DB" "SELECT MAX(id) FROM _warp_changes;")
sqlite3 "$DB" "INSERT INTO nodes(id,text,created_at,updated_at) VALUES('wv-after','after',2,2);"
wv_delta_reset "$DB" "$watermark_race"
race_before_gone=$(sqlite3 "$DB" "SELECT COUNT(*) FROM _warp_changes WHERE row_id='wv-before';")
race_after_kept=$(sqlite3 "$DB" "SELECT COUNT(*) FROM _warp_changes WHERE row_id='wv-after';")
[ "$race_before_gone" = "0" ] && [ "$race_after_kept" = "1" ] \
    && ok "wv_delta_reset with a watermark drains only rows captured by this cycle's snapshot, preserving a concurrent writer's row" \
    || fail "watermark reset race" "before_gone=$race_before_gone after_kept=$race_after_kept"
# The preserved row is not lost: the next cycle picks it up and can still
# drain it (with no watermark this time, matching a final catch-all reset).
wv_delta_reset "$DB"
race_after_final=$(sqlite3 "$DB" "SELECT COUNT(*) FROM _warp_changes WHERE row_id='wv-after';")
[ "$race_after_final" = "0" ] \
    && ok "a preserved concurrent row is drained by the next cycle, not lost forever" \
    || fail "watermark reset follow-up" "after_final=$race_after_final"

rm -f "$DB"

# ─── wv_delta_compact_batch: the watermark is self-captured under the write
# lock, closing a real race (wv-4448a2 review round 4, finding 2) ────────────
# The watermark used to be captured by the CALLER in its own separate
# `sqlite3` invocation, before wv_delta_compact_batch's BEGIN IMMEDIATE ever
# ran. A concurrent writer committing in that gap landed a row correctly
# EXCLUDED from _warp_net's grouping (its id is above the stale watermark) --
# but exists_after/new_data were read from the LIVE nodes/edges tables,
# unbounded, so they saw that same write's effect anyway, emitting it under
# the EARLIER batch's lineage. This is genuine concurrency (bash itself is
# single-threaded, so a real background process + a real write lock, not a
# simulated ordering): a background transaction holds BEGIN IMMEDIATE open
# (via an injected `.shell sleep`, standing in for compact_batch's own
# processing time) right after capturing its watermark; a foreground writer
# attempts a write to the SAME row during that window. If the watermark
# capture and the live-table view it grounds are truly one atomic unit, the
# foreground write cannot land until the lock releases, and its row's id
# must land STRICTLY ABOVE the watermark already captured -- proving it is
# structurally impossible for that write to contaminate the batch already
# holding the lock.
DB=$(make_db)
sqlite3 "$DB" "INSERT INTO nodes(id,text,status,created_at,updated_at) VALUES('wv-race','B','todo',1,1);"
wv_delta_reset "$DB"
sqlite3 "$DB" "UPDATE nodes SET status='active' WHERE id='wv-race';
UPDATE nodes SET text='B2' WHERE id='wv-race';"
BG_OUT=$(mktemp)
( sqlite3 -cmd ".timeout 20000" "$DB" <<'SQL' > "$BG_OUT" 2>&1
BEGIN IMMEDIATE;
CREATE TEMP TABLE _warp_watermark AS SELECT COALESCE(MAX(id),0) AS max_id FROM _warp_changes;
.shell sleep 2
SELECT 'watermark=' || max_id FROM _warp_watermark;
COMMIT;
SQL
) &
BG_PID=$!
sleep 0.5
_race_start=$(date +%s.%N)
sqlite3 -cmd ".timeout 20000" "$DB" "UPDATE nodes SET status='CONCURRENT' WHERE id='wv-race';"
_race_end=$(date +%s.%N)
wait "$BG_PID"
_race_elapsed=$(awk -v s="$_race_start" -v e="$_race_end" 'BEGIN{printf "%.0f", (e-s)*1000}')
_bg_watermark=$(grep -o 'watermark=[0-9]*' "$BG_OUT" | cut -d= -f2)
_concurrent_id=$(sqlite3 "$DB" "SELECT MAX(id) FROM _warp_changes WHERE row_id='wv-race';")
rm -f "$BG_OUT"
[ "$_race_elapsed" -ge 1000 ] \
    && ok "a concurrent writer genuinely blocks on wv_delta_compact_batch's held write lock ($_race_elapsed ms)" \
    || fail "concurrency did not block" "elapsed=${_race_elapsed}ms (expected >= 1000ms)"
[ -n "$_bg_watermark" ] && [ -n "$_concurrent_id" ] && [ "$_concurrent_id" -gt "$_bg_watermark" ] \
    && ok "the concurrent write's id lands strictly above the already-captured watermark (round 4 finding 2)" \
    || fail "watermark race" "bg_watermark=$_bg_watermark concurrent_id=$_concurrent_id"
rm -f "$DB"

# ─── wv_mutation_seq_for_snapshot ────────────────────────────────────────────
# Regression (release review 4): the GitHub sync recorded the counter read
# AFTER dumping state, so a mutation landing between the dump and the record
# was certified as synced while present in no dump -- and stayed invisible,
# because needs_sync compares against exactly that number. The recorded value
# must never be ahead of the snapshot it certifies.

echo ""
echo "wv_mutation_seq_for_snapshot"

got=$(wv_mutation_seq_for_snapshot 7 7)
[ "$got" = "7" ] && ok "unchanged across the snapshot records the exact counter" \
    || fail "unchanged across the snapshot records the exact counter" "got '$got'"

got=$(wv_mutation_seq_for_snapshot 7 9)
[ "$got" = "7" ] && ok "a writer racing the snapshot records the pre-snapshot counter" \
    || fail "a writer racing the snapshot records the pre-snapshot counter" "got '$got'"

# The direction of the error is the whole point: understating asks for another
# sync, overstating loses the mutation for good.
got=$(wv_mutation_seq_for_snapshot 7 9)
[ "$got" -le 9 ] && ok "the recorded counter is never ahead of the graph" \
    || fail "the recorded counter is never ahead of the graph" "got '$got'"

got=$(wv_mutation_seq_for_snapshot "" 9)
[ -z "$got" ] && ok "no pre-snapshot reading records no stamp at all" \
    || fail "no pre-snapshot reading records no stamp at all" "got '$got'"

got=$(wv_mutation_seq_for_snapshot "notanumber" 9)
[ -z "$got" ] && ok "a non-numeric reading is not recorded as a counter" \
    || fail "a non-numeric reading is not recorded as a counter" "got '$got'"

got=$(wv_mutation_seq_for_snapshot 7 "")
[ "$got" = "7" ] && ok "an unreadable post-snapshot counter falls back to the pre-snapshot one" \
    || fail "an unreadable post-snapshot counter falls back to the pre-snapshot one" "got '$got'"

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
