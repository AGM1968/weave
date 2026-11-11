#!/usr/bin/env bash
# The per-checkout gate lock wired into the git hooks (wv-c5500d). With another
# gate holding the checkout, a pre-push and a code pre-commit each refuse before
# running any suite, naming the holder, while a graph-only commit (auto-
# checkpoint, sync) still passes. Once the holder is gone both run, and the
# push's outcome is recorded: passed, or failed naming the suite. The library's
# own behaviour (identity matrix, dead holders, macOS fallback) is
# tests/test-gate-hold.sh; this suite pins where the hooks take the lock and
# what wv bootstrap, which session start prints, reports from it: a gate in
# flight (and no "git push runs them" advice while a push gate runs), a failed
# push with its suite, and an orphaned push as interrupted.
set -uo pipefail
export WV_TEST_SUITE=1
export WV_CALL_SOURCE=test

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOKS="$ROOT/scripts/hooks"
LIB="$ROOT/scripts/lib/wv-gate-hold.sh"

run=0; pass=0
ok()  { run=$((run+1)); pass=$((pass+1)); echo "  ✓ $1"; }
bad() { run=$((run+1)); echo "  ✗ $1"; [ -n "${2:-}" ] && echo "      $2"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2], got [$3]"; fi; }
has()   { if grep -qF -- "$3" <<< "$2"; then ok "$1"; else bad "$1" "missing [$3] in: $(tail -5 <<< "$2")"; fi; }
hasnt() { if grep -qF -- "$3" <<< "$2"; then bad "$1" "unexpected [$3] in: $(tail -5 <<< "$2")"; else ok "$1"; fi; }

T=$(mktemp -d /tmp/wv-gate-hold-hooks-XXXXXX)
HOLDER=""
cleanup() { [ -z "$HOLDER" ] || { pkill -9 -P "$HOLDER" 2>/dev/null; kill -9 "$HOLDER" 2>/dev/null; }; rm -rf "$T"; }
trap cleanup EXIT
mkdir -p "$T/bin" "$T/cfg" "$T/marks"
ln -s "$ROOT/scripts/wv" "$T/bin/wv"
export PATH="$T/bin:$PATH"
export WV_LIB_DIR="$ROOT/scripts"
export WV_HOT_ZONE="$T" WV_DB="$T/brain.db" WV_CONFIG_DIR="$T/cfg" WV_PROJECT_DIR="$T/work"
export WV_SUITE_LOG="$T/suite_runs.jsonl" WV_GATE_LOG="$T/gate_runs.jsonl"
export WV_AUTO_SYNC=0 WV_AUTO_CHECKPOINT=0 WV_REQUIRE_LEARNING=0 WV_RUN_CACHE=0
unset WV_GATE_PHASE WV_GATE_ID WV_GATE_CONTEXT WV_HOOK_REEXEC
unset GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0 GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
MARK="$T/marks"

git init -q --bare "$T/remote.git"
git init -q -b main "$T/work"
cd "$T/work" || exit 1
git config user.name "Gate Test"; git config user.email gate@example.com; git config commit.gpgsign false
git remote add origin "$T/remote.git"
mkdir -p src tests .weave
for s in light heavy; do
    printf '#!/bin/sh\necho run >> "%s/%s"\n[ -f "%s/%s-fail" ] && { echo "✗ planted %s failure"; exit 1; }\nexit 0\n' \
        "$MARK" "$s" "$MARK" "$s" "$s" > "tests/test-$s.sh"
    chmod +x "tests/test-$s.sh"
done
cat > .weave/test-map.conf <<'EOF'
[map]
src/a.sh = tests/test-light.sh tests/test-heavy.sh
tests/test-light.sh = tests/test-light.sh
tests/test-heavy.sh = tests/test-heavy.sh
[heavy]
tests/test-heavy.sh
EOF
printf '#!/bin/sh\necho a\n' > src/a.sh
git add -A && git -c core.hooksPath=/dev/null commit -q -m "fixture"
git -c core.hooksPath=/dev/null push -q origin main 2>/dev/null
# bootstrap reports the heavy tier against the upstream.
git branch -q --set-upstream-to=origin/main
cp "$HOOKS/pre-push-weave.sh" .git/hooks/pre-push; chmod +x .git/hooks/pre-push
wv add "gate hold fixture node" --status=active --force --criteria="c1|c2" --risks=low >/dev/null 2>&1

runs() { if [ -f "$MARK/$1" ]; then wc -l < "$MARK/$1" | tr -d ' '; else echo 0; fi; }
prepush() {
    OUT=$(bash "$HOOKS/pre-push-weave.sh" origin "$T/remote.git" \
        < <(printf 'refs/heads/main %s refs/heads/main %s\n' "$(git rev-parse HEAD)" "$(git rev-parse origin/main)") 2>&1)
    RC=$?
}
precommit() { OUT=$(bash "$HOOKS/pre-commit-weave.sh" 2>&1); RC=$?; }
# hold — another owner's gate holds the fixture checkout until drop.
hold() {
    rm -f "$T/ready"
    (exec env WV_AGENT_ID=other-owner bash -c ". '$LIB'; wv_gate_hold_acquire pre-push 'refs/heads/main abc1234' \
        && echo \$\$ > '$T/ready.tmp' && mv '$T/ready.tmp' '$T/ready' && sleep 120") &
    disown
    local i=0
    while [ ! -f "$T/ready" ] && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i+1)); done
    HOLDER=$(cat "$T/ready" 2>/dev/null)
}
drop() {
    local i=0
    pkill -9 -P "$HOLDER" 2>/dev/null; kill -9 "$HOLDER" 2>/dev/null
    while kill -0 "$HOLDER" 2>/dev/null && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i+1)); done
    HOLDER=""; sleep 0.1
}
# shellcheck source=/dev/null
last_push() { (. "$LIB"; wv_gate_push_last); }
# advisories — what bootstrap (and so session start, which prints them) reports.
advisories() { WV_RUN_CACHE=0 wv bootstrap --json 2>/dev/null | jq -r '.readiness.advisories // [] | .[]'; }
# shellcheck source=/dev/null
hold_status() { (. "$LIB"; wv_gate_hold_status); }

printf '#!/bin/sh\necho a2\n' > src/a.sh
git add src/a.sh && git -c core.hooksPath=/dev/null commit -q -m "a2"

echo "a held checkout"
hold
check "(holder took the lock)" "1" "$([ -n "$HOLDER" ] && echo 1 || echo 0)"
prepush
check "pre-push refuses" "1" "$RC"
has "...naming the holder" "$OUT" "gate held by other-owner"
has "...and what it gates" "$OUT" "refs/heads/main abc1234"
check "...before running any heavy suite" "0" "$(runs heavy)"
check "...and the held push's record is untouched" "" "$(last_push)"
adv=$(advisories)
has "bootstrap reports the gate in flight" "$adv" "gate in flight on this checkout: pre-push held by other-owner"
has "...says the push gate is running the pending heavy tier" "$adv" "a push gate is running them now (pid $HOLDER)"
hasnt "...and does not advise pushing again" "$adv" "git push runs them"
check "...with the holder in its JSON" "$HOLDER" "$(WV_RUN_CACHE=0 wv bootstrap --json 2>/dev/null | jq -r '.readiness.gate.holder.pid')"
printf '#!/bin/sh\necho a3\n' > src/a.sh; git add src/a.sh
precommit
check "a code pre-commit refuses" "1" "$RC"
has "...naming the holder" "$OUT" "gate held by other-owner"
check "...before running any suite" "0" "$(runs light)"
git reset -q && git checkout -q -- src/a.sh
printf 'graph\n' > .weave/state.sql; git add .weave/state.sql
precommit
check "a graph-only commit still passes while it is held" "0" "$RC"
git -c core.hooksPath=/dev/null commit -q -m "graph only"
drop
adv=$(advisories)
hasnt "with the holder gone, bootstrap reports no gate in flight" "$adv" "gate in flight"
has "...and advises the push again" "$adv" "git push runs them"

echo "a free checkout"
prepush
check "pre-push runs once the holder is gone" "0" "$RC"
check "...running the heavy suite it owes" "1" "$(runs heavy)"
check "...and records the push as passed" "passed" "$(last_push | jq -r '.state')"
check "...releasing the lock" "" "$(hold_status)"
touch "$MARK/heavy-fail"
prepush
check "a red heavy tier refuses the push" "1" "$RC"
check "...recorded as failed" "failed" "$(last_push | jq -r '.state')"
check "...naming the suite" "tests/test-heavy.sh" "$(last_push | jq -r '.detail')"
has "bootstrap reports the failed push and its suite" "$(advisories)" "last push failed on tests/test-heavy.sh"
rm -f "$MARK/heavy-fail"
# A push whose gate died (its session restarted): the record says running, the pid is gone.
env WV_AGENT_ID=gone-owner bash -c ". '$LIB'; wv_gate_push_outcome running 'refs/heads/main def5678'"
has "bootstrap reports an orphaned push as interrupted" "$(advisories)" "last push interrupted: its gate"

echo "Results: $pass/$run passed"
[ "$pass" -eq "$run" ]
