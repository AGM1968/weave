#!/usr/bin/env bash
# Suite-driven wv calls are tagged test so call-stats retro reads can exclude them.
export WV_CALL_SOURCE=test
# The edge-type enum rebuild must not strip the writer-lineage pair.
#
# db_migrate_edge_type_enum cannot ALTER a CHECK constraint, so it rebuilds
# edges from a hardcoded CREATE TABLE carrying only the six columns db_init
# declares. lineage_actor and lineage_seq are not among them — db_migrate_lineage
# appends them with ALTER TABLE — so on a database predating the resolves CHECK
# but already lineage-migrated, the rebuild dropped both and left the pair
# verdict at 'repairable', where sync and commit-refs cannot persist (wv-419ba1).
#
# Nothing repaired it inside that process: db_ensure runs db_migrate_lineage
# BEFORE the enum migration, and the pre-v1.2 hot-zone migration call site never
# runs it at all. A LATER db_ensure does repair it, which is why this is latent
# and why a full CLI invocation looks clean — wv calls db_ensure more than once
# per process. This suite therefore drives ONE db_ensure directly. Going through
# the wv binary would pass against the unfixed code.
#
# Isolation note: wv-config.sh treats a WV_HOT_ZONE that does not match
# REPO_ROOT as a leaked override and refuses to run (wv-5e804e), so the sourced helpers
# must run with the fixture directory as cwd. Sourcing them from inside the
# weave checkout points every assertion at the live graph instead.
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

echo "edge enum rebuild preserves writer lineage"

TEST_DIR=$(mktemp -d /tmp/wv-edge-enum-XXXXXX)
trap 'rm -rf "$TEST_DIR"' EXIT

export WEAVE_DIR="$TEST_DIR/.weave"
export WV_HOT_ZONE="$TEST_DIR/hot"
export WV_DB="$TEST_DIR/hot/brain.db"
export WV_CONFIG_DIR="$TEST_DIR/config"
export WV_AUTO_SYNC=0
export WV_AUTO_CHECKPOINT=0
mkdir -p "$WEAVE_DIR" "$WV_CONFIG_DIR" "$TEST_DIR/hot"
cd "$TEST_DIR" || exit 1

a=$("$WV" add "edge enum node a" 2>/dev/null | grep -oE '^wv-[0-9a-f]+$' | tail -1)
b=$("$WV" add "edge enum node b" 2>/dev/null | grep -oE '^wv-[0-9a-f]+$' | tail -1)
if [ -z "$a" ] || [ -z "$b" ] || [ ! -f "$WV_DB" ]; then
    bad "isolated graph created" "a=[$a] b=[$b] db=$WV_DB"
    echo ""; echo "  $pass/$run passed"; exit 1
fi
ok "isolated graph created"

# Rebuild edges as a pre-resolves table that IS lineage-migrated, then seed one
# edge carrying real lineage values. This is the state a database upgraded
# across the lineage migration but not across the resolves CHECK is in.
sqlite3 "$WV_DB" <<SQL 2>/dev/null
PRAGMA foreign_keys = OFF;
BEGIN;
DROP TABLE IF EXISTS edges;
CREATE TABLE edges (
    source TEXT NOT NULL,
    target TEXT NOT NULL,
    type TEXT NOT NULL CHECK(type IN ('blocks', 'relates_to', 'implements', 'contradicts', 'supersedes', 'references', 'obsoletes', 'addresses')),
    weight REAL DEFAULT 1.0,
    context JSON DEFAULT '{}',
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    lineage_actor TEXT NOT NULL DEFAULT '' CHECK(typeof(lineage_actor) = 'text'),
    lineage_seq INTEGER NOT NULL DEFAULT 0 CHECK(typeof(lineage_seq) = 'integer'),
    PRIMARY KEY(source, target, type)
);
INSERT INTO edges (source, target, type, lineage_actor, lineage_seq)
VALUES ('$a', '$b', 'relates_to', 'legacy-actor', 7);
COMMIT;
SQL

fixture_shape=$(sqlite3 "$WV_DB" "SELECT COALESCE(group_concat(name),'') FROM (SELECT name FROM pragma_table_info('edges') WHERE name IN ('lineage_actor','lineage_seq') ORDER BY cid);" 2>/dev/null)
check "fixture edges carry a canonical lineage pair" "lineage_actor,lineage_seq" "$fixture_shape"
check "fixture edges predate the resolves CHECK" \
    "0" "$(sqlite3 "$WV_DB" "SELECT sql LIKE '%resolves%' FROM sqlite_master WHERE type='table' AND name='edges';" 2>/dev/null)"
check "fixture edge carries lineage values" \
    "legacy-actor/7" "$(sqlite3 "$WV_DB" "SELECT lineage_actor || '/' || lineage_seq FROM edges;" 2>/dev/null)"

# ── one db_ensure, driven directly ────────────────────────────────────────────

# WEAVE_DIR/WV_HOT_ZONE/WV_DB/WV_CONFIG_DIR are already exported above, so the
# child inherits them; re-stating them as a prefix assignment would not reach
# the expansions inside this string anyway (SC2097/SC2098).
result=$(cd "$TEST_DIR" && bash -c "
source '$ROOT/scripts/lib/wv-config.sh' 2>/dev/null
source '$ROOT/scripts/lib/wv-db-lineage.sh' 2>/dev/null
source '$ROOT/scripts/lib/wv-db.sh' 2>/dev/null
# Guard the isolation itself: if the override was rejected this would silently
# assert against the developer's live graph and pass for the wrong reason.
[ \"\$WV_DB\" = '$WV_DB' ] || { echo 'ISOLATION-LOST'; exit 1; }
db_ensure >/dev/null 2>&1
printf '%s|%s|%s|%s' \
    \"\$(db_lineage_pair_verdict \"\$(db_lineage_shape nodes)\" \"\$(db_lineage_shape edges)\")\" \
    \"\$(sqlite3 \"\$WV_DB\" 'SELECT COALESCE(lineage_actor || \"/\" || lineage_seq, \"none\") FROM edges;' 2>/dev/null)\" \
    \"\$(sqlite3 \"\$WV_DB\" 'SELECT COUNT(*) FROM sqlite_master WHERE name = \"_wv_edges_lineage_carry\";' 2>/dev/null)\" \
    \"\$(sqlite3 \"\$WV_DB\" 'SELECT sql LIKE \"%resolves%\" FROM sqlite_master WHERE type = \"table\" AND name = \"edges\";' 2>/dev/null)\"
")

if [ "$result" = "ISOLATION-LOST" ]; then
    bad "fixture database is the one under test" "wv-config rejected the hot-zone override"
    echo ""; echo "  $pass/$run passed"; exit 1
fi
ok "fixture database is the one under test"

IFS='|' read -r verdict values carry resolves <<<"$result"

check "one db_ensure leaves a canonical pair verdict" "canonical" "$verdict"
check "the rebuild still widened the type CHECK" "1" "$resolves"
check "lineage values survive the rebuild" "legacy-actor/7" "$values"
check "the carry table is not left in the graph" "0" "$carry"

echo ""
echo "  $pass/$run passed"
[ "$pass" -eq "$run" ]
