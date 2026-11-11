#!/usr/bin/env bash
# test-load-v1-replay-branch.sh — wv load takes the right branch after the
# batched v1 delta replay (wv-aa9643).
#
# cmd_load replays every surviving delta in one sqlite3 call, then branches on
# its exit status. Success drains the change tracker (otherwise the next sync
# re-emits every replayed change as a fresh delta), writes .applied_deltas and
# rebuilds nodes_fts. Failure rolls back, warns, and writes nothing, so the next
# load retries. The cloud probe wv-0b9d5c inverted that test (fts-2) and every
# suite stayed green; test-load-fts-rebuild.sh now sees it, but only through the
# skipped FTS rebuild. This suite asserts the branch itself.
#
# .applied_deltas is observability only — load never trusts it to skip replay —
# so the failure half pins what it reports, not what it retries.

set -eu
export WV_TEST_SUITE=1  # the user's config.env cannot log this suite's wv calls (wv-6b0f57)
export WV_CALL_SOURCE=test

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WV="$REPO_ROOT/scripts/wv"

TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
export WV_HOT_ZONE="$TEST_DIR/hot"
WV_DB="$TEST_DIR/hot/brain.db"   # not exported — see test-tombstone-reconcile.sh
export WEAVE_DIR="$TEST_DIR/.weave"
export WV_PROJECT_DIR="$TEST_DIR"
export WV_AGENT_ID="load-branch-agent"
export WV_REQUIRE_LEARNING=0
export WV_AUTO_CHECKPOINT=0
mkdir -p "$WV_HOT_ZONE" "$WEAVE_DIR"
cd "$TEST_DIR"
git init -q 2>/dev/null || true

pass=0; run=0
ok()  { echo "  ✓ $1"; pass=$((pass + 1)); run=$((run + 1)); }
bad() { echo "  ✗ $1"; [ -n "${2:-}" ] && echo "      $2"; run=$((run + 1)); }

MANIFEST="$WEAVE_DIR/.applied_deltas"
D="$WEAVE_DIR/deltas/2026-01-01"

# Drop the hot zone so the next load rebuilds from state.sql + deltas.
reload() {
    rm -rf "$WV_HOT_ZONE"; mkdir -p "$WV_HOT_ZONE"
    # Callers capture $(reload): load's stderr is the result, its stdout is noise.
    { "$WV" load >/dev/null; } 2>&1 || true
}
text_of() { sqlite3 "$WV_DB" "SELECT text FROM nodes WHERE id='$1';" 2>/dev/null; }

"$WV" init >/dev/null 2>&1
id=$("$WV" add "original text" 2>/dev/null | grep -oE 'wv-[0-9a-f]{6}' | head -1)
id2=$("$WV" add "second node" 2>/dev/null | grep -oE 'wv-[0-9a-f]{6}' | head -1)  # wv-12dce0 checks
"$WV" sync >/dev/null 2>&1   # state.sql carries the node; cmd_load replays only when it exists
[ -n "$id" ] && ok "fixture node created ($id)" || bad "fixture node created"
mkdir -p "$D"

echo "wv load: a v1 replay that succeeds"
# Headered and late: a headerless delta older than the checkpoint is skipped as
# legacy pre-checkpoint, and nothing would replay.
good="9999999998-000000-000-zz-1.sql"
{ echo "/* weave-lineage seq=998 actor=zz */"
  echo "UPDATE nodes SET text='replayed text', lineage_seq=998, lineage_actor='zz' WHERE id='$id';"
} > "$D/$good"
out=$(reload)

[ "$(text_of "$id")" = "replayed text" ] \
    && ok "the delta was replayed (precondition)" \
    || bad "the delta was replayed (precondition)" "text=$(text_of "$id")"
# The fixture's own sync also emitted a delta, so the count is not asserted.
case "$out" in *"Replayed "*" delta(s)"*) ok "load reports the replay" ;;
    *) bad "load reports the replay" "stderr: $out" ;; esac
case "$out" in *"Delta replay failed"*) bad "load does not report a failure" "stderr: $out" ;;
    *) ok "load does not report a failure" ;; esac
grep -qxF -- "$good" "$MANIFEST" 2>/dev/null \
    && ok "the manifest records the replayed delta" \
    || bad "the manifest records the replayed delta" "manifest: $(cat "$MANIFEST" 2>/dev/null)"
pending=$(sqlite3 "$WV_DB" "SELECT count(*) FROM _warp_changes;" 2>/dev/null)
[ "$pending" = "0" ] && ok "the change tracker is drained after the replay" \
    || bad "the change tracker is drained after the replay" "_warp_changes rows: $pending"

echo "wv load: every delta classified in one pass (wv-12dce0)"
# The per-file greps became one awk read; these are the decisions they made.
lower="9999999996-000000-000-zz-3.sql"          # statements match in any case
eq="9999999995-000000-000-zz=eq-4.sql"          # "=" in a name is not an awk assignment
noop="9999999994-000000-000-zz-5.sql"           # comment-only: skipped, silently
corrupt="9999999993-000000-000-zz-6.sql"        # neither SQL nor comment: warned
legacy="1000000000-000000-000-zz-7.sql"         # old unguarded node replace: skipped
{ echo "/* weave-lineage seq=996 actor=zz */"
  echo "update nodes set alias='lc-probe' where id='$id';"; } > "$D/$lower"
{ echo "/* weave-lineage seq=995 actor=zz */"
  echo "UPDATE nodes SET alias='eq-probe' WHERE id='$id2';"; } > "$D/$eq"
printf -- "-- no-op UPDATE on node '%s'\n" "$id" > "$D/$noop"
printf 'this is not sql\n' > "$D/$corrupt"
printf "insert or replace into nodes (id, text, status) values ('%s', 'legacy text', 'todo');\n" "$id2" > "$D/$legacy"
out=$(reload)
alias_of() { sqlite3 "$WV_DB" "SELECT alias FROM nodes WHERE id='$1';" 2>/dev/null; }
[ "$(alias_of "$id")" = "lc-probe" ] && ok "a lowercase statement replays" \
    || bad "a lowercase statement replays" "alias=$(alias_of "$id")"
[ "$(alias_of "$id2")" = "eq-probe" ] && ok "a delta whose name holds '=' replays" \
    || bad "a delta whose name holds '=' replays" "alias=$(alias_of "$id2")"
grep -qxF -- "$noop" "$MANIFEST" 2>/dev/null && bad "a comment-only delta is not replayed" \
    || ok "a comment-only delta is not replayed"
case "$out" in *"$noop"*) bad "a comment-only delta is skipped silently" "stderr: $out" ;;
    *) ok "a comment-only delta is skipped silently" ;; esac
case "$out" in *"Skipped corrupt delta: $corrupt"*) ok "a corrupt delta is warned about" ;;
    *) bad "a corrupt delta is warned about" "stderr: $out" ;; esac
[ "$(text_of "$id2")" = "second node" ] && ok "a lowercase legacy node replace is skipped" \
    || bad "a lowercase legacy node replace is skipped" "text=$(text_of "$id2")"
case "$out" in *"legacy pre-checkpoint"*) ok "load counts the legacy skip" ;;
    *) bad "load counts the legacy skip" "stderr: $out" ;; esac
rm -f "$D/$lower" "$D/$eq" "$D/$noop" "$D/$corrupt" "$D/$legacy"

echo "wv load: a v1 replay that fails"
# The first statement is valid; the second fails, so .bail must roll back both.
bad_delta="9999999999-000000-000-zz-2.sql"
{ echo "/* weave-lineage seq=999 actor=zz */"
  echo "UPDATE nodes SET text='must roll back', lineage_seq=999, lineage_actor='zz' WHERE id='$id';"
  echo "UPDATE no_such_table SET x=1;"
} > "$D/$bad_delta"
out=$(reload)

case "$out" in *"Delta replay failed"*) ok "load reports the failure" ;;
    *) bad "load reports the failure" "stderr: $out" ;; esac
case "$out" in *"Replayed "*) bad "load does not report a replay" "stderr: $out" ;;
    *) ok "load does not report a replay" ;; esac
[ "$(text_of "$id")" = "original text" ] \
    && ok "the whole batch rolled back" \
    || bad "the whole batch rolled back" "text=$(text_of "$id")"
[ -s "$MANIFEST" ] \
    && bad "the manifest records nothing" "manifest: $(cat "$MANIFEST")" \
    || ok "the manifest records nothing"
out=$(reload)
case "$out" in *"Delta replay failed"*) ok "the next load retries the batch" ;;
    *) bad "the next load retries the batch" "stderr: $out" ;; esac

echo ""
echo "Results: $pass/$run passed"
[ "$pass" -eq "$run" ]
