#!/usr/bin/env bash
# The same unsafe shapes WITHOUT pipefail. The pipeline reports the last stage's
# own status, so the bug cannot occur and the scanner must not report these.
set -eu

producer | grep -q 'needle'
producer | head -5
