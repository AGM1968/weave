#!/usr/bin/env bash
# Suite-driven wv calls are tagged test so call-stats retro reads can exclude them.
export WV_CALL_SOURCE=test
# auto_sync failures must never be discarded at the call site.
#
# Twelve of the fourteen auto_sync call sites used to spell
# `auto_sync 2>/dev/null || true`, which threw away BOTH the diagnostics
# auto_sync writes to stderr and its exit status. A mutation that never reached
# state.sql was then indistinguishable from one that did — the shape of the
# consumer loss report (wv-87ac0f), where a node read done in one session and
# todo everywhere else with nothing on any terminal to say why.
#
# Two contracts are pinned here:
#
#   structural — every auto_sync invocation in scripts/ is either
#     `auto_sync_or_warn ...` (non-fatal: warn, keep going) or
#     `if ! auto_sync ...` (durability-critical: abort). Nothing may redirect
#     its stderr or `|| true` its status. This is what stops a new call site
#     from quietly reintroducing the pattern, which no behavioural test can do.
#
#   behavioural — when auto_sync actually fails, the operator sees a warning.
#     The failure is injected by making WEAVE_DIR unwritable, so auto_sync
#     cannot create its state.sql temp file.
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

echo "auto_sync failure visibility"

# ── structural pin ─────────────────────────────────────────────────────────────

# Invocations only. The filter is deliberately shape-blind: it keeps EVERY
# non-comment line that still mentions auto_sync after comments are stripped,
# rather than matching the shapes we expect. A locator that only recognises the
# good forms would skip a bad new call site instead of failing on it — the old
# `auto_sync 2>/dev/null || true` spelling was invisible to exactly that regex.
# Excluded: `name() {` definition lines, and the two wrappers' own inner calls,
# which are the only places auto_sync is invoked without a guard. That exclusion
# is bounded below — a third `auto_sync "$@"` outside the known wrappers fails
# the count check, so the escape hatch cannot be widened by copying the line.
mapfile -t invocations < <(
    grep -rn '\bauto_sync' "$ROOT/scripts" --include='*.sh' \
        | sed 's/[[:space:]]#.*$//' \
        | grep -vE ':[0-9]+:[[:space:]]*#' \
        | grep -E '\bauto_sync' \
        | grep -vE '\bauto_sync(_or_warn)?\(\)|\bpersist_or_refuse\(\)' \
        | grep -vE '\bauto_sync "\$@"'
)

raw_passthrough=$(grep -rc '^[[:space:]]*auto_sync "\$@"' "$ROOT/scripts/cmd/wv-cmd-data.sh")
check "exactly two guarded wrappers invoke auto_sync directly" "2" "$raw_passthrough"

if [ "${#invocations[@]}" -eq 0 ]; then
    bad "auto_sync call sites located" "grep matched nothing — did auto_sync move or get renamed?"
else
    ok "auto_sync call sites located (${#invocations[@]} found)"
fi

offenders=()
unguarded=()
for line in "${invocations[@]}"; do
    body="${line#*:*:}"
    # stderr must reach the terminal, and the status must not be thrown away
    if grep -qE '2>[[:space:]]*(/dev/null|&1)|\|\|[[:space:]]*true' <<<"$body"; then
        offenders+=("$line")
        continue
    fi
    # and the status must be handled by one of the three permitted forms
    if ! grep -qE '\bauto_sync_or_warn\b|\bpersist_or_refuse\b|if[[:space:]]+![[:space:]]+auto_sync\b' <<<"$body"; then
        unguarded+=("$line")
    fi
done

if [ "${#offenders[@]}" -eq 0 ]; then
    ok "no call site discards auto_sync stderr or exit status"
else
    bad "no call site discards auto_sync stderr or exit status" \
        "$(printf '%s\n      ' "${offenders[@]}")"
fi

if [ "${#unguarded[@]}" -eq 0 ]; then
    ok "every call site uses auto_sync_or_warn, persist_or_refuse or 'if ! auto_sync'"
else
    bad "every call site uses auto_sync_or_warn, persist_or_refuse or 'if ! auto_sync'" \
        "$(printf '%s\n      ' "${unguarded[@]}")"
fi

# The wrapper is only honest if it cannot itself be silenced.
wrapper=$(sed -n '/^auto_sync_or_warn() {/,/^}/p' "$ROOT/scripts/cmd/wv-cmd-data.sh")
if [ -z "$wrapper" ]; then
    bad "auto_sync_or_warn is defined in wv-cmd-data.sh" "function not found"
else
    ok "auto_sync_or_warn is defined in wv-cmd-data.sh"
    check "auto_sync_or_warn writes its warning to stderr" \
        "yes" "$(grep -qE '>&2' <<<"$wrapper" && echo yes || echo no)"
    check "auto_sync_or_warn does not abort its caller" \
        "yes" "$(grep -qE '^[[:space:]]*return 0[[:space:]]*$' <<<"$wrapper" && echo yes || echo no)"
fi

# The gate is the opposite contract: it must abort, or a caller that trusts it
# prints its success line anyway.
gate=$(sed -n '/^persist_or_refuse() {/,/^}/p' "$ROOT/scripts/cmd/wv-cmd-data.sh")
if [ -z "$gate" ]; then
    bad "persist_or_refuse is defined in wv-cmd-data.sh" "function not found"
else
    ok "persist_or_refuse is defined in wv-cmd-data.sh"
    check "persist_or_refuse writes its refusal to stderr" \
        "yes" "$(grep -qE '>&2' <<<"$gate" && echo yes || echo no)"
    check "persist_or_refuse aborts its caller" \
        "yes" "$(grep -qE '^[[:space:]]*return 1[[:space:]]*$' <<<"$gate" && echo yes || echo no)"
fi

# ── behavioural: a real auto_sync failure is not silent ────────────────────────

TEST_DIR=$(mktemp -d /tmp/wv-autosync-vis-XXXXXX)
cleanup() { chmod -R u+w "$TEST_DIR" 2>/dev/null || true; rm -rf "$TEST_DIR"; }
trap cleanup EXIT

export WEAVE_DIR="$TEST_DIR/.weave"
export WV_HOT_ZONE="$TEST_DIR/hot"
export WV_CONFIG_DIR="$TEST_DIR/config"; mkdir -p "$WV_CONFIG_DIR"
export WV_AUTO_SYNC=1
export WV_AUTO_CHECKPOINT=0
mkdir -p "$WEAVE_DIR"
cd "$TEST_DIR" || exit 1

if [ "$(id -u)" = "0" ]; then
    echo "  (skipping behavioural checks: running as root, chmod cannot deny writes)"
else
    node_id=$("$WV" add "autosync visibility probe" 2>/dev/null | grep -oE '^wv-[0-9a-f]+$' | tail -1)

    if [ -z "$node_id" ]; then
        bad "probe node created" "wv add produced no node"
    else
        ok "probe node created ($node_id)"

        # Deny auto_sync its temp files, and clear the throttle stamp so the
        # unforced call site is reached rather than skipped.
        rm -f "$WV_HOT_ZONE/.last_sync"
        chmod 500 "$WEAVE_DIR"

        stderr_unforced=$("$WV" remember "probe memory" 2>&1 >/dev/null)
        if grep -qE "not persisted|wv sync" <<<"$stderr_unforced"; then
            ok "unforced auto_sync failure warns on stderr"
        else
            bad "unforced auto_sync failure warns on stderr" "stderr was: [${stderr_unforced:0:200}]"
        fi

        # 'done' is quoted so shellcheck does not read it as a loop keyword (SC1010).
        stderr_forced=$("$WV" "done" "$node_id" --skip-verification 2>&1 >/dev/null)
        if grep -qE "not persisted|wv sync" <<<"$stderr_forced"; then
            ok "forced auto_sync failure warns on stderr"
        else
            bad "forced auto_sync failure warns on stderr" "stderr was: [${stderr_forced:0:200}]"
        fi

        chmod 700 "$WEAVE_DIR"
    fi
fi

echo ""
echo "  $pass/$run passed"
[ "$pass" -eq "$run" ]
