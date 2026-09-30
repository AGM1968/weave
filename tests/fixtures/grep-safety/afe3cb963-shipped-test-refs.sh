#!/usr/bin/env bash
# afe3cb963 (wv-4351d6) landed this line in tests/test-shipped-test-refs.sh:50.
# A deliberately unsafe example: an unbarriered variable grep in an early-exit
# pipeline under pipefail. Replayed by tests/test-map-coverage.sh (wv-b21ca8).
set -euo pipefail
    if grep -vF "${removed_suites[@]/#/-e}" "$tree/$f" | grep -qIE -- "$pattern"; then
        echo hit
    fi
