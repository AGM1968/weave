#!/usr/bin/env bash
# Suite-driven wv calls are tagged test so call-stats retro reads can exclude them.
export WV_CALL_SOURCE=test
# A load that drops live nodes must name them.
#
# wv load replaces the live database with state.sql and replays deltas. A node
# that was live beforehand and appears in neither is gone, and nothing said so:
# every guard around the replace is an AGGREGATE count -- a >50% node-count
# drop, or fewer 'done' rows than before -- so losing a handful of nodes clears
# all of them and the load reports routine progress (wv-061f1f). That is the
# shape of the cross-harness clobber in wv-b767ff, where a stale hot zone
# re-dumped a smaller graph over a larger committed one and the telltale was a
# routine 'Skipped N pre-prune delta(s)' line.
#
# The fixture exports WV_DB, which sets WV_DB_CUSTOM and disables auto_sync and
# delta emission. That is not a convenience: it is precisely the condition under
# test, a live node carrying no durable delta, and it also stops cmd_load's
# pre-flight flush from quietly rescuing the node before the diff can see it.
#
# Isolation note: wv-config.sh treats a WV_HOT_ZONE that does not match
# REPO_ROOT as a leaked override and refuses to run (wv-5e804e), so the fixture runs
# with its own directory as cwd.
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

echo "load names silently dropped nodes"

TEST_DIR=$(mktemp -d /tmp/wv-load-drop-XXXXXX)
trap 'rm -rf "$TEST_DIR"' EXIT

export WEAVE_DIR="$TEST_DIR/.weave"
export WV_HOT_ZONE="$TEST_DIR/hot"
export WV_DB="$TEST_DIR/hot/brain.db"
export WV_CONFIG_DIR="$TEST_DIR/config"
export WV_AUTO_CHECKPOINT=0
mkdir -p "$WEAVE_DIR" "$WV_CONFIG_DIR" "$TEST_DIR/hot"
cd "$TEST_DIR" || exit 1

keep_a=$("$WV" add "load drop keeper a" 2>/dev/null | grep -oE '^wv-[0-9a-f]+$' | tail -1)
keep_b=$("$WV" add "load drop keeper b" 2>/dev/null | grep -oE '^wv-[0-9a-f]+$' | tail -1)
if [ -z "$keep_a" ] || [ -z "$keep_b" ] || [ ! -f "$WV_DB" ]; then
    bad "isolated graph created" "a=[$keep_a] b=[$keep_b]"
    echo ""; echo "  $pass/$run passed"; exit 1
fi
ok "isolated graph created"

# Freeze state.sql while only the keepers exist. cmd_load imports this with
# sqlite3, so a plain dump is a faithful stand-in for the selective one.
sqlite3 "$WV_DB" ".dump" > "$WEAVE_DIR/state.sql" 2>/dev/null
# Counted per keeper with a literal pattern: a variable regex here would need
# an option barrier it cannot carry, which tests/test-assert-helper-safety.sh
# enforces across tests and production shell alike.
keepers_in_state=0
for _k in "$keep_a" "$keep_b"; do
    grep -qF -- "$_k" "$WEAVE_DIR/state.sql" 2>/dev/null && keepers_in_state=$((keepers_in_state + 1))
done
check "state.sql captured the keepers" "2" "$keepers_in_state"

# Now add a node that exists ONLY live: no sync, no delta, no tombstone.
doomed=$("$WV" add "live only, no durable delta" 2>/dev/null | grep -oE '^wv-[0-9a-f]+$' | tail -1)
if [ -z "$doomed" ]; then
    bad "live-only node created" "wv add produced no id"
    echo ""; echo "  $pass/$run passed"; exit 1
fi
ok "live-only node created ($doomed)"

check "the live-only node is absent from state.sql" \
    "0" "$(grep -cF -- "$doomed" "$WEAVE_DIR/state.sql" 2>/dev/null)"
check "no delta file carries it" \
    "0" "$(grep -rlF -- "$doomed" "$WEAVE_DIR/deltas" 2>/dev/null | grep -c .)"

# ── the load ──────────────────────────────────────────────────────────────────

load_err=$("$WV" load 2>&1 >/dev/null)

check "the node really was dropped" \
    "0" "$(sqlite3 "$WV_DB" "SELECT COUNT(*) FROM nodes WHERE id='$doomed';" 2>/dev/null || echo -1)"
check "the keepers survived" \
    "2" "$(sqlite3 "$WV_DB" "SELECT COUNT(*) FROM nodes WHERE id IN ('$keep_a','$keep_b');" 2>/dev/null || echo -1)"

if grep -qF -- "$doomed" <<<"$load_err"; then
    ok "the dropped node is named by id"
else
    bad "the dropped node is named by id" "stderr: [${load_err:0:300}]"
fi
if grep -qE "neither state.sql nor any delta" <<<"$load_err"; then
    ok "the line says what it means"
else
    bad "the line says what it means" "stderr: [${load_err:0:300}]"
fi
if grep -q "git log -S" <<<"$load_err"; then
    ok "the line names how to recover the id from git"
else
    bad "the line names how to recover the id from git" "stderr: [${load_err:0:300}]"
fi

# Criterion 3: distinguishable from the routine counts. The marker carries this,
# not the colour: wv-config.sh blanks RED/YELLOW when the stream is not a
# terminal, so asserting on ANSI codes would test the capture rather than the
# output, and would pass or fail depending on how the suite was invoked. The
# routine skip lines are 'ℹ'; this one is '✗'.
header_line=$(grep -E "neither state.sql nor any delta" <<<"$load_err" | sed -n 1p)
if grep -q "✗" <<<"$header_line"; then
    ok "the drop is marked as a failure, not as another informational count"
else
    bad "the drop is marked as a failure, not as another informational count" "line: [${header_line:0:200}]"
fi
if grep -q "ℹ" <<<"$header_line"; then
    bad "the drop line is not one of the routine skip counters" "line: [${header_line:0:200}]"
else
    ok "the drop line is not one of the routine skip counters"
fi

# ── a load that drops nothing stays quiet ─────────────────────────────────────

quiet_err=$("$WV" load 2>&1 >/dev/null)
if grep -qE "neither state.sql nor any delta" <<<"$quiet_err"; then
    bad "a load with no drops says nothing about drops" "stderr: [${quiet_err:0:220}]"
else
    ok "a load with no drops says nothing about drops"
fi

# ── the snapshot copy does not outlive the load ───────────────────────────────

leftovers=$(find "$WV_HOT_ZONE" -maxdepth 1 -name '.preload.db.*' 2>/dev/null | grep -c .)
check "the pre-load snapshot is cleaned up" "0" "$leftovers"

echo ""
echo "  $pass/$run passed"
[ "$pass" -eq "$run" ]
