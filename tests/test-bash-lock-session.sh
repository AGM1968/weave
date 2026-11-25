#!/usr/bin/env bash
# The duplicate-command lock is per session (wv-da7c28). Two sessions on one
# repository run their hooks from the same project directory; a lock keyed on
# the repository alone let one session's running commit deny the other's, with
# a "wait for the task-notification" the denied session never receives. This
# suite drives the checkout's hooks with two session ids and asserts: the same
# command in two sessions is allowed in both, an identical retry within one
# session is still denied, a release or session start touches only its own
# session's locks, and a call naming no session keeps the shared lock and says so.
export WV_CALL_SOURCE=test
set -uo pipefail
export WV_TEST_SUITE=1
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# The product's md5sum (wv-resolve-runtime.sh, side-effect free): the repo hash a
# product path is keyed on, the same on macOS, which has no md5sum(1) (wv-ef5621).
# shellcheck disable=SC1091  # resolved at run time
source "$ROOT/scripts/lib/wv-resolve-runtime.sh"
WV="$ROOT/scripts/wv"
HOOKS="$ROOT/.claude/hooks"
run=0; pass=0
ok()  { run=$((run+1)); pass=$((pass+1)); echo "  ✓ $1"; }
bad() { run=$((run+1)); echo "  ✗ $1"; [ -n "${2:-}" ] && echo "      $2"; }
TMP=$(cd "$(mktemp -d /tmp/wv-lock-session-XXXXXX)" && pwd -P)
P="$TMP/project"
# The hooks' own lock directory for $P, set once $P is a repository (wv-b3cb72).
# shellcheck source=tests/lib/dedup-locks.sh
. "$ROOT/tests/lib/dedup-locks.sh"
LOCKS=""
trap 'rm -rf "$TMP"; [ -z "$LOCKS" ] || rm -rf "$LOCKS"' EXIT
export WV_HOT_ZONE="$TMP/hot" WV_DB="$TMP/hot/brain.db" WV_CONFIG_DIR="$TMP/config"
export CLAUDE_PROJECT_DIR="$P" WV_PROJECT_DIR="$P"
export WV_AGENT_ID=test-bash-lock-session-agent
unset WV_SESSION_ID
mkdir -p "$P" "$WV_HOT_ZONE" "$WV_CONFIG_DIR"
cd "$P" || exit 1
git init -q . && git config user.email t@t && git config user.name t && git config commit.gpgsign false
LOCKS=$(dedup_lock_dir "$P") || { echo "fixture: no dedup lock directory for $P"; exit 1; }
"$WV" init >/dev/null 2>&1
git add -A >/dev/null 2>&1; git commit -q -m initial --allow-empty

echo "=== duplicate-command lock per session (wv-da7c28) ==="

# pre <session|-> <command> -> the hook's stdout. "-" sends no session id.
pre() {
    local payload
    if [ "$1" = - ]; then
        payload=$(jq -cn --arg c "$2" --arg cwd "$P" '{tool_name:"Bash",tool_input:{command:$c},cwd:$cwd}')
    else
        payload=$(jq -cn --arg s "$1" --arg c "$2" --arg cwd "$P" '{session_id:$s,tool_name:"Bash",tool_input:{command:$c},cwd:$cwd}')
    fi
    printf '%s' "$payload" | bash "$HOOKS/bash-dedup.sh" 2>/dev/null
}
post() {  # post <session> <command>: a foreground completion
    jq -cn --arg s "$1" --arg c "$2" --arg cwd "$P" \
        '{session_id:$s,tool_name:"Bash",tool_input:{command:$c,run_in_background:false},tool_response:{output:"done",success:true},cwd:$cwd}' \
        | bash "$HOOKS/bash-dedup-post.sh" >/dev/null 2>&1
}
denied() { grep -q '"deny"' <<< "$1"; }
reason() { jq -r '.hookSpecificOutput.permissionDecisionReason // empty' <<< "$1" 2>/dev/null; }

out=$(pre sess-A "wv sync --gh")
denied "$out" && bad "session A's first sync is allowed" "$out" || ok "session A's first sync is allowed"
[ -f "$LOCKS/s-sess-A/wv-sync.lock" ] && ok "the lock is in session A's own directory" \
    || bad "the lock is in session A's own directory" "$(ls -R "$LOCKS" 2>&1 | tr '\n' ' ')"

out=$(pre sess-B "wv sync --gh")
denied "$out" && bad "the same command in session B is allowed while A's runs" "$(reason "$out")" \
    || ok "the same command in session B is allowed while A's runs"

out=$(pre sess-A "wv sync --gh")
if denied "$out"; then ok "an identical retry within session A is still denied"; else bad "an identical retry within session A is still denied" "$out"; fi
# Inside the spawn window the deny says the call is not seen running yet; a
# running lock is what promises a notification, so seed one for the wording.
printf '%s\nrunning\nwv sync --gh\n\n' "$(date +%s)" > "$LOCKS/s-sess-A/wv-sync.lock"
r=$(reason "$(pre sess-A "wv sync --gh")")
case "$r" in *"names no session"*) bad "a session's own deny does not call the lock shared" "$r" ;;
    *"wait for the task-notification"*) ok "a session's own deny tells it to wait for its notification" ;;
    *) bad "a session's own deny tells it to wait for its notification" "$r" ;; esac

post sess-A "wv sync --gh"
[ ! -f "$LOCKS/s-sess-A/wv-sync.lock" ] && [ -f "$LOCKS/s-sess-B/wv-sync.lock" ] \
    && ok "session A's completion releases only A's lock" \
    || bad "session A's completion releases only A's lock" "$(ls -R "$LOCKS" 2>&1 | tr '\n' ' ')"

# The busy-wait guard reads only the caller's session: B's running make does
# not make A's legitimate wait loop a poller.
mkdir -p "$LOCKS/s-sess-B"
printf '%s\nrunning\nmake check\n\n' "$(date +%s)" > "$LOCKS/s-sess-B/make-build.lock"
loop='until [ -f /tmp/none ]; do sleep 1; done'
out=$(pre sess-A "$loop")
denied "$out" && bad "session B's running make does not deny session A's wait loop" "$(reason "$out")" \
    || ok "session B's running make does not deny session A's wait loop"
out=$(pre sess-B "$loop")
denied "$out" && ok "session B's own wait loop on its running make is denied" \
    || bad "session B's own wait loop on its running make is denied" "$out"

# A session start clears only its own orphans; another session's fresh lock
# survives, and a lock older than every lock lifetime is pruned.
mkdir -p "$LOCKS/s-sess-C" "$LOCKS/s-sess-old"
printf '%s\npending\nwv sync\n' "$(date +%s)" > "$LOCKS/s-sess-C/wv-sync.lock"
printf '%s\npending\nwv sync\n' "$(date +%s)" > "$LOCKS/s-sess-old/wv-sync.lock"
python3 -I -c 'import os, sys; t = float(sys.argv[1]); os.utime(sys.argv[2], (t, t))' "$(( $(date +%s) - 7200 ))" "$LOCKS/s-sess-old/wv-sync.lock"  # touch -d is GNU-only (wv-f6b909)
jq -cn --arg cwd "$P" '{session_id:"sess-B",hook_event_name:"SessionStart",source:"startup",cwd:$cwd}' \
    | "$WV" hook dispatch --event=SessionStart --format=host >/dev/null 2>&1
[ ! -e "$LOCKS/s-sess-B/make-build.lock" ] && ok "session B's start clears B's orphaned locks" \
    || bad "session B's start clears B's orphaned locks" "$(ls -R "$LOCKS" 2>&1 | tr '\n' ' ')"
[ -f "$LOCKS/s-sess-C/wv-sync.lock" ] && ok "session B's start leaves live session C's lock" \
    || bad "session B's start leaves live session C's lock"
[ ! -e "$LOCKS/s-sess-old" ] && ok "a session directory whose locks outlived every lifetime is pruned" \
    || bad "a session directory whose locks outlived every lifetime is pruned" "$(ls -R "$LOCKS/s-sess-old" 2>&1 | tr '\n' ' ')"

# A call naming no session keeps the repository's shared lock, and its deny
# does not promise a notification the caller may never receive.
out=$(pre - "git push origin main")
denied "$out" && bad "a sessionless first push is allowed" "$out" || ok "a sessionless first push is allowed"
[ -f "$LOCKS/git-push.lock" ] && ok "a sessionless call uses the repository's shared lock" \
    || bad "a sessionless call uses the repository's shared lock"
out=$(pre - "git push origin main")
denied "$out" && ok "a sessionless identical retry is denied" || bad "a sessionless identical retry is denied" "$out"
printf '%s\nrunning\ngit push origin main\n\n' "$(date +%s)" > "$LOCKS/git-push.lock"
out=$(pre - "git push origin main")
r=$(reason "$out")
if denied "$out" && [[ "$r" == *"names no session"* ]]; then
    ok "a sessionless duplicate is denied and the deny says the lock is shared"
else
    bad "a sessionless duplicate is denied and the deny says the lock is shared" "$out"
fi

echo ""
echo "Results: $pass/$run passed"
[ "$pass" -eq "$run" ]
