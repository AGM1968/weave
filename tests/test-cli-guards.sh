#!/usr/bin/env bash
# Suite-driven wv calls are tagged test so call-stats retro reads can exclude them.
export WV_CALL_SOURCE=test
# Guards in scripts/cmd that no routed suite exercised (wv-f45689), the CLI
# counterpart of test-lib-guards.sh. The S0 re-measure planted a break in each
# and every routed suite stayed green (S0 re-measure, wv-51427f):
#   wv memory           - bare 'wv memory' fails, 'wv memory --help' succeeds
#   wv show             - the Alias line appears only for a node with an alias
#   wv findings list    - its flags are read at all (a flipped loop test skipped them)
#   wv findings promote - --since-days reaches the Python selector
#   wv enrich-topology  - setting an epic's type keeps its other metadata
#   wv config test-gate - the starter test map offers a Node.js section when
#                         package.json exists, and only then
#   _hook_input_paths   - a file_path is extracted, which the guard against
#                         editing the installed wv depends on
#   _quality_conf_declares_exempt - a path the config exempts is recognised
#   _recover_delete     - delete recovery closes the GitHub issue once gh names
#                         the repository
# Commands run in an isolated repository and hot zone; helpers the CLI reaches
# only through GitHub or a denied close are driven directly with stubs.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WV="$ROOT/scripts/wv"

run=0; pass=0
ok()  { run=$((run+1)); pass=$((pass+1)); echo "  ✓ $1"; }
bad() { run=$((run+1)); echo "  ✗ $1"; [ -n "${2:-}" ] && echo "      $2"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2], got [$3]"; fi; }

T=$(mktemp -d /tmp/wv-cli-guards-XXXXXX)
trap 'rm -rf "$T"' EXIT

R="$T/repo"; mkdir -p "$R"
cd "$R" || exit 1
git init -q
git config user.name "CLI Guards"; git config user.email cli@example.com; git config commit.gpgsign false
unset WV_DB WEAVE_DIR
export WV_HOT_ZONE="$T/hot" WV_PROJECT_DIR="$R" WV_AGENT_ID=cli-guards-agent \
    WV_AUTO_CHECKPOINT=0 WV_REQUIRE_LEARNING=0 NO_COLOR=1
mkdir -p "$WV_HOT_ZONE"
"$WV" init >/dev/null 2>&1

# module <file> <shell code> — run code with one command module sourced and the
# colour variables it prints empty; stdout and stderr together.
module() {
    RED="" GREEN="" YELLOW="" CYAN="" NC="" bash -c "
source '$ROOT/scripts/cmd/$1' >/dev/null 2>&1
$2" 2>&1
}

echo "wv memory: a missing subcommand is an error, --help is not"
"$WV" memory >/dev/null 2>&1; check "bare 'wv memory' exits 1" "1" "$?"
"$WV" memory --help >/dev/null 2>&1; check "'wv memory --help' exits 0" "0" "$?"

echo "wv show: the Alias line follows the node"
A=$("$WV" add "cli guards aliased" --alias=cli-guards-alias --standalone 2>/dev/null | tail -1)
N=$("$WV" add "cli guards plain" --standalone 2>/dev/null | tail -1)
out=$("$WV" show "$A" 2>/dev/null | grep -c '^Alias:' || true)
check "a node with an alias shows it" "1" "$out"
out=$("$WV" show "$N" 2>/dev/null | grep -c '^Alias:' || true)
check "a node without one shows no Alias line" "0" "$out"

echo "wv findings list: its flags are read"
out=$("$WV" findings list --json 2>/dev/null | jq -e 'type == "array"' 2>/dev/null || echo "not json")
check "--json yields a JSON array" "true" "$out"

echo "wv findings promote: --since-days reaches the selector"
out=$(module wv-cmd-findings.sh '_wv_findings_python() { printf "%s\n" "$*"; }; cmd_findings_promote --since-days=45')
case "$out" in *"--since-days 45"*) out=forwarded ;; esac
check "--since-days=45 is passed on" "forwarded" "$out"

echo "wv enrich-topology: setting the epic type keeps the other metadata"
E=$("$WV" add "cli guards epic" --standalone --metadata='{"keep":"kept-value"}' 2>/dev/null | tail -1)
printf '{"epic":{"id":"%s","type":"epic"}}\n' "$E" > "$T/spec.json"
out=$("$WV" enrich-topology "$T/spec.json" --dry-run 2>/dev/null | grep -F -- "wv update '$E'" || true)
case "$out" in *'"keep":"kept-value"'*'"type":"epic"'*|*'"type":"epic"'*'"keep":"kept-value"'*) out=merged ;; esac
check "the planned update merges type into the existing metadata" "merged" "$out"

echo "wv config test-gate: the starter test map follows the repository's toolchain"
for pj in with without; do
    P="$T/init-$pj"; mkdir -p "$P"
    (cd "$P" && git init -q && { [ "$pj" = with ] && echo '{}' > package.json || true; }
     export WV_HOT_ZONE="$T/hot-$pj"; unset WV_PROJECT_DIR
     "$WV" init >/dev/null 2>&1; "$WV" config enable test-gate >/dev/null 2>&1 || true)
    if [ -f "$P/.weave/test-map.conf" ]; then
        out=$(grep -c '^# Node.js (package.json detected)' "$P/.weave/test-map.conf" || true)
    else
        out="no test-map"
    fi
    if [ "$pj" = with ]; then
        check "a repository with package.json gets the Node.js section" "1" "$out"
    else
        check "a repository without one does not" "0" "$out"
    fi
done

echo "_hook_input_paths: a file_path is extracted"
out=$(module wv-cmd-hook.sh '_hook_input_paths Edit "{\"file_path\":\"/home/u/.local/bin/wv\"}"')
check "the edited path is printed" "/home/u/.local/bin/wv" "$out"
out=$(module wv-cmd-hook.sh '_hook_input_paths Edit "{}"')
check "no path, no output" "" "$out"

echo "_quality_conf_declares_exempt: the config's exempt paths are recognised"
Q="$T/qconf"; mkdir -p "$Q"
printf '[exempt]\nscripts/legacy/\ntools/one.py  # single file\n' > "$Q/quality.conf"
for p in scripts/legacy/x.py tools/one.py tools/two.py; do
    out=$(WEAVE_DIR="$Q" module wv-cmd-data.sh "_quality_conf_declares_exempt '$p' && echo exempt || echo not")
    case "$p" in tools/two.py) want=not ;; *) want=exempt ;; esac
    check "$p is $want" "$want" "$out"
done

echo "_recover_delete: the GitHub issue is closed once gh names the repository"
B="$T/ghbin"; mkdir -p "$B"
cat > "$B/gh" <<EOF
#!/bin/sh
case "\$1 \$2" in
    "repo view") echo "owner/repo" ;;
    "issue close") echo "\$*" >> "$T/gh.log" ;;
esac
EOF
chmod +x "$B/gh"
PATH="$B:$PATH" module wv-cmd-ops.sh "_recover_delete '{\"gh_issue\":7,\"id\":\"wv-000001\"}' gh_close true" >/dev/null
check "issue #7 is closed in the named repository" "issue close 7 --repo owner/repo" "$(cat "$T/gh.log" 2>/dev/null)"

echo ""
echo "Results: $pass/$run passed"
[ "$pass" -eq "$run" ]
