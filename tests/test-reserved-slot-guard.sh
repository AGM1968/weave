#!/usr/bin/env bash
# Suite-driven wv calls are tagged test so call-stats retro reads can exclude them.
export WV_CALL_SOURCE=test
# A reserved node must not be claimable as ordinary work.
#
# A reservation marks a node as the measured task for a counted capture: fixing
# it outside that capture consumes the slot and cannot be undone. wv-5850d4 was
# consumed exactly that way on 2026-08-17. Three nodes carried the warning in
# metadata -- e5_reserved, plus a reservation_note spelling out the consequence
# -- and NOTHING in scripts/ or .claude/hooks/ read either field. Two of them sat
# in wv ready looking like ordinary trivial CLI fixes (wv-0060db).
#
# What this pins:
#   - reserved nodes are absent from wv ready, and ready SAYS how many it hid
#   - --all still shows them, so a reservation hides work without losing it
#   - wv work refuses, and prints the node's own reservation note
#   - --force does NOT bypass, because --force is the routine way to take a node
#     another agent claimed; if it also cleared reservations the guard would be
#     off in precisely the situation it exists for
#   - an explicit override claims it, and says out loud that the slot is spent
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

echo "reserved counted-capture slot guard"

TEST_DIR=$(mktemp -d /tmp/wv-reserved-XXXXXX)
trap 'rm -rf "$TEST_DIR"' EXIT

export WEAVE_DIR="$TEST_DIR/.weave"
export WV_HOT_ZONE="$TEST_DIR/hot"
export WV_DB="$TEST_DIR/hot/brain.db"
export WV_CONFIG_DIR="$TEST_DIR/config"
export WV_AUTO_CHECKPOINT=0
mkdir -p "$WEAVE_DIR" "$WV_CONFIG_DIR" "$TEST_DIR/hot"
cd "$TEST_DIR" || exit 1

ordinary=$("$WV" add "an ordinary claimable task" --standalone --criteria="c1" 2>/dev/null | grep -oE '^wv-[0-9a-f]+$' | tail -1)
reserved=$("$WV" add "looks like a trivial CLI fix" --standalone --criteria="c1" 2>/dev/null | grep -oE '^wv-[0-9a-f]+$' | tail -1)
if [ -z "$ordinary" ] || [ -z "$reserved" ]; then
    bad "fixture nodes created" "ordinary=[$ordinary] reserved=[$reserved]"
    echo ""; echo "  $pass/$run passed"; exit 1
fi
ok "fixture nodes created"

NOTE="RESERVED as the e5-cXX measured task. Do not fix as ordinary work."
"$WV" update "$reserved" --metadata="{\"e5_reserved\":true,\"e5_slot\":\"e5-cXX\",\"reservation_note\":\"$NOTE\"}" >/dev/null 2>&1
check "the reservation is recorded" "true" \
    "$(sqlite3 "$WV_DB" "SELECT json_extract(metadata,'\$.e5_reserved') FROM nodes WHERE id='$reserved';" 2>/dev/null | sed 's/^1$/true/')"

# ── wv ready ──────────────────────────────────────────────────────────────────

ready_ids=$("$WV" ready --json 2>/dev/null | grep -oE 'wv-[0-9a-f]+' | sort -u)
if grep -qF -- "$ordinary" <<<"$ready_ids"; then
    ok "an ordinary node is offered by wv ready"
else
    bad "an ordinary node is offered by wv ready" "ready had: $(tr '\n' ' ' <<<"$ready_ids")"
fi
if grep -qF -- "$reserved" <<<"$ready_ids"; then
    bad "a reserved node is NOT offered by wv ready" "reserved node was listed"
else
    ok "a reserved node is NOT offered by wv ready"
fi

ready_text=$("$WV" ready 2>&1)
if grep -qE "reserved node\(s\) hidden" <<<"$ready_text"; then
    ok "wv ready says how many reserved nodes it hid"
else
    bad "wv ready says how many reserved nodes it hid" "output: [${ready_text:0:200}]"
fi

all_ids=$("$WV" ready --all --json 2>/dev/null | grep -oE 'wv-[0-9a-f]+' | sort -u)
if grep -qF -- "$reserved" <<<"$all_ids"; then
    ok "--all still shows it, so the reservation hides work without losing it"
else
    bad "--all still shows it, so the reservation hides work without losing it" "not in --all"
fi

# ── wv work ───────────────────────────────────────────────────────────────────

deny=$("$WV" work "$reserved" 2>&1 >/dev/null); deny_rc=$?
check "wv work refuses a reserved node" "1" "$deny_rc"
if grep -q "RESERVED" <<<"$deny"; then
    ok "the refusal names the reservation"
else
    bad "the refusal names the reservation" "stderr: [${deny:0:200}]"
fi
if grep -qF -- "Do not fix as ordinary work" <<<"$deny"; then
    ok "the refusal prints the node's OWN reservation note"
else
    bad "the refusal prints the node's OWN reservation note" "stderr: [${deny:0:200}]"
fi
check "the reserved node was not claimed" "" \
    "$(sqlite3 "$WV_DB" "SELECT COALESCE(json_extract(metadata,'\$.claimed_by'),'') FROM nodes WHERE id='$reserved';" 2>/dev/null)"

# --force is the routine way to take another agent's claim. It must not also
# clear a reservation, or the guard is absent exactly when it is needed.
force_deny=$("$WV" work "$reserved" --force 2>&1 >/dev/null); force_rc=$?
check "--force does NOT bypass the reservation" "1" "$force_rc"
check "the reserved node is still unclaimed after --force" "" \
    "$(sqlite3 "$WV_DB" "SELECT COALESCE(json_extract(metadata,'\$.claimed_by'),'') FROM nodes WHERE id='$reserved';" 2>/dev/null)"

# ── the explicit override ─────────────────────────────────────────────────────

allow=$(WV_ALLOW_RESERVED=1 "$WV" work "$reserved" 2>&1 >/dev/null); allow_rc=$?
check "an explicit override claims it" "0" "$allow_rc"
if grep -q "consumes its capture slot" <<<"$allow"; then
    ok "the override says out loud that the slot is being spent"
else
    bad "the override says out loud that the slot is being spent" "stderr: [${allow:0:200}]"
fi
if [ -n "$(sqlite3 "$WV_DB" "SELECT COALESCE(json_extract(metadata,'\$.claimed_by'),'') FROM nodes WHERE id='$reserved';" 2>/dev/null)" ]; then
    ok "the node is claimed under the override"
else
    bad "the node is claimed under the override" "claimed_by still empty"
fi

# ── the generic marker works too, not just the E5-specific one ────────────────

generic=$("$WV" add "reserved by the generic flag" --standalone --criteria="c1" 2>/dev/null | grep -oE '^wv-[0-9a-f]+$' | tail -1)
"$WV" update "$generic" --metadata='{"reserved":true}' >/dev/null 2>&1
generic_rc=0
"$WV" work "$generic" >/dev/null 2>&1 || generic_rc=$?
check "a generic 'reserved' marker is honoured, not only e5_reserved" "1" "$generic_rc"

echo ""
echo "  $pass/$run passed"
[ "$pass" -eq "$run" ]
