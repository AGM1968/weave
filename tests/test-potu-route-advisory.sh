#!/usr/bin/env bash
# Suite-driven wv calls are tagged test so call-stats retro reads can exclude them.
export WV_CALL_SOURCE=test
# The PostToolUse edit advisory for a suite under a measured route retirement
# (wv-99c9f8): a suite whose bytes no longer match the sha256 in its
# .weave/route-evidence/<node>.json is refused by test-map-coverage.sh mid-gate,
# so the edit itself must say so and name the re-measure procedure. Silent for a
# suite still at its measured bytes, one with no evidence-backed retirement, and
# a repository with no route evidence at all. Runs the real Claude Code adapter
# against a scratch repository.
set -uo pipefail
export WV_TEST_SUITE=1
ROOT=$(cd "$(dirname "$0")/.." && pwd)
HOOK="$ROOT/.claude/hooks/post-edit-lint.sh"
run=0 pass=0
ok()  { run=$((run+1)); pass=$((pass+1)); echo "  ✓ $1"; }
bad() { run=$((run+1)); echo "  ✗ $1"; [ -n "${2:-}" ] && echo "      $2"; }
has()   { if grep -qF -- "$3" <<< "$2"; then ok "$1"; else bad "$1" "missing [$3] in: $2"; fi; }
empty() { if [ -z "$2" ]; then ok "$1"; else bad "$1" "expected no advisory, got: $2"; fi; }

T=$(mktemp -d "${TMPDIR:-/tmp}/wv-potu-route-XXXXXX")
trap 'rm -rf "$T"' EXIT
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
R="$T/repo"
mkdir -p "$R/tests" "$R/.weave/route-evidence"
git -C "$R" init -q
printf '#!/bin/bash\n"$WV" list\n' > "$R/tests/test-probe.sh"
printf '#!/bin/bash\necho other\n' > "$R/tests/test-other.sh"
printf 'wv-000001 tests/test-probe.sh = scripts/cmd/wv-cmd-ops.sh\nwv-000002 tests/test-other.sh = scripts/cmd/wv-cmd-ops.sh\n' \
    > "$R/.weave/test-map-retired.conf"
sha=$(sha256sum "$R/tests/test-probe.sh" | cut -d' ' -f1)
# The multi-module shape (wv-be5057); wv-000002 has no evidence file.
jq -n --arg sha "$sha" \
    '{node:"wv-000001",modules:{"scripts/cmd/wv-cmd-ops.sh":{suites:{"tests/test-probe.sh":{sha256:$sha,reach:[],wv_cmds:["list"]}}}}}' \
    > "$R/.weave/route-evidence/wv-000001.json"

# advise <file> — the additionalContext the adapter emits for an Edit of <file>.
advise() {
    jq -cn --arg p "$1" '{tool_name:"Edit",tool_input:{file_path:$p},tool_response:{success:true}}' \
        | (cd "$R" && bash "$HOOK") 2>/dev/null | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null
}

echo "route-evidence edit advisory"
empty "(control) a suite still at its measured bytes gets no advisory" "$(advise "$R/tests/test-probe.sh")"
printf '# edited\n' >> "$R/tests/test-probe.sh"
out=$(advise "$R/tests/test-probe.sh")
has "an edited suite under a measured retirement is named" "$out" "tests/test-probe.sh carries a measured route retirement (wv-000001)"
# The gate check it names does not ship, so the release closure forbids naming
# it here; the advisory's own text carries it.
has "...saying the commit will be refused" "$out" "will refuse the commit"
has "...the re-measure tools" "$out" "tests/lib/route-reach-measure.sh"
has "...where the evidence lives" "$out" ".weave/route-evidence/<node>.json"
has "...and the guide section" "$out" "docs/DEVELOPMENT.md, Route Evidence"
printf '# edited\n' >> "$R/tests/test-other.sh"
empty "a retirement with no evidence file gets no advisory" "$(advise "$R/tests/test-other.sh")"
printf '#!/bin/bash\n' > "$R/tests/test-unlisted.sh"
empty "a suite with no retirement gets no advisory" "$(advise "$R/tests/test-unlisted.sh")"
rm "$R/.weave/test-map-retired.conf"
empty "a repository with no retirements gets no advisory" "$(advise "$R/tests/test-probe.sh")"

echo "Results: $pass/$run passed"
[ "$pass" -eq "$run" ]
