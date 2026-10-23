#!/usr/bin/env bash
# Suite-driven wv calls are tagged test so call-stats retro reads can exclude them.
export WV_CALL_SOURCE=test
# A lineage stamp failure must route to recovery, not promise a retry.
#
# wv_lineage_stamp aborts the emission when it cannot stamp, and the caller said
# "will retry next sync" for every cause alike. That is true for contention and
# false for a schema fault: when the writer-lineage columns are missing, or in an
# order ALTER TABLE cannot reach, every later sync fails here identically, so the
# promise is reassurance for a permanent outage (wv-c395a3).
#
# The status is now three-valued -- 0 stamped, 1 transient, 2 unfixable by
# retrying -- and this suite pins the operator-visible consequence of each:
#
#   canonical schema, write refused  -> 1, says it is NOT a schema fault
#   repairable (columns missing)     -> 0, repaired in place and retried once
#   reversed (seq-first)             -> 2, says why, and names the recovery
#
# Isolation note: wv-config.sh treats a WV_HOT_ZONE that does not match
# REPO_ROOT as a leaked override and refuses to run (wv-5e804e), so these helpers run
# with the fixture directory as cwd and every case asserts WV_DB is the fixture
# before trusting a result. Without that a failure here reads as a pass against
# the developer's live graph.
set -uo pipefail
export WV_TEST_SUITE=1  # the user's config.env cannot log this suite's wv calls (wv-6b0f57)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WV="$ROOT/scripts/wv"

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
run=0; pass=0
ok() { run=$((run+1)); pass=$((pass+1)); echo -e "  ${GREEN}✓${NC} $1"; }
bad() { run=$((run+1)); echo -e "  ${RED}✗${NC} $1"; [ -n "${2:-}" ] && echo "      $2"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2], got [$3]"; fi; }

echo "lineage stamp failure routes to recovery"

if [ "$(id -u)" = "0" ]; then
    echo "  (skipped: running as root, chmod cannot deny writes)"
    echo ""; echo "  0/0 passed"; exit 0
fi

TEST_DIR=$(mktemp -d /tmp/wv-stamp-XXXXXX)
cleanup() { chmod -R u+w "$TEST_DIR" 2>/dev/null || true; rm -rf "$TEST_DIR"; }
trap cleanup EXIT

export WEAVE_DIR="$TEST_DIR/.weave"
export WV_HOT_ZONE="$TEST_DIR/hot"
export WV_DB="$TEST_DIR/hot/brain.db"
export WV_CONFIG_DIR="$TEST_DIR/config"
export WV_AUTO_SYNC=0
export WV_AUTO_CHECKPOINT=0
mkdir -p "$WEAVE_DIR" "$WV_CONFIG_DIR" "$TEST_DIR/hot"
cd "$TEST_DIR" || exit 1

"$WV" add "stamp probe" >/dev/null 2>&1
if [ ! -f "$WV_DB" ]; then
    bad "isolated graph created" "no database at $WV_DB"
    echo ""; echo "  $pass/$run passed"; exit 1
fi
ok "isolated graph created"

cp "$WV_DB" "$TEST_DIR/pristine.db"

# stamp_case <setup-sql-or-empty> — run wv_lineage_stamp once against the
# fixture and print "<rc>|<stderr>". The setup runs inside the same shell so a
# schema change lands before the stamp sees it. Each case starts from the
# pristine database: the cases mutate schema, and left sequential one case's
# repair silently satisfies the next one's precondition.
stamp_case() {
    local setup="$1"
    cp "$TEST_DIR/pristine.db" "$WV_DB"
    (cd "$TEST_DIR" && bash -c "
source '$ROOT/scripts/lib/wv-config.sh' 2>/dev/null
source '$ROOT/scripts/lib/wv-db-lineage.sh' 2>/dev/null
source '$ROOT/scripts/lib/wv-db.sh' 2>/dev/null
source '$ROOT/scripts/lib/wv-delta.sh' 2>/dev/null
[ \"\$WV_DB\" = '$WV_DB' ] || { echo 'ISOLATION-LOST'; exit 1; }
# The stamp's subqueries read _warp_changes. Without it every case fails with
# 'no such table' before reaching the schema it is meant to be classifying,
# which silently turns the repairable case into an unrepairable verdict.
wv_delta_init \"\$WV_DB\" >/dev/null 2>&1
${setup}
err=\$(wv_lineage_stamp \"\$WV_DB\" 'test-actor' 99 2>&1 >/dev/null); rc=\$?
printf '%s|%s' \"\$rc\" \"\$(printf '%s' \"\$err\" | tr '\n' ' ')\"
")
}

# ── canonical schema, but the write itself is refused ─────────────────────────

# The chmod runs inside the case, after stamp_case has restored the pristine
# database: denying writes to the directory first would block that copy.
res=$(stamp_case "chmod 500 \"\$WV_HOT_ZONE\"; chmod 400 \"\$WV_DB\"")
chmod 700 "$TEST_DIR/hot"; chmod 600 "$WV_DB"

if [ "$res" = "ISOLATION-LOST" ]; then
    bad "fixture database is the one under test" "wv-config rejected the hot-zone override"
    echo ""; echo "  $pass/$run passed"; exit 1
fi
ok "fixture database is the one under test"

rc="${res%%|*}"; msg="${res#*|}"
check "a readonly database is reported as transient, not permanent" "1" "$rc"
# Either transient wording is correct here, and which one appears depends on how
# thoroughly the sandbox denied access: a readable database reports the schema as
# intact, while one whose directory blocks the -wal/-shm files cannot be read at
# all and says so. What must never appear is a claim that the SCHEMA is broken.
if grep -qE "not a schema fault|not known to be the schema" <<<"$msg"; then
    ok "a transient failure does not blame the schema"
else
    bad "a transient failure does not blame the schema" "stderr: [${msg:0:220}]"
fi
if grep -q "cannot be repaired in place" <<<"$msg"; then
    bad "a transient failure is not reported as unrepairable" "stderr: [${msg:0:220}]"
else
    ok "a transient failure is not reported as unrepairable"
fi

# ── repairable: the lineage columns are missing from edges ────────────────────

res=$(stamp_case "
sqlite3 \"\$WV_DB\" <<'SQL' >/dev/null 2>&1
PRAGMA foreign_keys = OFF;
BEGIN;
ALTER TABLE edges RENAME TO edges_pre;
CREATE TABLE edges (
    source TEXT NOT NULL, target TEXT NOT NULL,
    type TEXT NOT NULL CHECK(type IN ('blocks','relates_to','implements','contradicts','supersedes','references','obsoletes','addresses','resolves')),
    weight REAL DEFAULT 1.0, context JSON DEFAULT '{}', created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY(source, target, type));
INSERT INTO edges (source,target,type,weight,context,created_at)
  SELECT source,target,type,weight,context,created_at FROM edges_pre;
DROP TABLE edges_pre;
COMMIT;
SQL
")
rc="${res%%|*}"; msg="${res#*|}"
check "a repairable shape is migrated and retried into success" "0" "$rc"
if grep -q "repaired in place" <<<"$msg"; then
    ok "the repair is stated rather than silent"
else
    bad "the repair is stated rather than silent" "stderr: [${msg:0:220}]"
fi

# ── seq-only: lineage_actor absent, which the stamp genuinely cannot write ────
#
# This is the shape that reaches the permanent arm. Reversed is covered by the
# same arm and the same message, but reversed alone does NOT break the stamp --
# see the case below.

res=$(stamp_case "
sqlite3 \"\$WV_DB\" <<'SQL' >/dev/null 2>&1
ALTER TABLE edges RENAME COLUMN lineage_actor TO la_x;
SQL
")
rc="${res%%|*}"; msg="${res#*|}"
check "a seq-only shape is refused as unfixable by retrying" "2" "$rc"
if grep -q "ALTER TABLE can only append" <<<"$msg"; then
    ok "the refusal says WHY it cannot be repaired"
else
    bad "the refusal says WHY it cannot be repaired" "stderr: [${msg:0:260}]"
fi
if grep -q "Retrying will fail identically" <<<"$msg"; then
    ok "the refusal contradicts the retry promise explicitly"
else
    bad "the refusal contradicts the retry promise explicitly" "stderr: [${msg:0:260}]"
fi
if grep -q "wv doctor" <<<"$msg" && grep -q "wv load" <<<"$msg"; then
    ok "the refusal names wv doctor and the hot-zone recovery"
else
    bad "the refusal names wv doctor and the hot-zone recovery" "stderr: [${msg:0:260}]"
fi
if grep -q "will retry next sync" <<<"$msg"; then
    bad "a permanent fault never promises a retry" "stderr claimed a retry: [${msg:0:260}]"
else
    ok "a permanent fault never promises a retry"
fi

# ── reversed alone does not break the stamp, and must not be reported as if ───
#
# UPDATE does not care about column ORDER, so a reversed pair stamps fine. It
# still breaks sync via the byte-compared state.sql, which is wv doctor's and
# the health probe's job to catch, not this one's. Pinned so a future change
# cannot start reporting a working stamp as a permanent lineage fault.

res=$(stamp_case "
sqlite3 \"\$WV_DB\" <<'SQL' >/dev/null 2>&1
ALTER TABLE edges RENAME COLUMN lineage_actor TO la_x;
ALTER TABLE edges RENAME COLUMN lineage_seq   TO ls_x;
ALTER TABLE edges ADD COLUMN lineage_seq   INTEGER NOT NULL DEFAULT 0;
ALTER TABLE edges ADD COLUMN lineage_actor TEXT    NOT NULL DEFAULT '';
SQL
")
rc="${res%%|*}"; msg="${res#*|}"
check "a reversed pair still stamps, because UPDATE ignores column order" "0" "$rc"
if [ -z "$msg" ]; then
    ok "a successful stamp says nothing"
else
    bad "a successful stamp says nothing" "stderr: [${msg:0:220}]"
fi

# ── the caller's retry promise is conditional on the status ───────────────────
#
# The three-valued status only helps if the caller branches on it, and the
# promise itself lives there rather than in wv_lineage_stamp. Driving
# _wv_emit_deltas end to end needs a staging dir and a watermark it has no
# stable way to hand back, so the branch is pinned structurally: without this,
# "a permanent fault never promises a retry" passes vacuously above, because the
# stamp's own stderr never contained that sentence in the first place.

# shellcheck disable=SC2016  # the pattern matches literal $ in the source text it reads
caller_block=$(sed -n '/wv_lineage_stamp "\$db"/,/^    fi$/p' "$ROOT/scripts/cmd/wv-cmd-data.sh")
if [ -z "$caller_block" ]; then
    bad "the stamp call site was located in wv-cmd-data.sh" "sed range matched nothing — did the call move?"
else
    ok "the stamp call site was located in wv-cmd-data.sh"
    check "the call site branches on the permanent status" \
        "yes" "$(grep -qE '\-eq 2' <<<"$caller_block" && echo yes || echo no)"
    check "the retry promise survives for the transient arm" \
        "yes" "$(grep -q 'will retry next sync' <<<"$caller_block" && echo yes || echo no)"
    check "the permanent arm says a retry cannot succeed" \
        "yes" "$(grep -q 'cannot succeed until' <<<"$caller_block" && echo yes || echo no)"
fi

echo ""
echo "  $pass/$run passed"
[ "$pass" -eq "$run" ]
