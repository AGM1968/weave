#!/usr/bin/env bash
# Suite-driven wv calls are tagged test so call-stats retro reads can exclude them.
export WV_CALL_SOURCE=test
# A mutation that failed to persist must not be reported as a success.
#
# wv-498660 stopped the call sites discarding auto_sync's failure, but a warning
# printed underneath a "✓ Closed" line still reads as success, and the success
# line is what an agent parses. wv done closed the node in the hot-zone DB,
# printed its closure, closed the GitHub issue, and returned 0 whether or not
# the closure ever reached state.sql — so the node read done in that session and
# unchanged in every other clone, with a zero exit status asserting otherwise.
#
# The gate is persist_or_refuse: it runs after the last mutation and before the
# first success line, and returns non-zero. What this suite pins is the
# user-visible surface of a refusal, not the internals:
#
#   - a non-zero exit status, so a caller in a pipeline notices
#   - NOT PERSISTED named explicitly on stderr
#   - NO success line, which is the part a warning alone never fixed
#
# The failure is injected by making WEAVE_DIR unwritable, so auto_sync cannot
# create the temp file it writes state.sql through. That is a real auto_sync
# failure rather than a stubbed one.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WV="$ROOT/scripts/wv"

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
run=0; pass=0
ok() { run=$((run+1)); pass=$((pass+1)); echo -e "  ${GREEN}✓${NC} $1"; }
bad() { run=$((run+1)); echo -e "  ${RED}✗${NC} $1"; [ -n "${2:-}" ] && echo "      $2"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2], got [$3]"; fi; }

echo "durability refusal surface"

if [ "$(id -u)" = "0" ]; then
    echo "  (skipped: running as root, chmod cannot deny writes)"
    echo ""
    echo "  0/0 passed"
    exit 0
fi

TEST_DIR=$(mktemp -d /tmp/wv-refusal-XXXXXX)
cleanup() { chmod -R u+w "$TEST_DIR" 2>/dev/null || true; rm -rf "$TEST_DIR"; }
trap cleanup EXIT

export WEAVE_DIR="$TEST_DIR/.weave"
export WV_HOT_ZONE="$TEST_DIR/hot"
export WV_CONFIG_DIR="$TEST_DIR/config"; mkdir -p "$WV_CONFIG_DIR"
export WV_AUTO_SYNC=1
export WV_AUTO_CHECKPOINT=0
mkdir -p "$WEAVE_DIR"
cd "$TEST_DIR" || exit 1

deny_writes()  { rm -f "$WV_HOT_ZONE/.last_sync"; chmod 500 "$WEAVE_DIR"; }
allow_writes() { chmod 700 "$WEAVE_DIR"; }

# ── baseline: the same commands succeed when persistence works ─────────────────

base_id=$("$WV" add "refusal baseline" 2>/dev/null | grep -oE '^wv-[0-9a-f]+$' | tail -1)
if [ -n "$base_id" ]; then
    ok "wv add succeeds and prints an id when persistence works ($base_id)"
else
    bad "wv add succeeds and prints an id when persistence works" "no id on stdout"
fi

base_out=$("$WV" "done" "$base_id" --skip-verification 2>/dev/null)
base_rc=$?
check "wv done exits zero when persistence works" "0" "$base_rc"
if grep -q "Closed" <<<"$base_out"; then
    ok "wv done prints its closure when persistence works"
else
    bad "wv done prints its closure when persistence works" "stdout was: [${base_out:0:120}]"
fi

# ── wv add refuses ─────────────────────────────────────────────────────────────

allow_writes
probe_id=$("$WV" add "refusal probe" 2>/dev/null | grep -oE '^wv-[0-9a-f]+$' | tail -1)

deny_writes
add_out=$("$WV" add "unpersistable node" 2>"$TEST_DIR/add.err")
add_rc=$?
add_err=$(cat "$TEST_DIR/add.err")

check "wv add exits non-zero when its persist fails" "1" "$add_rc"
if grep -q "NOT PERSISTED" <<<"$add_err"; then
    ok "wv add names NOT PERSISTED on stderr"
else
    bad "wv add names NOT PERSISTED on stderr" "stderr was: [${add_err:0:200}]"
fi
if grep -qE '✓ wv-[0-9a-f]+' <<<"$add_err"; then
    bad "wv add prints no creation line when its persist fails" "stderr claimed success: [${add_err:0:200}]"
else
    ok "wv add prints no creation line when its persist fails"
fi
if [ -z "$add_out" ]; then
    ok "wv add prints no id on stdout when its persist fails"
else
    bad "wv add prints no id on stdout when its persist fails" "stdout was: [$add_out]"
fi

# ── wv done refuses ────────────────────────────────────────────────────────────

deny_writes
done_out=$("$WV" "done" "$probe_id" --skip-verification 2>"$TEST_DIR/done.err")
done_rc=$?
done_err=$(cat "$TEST_DIR/done.err")

check "wv done exits non-zero when its persist fails" "1" "$done_rc"
if grep -q "NOT PERSISTED" <<<"$done_err"; then
    ok "wv done names NOT PERSISTED on stderr"
else
    bad "wv done names NOT PERSISTED on stderr" "stderr was: [${done_err:0:200}]"
fi
if grep -q "Closed" <<<"$done_out$done_err"; then
    bad "wv done prints no closure line when its persist fails" "output claimed success: [${done_out:0:120}]"
else
    ok "wv done prints no closure line when its persist fails"
fi

# The refusal must say where the change still is. An operator who reads "NOT
# PERSISTED" and assumes the work is gone will redo it on top of a hot zone that
# already has it.
if grep -qE "hot-zone database|wv sync" <<<"$done_err"; then
    ok "the refusal says where the change still is and how to retry"
else
    bad "the refusal says where the change still is and how to retry" "stderr was: [${done_err:0:200}]"
fi

allow_writes

echo ""
echo "  $pass/$run passed"
[ "$pass" -eq "$run" ]
