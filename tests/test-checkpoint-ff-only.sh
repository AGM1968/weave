#!/usr/bin/env bash
# Suite-driven wv calls are tagged test so call-stats retro reads can exclude them.
export WV_CALL_SOURCE=test
# test-checkpoint-ff-only.sh — an auto-checkpoint never rewrites history (wv-2f32a7).
#
# On 2026-11-09 an auto-checkpoint ran 'git pull --rebase --autostash', which
# silently rebased 8 unpushed commits and flattened a deliberate merge; later
# checkpoints amended their commit while a commit gate was running. Pinned here:
#   - a branch that has diverged from its upstream (with a local merge commit) is
#     left exactly as it was, and the checkpoint says why;
#   - a branch only behind its upstream is fast-forwarded, then checkpointed;
#   - while a gate holds the checkout (wv-c5500d's lock) no checkpoint commit is
#     made, and once it is released the next one is.
set -uo pipefail
export WV_TEST_SUITE=1  # the user's config.env cannot log this suite's wv calls (wv-6b0f57)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WV="$REPO_ROOT/scripts/wv"
LIB="$REPO_ROOT/scripts/lib/wv-gate-hold.sh"
T=$(mktemp -d)
HOLDER=""
cleanup() { [ -z "$HOLDER" ] || { pkill -9 -P "$HOLDER" 2>/dev/null; kill -9 "$HOLDER" 2>/dev/null; }; rm -rf "$T"; }
trap cleanup EXIT
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE WV_DB WV_DB_CUSTOM WV_AUTO_CHECKPOINT WV_CHECKPOINT_PULL
pass=0; run=0
ok()  { echo "  ✓ $1"; pass=$((pass + 1)); run=$((run + 1)); }
bad() { echo "  ✗ $1"; [ -n "${2:-}" ] && echo "      $2"; run=$((run + 1)); }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2], got [$3]"; fi; }
has() { if grep -qF -- "$3" <<< "$2"; then ok "$1"; else bad "$1" "missing [$3] in: $(tail -3 <<< "$2")"; fi; }

# clone_as <name> — a working clone of the remote with its own hot zone.
clone_as() {
    git clone -q "$T/remote.git" "$T/$1" 2>/dev/null
    git -C "$T/$1" config user.name "$1"; git -C "$T/$1" config user.email "$1@t"; git -C "$T/$1" config commit.gpgsign false
    mkdir -p "$T/hz-$1" "$T/cfg-$1"
}
# wvin <name> <cmd...> — run a wv command in a clone, checkpoints and pull at their defaults.
wvin() {
    local n="$1"; shift
    (cd "$T/$n" && WV_HOT_ZONE="$T/hz-$n" WEAVE_DIR="$T/$n/.weave" WV_PROJECT_DIR="$T/$n" WV_CONFIG_DIR="$T/cfg-$n" \
        WV_AGENT_ID="agent-$n" WV_REQUIRE_LEARNING=0 WV_SYNC_INTERVAL=0 WV_CHECKPOINT_INTERVAL=0 "$@")
}

git init -q --bare -b main "$T/remote.git"
clone_as a
wvin a "$WV" init >/dev/null 2>&1
wvin a "$WV" add "seed" --force >/dev/null 2>&1
wvin a env WV_FORCE_SYNC=1 "$WV" sync >/dev/null 2>&1
# The sync may already have checkpointed the seed; commit whatever is left, then push.
git -C "$T/a" add -A; git -C "$T/a" commit -q -m seed --no-verify >/dev/null 2>&1 || true
git -C "$T/a" push -q origin HEAD:main 2>/dev/null
git -C "$T/a" branch -q --set-upstream-to=origin/main 2>/dev/null
clone_as b
clone_as c

echo "a diverged branch with a local merge"
git -C "$T/a" checkout -q -b side && echo s > "$T/a/side.txt" && git -C "$T/a" add side.txt && git -C "$T/a" commit -q -m side --no-verify
git -C "$T/a" checkout -q main && git -C "$T/a" merge -q --no-ff side -m "local merge" --no-verify >/dev/null
echo b > "$T/b/b.txt" && git -C "$T/b" add b.txt && git -C "$T/b" commit -q -m "remote work" --no-verify && git -C "$T/b" push -q origin HEAD:main 2>/dev/null
before=$(git -C "$T/a" rev-parse HEAD); merges_before=$(git -C "$T/a" rev-list --merges --count HEAD)
wvin a "$WV" add "pending graph change" --force >/dev/null 2>&1
out=$(wvin a "$WV" sync 2>&1)
check "the local commits are untouched (the old HEAD is still in history)" "yes" \
    "$(git -C "$T/a" merge-base --is-ancestor "$before" HEAD && echo yes || echo no)"
check "...the local merge commit survives" "$merges_before" "$(git -C "$T/a" rev-list --merges --count HEAD)"
check "...nothing from the diverged upstream was pulled in" "no" \
    "$(git -C "$T/a" merge-base --is-ancestor origin/main HEAD && echo yes || echo no)"
has "...and the checkpoint says why" "$out" "diverged"

echo "a branch only behind its upstream"
c_before=$(git -C "$T/c" rev-parse HEAD)
git -C "$T/c" fetch -q 2>/dev/null
check "(the clone is behind, not diverged)" "0" "$(git -C "$T/c" rev-list --count '@{u}..HEAD')"
wvin c "$WV" load >/dev/null 2>&1
wvin c "$WV" add "c change" --force >/dev/null 2>&1
wvin c "$WV" sync >/dev/null 2>&1
check "it is fast-forwarded to its upstream" "yes" \
    "$(git -C "$T/c" merge-base --is-ancestor origin/main HEAD && echo yes || echo no)"
check "...with its old HEAD kept in history" "yes" \
    "$(git -C "$T/c" merge-base --is-ancestor "$c_before" HEAD && echo yes || echo no)"
check "...and no merge or rebase made" "0" "$(git -C "$T/c" rev-list --merges --count "$c_before"..HEAD)"

echo "while a gate holds the checkout"
rm -f "$T/ready"
(cd "$T/c" && exec bash -c ". '$LIB'; wv_gate_hold_acquire pre-push 'refs/heads/main' && echo \$\$ > '$T/ready.tmp' && mv '$T/ready.tmp' '$T/ready' && sleep 120") &
disown
i=0; while [ ! -f "$T/ready" ] && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i+1)); done
HOLDER=$(cat "$T/ready" 2>/dev/null)
held=$(git -C "$T/c" rev-parse HEAD)
wvin c "$WV" add "made under a gate" --force >/dev/null 2>&1
wvin c "$WV" sync >/dev/null 2>&1
check "no checkpoint commit is made" "$held" "$(git -C "$T/c" rev-parse HEAD)"
pkill -9 -P "$HOLDER" 2>/dev/null; kill -9 "$HOLDER" 2>/dev/null; HOLDER=""; sleep 0.2
wvin c "$WV" sync >/dev/null 2>&1
check "...and once the gate is gone the next one is" "yes" \
    "$([ "$(git -C "$T/c" rev-parse HEAD)" != "$held" ] && echo yes || echo no)"

echo "Results: $pass/$run passed"
[ "$pass" -eq "$run" ]
