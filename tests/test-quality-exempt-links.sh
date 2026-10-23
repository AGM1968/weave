#!/usr/bin/env bash
# Every quality-gate exemption names the node that decided it (wv-c874a1).
# .weave/quality.conf [exempt] entries switch off the close gate's complexity,
# trend and test clauses for a path, and they used to accumulate as "CC is
# structural" with nothing tracking their removal. An entry must now carry a
# wv-xxxxxx reference to a node in the committed graph: product code points at
# its decomposition plan, non-product paths at the decision that scoped them out.
# The repository's shell ceiling may only move down from the schema default.
set -uo pipefail
export WV_TEST_SUITE=1  # the user's config.env cannot log this suite's wv calls (wv-6b0f57)
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
run=0; pass=0
ok()  { run=$((run+1)); pass=$((pass+1)); echo "  ✓ $1"; }
bad() { run=$((run+1)); echo "  ✗ $1"; [ -n "${2:-}" ] && echo "      $2"; }
TMP=$(mktemp -d /tmp/wv-quality-exempt-links-XXXXXX)
trap 'rm -rf "$TMP"' EXIT

# unlinked <quality.conf> <nodes.jsonl> -> one line per [exempt] entry that names
# no node, or names one the graph does not hold
unlinked() {
    local section="" line entry ref
    while IFS= read -r line; do
        if [[ "$line" =~ ^\[([a-z_]+)\] ]]; then section="${BASH_REMATCH[1]}"; continue; fi
        [ "$section" = "exempt" ] || continue
        entry="${line%%#*}"; entry="${entry// /}"
        [ -n "$entry" ] || continue
        ref=$(grep -oE 'wv-[0-9a-f]{6}' <<< "$line" | sed -n 1p)
        if [ -z "$ref" ]; then
            echo "$entry names no node"
        elif ! grep -q "\"id\":\"$ref\"" "$2"; then
            echo "$entry names $ref, which the graph does not hold"
        fi
    done < "$1"
}

CONF="$ROOT/.weave/quality.conf"
NODES="$ROOT/.weave/nodes.jsonl"
if [ ! -f "$CONF" ]; then
    echo "  - no .weave/quality.conf in this tree; not asserted"
    echo "Results: 0/0 passed"
    exit 0
fi

echo "=== every exemption names its node ==="
out=$(unlinked "$CONF" "$NODES")
[ -z "$out" ] && ok "every [exempt] entry names a node in the committed graph" ||
    bad "every [exempt] entry names a node in the committed graph" "$out"

echo "=== the shell ceiling only steps down ==="
ceiling=$(sed -n '/^\[thresholds\]/,/^\[/{s/^mccabe_max_sh[[:space:]]*=[[:space:]]*\([0-9]*\).*/\1/p}' "$CONF")
default=$(grep -oE "'mccabe_max_sh', [0-9]+" "$ROOT/scripts/lib/wv-db.sh" | sed -n 1p | grep -oE '[0-9]+$')
if [ -z "$ceiling" ]; then
    ok "no repository shell ceiling set; the schema default ($default) applies"
elif [ -n "$default" ] && [ "$ceiling" -le "$default" ]; then
    ok "the repository shell ceiling ($ceiling) is at or below the schema default ($default)"
else
    bad "the repository shell ceiling ($ceiling) is at or below the schema default (${default:-unknown})"
fi

echo "=== the check fails closed ==="
printf '[exempt]\nscripts/new-debt.sh  # CC is structural\n' > "$TMP/no-ref.conf"
[[ "$(unlinked "$TMP/no-ref.conf" "$NODES")" == "scripts/new-debt.sh names no node" ]] &&
    ok "an exemption that names no node is refused" || bad "an exemption that names no node is refused"
printf '[exempt]\nscripts/new-debt.sh  # plan wv-000000\n' > "$TMP/bad-ref.conf"
[[ "$(unlinked "$TMP/bad-ref.conf" "$NODES")" == *"names wv-000000, which the graph does not hold" ]] &&
    ok "an exemption naming a node the graph does not hold is refused" ||
    bad "an exemption naming a node the graph does not hold is refused"
printf '[exempt]\n# a comment naming nothing\n\n[thresholds]\nnot_an_entry = 1\n' > "$TMP/comments.conf"
[ -z "$(unlinked "$TMP/comments.conf" "$NODES")" ] &&
    ok "comments, blank lines and other sections are not entries" ||
    bad "comments, blank lines and other sections are not entries"

echo "Results: $pass/$run passed"
[ "$pass" -eq "$run" ]
