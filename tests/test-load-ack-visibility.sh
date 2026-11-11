#!/usr/bin/env bash
# Suite-driven wv calls are tagged test so call-stats retro reads can exclude them.
export WV_CALL_SOURCE=test
# test-load-ack-visibility.sh — an unacknowledged graph load is loud (wv-2f55dd).
#
# On 2026-11-09 every fresh wv load failed for nine hours behind a one-line
# warning (wv-5e5f18): the replay rolled back, so changes made only in deltas were
# missing, and nothing after the load said so. Pinned here, with a load made to
# fail by a planted malformed v2 operation:
#   - the recorded failure names the failing operation;
#   - wv bootstrap puts it first in readiness, with the operation;
#   - wv doctor fails its graph load check;
#   - a load that completes clears both.
set -uo pipefail
export WV_TEST_SUITE=1  # the user's config.env cannot log this suite's wv calls (wv-6b0f57)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WV="$REPO_ROOT/scripts/wv"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE WV_DB WV_DB_CUSTOM
export WV_HOT_ZONE="$T/hot" WEAVE_DIR="$T/.weave" WV_PROJECT_DIR="$T" WV_CONFIG_DIR="$T/cfg"
export WV_AGENT_ID=load-ack-test WV_REQUIRE_LEARNING=0 WV_AUTO_CHECKPOINT=0 WV_SYNC_INTERVAL=0
mkdir -p "$WV_HOT_ZONE" "$WV_CONFIG_DIR"
cd "$T" || exit 1
git init -q && git config user.email t@t && git config user.name t && git config commit.gpgsign false
pass=0; run=0
ok()  { echo "  ✓ $1"; pass=$((pass + 1)); run=$((run + 1)); }
bad() { echo "  ✗ $1"; [ -n "${2:-}" ] && echo "      $2"; run=$((run + 1)); }
has()   { if grep -qF -- "$3" <<< "$2"; then ok "$1"; else bad "$1" "missing [$3] in: $(tail -4 <<< "$2")"; fi; }
hasnt() { if grep -qF -- "$3" <<< "$2"; then bad "$1" "unexpected [$3]"; else ok "$1"; fi; }
fresh_load() { rm -rf "$WV_HOT_ZONE"; mkdir -p "$WV_HOT_ZONE"; "$WV" load 2>&1; }
advisories() { "$WV" bootstrap --json 2>/dev/null | jq -r '.readiness.advisories // [] | .[]'; }

"$WV" init >/dev/null 2>&1
"$WV" add "a node" --force >/dev/null 2>&1
WV_FORCE_SYNC=1 "$WV" sync >/dev/null 2>&1
git add -A && git commit -q -m fixture

echo "a load whose replay fails"
plant="$WEAVE_DIR/deltas/2026-11-09/v2/000000999999-planted.json"
mkdir -p "$(dirname "$plant")" && printf '{ not json\n' > "$plant"
out=$(fresh_load)
has "wv load says it was not acknowledged" "$out" "not acknowledged"
has "...naming the failing operation" "$out" "000000999999-planted.json"
state=$("$WV" bootstrap --json 2>/dev/null | jq -r '.readiness.load.state // empty')
[ "$state" = failed ] && ok "bootstrap records the load as failed" || bad "bootstrap records the load as failed" "got [$state]"
adv=$(advisories)
first=$(sed -n 1p <<< "$adv")
has "bootstrap's first readiness advisory is the failed load" "$first" "graph load not acknowledged"
has "...naming the failing operation" "$first" "2026-11-09/000000999999-planted.json"
doc=$("$WV" doctor 2>&1)
has "doctor fails its graph load check" "$doc" "✗ graph load: last load not acknowledged"

echo "a load that completes"
rm -f "$plant"
out=$(fresh_load)
hasnt "wv load is acknowledged" "$out" "not acknowledged"
hasnt "bootstrap no longer reports it" "$(advisories)" "graph load not acknowledged"
has "doctor passes its graph load check" "$("$WV" doctor 2>&1)" "✓ graph load: last load acknowledged"

echo "Results: $pass/$run passed"
[ "$pass" -eq "$run" ]
