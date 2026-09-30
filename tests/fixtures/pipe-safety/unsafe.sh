#!/usr/bin/env bash
# Deliberately unsafe: every early-exit reader form, for the scanner to find.
# Not executed. Under pipefail each of these returns the writer's SIGPIPE 141
# when the reader leaves first, so a MATCH reports FAILURE.
set -euo pipefail

producer | grep -q 'needle'
producer | grep -qF 'needle'
producer | grep -l 'needle'
producer | grep -m 1 'needle'
producer | head -5
producer | head -n 20
producer | sed 2q
producer | sed -n '1p;q'
producer | read -r line
! producer | grep -q 'needle'
producer \
    | grep -q 'continued across lines'
producer | grep -oE 'x' | head -1
x=$(producer | grep -q 'inside a substitution' && echo yes || echo no)
producer |
    grep -q 'continued after a trailing pipe'
x=$(producer | grep -m1 'mid-pipeline reader' | cut -d' ' -f1)
