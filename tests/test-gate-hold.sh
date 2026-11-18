#!/usr/bin/env bash
# Suite-driven wv calls are tagged test so call-stats retro reads can exclude them.
export WV_CALL_SOURCE=test
# scripts/lib/wv-gate-hold.sh (wv-c5500d): one gate at a time per checkout.
# A second gate on the same checkout must refuse within a second, naming the
# holder, under every harness identity (claude, codex, pi, amp, copilot with and
# without WV_SESSION_ID, human, WV_AGENT_ID), worded by identity: the same
# session is told its earlier gate still runs; anyone else is told who holds it
# and to wait. A dead holder never leaves a stale lock, with flock or with the
# mkdir fallback, including a pid reused by another process. A linked worktree
# has its own lock. Readers see a live holder only, and the last push's outcome,
# with a running push whose gate died read as interrupted.
set -uo pipefail
export WV_TEST_SUITE=1
ROOT=$(cd "$(dirname "$0")/.." && pwd)
LIB="$ROOT/scripts/lib/wv-gate-hold.sh"
run=0 pass=0
ok()  { run=$((run+1)); pass=$((pass+1)); echo "  ✓ $1"; }
bad() { run=$((run+1)); echo "  ✗ $1"; [ -n "${2:-}" ] && echo "      $2"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2], got [$3]"; fi; }
has()   { if grep -qF -- "$3" <<< "$2"; then ok "$1"; else bad "$1" "missing [$3] in: $2"; fi; }
hasnt() { if grep -qF -- "$3" <<< "$2"; then bad "$1" "unexpected [$3] in: $2"; else ok "$1"; fi; }

T=$(mktemp -d "${TMPDIR:-/tmp}/wv-gate-hold-XXXXXX")
pids=()
cleanup() { local p; for p in ${pids[@]+"${pids[@]}"}; do pkill -9 -P "$p" 2>/dev/null; kill -9 "$p" 2>/dev/null; done; rm -rf "$T"; }
trap cleanup EXIT
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
R="$T/repo"
git init -q "$R" && git -C "$R" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m init

# in_env <env assignments...> -- <script> — run <script> with the library
# loaded, from the scratch checkout, in an environment holding only the named
# harness markers (this suite's own session markers must not leak in).
in_env() {
    local -a vars=()
    while [ "$1" != -- ]; do vars+=("$1"); shift; done
    shift
    (cd "$R" && exec env -i PATH="$PATH" HOME="$HOME" TMPDIR="${TMPDIR:-/tmp}" ${vars[@]+"${vars[@]}"} \
        bash -c ". '$LIB'; $1")
}
# hold <env...> — start a holder in the background; waits until it holds.
hold() {
    rm -f "$T/ready"
    # The holder names its own pid: \$! would be a wrapper subshell's.
    in_env "$@" -- "wv_gate_hold_acquire pre-push 'refs/heads/main' && echo \$\$ > '$T/ready.tmp' && mv '$T/ready.tmp' '$T/ready' && sleep 60" &
    pids+=("$!")
    local i=0
    while [ ! -f "$T/ready" ] && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i+1)); done
    HOLDER=$(cat "$T/ready" 2>/dev/null); pids+=("$HOLDER")
}
# drop — end the holder and everything it started (a gate's children inherit
# its lock descriptor, so killing the shell alone leaves the lock held).
drop() {
    local i=0
    pkill -9 -P "$HOLDER" 2>/dev/null; kill -9 "$HOLDER" 2>/dev/null
    while kill -0 "$HOLDER" 2>/dev/null && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i+1)); done
    sleep 0.1
}
# contend <env...> — a second gate's attempt; sets OUT, RC and MS.
contend() {
    local t0 t1
    t0=$(date +%s%N)
    OUT=$(in_env "$@" -- "wv_gate_hold_acquire pre-commit 'the staged change'" 2>&1); RC=$?
    t1=$(date +%s%N)
    MS=$(( (t1 - t0) / 1000000 ))
}
idof() { in_env "$@" -- ". '$ROOT/scripts/lib/wv-resolve-runtime.sh'; resolve_agent_id" 2>/dev/null; }

echo "control"
contend
check "(control) a free checkout is taken" "0" "$RC"
hasnt "...silently" "$OUT" "✗"

echo "harness matrix: the second gate always refuses, labelled by the holder"
matrix=(
    "claude|CLAUDECODE=1 CLAUDE_CODE_SESSION_ID=sess-claude-1|session"
    "codex|CODEX_THREAD_ID=thread-codex-1|session"
    "pi|AI_AGENT=pi PI_SESSION_ID=sess-pi-1|session"
    "amp|AI_AGENT=amp AMP_CURRENT_THREAD_ID=thread-amp-1|session"
    "copilot, no WV_SESSION_ID|COPILOT_AGENT=1|actor"
    "copilot, WV_SESSION_ID|COPILOT_AGENT=1 WV_SESSION_ID=sess-copilot-1|session"
    "human|WV_HOLD_TEST=1|actor"
    "WV_AGENT_ID|WV_AGENT_ID=custom-agent-7|actor"
)
for row in "${matrix[@]}"; do
    IFS='|' read -r name envs mode <<< "$row"
    read -ra ev <<< "$envs"
    hid=$(idof "${ev[@]}")
    hold "${ev[@]}"
    contend "${ev[@]}"
    check "$name: the same identity's second gate refuses" "1" "$RC"
    if [ "$MS" -lt 1000 ]; then ok "...within a second (${MS}ms)"; else bad "...within a second" "took ${MS}ms"; fi
    if [ "$mode" = session ]; then
        has "...told its earlier gate still runs" "$OUT" "your earlier pre-push gate is still running"
    else
        has "...an actor-owned identity is told who holds it ($hid)" "$OUT" "gate held by $hid"
    fi
    has "...naming the holder's pid" "$OUT" "pid $HOLDER"
    has "...and what it gates" "$OUT" "refs/heads/main"
    contend WV_AGENT_ID=other-owner
    check "$name: another owner's gate refuses" "1" "$RC"
    has "...labelled with the holder ($hid)" "$OUT" "gate held by $hid"
    has "...told to wait, not to stop it" "$OUT" "Do not stop a gate another owner started"
    drop
done
contend CLAUDECODE=1 CLAUDE_CODE_SESSION_ID=sess-claude-1
check "with every holder gone, the checkout is free again" "0" "$RC"

echo "a different session of the same harness is another owner"
hold CLAUDECODE=1 CLAUDE_CODE_SESSION_ID=sess-before-restart
contend CLAUDECODE=1 CLAUDE_CODE_SESSION_ID=sess-after-restart
check "a restarted session (new session id) is refused" "1" "$RC"
has "...as another session's gate" "$OUT" "Do not stop a gate another owner started"
echo "readers"
st=$(in_env -- "wv_gate_hold_status")
check "status names the live holder" "$HOLDER" "$(jq -r '.pid' <<< "$st" 2>/dev/null)"
check "...and its kind" "pre-push" "$(jq -r '.kind' <<< "$st" 2>/dev/null)"
drop
check "status is empty once the holder died (flock left no lock)" "" "$(in_env -- "wv_gate_hold_status")"
contend
check "...and the next gate takes it" "0" "$RC"

echo "a gate that died while its suites run"
hold
kids=$(pgrep -P "$HOLDER" | tr '\n' ' ')
kill -9 "$HOLDER" 2>/dev/null; i=0; while kill -0 "$HOLDER" 2>/dev/null && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i+1)); done
contend
check "suites still running after their gate died keep the checkout" "1" "$RC"
has "...and the refusal says the gate is gone but its processes hold it" "$OUT" "is gone, but processes it started still hold this checkout"
check "...while readers report no live gate" "" "$(in_env -- "wv_gate_hold_status")"
# shellcheck disable=SC2086  # one pid per word
kill -9 $kids 2>/dev/null; sleep 0.2
contend
check "once they exit, the checkout is free" "0" "$RC"

echo "mkdir fallback (no flock)"
hold WV_GATE_HOLD_NO_FLOCK=1
contend WV_GATE_HOLD_NO_FLOCK=1
check "a second gate refuses" "1" "$RC"
has "...naming the holder" "$OUT" "pid $HOLDER"
drop
contend WV_GATE_HOLD_NO_FLOCK=1
check "a dead holder's lock directory is cleared and taken" "0" "$RC"
lockd="$(cd "$R" && git rev-parse --absolute-git-dir)/weave-gate.lock.d"
contend WV_GATE_HOLD_NO_FLOCK=1
check "...and one left by a gate that exited without releasing is cleared too" "0" "$RC"
mkdir -p "$lockd"
jq -cn --arg p "$$" '{kind:"pre-push", pid:($p | tonumber), start:"Thu Jan  1 00:00:00 1970", agent_id:"ghost"}' > "$lockd/holder.json"
contend WV_GATE_HOLD_NO_FLOCK=1
check "a holder whose pid now names another process is cleared" "0" "$RC"
in_env WV_GATE_HOLD_NO_FLOCK=1 -- "wv_gate_hold_acquire pre-commit x && wv_gate_hold_release" >/dev/null 2>&1
check "release removes the lock directory" "no" "$([ -d "$lockd" ] && echo yes || echo no)"

echo "linked worktree"
git -C "$R" worktree add -q --detach "$T/wt" HEAD
hold
OUT=$(cd "$T/wt" && env -i PATH="$PATH" HOME="$HOME" bash -c ". '$LIB'; wv_gate_hold_acquire pre-commit x" 2>&1); RC=$?
check "a linked worktree has its own lock" "0" "$RC"
# wv-8abb6a: a gate holding another worktree of the repository.
fst=$(cd "$T/wt" && env -i PATH="$PATH" HOME="$HOME" bash -c ". '$LIB'; wv_gate_hold_foreign_status")
check "the linked worktree sees the main worktree's live gate as foreign" "$HOLDER" "$(jq -r '.pid' <<< "$fst" 2>/dev/null)"
check "...while the main worktree does not count its own gate as foreign" "" "$(in_env -- "wv_gate_hold_foreign_status")"
drop
check "a dead holder's record in another worktree reads as nothing" "" \
    "$(cd "$T/wt" && env -i PATH="$PATH" HOME="$HOME" bash -c ". '$LIB'; wv_gate_hold_foreign_status")"
rm -f "$T/ready"
(cd "$T/wt" && exec env -i PATH="$PATH" HOME="$HOME" bash -c ". '$LIB'; wv_gate_hold_acquire pre-push x && echo \$\$ > '$T/ready.tmp' && mv '$T/ready.tmp' '$T/ready' && sleep 60") &
pids+=("$!")
i=0; while [ ! -f "$T/ready" ] && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i+1)); done
HOLDER=$(cat "$T/ready" 2>/dev/null); pids+=("$HOLDER")
check "the main worktree sees a linked worktree's live gate as foreign" "$HOLDER" "$(in_env -- "wv_gate_hold_foreign_status" | jq -r '.pid' 2>/dev/null)"
check "...and the linked worktree does not count its own" "" \
    "$(cd "$T/wt" && env -i PATH="$PATH" HOME="$HOME" bash -c ". '$LIB'; wv_gate_hold_foreign_status")"
drop
wtrec="$(git -C "$R" rev-parse --path-format=absolute --git-common-dir)/worktrees/wt/weave-gate.holder.json"
jq -cn --arg p "$$" '{kind:"pre-push", pid:($p | tonumber), start:"Thu Jan  1 00:00:00 1970", agent_id:"ghost"}' > "$wtrec"
check "a foreign record whose pid now names another process reads as nothing" "" "$(in_env -- "wv_gate_hold_foreign_status")"
rm -f "$wtrec"

echo "last push outcome"
rm -f "$T/ready"
in_env -- "wv_gate_push_outcome running 'refs/heads/main 1234567'; echo \$\$ > '$T/ready.tmp'; mv '$T/ready.tmp' '$T/ready'; sleep 60" &
pids+=("$!")
i=0; while [ ! -f "$T/ready" ] && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i+1)); done
HOLDER=$(cat "$T/ready" 2>/dev/null); pids+=("$HOLDER")
check "a push in flight reads as running" "running" "$(in_env -- "wv_gate_push_last" | jq -r '.state')"
drop
check "...and as interrupted once its gate died" "interrupted" "$(in_env -- "wv_gate_push_last" | jq -r '.state')"
in_env -- "wv_gate_push_outcome running 'refs/heads/main 89abcde'; wv_gate_push_outcome failed 'tests/test-hooks.sh' 1"
last=$(in_env -- "wv_gate_push_last")
check "a failed push names its state" "failed" "$(jq -r '.state' <<< "$last")"
check "...the failing suite" "tests/test-hooks.sh" "$(jq -r '.detail' <<< "$last")"
check "...and the exit code" "1" "$(jq -r '.exit' <<< "$last")"
in_env -- "wv_gate_push_outcome running x; wv_gate_push_outcome passed '' 0"
check "a passed push reads as passed" "passed" "$(in_env -- "wv_gate_push_last" | jq -r '.state')"

echo "outside a checkout"
OUT=$(cd "$T" && env -i PATH="$PATH" HOME="$HOME" GIT_CEILING_DIRECTORIES="$T" bash -c ". '$LIB'; wv_gate_hold_acquire pre-commit x" 2>&1); RC=$?
check "no checkout, nothing to hold: passes" "0" "$RC"

echo "Results: $pass/$run passed"
[ "$pass" -eq "$run" ]
