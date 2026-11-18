#!/usr/bin/env bash
# Suite-driven wv calls are tagged test so call-stats retro reads can exclude them.
export WV_CALL_SOURCE=test
# Session identity S3 (wv-b2996f): acceptance battery for session-owned
# admission, end to end through the real edit hook (hook dispatch PreToolUse),
# the real git pre-commit hook and the built MCP server. Each case is named as
# in the node; a session is modelled by its id relation, as the S0 probe
# (wv-280f9e) and the 2026-11-04 /clear observation recorded it:
#   1. same-harness sessions A/B: A's claim admits neither B's edit nor B's commit
#   2. resume keeps the session id, so ownership survives a new process;
#      fork (Claude --fork-session, codex fork) gets a new id and does not
#   3. MCP claim then shell commit agrees: in session mode MCP refuses to change
#      ownership (wv-116cbd), including when it was started with another id
#      (Claude --continue, implicit resume); actor-owned, MCP and shell agree.
#      /clear starts a new id: the old claim admits nothing until taken over
#   4. takeover excludes the previous holder from edit, commit and status
#   5. A's phase, primary node and context stamp cannot satisfy B
#   6. the human/unsupported fallback is usable and labelled actor-owned,
#      not session-isolated
set -uo pipefail
export WV_TEST_SUITE=1  # the user's config.env cannot log this suite's wv calls (wv-6b0f57)
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WV="$ROOT/scripts/wv"
MCP_DIST="$ROOT/mcp/dist/index.js"
run=0; pass=0
ok()  { run=$((run+1)); pass=$((pass+1)); echo "  ✓ $1"; }
bad() { run=$((run+1)); echo "  ✗ $1"; [ -n "${2:-}" ] && echo "      $2"; }
TMP=$(mktemp -d /tmp/wv-session-accept-XXXXXX)
trap 'rm -rf "$TMP"' EXIT
R="$TMP/repo"; HOT="$TMP/hot"
mkdir -p "$R" "$TMP/cfg"
# The hooks find wv and their libraries through the project's scripts/. The
# whole checkout scripts/, not a subset: with only some of it, a hook falls back
# to the INSTALLED copy under $HOME, so it would judge with installed code, and
# under the gate's private HOME not at all (wv-a6b930).
ln -s "$ROOT/scripts" "$R/scripts"
git -C "$R" init -q . && git -C "$R" config user.email t@t && git -C "$R" config user.name t
git -C "$R" config commit.gpgsign false
git -C "$R" commit -q --allow-empty -m init
export WV_ATTEMPT_JOURNAL="$TMP/journal.jsonl"
HOST=$(hostname); ME=$(whoami)

# Identity markers are stripped and set per call, whatever session runs this suite.
# WV and WV_CLI too: an inherited one (the gate's suite pool runs under HEAD's
# wv, whose scripts/wv exports WV_CLI) would make the hooks judge with that copy
# instead of the code under test (wv-a6b930).
# AMP_CURRENT_THREAD_ID and PI_SESSION_ID are markers since wv-55a24d: an Amp
# or pi session running this suite would otherwise change who owns what.
IDVARS=(-u WV_AGENT_ID -u CLAUDECODE -u AI_AGENT -u CLAUDE_CODE_SSE_PORT -u CLAUDE_CODE_SESSION_ID -u CODEX_THREAD_ID
    -u CODEX_CI -u COPILOT_AGENT -u WV_SESSION_ID -u WV_SESSION_IDENTITY -u WV_PRIMARY_FILE -u WV_ACTIVE
    -u AMP_CURRENT_THREAD_ID -u PI_SESSION_ID -u WV -u WV_CLI)
FIXENV=(WEAVE_DIR="$R/.weave" WV_HOT_ZONE="$HOT" WV_DB="$HOT/brain.db" WV_CONFIG_DIR="$TMP/cfg"
    WV_PROJECT_DIR="$R" CLAUDE_PROJECT_DIR="$R")
# as <env...> -- <wv args...>: wv as one session. Stdin passes through.
as() {
    local envs=()
    while [ "$1" != "--" ]; do envs+=("$1"); shift; done
    shift
    (cd "$R" && env "${IDVARS[@]}" "${envs[@]}" "${FIXENV[@]}" "$WV" "$@")
}
# commit_as <env...>: run the real pre-commit hook as one session; rc is the hook's.
# The fixture's HEAD holds no committed gate, so the hook takes wv from PATH
# (pre-commit-weave.sh, consumer branch): the checkout's scripts/ go first, or
# admission would be judged by the INSTALLED wv, not the code under test.
commit_as() {
    (cd "$R" && env "${IDVARS[@]}" "$@" "${FIXENV[@]}" PATH="$ROOT/scripts:$PATH" \
        bash "$ROOT/scripts/hooks/pre-commit-weave.sh") </dev/null 2>&1
}
[ "$(cd "$R" && PATH="$ROOT/scripts:$PATH" command -v wv)" = "$ROOT/scripts/wv" ] \
    || { echo "  ✗ the hook would not resolve the checkout's wv"; exit 1; }
# edit_as <payload sid> <env...>: the real edit guard for an Edit of file.txt.
edit_as() {
    local sid="$1"; shift
    jq -cn --arg sid "$sid" --arg f "$R/file.txt" --arg cwd "$R" \
        '{session_id:$sid, cwd:$cwd, hook_event_name:"PreToolUse", tool_name:"Edit",
          tool_input:{file_path:$f, old_string:"a", new_string:"b"}}' \
        | as "$@" -- hook dispatch --event=PreToolUse --format=host 2>&1
}
# mcp_call <tool> <args-json> <env...>: one tools/call to a fresh MCP server.
mcp_call() {
    local tool="$1" args="$2"; shift 2
    printf '%s\n%s\n%s\n' \
        '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"s3","version":"0"}}}' \
        '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
        "$(jq -cn --arg t "$tool" --argjson a "$args" '{jsonrpc:"2.0",id:2,method:"tools/call",params:{name:$t,arguments:$a}}')" \
        | (cd "$R" && env "${IDVARS[@]}" "$@" "${FIXENV[@]}" WV_PATH="$WV" timeout 30 node "$MCP_DIST" --scope=all 2>/dev/null) \
        | jq -rs '[.[] | select(.id==2)][0].result.content[0].text // empty'
}
sq() { sqlite3 -cmd ".timeout 5000" "$HOT/brain.db" "$1"; }
holder() { sq "SELECT COALESCE(json_extract(metadata,'\$.claimed_by'),'') FROM nodes WHERE id='$1';"; }
node() { as -- add "$1" --standalone --criteria="c1" --risks=low </dev/null 2>/dev/null | grep -oE 'wv-[a-f0-9]{6}' | head -1; }
primary_of() { as "$@" -- status </dev/null 2>/dev/null | sed -n 's/^Primary: \(wv-[a-f0-9]*\).*/\1/p'; }
# release <id>: close a node so the next case starts with no active claim.
release() { sq "UPDATE nodes SET status='done' WHERE id='$1';"; }
dig() { printf '%s' "$1" | sha256sum | cut -c1-16; }
owner_of() { printf '%s-%s-%s-h%s' "$1" "$HOST" "$ME" "$(dig "$2")"; }

SID_A=aaaaaaaa-1111-2222-3333-444444444444
SID_B=bbbbbbbb-1111-2222-3333-444444444444
SID_A2=a2a2a2a2-1111-2222-3333-444444444444   # A after /clear or --fork-session
A=(CLAUDECODE=1 "CLAUDE_CODE_SESSION_ID=$SID_A")
B=(CLAUDECODE=1 "CLAUDE_CODE_SESSION_ID=$SID_B")
A2=(CLAUDECODE=1 "CLAUDE_CODE_SESSION_ID=$SID_A2")
HUMAN=()
as -- init </dev/null >/dev/null 2>&1
echo a > "$R/file.txt"
git -C "$R" add file.txt   # a staged non-graph file: the pre-commit hook must decide admission

echo "=== 1. same-harness sessions: A's claim cannot admit B ==="
n1=$(node "case 1")
as "${A[@]}" -- work "$n1" </dev/null >/dev/null 2>&1
[ "$(holder "$n1")" = "$(owner_of claude "$SID_A")" ] && ok "A claims under its session id" \
    || bad "A's claim" "got: $(holder "$n1")"
out=$(edit_as "$SID_B" "${B[@]}"); rc=$?
[ "$rc" = 2 ] && ok "B's edit is refused while only A holds a claim" || bad "B edit refused" "rc=$rc $out"
out=$(commit_as "${B[@]}"); rc=$?
[ "$rc" = 1 ] && [[ "$out" == *"No active Weave node is claimed by $(owner_of claude "$SID_B")"* ]] \
    && ok "B's commit is refused by the pre-commit hook, naming B" || bad "B commit refused" "rc=$rc ${out: -400}"
out=$(edit_as "$SID_A" "${A[@]}"); rc=$?
[ "$rc" = 0 ] && ok "A's own edit is admitted" || bad "A edit admitted" "rc=$rc $out"
out=$(commit_as "${A[@]}"); rc=$?
[ "$rc" = 0 ] && ok "A's own commit is admitted" || bad "A commit admitted" "rc=$rc ${out: -400}"

echo "=== 2. resume preserves ownership; fork does not ==="
# Resume (Claude --resume/--continue, Codex exec resume): a new process, same id.
[ "$(primary_of "${A[@]}")" = "$n1" ] && ok "a resumed Claude session (same id) still reports A's claim as Primary" \
    || bad "resumed Primary" "got: $(primary_of "${A[@]}")"
out=$(as "${A[@]}" -- list --status=active --claimed-by=current --json </dev/null 2>/dev/null | jq -r '.[].id')
[ "$out" = "$n1" ] && ok "a resumed Claude session still owns the claim" || bad "resumed owns" "got: $out"
# Fork (Claude --fork-session observed by S0): a new id is another owner.
out=$(edit_as "$SID_A2" "${A2[@]}"); rc=$?
[ "$rc" = 2 ] && ok "a forked Claude session (new id) is refused A's edit" || bad "fork edit refused" "rc=$rc $out"
out=$(commit_as "${A2[@]}"); rc=$?
[ "$rc" = 1 ] && ok "a forked Claude session is refused A's commit" || bad "fork commit refused" "rc=$rc ${out: -300}"
release "$n1"
# Codex thread ids are UUIDv7 (S0). The fork is created in the SAME millisecond,
# so both ids share their first 12 characters (the timestamp): the session part
# digests the whole id, so they are still two owners (wv-24d57b).
CXID=01a12cd8-e777-7f00-a22c-5bdd105db0ba
CX=(CODEX_CI=1 "CODEX_THREAD_ID=$CXID")
CXF=(CODEX_CI=1 CODEX_THREAD_ID=01a12cd8-e777-7a11-b33c-0123456789ab)
n2=$(node "case 2 codex")
as "${CX[@]}" -- work "$n2" </dev/null >/dev/null 2>&1
[ "$(holder "$n2")" = "$(owner_of codex "$CXID")" ] && ok "a Codex thread claims under its thread id" \
    || bad "Codex claim" "got: $(holder "$n2")"
out=$(commit_as "${CX[@]}"); rc=$?
[ "$rc" = 0 ] && ok "a resumed Codex thread (same thread id) is admitted" || bad "Codex resume admitted" "rc=$rc ${out: -300}"
out=$(commit_as "${CXF[@]}"); rc=$?
[ "$rc" = 1 ] && ok "a forked Codex thread (new thread id, same millisecond) is refused" || bad "Codex fork refused" "rc=$rc ${out: -300}"
release "$n2"
# Amp (wv-e70606): AI_AGENT=amp and AMP_CURRENT_THREAD_ID, observed 2026-11-04.
# Its work of 2026-10-09..22 was recorded as Claude Code's, so these cases pin
# that an Amp thread owns its own claim, also when started from a Claude shell.
AMPID=T-01a1a749-e3b6-723b-bd6c-86427007bbbe
AMP=(AI_AGENT=amp "AMP_CURRENT_THREAD_ID=$AMPID")
AMPO=(AI_AGENT=amp AMP_CURRENT_THREAD_ID=T-01a1a755-4c7b-77b4-9982-053d0b097bbb)
n2a=$(node "case 2 amp")
as "${AMP[@]}" -- work "$n2a" </dev/null >/dev/null 2>&1
[ "$(holder "$n2a")" = "$(owner_of amp "$AMPID")" ] && ok "an Amp thread claims under its thread id" \
    || bad "Amp claim" "got: $(holder "$n2a")"
out=$(commit_as "${AMP[@]}"); rc=$?
[ "$rc" = 0 ] && ok "the same Amp thread is admitted" || bad "Amp same thread admitted" "rc=$rc ${out: -300}"
out=$(commit_as "${AMPO[@]}"); rc=$?
[ "$rc" = 1 ] && ok "another Amp thread is refused" || bad "Amp other thread refused" "rc=$rc ${out: -300}"
release "$n2a"
# Amp started inside a Claude Code shell inherits CLAUDECODE and the Claude
# session id; AI_AGENT, set by the innermost agent, makes the claim Amp's.
AMPC=(CLAUDECODE=1 "CLAUDE_CODE_SESSION_ID=$SID_A" AI_AGENT=amp "AMP_CURRENT_THREAD_ID=$AMPID")
n2b=$(node "case 2 amp inside claude")
as "${AMPC[@]}" -- work "$n2b" </dev/null >/dev/null 2>&1
[ "$(holder "$n2b")" = "$(owner_of amp "$AMPID")" ] && ok "Amp started from a Claude shell owns its own claim" \
    || bad "Amp-in-Claude claim" "got: $(holder "$n2b")"
out=$(commit_as "${A[@]}"); rc=$?
[ "$rc" = 1 ] && ok "the Claude session that launched Amp is refused Amp's commit" || bad "launching Claude refused" "rc=$rc ${out: -300}"
out=$(commit_as "${AMPC[@]}"); rc=$?
[ "$rc" = 0 ] && ok "Amp inside the Claude shell is admitted for its own claim" || bad "Amp-in-Claude admitted" "rc=$rc ${out: -300}"
release "$n2b"
# Without AI_AGENT the thread variable is the fallback marker (wv-55a24d).
n2c=$(node "case 2 amp fallback")
as "AMP_CURRENT_THREAD_ID=$AMPID" -- work "$n2c" </dev/null >/dev/null 2>&1
[ "$(holder "$n2c")" = "$(owner_of amp "$AMPID")" ] && ok "an Amp thread without AI_AGENT still claims as amp" \
    || bad "Amp fallback claim" "got: $(holder "$n2c")"
release "$n2c"

echo "=== 3. MCP claim then shell commit agrees ==="
if [ ! -f "$MCP_DIST" ]; then
    bad "mcp/dist/index.js exists" "run: npm --prefix mcp run build"
else
    n3=$(node "case 3 mcp")
    out=$(mcp_call weave_work "$(jq -cn --arg id "$n3" '{id:$id}')" "${A[@]}")
    [[ "$out" == Error:*"changes ownership"* ]] && [ -z "$(holder "$n3")" ] \
        && ok "session mode: MCP weave_work refuses and leaves the node unclaimed" || bad "MCP refuses" "holder=$(holder "$n3") $out"
    # Claude --continue started the MCP server with another session's id (S0).
    out=$(mcp_call weave_work "$(jq -cn --arg id "$n3" '{id:$id}')" "${A2[@]}")
    [[ "$out" == Error:*"changes ownership"* ]] && [ -z "$(holder "$n3")" ] \
        && ok "implicit resume: an MCP server holding another id cannot claim for the session" \
        || bad "MCP with a stale id refuses" "holder=$(holder "$n3") $out"
    out=$(mcp_call weave_show "$(jq -cn --arg id "$n3" '{id:$id}')" "${A[@]}")
    [[ "$out" == *"$n3"* ]] && [[ "$out" != Error:* ]] && ok "session mode: read-only MCP tools still work" \
        || bad "MCP read works" "${out:0:200}"
    as "${A[@]}" -- work "$n3" </dev/null >/dev/null 2>&1
    out=$(commit_as "${A[@]}"); rc=$?
    [ "$rc" = 0 ] && ok "session mode: the shell claim admits the shell commit" || bad "shell claim admits" "rc=$rc ${out: -300}"
    release "$n3"
    n3b=$(node "case 3 actor-owned")
    out=$(mcp_call weave_work "$(jq -cn --arg id "$n3b" '{id:$id}')" "${A[@]}" WV_SESSION_IDENTITY=0)
    [ "$(holder "$n3b")" = "claude-$HOST-$ME" ] && ok "actor-owned: MCP weave_work claims under the coarse id" \
        || bad "actor-owned MCP claim" "holder=$(holder "$n3b") $out"
    out=$(commit_as "${A2[@]}" WV_SESSION_IDENTITY=0); rc=$?
    [ "$rc" = 0 ] && ok "actor-owned: the MCP claim admits the shell commit, whatever the session id" \
        || bad "actor-owned agreement" "rc=$rc ${out: -300}"
    release "$n3b"
fi
# /clear (observed on Claude Code 2.1.318): the shell and the hook payload both
# carry the NEW id, so the pre-clear claim is the previous session's.
n3c=$(node "case 3 clear")
as "${A[@]}" -- work "$n3c" </dev/null >/dev/null 2>&1
out=$(edit_as "$SID_A2" CLAUDECODE=1); rc=$?
[ "$rc" = 2 ] && ok "/clear: a hook given the new payload id is refused the pre-clear claim's edit" \
    || bad "/clear hook refused" "rc=$rc $out"
out=$(commit_as "${A2[@]}"); rc=$?
[ "$rc" = 1 ] && ok "/clear: the cleared session's commit is refused" || bad "/clear commit refused" "rc=$rc ${out: -300}"
out=$(as "${A2[@]}" -- work "$n3c" --continue </dev/null 2>&1); rc=$?
[ "$rc" != 0 ] && [ "$(holder "$n3c")" = "$(owner_of claude "$SID_A")" ] \
    && ok "/clear: --continue does not adopt the previous session's claim" || bad "/clear --continue refused" "rc=$rc $out"
as "${A2[@]}" -- work "$n3c" --force </dev/null >/dev/null 2>&1
out=$(commit_as "${A2[@]}"); rc=$?
[ "$rc" = 0 ] && ok "/clear: after wv work --force the cleared session is admitted" || bad "/clear takeover admits" "rc=$rc ${out: -300}"
release "$n3c"

echo "=== 4. takeover excludes the previous holder ==="
n4=$(node "case 4")
as "${A[@]}" -- work "$n4" </dev/null >/dev/null 2>&1
edit_as "$SID_A" "${A[@]}" >/dev/null   # A has a context stamp and a primary for n4
as "${B[@]}" -- work "$n4" --force </dev/null >/dev/null 2>&1
hist=$(sq "SELECT json_extract(metadata,'\$.claim_history[0].kind') || '|' || json_extract(metadata,'\$.claim_history[0].from') FROM nodes WHERE id='$n4';")
[ "$(holder "$n4")" = "$(owner_of claude "$SID_B")" ] && [ "$hist" = "takeover|$(owner_of claude "$SID_A")" ] \
    && ok "B's takeover is recorded from A" || bad "takeover recorded" "holder=$(holder "$n4") hist=$hist"
out=$(edit_as "$SID_A" "${A[@]}"); rc=$?
[ "$rc" = 2 ] && ok "A's edit is refused after the takeover, despite A's stamp" || bad "A edit refused" "rc=$rc $out"
out=$(commit_as "${A[@]}"); rc=$?
[ "$rc" = 1 ] && ok "A's commit is refused after the takeover" || bad "A commit refused" "rc=$rc ${out: -300}"
[ -z "$(primary_of "${A[@]}")" ] && ok "A's status no longer reports the node, despite A's primary file" \
    || bad "A Primary cleared" "got: $(primary_of "${A[@]}")"
out=$(commit_as "${B[@]}"); rc=$?
[ "$rc" = 0 ] && ok "B's commit is admitted after the takeover" || bad "B commit admitted" "rc=$rc ${out: -300}"
release "$n4"

echo "=== 5. A's phase, primary node and context stamp cannot satisfy B ==="
n5=$(node "case 5")
as "${A[@]}" -- work "$n5" </dev/null >/dev/null 2>&1
edit_as "$SID_A" "${A[@]}" >/dev/null
OA="$HOT/owners/$(owner_of claude "$SID_A")"; OB="$HOT/owners/$(owner_of claude "$SID_B")"
[ -e "$OA/.context_checked_$n5" ] && [ "$(cat "$OA/primary" 2>/dev/null)" = "$n5" ] \
    && [ "$(cat "$OA/.session_phase" 2>/dev/null)" = execute ] \
    && ok "A holds a stamp, a primary and an execute phase for its node" || bad "A's state" "$(ls -a "$OA" 2>&1)"
[ -z "$(primary_of "${B[@]}")" ] && ok "A's primary is not B's" || bad "B has no Primary" "got: $(primary_of "${B[@]}")"
out=$(edit_as "$SID_B" "${B[@]}"); rc=$?
[ "$rc" = 2 ] && [ ! -e "$OB/.context_checked_$n5" ] \
    && ok "A's stamp and phase do not admit B's edit, and B gets no stamp" || bad "B not satisfied" "rc=$rc $out"
out=$(commit_as "${B[@]}"); rc=$?
[ "$rc" = 1 ] && ok "A's state does not admit B's commit" || bad "B commit refused" "rc=$rc ${out: -300}"
release "$n5"

echo "=== 6. the human/unsupported fallback is usable and honestly labelled ==="
n6=$(node "case 6")
out=$(as "${HUMAN[@]}" -- work "$n6" </dev/null 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$(holder "$n6")" = "human-$HOST-$ME" ] && ok "a human shell claims actor-owned" \
    || bad "human claim" "rc=$rc holder=$(holder "$n6") $out"
[[ "$out" == *"actor-owned, not session-isolated"* ]] && ok "wv work labels the claim actor-owned, not session-isolated" \
    || bad "human label" "$out"
out=$(commit_as "${HUMAN[@]}"); rc=$?
[ "$rc" = 0 ] && ok "the human's commit is admitted" || bad "human commit" "rc=$rc ${out: -300}"
out=$(as "${HUMAN[@]}" -- list --status=active --claimed-by=current --json </dev/null 2>/dev/null | jq -r '.[].id')
[ "$out" = "$n6" ] && ok "a second human shell shares the claim (which is what the label says)" || bad "shared" "got: $out"
release "$n6"
n6b=$(node "case 6 unsupported")
out=$(as WV_SESSION_IDENTITY=0 "${A[@]}" -- work "$n6b" --json </dev/null 2>/dev/null)
[ "$(jq -r '.ownership' <<<"$out" 2>/dev/null)" = actor ] && [ "$(jq -r '.claimed_by' <<<"$out")" = "claude-$HOST-$ME" ] \
    && ok "WV_SESSION_IDENTITY=0: --json reports ownership actor" || bad "opt-out json" "$out"
release "$n6b"
n6c=$(node "case 6 session")
out=$(as "${A[@]}" -- work "$n6c" </dev/null 2>&1)
[[ "$out" != *"actor-owned"* ]] && ok "a session-owned claim carries no actor-owned label" || bad "no label in session mode" "$out"
out=$(as "${B[@]}" -- work "$n6c" --force --json </dev/null 2>/dev/null)
[ "$(jq -r '.ownership' <<<"$out" 2>/dev/null)" = session ] && ok "a session claim's --json reports ownership session" \
    || bad "session json" "$out"

echo "Results: $pass/$run passed"
[ "$pass" = "$run" ]
