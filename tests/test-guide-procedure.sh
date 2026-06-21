#!/usr/bin/env bash
# Procedure-guide contract: installed bodies are addressable by stable id.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_DIR=$(mktemp -d)
trap 'rm -rf "$CONFIG_DIR"' EXIT
mkdir -p "$CONFIG_DIR/procedures"
printf '%s\n' '# Session procedure' > "$CONFIG_DIR/procedures/session.md"

output=$(WV_CONFIG_DIR="$CONFIG_DIR" "$ROOT/scripts/wv" guide --procedure=session)
[ "$output" = '# Session procedure' ]

if WV_CONFIG_DIR="$CONFIG_DIR" "$ROOT/scripts/wv" guide --procedure=missing >/dev/null 2>&1; then
    echo "missing procedure unexpectedly succeeded" >&2
    exit 1
fi
if WV_CONFIG_DIR="$CONFIG_DIR" "$ROOT/scripts/wv" guide --procedure='../escape' >/dev/null 2>&1; then
    echo "invalid procedure id unexpectedly succeeded" >&2
    exit 1
fi

echo "Results: 3/3 passed"
