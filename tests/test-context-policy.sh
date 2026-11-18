#!/usr/bin/env bash
# test-context-policy.sh — `wv context-policy`, the context load policy every
# harness reads (wv-f757a4): SessionStart (through wv hook dispatch) and MCP
# weave_overview both call it. Driven against this checkout's scripts/wv in fixture repos.
set -uo pipefail
export WV_TEST_SUITE=1  # the user's config.env cannot log this suite's wv calls (wv-6b0f57)
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

# wv-eb061d: what a level means has one source, the directives context-policy
# emits; every surface renders them instead of restating the numbers.
out=$(policy "$T/big")
[ "$(jq -c '.directives | [.search_first, .whole_read_max_lines, .slice_max_lines, .summarise, (.text | length)]' <<< "$out")" \
        = '["always",null,200,true,3]' ] \
    && ok "--json carries the LOW directives" || bad "--json carries the LOW directives" "$out"
out=$(policy "$T/bare")
[ "$(jq -c '.directives | [.search_first, .whole_read_max_lines, .slice_max_lines, .summarise]' <<< "$out")" \
        = '["large_files",500,null,false]' ] \
    && ok "--json carries the HIGH directives" || bad "--json carries the HIGH directives" "$out"
low_text=$(jq -r '.directives.text[]' <<< "$(policy "$T/big")")
first_directive=$(head -1 <<< "$low_text")

if [ "$(sed -n '3,$p' <<< "$text")" = "$(sed 's/^/- /' <<< "$low_text")" ]; then
    ok "text output lists the level's directives after the reason"
else
    bad "text output lists the level's directives after the reason" "$text"
fi
if grep -qxF -- "- $first_directive" "$T/big/.weave/runtime.md"; then
    ok "runtime.md carries the directives under the policy line"
else
    bad "runtime.md carries the directives under the policy line" "$(cat "$T/big/.weave/runtime.md")"
fi

guide=$(cd "$T/big" && WV_HOT_ZONE="$T/hot-big" "$WV" guide --topic=context 2>&1)
if [ -n "$low_text" ] && grep -qF -- "LOW    — $(tr '\n' ' ' <<< "$low_text" | sed 's/ $//')" <<< "$guide" \
        && [ "$(grep -cE '^  (HIGH|MEDIUM|LOW) +— ' <<< "$guide")" = "3" ]; then
    ok "wv guide --topic=context lists every level from the directives"
else
    bad "wv guide --topic=context lists every level from the directives" "$guide"
fi

# The SessionStart line reads counts and the primary node from wv status --json
# (wv-a84f42). A stub wv answers status from STUB_STATUS (or fails when it is
# unset) and passes context-policy to the real one.
cat > "$T/stub-wv" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = "status" ]; then
    [ -n "${STUB_STATUS:-}" ] || exit 1
    printf '%s\n' "$STUB_STATUS"; exit 0
fi
# The real wv must not see WV naming this stub, or it calls back into it.
WV="$REAL_WV" exec "$REAL_WV" "$@"
STUB
chmod +x "$T/stub-wv"
summary_line() {  # summary_line <status JSON, or empty for a failing status>
    # The real wv's path is taken before WV names the stub, or the stub execs itself.
    local real_wv="$WV"
    (cd "$T/big" && REAL_WV="$real_wv" WV="$T/stub-wv" STUB_STATUS="$1" WV_HOT_ZONE="$T/hot-big" bash -c \
        'source "$2"; _ss_summary_line' _ "$1" "$ROOT/scripts/lib/wv-session-start.sh" 2>&1)
}
summary=$(summary_line '{"active":1,"ready":2,"blocked":3,"current":{"id":"wv-plan-x"}}')
if [ "$(head -1 <<< "$summary")" = "Weave: 1 active, 2 ready, 3 blocked | policy=LOW | current=wv-plan-x" ] \
        && [ "$(sed -n 2p <<< "$summary")" = "Context policy LOW: $(tr '\n' ' ' <<< "$low_text" | sed 's/ $//')" ]; then
    ok "the SessionStart line takes counts and the primary from status --json; the next line states the directives"
else
    bad "the SessionStart line takes counts and the primary from status --json; the next line states the directives" "$summary"
fi
summary=$(summary_line "")
if [ "$(head -1 <<< "$summary")" = "Weave: status unavailable (wv status --json failed) | policy=LOW | current=unknown" ]; then
    ok "a failing status --json is reported, not printed as an empty graph"
else
    bad "a failing status --json is reported, not printed as an empty graph" "$summary"
fi

# context-guard.sh retired (wv-26fda8): wv context-policy is the policy, wv
# bootstrap readiness carries the stale-findings warning. No copy of the script
# remains, and install.sh removes an installed one rather than shipping it.
if [ ! -e "$ROOT/.claude/hooks/context-guard.sh" ] && [ ! -e "$ROOT/scripts/context-guard.sh" ]; then
    ok "context-guard.sh is retired: no copy in the checkout"
else
    bad "context-guard.sh is retired: no copy in the checkout"
fi
cg_ship=$(grep -nE 'install_copy .*context-guard|curl .*context-guard' "$ROOT/install.sh" || true)
cg_prune=$(grep -cF '"$CONFIG_DIR/hooks/context-guard.sh"' "$ROOT/install.sh" || true)
if [ -z "$cg_ship" ] && [ "${cg_prune:-0}" -ge 2 ]; then
    ok "install.sh ships no context-guard.sh and removes the installed one (local and remote paths)"
else
    bad "install.sh ships no context-guard.sh and removes the installed one (local and remote paths)" "ship: $cg_ship prune: $cg_prune"
fi

err=$(cd "$T/big" && WV_HOT_ZONE="$T/hot-big" "$WV" context-policy --bogus 2>&1) && rc=0 || rc=$?
[ "$rc" = "2" ] && grep -qF -- 'unknown argument: --bogus' <<< "$err" \
    && ok "an unknown argument is refused" || bad "an unknown argument is refused" "rc=$rc $err"

echo ""
echo "Results: $pass/$run passed"
[ "$pass" -eq "$run" ]
