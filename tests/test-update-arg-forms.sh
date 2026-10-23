#!/usr/bin/env bash
# Suite-driven wv calls are tagged test so call-stats retro reads can exclude them.
export WV_CALL_SOURCE=test
# wv update applies or refuses every argument it is given (wv-51605f).
#
# The parser had no default branch: an option it did not know was skipped with
# its value, and only --metadata/--metadata-file had a space-separated form. So
# 'wv update <id> --text "new"' dropped the text, and alongside any =-form
# option it printed the success line: a text correction reported as applied
# reached the GitHub projection stale. Every value option now takes both forms,
# and an unknown argument fails the command before anything is written.
set -uo pipefail
export WV_TEST_SUITE=1  # the user's config.env cannot log this suite's wv calls (wv-6b0f57)
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WV="$ROOT/scripts/wv"
run=0; pass=0
ok()  { run=$((run+1)); pass=$((pass+1)); echo "  ✓ $1"; }
bad() { run=$((run+1)); echo "  ✗ $1"; [ -n "${2:-}" ] && echo "      $2"; }
TMP=$(mktemp -d /tmp/wv-update-args-XXXXXX)
trap 'rm -rf "$TMP"' EXIT

R="$TMP/repo"; mkdir -p "$R" "$TMP/cfg"
git -C "$R" init -q . && git -C "$R" config user.email t@t && git -C "$R" config user.name t
w() { (cd "$R" && WEAVE_DIR="$R/.weave" WV_HOT_ZONE="$TMP/hot" WV_CONFIG_DIR="$TMP/cfg" "$WV" "$@"); }
DB="$TMP/hot/brain.db"
w init >/dev/null 2>&1
id=$(w add "original text" --standalone 2>/dev/null | grep -oE 'wv-[a-f0-9]{6}' | sed -n 1p)
[ -n "$id" ] && ok "fixture node created" || bad "fixture node created"
col() { sqlite3 "$DB" "SELECT COALESCE($1,'') FROM nodes WHERE id='$id';"; }

echo "=== the space-separated form applies ==="
out=$(w update "$id" --text "spaced text" 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$(col text)" = "spaced text" ] && ok "--text <value>" || bad "--text <value>" "rc=$rc text=$(col text) $out"
out=$(w update "$id" --status blocked 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$(col status)" = "blocked" ] && ok "--status <value>" || bad "--status <value>" "rc=$rc status=$(col status) $out"
out=$(w update "$id" --alias spaced-alias 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$(col alias)" = "spaced-alias" ] && ok "--alias <value>" || bad "--alias <value>" "rc=$rc alias=$(col alias) $out"
out=$(w update "$id" --text "mixed text" --metadata='{"k":1}' 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$(col text)" = "mixed text" ] && [ "$(col "json_extract(metadata,'\$.k')")" = 1 ] &&
    ok "a space form beside an =-form both apply" || bad "a space form beside an =-form both apply" "rc=$rc text=$(col text) $out"
w update "$id" --metadata='{"drop_me":1}' >/dev/null 2>&1
out=$(w update "$id" --remove-key drop_me 2>&1); rc=$?
[ "$rc" = 0 ] && [ -z "$(col "json_extract(metadata,'\$.drop_me')")" ] && ok "--remove-key <key>" || bad "--remove-key <key>" "rc=$rc $out"
out=$(w update "$id" --text=equals-text --status=todo 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$(col text)" = "equals-text" ] && [ "$(col status)" = "todo" ] &&
    ok "the =-forms still apply" || bad "the =-forms still apply" "rc=$rc $out"

echo "=== nothing is dropped silently ==="
before=$(col "text||'|'||status||'|'||metadata")
out=$(w update "$id" --bogus-flag x --metadata='{"k":2}' 2>&1); rc=$?
[ "$rc" != 0 ] && [ "$(col "text||'|'||status||'|'||metadata")" = "$before" ] && [[ "$out" == *"--bogus-flag"* ]] &&
    ok "an unknown option fails, names itself, and writes nothing" || bad "an unknown option fails, names itself, and writes nothing" "rc=$rc $out"
out=$(w update "$id" --metadata='{"k":3}' stray-word 2>&1); rc=$?
[ "$rc" != 0 ] && [ "$(col "text||'|'||status||'|'||metadata")" = "$before" ] && [[ "$out" == *"stray-word"* ]] &&
    ok "a stray positional fails and writes nothing" || bad "a stray positional fails and writes nothing" "rc=$rc $out"
out=$(w update "$id" --text 2>&1); rc=$?
[ "$rc" != 0 ] && [[ "$out" == *"--text requires"* ]] &&
    ok "a value option with no value fails" || bad "a value option with no value fails" "rc=$rc $out"
out=$(w update "$id" --text --status=todo 2>&1); rc=$?
[ "$rc" != 0 ] && [ "$(col text)" = "equals-text" ] &&
    ok "a value option does not swallow the next option as its value" || bad "a value option does not swallow the next option as its value" "rc=$rc text=$(col text) $out"

echo "=== rejected writes are not reported as applied ==="
w update "$id" --metadata='{"hold":true}' >/dev/null 2>&1
# Reject the requested changes, not lineage bookkeeping during sync: otherwise
# a later sync failure can accidentally hide the unchecked write (wv-ccd364).
sqlite3 "$DB" "CREATE TRIGGER test_update_refused BEFORE UPDATE ON nodes
    WHEN OLD.id='$id' AND (NEW.text IS NOT OLD.text OR
        json_extract(NEW.metadata,'$.hold') IS NOT json_extract(OLD.metadata,'$.hold'))
    BEGIN SELECT RAISE(ABORT, 'simulated write failure'); END;"
out=$(w update "$id" --text='rejected text' 2>&1); rc=$?
[ "$rc" != 0 ] && [[ "$out" != *"Updated:"* ]] && [ "$(col text)" = "equals-text" ] &&
    ok "a rejected text write fails without reporting success" || bad "a rejected text write fails without reporting success" "rc=$rc $out"
out=$(w update "$id" --metadata='{"hold":false}' --echo 2>&1); rc=$?
[ "$rc" != 0 ] && [ "$(col "json_extract(metadata,'$.hold')")" = 1 ] &&
    ok "a rejected metadata write fails with --echo" || bad "a rejected metadata write fails with --echo" "rc=$rc $out"
out=$(w update "$id" --remove-key=hold 2>&1); rc=$?
[ "$rc" != 0 ] && [[ "$out" != *"Removed metadata key"* ]] && [ "$(col "json_extract(metadata,'$.hold')")" = 1 ] &&
    ok "a rejected key removal fails without reporting success" || bad "a rejected key removal fails without reporting success" "rc=$rc $out"
sqlite3 "$DB" "DROP TRIGGER test_update_refused;"
out=$(w update "$id" --text='persisted text' --metadata='{"hold":false}' 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$(col text)" = "persisted text" ] && [ "$(col "json_extract(metadata,'$.hold')")" = 0 ] &&
    ok "an ordinary update persists after the failure is removed" || bad "an ordinary update persists after the failure is removed" "rc=$rc $out"

echo "Results: $pass/$run passed"
[ "$pass" -eq "$run" ]
