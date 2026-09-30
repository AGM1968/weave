#!/usr/bin/env bash
# Suite-driven wv calls are tagged test so call-stats retro reads can exclude them.
export WV_CALL_SOURCE=test
# The live database changes only through SQLite (wv-f241fa).
#
# wv load used to install its import with rm+mv. Any wv process holding the
# live file open -- a parallel SessionStart hook, the status line -- then wrote
# its next commit into the new file's WAL, computed against the old image, and
# the graph read "malformed" (it did, 2026-09-26). wv init --force removed the
# database but left its WAL for the next connection to replay. Each case below
# drives the real wv against an isolated hot zone.
#
# Isolation note: wv-config.sh treats a WV_HOT_ZONE that does not match
# REPO_ROOT as a leaked override and refuses to run (wv-5e804e), so the fixture runs
# with its own directory as cwd.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WV="$ROOT/scripts/wv"

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
run=0; pass=0
ok() { run=$((run+1)); pass=$((pass+1)); echo -e "  ${GREEN}✓${NC} $1"; }
bad() { run=$((run+1)); echo -e "  ${RED}✗${NC} $1"; [ -n "${2:-}" ] && echo "      $2"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2], got [$3]"; fi; }

echo "load and init change the live database only through SQLite"

TEST_DIR=$(mktemp -d /tmp/wv-load-swap-XXXXXX)
trap 'rm -rf "$TEST_DIR"' EXIT

export WEAVE_DIR="$TEST_DIR/.weave"
export WV_HOT_ZONE="$TEST_DIR/hot"
export WV_DB="$TEST_DIR/hot/brain.db"
export WV_CONFIG_DIR="$TEST_DIR/config"
export WV_AUTO_CHECKPOINT=0
cd "$TEST_DIR" || exit 1

# A graph of seven nodes whose state.sql holds only the first three, so a load
# visibly replaces the live contents.
fixture() {
    rm -rf "$WEAVE_DIR" "$WV_HOT_ZONE" "$WV_CONFIG_DIR"
    mkdir -p "$WEAVE_DIR" "$WV_CONFIG_DIR" "$WV_HOT_ZONE"
    local i
    for i in 1 2 3; do "$WV" add "swap node $i" >/dev/null 2>&1; done
    sqlite3 "$WV_DB" ".dump" > "$WEAVE_DIR/state.sql" 2>/dev/null
    for i in 4 5 6 7; do "$WV" add "swap node $i" >/dev/null 2>&1; done
}
integrity() { python3 -c 'import sqlite3,sys
try: print(sqlite3.connect(sys.argv[1]).execute("PRAGMA integrity_check").fetchone()[0])
except sqlite3.Error as e: print("error:", e)' "$WV_DB"; }
nodes() { sqlite3 "$WV_DB" "SELECT COUNT(*) FROM nodes;" 2>/dev/null || echo "unreadable"; }

fixture
if [ "$(nodes)" != "7" ] || ! grep -q 'swap node 3' "$WEAVE_DIR/state.sql"; then
    bad "isolated graph created" "nodes=$(nodes) db=$WV_DB"
    echo ""; echo "  $pass/$run passed"; exit 1
fi
ok "isolated graph created"

# 1. A connection opened before the load and written after it. sqlite3.connect
# opens the database file; the WAL is opened by path at the first statement.
probe=$(python3 - "$WV_DB" "$WV" <<'EOF'
import sqlite3, subprocess, sys
db, wv = sys.argv[1], sys.argv[2]
con = sqlite3.connect(db, isolation_level=None)
r = subprocess.run([wv, "load"], capture_output=True, text=True)
print("load", r.returncode)
try:
    con.execute("CREATE TABLE swap_probe(x)")
    con.execute("INSERT INTO swap_probe VALUES (1)")
    con.close()
    print("write ok")
except sqlite3.Error as e:
    print("write", e)
EOF
)
check "load succeeds with a connection open" "load 0" "$(sed -n 1p <<<"$probe")"
check "the open connection can still write" "write ok" "$(sed -n 2p <<<"$probe")"
check "the graph is intact after the load" "ok" "$(integrity)"
check "the load installed state.sql" "3" "$(nodes)"
check "the open connection's write landed in the new graph" "1" \
    "$(sqlite3 "$WV_DB" "SELECT COUNT(*) FROM swap_probe;" 2>/dev/null || echo missing)"
check "the live database stays in WAL mode" "wal" "$(sqlite3 "$WV_DB" "PRAGMA journal_mode;" 2>/dev/null)"

# 2. A live file already corrupt is replaced: nothing consistent is left to
# protect, and this is how a load heals a hot zone.
fixture
sqlite3 "$WV_DB" "PRAGMA wal_checkpoint(TRUNCATE);" >/dev/null 2>&1
python3 - "$WV_DB" <<'EOF'
import sys
with open(sys.argv[1], "r+b") as f:
    f.seek(4096)              # page 2 onwards: the schema survives, the b-trees do not
    f.write(b"\xa5" * 4096 * 4)
EOF
[ "$(integrity)" != "ok" ] && ok "fixture corrupted the live database" \
    || bad "fixture corrupted the live database" "integrity still ok"
"$WV" load >/dev/null 2>&1
check "load replaces a corrupt live database" "ok" "$(integrity)"
check "the replacement holds state.sql" "3" "$(nodes)"

# 3. A healthy file held locked past the timeout is refused, never replaced
# out from under its holder.
fixture
lock_ready="$TEST_DIR/lock-ready"
python3 - "$WV_DB" "$lock_ready" <<'EOF' &
import sqlite3, sys, time
con = sqlite3.connect(sys.argv[1], isolation_level=None)
con.execute("BEGIN EXCLUSIVE")
open(sys.argv[2], "w").close()
time.sleep(12)
con.execute("ROLLBACK")
EOF
holder=$!
for _ in $(seq 1 50); do [ -f "$lock_ready" ] && break; sleep 0.1; done
load_err=$("$WV" load 2>&1 >/dev/null)
load_rc=$?
wait "$holder" 2>/dev/null
[ "$load_rc" -ne 0 ] && ok "load fails while the live database is locked" \
    || bad "load fails while the live database is locked" "rc=$load_rc"
if grep -qF -- "stayed locked" <<<"$load_err"; then ok "the failure names the lock"
else bad "the failure names the lock" "$(tail -3 <<<"$load_err")"; fi
check "the locked database was left intact" "ok" "$(integrity)"
check "the locked database kept its contents" "7" "$(nodes)"

# 4. init --force takes the WAL with the database. The holder keeps committed
# frames in the WAL (no checkpoint) while init replaces the file, and exits
# without closing: a close would checkpoint and delete the -wal path.
fixture
python3 - "$WV_DB" "$WV" <<'EOF'
import sqlite3, subprocess, sys
db, wv = sys.argv[1], sys.argv[2]
con = sqlite3.connect(db, isolation_level=None)
con.execute("PRAGMA wal_autocheckpoint=0")
con.execute("CREATE TABLE wal_resident(x)")
con.execute("INSERT INTO wal_resident VALUES (1)")
subprocess.run([wv, "init", "--force"], capture_output=True, text=True, input="y\n")
import os; os._exit(0)
EOF
# integrity_check alone passed on the unfixed code; the replayed WAL showed as
# a nodes table no query could read, which the count below catches.
check "init --force leaves a database passing integrity_check" "ok" "$(integrity)"
check "init --force leaves an empty, readable graph" "0" "$(nodes)"

echo ""
echo "  $pass/$run passed"
[ "$pass" -eq "$run" ]
