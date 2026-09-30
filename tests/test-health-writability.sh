#!/usr/bin/env bash
# Suite-driven wv calls are tagged test so call-stats retro reads can exclude them.
export WV_CALL_SOURCE=test
# Session start must probe whether the graph can be WRITTEN, not only its shape.
#
# Every input to the health score describes shape — node and edge counts,
# orphans, ghost edges — and none of it moves when the writer-lineage schema
# drifts. A hot zone that wv sync and wv commit-refs cannot persist to therefore
# scored 100/100, and the session-start hook printed that number at the top of
# every session (wv-71d076). The verdict comes from db_lineage_pair_verdict, the
# same classifier wv doctor uses.
#
# The drift is injected by reversing the lineage column order on edges, which is
# deliberately the UNREPAIRABLE shape: ALTER TABLE can only append, so db_ensure
# cannot quietly repair it between the injection and the probe. A repairable
# shape would be auto-migrated and the assertion would pass for the wrong
# reason — it would be testing the migration, not the probe.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WV="$ROOT/scripts/wv"

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
run=0; pass=0
ok() { run=$((run+1)); pass=$((pass+1)); echo -e "  ${GREEN}✓${NC} $1"; }
bad() { run=$((run+1)); echo -e "  ${RED}✗${NC} $1"; [ -n "${2:-}" ] && echo "      $2"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2], got [$3]"; fi; }

echo "health writability probe"

TEST_DIR=$(mktemp -d /tmp/wv-health-write-XXXXXX)
trap 'rm -rf "$TEST_DIR"' EXIT

export WEAVE_DIR="$TEST_DIR/.weave"
export WV_HOT_ZONE="$TEST_DIR/hot"
export WV_CONFIG_DIR="$TEST_DIR/config"; mkdir -p "$WV_CONFIG_DIR"
export WV_AUTO_CHECKPOINT=0
mkdir -p "$WEAVE_DIR"
cd "$TEST_DIR" || exit 1

"$WV" add "health probe node" >/dev/null 2>&1
DB="$WV_HOT_ZONE/brain.db"
CACHE="$WV_HOT_ZONE/.health_fast.json"

if [ ! -f "$DB" ]; then
    bad "isolated graph created" "no database at $DB"
    echo ""; echo "  $pass/$run passed"; exit 1
fi
ok "isolated graph created"

# ── canonical: the probe records its verdict and changes nothing else ──────────

rm -f "$CACHE"
healthy=$("$WV" health --fast --json 2>/dev/null)
check "canonical graph records its lineage verdict" \
    "canonical" "$(jq -r '.lineage // "missing"' <<<"$healthy")"
check "canonical graph carries no recovery key" \
    "" "$(jq -r '.recovery // ""' <<<"$healthy")"
healthy_score=$(jq -r '.score' <<<"$healthy")
if [ "${healthy_score:-0}" -gt 0 ]; then
    ok "canonical graph keeps its shape score ($healthy_score/100)"
else
    bad "canonical graph keeps its shape score" "scored $healthy_score"
fi

# ── the cache is now warm and says the graph is healthy ───────────────────────

if [ -f "$CACHE" ]; then
    ok "fast cache was written"
else
    bad "fast cache was written" "no file at $CACHE"
fi

# Reverse the lineage column order on edges: ALTER TABLE appends only, so this
# shape is unreachable by repair and db_ensure cannot mask it.
sqlite3 "$DB" "
    ALTER TABLE edges RENAME COLUMN lineage_actor TO la_x;
    ALTER TABLE edges RENAME COLUMN lineage_seq   TO ls_x;
    ALTER TABLE edges ADD COLUMN lineage_seq   INTEGER NOT NULL DEFAULT 0;
    ALTER TABLE edges ADD COLUMN lineage_actor TEXT    NOT NULL DEFAULT '';
" 2>/dev/null
shape=$(sqlite3 "$DB" "SELECT group_concat(name) FROM (SELECT name FROM pragma_table_info('edges') WHERE name IN ('lineage_actor','lineage_seq') ORDER BY cid);" 2>/dev/null)
check "edges lineage order is reversed by the fixture" "lineage_seq,lineage_actor" "$shape"

# ── the stale-cache case, which is the whole point ────────────────────────────
#
# No wv command ran between the warm cache and the drift, so the run-cache write
# sentinel is untouched and the TTL has not expired. Everything the cache keys
# on says "still fresh". Only the recorded verdict differs.

drifted=$("$WV" health --fast --json 2>/dev/null)
check "a drifted graph is not served a stale cached score" \
    "0" "$(jq -r '.score' <<<"$drifted")"
check "the drifted verdict is reported" \
    "unrepairable" "$(jq -r '.lineage // "missing"' <<<"$drifted")"
if [ -n "$(jq -r '.recovery // ""' <<<"$drifted")" ]; then
    ok "the drifted result carries a recovery command"
else
    bad "the drifted result carries a recovery command" "recovery key absent"
fi

# ── the human-readable path says the same thing ───────────────────────────────

text_out=$("$WV" health --fast 2>&1)
# Anchored on purpose: a bare "0/100" is a substring of "100/100", so the
# unanchored form passes against the very output it is meant to reject.
if grep -qE "Health: 0/100" <<<"$text_out"; then
    ok "text output reports the floored score"
else
    bad "text output reports the floored score" "output was: [${text_out:0:160}]"
fi
if grep -q "not writable" <<<"$text_out"; then
    ok "text output names the graph as not writable"
else
    bad "text output names the graph as not writable" "output was: [${text_out:0:160}]"
fi
if grep -q "wv load" <<<"$text_out"; then
    ok "text output names the recovery command"
else
    bad "text output names the recovery command" "output was: [${text_out:0:160}]"
fi

# ── a cache written before the probe existed must not be trusted ──────────────
#
# On the first run after a CLI upgrade the cached payload has no .lineage at all.
# Treating a missing key as "matches" would serve the pre-upgrade score for the
# whole TTL, which is the same stale reassurance one version later.

jq 'del(.lineage) | del(.recovery) | .score = 100' <<<"$drifted" > "$CACHE"
upgraded=$("$WV" health --fast --json 2>/dev/null)
check "a cache with no recorded verdict is recomputed, not served" \
    "0" "$(jq -r '.score' <<<"$upgraded")"

echo ""
echo "  $pass/$run passed"
[ "$pass" -eq "$run" ]
