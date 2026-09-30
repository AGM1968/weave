#!/usr/bin/env bash
# Citation-drift check (wv-1b1e31): a doc sentence that calls a graph node
# open, pending, tracked or blocked while the graph says it is done.
# Runs against a fixture graph and fixture docs only; the live graph is never
# read, so the suite's verdict cannot depend on what this repository closed today.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOL="$ROOT/tests/lib/citation-drift-scan.py"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

pass=0
run=0
ok()  { echo "  ✓ $1"; pass=$((pass + 1)); run=$((run + 1)); }
bad() { echo "  ✗ $1"; run=$((run + 1)); }

python3 - "$TMP/graph.db" <<'PY'
import sqlite3, sys
conn = sqlite3.connect(sys.argv[1])
conn.execute("CREATE TABLE nodes (id TEXT PRIMARY KEY, status TEXT)")
conn.executemany("INSERT INTO nodes VALUES (?, ?)", [
    ("wv-aaaaa1", "done"), ("wv-bbbbb2", "todo"), ("wv-ccccc3", "done"),
    ("wv-ddddd4", "done"), ("wv-eeeee5", "done"), ("wv-fffff6", "done"),
])
conn.commit()
PY

mkdir -p "$TMP/repo/docs/findings"
cat > "$TMP/repo/docs/open.md" <<'DOC'
# Drifted

The loader residual is tracked as `wv-aaaaa1`.

Status: spec (implementation pending) Node: `wv-ccccc3`

- The split landed long ago and was verified.
- Checkpoint migration remains open under `wv-eeeee5`.

The promotion side is implemented under `wv-ddddd4`; parent `wv-fffff6` remains open for Phase 2.
DOC
cat > "$TMP/repo/docs/clean.md" <<'DOC'
# Historical by design

Tracked as `wv-bbbbb2`.

This was tracked as `wv-aaaaa1` and has since closed.

As of 2026-08-04 the remainder is tracked as `wv-ccccc3`.

Ground-truth pass: wv-ddddd4 (2026-06-10) — gate dates aligned; item 1 tracked as wv-aaaaa1
and item 2 remains open under wv-eeeee5.
DOC
cat > "$TMP/repo/docs/findings/old.md" <<'DOC'
Tracked as `wv-aaaaa1`, not yet run.
DOC

set +e
python3 "$TOOL" --repo-root "$TMP/repo" --db "$TMP/graph.db" --json > "$TMP/report.json" 2>"$TMP/err"
advisory_rc=$?
set -e

[ "$advisory_rc" -eq 0 ] \
  && ok "advisory mode exits 0 even when it finds drift" \
  || { bad "advisory mode exits 0 even when it finds drift"; sed -n '1,5p' "$TMP/err" >&2; }

jq -e '[.drift[] | select(.file == "docs/open.md") | .id] | sort == ["wv-aaaaa1","wv-ccccc3","wv-eeeee5","wv-fffff6"]' \
  "$TMP/report.json" >/dev/null \
  && ok "flags each done node cited as open: tracked, pending status, open bullet, open clause" \
  || bad "flags each done node cited as open: tracked, pending status, open bullet, open clause"

jq -e '[.drift[] | select(.id == "wv-ddddd4")] | length == 0' "$TMP/report.json" >/dev/null \
  && ok "a closed clause is not flagged for its open neighbour in the same sentence" \
  || bad "a closed clause is not flagged for its open neighbour in the same sentence"

jq -e '[.drift[] | select(.file == "docs/clean.md")] | length == 0' "$TMP/report.json" >/dev/null \
  && ok "silent on a todo node, past tense, a dated as-of, and a provenance-trailer entry" \
  || bad "silent on a todo node, past tense, a dated as-of, and a provenance-trailer entry"

jq -e '[.drift[] | select(.file | startswith("docs/findings/"))] | length == 0' "$TMP/report.json" >/dev/null \
  && ok "docs/findings/ is exempt as dated records" \
  || bad "docs/findings/ is exempt as dated records"

# Seven: five in open.md, two in clean.md. The trailer entry is excused before
# counting and docs/findings/ is never read.
jq -e '.cited_done == 7' "$TMP/report.json" >/dev/null \
  && ok "the scan resolves citations against the graph (it is not vacuously silent)" \
  || bad "the scan resolves citations against the graph (it is not vacuously silent)"

if python3 "$TOOL" --repo-root "$TMP/repo" --db "$TMP/graph.db" --strict >/dev/null 2>&1; then
  bad "--strict exits nonzero when drift is found"
else
  ok "--strict exits nonzero when drift is found"
fi

# The status column and closed value come from the node field registry. Copy
# the tool beside a registry whose enum has lost "done": it must refuse rather
# than silently find nothing done.
mkdir -p "$TMP/tree/tests/lib" "$TMP/tree/contracts"
cp "$TOOL" "$TMP/tree/tests/lib/"
jq '.fields.status.value.enum -= ["done"]' "$ROOT/contracts/node-field-registry-v1.json" \
  > "$TMP/tree/contracts/node-field-registry-v1.json"
if python3 "$TMP/tree/tests/lib/citation-drift-scan.py" --repo-root "$TMP/repo" --db "$TMP/graph.db" \
  >/dev/null 2>"$TMP/registry.err"; then
  bad "a registry without the closed status stops the scan instead of finding nothing"
else
  grep -q "no longer contains 'done'" "$TMP/registry.err" \
    && ok "a registry without the closed status stops the scan instead of finding nothing" \
    || bad "a registry without the closed status stops the scan instead of finding nothing"
fi

rm "$TMP/repo/docs/open.md"
python3 "$TOOL" --repo-root "$TMP/repo" --db "$TMP/graph.db" --strict >/dev/null 2>&1 \
  && ok "--strict exits 0 on a tree with only historical-by-design citations" \
  || bad "--strict exits 0 on a tree with only historical-by-design citations"

echo "Results: $pass/$run passed"
[ "$pass" -eq "$run" ]
