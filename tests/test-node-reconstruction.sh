#!/usr/bin/env bash
# Suite-driven wv calls are tagged test so call-stats retro reads can exclude them.
export WV_CALL_SOURCE=test
# A pushed Weave-ID trailer must not be able to point at nothing.
#
# A commit trailer names a node id permanently: the commit is pushed and the
# trailer cannot be rewritten without rewriting history. If the node is later
# lost -- a delta that never persisted, a graph clobbered by a stale hot zone --
# the id in the trailer resolves to nothing and there was no way to put it back,
# because every creation path mints a fresh id (wv-0f1092).
#
# `wv add --id=<wv-id>` reconstructs under the lost id. The checks are the
# INVERSE of an ordinary add: the id must be a node id rather than an alias,
# because an alias is not reconstructible and validate_id would resolve one
# against a live row; and the id must NOT already exist, because overwriting a
# live node would turn a recovery into the second loss.
#
# Isolation note: wv-config.sh discards a WV_HOT_ZONE that does not match
# REPO_ROOT as a leaked override, so the fixture runs with its own cwd.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WV="$ROOT/scripts/wv"

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
run=0; pass=0
ok() { run=$((run+1)); pass=$((pass+1)); echo -e "  ${GREEN}✓${NC} $1"; }
bad() { run=$((run+1)); echo -e "  ${RED}✗${NC} $1"; [ -n "${2:-}" ] && echo "      $2"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2], got [$3]"; fi; }

echo "node reconstruction under a lost id"

TEST_DIR=$(mktemp -d /tmp/wv-reconstruct-XXXXXX)
trap 'rm -rf "$TEST_DIR"' EXIT

export WEAVE_DIR="$TEST_DIR/.weave"
export WV_HOT_ZONE="$TEST_DIR/hot"
export WV_DB="$TEST_DIR/hot/brain.db"
export WV_CONFIG_DIR="$TEST_DIR/config"
export WV_AUTO_CHECKPOINT=0
mkdir -p "$WEAVE_DIR" "$WV_CONFIG_DIR" "$TEST_DIR/hot"
cd "$TEST_DIR" || exit 1

live=$("$WV" add "a node that still exists" 2>/dev/null | grep -oE '^wv-[0-9a-f]+$' | tail -1)
if [ -z "$live" ]; then
    bad "isolated graph created" "wv add produced no id"
    echo ""; echo "  $pass/$run passed"; exit 1
fi
ok "isolated graph created"

# ── the worked example: the id wv-87ac0f, named by a trailer, absent here ─────

lost="wv-87ac0f"
check "the lost id is absent to begin with" \
    "0" "$(sqlite3 "$WV_DB" "SELECT COUNT(*) FROM nodes WHERE id='$lost';" 2>/dev/null)"

out=$("$WV" add "reconstructed from a pushed Weave-ID trailer" --id="$lost" --standalone 2>/dev/null)
rc=$?
check "reconstruction succeeds" "0" "$rc"
check "the node exists under the SAME id" \
    "1" "$(sqlite3 "$WV_DB" "SELECT COUNT(*) FROM nodes WHERE id='$lost';" 2>/dev/null)"
if grep -qF -- "$lost" <<<"$out"; then
    ok "the reconstructed id is echoed, not a fresh one"
else
    bad "the reconstructed id is echoed, not a fresh one" "stdout: [${out:0:120}]"
fi
check "the text is the one supplied" \
    "reconstructed from a pushed Weave-ID trailer" \
    "$(sqlite3 "$WV_DB" "SELECT text FROM nodes WHERE id='$lost';" 2>/dev/null)"

# ── it must refuse to overwrite a live id ─────────────────────────────────────

before_text=$(sqlite3 "$WV_DB" "SELECT text FROM nodes WHERE id='$live';" 2>/dev/null)
collide_err=$("$WV" add "should never land" --id="$live" --standalone 2>&1 >/dev/null)
collide_rc=$?
check "a colliding reconstruction is refused" "1" "$collide_rc"
check "the live node is untouched" "$before_text" \
    "$(sqlite3 "$WV_DB" "SELECT text FROM nodes WHERE id='$live';" 2>/dev/null)"
check "no second row was created" \
    "1" "$(sqlite3 "$WV_DB" "SELECT COUNT(*) FROM nodes WHERE id='$live';" 2>/dev/null)"
if grep -q "refusing to overwrite" <<<"$collide_err"; then
    ok "the refusal says why"
else
    bad "the refusal says why" "stderr: [${collide_err:0:200}]"
fi

# Re-reconstructing an id that was itself just reconstructed is also a collision:
# the point is that a LIVE id is not a lost one, however it got there.
repeat_rc=0
"$WV" add "second attempt" --id="$lost" --standalone >/dev/null 2>&1 || repeat_rc=$?
check "reconstructing an already-reconstructed id is refused" "1" "$repeat_rc"

# ── it must refuse an alias ───────────────────────────────────────────────────
#
# validate_id accepts an alias and resolves it against a live row, which is
# exactly wrong here: an alias cannot name a node the graph has lost.

alias_err=$("$WV" add "aliased" --id="some-alias-name" --standalone 2>&1 >/dev/null)
alias_rc=$?
check "an alias is refused as --id" "1" "$alias_rc"
if grep -q "not an alias" <<<"$alias_err"; then
    ok "the alias refusal names the reason"
else
    bad "the alias refusal names the reason" "stderr: [${alias_err:0:200}]"
fi

malformed_rc=0
"$WV" add "malformed" --id="wv-ZZZZZZ" --standalone >/dev/null 2>&1 || malformed_rc=$?
check "a malformed id is refused" "1" "$malformed_rc"

# ── an ordinary add is unaffected ─────────────────────────────────────────────

plain=$("$WV" add "ordinary add, fresh id" --standalone 2>/dev/null | grep -oE '^wv-[0-9a-f]+$' | tail -1)
if [ -n "$plain" ] && [ "$plain" != "$lost" ] && [ "$plain" != "$live" ]; then
    ok "an add without --id still mints a fresh id ($plain)"
else
    bad "an add without --id still mints a fresh id" "got [$plain]"
fi

echo ""
echo "  $pass/$run passed"
[ "$pass" -eq "$run" ]
