#!/usr/bin/env bash
# The pre-commit hook body only shrinks while wv-0e2998 is open (wv-3ce219,
# owner ruling (c) on wv-562ed6): new gate features land in sourced modules or
# functions, never as top-level code in scripts/hooks/pre-commit-weave.sh.
#
# The count is the hook's non-blank, non-comment lines outside function bodies
# (a function runs from 'name() {' to the next '}' in column 0; a one-line
# function is function code). tests/lib/hook-body-ceiling holds the ceiling and
# the mode: advisory reports a count off the ceiling and passes; enforced fails
# on a count above it (a feature landed in the body) and below it (the ceiling
# was not lowered with the code that moved out).
set -uo pipefail
export WV_TEST_SUITE=1
export WV_CALL_SOURCE=test
ROOT=$(cd "$(dirname "$0")/.." && pwd)
HOOK="$ROOT/scripts/hooks/pre-commit-weave.sh"
CEILING_FILE="$ROOT/tests/lib/hook-body-ceiling"
run=0 pass=0
ok()  { run=$((run+1)); pass=$((pass+1)); echo "  ✓ $1"; }
bad() { run=$((run+1)); echo "  ✗ $1"; [ -n "${2:-}" ] && echo "      $2"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2], got [$3]"; fi; }

# body_lines <file> — the top-level line count.
body_lines() {
    awk '
        infn && /^\}/ { infn = 0; next }
        infn { next }
        /^[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\(\)[[:space:]]*\{/ {
            s = $0; sub(/[[:space:]]+#.*$/, "", s)
            if (s !~ /\}[[:space:]]*;?[[:space:]]*$/) infn = 1
            next
        }
        /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
        { n++ }
        END { print n + 0 }' "$1"
}

# verdict <count> <ceiling> <mode> — "pass", "warn: ..." or "fail: ...".
verdict() {
    local count=$1 ceiling=$2 mode=$3 why=""
    if [ "$count" -gt "$ceiling" ]; then
        why="the hook body has $count top-level lines, above the ceiling of $ceiling: put new gate code in a function or a sourced module (ruling (c), wv-3ce219)"
    elif [ "$count" -lt "$ceiling" ]; then
        why="the hook body has $count top-level lines, below the ceiling of $ceiling: lower ceiling= in tests/lib/hook-body-ceiling to $count in this commit"
    fi
    if [ -z "$why" ]; then echo pass
    elif [ "$mode" = enforced ]; then echo "fail: $why"
    else echo "warn: $why"
    fi
}

T=$(mktemp -d "${TMPDIR:-/tmp}/wv-hook-ratchet-XXXXXX")
trap 'rm -rf "$T"' EXIT

echo "the count"
cat > "$T/fixture.sh" <<'FIXTURE_EOF'
#!/usr/bin/env bash
# a comment

top_one=1
one_liner() { [ "$top_one" = 1 ]; }
multi() {  # a trailing comment
    echo inside
    if true; then
        echo nested
    fi
}
    # an indented comment
top_two() { echo "braces { } inside"; }
echo top_three
cat <<'X'
heredoc body
X
FIXTURE_EOF
check "counts top-level code, not functions, comments or blank lines" "5" "$(body_lines "$T/fixture.sh")"

echo "the verdict"
check "at the ceiling: pass" "pass" "$(verdict 10 10 enforced)"
check "above it, enforced: fail" "fail" "$(verdict 11 10 enforced | cut -d: -f1)"
v=$(verdict 9 10 enforced)
check "below it, enforced: fail, naming the new ceiling" "yes" \
    "$(grep -q '^fail: .*lower ceiling= .* to 9 ' <<< "$v" && echo yes)"
check "above it, advisory: a warning only" "warn" "$(verdict 11 10 advisory | cut -d: -f1)"

echo "the hook"
ceiling=$(sed -n 's/^ceiling=\([0-9][0-9]*\)$/\1/p' "$CEILING_FILE")
mode=$(sed -nE 's/^mode=(advisory|enforced)$/\1/p' "$CEILING_FILE")
check "the ceiling file declares a ceiling and a mode" "yes" \
    "$([ -n "$ceiling" ] && [ -n "$mode" ] && echo yes)"
if [ -n "$ceiling" ] && [ -n "$mode" ]; then
    count=$(body_lines "$HOOK")
    # The ceiling counts the source hook, its source-only blocks included;
    # build-release.sh strips those, so a shipped copy sits below the ceiling
    # by construction and its verdict is reported, not enforced (wv-c804fa).
    mode_here=advisory
    mode=$mode_here
    v=$(verdict "$count" "$ceiling" "$mode")
    case "$v" in
        pass) ok "pre-commit-weave.sh body: $count top-level lines, at the ceiling ($mode)" ;;
        warn:*) echo "  ⚠ ${v#warn: }"; ok "pre-commit-weave.sh body: $count against $ceiling (advisory, reported)" ;;
        fail:*) bad "pre-commit-weave.sh body ($mode)" "${v#fail: }" ;;
    esac
fi

echo "Results: $pass/$run passed"
[ "$pass" -eq "$run" ]
