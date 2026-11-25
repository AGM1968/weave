#!/usr/bin/env bash
# Per-scope MCP process status contract: absence is unknown for client-managed
# stdio servers, while multiple processes in one scope are stale duplicates.
set -euo pipefail
export WV_TEST_SUITE=1  # the user's config.env cannot log this suite's wv calls (wv-6b0f57)

export WV_CALL_SOURCE=test

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WV="$ROOT/scripts/wv"
TMP=$(mktemp -d)
export WV_HOT_ZONE="$TMP/hotzone"
export HOME="$TMP/home"
mkdir -p "$HOME" "$TMP/bin"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/bin/pgrep" <<'EOF'
#!/usr/bin/env bash
cat "${MCP_PROCESS_FIXTURE:?}"
EOF
chmod +x "$TMP/bin/pgrep"
export PATH="$TMP/bin:$PATH"

TESTS=0
PASSED=0

assert_eq() {
    local expected="$1" actual="$2" message="$3"
    TESTS=$((TESTS + 1))
    if [ "$expected" = "$actual" ]; then
        PASSED=$((PASSED + 1))
    else
        echo "FAIL: $message (expected '$expected', got '$actual')" >&2
    fi
}

assert_contains() {
    local output="$1" expected="$2" message="$3"
    TESTS=$((TESTS + 1))
    if grep -qF -- "$expected" <<<"$output"; then
        PASSED=$((PASSED + 1))
    else
        echo "FAIL: $message (missing '$expected')" >&2
    fi
}

scope_field() { # json scope field
    jq -r --arg scope "$2" --arg field "$3" '.per_scope[] | select(.scope == $scope) | .[$field]' <<<"$1"
}

# No visible child process is unknown, not stale: clients own stdio lifetime and
# may not have started an otherwise configured server yet.
: > "$TMP/no-processes"
export MCP_PROCESS_FIXTURE="$TMP/no-processes"
# This suite judges per-scope process status, not the overall verdict:
# mcp-status exits 1 when any other check fails, such as the server version
# (wv-4cdc07), and under set -e that ended the suite with no output at all.
no_server=$(cd "$ROOT" && "$WV" mcp-status --json) || true
assert_eq "scope,expected,running,duplicate,status" \
    "$(jq -r '.status_report.per_scope_required_fields | join(",")' "$ROOT/mcp/contract.json")" \
    "contract freezes the per-scope field set"
assert_eq "running,stale,unknown" \
    "$(jq -r '.status_report.status_values | join(",")' "$ROOT/mcp/contract.json")" \
    "contract freezes the scope status vocabulary"
assert_eq 5 "$(jq '.per_scope | length' <<<"$no_server")" "JSON reports every contract scope"
assert_eq true "$(scope_field "$no_server" all expected)" "all scope is expected"
assert_eq false "$(scope_field "$no_server" graph expected)" "graph scope is optional"
assert_eq 0 "$(scope_field "$no_server" lite running)" "absent scope has zero running processes"
assert_eq false "$(scope_field "$no_server" lite duplicate)" "absent scope is not duplicate"
assert_eq unknown "$(scope_field "$no_server" lite status)" "absent scope status is unknown"

# Two same-scope processes are stale even when other scopes are healthy.
cat > "$TMP/duplicates" <<'EOF'
101 node /opt/weave/mcp/dist/index.js --scope=lite
102 node /opt/weave/mcp/dist/index.js --scope=lite
103 node /opt/weave/mcp/dist/index.js --scope=session
EOF
export MCP_PROCESS_FIXTURE="$TMP/duplicates"
duplicates=$(cd "$ROOT" && "$WV" mcp-status --json) || true
assert_eq 2 "$(scope_field "$duplicates" lite running)" "same-scope processes are counted"
assert_eq true "$(scope_field "$duplicates" lite duplicate)" "same-scope excess is duplicate"
assert_eq stale "$(scope_field "$duplicates" lite status)" "duplicate scope is stale"
assert_eq 1 "$(scope_field "$duplicates" session running)" "independent scope count is preserved"
assert_eq running "$(scope_field "$duplicates" session status)" "single process is running"

text=$(cd "$ROOT" && "$WV" mcp-status) || true
assert_contains "$text" "lite expected/stale (2)" "text output identifies stale scope concisely"
assert_contains "$text" "restart duplicate scope(s) lite:2" "text output gives duplicate remediation"

echo "Results: $PASSED/$TESTS passed"
[ "$PASSED" -eq "$TESTS" ]
