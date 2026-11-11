#!/usr/bin/env bash
# Suite-driven wv calls are tagged test so call-stats retro reads can exclude them.
export WV_CALL_SOURCE=test
# Session identity S1 (wv-99978b): claims are owned per harness session.
#   - a session claims under <harness>-<host>-<user>-h<digest16>, the first 16
#     hex of sha256 over the whole session id (wv-24d57b)
#   - another session of the same harness does not own that claim
#   - an unverifiable session (harness channel set but empty) cannot claim,
#     add an active node, or list --claimed-by=current (commit admission)
#   - a pre-session coarse claim is adopted only by `wv work --continue`, and
#     only by the same actor; --force takes over anyone's; both are recorded
#   - WV_SESSION_ID is the harness-agnostic channel (any host)
#   - a legacy -s<sid12> claim is adopted only by `wv work --continue` from the
#     session whose id reproduces it; a hasher failure refuses ownership
set -uo pipefail
export WV_TEST_SUITE=1  # the user's config.env cannot log this suite's wv calls (wv-6b0f57)
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WV="$ROOT/scripts/wv"
run=0; pass=0
ok()  { run=$((run+1)); pass=$((pass+1)); echo "  ✓ $1"; }
bad() { run=$((run+1)); echo "  ✗ $1"; [ -n "${2:-}" ] && echo "      $2"; }
TMP=$(mktemp -d /tmp/wv-session-claims-XXXXXX)
trap 'rm -rf "$TMP"' EXIT
R="$TMP/repo"; mkdir -p "$R" "$TMP/cfg"
git -C "$R" init -q . && git -C "$R" config user.email t@t && git -C "$R" config user.name t
export WV_ATTEMPT_JOURNAL="$TMP/journal.jsonl"
HOST=$(hostname); ME=$(whoami)
dig() { printf '%s' "$1" | sha256sum | cut -c1-16; }

# as <env assignments...> -- <wv args...>: run wv with ONLY the given identity
# markers, whatever session runs this suite.
IDVARS=(-u WV_AGENT_ID -u CLAUDECODE -u AI_AGENT -u CLAUDE_CODE_SSE_PORT -u CLAUDE_CODE_SESSION_ID -u CODEX_THREAD_ID
    -u CODEX_CI -u COPILOT_AGENT -u WV_SESSION_ID -u WV_SESSION_IDENTITY -u WV -u WV_CLI)
as() {
    local envs=()
    while [ "$1" != "--" ]; do envs+=("$1"); shift; done
    shift
    (cd "$R" && env -u WV_AGENT_ID -u CLAUDECODE -u AI_AGENT -u CLAUDE_CODE_SSE_PORT -u CLAUDE_CODE_SESSION_ID \
        -u CODEX_THREAD_ID -u CODEX_CI -u COPILOT_AGENT -u WV_SESSION_ID -u WV_SESSION_IDENTITY -u WV -u WV_CLI \
        "${envs[@]}" WEAVE_DIR="$R/.weave" WV_HOT_ZONE="$TMP/hot" WV_CONFIG_DIR="$TMP/cfg" \
        "$WV" "$@") </dev/null
}
A=(CLAUDECODE=1 CLAUDE_CODE_SESSION_ID=aaaaaaaa-1111-2222-3333-444444444444)
B=(CLAUDECODE=1 CLAUDE_CODE_SESSION_ID=bbbbbbbb-1111-2222-3333-444444444444)
NOSID=(CLAUDECODE=1)
DB="$TMP/hot/brain.db"
A_ID="claude-$HOST-$ME-h$(dig aaaaaaaa-1111-2222-3333-444444444444)"
A_LEGACY="claude-$HOST-$ME-saaaaaaaa1111"
B_LEGACY="claude-$HOST-$ME-sbbbbbbbb1111"
sq() { sqlite3 -cmd ".timeout 5000" "$DB" "$1"; }
holder() { sq "SELECT COALESCE(json_extract(metadata,'\$.claimed_by'),'') FROM nodes WHERE id='$1';"; }
node() { as -- add "$1" --standalone --criteria="c1" --risks=low 2>/dev/null | grep -oE 'wv-[a-f0-9]{6}' | head -1; }
as -- init >/dev/null 2>&1

echo "=== a session claims under its own qualified identity ==="
n1=$(node "session claim")
as "${A[@]}" -- work "$n1" >/dev/null 2>&1
[ "$(holder "$n1")" = "$A_ID" ] \
    && ok "claimed_by is claude-<host>-<user>-h<digest16>" || bad "claimed_by is session-qualified" "got: $(holder "$n1")"

echo "=== another session of the same harness does not own it ==="
out=$(as "${B[@]}" -- work "$n1" 2>&1); rc=$?
[ "$rc" != 0 ] && [ "$(holder "$n1")" = "$A_ID" ] \
    && ok "session B cannot claim session A's node without --force" || bad "session B refused" "rc=$rc $out"
mine=$(as "${B[@]}" -- list --status=active --claimed-by=current --json 2>/dev/null | jq 'length')
[ "$mine" = "0" ] && ok "session B's --claimed-by=current does not list A's claim (commit admission)" \
    || bad "session B does not list A's claim" "got: $mine"
mine=$(as "${A[@]}" -- list --status=active --claimed-by=current --json 2>/dev/null | jq 'length')
[ "$mine" = "1" ] && ok "session A lists its own claim" || bad "session A lists its own claim" "got: $mine"

echo "=== an unverifiable session fails closed ==="
n2=$(node "no sid")
out=$(as "${NOSID[@]}" -- work "$n2" 2>&1); rc=$?
[ "$rc" != 0 ] && [ -z "$(holder "$n2")" ] && [[ "$out" == *"cannot verify"* ]] \
    && ok "wv work refuses with no session id and leaves the node unclaimed" || bad "wv work refuses" "rc=$rc $out"
before=$(sq "SELECT COUNT(*) FROM nodes;")
out=$(as "${NOSID[@]}" -- add "should not exist" --status=active --standalone 2>&1); rc=$?
[ "$rc" != 0 ] && [ "$(sq "SELECT COUNT(*) FROM nodes;")" = "$before" ] \
    && ok "wv add --status=active refuses before creating a node" || bad "active add refuses" "rc=$rc $out"
if as "${NOSID[@]}" -- list --status=active --claimed-by=current --json >/dev/null 2>&1; then
    bad "--claimed-by=current fails without a session id (admission reads it as no claim)"
else
    ok "--claimed-by=current fails without a session id (admission reads it as no claim)"
fi
out=$(as "${NOSID[@]}" WV_SESSION_IDENTITY=0 -- work "$n2" 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$(holder "$n2")" = "claude-$HOST-$ME" ] \
    && ok "WV_SESSION_IDENTITY=0 claims actor-owned" || bad "opt-out claims actor-owned" "rc=$rc $out"

echo "=== a pre-session coarse claim needs explicit continuation ==="
n3=$(node "coarse claim")
sq "UPDATE nodes SET status='active', metadata=json_set(metadata,'\$.claimed_by','claude-$HOST-$ME') WHERE id='$n3';"
out=$(as "${A[@]}" -- work "$n3" 2>&1); rc=$?
[ "$rc" != 0 ] && [ "$(holder "$n3")" = "claude-$HOST-$ME" ] \
    && ok "a new session does not inherit a coarse claim automatically" || bad "no automatic adoption" "rc=$rc $out"
out=$(as "${A[@]}" -- work "$n3" --continue 2>&1); rc=$?
hist=$(sq "SELECT json_extract(metadata,'\$.claim_history[0].kind') || '|' || json_extract(metadata,'\$.claim_history[0].from') FROM nodes WHERE id='$n3';")
[ "$rc" = 0 ] && [ "$(holder "$n3")" = "$A_ID" ] && [ "$hist" = "continuation|claude-$HOST-$ME" ] \
    && ok "--continue adopts the actor's own coarse claim and records it" || bad "--continue adopts and records" "rc=$rc hist=$hist $out"

n4=$(node "foreign coarse claim")
sq "UPDATE nodes SET status='active', metadata=json_set(metadata,'\$.claimed_by','codex-$HOST-$ME') WHERE id='$n4';"
out=$(as "${A[@]}" -- work "$n4" --continue 2>&1); rc=$?
[ "$rc" != 0 ] && [ "$(holder "$n4")" = "codex-$HOST-$ME" ] \
    && ok "--continue refuses another actor's claim" || bad "--continue refuses another actor" "rc=$rc $out"
out=$(as "${A[@]}" -- work "$n4" --force 2>&1); rc=$?
hist=$(sq "SELECT json_extract(metadata,'\$.claim_history[0].kind') || '|' || json_extract(metadata,'\$.claim_history[0].from') || '|' || json_extract(metadata,'\$.claim_history[0].to') FROM nodes WHERE id='$n4';")
[ "$rc" = 0 ] && [ "$hist" = "takeover|codex-$HOST-$ME|$A_ID" ] \
    && ok "--force takes over and records from/to" || bad "--force records the takeover" "rc=$rc hist=$hist $out"

echo "=== WV_SESSION_ID is the harness-agnostic channel ==="
n5=$(node "agnostic host")
as WV_SESSION_ID=T-amp-0001 -- work "$n5" >/dev/null 2>&1
[ "$(holder "$n5")" = "human-$HOST-$ME-h$(dig T-amp-0001)" ] \
    && ok "any host qualifies by exporting WV_SESSION_ID" || bad "WV_SESSION_ID qualifies" "got: $(holder "$n5")"
n6=$(node "explicit wins")
as "${A[@]}" WV_AGENT_ID=pinned-agent -- work "$n6" >/dev/null 2>&1
[ "$(holder "$n6")" = "pinned-agent" ] && ok "WV_AGENT_ID wins verbatim" || bad "WV_AGENT_ID wins" "got: $(holder "$n6")"

echo "=== a legacy -s<sid12> claim needs explicit continuation by its own session ==="
n7=$(node "legacy session claim")
sq "UPDATE nodes SET status='active', metadata=json_set(metadata,'\$.claimed_by','$A_LEGACY') WHERE id='$n7';"
out=$(as "${A[@]}" -- work "$n7" 2>&1); rc=$?
[ "$rc" != 0 ] && [ "$(holder "$n7")" = "$A_LEGACY" ] \
    && ok "a session does not inherit its own legacy claim automatically" || bad "no automatic legacy adoption" "rc=$rc $out"
out=$(as "${A[@]}" -- list --status=active --claimed-by=current --json 2>/dev/null | jq --arg n "$n7" '[.[] | select(.id == $n)] | length')
[ "$out" = 0 ] && ok "the legacy claim does not admit the session's commits" || bad "legacy claim not admitted" "got: $out"
n8=$(node "another session's legacy claim")
sq "UPDATE nodes SET status='active', metadata=json_set(metadata,'\$.claimed_by','$B_LEGACY') WHERE id='$n8';"
out=$(as "${A[@]}" -- work "$n8" --continue 2>&1); rc=$?
[ "$rc" != 0 ] && [ "$(holder "$n8")" = "$B_LEGACY" ] \
    && ok "--continue refuses another session's legacy claim" || bad "--continue refuses B's legacy" "rc=$rc $out"
out=$(as "${A[@]}" -- work "$n7" --continue 2>&1); rc=$?
hist=$(sq "SELECT json_extract(metadata,'\$.claim_history[0].kind') || '|' || json_extract(metadata,'\$.claim_history[0].from') FROM nodes WHERE id='$n7';")
[ "$rc" = 0 ] && [ "$(holder "$n7")" = "$A_ID" ] && [ "$hist" = "continuation|$A_LEGACY" ] \
    && ok "--continue adopts this session's own legacy claim and records it" || bad "--continue adopts own legacy" "rc=$rc hist=$hist $out"

echo "=== no working sha256 hasher: ownership is refused, never truncated ==="
n9=$(node "no hasher")
out=$( (cd "$R" && env "${IDVARS[@]}" "${A[@]}" WEAVE_DIR="$R/.weave" WV_HOT_ZONE="$TMP/hot" WV_CONFIG_DIR="$TMP/cfg" \
    bash -c 'source "$1/scripts/lib/wv-resolve-runtime.sh"; sha256sum() { return 1; }; shasum() { return 1; }; require_agent_id' _ "$ROOT") 2>&1 </dev/null); rc=$?
[ "$rc" != 0 ] && [[ "$out" == *"no sha256 hasher"* ]] && [[ "$out" != *"-s"aaaaaaaa* ]] \
    && ok "a failing hasher makes the session unverified, with the cause named" || bad "no-hasher refusal" "rc=$rc $out"

echo "Results: $pass/$run passed"
[ "$pass" = "$run" ]
