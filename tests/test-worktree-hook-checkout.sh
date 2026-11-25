#!/usr/bin/env bash
# "done" is an argument to wv below, never the loop keyword.
# shellcheck disable=SC1010
# test-worktree-hook-checkout.sh -- the close guard, the claim guard and edit
# attribution judge the checkout a command or file is in, not the session cwd
# (wv-7ab9d4).
#
# A harness pinned to one checkout sends every tool call with that checkout as
# .cwd and reaches a linked worktree only by `cd <dir> && wv ...`. On
# 2026-11-18 wv done for wv-81338c, run that way in a worktree, was refused
# "No commit attributed" although the worktree's unpushed commit carried the
# Weave-ID trailer: the guard read the main checkout's git log. The same guard
# checked the main checkout's uncommitted files, never the worktree's.
#   - a worktree close whose commit is only in the worktree is admitted;
#   - a worktree close with no attributed commit is still refused;
#   - uncommitted work in the worktree refuses the close;
#   - a cd the guard cannot resolve ($var, missing dir) refuses the close;
#   - pushd, subshells, cd chains, cd -, popd, env -C and wrappers (ssh, sudo,
#     bash -c) each judge the right checkout or refuse unjudged;
#   - an edit to a file in no Weave checkout is not judged by the session one,
#     but an edit to an installed copy (~/.local/bin, ~/.local/lib/weave,
#     ~/.config/weave except the user's config) is still refused;
#   - a worktree claim reads the worktree's graph;
#   - an edit in the worktree is attributed to the worktree's active node.
export WV_CALL_SOURCE=test
set -uo pipefail
export WV_TEST_SUITE=1
export WV_RUN_CACHE=0
export WV_REQUIRE_LEARNING=0 WV_REQUIRE_QUALITY=0
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WV="$ROOT/scripts/wv"
HOOKS="$ROOT/.claude/hooks"
run=0; pass=0
ok()  { run=$((run+1)); pass=$((pass+1)); echo "  ✓ $1"; }
bad() { run=$((run+1)); echo "  ✗ $1"; [ -n "${2:-}" ] && echo "      $2"; }
TMP=$(cd "$(mktemp -d /tmp/wv-worktree-hook-XXXXXX)" && pwd -P)
trap 'rm -rf "$TMP"' EXIT

P="$TMP/main"; W="$TMP/wt"
mkdir -p "$P"
export WV_HOT_ZONE="$TMP/hot" WV_DB="$TMP/hot/brain.db" WV_CONFIG_DIR="$TMP/config"
export CLAUDE_PROJECT_DIR="$P" WV_PROJECT_DIR="$P" WV_AGENT_ID=test-worktree-hook-agent
mkdir -p "$WV_CONFIG_DIR"
g() { git -C "$1" "${@:2}"; }
(cd "$P" && git init -q . && git config user.email t@t && git config user.name t && git config commit.gpgsign false)
(cd "$P" && "$WV" init >/dev/null 2>&1)
g "$P" add -A >/dev/null 2>&1; g "$P" commit -q --allow-empty -m init
g "$P" worktree add -q -b wt "$W" >/dev/null 2>&1
# The worktree's graph sits at the default placement, as a real linked
# worktree's does: the guards drop the pinned zone when they move there.
[ -z "${WV_TEST_HOT_ZONE_ROOT:-}" ] || (umask 077 && mkdir -p "$WV_TEST_HOT_ZONE_ROOT/tmp")
w() { (cd "$W" && env -u WV_HOT_ZONE -u WV_DB -u WV_PROJECT_DIR -u CLAUDE_PROJECT_DIR "$WV" "$@") </dev/null; }
w init >/dev/null 2>&1
W_DB=$(w hotzone db 2>/dev/null); W_ZONE=$(dirname "$W_DB")
case "$W_ZONE" in /tmp/weave-*/?*) trap 'rm -rf "$TMP" "$W_ZONE"' EXIT ;; esac
g "$W" add -A >/dev/null 2>&1; g "$W" commit -q --allow-empty -m "wt init"
if [ -s "$W_DB" ] && [ "$W_DB" != "$WV_DB" ]; then ok "(fixture) the worktree has its own graph"; else bad "(fixture) the worktree has its own graph" "W_DB=$W_DB"; fi

first_id() { [[ "$1" =~ wv-[a-f0-9]{4,6} ]] && printf '%s\n' "${BASH_REMATCH[0]}"; }
# share <id> -- copy a worktree node into the main graph with empty metadata,
# as the shared git graph carries it before the worktree's work is pushed.
share() { sqlite3 "$WV_DB" "ATTACH '$W_DB' AS w; INSERT OR REPLACE INTO nodes(id,text,status,metadata) SELECT id,text,'active','{}' FROM w.nodes WHERE id='$1';"; }
bash_in() { jq -cn --arg c "$1" --arg cwd "$P" '{tool_name:"Bash",tool_input:{command:$c},cwd:$cwd}'; }
# The harness runs a hook from the session cwd, which is the payload cwd.
hook() { (cd "$P" && printf '%s' "$2" | bash "$HOOKS/$1" 2>"$TMP/hook.err"); }
denied() { grep -q '"deny"' <<< "$1"; }

echo "=== wv done in a linked worktree ==="
n=$(first_id "$(w add "worktree close probe" --standalone --alias=wt-close --criteria=c1 --risks=low 2>/dev/null)")
w work "$n" >/dev/null 2>&1
share "$n"
echo x > "$W/feature.txt"; g "$W" add feature.txt; g "$W" commit -q -m "feat: worktree work" -m "Weave-ID: $n"
if [ -z "$(g "$P" log --format=%H --grep="Weave-ID: $n")" ]; then ok "(fixture) the attributed commit is only in the worktree"; else bad "(fixture) the attributed commit is only in the worktree"; fi
out=$(hook pre-close-verification.sh "$(bash_in "cd $W && wv done $n --verification-method=test")")
if ! denied "$out"; then ok "a worktree close whose commit is only in the worktree is admitted"; else bad "a worktree close whose commit is only in the worktree is admitted" "$out"; fi
out=$(hook pre-close-verification.sh "$(bash_in "cd '$W' && wv done $n --verification-method=test")")
if ! denied "$out"; then ok "...with the path quoted"; else bad "...with the path quoted" "$out"; fi

m=$(first_id "$(w add "worktree unattributed probe" --standalone --alias=wt-none --criteria=c1 --risks=low 2>/dev/null)")
w work "$m" >/dev/null 2>&1
share "$m"
out=$(hook pre-close-verification.sh "$(bash_in "cd $W && wv done $m --verification-method=test")")
if denied "$out" && grep -qF -- "No commit attributed to $m" <<< "$out"; then ok "a worktree close with no attributed commit is still refused"; else bad "a worktree close with no attributed commit is still refused" "$out"; fi

echo y > "$W/feature.txt"
out=$(hook pre-close-verification.sh "$(bash_in "cd $W && wv done $n --verification-method=test")")
if denied "$out" && grep -q "Commit work before close" <<< "$out"; then ok "uncommitted work in the worktree refuses the close"; else bad "uncommitted work in the worktree refuses the close" "$out"; fi
g "$W" checkout -q -- feature.txt

out=$(hook pre-close-verification.sh "$(bash_in "cd \$WT && wv done $n --verification-method=test")")
if denied "$out" && grep -q "Cannot verify this close" <<< "$out"; then ok "a cd to a variable refuses the close"; else bad "a cd to a variable refuses the close" "$out"; fi
out=$(hook pre-close-verification.sh "$(bash_in "cd $TMP/nowhere && wv done $n --verification-method=test")")
if denied "$out" && grep -q "does not exist" <<< "$out"; then ok "a cd to a missing directory refuses the close"; else bad "a cd to a missing directory refuses the close" "$out"; fi

echo "=== the forms a command reaches the worktree by ==="
# admitted <label> <command>: judged in the worktree, where n's commit is.
admitted() {
    local out; out=$(hook pre-close-verification.sh "$(bash_in "$2")")
    if ! denied "$out"; then ok "$1"; else bad "$1" "$out"; fi
}
# refused <label> <expect> <command>: refused, the message naming why.
refused() {
    local out; out=$(hook pre-close-verification.sh "$(bash_in "$3")")
    if denied "$out" && grep -qF -- "$2" <<< "$out"; then ok "$1"; else bad "$1" "$out"; fi
}
V="--verification-method=test"
admitted "pushd <wt> && wv done judges the worktree" "pushd $W && wv done $n $V"
admitted "(cd <wt> && wv done) judges the worktree" "(cd $W && wv done $n $V)"
refused "(cd <wt>) && wv done judges the session checkout, where the commit is not" \
    "No commit attributed to $n" "(cd $W) && wv done $n $V"
admitted "cd <wt>; wv done; cd - judges the worktree" "cd $W; wv done $n $V; cd -"
admitted "cd <parent> && cd <wt> judges the second, relative to the first" "cd $TMP && cd wt && wv done $n $V"
refused "git -C <wt> ... && wv done (no cd) judges the session checkout" \
    "No commit attributed to $n" "git -C $W status && wv done $n $V"
admitted "env -C <wt> wv done judges the worktree" "env -C $W wv done $n $V"
admitted "a path to wv after cd <wt> judges the worktree" "cd $W && ./scripts/wv done $n $V"
refused "cd - before wv done is refused unjudged" "Cannot verify this close" "cd - && wv done $n $V"
refused "popd before wv done is refused unjudged" "Cannot verify this close" "pushd $W && popd && wv done $n $V"
refused "wv done under ssh is refused unjudged" "Cannot verify this close" "ssh elsewhere wv done $n $V"
refused "wv done under sudo is refused unjudged" "Cannot verify this close" "sudo wv done $n $V"
refused "wv done inside bash -c is refused unjudged" "Cannot verify this close" "bash -c \"cd $W && wv done $n $V\""

echo "=== wv work in a linked worktree ==="
k=$(first_id "$(w add "worktree claim probe" --standalone --alias=wt-claim --criteria=c1 --risks=low 2>/dev/null)")
share "$k"   # the main graph's copy has no criteria and no alias
out=$(hook pre-claim-skills.sh "$(bash_in "wv work $k")")
if denied "$out"; then ok "(fixture) from the main checkout the claim reads the criteria-less copy"; else bad "(fixture) from the main checkout the claim reads the criteria-less copy" "$out"; fi
out=$(hook pre-claim-skills.sh "$(bash_in "cd $W && wv work $k")")
if ! denied "$out"; then ok "a worktree claim reads the worktree's graph"; else bad "a worktree claim reads the worktree's graph" "$out"; fi

echo "=== edit attribution in a linked worktree ==="
mkdir -p "$W/src"; echo "a" > "$W/src/edited.py"
payload=$(jq -cn --arg p "$W/src/edited.py" --arg cwd "$P" '{tool_name:"Edit",tool_input:{file_path:$p,old_string:"a",new_string:"b"},tool_response:{success:true},cwd:$cwd}')
(cd "$P" && printf '%s' "$payload" | bash "$HOOKS/wv-touched-files.sh" >/dev/null 2>&1)
got=$(sqlite3 "$W_DB" "SELECT COUNT(*) FROM node_files WHERE node_id='$m' AND path='src/edited.py';" 2>/dev/null)
if [ "$got" = 1 ]; then ok "an edit in the worktree is attributed to the worktree's active node"; else bad "an edit in the worktree is attributed to the worktree's active node" "node_files rows=$got"; fi

echo "=== an edit outside every Weave checkout ==="
# An edit inside the session checkout is judged and refused there; a file in
# no Weave checkout has no claim to enforce.
mkdir -p "$TMP/outside"
edit_in() { jq -cn --arg p "$1" --arg cwd "$P" '{tool_name:"Write",tool_input:{file_path:$p,content:"x"},cwd:$cwd}'; }
(cd "$P" && printf '%s' "$(edit_in "$P/inside.txt")" | bash "$HOOKS/pre-action.sh" >/dev/null 2>&1); rc=$?
if [ "$rc" = 2 ]; then ok "(fixture) an edit in the session checkout is judged there, and refused"; else bad "(fixture) an edit in the session checkout is judged there, and refused" "rc=$rc"; fi
(cd "$P" && printf '%s' "$(edit_in "$TMP/outside/scratch.txt")" | bash "$HOOKS/pre-action.sh" >/dev/null 2>&1); rc=$?
if [ "$rc" = 0 ]; then ok "an edit to a file in no Weave checkout is not judged by the session checkout"; else bad "an edit to a file in no Weave checkout is not judged by the session checkout" "rc=$rc"; fi

# Installed copies are in no checkout, and stay refused: the installed-copy
# guard runs before the no-checkout rule. Paths only; nothing is written.
for f in "$HOME/.local/bin/wv" "$HOME/.local/lib/weave/lib/wv-db.sh" \
         "$HOME/.config/weave/lib/wv-pre-tool-use.sh" "$HOME/.config/weave/hooks/stop-check.sh" \
         "$HOME/.config/weave/WORKFLOW.md"; do
    (cd "$P" && printf '%s' "$(edit_in "$f")" | bash "$HOOKS/pre-action.sh" >/dev/null 2>"$TMP/ic.err"); rc=$?
    if [ "$rc" = 2 ] && grep -q "Editing installed copy" "$TMP/ic.err"; then ok "an edit to the installed copy ${f#"$HOME"/} is refused"
    else bad "an edit to the installed copy ${f#"$HOME"/} is refused" "rc=$rc $(head -c 200 "$TMP/ic.err")"; fi
done
(cd "$P" && printf '%s' "$(edit_in "$HOME/.config/weave/config.env")" | bash "$HOOKS/pre-action.sh" >/dev/null 2>"$TMP/ic.err"); rc=$?
if [ "$rc" = 0 ]; then ok "the user's own ~/.config/weave/config.env stays editable"; else bad "the user's own ~/.config/weave/config.env stays editable" "rc=$rc $(head -c 200 "$TMP/ic.err")"; fi

echo ""
echo "worktree hook checkout: $pass/$run passed"
[ "$pass" -eq "$run" ]
