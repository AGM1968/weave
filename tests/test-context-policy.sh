#!/usr/bin/env bash
# test-context-policy.sh — `wv context-policy`, the context load policy every
# harness reads (wv-f757a4): the Claude SessionStart hook and MCP weave_overview
# both call it. Driven against this checkout's scripts/wv in fixture repos.
set -uo pipefail
export WV_CALL_SOURCE=test

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WV="$ROOT/scripts/wv"

run=0; pass=0
ok()  { run=$((run+1)); pass=$((pass+1)); echo "  ✓ $1"; }
bad() { run=$((run+1)); echo "  ✗ $1"; [ -n "${2:-}" ] && echo "$2" | sed 's/^/      /'; }

T=$(mktemp -d "${TMPDIR:-/tmp}/wv-context-policy-XXXXXX")
trap 'rm -rf "$T"' EXIT

# make_repo <dir> <nodes.jsonl lines, or "none" for no .weave/>
make_repo() {
    mkdir -p "$1"
    git -C "$1" init -q
    for i in 1 2 3; do echo "x=$i" > "$1/m$i.py"; done
    if [ "$2" != "none" ]; then
        mkdir -p "$1/.weave"
        for _ in $(seq 1 "$2"); do echo '{}'; done > "$1/.weave/nodes.jsonl"
    fi
    git -C "$1" add -A
    git -C "$1" -c commit.gpgsign=false -c user.email=t@t -c user.name=t commit -qm init
}
policy() {  # policy <repo> [args...] -> JSON on stdout
    local repo="$1"; shift
    (cd "$repo" && env -u POLICY_CACHE WV_HOT_ZONE="$T/hot-$(basename "$repo")" "$WV" context-policy --json "$@")
}

echo "wv context-policy"

make_repo "$T/small" 5
out=$(policy "$T/small")
[ "$(jq -r '.policy + "|" + .reasons[0] + "|" + (.cached|tostring)' <<< "$out")" = "HIGH|small/fresh workspace|false" ] \
    && ok "a small repository is HIGH, freshly computed" || bad "a small repository is HIGH, freshly computed" "$out"
[ "$(head -1 "$T/small/.weave/.context_policy" 2>/dev/null)" = "HIGH" ] \
    && ok "the decision is cached in .weave/.context_policy" || bad "the decision is cached in .weave/.context_policy"

make_repo "$T/big" 150
out=$(policy "$T/big")
[ "$(jq -r '.policy + "|" + .reasons[0]' <<< "$out")" = "LOW|large Weave history (150 nodes)" ] \
    && ok "a large Weave history makes the policy LOW, naming why" || bad "a large Weave history makes the policy LOW, naming why" "$out"

# Within the hour the cache answers, even once the repository has grown; --refresh recomputes.
for _ in $(seq 1 200); do echo '{}'; done >> "$T/small/.weave/nodes.jsonl"
out=$(policy "$T/small")
[ "$(jq -r '.policy + "|" + (.cached|tostring)' <<< "$out")" = "HIGH|true" ] \
    && ok "a fresh cache answers without recomputing" || bad "a fresh cache answers without recomputing" "$out"
out=$(policy "$T/small" --refresh)
[ "$(jq -r '.policy + "|" + (.cached|tostring)' <<< "$out")" = "LOW|false" ] \
    && ok "--refresh recomputes and replaces the cache" || bad "--refresh recomputes and replaces the cache" "$out"
touch -d "2 hours ago" "$T/big/.weave/.context_policy"
out=$(policy "$T/big")
[ "$(jq -r '.cached|tostring' <<< "$out")" = "false" ] \
    && ok "a cache older than an hour is recomputed" || bad "a cache older than an hour is recomputed" "$out"

printf 'repo notes\n' > "$T/big/.weave/runtime.md"
policy "$T/big" --refresh >/dev/null
if grep -qxF -- 'Current context policy: LOW' "$T/big/.weave/runtime.md" \
        && grep -qxF -- 'repo notes' "$T/big/.weave/runtime.md"; then
    ok "runtime.md gains the policy block and keeps its own text"
else
    bad "runtime.md gains the policy block and keeps its own text" "$(cat "$T/big/.weave/runtime.md")"
fi

make_repo "$T/bare" none
out=$(policy "$T/bare")
if [ "$(jq -r .policy <<< "$out")" = "HIGH" ] && [ ! -e "$T/bare/.weave" ]; then
    ok "an uninitialised repository gets a policy and no .weave/"
else
    bad "an uninitialised repository gets a policy and no .weave/" "$out; $(ls -a "$T/bare")"
fi

# It reads no graph: no hot-zone database appears for any fixture.
if [ -z "$(find "$T" -name brain.db 2>/dev/null)" ]; then
    ok "no graph database is created or loaded"
else
    bad "no graph database is created or loaded" "$(find "$T" -name brain.db)"
fi

text=$(cd "$T/big" && WV_HOT_ZONE="$T/hot-big" "$WV" context-policy 2>&1)
[ "$(head -1 <<< "$text")" = "policy: LOW" ] \
    && ok "text output leads with the policy: line MCP and the hook read" || bad "text output leads with the policy: line MCP and the hook read" "$text"

err=$(cd "$T/big" && WV_HOT_ZONE="$T/hot-big" "$WV" context-policy --bogus 2>&1) && rc=0 || rc=$?
[ "$rc" = "2" ] && grep -qF -- 'unknown argument: --bogus' <<< "$err" \
    && ok "an unknown argument is refused" || bad "an unknown argument is refused" "rc=$rc $err"

echo ""
echo "Results: $pass/$run passed"
[ "$pass" -eq "$run" ]
