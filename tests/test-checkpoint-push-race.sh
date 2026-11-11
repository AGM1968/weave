#!/usr/bin/env bash
# "done" is an argument to the wv helpers below, never the loop keyword.
# shellcheck disable=SC1010
# Suite-driven wv calls are tagged test so call-stats retro reads can exclude them.
export WV_CALL_SOURCE=test
# A checkpoint never rewrites a commit a push is publishing (wv-13db30).
#
# The checkpoint writers amend HEAD when it is an unpushed graph-only
# checkpoint, judged against origin/<branch>, which moves only when a push
# completes. The pre-push gate runs for minutes first, so a checkpoint in that
# window amended the commit being pushed: the push published the old commit and
# main was left on an amended sibling, diverged. Reproduced here with a real
# git push whose heavy-tier suite blocks until released, and a wv sync (which
# runs auto_checkpoint and the sync commit) while it waits.
set -uo pipefail
export WV_TEST_SUITE=1  # the user's config.env cannot log this suite's wv calls (wv-6b0f57)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOKS="$ROOT/scripts/hooks"
run=0; pass=0
ok()  { run=$((run+1)); pass=$((pass+1)); echo "  ✓ $1"; }
bad() { run=$((run+1)); echo "  ✗ $1"; [ -n "${2:-}" ] && echo "      $2"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$3] got [$2]"; fi; }

T=$(mktemp -d /tmp/wv-checkpoint-push-race-XXXXXX)
PUSH_PID=""
trap '[ -n "$PUSH_PID" ] && kill "$PUSH_PID" 2>/dev/null; rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/cfg" "$T/marks" "$T/hooks"
ln -s "$ROOT/scripts/wv" "$T/bin/wv"
export PATH="$T/bin:$PATH" WV_LIB_DIR="$ROOT/scripts"
export WV_HOT_ZONE="$T/hot" WV_DB="$T/hot/brain.db" WV_CONFIG_DIR="$T/cfg" WV_PROJECT_DIR="$T/work"
export WV_SUITE_LOG="$T/suite_runs.jsonl" WV_GATE_LOG="$T/gate_runs.jsonl"
export WV_AUTO_SYNC=0 WV_AUTO_CHECKPOINT=0 WV_REQUIRE_LEARNING=0 WV_RUN_CACHE=0
unset WV_GATE_PHASE WV_GATE_ID WV_GATE_CONTEXT WV_HOOK_REEXEC WV_PUSH_INFLIGHT_TTL
# The commit gate injects core.hooksPath=/dev/null through GIT_CONFIG_*; this
# suite's subject is a hook, so the fixture states its own git config.
unset GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0 GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
MARK="$T/marks"

git init -q --bare "$T/remote.git"
git init -q -b main "$T/work"
cd "$T/work" || exit 1
git config user.name "Race Test"; git config user.email race@example.com; git config commit.gpgsign false
git remote add origin "$T/remote.git"
mkdir -p src tests .weave
# The heavy suite announces it is running, then holds the push open until released.
printf '#!/bin/sh\ntouch "%s/started"\ni=0\nwhile [ ! -f "%s/release" ] && [ "$i" -lt 600 ]; do sleep 0.1; i=$((i+1)); done\nexit 0\n' \
    "$MARK" "$MARK" > tests/test-heavy.sh
chmod +x tests/test-heavy.sh
printf '[map]\nsrc/a.sh = tests/test-heavy.sh\ntests/test-heavy.sh = tests/test-heavy.sh\n[heavy]\ntests/test-heavy.sh\n' > .weave/test-map.conf
printf '#!/bin/sh\necho a\n' > src/a.sh
git add -A && git -c core.hooksPath=/dev/null commit -q -m "fixture"
git -c core.hooksPath=/dev/null push -q -u origin main 2>/dev/null
# A repository with a remote must be classified before wv init writes to it.
wv repo-class set owned --acknowledge-upstream-fork >/dev/null 2>&1
wv init >/dev/null 2>&1
[ -d .weave ] || { echo "  ✗ fixture: wv init did not initialise the graph"; exit 1; }
printf '#!/bin/sh\nexec bash %q "$@"\n' "$HOOKS/pre-push-weave.sh" > "$T/hooks/pre-push"
chmod +x "$T/hooks/pre-push"
git config core.hooksPath "$T/hooks"

# checkpoint <message> — a graph-only checkpoint commit, as the writers make one
checkpoint() {
    printf '{"probe":"%s"}\n' "$RANDOM$RANDOM" >> .weave/probe.jsonl
    git add -f .weave/probe.jsonl && git -c core.hooksPath=/dev/null commit -q -m "chore(weave): $1"
}
# graph_write — a real graph change for the next sync to dump and commit
graph_write() { wv add "race probe $RANDOM" --standalone >/dev/null 2>&1; }
sync_checkpoint() { WV_AUTO_CHECKPOINT=1 WV_CHECKPOINT_INTERVAL=0 wv sync >/dev/null 2>&1; }

echo "=== a checkpoint during a push leaves main on the pushed commit ==="
printf '#!/bin/sh\necho a2\n' > src/a.sh
git add -A && git -c core.hooksPath=/dev/null commit -q -m "work owing the heavy tier"
# The unpushed graph-only checkpoint the push will carry. WV_AUTO_CHECKPOINT=0
# (exported above) now stops sync's own commit too (wv-fbbdff), so this goes
# through sync_checkpoint; either checkpoint writer's subject is the same kind.
graph_write; sync_checkpoint
pushed=$(git rev-parse HEAD)
# Without these the race below would pass vacuously: no checkpoint, nothing to amend.
check "the push carries a graph-only checkpoint at its tip" "$(git log -1 --format=%s | grep -cE 'sync state|auto-checkpoint')" "1"
check "and that checkpoint holds the dumped graph" "$(git ls-files .weave/nodes.jsonl)" ".weave/nodes.jsonl"
rm -f "$MARK/started" "$MARK/release"
git push -q origin main > "$T/push.log" 2>&1 &
PUSH_PID=$!
for _ in $(seq 1 600); do [ -f "$MARK/started" ] && break; sleep 0.1; done
[ -f "$MARK/started" ] && ok "the push is held in its heavy tier" || bad "the push is held in its heavy tier" "$(tail -5 "$T/push.log")"
graph_write; sync_checkpoint                  # a checkpoint while the push is in flight
check "the in-flight checkpoint did not rewrite the pushed commit" \
    "$(git merge-base --is-ancestor "$pushed" HEAD && echo kept || echo rewritten)" "kept"
touch "$MARK/release"
wait "$PUSH_PID"; push_rc=$?; PUSH_PID=""
check "the push completes" "$push_rc" "0"
check "the remote holds the commit the push carried" "$(git rev-parse origin/main)" "$pushed"
git fetch -q origin 2>/dev/null
check "main continues from what was published (no divergence)" \
    "$(git merge-base --is-ancestor origin/main HEAD && echo fast-forward || echo diverged)" "fast-forward"
check "the next push needs no force" \
    "$(git -c core.hooksPath=/dev/null push -q origin main >/dev/null 2>&1 && echo pushed || echo refused)" "pushed"

echo "=== the existing collapse rules still hold ==="
checkpoint "auto-checkpoint 10:00"; before=$(git rev-parse HEAD^)
graph_write; sync_checkpoint
check "with no push in flight an unpushed checkpoint is still amended" "$(git rev-parse HEAD^)" "$before"
git -c core.hooksPath=/dev/null push -q origin main 2>/dev/null
at=$(git rev-parse HEAD); graph_write; sync_checkpoint
check "after a completed push a new checkpoint builds on the pushed commit" \
    "$(git merge-base --is-ancestor "$at" HEAD && echo kept || echo rewritten)" "kept"
nodes_before=$(wc -l < .weave/nodes.jsonl)
check "every graph node survives the checkpoints" "$(wv list --json 2>/dev/null | jq 'length')" "$nodes_before"

echo "=== a failed push's record ages out ==="
checkpoint "auto-checkpoint 11:00"; stuck=$(git rev-parse HEAD)
. "$ROOT/scripts/lib/wv-checkpoint-ci.sh"
wv_push_inflight_record "$PWD" "$stuck"     # as a push that never completed leaves it
graph_write; sync_checkpoint
check "while it counts, a checkpoint adds a commit instead of amending" \
    "$(git merge-base --is-ancestor "$stuck" HEAD && echo kept || echo rewritten)" "kept"
checkpoint "auto-checkpoint 11:30"; before=$(git rev-parse HEAD^)
wv_push_inflight_record "$PWD" "$(git rev-parse HEAD)"
graph_write; WV_PUSH_INFLIGHT_TTL=0 sync_checkpoint
check "once it ages out, amending resumes" "$(git rev-parse HEAD^)" "$before"

echo ""
echo "Results: $pass/$run passed"
[ "$pass" -eq "$run" ]
