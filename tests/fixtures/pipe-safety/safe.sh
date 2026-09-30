#!/usr/bin/env bash
# Safe shapes under pipefail. None is skipped by a special case: the rule only
# matches a last stage that can leave before consuming its input.
set -euo pipefail

grep -q 'needle' <<< "$value"          # herestring: no writer process at all
grep -q 'needle' "$file"               # not a pipeline
producer | wc -l                       # consumes all input
producer | tail -5                     # consumes all input
producer | sort                        # consumes all input
producer | awk '{ print $1 }'          # consumes all input
producer | cat                         # consumes all input
producer | grep 'needle'               # no -q: reads to the end
producer | sed 's/a/b/'                # no q command
producer | tr -d ' '                   # consumes all input
echo "a|b" | wc -c                     # a pipe inside quotes is not a stage
producer | grep -E 'a|b'               # alternation is not a stage boundary
