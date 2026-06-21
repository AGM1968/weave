#!/usr/bin/env bash
# Regression: test-hooks.sh must run when its caller inherited a deleted cwd.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DELETED_CWD=$(mktemp -d)
trap 'rm -rf "$DELETED_CWD"' EXIT

(
    cd "$DELETED_CWD"
    rmdir "$DELETED_CWD"
    bash "$ROOT/tests/test-hooks.sh" --cwd-smoke
)
# set -e aborts above on failure; reaching here means the regression passed.
# Emit the line run-all.sh parses so the suite counts as 1/1 rather than 0/0.
echo "Results: 1/1 passed"
