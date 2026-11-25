#!/bin/bash
# test-projection-verdict.sh — the committed .weave/state.sql must reflect the
# operations committed with it (wv-65cd02).
#
# .gitattributes merges state.sql with merge=ours, and under git pull --rebase
# "ours" is the upstream: rebasing a local commit onto another copy's graph
# commit replaces this copy's snapshot with the other's, while this copy's
# Delta v2 operations still travel. The graph's git verdict (wv status,
# _detect_git_pending) reports projection_lags_operations, and the pre-push
# hook, which asks it, refuses until wv load + wv sync re-dump the snapshot.
# Also: a linked worktree, whose .git is a file, is a repository to the verdict.
export WV_CALL_SOURCE=test
export WV_TEST_SUITE=1  # the user's config.env cannot log this suite's wv calls (wv-6b0f57)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
run=0; pass=0
ok()  { run=$((run+1)); pass=$((pass+1)); echo "  ✓ $1"; }
bad() { run=$((run+1)); echo "  ✗ $1"; [ -n "${2:-}" ] && echo "      $2"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$3] got [$2]"; fi; }

T=$(mktemp -d /tmp/wv-projection-verdict-XXXXXX)
trap '[ -n "${KEEP:-}" ] || rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/cfg"
ln -s "$ROOT/scripts/wv" "$T/bin/wv"
export PATH="$T/bin:$PATH" WV_LIB_DIR="$ROOT/scripts" WV_CONFIG_DIR="$T/cfg"
export WV_AUTO_SYNC=0 WV_AUTO_CHECKPOINT=0 WV_REQUIRE_LEARNING=0 WV_RUN_CACHE=0
export WV_SUITE_LOG="$T/suite_runs.jsonl" WV_GATE_LOG="$T/gate_runs.jsonl"
unset WV_DB WV_DB_CUSTOM WV_GATE_PHASE WV_GATE_ID WV_GATE_CONTEXT WV_HOOK_REEXEC
unset WV_SESSION_ID CLAUDE_CODE_SESSION_ID CODEX_THREAD_ID PI_SESSION_ID AMP_CURRENT_THREAD_ID
export WV_SESSION_IDENTITY=0
# The commit gate injects core.hooksPath=/dev/null through GIT_CONFIG_*; this
# suite runs the pre-push hook by hand, so the fixture states its own config.
unset GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0 GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE

G() { git -c core.hooksPath=/dev/null -c user.name=t -c user.email=t@example.com -c commit.gpgsign=false "$@"; }
# on <side> <cmd>... — run in one copy with its own hot zone
on() {
    local side=$1; shift
    ( cd "$T/$side" && WV_PROJECT_DIR="$T/$side" WV_HOT_ZONE="$T/hz-$side" WV_DB="$T/hz-$side/brain.db" \
        WV_AGENT_ID="copy-$side" "$@" )
}
reason() { on "$1" wv status --json 2>/dev/null | jq -r '.git_sync_reason // "none"'; }
prepush() {  # prepush <side> — the hook as git runs it for HEAD -> its upstream
    local side=$1 head up
    head=$(G -C "$T/$side" rev-parse HEAD); up=$(G -C "$T/$side" rev-parse '@{upstream}')
    printf 'refs/heads/main %s refs/heads/main %s\n' "$head" "$up" \
        | on "$side" bash "$ROOT/scripts/hooks/pre-push-weave.sh" origin "$T/remote.git"
}
drivers() { G -C "$T/$1" config merge.ours.driver true; G -C "$T/$1" config merge.theirs.driver 'cp %B %A'; }

echo "Testing: fixture (two copies of one graph)"
G init -q --bare -b main "$T/remote.git"
G init -q -b main "$T/A"
G -C "$T/A" remote add origin "$T/remote.git"
on A wv repo-class set owned --acknowledge-upstream-fork >/dev/null 2>&1
on A wv init >/dev/null 2>&1
[ -d "$T/A/.weave" ] || { echo "  ✗ fixture: wv init did not initialise the graph"; exit 1; }
# The merge rules install.sh writes into a Weave repository's .gitattributes.
printf '%s\n' '.weave/state.sql merge=ours -diff' '.weave/nodes.jsonl merge=ours -diff' \
    '.weave/edges.jsonl merge=ours -diff' '.weave/breadcrumbs.md merge=ours' \
    '.weave/causal-cutover merge=ours -diff' \
    '.weave/deltas/**/*.sql merge=theirs' '.weave/deltas/**/*.json merge=theirs' > "$T/A/.gitattributes"
# And the runtime ignores it writes into .gitignore: machine-local files such as
# .weave/.applied_deltas are never graph state, and the re-projection commits
# graph state alone (wv-6729a0).
( source "$ROOT/scripts/lib/wv-runtime-ignores.sh" && wv_runtime_ignores ) > "$T/A/.gitignore"
on A wv add "seed node" --standalone >/dev/null 2>&1
on A wv sync >/dev/null 2>&1
G -C "$T/A" add -A >/dev/null && G -C "$T/A" commit -q -m seed && G -C "$T/A" push -q -u origin main 2>/dev/null
G clone -q "$T/remote.git" "$T/B"
drivers A; drivers B
# A repository's own identity: wv recover --reproject commits with plain git, and
# the gate's environment has no global one (only -c on G/GH, which hooks inherit).
for side in A B; do G -C "$T/$side" config user.name t; G -C "$T/$side" config user.email t@example.com; done
on B wv load >/dev/null 2>&1
check "fixture: both copies at the seed" "$(G -C "$T/B" rev-parse HEAD)" "$(G -C "$T/A" rev-parse HEAD)"

echo "Testing: a synced commit ahead is not lag"
on A wv add "node from A" --standalone >/dev/null 2>&1
on A wv sync >/dev/null 2>&1
G -C "$T/A" add -A .weave && G -C "$T/A" commit -q -m "A work"
check "verdict for a synced commit ahead" "$(reason A)" "ahead_weave"
prepush A >/dev/null 2>&1; check "pre-push passes a synced snapshot" "$?" "0"
G -C "$T/A" push -q origin main 2>/dev/null

echo "Testing: a rebase onto another copy's graph commit"
on B wv add "node from B" --standalone >/dev/null 2>&1
on B wv sync >/dev/null 2>&1
G -C "$T/B" add -A .weave && G -C "$T/B" commit -q -m "B work"
G -C "$T/B" pull -q --rebase >/dev/null 2>&1
b_node=$(on B wv list --json 2>/dev/null | jq -r '.[] | select(.text=="node from B") | .id' | head -1)
check "the rebased snapshot lost this copy's node (the defect)" \
    "$(G -C "$T/B" show HEAD:.weave/state.sql | grep -c -- "$b_node")" "0"
proj=$(on B wv status --json 2>/dev/null)
check "verdict names the lag" "$(jq -r .git_sync_reason <<< "$proj")" "projection_lags_operations"
check "verdict action" "$(jq -r .git_sync_action <<< "$proj")" "load_and_sync"
case "$(jq -r .git_sync_hint <<< "$proj")" in
    *"wv load, then wv sync"*) ok "hint names the remedy" ;;
    *) bad "hint names the remedy" "$(jq -r .git_sync_hint <<< "$proj")" ;;
esac
out=$(prepush B 2>&1); rc=$?
check "pre-push refuses a lagging snapshot" "$rc" "1"
case "$out" in
    *projection_lags_operations*"wv load, then wv sync"*) ok "pre-push prints the graph's reason and hint" ;;
    *) bad "pre-push prints the graph's reason and hint" "$out" ;;
esac

echo "Testing: wv load + wv sync repairs it"
on B wv load >/dev/null 2>&1
on B wv sync >/dev/null 2>&1
G -C "$T/B" add -A .weave && G -C "$T/B" commit -q -m "re-dump"
check "the repaired snapshot holds this copy's node" \
    "$([ "$(G -C "$T/B" show HEAD:.weave/state.sql | grep -c -- "$b_node")" -gt 0 ] && echo yes)" "yes"
check "verdict after the repair" "$(reason B)" "ahead_weave"
prepush B >/dev/null 2>&1; check "pre-push passes after the repair" "$?" "0"

echo "Testing: a linked worktree is a repository to the verdict"
G -C "$T/B" worktree add -q -b wt "$T/W" >/dev/null 2>&1
G -C "$T/W" branch -q --set-upstream-to=origin/main wt 2>/dev/null
check "worktree has a .git file" "$([ -f "$T/W/.git" ] && echo file)" "file"
on W wv load >/dev/null 2>&1
check "worktree verdict is not not_repo" "$(reason W)" "ahead_weave"

# wv-6729a0: the snapshot is re-projected where git already runs, after a
# rebase or merge, by the post-rewrite and post-merge hooks asking the graph.
# GH runs git with hooks on; G keeps them off, so the pre-hook cases above and
# the control below see git alone.
GH() { git -c user.name=t -c user.email=t@example.com -c commit.gpgsign=false "$@"; }
# pullh <side> <args>... — git pull as an operator runs it, hooks on, auto-commit allowed
pullh() {
    local side=$1; shift
    ( cd "$T/$side" && WV_AUTO_CHECKPOINT=1 WV_PROJECT_DIR="$T/$side" WV_HOT_ZONE="$T/hz-$side" \
        WV_DB="$T/hz-$side/brain.db" WV_AGENT_ID="copy-$side" GH pull -q "$@" 2>&1 )
}
# work <side> <text> — a node added, synced and committed as graph state
work() {
    on "$1" wv load >/dev/null 2>&1; on "$1" wv add "$2" --standalone >/dev/null 2>&1
    on "$1" wv sync >/dev/null 2>&1; G -C "$T/$1" add -A .weave && G -C "$T/$1" commit -q -m "$2"
}
in_head() { G -C "$T/$1" show HEAD:.weave/state.sql 2>/dev/null | grep -c -- "$2"; }
G -C "$T/B" push -q origin main 2>/dev/null; G -C "$T/A" pull -q --rebase >/dev/null 2>&1

echo "Testing: a merge keeps this copy's snapshot, and the verdict sees it"
work A "merge node from A"; G -C "$T/A" push -q origin main 2>/dev/null
work B "merge node from B"
G -C "$T/B" pull -q --no-rebase --no-edit >/dev/null 2>&1
check "(the merge kept this copy's snapshot, without the merged node)" "$(in_head B 'merge node from A')" "0"
check "verdict names the lag after a merge" "$(reason B)" "projection_lags_operations"
prepush B >/dev/null 2>&1; check "pre-push refuses a lagging merge" "$?" "1"
on B wv load >/dev/null 2>&1; on B wv sync >/dev/null 2>&1
G -C "$T/B" add -A .weave && G -C "$T/B" commit -q -m "re-dump merge"
G -C "$T/B" push -q origin main 2>/dev/null; G -C "$T/A" pull -q --rebase >/dev/null 2>&1

for side in A B; do
    for h in post-rewrite post-merge; do
        cp "$ROOT/scripts/hooks/reproject-weave.sh" "$T/$side/.git/hooks/$h"; chmod +x "$T/$side/.git/hooks/$h"
    done
done

echo "Testing: post-rewrite re-projects after a rebase"
work A "hook node from A"; G -C "$T/A" push -q origin main 2>/dev/null
work B "hook node from B"
out=$(pullh B --rebase)
check "the rebase is followed by a graph-state commit" "$(G -C "$T/B" log -1 --format=%s)" \
    "chore(weave): re-project graph state after rebase [skip ci]"
check "...on top of this copy's own commit, not amending it" "$(G -C "$T/B" log -1 --skip=1 --format=%s)" "hook node from B"
check "...which touches graph state alone" "$(G -C "$T/B" diff --name-only HEAD~1 HEAD | grep -vc '^\.weave/')" "0"
check "the snapshot holds this copy's node" "$([ "$(in_head B 'hook node from B')" -gt 0 ] && echo yes)" "yes"
check "...and the other copy's" "$([ "$(in_head B 'hook node from A')" -gt 0 ] && echo yes)" "yes"
case "$out" in *"re-projected .weave/ after rebase: 1 operation(s)"*) ok "the hook reports what it re-projected" ;;
    *) bad "the hook reports what it re-projected" "$out" ;; esac
check "verdict after the hook" "$(reason B)" "ahead_weave"
prepush B >/dev/null 2>&1; check "pre-push passes with no repair by hand" "$?" "0"
G -C "$T/B" push -q origin main 2>/dev/null

echo "Testing: post-merge re-projects after a merge, and does nothing on a fast-forward"
pullh A --rebase >/dev/null
check "a fast-forward adds no commit" "$(G -C "$T/A" rev-list --count '@{upstream}..HEAD')" "0"
work B "post-merge node from B"; G -C "$T/B" push -q origin main 2>/dev/null
work A "post-merge node from A"
out=$(pullh A --no-rebase --no-edit)
check "the merge is followed by a graph-state commit" "$(G -C "$T/A" log -1 --format=%s)" \
    "chore(weave): re-project graph state after merge [skip ci]"
check "the snapshot holds the merged node" "$([ "$(in_head A 'post-merge node from B')" -gt 0 ] && echo yes)" "yes"
check "verdict after the merge hook" "$(reason A)" "ahead_weave"
G -C "$T/A" push -q origin main 2>/dev/null; pullh B --rebase >/dev/null

echo "Testing: the hook defers, and pre-push stays the backstop"
work A "deferred node from A"; G -C "$T/A" push -q origin main 2>/dev/null
work B "deferred node from B"
printf '# local edit\n' >> "$T/B/.weave/edges.jsonl"
out=$(pullh B --rebase --autostash)
case "$out" in *"not re-projected: the pending autostash holds .weave/ changes"*) ok "an autostash holding .weave/ changes defers it, saying why" ;;
    *) bad "an autostash holding .weave/ changes defers it, saying why" "$out" ;; esac
check "...and the stashed change comes back" "$(G -C "$T/B" status --porcelain -- .weave/edges.jsonl | cut -c1-2)" " M"
check "...no commit was made" "$(G -C "$T/B" log -1 --format=%s)" "deferred node from B"
prepush B >/dev/null 2>&1; check "pre-push still refuses the lagging snapshot" "$?" "1"
G -C "$T/B" checkout -q -- .weave/edges.jsonl
out=$(on B env WV_AUTO_CHECKPOINT=0 wv recover --reproject --json 2>/dev/null)
check "WV_AUTO_CHECKPOINT=0 defers it" "$(jq -r '.action + " | " + .reason' <<< "$out")" \
    "deferred | automatic commits are off (WV_AUTO_CHECKPOINT=0)"
out=$(on B env WV_AUTO_CHECKPOINT=1 wv recover --reproject --json 2>/dev/null)
check "run by hand it re-projects" "$(jq -r '.action' <<< "$out")" "reprojected"
check "...reporting the states apart" "$(jq -c '{serialized_to_weave, c: (.git_committed_local != null)}' <<< "$out")" \
    '{"serialized_to_weave":true,"c":true}'
out=$(on B env WV_AUTO_CHECKPOINT=1 wv recover --reproject --json 2>/dev/null)
check "a current snapshot is left alone" "$(jq -r '.action + " " + .verdict' <<< "$out")" "none ok"

echo ""
echo "Results: $pass/$run passed"
[ "$pass" -eq "$run" ]
