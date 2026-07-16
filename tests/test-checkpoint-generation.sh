#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/lib/wv-delta-catalog.sh"
source "$ROOT/scripts/lib/wv-checkpoint-generation.sh"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/weave/deltas/day"
cat > "$TMP/weave/state.sql" <<'SQL'
CREATE TABLE nodes (id TEXT PRIMARY KEY, text TEXT NOT NULL);
INSERT INTO nodes VALUES('wv-base', 'base');
SQL
cat > "$TMP/weave/deltas/day/a.sql" <<'SQL'
INSERT INTO nodes VALUES('wv-delta', 'delta');
SQL
wv_checkpoint_generation_stage "$TMP/weave" "$TMP/stage" gen-1
[ -f "$TMP/stage/gen-1/state.sql" ] && [ -f "$TMP/stage/gen-1/manifest.json" ] && [ -f "$TMP/stage/gen-1/generation.json" ] && [ -f "$TMP/stage/gen-1/journal.json" ] && [ -f "$TMP/weave/deltas/day/a.sql" ]
[ -f "$TMP/stage/gen-1/legacy-deltas/v1/day/a.sql" ] && [ -f "$TMP/stage/gen-1/legacy-deltas/v1/catalog.json" ]
[ ! -e "$TMP/stage/gen-1/candidate.db" ] && [ ! -e "$TMP/stage/gen-1/entries.jsonl" ] && [ ! -e "$TMP/stage/gen-1/.work" ]
[ "$(find "$TMP/stage/gen-1" -type f | wc -l)" -eq 6 ]
sqlite3 :memory: < "$TMP/stage/gen-1/state.sql"
sqlite3 "$TMP/check.db" < "$TMP/stage/gen-1/state.sql"
[ "$(sqlite3 "$TMP/check.db" "SELECT text FROM nodes WHERE id = 'wv-delta';")" = "delta" ]
jq -e '.incorporated_legacy_deltas["day/a.sql"].disposition == "incorporated"' "$TMP/stage/gen-1/manifest.json" >/dev/null
jq -e '.graph_revision | not' "$TMP/stage/gen-1/manifest.json" >/dev/null
jq -e '.entries[0].archived_path == "legacy-deltas/v1/day/a.sql"' "$TMP/stage/gen-1/legacy-deltas/v1/catalog.json" >/dev/null
jq -e '.state == "staged"' "$TMP/stage/gen-1/journal.json" >/dev/null
mkdir -p "$TMP/no-deltas"
cp "$TMP/weave/state.sql" "$TMP/no-deltas/state.sql"
wv_checkpoint_generation_stage "$TMP/no-deltas" "$TMP/stage" gen-empty
jq -e '.incorporated_legacy_deltas == {}' "$TMP/stage/gen-empty/manifest.json" >/dev/null
mkdir -p "$TMP/bad-root"
cp "$TMP/weave/state.sql" "$TMP/bad-root/state.sql"
printf not-a-directory > "$TMP/bad-root/deltas"
if wv_checkpoint_generation_stage "$TMP/bad-root" "$TMP/stage" gen-bad-root >/dev/null 2>&1; then exit 1; fi
printf x > "$TMP/weave/deltas/day/unknown.txt"
if wv_checkpoint_generation_stage "$TMP/weave" "$TMP/stage" gen-2 >/dev/null 2>&1; then exit 1; fi
rm "$TMP/weave/deltas/day/unknown.txt"
ln -s "$TMP/weave/deltas/day/a.sql" "$TMP/weave/deltas/day/link.sql"
if wv_checkpoint_generation_stage "$TMP/weave" "$TMP/stage" gen-3 >/dev/null 2>&1; then exit 1; fi
rm "$TMP/weave/deltas/day/link.sql"
if wv_checkpoint_generation_stage "$TMP/weave" "$TMP/stage" ../escape >/dev/null 2>&1; then exit 1; fi
if wv_checkpoint_generation_stage "$TMP/weave" "$TMP/stage" gen-1 >/dev/null 2>&1; then exit 1; fi
wv_checkpoint_stage_transition "$TMP/stage/gen-1/journal.json" published > "$TMP/published.json"
jq -e '.state == "published" and .generation == "gen-1"' "$TMP/published.json" >/dev/null
jq '. + {extra: true}' "$TMP/stage/gen-1/journal.json" > "$TMP/bad-journal.json"
if wv_checkpoint_stage_transition "$TMP/bad-journal.json" published >/dev/null 2>&1; then exit 1; fi
if wv_checkpoint_stage_transition "$TMP/stage/gen-1/journal.json" selected >/dev/null 2>&1; then exit 1; fi
if wv_checkpoint_stage_transition "$TMP/published.json" aborted >/dev/null 2>&1; then exit 1; fi
if wv_checkpoint_stage_transition "$TMP/published.json" selected >/dev/null 2>&1; then exit 1; fi
printf '{"format":"weave.checkpoint-current.v1","generation":"gen-1"}' > "$TMP/current.json"
wv_checkpoint_stage_transition "$TMP/published.json" aborted "$TMP/current.json" > "$TMP/selected.json"
jq -e '.state == "selected"' "$TMP/selected.json" >/dev/null
printf '{"format":"weave.checkpoint-current.v1","generation":"other"}' > "$TMP/current-other.json"
wv_checkpoint_stage_transition "$TMP/published.json" selected "$TMP/current-other.json" > "$TMP/aborted.json"
jq -e '.state == "aborted"' "$TMP/aborted.json" >/dev/null
echo "Results: checkpoint generation tests passed"
