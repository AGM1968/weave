#!/bin/bash
# route-reach-measure.sh <outdir> <suite> — run one suite alone under strace for
# the route-reach measurement (wv-be5057); tests/lib/route-reach-classify.py
# reads what it writes. Run from the repository root with the tree under test
# installed (./install.sh), so a suite calling the installed wv opens the same
# modules. Several can run in parallel: xargs -P4 -I{} <this> <outdir> {} < row.
#
# Keeps only process lineage (clone/fork/execve) and opens of command modules.
# Never add -v: it prints every process environment, secrets included.
set -u
out="$1"
suite="$2"
name=$(basename "$suite" .sh)
start=$(date +%s)
GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=/dev/null \
    strace -f -qq -s 256 -e trace=openat,execve,clone,clone3,fork,vfork -e status=successful \
    -o "|grep -E 'execve\\(|clone|fork|wv-cmd-[a-z]+\\.sh' > '$out/$name.trace'" \
    bash "$suite" >"$out/$name.out" 2>&1
rc=$?
echo "$suite rc=$rc secs=$(($(date +%s) - start))" | tee -a "$out/runs.txt"
