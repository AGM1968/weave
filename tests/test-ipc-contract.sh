#!/bin/bash
set -euo pipefail
export WV_TEST_SUITE=1  # the user's config.env cannot log this suite's wv calls (wv-6b0f57)
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
node "$ROOT/tests/validate-ipc-contract.mjs"
query_help=$("$ROOT/scripts/wv" query --help)
[[ "$query_help" == *"--format"* ]] || { echo "query --format missing" >&2; exit 1; }
[[ "$query_help" != *"--json-v2"* ]] || { echo "query --json-v2 unexpectedly accepted" >&2; exit 1; }
preflight_help=$("$ROOT/scripts/wv" preflight --help)
[[ "$preflight_help" == *"node"* ]] || { echo "preflight node argument missing" >&2; exit 1; }
printf 'Results: 1/1 passed\n'
