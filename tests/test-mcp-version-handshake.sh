#!/usr/bin/env bash
# The MCP server is rebuilt or the install fails, and its version is checked
# (wv-4cdc07). install.sh rebuilt the server only when npm was on PATH; with
# node found and npm absent (nvm unloaded in a non-interactive shell) it printed
# a red line and carried on, and wv mcp-status checked only that a bundle
# existed and started. A consumer ran an rc.10 server under an rc.18 CLI for
# every upgrade since. This suite installs from the working tree into a temp
# HOME with a PATH holding node but no npm, then with npm only beside the
# binary node links to, and runs mcp-status and doctor against stale,
# unversioned and matching bundles.
export WV_CALL_SOURCE=test
set -uo pipefail
export WV_TEST_SUITE=1
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WV="$PROJECT_ROOT/scripts/wv"
run=0; pass=0
ok()  { run=$((run+1)); pass=$((pass+1)); echo "  ✓ $1"; }
bad() { run=$((run+1)); echo "  ✗ $1"; [ -n "${2:-}" ] && echo "      $2"; }
TMP=$(cd "$(mktemp -d /tmp/wv-mcp-handshake-XXXXXX)" && pwd -P)
trap '[ -n "${KEEP_TMP:-}" ] || rm -rf "$TMP"' EXIT
REAL_NODE=$(command -v node 2>/dev/null || true)
if [ -z "$REAL_NODE" ]; then
    echo "SKIP: node not available"; echo "Results: 0/0 passed"; exit 0
fi
CLI_VERSION=$(tr -d '[:space:]' < "$PROJECT_ROOT/scripts/lib/VERSION")

echo "=== MCP server rebuild and version handshake (wv-4cdc07) ==="

# A PATH with every system tool except node, npm and npx.
SYS="$TMP/sysbin"; mkdir -p "$SYS"
IFS=: read -ra _dirs <<< "$PATH"
for d in "${_dirs[@]}"; do
    [ -d "$d" ] || continue
    for f in "$d"/*; do
        n=${f##*/}
        case "$n" in node|npm|npx|nodejs|corepack) continue ;; esac
        [ -x "$f" ] && [ ! -e "$SYS/$n" ] && ln -s "$f" "$SYS/$n"
    done
done

# Install from a clean clone of the working tree, as test-install-provenance.
SRC="$TMP/src"
git clone -q --shared "$PROJECT_ROOT" "$SRC"
git -C "$PROJECT_ROOT" ls-files -z | tar -C "$PROJECT_ROOT" --null --files-from=- -cf - | tar -C "$SRC" -xf -
git -C "$SRC" add -A
git -C "$SRC" -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -q -m tree >/dev/null 2>&1 || true

install_with() {  # install_with <label> <path-prefix>: rc in $rc, output in $TMP/<label>.out
    local home="$TMP/home-$1"
    mkdir -p "$home"
    ( cd "$SRC" && env -i HOME="$home" PATH="$2:$SYS" TERM=dumb USER="${USER:-u}" \
        WV_INSTALL_DIR="$home/bin" WV_LIB_DIR="$home/lib" WV_CONFIG_DIR="$home/config" \
        CLAUDE_CONFIG_DIR="$home/.claude" bash ./install.sh --with-mcp --no-ast-grep ) > "$TMP/$1.out" 2>&1
    rc=$?
}

# 1. node on PATH, npm nowhere: the install fails and its summary says why.
# A wrapper, not a symlink: the install looks beside the binary a link
# resolves to, and the system node may well have npm beside it.
mkdir -p "$TMP/only-node"
printf '#!/bin/sh\nexec "%s" "$@"\n' "$REAL_NODE" > "$TMP/only-node/node"; chmod +x "$TMP/only-node/node"
install_with nonpm "$TMP/only-node"
[ "$rc" -ne 0 ] && ok "an install that cannot rebuild the MCP server exits nonzero" \
    || bad "an install that cannot rebuild the MCP server exits nonzero" "rc=$rc"
grep -q "Install incomplete: npm not found on PATH or beside" "$TMP/nonpm.out" \
    && ok "the summary names the skipped rebuild and its cause" \
    || bad "the summary names the skipped rebuild and its cause" "$(tail -5 "$TMP/nonpm.out" | tr '\n' ' ')"
grep -q "weave-mcp     — MCP server" "$TMP/nonpm.out" \
    && bad "the summary does not list a server it did not build" || ok "the summary does not list a server it did not build"

# 2. node symlinked onto PATH from a directory that also holds npm (nvm's
# layout): the install finds npm beside the binary and builds with it.
REAL="$TMP/nvm/bin"; LINKS="$TMP/links"; mkdir -p "$REAL" "$LINKS"
printf '#!/bin/sh\nexec "%s" "$@"\n' "$REAL_NODE" > "$REAL/node"
cat > "$REAL/npm" <<'NPM'
#!/bin/sh
echo "npm $*" >> "$NPM_LOG"
if [ "$1" = run ] && [ "$2" = build ]; then
    mkdir -p dist
    { echo '// fixture bundle'; i=0; while [ $i -lt 40 ]; do echo '// padding line for the bundle size check'; i=$((i+1)); done
      echo 'process.stdout.write(JSON.stringify({schema:"weave-mcp-startup.v1",status:"pass",scope:"lite",tools:1}));'; } > dist/index.js
fi
exit 0
NPM
chmod +x "$REAL/node" "$REAL/npm"
ln -s "$REAL/node" "$LINKS/node"
export NPM_LOG="$TMP/npm.log"
( cd "$SRC" && env -i HOME="$TMP/home-beside" PATH="$LINKS:$SYS" TERM=dumb USER="${USER:-u}" NPM_LOG="$NPM_LOG" \
    WV_INSTALL_DIR="$TMP/home-beside/bin" WV_LIB_DIR="$TMP/home-beside/lib" WV_CONFIG_DIR="$TMP/home-beside/config" \
    CLAUDE_CONFIG_DIR="$TMP/home-beside/.claude" bash ./install.sh --with-mcp --no-ast-grep ) > "$TMP/beside.out" 2>&1
rc=$?
[ "$rc" -eq 0 ] && ok "with npm beside the linked node binary the install succeeds" \
    || bad "with npm beside the linked node binary the install succeeds" "rc=$rc: $(grep -m3 '✗' "$TMP/beside.out" | tr '\n' ' ')"
grep -qF -- "Using npm beside node: $REAL/npm" "$TMP/beside.out" && grep -q "npm run build" "$NPM_LOG" 2>/dev/null \
    && ok "the install used the npm beside node to build the server" \
    || bad "the install used the npm beside node to build the server" "$(grep -m2 -i npm "$TMP/beside.out" | tr '\n' ' ')"

# 3. mcp-status and doctor ask the bundle its version and fail a mismatch.
REPO="$TMP/repo"; mkdir -p "$REPO/mcp/dist"
git -C "$REPO" init -q
bundle() {  # bundle <version|-> : a bundle whose health check reports that version ("-" omits it)
    local v=""
    [ "$1" = - ] || v=",version:\"$1\""
    { echo '// fixture bundle'; i=0; while [ $i -lt 40 ]; do echo '// padding line for the bundle size check'; i=$((i+1)); done
      echo "process.stdout.write(JSON.stringify({schema:\"weave-mcp-startup.v1\",status:\"pass\",scope:\"lite\",tools:9${v}}));"; } > "$REPO/mcp/dist/index.js"
}
in_repo() {
    ( cd "$REPO" && WV_HOT_ZONE="$TMP/hz" WV_DB="$TMP/hz/brain.db" WV_CONFIG_DIR="$TMP/cfg" "$@" )
}
mkdir -p "$TMP/hz" "$TMP/cfg"
check_status() {  # check_status <label> <expected status> <version|->
    local out rc_s
    bundle "$3"
    out=$(in_repo "$WV" mcp-status --json 2>/dev/null); rc_s=$?
    local got
    got=$(jq -r '.checks[] | select(.check == "server version") | .status' <<< "$out" 2>/dev/null)
    if [ "$got" = "$2" ] && { [ "$2" = pass ] || [ "$rc_s" -ne 0 ]; }; then ok "$1"; else bad "$1" "status=$got rc=$rc_s $(head -c 300 <<< "$out")"; fi
    out=$(in_repo "$WV" doctor --json 2>/dev/null)
    got=$(jq -r '.checks[] | select(.check == "mcp server version") | .status' <<< "$out" 2>/dev/null)
    [ "$got" = "$2" ] && ok "doctor: $1" || bad "doctor: $1" "status=$got"
}
check_status "a stale bundle fails mcp-status" fail "1.70.0-rc.10"
check_status "a bundle reporting no version fails mcp-status" fail -
check_status "a bundle at the CLI's version passes mcp-status" pass "$CLI_VERSION"
out=$(bundle "1.70.0-rc.10"; in_repo "$WV" mcp-status 2>&1)
[[ "$out" == *"server 1.70.0-rc.10 under CLI $CLI_VERSION"*"./install.sh --with-mcp"* ]] \
    && ok "the mismatch names both versions and the remedy" || bad "the mismatch names both versions and the remedy" "$out"

# A health check slower than WV_MCP_HEALTH_TIMEOUT fails with the retry remedy,
# never passes as unconfirmed: under load that let a stale server through.
{ echo '// fixture bundle'; i=0; while [ $i -lt 40 ]; do echo '// padding line for the bundle size check'; i=$((i+1)); done
  echo "setTimeout(() => process.stdout.write(JSON.stringify({schema:\"weave-mcp-startup.v1\",status:\"pass\",scope:\"lite\",tools:9,version:\"$CLI_VERSION\"})), 2500);"; } > "$REPO/mcp/dist/index.js"
out=$(in_repo env WV_MCP_HEALTH_TIMEOUT=1 "$WV" mcp-status --json 2>/dev/null); rc_s=$?
got=$(jq -r '.checks[] | select(.check == "server version") | "\(.status)|\(.detail)"' <<< "$out" 2>/dev/null)
if [ "$rc_s" -ne 0 ] && [[ "$got" == "fail|version not confirmed: the health check took longer than 1s; re-run wv mcp-status"* ]]; then
    ok "a health check past the timeout fails mcp-status with the retry remedy"
else
    bad "a health check past the timeout fails mcp-status with the retry remedy" "rc=$rc_s $got"
fi
got=$(in_repo env WV_MCP_HEALTH_TIMEOUT=1 "$WV" doctor --json 2>/dev/null | jq -r '.checks[] | select(.check == "mcp server version") | "\(.status)|\(.detail)"' 2>/dev/null)
[[ "$got" == "fail|version not confirmed:"*"re-run wv doctor"* ]] \
    && ok "doctor: a health check past the timeout fails with the retry remedy" \
    || bad "doctor: a health check past the timeout fails with the retry remedy" "$got"

echo ""
echo "Results: $pass/$run passed"
[ "$pass" -eq "$run" ]
