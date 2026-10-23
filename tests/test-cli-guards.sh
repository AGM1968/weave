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
export WV_TEST_SUITE=1  # the user's config.env cannot log this suite's wv calls (wv-6b0f57)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WV="$ROOT/scripts/wv"

run=0; pass=0
ok()  { run=$((run+1)); pass=$((pass+1)); echo "  ✓ $1"; }
bad() { run=$((run+1)); echo "  ✗ $1"; [ -n "${2:-}" ] && echo "      $2"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2], got [$3]"; fi; }

T=$(mktemp -d /tmp/wv-cli-guards-XXXXXX)
trap 'rm -rf "$T"' EXIT
export HOME="$T/home" WV_CONFIG_DIR="$T/config"
mkdir -p "$HOME" "$WV_CONFIG_DIR"

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

# Exact-query fault injection through the actual public CLI. Only the required
# findings row SELECT is refused; COUNT and schema/init queries use real sqlite.
# Match the two projection signatures, not all SELECTs or the optional count.
mkdir -p "$T/refuse-bin"
export FINDINGS_REAL_SQLITE
FINDINGS_REAL_SQLITE=$(command -v sqlite3)
cat > "$T/refuse-bin/sqlite3" <<'EOF'
#!/bin/bash
for arg in "$@"; do
    if [[ "$arg" == *"SELECT n.id, n.text, n.status, n.metadata FROM nodes n"* ]] ||
       [[ "$arg" == *"AS age_days,"* && "$arg" == *"FROM nodes n"* ]]; then
        echo 'test: required findings row query refused' >&2
        exit 73
    fi
done
exec "$FINDINGS_REAL_SQLITE" "$@"
EOF
chmod +x "$T/refuse-bin/sqlite3"
for format in text json; do
    args=(); [ "$format" = json ] && args+=(--json)
    out=$(PATH="$T/refuse-bin:$PATH" "$WV" findings list "${args[@]}" 2>"$T/findings.err")
    check "$format required query refusal exits 73" "73" "$?"
    check "$format failed query emits no empty-success output" "" "$out"
    check "$format reaches exact row-query refusal" "test: required findings row query refused" "$(cat "$T/findings.err")"
done
# Explicit handler guard: db_query helpers historically ignored db_ensure's
# status. This conditional call disables implicit errexit, as CLI wrappers can.
out=$(module wv-cmd-findings.sh '
db_ensure() { echo "test: init refused" >&2; return 73; }
db_query() { echo "unexpected query"; }
db_query_json() { echo "[]"; }
if cmd_findings_list --json; then exit 0; else exit $?; fi')
check "required initialization refusal exits 73" "73" "$?"
check "initialization refusal does not reach query/empty handling" "test: init refused" "$out"

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

echo "wv init: a database it cannot create is a failure, not '✓ Initialized' (wv-b98794)"
R2="$T/repo-unopenable"; mkdir -p "$R2"; (cd "$R2" && git init -q)
RO="$T/readonly"; mkdir -p "$RO"; chmod 500 "$RO"
for mode in fresh --force; do
    args=(); [ "$mode" = --force ] && args=(--force)
    out=$(cd "$R2" && WV_PROJECT_DIR="$R2" WV_HOT_ZONE="$RO/zone" "$WV" init "${args[@]}" 2>&1)
    rc=$?
    check "init ($mode) exits nonzero" "nonzero" "$([ "$rc" -ne 0 ] && echo nonzero || echo zero)"
    check "init ($mode) prints no success line" "0" "$(grep -c 'Initialized Weave' <<<"$out")"
done
chmod 700 "$RO"

echo "wv init: the zone's owner is the git toplevel when nothing contradicts it, else unrecorded (wv-29e416)"
P1="$T/owner-project"; P2="$T/owner-other"; NR="$T/owner-norepo"
mkdir -p "$P1" "$P2/sub" "$NR"; (cd "$P1" && git init -q); (cd "$P2" && git init -q)
P1=$(cd -P "$P1" && pwd); P2=$(cd -P "$P2" && pwd)
owner_of() { cat "$1/.repo_root" 2>/dev/null || echo unrecorded; }
(cd "$P2/sub" && unset WV_PROJECT_DIR && WV_HOT_ZONE="$T/zone-git" "$WV" init >/dev/null 2>&1)
check "the git toplevel, not the subdirectory" "$P2" "$(owner_of "$T/zone-git")"
(cd "$P2/sub" && unset WV_PROJECT_DIR && WV_HOT_ZONE="$T/zone-git" "$WV" init --force >/dev/null 2>&1)
check "init --force records it too" "$P2" "$(owner_of "$T/zone-git")"
(cd "$P2/sub" && WV_PROJECT_DIR="$P2" WV_HOT_ZONE="$T/zone-agree" "$WV" init >/dev/null 2>&1)
check "WV_PROJECT_DIR naming the same repository agrees" "$P2" "$(owner_of "$T/zone-agree")"
# test-core's shape: init from one repository, the zone used from WV_PROJECT_DIR.
(cd "$P2/sub" && WV_PROJECT_DIR="$P1" WV_HOT_ZONE="$T/zone-named" "$WV" init >/dev/null 2>&1)
check "WV_PROJECT_DIR naming another repository leaves it unrecorded" "unrecorded" "$(owner_of "$T/zone-named")"
(cd "$P1" && WV_PROJECT_DIR="$P1" WV_HOT_ZONE="$T/zone-named" "$WV" status >/dev/null 2>&1)
check "so the named project's later calls are accepted" "0" "$?"
# test-commit-refs' shape: WV_PROJECT_DIR a parent, the zone used from the toplevel.
(cd "$P2/sub" && WV_PROJECT_DIR="$T" WV_HOT_ZONE="$T/zone-parent" "$WV" init >/dev/null 2>&1)
check "WV_PROJECT_DIR naming a parent leaves it unrecorded" "unrecorded" "$(owner_of "$T/zone-parent")"
(cd "$P2" && WV_PROJECT_DIR="$T" WV_HOT_ZONE="$T/zone-parent" "$WV" status >/dev/null 2>&1)
check "so the toplevel's later calls are accepted" "0" "$?"
# the MCP suite's shape: init from a scratch directory, the zone used from a repository.
(cd "$NR" && unset WV_PROJECT_DIR && WV_HOT_ZONE="$T/zone-norepo" "$WV" init >/dev/null 2>&1)
check "outside any repository nothing is recorded" "unrecorded" "$(owner_of "$T/zone-norepo")"
(cd "$P1" && unset WV_PROJECT_DIR && WV_HOT_ZONE="$T/zone-norepo" "$WV" status >/dev/null 2>&1)
check "so a repository using that zone afterwards is not refused" "0" "$?"

echo ""
echo "Results: $pass/$run passed"
[ "$pass" -eq "$run" ]
