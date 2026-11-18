#!/usr/bin/env bash
# Suite-driven wv calls are tagged test so call-stats retro reads can exclude them.
export WV_CALL_SOURCE=test
# Claiming a node that declares metadata.retires lists every reference to the
# retired name before work starts (wv-dfdc21).
#
# Origin wv-d231af (2026-11-14): converting the trails skill, a sweep on
# "skills/trails" missed test-install-skill-prune pinning the BARE name
# 'trails' as a shipped skill; the failure surfaced only at the 15-minute gate.
#
# What this pins:
#   - a bare name pinned in a test fixture is listed (the wv-d231af miss)
#   - the match is word-bounded (trailsx is not listed) and scoped to
#     tests/ install.sh templates/ scripts/ (docs/ is not listed)
#   - an array of entries sweeps each one
#   - --json stdout stays a single JSON object; the sweep goes to stderr
#   - a node without retires prints no sweep; a malformed entry warns, no grep
set -uo pipefail
export WV_TEST_SUITE=1  # the user's config.env cannot log this suite's wv calls (wv-6b0f57)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WV="$ROOT/scripts/wv"

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
run=0; pass=0
ok() { run=$((run+1)); pass=$((pass+1)); echo -e "  ${GREEN}✓${NC} $1"; }
bad() { run=$((run+1)); echo -e "  ${RED}✗${NC} $1"; [ -n "${2:-}" ] && echo "      $2"; }
has() { if grep -qF -- "$2" <<<"$3"; then ok "$1"; else bad "$1" "missing [$2] in: ${3:0:400}"; fi; }
lacks() { if grep -qF -- "$2" <<<"$3"; then bad "$1" "unexpected [$2] in: ${3:0:400}"; else ok "$1"; fi; }

echo "wv work: retires reference sweep"

# git bisect run and nested hooks export GIT_*; a scratch git init must not
# reach the real repository (wv-8f1da6).
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR

TEST_DIR=$(mktemp -d /tmp/wv-retires-XXXXXX)
trap 'rm -rf "$TEST_DIR"' EXIT

export WEAVE_DIR="$TEST_DIR/.weave"
export WV_HOT_ZONE="$TEST_DIR/hot"
export WV_DB="$TEST_DIR/hot/brain.db"
export WV_CONFIG_DIR="$TEST_DIR/config"
export WV_AUTO_CHECKPOINT=0
mkdir -p "$WEAVE_DIR" "$WV_CONFIG_DIR" "$TEST_DIR/hot"
cd "$TEST_DIR" || exit 1

git init -q . && git config user.email t@example.invalid && git config user.name t
git config core.hooksPath /dev/null
mkdir -p tests scripts templates docs
printf '%s\n' '#!/bin/bash' 'SHIPPED=(weave trails)' > tests/test-fixture-prune.sh
printf '%s\n' 'cp skills/trails/SKILL.md out/' 'echo trailsx' > scripts/copy.sh
printf '%s\n' 'see the zero-in skill' > templates/guide.md
printf '%s\n' 'trails is documented here' > docs/notes.md
printf '%s\n' 'WV_CONFIG_SKILLS=(weave)' > install.sh
git add -A && git commit -qm fixture

new_node() { "$WV" add "$1" --standalone --criteria="c1" 2>/dev/null | grep -oE '^wv-[0-9a-f]+$' | tail -1; }
retiring=$(new_node "retire the trails fixture skill")
pair=$(new_node "retire two fixture skills")
plain=$(new_node "ordinary node with nothing retired")
malformed=$(new_node "node with a malformed retires entry")
if [ -z "$retiring" ] || [ -z "$pair" ] || [ -z "$plain" ] || [ -z "$malformed" ]; then
    bad "fixture nodes created" "[$retiring] [$pair] [$plain] [$malformed]"
    echo ""; echo "  $pass/$run passed"; exit 1
fi
ok "fixture nodes created"
"$WV" update "$retiring" --metadata='{"retires":"skill:trails"}' >/dev/null 2>&1
"$WV" update "$pair" --metadata='{"retires":["skill:trails","skill:zero-in"]}' >/dev/null 2>&1
"$WV" update "$malformed" --metadata='{"retires":"skill:bad name;rm"}' >/dev/null 2>&1

# ── a single entry ───────────────────────────────────────────────────────────
err=$("$WV" work "$retiring" 2>&1 >/dev/null)
has   "the bare name pinned in a test fixture is listed" "tests/test-fixture-prune.sh:2:SHIPPED=(weave trails)" "$err"
has   "a path-form reference in scripts/ is listed" "scripts/copy.sh:1:" "$err"
lacks "the match is word-bounded (trailsx is not listed)" "scripts/copy.sh:2:" "$err"
lacks "docs/ is outside the sweep" "docs/notes.md" "$err"
has   "the sweep states its count" "2 reference(s) to 'trails'" "$err"
"$WV" "done" "$retiring" --skip-verification >/dev/null 2>&1 || true

# ── an array, and --json stdout ──────────────────────────────────────────────
out_file="$TEST_DIR/json.out"
err=$("$WV" work "$pair" --json 2>&1 >"$out_file")
if jq -e --arg id "$pair" '.id == $id' "$out_file" >/dev/null 2>&1; then
    ok "--json stdout is one JSON object, unchanged by the sweep"
else
    bad "--json stdout is one JSON object, unchanged by the sweep" "stdout: $(head -c 300 "$out_file")"
fi
has "each array entry is swept (trails)" "Retires skill:trails" "$err"
has "each array entry is swept (zero-in)" "templates/guide.md:1:" "$err"
"$WV" "done" "$pair" --skip-verification >/dev/null 2>&1 || true

# ── no retires, and a malformed entry ────────────────────────────────────────
err=$("$WV" work "$plain" 2>&1 >/dev/null)
lacks "a node without retires prints no sweep" "Retires" "$err"
"$WV" "done" "$plain" --skip-verification >/dev/null 2>&1 || true

err=$("$WV" work "$malformed" 2>&1 >/dev/null)
has   "a malformed entry is reported" "names no sweepable entity" "$err"
lacks "a malformed entry runs no grep" "reference(s)" "$err"

echo ""
echo "  $pass/$run passed"
[ "$pass" -eq "$run" ]
