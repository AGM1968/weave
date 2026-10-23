#!/usr/bin/env bash
# The manifest must compile to both committed projections.
set -euo pipefail
export WV_TEST_SUITE=1  # the user's config.env cannot log this suite's wv calls (wv-6b0f57)

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bash "$ROOT/scripts/gen-workflow-classes.sh" --check
echo "workflow manifest projections are current"
