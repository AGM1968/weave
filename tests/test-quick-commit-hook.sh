#!/usr/bin/env bash
# Suite-driven wv calls are tagged test so call-stats retro reads can exclude them.
export WV_CALL_SOURCE=test
# wv quick commits through the real pre-commit hook (wv-bb7589). Since
# 7eff88740 the hook admits a commit only under a claim held by the committer,
# and wv quick created its node active but unclaimed, so every quick commit
# with staged changes was refused and left the node active. Every other wv
# quick test runs with core.hooksPath=/dev/null, which is why none saw it.
set -uo pipefail
export WV_TEST_SUITE=1  # the user's config.env cannot log this suite's wv calls (wv-6b0f57)
export WV_REQUIRE_LEARNING=0 WV_REQUIRE_QUALITY=0
# A checkpoint commit after the quick commit would be counted as its own.
export WV_AUTO_CHECKPOINT=0
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WV="$ROOT/scripts/wv"
run=0; pass=0
ok()  { run=$((run+1)); pass=$((pass+1)); echo "  ✓ $1"; }
bad() { run=$((run+1)); echo "  ✗ $1"; [ -n "${2:-}" ] && echo "      $2"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$3] got [$2]"; fi; }
TMP=$(mktemp -d /tmp/wv-quick-hook-XXXXXX)
trap 'rm -rf "$TMP"' EXIT

R="$TMP/repo"; mkdir -p "$R" "$TMP/cfg" "$TMP/hooks"
git -C "$R" init -q . && git -C "$R" config user.email t@t && git -C "$R" config user.name t
git -C "$R" config commit.gpgsign false
# The checkout's own hook, so the suite judges the hook under test, not an
# installed copy (wv-6a0cab).
printf '#!/usr/bin/env bash\nexec bash %q "$@"\n' "$ROOT/scripts/hooks/pre-commit-weave.sh" > "$TMP/hooks/pre-commit"
chmod +x "$TMP/hooks/pre-commit"
git -C "$R" config core.hooksPath "$TMP/hooks"
# The pre-commit gate runs suites with core.hooksPath=/dev/null injected through
# GIT_CONFIG_*, which beats repository config: cleared, or this tests nothing.
w() {
    (cd "$R" && env -u GIT_CONFIG_COUNT -u GIT_CONFIG_KEY_0 -u GIT_CONFIG_VALUE_0 \
        WEAVE_DIR="$R/.weave" WV_HOT_ZONE="$TMP/hot" WV_CONFIG_DIR="$TMP/cfg" \
        WV_AGENT_ID="claude-quick-probe" "$WV" "$@") </dev/null
}
DB="$TMP/hot/brain.db"
w init >/dev/null 2>&1
git -C "$R" add -A >/dev/null 2>&1
git -C "$R" -c core.hooksPath=/dev/null commit -q --allow-empty -m "scaffold" >/dev/null 2>&1

echo "=== wv quick commits under its own claim ==="
printf 'one line\n' > "$R/note.txt"
git -C "$R" add note.txt
before=$(git -C "$R" rev-parse HEAD)
out=$(w quick "docs: add a note" 2>&1); rc=$?
id=$(grep -oE 'wv-[a-f0-9]{6}' <<< "$out" | tail -1)
check "wv quick exits 0" "$rc" "0"
[[ "$out" != *"No active Weave node is claimed"* ]] && ok "the hook admits the commit" ||
    bad "the hook admits the commit" "$(grep -m1 'claimed' <<< "$out")"
# wv quick then syncs .weave/ in a commit of its own; judge the quick commit.
quick_commit=$(git -C "$R" log --format='%H %s' "$before..HEAD" | awk '$2 == "docs:" && !found {print $1; found = 1}')
[ -n "$quick_commit" ] && ok "a commit carries the node's text" ||
    bad "a commit carries the node's text" "$(git -C "$R" log --format=%s "$before..HEAD" | tr '\n' ';')"
check "that commit holds the staged change" "$(git -C "$R" show --name-only --format= "${quick_commit:-HEAD}" | tr '\n' ' ')" "note.txt "
check "the node is closed" "$(sqlite3 "$DB" "SELECT status FROM nodes WHERE id='$id';")" "done"
check "the claim ends with the close" "$(sqlite3 "$DB" "SELECT COALESCE(json_extract(metadata,'\$.claimed_by'),'-') FROM nodes WHERE id='$id';")" "-"
[[ "$out" == *"Weave pre-commit:"* ]] && ok "the Weave pre-commit hook ran on the commit" ||
    bad "the Weave pre-commit hook ran on the commit" "no 'Weave pre-commit:' line in the output"

echo "=== a claim held by someone else is still not borrowed ==="
other=$(cd "$R" && WEAVE_DIR="$R/.weave" WV_HOT_ZONE="$TMP/hot" WV_CONFIG_DIR="$TMP/cfg" WV_AGENT_ID="codex-other" \
    "$WV" add "someone else's work" --standalone --status=active --criteria=c --risks=low 2>/dev/null </dev/null | grep -oE 'wv-[a-f0-9]{6}' | sed -n 1p)
printf 'two\n' > "$R/second.txt"; git -C "$R" add second.txt
out=$(w quick "docs: add a second note" 2>&1); rc=$?
check "wv quick still commits beside another actor's active claim" "$rc" "0"
check "the other actor's node keeps its claim" "$(sqlite3 "$DB" "SELECT json_extract(metadata,'\$.claimed_by') FROM nodes WHERE id='$other';")" "codex-other"

echo ""
echo "Results: $pass/$run passed"
[ "$pass" -eq "$run" ]
