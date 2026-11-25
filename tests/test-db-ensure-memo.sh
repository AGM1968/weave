#!/usr/bin/env bash
# Suite-driven wv calls are tagged test so call-stats retro reads can exclude them.
export WV_CALL_SOURCE=test
# db_ensure runs its migrations once per process per database (wv-3d6ed0).
#
# Without a fast path every db_query re-ran about ten migration probes, each its
# own sqlite3, at ~220ms per query: wv add went from 515ms to 1520ms per call
# once f43c52f4a added queries to the --force paths, and the suites that call it
# thousands of times slowed two to three times over. The memo is keyed on the
# DB path and inode, so a replaced file is migrated again, and code that
# rebuilds the DB under the same path clears it.
#
# The probe is the nodes_policy_check trigger, which db_migrate_test_gate (the
# last migration) re-creates: a db_ensure that ran the migrations restores it,
# one that took the fast path leaves it dropped. Driven through sourced helpers,
# not the wv binary, because one wv invocation cannot show two ensures apart.
#
# Isolation note (see test-edge-enum-lineage.sh): wv-config.sh discards a
# WV_HOT_ZONE that does not match REPO_ROOT, so the helpers run with the
# fixture directory as cwd, and the suite checks the isolation held.
set -uo pipefail
export WV_TEST_SUITE=1  # the user's config.env cannot log this suite's wv calls (wv-6b0f57)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck disable=SC1091  # resolved at run time
source "$ROOT/scripts/lib/wv-lock.sh"  # flock(1) is util-linux; macOS has none (wv-412db3)
WV="$ROOT/scripts/wv"

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
run=0; pass=0
ok() { run=$((run+1)); pass=$((pass+1)); echo -e "  ${GREEN}✓${NC} $1"; }
bad() { run=$((run+1)); echo -e "  ${RED}✗${NC} $1"; [ -n "${2:-}" ] && echo "      $2"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2], got [$3]"; fi; }

echo "db_ensure per-process memo"

TEST_DIR=$(mktemp -d /tmp/wv-ensure-memo-XXXXXX)
trap 'rm -rf "$TEST_DIR"' EXIT

export WEAVE_DIR="$TEST_DIR/.weave"
export WV_HOT_ZONE="$TEST_DIR/hot"
export WV_DB="$TEST_DIR/hot/brain.db"
export WV_CONFIG_DIR="$TEST_DIR/config"
export WV_AUTO_SYNC=0
export WV_AUTO_CHECKPOINT=0
mkdir -p "$WEAVE_DIR" "$WV_CONFIG_DIR" "$TEST_DIR/hot"
cd "$TEST_DIR" || exit 1

"$WV" add "ensure memo node" >/dev/null 2>&1
trigger_count() { sqlite3 "$WV_DB" "SELECT COUNT(*) FROM sqlite_master WHERE type='trigger' AND name='nodes_policy_check';" 2>/dev/null; }
if [ ! -f "$WV_DB" ] || [ "$(trigger_count)" != "1" ]; then
    bad "isolated graph created with its policy trigger" "db=$WV_DB trigger=$(trigger_count)"
    echo ""; echo "Results: $pass/$run passed"; exit 1
fi
ok "isolated graph created with its policy trigger"

# Each step drops the trigger (or not), ensures, and reports whether it is there.
result=$(cd "$TEST_DIR" && bash -c "
source '$ROOT/scripts/lib/wv-config.sh' 2>/dev/null
source '$ROOT/scripts/lib/wv-db-lineage.sh' 2>/dev/null
source '$ROOT/scripts/lib/wv-db.sh' 2>/dev/null
[ \"\$WV_DB\" = '$WV_DB' ] || { echo 'ISOLATION-LOST'; exit 1; }
drop() { sqlite3 \"\$WV_DB\" 'DROP TRIGGER IF EXISTS nodes_policy_check;'; }
count() { sqlite3 \"\$WV_DB\" \"SELECT COUNT(*) FROM sqlite_master WHERE type='trigger' AND name='nodes_policy_check';\"; }
db_ensure >/dev/null 2>&1; first=\$(count)
drop; db_ensure >/dev/null 2>&1; memo=\$(count)
drop; ( db_ensure >/dev/null 2>&1 ); subshell=\$(count)
_WV_DB_READY=''; db_ensure >/dev/null 2>&1; reset=\$(count)
drop; cp \"\$WV_DB\" \"\$WV_DB.new\" && mv \"\$WV_DB.new\" \"\$WV_DB\"
db_ensure >/dev/null 2>&1; replaced=\$(count)
printf '%s|%s|%s|%s|%s' \"\$first\" \"\$memo\" \"\$subshell\" \"\$reset\" \"\$replaced\"
")

if [ "$result" = "ISOLATION-LOST" ]; then
    bad "fixture database is the one under test" "wv-config rejected the hot-zone override"
    echo ""; echo "Results: $pass/$run passed"; exit 1
fi
ok "fixture database is the one under test"

IFS='|' read -r first memo subshell reset replaced <<<"$result"
check "the first db_ensure in a process leaves a migrated schema" "1" "$first"
check "a second db_ensure on the same database takes the fast path" "0" "$memo"
check "a subshell (a \$(db_query) capture) inherits the memo" "0" "$subshell"
check "clearing _WV_DB_READY makes db_ensure migrate again" "1" "$reset"
check "a replaced database file (new inode) is migrated again" "1" "$replaced"

# ── cross-process schema stamp (wv-048429) ────────────────────────────────────
# Every wv process still paid one full ensure (~170ms of sqlite3 calls). After
# migrating, db_ensure writes $WV_DB.ensured: a checksum over the DB inode, the
# files defining the migrations, and the schema text. A new process whose stamp
# matches skips the migrations. Each case below runs in a FRESH process (no
# memo), counts sqlite3 calls through a PATH shim, and uses the seeded
# test_gate threshold row as a data probe: only a real migration run re-seeds
# it, so a deleted row coming back means the migrations ran.
echo ""
echo "db_ensure cross-process schema stamp"

SHIM="$TEST_DIR/shim"; mkdir -p "$SHIM"
SQLITE_LOG="$TEST_DIR/sqlite-calls"
printf '#!/bin/sh\necho call >> "%s"\nexec %s "$@"\n' "$SQLITE_LOG" "$(command -v sqlite3)" > "$SHIM/sqlite3"
chmod +x "$SHIM/sqlite3"
LIB="$TEST_DIR/lib"; mkdir -p "$LIB"
cp "$ROOT/scripts/lib/wv-db.sh" "$ROOT/scripts/lib/wv-db-lineage.sh" "$ROOT/scripts/lib/wv-lock.sh" "$LIB/"

# fresh <snippet> — one new process: source the helpers (wv-db.sh from $LIB,
# so an edit there is a code change), run the snippet with sqlite3 counted.
fresh() {
    (cd "$TEST_DIR" && PATH="$SHIM:$PATH" bash -c "
source '$ROOT/scripts/lib/wv-config.sh' 2>/dev/null
source '$LIB/wv-db.sh' 2>/dev/null
[ \"\$WV_DB\" = '$WV_DB' ] || { echo 'ISOLATION-LOST'; exit 1; }
$1")
}
seeded() { sqlite3 "$WV_DB" "SELECT COUNT(*) FROM policy_thresholds WHERE key = 'test_gate';" 2>/dev/null; }
unseed() { sqlite3 "$WV_DB" "DELETE FROM policy_thresholds WHERE key = 'test_gate';" 2>/dev/null; }
calls() { : > "$SQLITE_LOG"; fresh "db_ensure >/dev/null 2>&1" >/dev/null; wc -l < "$SQLITE_LOG" | tr -d ' '; }

fresh "db_ensure >/dev/null 2>&1" >/dev/null
check "a migrating db_ensure writes the stamp file" "present" "$([ -s "$WV_DB.ensured" ] && echo present || echo absent)"
check "a migrating db_ensure seeds the probe row" "1" "$(seeded)"

n=$(calls)
check "a new process with a current stamp checks it in one sqlite3 call" "1" "$n"
unseed
fresh "db_ensure >/dev/null 2>&1" >/dev/null
check "...and does not run the migrations (a data-only deletion is not re-seeded)" "0" "$(seeded)"

sqlite3 "$WV_DB" "DROP TRIGGER IF EXISTS nodes_policy_check;"
fresh "db_ensure >/dev/null 2>&1" >/dev/null
check "an out-of-band schema change is migrated again" "1" "$(trigger_count)"
check "...which re-seeds the probe row" "1" "$(seeded)"

unseed
printf '\n# a code change\n' >> "$LIB/wv-db.sh"
fresh "db_ensure >/dev/null 2>&1" >/dev/null
check "a change to the migration code is migrated again" "1" "$(seeded)"

unseed
rm -f "$WV_DB.ensured"
fresh "db_ensure >/dev/null 2>&1" >/dev/null
check "a missing stamp is migrated again" "1" "$(seeded)"

unseed
cp "$WV_DB" "$WV_DB.new" && mv "$WV_DB.new" "$WV_DB"
fresh "db_ensure >/dev/null 2>&1" >/dev/null
check "a replaced database file is migrated again" "1" "$(seeded)"

unseed
printf 'garbage\n' > "$WV_DB.ensured"
fresh "db_ensure >/dev/null 2>&1" >/dev/null
check "a stamp that does not match is migrated again" "1" "$(seeded)"

# A cold-start race (ultrareview #4574): processes that found no stamp queue on
# the schema lock, and the first one migrates and stamps. The rest must re-check
# under the lock rather than migrate again. Staged deterministically: this test
# holds the lock, a fresh process finds no stamp and waits, the test restores a
# current stamp and releases. The probe row, deleted beforehand, comes back
# only if the waiting process migrated anyway.
fresh "db_ensure >/dev/null 2>&1" >/dev/null
saved_stamp=$(cat "$WV_DB.ensured")
unseed; rm -f "$WV_DB.ensured"
( exec 8>"$WV_HOT_ZONE/.schema.lock"; wv_lock_fd 8 -x 10; sleep 2; printf '%s\n' "$saved_stamp" > "$WV_DB.ensured" ) &
holder=$!
sleep 0.5
fresh "db_ensure >/dev/null 2>&1" >/dev/null
wait "$holder"
check "a process that waited on the schema lock and finds the stamp current does not migrate" "0" "$(seeded)"

# A migration that fails is not stamped as done (wv-e90d62). The migrations
# swallow their own sqlite3 errors (2>/dev/null || true), so on 2026-09-29 a
# learning-index migration that failed once was stamped anyway, and every later
# process took the stamp's word that the schema was complete. A sqlite3 shim
# fails that one migration once, as a transient SQLITE_BUSY would; the next
# fresh process must recreate the index rather than trust the stamp.
echo ""
echo "db_ensure does not stamp a schema a migration failed to complete"

FAIL_FLAG="$TEST_DIR/fail-learning-fts-once"
FAILSHIM="$TEST_DIR/failshim"; mkdir -p "$FAILSHIM"
REAL_SQLITE=$(command -v sqlite3)
# Only a script-on-stdin call (the database as the sole argument, as the
# migration heredocs are) is inspected; every query-as-argument call passes
# straight through, so the probes db_ensure runs first see a real sqlite3.
cat > "$FAILSHIM/sqlite3" <<EOF
#!/bin/sh
if [ -f "$FAIL_FLAG" ] && [ \$# -eq 1 ]; then
    in=\$(cat)
    case "\$in" in
        *"CREATE VIRTUAL TABLE IF NOT EXISTS nodes_learning_fts"*) rm -f "$FAIL_FLAG"; exit 1 ;;
    esac
    printf '%s\n' "\$in" | exec "$REAL_SQLITE" "\$@"
fi
exec "$REAL_SQLITE" "\$@"
EOF
chmod +x "$FAILSHIM/sqlite3"
learning_fts() { sqlite3 "$WV_DB" "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='nodes_learning_fts';" 2>/dev/null; }

fresh "db_ensure >/dev/null 2>&1" </dev/null >/dev/null
sqlite3 "$WV_DB" "DROP TABLE IF EXISTS nodes_learning_fts;"
touch "$FAIL_FLAG"
(cd "$TEST_DIR" && PATH="$FAILSHIM:$PATH" bash -c "
source '$ROOT/scripts/lib/wv-config.sh' 2>/dev/null
source '$LIB/wv-db.sh' 2>/dev/null
db_ensure >/dev/null 2>&1" </dev/null)
check "the injected migration failure fired" "fired" "$([ -f "$FAIL_FLAG" ] && echo armed || echo fired)"
check "...and left the learning index missing" "0" "$(learning_fts)"
fresh "db_ensure >/dev/null 2>&1" </dev/null >/dev/null
check "the next process recreates what the failed migration left out" "1" "$(learning_fts)"

echo ""
echo "Results: $pass/$run passed"
[ "$pass" -eq "$run" ]
