#!/usr/bin/env bash
# Suite-driven wv calls are tagged test so call-stats retro reads can exclude them.
export WV_CALL_SOURCE=test
# The database size guard judges the graph, not the file (wv-dc5486). The
# code-search index (wv index) can be most of brain.db; wv prune cannot shrink
# it, so it must neither trigger the warning nor make WV_AUTO_PRUNE=1 delete
# graph nodes. When the graph itself is over the limit, auto-prune runs wv prune,
# which keeps findings, memories and unaddressed pitfalls.
set -uo pipefail
export WV_TEST_SUITE=1  # the user's config.env cannot log this suite's wv calls (wv-6b0f57)
export WV_RUN_CACHE=0
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WV="$ROOT/scripts/wv"
run=0; pass=0
ok()  { run=$((run+1)); pass=$((pass+1)); echo "  ✓ $1"; }
bad() { run=$((run+1)); echo "  ✗ $1"; [ -n "${2:-}" ] && echo "      $2"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$3] got [$2]"; fi; }
TMP=$(mktemp -d /tmp/wv-db-size-guard-XXXXXX)
trap 'rm -rf "$TMP"' EXIT

R="$TMP/repo"; mkdir -p "$R" "$TMP/cfg"
git -C "$R" init -q . && git -C "$R" config user.email t@t && git -C "$R" config user.name t
DB="$TMP/hot/brain.db"
# w — a wv call in the scratch repo with a 1MB limit and a fresh size check.
w() {
    (cd "$R" && env -u _WV_SIZE_CHECKED -u WV_DISABLE_AUTOPRUNE WEAVE_DIR="$R/.weave" WV_HOT_ZONE="$TMP/hot" \
        WV_CONFIG_DIR="$TMP/cfg" WV_MAX_DB_SIZE=1048576 "$@" "$WV" status) </dev/null
}
sq() { sqlite3 -cmd ".timeout 5000" "$DB" "$1"; }
(cd "$R" && WEAVE_DIR="$R/.weave" WV_HOT_ZONE="$TMP/hot" WV_CONFIG_DIR="$TMP/cfg" "$WV" init) </dev/null >/dev/null 2>&1
add() { (cd "$R" && WEAVE_DIR="$R/.weave" WV_HOT_ZONE="$TMP/hot" WV_CONFIG_DIR="$TMP/cfg" "$WV" add "$@" --standalone) </dev/null 2>/dev/null | grep -oE 'wv-[a-f0-9]{6}' | sed -n 1p; }
old_done() { sq "UPDATE nodes SET status='done', updated_at=datetime('now','-3 days') WHERE id='$1';"; }
task=$(add "an old done task"); memory=$(add "an old done memory" --kind=memory); finding=$(add "an old done finding" --kind=finding)
for n in "$task" "$memory" "$finding"; do old_done "$n"; done
exists() { sq "SELECT COUNT(*) FROM nodes WHERE id='$1';"; }

echo "=== a large code index is not graph data ==="
sq "WITH RECURSIVE s(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM s WHERE i < 1500)
    INSERT INTO chunks(file, line_start, line_end, content) SELECT 'src/f' || i || '.py', 1, 40, hex(randomblob(1500)) FROM s;"
size=$(stat -c%s "$DB" 2>/dev/null || stat -f%z "$DB")
[ "$size" -gt 1048576 ] && ok "the fixture file is over the 1MB limit ($((size / 1024))KB)" || bad "the fixture file is over the 1MB limit" "$size"
chunks=$(sq "SELECT COUNT(*) FROM chunks;")
err=$(w 2>&1 >/dev/null)
[[ "$err" != *"MB (limit"* ]] && ok "an index-heavy DB under the graph limit draws no size warning" ||
    bad "an index-heavy DB under the graph limit draws no size warning" "$err"
w WV_AUTO_PRUNE=1 >/dev/null 2>&1
check "auto-prune leaves the graph alone when only the index is large" "$(exists "$task")" "1"
check "and leaves the index alone" "$(sq "SELECT COUNT(*) FROM chunks;")" "$chunks"

echo "=== a large graph is still caught ==="
big=$(add "a live node carrying a large text")
sq "UPDATE nodes SET text = hex(randomblob(700000)) WHERE id='$big';"
err=$(w 2>&1 >/dev/null)
[[ "$err" == *"graph data is"*"MB (limit 1MB)"* ]] && ok "a graph over the limit is warned about" ||
    bad "a graph over the limit is warned about" "$err"
w WV_AUTO_PRUNE=1 >/dev/null 2>&1
check "auto-prune removes an old done task" "$(exists "$task")" "0"
check "auto-prune keeps an old done memory, as wv prune does" "$(exists "$memory")" "1"
check "auto-prune keeps an old done finding, as wv prune does" "$(exists "$finding")" "1"
check "auto-prune keeps the live node" "$(exists "$big")" "1"
check "auto-prune never evicts the code index" "$(sq "SELECT COUNT(*) FROM chunks;")" "$chunks"
[ -n "$(find "$R/.weave/archive" -name '*.jsonl' 2>/dev/null)" ] && ok "the pruned node is archived" || bad "the pruned node is archived"

echo "=== a dot-command never swallows the SQL after it ==="
# The guard's old auto-prune passed ".timeout 5000<newline>DELETE ..." as one
# argument: sqlite3 read it as the .timeout command alone and exited 0, so the
# prune and the chunk eviction deleted nothing. The rule finds the shape; it is
# memory-system's own since wv-ca97ce, no longer a shipped default.
sq "CREATE TABLE IF NOT EXISTS probe(x); INSERT INTO probe VALUES(1);"
sqlite3 "$DB" ".timeout 5000
DELETE FROM probe;" 2>/dev/null
check "sqlite3 still swallows it (the rule's premise)" "$(sq "SELECT COUNT(*) FROM probe;")" "1"

echo ""
echo "Results: $pass/$run passed"
[ "$pass" -eq "$run" ]
