#!/usr/bin/env bash
# The manifest must compile to both committed projections.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bash "$ROOT/scripts/gen-workflow-classes.sh" --check
echo "workflow manifest projections are current"
