#!/usr/bin/env bash
# test-lifecycle-hooks-adverse.sh -- every lifecycle hook finishes inside its
# registered timeout under adverse conditions (wv-5605d7).
#
# The session-end routine failed on every exit for eight months because its
# tests ran a stub wv: the real routine's pull and push against a slow remote
# never ran under test (wv-a32e69). Here each lifecycle event runs the REAL
# routine of this checkout -- the shared `wv hook dispatch` every host calls,
# and the Claude Code adapter that wraps it -- against a scratch repository
# whose origin is unreachable (a non-routable address, so a connect hangs
# rather than failing fast) and whose branch is ahead of it, so any pull, fetch
# or push the routine attempts costs real time. Each run must exit inside the
# budget install.sh registers for that event (tests/test-init-repo.sh holds
# install.sh to explicit timeouts).
#
# Exit codes:
#   0 - All tests passed
#   1 - One or more tests failed
set -euo pipefail
export WV_TEST_SUITE=1  # the user's config.env cannot log this suite's wv calls (wv-6b0f57)
export WV_CALL_SOURCE=test
# The commit gate injects git config through GIT_CONFIG_*; a scratch repository
# must see only its own (wv-8f1da6).
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0 2>/dev/null || true
# The hooks and the fixture setup run with their own checkpoint default. An
# inherited WV_AUTO_CHECKPOINT=0 changed both the fixture repos and the hooks'
# paths, and decided SessionEnd's result once the session-end prune, which
# committed regardless, was removed (wv-68c882).
unset WV_AUTO_CHECKPOINT

# ADVERSE_ROOT runs another tree's routine under this test (e.g. a scratch
# export of an older commit, to show the test fails there).
ROOT="${ADVERSE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# wv_stat / wv_date_fmt: GNU and BSD behind one call (wv-resolve-runtime.sh, side-effect free).
# shellcheck disable=SC1091  # resolved at run time
source "$ROOT/scripts/lib/wv-resolve-runtime.sh"
source "$ROOT/tests/lib/bounded.sh"  # timeout(1) is GNU-only; macOS has none (wv-412db3)
WV="$ROOT/scripts/wv"
HOOKS="$ROOT/.claude/hooks"
TEST_DIR=$(mktemp -d)
trap 'cd /tmp; rm -rf "$TEST_DIR"' EXIT

# Budgets registered by install.sh (Claude Code global settings; the generated
# Codex and VS Code configs give SessionStart, PreCompact and Stop the same or
# more). Codex registers no SessionEnd.
declare -A BUDGET=([SessionStart]=120 [PreCompact]=30 [Stop]=30 [SessionEnd]=30)
declare -A ADAPTER=([SessionStart]=session-start-context.sh [PreCompact]=pre-compact-context.sh
                    [Stop]=stop-check.sh [SessionEnd]=session-end-sync.sh)
# Non-routable (RFC 5737 TEST-NET-1): TCP connects hang until git's own timeout.
UNREACHABLE="http://192.0.2.1:9/weave-unreachable.git"

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
within() { [ "$1" -lt "$2" ]; }

# make_repo <name> <hot> <cfg> <agent>: an initialised Weave repo with one active
# node and a committed graph, in its own hot zone, then origin made unreachable
# and the branch one commit ahead of origin/main. The remote is added only after
# setup so setup itself never waits on it.
make_repo() {
    local repo="$TEST_DIR/$1" hot="$2" cfg="$3" agent="$4"
    mkdir -p "$repo" "$cfg"
    (umask 077 && mkdir -p "$hot")
    git -C "$repo" init -q -b main
    git -C "$repo" config user.email adverse@test.local
    git -C "$repo" config user.name adverse
    git -C "$repo" config commit.gpgsign false
    git -C "$repo" config core.hooksPath /dev/null
    git -C "$repo" commit -q --allow-empty -m base
    (
        cd "$repo"
        export WV_PROJECT_DIR="$repo" WEAVE_DIR="$repo/.weave" WV_HOT_ZONE="$hot" WV_DB="$hot/brain.db" \
            WV_CONFIG_DIR="$cfg" WV_AGENT_ID="$agent" WV_CHECKPOINT_PULL=0
        "$WV" init >/dev/null 2>&1
        "$WV" add "adverse-conditions fixture node" --status=active --standalone >/dev/null 2>&1 || true
        "$WV" sync >/dev/null 2>&1 || true
        git add -A >/dev/null 2>&1
        git commit -q -m "graph" >/dev/null 2>&1 || true
    )
    git -C "$repo" update-ref refs/remotes/origin/main "$(git -C "$repo" rev-parse HEAD~1)"
    git -C "$repo" remote add origin "$UNREACHABLE"
    git -C "$repo" config branch.main.remote origin
    git -C "$repo" config branch.main.merge refs/heads/main
    printf '%s\n' "$repo"
}

# run_timed <budget> <out> <cmd...>: run with a hard ceiling of budget+30 s so a
# hang fails the suite instead of stalling it; stdout goes to <out>; prints
# elapsed whole seconds.
run_timed() {
    local budget="$1" out="$2" start end
    shift 2
    start=$(date +%s)
    bounded "$((budget + 30))" "$@" >"$out" 2>/dev/null || true
    end=$(date +%s)
    printf '%s\n' "$((end - start))"
}

# did_work <event> <repo> <hot> <out>: evidence the real routine ran rather than
# exiting early, so a fast pass cannot be vacuous.
did_work() {
    case "$1" in
        SessionStart) [ -s "$4" ] && grep -q "Weave" "$4" ;;
        PreCompact)   [ -s "$4" ] ;;
        Stop)         grep -q '"block"' "$4" ;;
        SessionEnd)   git -C "$2" log -1 --pretty=%s | grep -q "auto-checkpoint" ;;
    esac
}

# stamped_clean <event> <hot>: the run left "<event> begin" and an end whose
# status is below 128 (not killed) in the hot zone's hook-runs.log.
stamped_clean() {
    awk -v ev="$1" '$2 == ev && $3 == "begin" { b = 1 } $2 == ev && $3 == "end" && $5 + 0 < 128 { e = 1 }
        END { exit !(b && e) }' "$2/hook-runs.log" 2>/dev/null
}

payload_for() {
    case "$1" in
        SessionStart) printf '{"session_id":"adverse-%s","source":"startup","hook_event_name":"SessionStart"}' "$2" ;;
        PreCompact)   printf '{"session_id":"adverse-%s","trigger":"auto","hook_event_name":"PreCompact"}' "$2" ;;
        Stop)         printf '{"session_id":"adverse-%s","stop_hook_active":false,"hook_event_name":"Stop"}' "$2" ;;
        SessionEnd)   printf '{"session_id":"adverse-%s","reason":"prompt_input_exit","hook_event_name":"SessionEnd"}' "$2" ;;
    esac
}

for ev in SessionStart PreCompact Stop SessionEnd; do
    for form in dispatch adapter; do
        hot="$TEST_DIR/hot-$ev-$form"
        cfg="$TEST_DIR/cfg-$ev-$form"
        repo=$(make_repo "$ev-$form" "$hot" "$cfg" "adverse-$form")
        payload=$(payload_for "$ev" "$form")
        # shellcheck disable=SC2016  # $1..$3 are bash -c positional arguments
        if [ "$form" = dispatch ]; then
            cmd=(bash -c 'printf "%s" "$1" | "$2" hook dispatch --event="$3" --format=host' _ "$payload" "$WV" "$ev")
        else
            # shellcheck disable=SC2016  # $1, $2 are bash -c positional arguments
            cmd=(bash -c 'printf "%s" "$1" | bash "$2"' _ "$payload" "$HOOKS/${ADAPTER[$ev]}")
        fi
        out="$TEST_DIR/out-$ev-$form"
        # SessionEnd only checkpoints a dirty .weave/: leave a change for it.
        [ "$ev" != SessionEnd ] || echo "pending" >> "$repo/.weave/breadcrumbs.md"
        secs=$(cd "$repo" && WV_PROJECT_DIR="$repo" CLAUDE_PROJECT_DIR="$repo" WEAVE_DIR="$repo/.weave" \
            WV_HOT_ZONE="$hot" WV_DB="$hot/brain.db" WV_CONFIG_DIR="$cfg" WV_AGENT_ID="adverse-$form" \
            GIT_TERMINAL_PROMPT=0 run_timed "${BUDGET[$ev]}" "$out" "${cmd[@]}")
        check "$ev ($form) finishes in ${secs}s against an unreachable remote, inside its ${BUDGET[$ev]}s budget" \
            within "$secs" "${BUDGET[$ev]}"
        check "$ev ($form) ran the real routine" did_work "$ev" "$repo" "$hot" "$out"
        check "$ev ($form) stamped its begin and a clean end (wv-ca3ffe)" stamped_clean "$ev" "$hot"
    done
done

# ── A hook cut short is reported (wv-ca3ffe) ─────────────────────────────────
# SIGKILL a real SessionStart once its begin stamp is written, as a host does at
# its timeout; wv doctor and the next SessionStart must both say so.
hot="$TEST_DIR/hot-cut"; cfg="$TEST_DIR/cfg-cut"
repo=$(make_repo "cut" "$hot" "$cfg" "adverse-cut")
in_repo() {
    (cd "$repo" && WV_PROJECT_DIR="$repo" CLAUDE_PROJECT_DIR="$repo" WEAVE_DIR="$repo/.weave" \
        WV_HOT_ZONE="$hot" WV_DB="$hot/brain.db" WV_CONFIG_DIR="$cfg" WV_AGENT_ID="adverse-cut" \
        GIT_TERMINAL_PROMPT=0 "$@")
}
# exec + setsid: the background job IS the new process group's leader, so the
# kill reaches the whole group, as a host's does. The session comes from
# python3's os.setsid(): util-linux setsid(1) is not on macOS (wv-412db3).
# shellcheck disable=SC2016  # $1, $2 are bash -c positional arguments
(cd "$repo" && exec env WV_PROJECT_DIR="$repo" CLAUDE_PROJECT_DIR="$repo" WEAVE_DIR="$repo/.weave" \
    WV_HOT_ZONE="$hot" WV_DB="$hot/brain.db" WV_CONFIG_DIR="$cfg" WV_AGENT_ID="adverse-cut" \
    python3 -I -c 'import os, sys; os.setsid(); os.execvp(sys.argv[1], sys.argv[1:])' bash -c 'printf "%s" "$1" | "$2" hook dispatch --event=SessionStart --format=host >/dev/null 2>&1' \
    _ "$(payload_for SessionStart cut)" "$WV") &
cut_pid=$!
for _ in $(seq 1 100); do
    grep -q " SessionStart begin " "$hot/hook-runs.log" 2>/dev/null && break
    sleep 0.1
done
kill -KILL -- "-$cut_pid" 2>/dev/null || kill -KILL "$cut_pid" 2>/dev/null || true
wait "$cut_pid" 2>/dev/null || true
cut_has_begin() { grep -q " SessionStart begin " "$hot/hook-runs.log" 2>/dev/null; }
check "the cut-short SessionStart left a begin stamp" cut_has_begin
doctor_out=$(in_repo "$WV" doctor --json 2>/dev/null || true)
doctor_row=$(jq -r '[.checks[] | select(.check == "hook runs")][0] | "\(.status) \(.detail)"' <<<"$doctor_out" 2>/dev/null || true)
has() { case "$1" in *"$2"*) return 0 ;; esac; printf '    got: %s\n' "$1" >&2; return 1; }
check "wv doctor warns about the unfinished SessionStart" has "$doctor_row" "warn unfinished lifecycle runs in the last 7 days: SessionStart x1"
next_out=$(printf '%s' "$(payload_for SessionStart next)" | in_repo "$WV" hook dispatch --event=SessionStart --format=host 2>/dev/null || true)
check "the next SessionStart summary reports it" has "$next_out" "Hooks: unfinished lifecycle runs in the last 7 days: SessionStart x1"

# ── wv work's stale-operation auto-clear is reported, not silent ─────────────
printf '{"event":"begin","op":"sync","op_id":"stale1","args":{},"ts":"%s"}\n' \
    "$(wv_date_fmt -u "$(( $(date +%s) - 7200 ))" +%Y-%m-%dT%H:%M:%SZ)" > "$hot/ops.journal"
node=$(in_repo "$WV" list --json 2>/dev/null | jq -r '.[0].id // empty')
work_err=$(in_repo "$WV" work "$node" 2>&1 >/dev/null || true)
check "wv work names the operation it cleared" has "$work_err" "Cleared an unfinished operation older than 30 min: sync started"
doctor_out=$(in_repo "$WV" doctor --json 2>/dev/null || true)
cleared_row=$(jq -r '[.checks[] | select(.check == "cleared operations")][0] | "\(.status) \(.detail)"' <<<"$doctor_out" 2>/dev/null || true)
check "wv doctor counts cleared operations" has "$cleared_row" "warn wv work cleared 1 unfinished operation(s)"

echo ""
echo "Results: $pass/$total passed"
[ "$pass" -eq "$total" ]
