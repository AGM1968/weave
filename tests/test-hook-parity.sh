#!/usr/bin/env bash
# test-hook-parity.sh -- Claude Code, Codex and VS Code Local hook decisions
# (agnostic-cutover S4e, wv-3c3cd4).
#
# Registrations are read from install.sh, where each is written. Each case
# uses three copies of one fixture: Claude and Codex matchers select their
# commands, while VS Code Local runs flat native entries with its documented
# payload shape. Compare decisions, advisory text and state, interpreting
# each host's output contract separately. This is command-level parity, not
# evidence that a live editor discovered or fired the hooks (wv-971035).
set -uo pipefail
export WV_TEST_SUITE=1  # the user's config.env cannot log this suite's wv calls (wv-6b0f57)

export WV_CALL_SOURCE=test
# Session-local state is per owner (wv-43d6be): pin one owner, whatever
# session runs this suite, so both hosts resolve the same owner directory.
export WV_AGENT_ID=test-hook-parity-agent

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WV="$ROOT/scripts/wv"
TEST_DIR=$(mktemp -d)
trap 'cd /tmp; rm -rf "$TEST_DIR"' EXIT

pass=0
total=0
check() {
    local description="$1"
    shift
    total=$((total + 1))
    if "$@"; then
        pass=$((pass + 1))
        printf 'ok %d - %s\n' "$total" "$description"
    else
        printf 'not ok %d - %s\n' "$total" "$description"
    fi
}
# same <label> <claude> <codex> -- check equality and show both on a mismatch.
same() {
    total=$((total + 1))
    if [ "$2" = "$3" ]; then
        pass=$((pass + 1))
        printf 'ok %d - %s\n' "$total" "$1"
    else
        printf 'not ok %d - %s\n  claude: %s\n  codex:  %s\n' "$total" "$1" \
            "$(head -c 400 <<<"$2" | tr '\n' '~')" "$(head -c 400 <<<"$3" | tr '\n' '~')"
    fi
}

# ── The registrations, as install.sh writes them ──
CLAUDE_HOOKS=$(python3 - "$ROOT/install.sh" <<'PY'
import re, sys
src = open(sys.argv[1]).read()
m = re.search(r"hooks_json=\$\(jq -n \\\n\s+--arg h \"\$hooks_dir\" \\\n\s+'(.*?)'\)\n", src, re.S)
print(m.group(1) if m else "")
PY
)
CLAUDE_HOOKS=$(jq -n --arg h "HOOKS" "$CLAUDE_HOOKS" 2>/dev/null) || CLAUDE_HOOKS=""
CODEX_HOOKS=$(python3 - "$ROOT/install.sh" <<'PY'
import re, sys
src = open(sys.argv[1]).read()
m = re.search(r"<<'CODEXHOOKSEOF'\n(.*?)\nCODEXHOOKSEOF\n", src, re.S)
print(m.group(1) if m else "")
PY
)
check "install.sh's Claude Code hooks block parses" jq -e '.SessionStart' <<<"$CLAUDE_HOOKS" >/dev/null 2>&1
check "install.sh's Codex hooks.json parses" jq -e '.hooks.Stop' <<<"$CODEX_HOOKS" >/dev/null 2>&1
VSCODE_HOOKS=$(python3 - "$ROOT/install.sh" <<'PY'
import re, sys
src = open(sys.argv[1]).read()
m = re.search(r"<<'VSCODEHOOKSEOF'\n(.*?)\nVSCODEHOOKSEOF\n", src, re.S)
print(m.group(1) if m else "")
PY
)
check "install.sh's VS Code Local hooks parse" jq -e '.hooks.Stop' <<<"$VSCODE_HOOKS" >/dev/null 2>&1

# Every event Claude Code registers is either registered for Codex or named
# here with the reason Codex goes without it.
declare -A CLAUDE_ONLY=(
    # Codex fires SessionEnd only when a conversation is archived or deleted,
    # and this one pushes; the Codex hook proposal keeps push out of hooks (wv-25903d).
    [SessionEnd]=1
    # Codex runs PostToolUse after a failed shell call too, so the dedup lock
    # the failure hook releases is released there (wv-594381).
    [PostToolUseFailure]=1
)
while read -r event; do
    if [ -n "${CLAUDE_ONLY[$event]:-}" ]; then
        check "$event: Claude-only by recorded reason" true
    else
        # shellcheck disable=SC2016  # $e is a jq variable
        check "$event: registered for Codex too" jq -e --arg e "$event" '.hooks[$e] | length > 0' <<<"$CODEX_HOOKS" >/dev/null
    fi
done < <(jq -r 'keys[]' <<<"$CLAUDE_HOOKS")
# A Codex command must answer in the shape Codex acts on.
while IFS=$'\t' read -r event command; do
    check "$event: the Codex command uses --format=host" grep -q -- '--format=host' <<<"$command"
done < <(jq -r '.hooks | to_entries[] | .key as $e | .value[].hooks[] | [$e, .command] | @tsv' <<<"$CODEX_HOOKS")

# ── Matchers: which hooks each host runs for a payload ──
# _key <event> <payload> -- what a matcher is tested against.
_key() {
    case "$1" in
        PreToolUse|PostToolUse) jq -r '.tool_name // ""' <<<"$2" ;;
        SessionStart) jq -r '.source // ""' <<<"$2" ;;
        PreCompact) jq -r '.trigger // ""' <<<"$2" ;;
        *) echo "" ;;
    esac
}
# _claude_hooks <event> <payload> -- the Claude hook scripts that run, in
# registration order. Claude Code matchers are regexes over the whole name.
_claude_hooks() {
    local key; key=$(_key "$1" "$2")
    jq -r --arg e "$1" --arg k "$key" '.[$e][]? | (.matcher // "") as $m | select($m == "" or ($k | test("^(" + $m + ")$")))
        | .hooks[].command | sub("^HOOKS/"; "")' <<<"$CLAUDE_HOOKS"
}
_codex_commands() {
    local key; key=$(_key "$1" "$2")
    jq -r --arg e "$1" --arg k "$key" '.hooks[$e][]? | (.matcher // "") as $m | select($m == "" or ($k | test("^(" + $m + ")$")))
        | .hooks[].command' <<<"$CODEX_HOOKS"
}
_vscode_commands() {
    # Native Local entries are flat, have no matcher, and must use its output
    # contract. Run the source checkout, just as init-repo renders it there.
    jq -r --arg e "$1" '.hooks[$e][]? | .command
        | sub("^wv "; "\"$(git rev-parse --show-toplevel)/scripts/wv\" ")' <<<"$VSCODE_HOOKS"
}
_vscode_payload() {
    jq -c 'if .tool_name == "Edit" or .tool_name == "Write" then
            .tool_name = (if .tool_name == "Edit" then "replace_string_in_file" else "create_file" end)
            | .tool_input.filePath = .tool_input.file_path | del(.tool_input.file_path)
        elif .tool_name == "Bash" then .tool_name = "run_in_terminal"
            | .tool_input.cmd = .tool_input.command | del(.tool_input.command)
        elif .hook_event_name == "SessionStart" then .source = "new"
        else . end' <<<"$1"
}

# ── Fixture ──
BASE="$TEST_DIR/base"
mkdir -p "$BASE/repo/src" "$BASE/hot"
git -C "$BASE/repo" init -q
git -C "$BASE/repo" config user.email parity@test.local
git -C "$BASE/repo" config user.name parity
# The Codex command runs "$(git rev-parse --show-toplevel)/scripts/wv".
ln -s "$ROOT/scripts" "$BASE/repo/scripts"
printf 'print("ok")\n' > "$BASE/repo/src/p.py"
# shellcheck disable=SC2016  # an unquoted expansion, for the edit linter to find
printf '#!/bin/bash\necho $1\n' > "$BASE/repo/src/bad.sh"
(
    cd "$BASE/repo" || exit 1
    export WV_PROJECT_DIR="$BASE/repo" WEAVE_DIR="$BASE/repo/.weave" WV_HOT_ZONE="$BASE/hot" \
        WV_DB="$BASE/hot/brain.db" WV_REQUIRE_LEARNING=0 WV_RUN_CACHE=0
    "$WV" init >/dev/null 2>&1
    git add -A >/dev/null 2>&1 && git commit -qm fixture --no-verify >/dev/null 2>&1
) || true

# _wv_in <dir> <args...> -- wv against one copy.
_wv_in() {
    local dir="$1"; shift
    (cd "$dir/repo" && WV_PROJECT_DIR="$dir/repo" WEAVE_DIR="$dir/repo/.weave" WV_HOT_ZONE="$dir/hot" \
        WV_DB="$dir/hot/brain.db" WV_REQUIRE_LEARNING=0 WV_RUN_CACHE=0 "$WV" "$@")
}
ACTIVE_ID=$(_wv_in "$BASE" add "Parity active node" --status=active --criteria="c1" --risks=low --force --json 2>/dev/null | jq -r '.id')
BARE_ID=$(_wv_in "$BASE" add "Parity claim probe" --force --json 2>/dev/null | jq -r '.id')
ADVISED_ID=$(_wv_in "$BASE" add "Parity advisory probe" --alias=parity-advised --criteria="c1" --force --json 2>/dev/null | jq -r '.id')
CLOSE_ID=$(_wv_in "$BASE" add "Parity close probe" --criteria="c1" --risks=low --force \
    --metadata='{"commit":"0000000"}' --json 2>/dev/null | jq -r '.id')
mkdir -p "$BASE/hot/owners/$WV_AGENT_ID"
printf 'execute' > "$BASE/hot/owners/$WV_AGENT_ID/.session_phase"
rm -f "$BASE/hot/.session_epoch" "$BASE/hot/owners/$WV_AGENT_ID/primary"
check "the fixture has its nodes" test -n "$ACTIVE_ID" -a -n "$BARE_ID" -a -n "$ADVISED_ID" -a -n "$CLOSE_ID"

# _copy <setup> -- a fresh copy of the fixture, with <setup> run in it; prints
# its dir. It runs in a command substitution, so no counter could name it.
_copy() {
    local dir
    dir=$(mktemp -d "$TEST_DIR/c.XXXXXX")
    cp -a "$BASE/." "$dir/"
    # A hot zone names the repository that owns it; wv refuses one owned by
    # another (wv-5e804e), and the copy's owner is its own repository.
    printf '%s\n' "$dir/repo" > "$dir/hot/.repo_root"
    (cd "$dir/repo" && C="$dir" eval "$1") >/dev/null 2>&1 || true
    printf '%s\n' "$dir"
}
# The Bash dedup lock directory: the hash of the repository path with echo's
# trailing newline, as every hook computes it.
_locks() { printf '/tmp/weave-bash-locks-%s/%s' "$(id -u)" "$(echo "$1/repo" | md5sum | cut -c1-8)"; }
# _plant_lock <copy> -- the lock a first, still-running `make check` holds.
# 700 like the hook makes it: a fixture base left 775 by the umask is refused (wv-80be32).
_plant_lock() { (umask 077 && mkdir -p "$(_locks "$1")") && printf '%s\npending\nmake check\n' "$(date +%s)" > "$(_locks "$1")/make-build.lock"; }

# _run <dir> <command-or-hook> <payload> <host> -- one hook run in a copy;
# writes rc, out and err files under <dir>/run.
_run() {
    local dir="$1" what="$2" payload="$3" host="$4"
    payload=${payload//@REPO@/$dir/repo}
    [ "$host" != vscode ] || payload=$(_vscode_payload "$payload")
    mkdir -p "$dir/run"
    (
        cd "$dir/repo" || exit 1
        export WV_PROJECT_DIR="$dir/repo" WEAVE_DIR="$dir/repo/.weave" WV_HOT_ZONE="$dir/hot" \
            WV_DB="$dir/hot/brain.db" WV_REQUIRE_LEARNING=0 WV_RUN_CACHE=0
        if [ "$host" = claude ]; then
            bash "$ROOT/.claude/hooks/$what" >"$dir/run/out" 2>"$dir/run/err" < <(printf '%s' "$payload")
        else
            printf '%s' "$payload" | bash -c "$what" >"$dir/run/out" 2>"$dir/run/err"
        fi
        echo $? > "$dir/run/rc"
    )
}

# _decision <dir> -- deny|<shape>|<reason> or allow, read from one run.
_decision() {
    local dir="$1" host="$2" rc out
    rc=$(cat "$dir/run/rc"); out=$(cat "$dir/run/out")
    if [ "$rc" = 2 ]; then
        printf 'deny|exit2|%s' "$(sed -e 's/[[:space:]]*$//' "$dir/run/err")"
    elif jq -e '.hookSpecificOutput.permissionDecision == "deny"' <<<"$out" >/dev/null 2>&1; then
        printf 'deny|json|%s' "$(jq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$out")"
    elif [ "$host" = vscode ] && jq -e '.hookSpecificOutput.hookEventName == "Stop" and .hookSpecificOutput.decision == "block"' <<<"$out" >/dev/null 2>&1; then
        printf 'block|rc%s|%s' "$rc" "$(jq -r '.hookSpecificOutput.reason' <<<"$out")"
    elif [ "$host" != vscode ] && jq -e '.decision == "block"' <<<"$out" >/dev/null 2>&1; then
        printf 'block|rc%s|%s' "$rc" "$(jq -r '.reason' <<<"$out")"
    elif [ "$rc" != 0 ]; then
        printf 'error|rc%s|%s' "$rc" "$(head -c 200 "$dir/run/err")"
    else
        printf 'allow'
    fi
}

# _host <host> <event> <payload> <dir> -- run every hook the host registers for
# the payload, in order; print the first decision and the advisories (sorted,
# as Claude runs a matcher group's hooks in parallel and Codex in one call).
_host() {
    local host="$1" event="$2" payload="$3" dir="$4" decision="" d hooks advice=""
    case "$host" in
        claude) hooks=$(_claude_hooks "$event" "$payload") ;;
        codex) hooks=$(_codex_commands "$event" "$payload") ;;
        vscode) hooks=$(_vscode_commands "$event") ;;
    esac
    while IFS= read -r h; do
        [ -n "$h" ] || continue
        _run "$dir" "$h" "$payload" "$host"
        d=$(_decision "$dir" "$host")
        [ -n "$decision" ] || [ "$d" = allow ] || decision="$d"
        advice+=$(jq -r '.hookSpecificOutput.additionalContext // empty' "$dir/run/out" 2>/dev/null)$'\n'
        if [ "$event" = PreCompact ]; then
            if [ "$host" = vscode ]; then
                advice+=$(jq -r '.systemMessage // empty' "$dir/run/out" 2>/dev/null)$'\n'
            else
                advice+=$(cat "$dir/run/out")$'\n'
            fi
        fi
    done <<<"$hooks"
    # A lock's age is when the copy ran, not what either host decided.
    { printf 'decision=%s\n' "${decision:-allow}"; printf '%s' "$advice" | grep -v '^$' | sort; } \
        | sed -e 's/, [0-9]*s old,/, Ns old,/'
}

# _state <dir> -- what the hooks left behind, with the copy's path taken out.
_state() {
    local dir="$1"
    {
        echo "node_files: $(sqlite3 "$dir/hot/brain.db" "SELECT group_concat(path, ',') FROM (SELECT path FROM node_files WHERE node_id='$ACTIVE_ID' ORDER BY path);" 2>/dev/null)"
        echo "touched: $(sqlite3 "$dir/hot/brain.db" "SELECT json_extract(metadata, '\$.touched_files') FROM nodes WHERE id='$ACTIVE_ID';" 2>/dev/null)"
        echo "ring: $(tr '\n' ',' 2>/dev/null < "$dir/hot/recent-edits.txt")"
        echo "budget: $(jq -c '{calls, bytes, list_calls}' "$dir/hot/session-budget.json" 2>/dev/null)"
        echo "locks: $(ls "$(_locks "$dir")" 2>/dev/null | tr '\n' ',')"
        echo "laststop: $(cut -d' ' -f2 "$dir/hot/.session_laststop" 2>/dev/null)"
        echo "head: $(git -C "$dir/repo" log -1 --format=%s 2>/dev/null | sed -e 's/ [0-9][0-9]:[0-9][0-9]//')"
        echo "phase: $(cat "$dir/hot/owners/$WV_AGENT_ID/.session_phase" 2>/dev/null)"
    } | sed -e "s#$dir#<COPY>#g"
}

# parity <label> <event> <payload> [setup] [env]
parity() {
    local label="$1" event="$2" payload="$3" setup="${4:-:}" envs="${5:-}" cdir xdir vdir c x v
    cdir=$(_copy "$setup"); xdir=$(_copy "$setup"); vdir=$(_copy "$setup")
    # shellcheck disable=SC2086,SC2163  # envs is a list of NAME=value words
    c=$( { [ -z "$envs" ] || export $envs; }; _host claude "$event" "$payload" "$cdir" | sed -e "s#$cdir#<COPY>#g")
    # shellcheck disable=SC2086,SC2163
    x=$( { [ -z "$envs" ] || export $envs; }; _host codex "$event" "$payload" "$xdir" | sed -e "s#$xdir#<COPY>#g")
    # shellcheck disable=SC2086,SC2163
    v=$( { [ -z "$envs" ] || export $envs; }; _host vscode "$event" "$payload" "$vdir" | sed -e "s#$vdir#<COPY>#g")
    same "$label: same decision and advisories" "$c" "$x"
    same "$label: same state left behind" "$(_state "$cdir")" "$(_state "$xdir")"
    same "$label: VS Code Local decision and advisories" "$c" "$v"
    same "$label: VS Code Local state left behind" "$(_state "$cdir")" "$(_state "$vdir")"
    PARITY_CLAUDE="$c"
    rm -rf "$(_locks "$cdir")" "$(_locks "$xdir")" "$(_locks "$vdir")"
}
edit_of() { jq -cn --arg p "$1" '{tool_name:"Edit",tool_input:{file_path:$p,old_string:"a",new_string:"b"},tool_response:{success:true},cwd:"@REPO@"}'; }
bash_of() { jq -cn --arg c "$1" '{tool_name:"Bash",tool_input:{command:$c},cwd:"@REPO@"}'; }
UNCLAIM="sqlite3 \"\$C/hot/brain.db\" \"UPDATE nodes SET status='todo' WHERE status='active';\""

echo "=== PreToolUse ==="
parity "an edit with no active node" PreToolUse "$(edit_of "src/p.py")" "$UNCLAIM"
check "an edit with no active node is denied" grep -q '^decision=deny|exit2|.*No active Weave node' <<<"$PARITY_CLAUDE"
parity "an edit with an active node" PreToolUse "$(edit_of "src/p.py")"
check "an edit with an active node is allowed" grep -qx 'decision=allow' <<<"$PARITY_CLAUDE"
parity "an edit of the installed copy" PreToolUse "$(edit_of "$HOME/.local/bin/wv")"
check "an edit of the installed copy is denied" grep -q '^decision=deny' <<<"$PARITY_CLAUDE"
parity "a write in the discover phase" PreToolUse \
    "$(jq -cn '{tool_name:"Write",tool_input:{file_path:"src/n.py",content:"x"},cwd:"@REPO@"}')" \
    "printf discover > \"\$C/hot/owners/$WV_AGENT_ID/.session_phase\""
check "a write in the discover phase is denied" grep -q '^decision=deny.*discover' <<<"$PARITY_CLAUDE"
parity "a claim of an unplanned node" PreToolUse "$(bash_of "wv work $BARE_ID")"
check "a claim of an unplanned node is denied by the claim preflight" grep -qF -- "decision=deny|json|Claim preflight for $BARE_ID" <<<"$PARITY_CLAUDE"
# wv-6e4798: missing risks alone is advice, not a requirement. Every host gets
# the claim through with the advice as context; dispatch used to drop the
# output of a guard that did not decide.
parity "a claim missing only risks" PreToolUse "$(bash_of "wv work $ADVISED_ID")"
check "a claim missing only risks is allowed" grep -qx 'decision=allow' <<<"$PARITY_CLAUDE"
check "a claim missing only risks carries the advice as context" \
    grep -qF -- "Claim preflight advisory for $ADVISED_ID, not a requirement; the claim proceeds" <<<"$PARITY_CLAUDE"
parity "a close without verification evidence" PreToolUse "$(bash_of "wv done $CLOSE_ID")" \
    "sqlite3 \"\$C/hot/brain.db\" \"UPDATE nodes SET status='active' WHERE id='$CLOSE_ID';\""
check "a close without verification evidence is denied" grep -qF -- "decision=deny|json|Run: wv done $CLOSE_ID" <<<"$PARITY_CLAUDE"
parity "a command no guard governs" PreToolUse "$(bash_of "ls")"
check "a command no guard governs is allowed" grep -qx 'decision=allow' <<<"$PARITY_CLAUDE"
# The lock a first call took, planted the same way in both copies.
# shellcheck disable=SC2016  # the setup snippet is evaluated in each copy, where $C is set
parity "a duplicate of an in-flight command" PreToolUse "$(bash_of "make check")" \
    '_plant_lock "$C"'
check "a duplicate of an in-flight command is denied" grep -q '^decision=deny' <<<"$PARITY_CLAUDE"

echo "=== PostToolUse ==="
parity "an edit attributes its file" PostToolUse "$(edit_of "src/p.py")"
check "an edit attributes its file" true
parity "a failed edit attributes nothing" PostToolUse \
    "$(jq -cn '{tool_name:"Write",tool_input:{file_path:"src/f.py"},tool_response:{success:false},cwd:"@REPO@"}')"
parity "an edit the linter flags" PostToolUse "$(edit_of "src/bad.sh")"
parity "a wv call is tallied" PostToolUse \
    "$(jq -cn '{tool_name:"Bash",tool_input:{command:"wv ready"},tool_response:{stdout:"ready list",stderr:""},cwd:"@REPO@"}')" ":" "WV_BUDGET_THRESHOLD=1"
check "a wv call over the threshold advises" grep -qv '^decision=' <<<"$PARITY_CLAUDE"
# shellcheck disable=SC2016  # the setup snippet is evaluated in each copy, where $C is set
parity "a finished command releases its dedup lock" PostToolUse \
    "$(jq -cn '{tool_name:"Bash",tool_input:{command:"make check"},tool_response:{stdout:"ok",stderr:""},cwd:"@REPO@"}')" \
    '_plant_lock "$C"'

echo "=== Stop ==="
parity "a stop with an active node" Stop '{"hook_event_name":"Stop","stop_hook_active":false}'
check "a stop with an active node is blocked" grep -q '^decision=block|rc0|1 active node(s) still open' <<<"$PARITY_CLAUDE"
parity "a stop with no active node" Stop '{"hook_event_name":"Stop","stop_hook_active":false}' "$UNCLAIM"
check "a stop with no active node is allowed" grep -qx 'decision=allow' <<<"$PARITY_CLAUDE"
parity "a stop the host is already continuing from" Stop '{"hook_event_name":"Stop","stop_hook_active":true}'
check "a stop the host is already continuing from is allowed" grep -qx 'decision=allow' <<<"$PARITY_CLAUDE"

echo "=== PreCompact ==="
parity "a compaction" PreCompact '{"hook_event_name":"PreCompact","trigger":"auto"}' \
    "echo note >> \"\$C/repo/.weave/breadcrumbs.md\""
check "a compaction prints the snapshot" grep -q '^Weave state (pre-compact snapshot):' <<<"$PARITY_CLAUDE"

echo "=== SessionStart ==="
parity "a start after a crash" SessionStart '{"hook_event_name":"SessionStart","source":"startup","session_id":"parity"}' \
    "printf '{\"ts\":\"2026-01-01T00:00:00Z\",\"active\":[],\"pid\":1}' > \"\$C/hot/.session_sentinel\"; rm -f \"\$C/hot/.session_laststop\" \"\$C/hot/.session_heartbeat\""
check "a start after a crash reports it" grep -q 'CRASH DETECTED' <<<"$PARITY_CLAUDE"

printf '1..%d\n' "$total"
printf 'Results: %d/%d passed\n' "$pass" "$total"
test "$pass" -eq "$total"
