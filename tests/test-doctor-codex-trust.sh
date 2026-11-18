#!/usr/bin/env bash
# wv doctor reads Codex hook trust from the Codex config (wv-f838ba). Codex
# runs a project hook only after a person trusts it in the TUI, and codex exec
# skips an untrusted one without a message (probe wv-f2dc79). Trust is one
# [hooks.state."<abs path>/.codex/hooks.json:<event>:<group>:<hook>"] entry per
# hook in $CODEX_HOME/config.toml. Doctor passes only when every hook has one,
# warns naming the untrusted events otherwise, and never writes the config.
# An entry edited after trust warns until Codex's trusted_hash moves (a person
# trusted it again), from doctor's own baseline (wv-d9f789).
set -euo pipefail
export WV_TEST_SUITE=1  # the user's config.env cannot log this suite's wv calls (wv-6b0f57)
export WV_CALL_SOURCE=test

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WV="$ROOT/scripts/wv"
TMP=$(mktemp -d)
export WV_HOT_ZONE="$TMP/hotzone"
export WV_CONFIG_DIR="$TMP/config"
export CODEX_HOME="$TMP/codex"
export WV_CODEX_TRUST_BASELINE="$TMP/baseline/codex-hook-trust.tsv"
trap 'cd /tmp; rm -rf "$TMP"' EXIT
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE

TESTS=0
PASSED=0
check() { # message expected-status expected-substring
    local got status detail
    got=$({ "$WV" doctor --agent --json 2>/dev/null || true; } | jq -c '.checks[] | select(.check == "codex hooks")')
    status=$(jq -r '.status' <<< "$got")
    detail=$(jq -r '.detail' <<< "$got")
    TESTS=$((TESTS + 1))
    if [ "$status" = "$2" ] && grep -qF -- "$3" <<< "$detail"; then
        PASSED=$((PASSED + 1))
        echo "  ✓ $1"
    else
        echo "  ✗ $1 (wanted $2 with '$3', got $status: $detail)"
    fi
}
trust() { # event-key...
    local k
    mkdir -p "$CODEX_HOME"
    for k in "$@"; do
        printf '[hooks.state."%s:%s"]\ntrusted_hash = "sha256:%064d"\n\n' "$REPO/.codex/hooks.json" "$k" 0 >> "$CODEX_HOME/config.toml"
    done
}

REPO="$TMP/repo"
mkdir -p "$REPO/.codex"
REPO="$(cd "$REPO" && pwd -P)"
cd "$REPO"
git init -q .
# shellcheck disable=SC2016  # the command is literal: Codex expands it, not this suite
hook='{"type":"command","command":"\"$(git rev-parse --show-toplevel)/scripts/wv\" hook dispatch --format=host"}'
jq -n --argjson h "$hook" '{hooks: {
    SessionStart: [{matcher: "startup", hooks: [$h]}],
    PreToolUse: [{matcher: "Bash", hooks: [$h]}, {matcher: "apply_patch", hooks: [$h]}],
    PostToolUse: [{hooks: [$h]}], PreCompact: [{hooks: [$h]}], Stop: [{hooks: [$h]}]}}' > .codex/hooks.json

echo "=== Codex hook trust (wv-f838ba) ==="
check "no Codex config: every event pending trust" warn "pending trust for: SessionStart, PreToolUse, PostToolUse, PreCompact, Stop"

trust session_start:0:0 pre_tool_use:0:0 post_tool_use:0:0 pre_compact:0:0 stop:0:0
check "a second PreToolUse group without an entry is still pending" warn "pending trust for: PreToolUse"

trust pre_tool_use:1:0
check "an entry for every hook passes" pass "trust entry for all 6 hook(s)"
check "the pass says each entry is unchanged since first seen trusted" pass "each unchanged since first seen trusted"
TESTS=$((TESTS + 1))
if [ "$(wc -l < "$WV_CODEX_TRUST_BASELINE")" -eq 6 ]; then PASSED=$((PASSED + 1)); echo "  ✓ the baseline records one row per trusted hook"
else echo "  ✗ the baseline does not hold 6 rows"; fi

# Editing a hook's entry after trust: Codex skips it silently (wv-514488).
cp .codex/hooks.json "$TMP/hooks.orig"
jq '.hooks.PreToolUse[0].hooks[0].command += " --edited"' "$TMP/hooks.orig" > .codex/hooks.json
check "an entry edited after trust warns, naming the event" warn "changed since Codex trusted them: PreToolUse"
check "the edit keeps warning on the next run" warn "review them again in the Codex TUI"
# A person trusts it again: Codex writes a new trusted_hash for that key.
sed -i "/hooks.json:pre_tool_use:0:0\"\]/{n;s/sha256:0*/sha256:$(printf '%064d' 1)/}" "$CODEX_HOME/config.toml"
check "trusting the edited hook again passes" pass "each unchanged since first seen trusted"
# The script a hook runs is outside its entry; Codex kept such a hook trusted.
mkdir -p scripts && echo 'echo v2' > scripts/wv
check "a changed hook script stays trusted" pass "each unchanged since first seen trusted"
# A baseline that cannot be written is said, not passed off as checked.
mkdir -p "$TMP/ro" && chmod 555 "$TMP/ro"
WV_CODEX_TRUST_BASELINE="$TMP/ro/codex-hook-trust.tsv" check "an unwritable baseline is reported" pass "not checked for edits"
chmod 755 "$TMP/ro"
# A suite naming no baseline writes into its hot zone, never under HOME.
mkdir -p "$TMP/home"
(unset WV_CODEX_TRUST_BASELINE; HOME="$TMP/home" "$WV" doctor --agent --json >/dev/null 2>&1 || true)
TESTS=$((TESTS + 1))
if [ ! -e "$TMP/home/.local/share/weave/codex-hook-trust.tsv" ] && [ -s "$WV_HOT_ZONE/codex-hook-trust.tsv" ]; then
    PASSED=$((PASSED + 1)); echo "  ✓ in a suite the default baseline is the hot zone, not HOME"
else echo "  ✗ the suite's default baseline left the hot zone"; fi

before=$(sha256sum "$CODEX_HOME/config.toml")
"$WV" doctor --agent --json >/dev/null 2>&1 || true
TESTS=$((TESTS + 1))
if [ "$(sha256sum "$CODEX_HOME/config.toml")" = "$before" ]; then PASSED=$((PASSED + 1)); echo "  ✓ doctor leaves the Codex config unchanged"
else echo "  ✗ doctor wrote the Codex config"; fi

sed -i "s#$REPO/.codex/hooks.json:stop:0:0#/elsewhere/.codex/hooks.json:stop:0:0#" "$CODEX_HOME/config.toml"
check "an entry for another checkout path does not count" warn "pending trust for: Stop"

echo "Results: $PASSED/$TESTS passed"
[ "$PASSED" -eq "$TESTS" ]
