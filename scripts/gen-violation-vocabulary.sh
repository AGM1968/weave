#!/usr/bin/env bash
# Compile contracts/violation-vocabulary-v1.json into the shell projection.
#
# The catalog is the source of truth; Bash reads a generated fragment rather
# than parsing JSON on every invocation. Keeping the projection under
# scripts/lib/ puts it inside the E6 implementation-source closure automatically
# (the runner globs scripts/lib/*.sh), so no runner-manifest edit is needed --
# but it also means regenerating it is a hash-bound change.
#
# Usage: scripts/gen-violation-vocabulary.sh [--check]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CATALOG="$ROOT/contracts/violation-vocabulary-v1.json"
GENERATED="$ROOT/scripts/lib/wv-violation-vocabulary.gen.sh"
CHECK_ONLY=false
[ "${1:-}" != "--check" ] || CHECK_ONLY=true

[ -f "$CATALOG" ] || { echo "gen-violation-vocabulary: missing $CATALOG" >&2; exit 1; }

emit() {
    local output="$1" types
    # Sorted so the projection is a pure function of the catalog's content and
    # not of its key order: a reordered catalog must not produce a different
    # file, or every reorder would invalidate the E6 receipts for nothing.
    types=$(python3 -c "
import json, sys
catalog = json.load(open(sys.argv[1], encoding='utf-8'))
names = sorted(catalog['types'])
if not names:
    raise SystemExit('violation vocabulary is empty')
for name in names:
    if any(ch.isspace() or ch == \"'\" for ch in name):
        raise SystemExit(f'violation type {name!r} is unusable in a space-delimited shell list')
print(' '.join(names))
" "$CATALOG")

    {
        printf '%s\n' '# GENERATED FROM contracts/violation-vocabulary-v1.json — do not edit.'
        printf '%s\n' '# Regenerate with: scripts/gen-violation-vocabulary.sh'
        printf '%s\n' '# shellcheck shell=bash'
        printf '%s\n' ''
        printf '%s\n' '# Space-delimited canonical finding.violation_type values. The catalog is'
        printf '%s\n' '# authoritative; this projection exists so the validator does not parse JSON'
        printf '%s\n' '# on every wv invocation.'
        printf 'FINDING_VIOLATION_TYPES="%s"\n' "$types"
    } > "$output"
}

if [ "$CHECK_ONLY" = true ]; then
    tmp=$(mktemp)
    trap 'rm -f "$tmp"' EXIT
    emit "$tmp"
    if ! cmp -s "$tmp" "$GENERATED"; then
        echo "gen-violation-vocabulary: $GENERATED is stale — run scripts/gen-violation-vocabulary.sh" >&2
        diff -u "$GENERATED" "$tmp" >&2 || true
        exit 1
    fi
    echo "violation vocabulary projection is current"
    exit 0
fi

emit "$GENERATED"
echo "wrote $GENERATED"
