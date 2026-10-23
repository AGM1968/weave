#!/bin/bash
# wv-post-tool-use.sh -- the PostToolUse hooks, one implementation for every
# host (agnostic-cutover S4c, wv-594381).
#
# Five guards run after a tool call: file attribution (node_files and the
# capped touched_files list), the Bash dedup lock release, the wv budget tally,
# the edit linter, and repo-scoped Claude memory capture. Each Claude Code hook
# in .claude/hooks sources this file and calls one guard in-process; `wv hook
# dispatch --event=PostToolUse` runs them all for Codex. Attribution stays a
# direct write, not a wv call per edit (judge panel 2026-10-01: wv touch costs
# about 1.3 s an edit), and inside an E5 capture window it is queued for the
# agent's next mutation-class wv call (wv-cdafa1, wv-attribution.sh).
#
# Each guard is a subshell function holding what its hook script held, so its
# exits and shell options are the hook's. An advisory is printed as
# hookSpecificOutput.additionalContext, the field both hosts read for
# PostToolUse; the hooks printed it top-level, where neither looks (wv-09aa6f).
#
# No side effects on source.

[ -n "${_WV_POST_TOOL_USE_LOADED:-}" ] && return 0
_WV_POST_TOOL_USE_LOADED=1
_POTU_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# _potu_source <lib> -- load a library from beside this file, then from the
# installed locations, falling through a copy that fails to load. Libraries
# load with nounset off: two guards run under the `set -u` their hooks had,
# and inside a subshell an unbound expansion in a sourced library (a partial
# install's wv-hook-common without its generated classes) exits the guard
# where the hook's top-level `source ... || true` carried on.
_potu_source() {
    local lib="$1" dir guard nounset=false rc
    [[ $- == *u* ]] && nounset=true
    for dir in "$_POTU_LIB_DIR" "${HOME}/.config/weave/lib" "${HOME}/.local/lib/weave/lib"; do
        [ -r "$dir/$lib.sh" ] || continue
        set +u
        rc=0
        # shellcheck source=/dev/null
        . "$dir/$lib.sh" 2>/dev/null || rc=$?
        [ "$nounset" = false ] || set -u
        [ "$rc" -ne 0 ] || return 0
        while read -r guard; do unset "$guard"; done < <(compgen -v | grep -E '^_WV_[A-Z0-9_]*_LOADED$')
    done
    return 1
}

# _potu_tag_hook -- tag the guard's own wv calls hook, keeping a test run's tag.
# Set at entry, not left to wv-hook-common's side effect: that load is
# `|| true`, and a failed one leaves the inherited agent tag (wv-a093ea).
_potu_tag_hook() {
    [ "${WV_CALL_SOURCE:-}" = "test" ] || export WV_CALL_SOURCE=hook
}

# _potu_context <message> -- an advisory in the shape Claude Code and Codex
# both read after a tool call.
_potu_context() {
    jq -n --arg ctx "$1" '{hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: $ctx}}'
}

# _potu_paths <input> -- the files a tool call edited, one per line: the
# file_path/filePath/path field, or every file header of a Codex apply_patch.
# A relative patch path is resolved against the payload's cwd.
_potu_paths() {
    local input="$1" tool="" cwd="" path paths=""
    # One jq call: an edit names its one file; only a patch needs the header parser.
    # Fields joined on the unit separator: @tsv would escape a backslash in a path.
    IFS=$'\x1f' read -r tool cwd paths < <(printf '%s' "$input" | jq -r '[.tool_name // "", .cwd // "",
        (.tool_input.file_path // .tool_input.filePath // .tool_input.path // "")] | join("\u001f")' 2>/dev/null) || true
    if [ "$tool" = "apply_patch" ]; then
        declare -F _ptu_input_paths >/dev/null || _potu_source wv-pre-tool-use || return 0
        paths=$(_ptu_input_paths "$tool" "$(printf '%s' "$input" | jq -c '.tool_input // {}' 2>/dev/null)")
    fi
    while IFS= read -r path; do
        [ -n "$path" ] || continue
        case "$path" in
            /*) printf '%s\n' "$path" ;;
            *) printf '%s\n' "${cwd:-$PWD}/$path" ;;
        esac
    done <<< "$paths"
}

# _potu_bash_output <input> -- what a terminal call printed. Claude Code's Bash
# result carries stdout and stderr, never an output field; Codex passes its
# shell result through as JSON (wv-461da4).
_potu_bash_output() {
    printf '%s' "$1" | jq -r '
        .tool_response
        | if type == "string" then .
          elif type == "object" then (.output // ((.stdout // "") + (.stderr // "")))
          else "" end' 2>/dev/null
}

# The guards run hottest first: every Bash call runs the dedup release, every
# edit the attribution (which costs far more than the parse of the section above it). A Claude adapter names its guard in
# WV_POTU_ONLY and the file stops there, since bash parses a sourced file only as
# far as it executes (the hooks run in parallel, so their time is the call's).

# ─── Bash dedup lock release (was bash-dedup-post.sh) ────────────────────────
# Release or promote the locks wv_ptu_dedup_guard takes, after a Bash command.
#
# Foreground commands: clear ALL matching locks immediately (command is done).
# Background commands: promote ALL matching locks from phase=pending to phase=running,
#   storing the backgroundTaskId in the lock (line 4) so that PreToolUse can use
#   fuser/lsof on the task output file to detect completion rather than waiting
#   for TTL to expire.
#
# Lock file format after promotion (4 lines):
#   line 1: original epoch from PreToolUse (preserved)
#   line 2: "running"
#   line 3: original command (preserved)
#   line 4: backgroundTaskId (e.g. "b10rim7fu"; empty string if unknown)
#
# PreToolUse globs /tmp/claude-*/*/tasks/<taskId>.output and checks fuser/lsof
# to detect when the background subprocess has released the file.
#
# "ALL matching" matters because a compound command (e.g. "wv sync && git push")
# can match multiple lock-key patterns. PreToolUse creates only one lock (first
# match), but this guard clears/promotes all matches for defensive correctness.
wv_potu_dedup_release_guard() (
    set -e; set +u; set +o pipefail
    _potu_tag_hook
    INPUT="$1"
    TOOL=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)

    [[ "$TOOL" != "Bash" && "$TOOL" != "run_in_terminal" ]] && exit 0

    # Always read RESPONSE_OUT — used for background fallback detection.
    RESPONSE_OUT=$(_potu_bash_output "$INPUT")

    # Detect background execution.
    # Primary signal: tool_input.run_in_background field.
    # Fallback: response output contains Claude Code's background task header
    #   (occurs when run_in_background was not set explicitly but Claude Code
    #   still ran the command in background via its own heuristics).
    RUN_IN_BG=$(echo "$INPUT" | jq -r '.tool_input.run_in_background // false' 2>/dev/null)
    if [[ "$RUN_IN_BG" != "true" ]]; then
        [[ "$RESPONSE_OUT" == *"Command running in background with ID:"* ]] && RUN_IN_BG="true"
    fi

    # Extract background task ID for liveness checking.
    # For explicit run_in_background=true: tool_response.backgroundTaskId is populated.
    # For implicit background (fallback path): extract task ID from response output text.
    _TASK_ID=""
    if [[ "$RUN_IN_BG" == "true" ]]; then
        _TASK_ID=$(echo "$INPUT" | jq -r '.tool_response.backgroundTaskId // ""' 2>/dev/null)
        # Fallback: parse from response output text (implicit background path)
        if [[ -z "$_TASK_ID" ]]; then
            _TASK_ID=$(echo "$RESPONSE_OUT" \
                | sed -n 's/.*running in background with ID: \([^ .]*\).*/\1/p' \
                2>/dev/null || echo "")
        fi
        # Validate: task IDs are alphanumeric; reject anything suspicious
        [[ "$_TASK_ID" =~ ^[a-z0-9]+$ ]] || _TASK_ID=""
    fi

    CMD=$(echo "$INPUT" | jq -r '.tool_input.command // .tool_input.cmd // empty' 2>/dev/null)
    [[ -z "$CMD" ]] && exit 0

    # ── Portable repo hash (md5sum → md5 → sha256sum → fallback) ─────────────

    REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
    # Use echo to match hash convention in the dedup guard and all other hooks
    REPO_HASH=$(
        echo "$REPO_ROOT" | md5sum    2>/dev/null | cut -c1-8 ||
        echo "$REPO_ROOT" | md5       2>/dev/null | cut -c1-8 ||
        echo "$REPO_ROOT" | sha256sum 2>/dev/null | cut -c1-8 ||
        echo "default"
    )
    _potu_source wv-resolve-runtime || exit 0
    LOCK_DIR=$(resolve_bash_lock_dir "$REPO_HASH")

    # ── Helper: process one lock key ──────────────────────────────────────────
    # For foreground: clears the lock (command is done).
    # For background: promotes pending→running and stores backgroundTaskId so
    #   PreToolUse can do fuser/lsof liveness checks on the task output file.

    _handle_lock() {
        local key="$1" pattern="$2"
        [[ "$CMD" =~ $pattern ]] || return 0

        local lock_file="${LOCK_DIR}/${key}.lock"
        [[ -f "$lock_file" ]] || return 0

        if [[ "$RUN_IN_BG" == "true" ]]; then
            # Promote: rewrite lock with phase=running, preserving original epoch and cmd.
            # Store backgroundTaskId on line 4 for fuser-based liveness checking.
            local epoch cmd_line
            epoch=$(sed -n '1p' "$lock_file" 2>/dev/null || date +%s)
            cmd_line=$(sed -n '3p' "$lock_file" 2>/dev/null || echo "$CMD")
            # Guard: old 2-line format — cmd is on line 2, no phase line
            if [[ ! "$epoch" =~ ^[0-9]+$ ]]; then
                epoch=$(date +%s)
                cmd_line=$(sed -n '2p' "$lock_file" 2>/dev/null || echo "$CMD")
            fi
            printf '%s\nrunning\n%s\n%s\n' "$epoch" "$cmd_line" "${_TASK_ID}" \
                > "$lock_file" 2>/dev/null || true
        else
            rm -f "$lock_file" 2>/dev/null || true
        fi
    }

    # ── Process all lock-key patterns ─────────────────────────────────────────
    # Patterns must stay in sync with wv_ptu_dedup_guard (wv-pre-tool-use.sh).

    _handle_lock "make-build" "(^|[;[:space:]])(make[[:space:]]+(check|test|build)|make[[:space:]]*$)"
    _handle_lock "wv-sync"    "(^|[[:space:]]*[;&|]+[[:space:]]*)wv[[:space:]]+sync"
    _handle_lock "git-commit" "(^|[[:space:]]*[;&|]+[[:space:]]*)git[[:space:]]+commit"
    _handle_lock "git-push"   "(^|[[:space:]]*[;&|]+[[:space:]]*)git[[:space:]]+push"
    _handle_lock "install"    "(^|[[:space:]])\.\/install\.sh"
    _handle_lock "npm-build"  "npm[[:space:]]+(run|test|build|install)"
    _handle_lock "pytest"     "poetry[[:space:]]+run[[:space:]]+pytest"

    exit 0
)

[ "${WV_POTU_ONLY:-}" = dedup_release ] && return 0

# ─── File attribution (was wv-touched-files.sh) ──────────────────────────────
# Capture file paths edited via Edit/Write/NotebookEdit (and Codex apply_patch)
# into (a) the active node's metadata.touched_files list (dedup, cap 50) and
# node_files, and (b) a per-session recent-edits ring buffer on tmpfs (cap 20,
# FIFO).
#
# Together they let `wv ready` re-rank: nodes whose touched_files overlap
# recent session edits float to top — the agent steers toward work that is
# already in cache (file context loaded, mental model warm).
#
# Sprint B1 from PROPOSAL-wv-active-counterweight (relevance signal in the
# in-source layer; the runtime tracked similar via session edit history).
wv_potu_touched_guard() (
    set -euo pipefail
    _potu_tag_hook
    INPUT="$1"

    _potu_source wv-resolve-project || exit 0
    _potu_source wv-hook-common || true
    _potu_source wv-resolve-runtime || exit 0
    _potu_source wv-attribution || exit 0
    _hc_refresh

    TOOL=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)
    is_attribution_tool "$TOOL" || [ "$TOOL" = "apply_patch" ] || exit 0

    # Skip on tool failure. jq's `// true` collapses explicit false → true (boolean
    # alternative semantics), so check explicit equality instead.
    if echo "$INPUT" | jq -e '.tool_response.success == false' >/dev/null 2>&1; then
        exit 0
    fi

    FILE_PATHS=$(_potu_paths "$INPUT")
    [ -z "$FILE_PATHS" ] && exit 0

    # Normalize to repo-relative path when possible (stable comparison key).
    REPO_ROOT="${WV_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
    # Reject home dir — hook firing from ~ must not treat home as project root.
    if [ "$REPO_ROOT" = "$HOME" ] || [ "$REPO_ROOT" = "/root" ]; then REPO_ROOT=""; fi

    # Per-repo session ring on tmpfs (matches budget-tally hot-zone naming).
    _TF_HOT_ZONE="${_HC_HOT_ZONE}"
    RING_DIR="${WV_TOUCHED_DIR:-$_TF_HOT_ZONE}"
    RING_FILE="${RING_DIR}/recent-edits.txt"
    hot_zone_ensure "$RING_DIR" 2>/dev/null || exit 0
    RING_CAP="${WV_TOUCHED_RING_CAP:-20}"

    _TF_DB="${WV_DB:-$_HC_DB}"
    ACTIVE_ID=""
    if [ -f "$_TF_DB" ]; then
        ACTIVE_ID=$(resolve_active_primary "$_TF_DB" "$_TF_HOT_ZONE") || true
    fi
    NODE_CAP="${WV_TOUCHED_NODE_CAP:-50}"

    while IFS= read -r FILE_PATH; do
        REL_PATH="$FILE_PATH"
        case "$FILE_PATH" in
            "$REPO_ROOT"/*) REL_PATH="${FILE_PATH#"$REPO_ROOT"/}" ;;
        esac

        # Append to ring (newest at bottom), keep last 20 unique paths.
        {
            if [ -f "$RING_FILE" ]; then
                grep -vF -- "$REL_PATH" "$RING_FILE" 2>/dev/null || true
            fi
            echo "$REL_PATH"
        } | tail -n "$RING_CAP" > "${RING_FILE}.new" 2>/dev/null && mv "${RING_FILE}.new" "$RING_FILE" 2>/dev/null || true

        # A path outside the repository (a memory file, a scratch file) stays absolute
        # after normalisation. It is not the node's work product and no test map can
        # route it, so attributing it made wv done report it stale forever.
        case "$REL_PATH" in /*) continue ;; esac

        # Attribute to the active node: metadata.touched_files (cap 50) and node_files.
        # Inside an E5 capture window the write is queued for the agent's next
        # mutation-class wv call, so the graph moves inside a counted agent row
        # (wv-cdafa1, scripts/lib/wv-attribution.sh).
        [ -n "$ACTIVE_ID" ] || continue
        if [ -n "${WV_WORKFLOW_ID:-}" ]; then
            wv_attribution_enqueue "$_TF_DB" "$ACTIVE_ID" "$REL_PATH" || true
        else
            wv_attribution_write "$_TF_DB" "$ACTIVE_ID" "$REL_PATH" "$NODE_CAP" || true
        fi
    done <<< "$FILE_PATHS"

    exit 0
)

[ "${WV_POTU_ONLY:-}" = touched ] && return 0

# ─── wv budget tally (was wv-budget-tally.sh) ────────────────────────────────
# Tally bytes returned by `wv` calls into a per-session budget file. After a
# threshold of calls, emit a one-shot advisory that the agent is calling wv
# broadly; suggest --mode=execute or narrower queries. Soft advisory — never
# blocks.
#
# Counter-weight A2 from PROPOSAL-wv-active-counterweight (BudgetMiddleware
# analogue). The runtime tracked per-call output bytes; this guard does the
# equivalent for sessions where wv is invoked via Bash.
#
# Suppression:
#   WV_NONINTERACTIVE=1  — skip advisory (still tally)
#   WV_BUDGET_DISABLE=1  — skip advisory (still tally)
#
# Tunables:
#   WV_BUDGET_THRESHOLD   — total wv call count that triggers broad advisory (default 20)
#   WV_LIST_THRESHOLD     — wv list call count that triggers list-specific advisory (default 5)
#   WV_BUDGET_DIR         — override budget dir (default: the resolved hot zone)
wv_potu_budget_guard() (
    set -e; set +u; set +o pipefail
    _potu_tag_hook
    INPUT="$1"
    TOOL=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)
    [[ "$TOOL" != "Bash" && "$TOOL" != "run_in_terminal" ]] && exit 0

    CMD=$(echo "$INPUT" | jq -r '.tool_input.command // .tool_input.cmd // empty' 2>/dev/null)
    [[ -z "$CMD" ]] && exit 0

    # Only count `wv ...` invocations (with or without ./scripts/ prefix). Anchored
    # to command-start or after a pipe/semicolon so we do not match `find ... wv*`.
    grep -qE '(^|[;&|][[:space:]]*)(\./scripts/)?wv[[:space:]]' <<< "$CMD" || exit 0

    # Detect `wv list` specifically (flags allowed after; subcommands like `wv listen` excluded).
    IS_LIST=false
    grep -qE '(^|[;&|][[:space:]]*)(\./scripts/)?wv[[:space:]]+list([[:space:]]|$)' <<< "$CMD" && IS_LIST=true

    # The budget file lives where wv health reads it (wv-76bb48): the resolved hot
    # zone, through the one helper both sides call. The hook used to hardcode
    # /dev/shm/weave/<hash>, so under a sandboxed runtime (hot zone
    # /tmp/weave-hotzone-<uid>) health never found the file and scored 25/25 unearned.
    for _bt_lib in wv-resolve-project wv-config wv-resolve-runtime; do _potu_source "$_bt_lib" || true; done
    # An advisory hook: without the resolver it counts nothing rather than guess.
    command -v wv_session_budget_file >/dev/null 2>&1 && command -v resolve_repo_hot_zone >/dev/null 2>&1 || exit 0
    BUDGET_FILE=$(wv_session_budget_file "$(resolve_repo_hot_zone "" "${WV_PROJECT_DIR:-}")")
    BUDGET_DIR="${BUDGET_FILE%/*}"
    hot_zone_ensure "$BUDGET_DIR" 2>/dev/null || exit 0

    OUTPUT=$(_potu_bash_output "$INPUT")
    BYTES=${#OUTPUT}

    # Read prior tally (default zeros).
    PRIOR=$(cat "$BUDGET_FILE" 2>/dev/null || echo '{}')
    CALLS=$(echo "$PRIOR" | jq -r '.calls // 0' 2>/dev/null || echo 0)
    TOTAL=$(echo "$PRIOR" | jq -r '.bytes // 0' 2>/dev/null || echo 0)
    ADVISED=$(echo "$PRIOR" | jq -r '.advised // false' 2>/dev/null || echo false)
    LIST_CALLS=$(echo "$PRIOR" | jq -r '.list_calls // 0' 2>/dev/null || echo 0)
    LIST_ADVISED=$(echo "$PRIOR" | jq -r '.list_advised // false' 2>/dev/null || echo false)
    NEW_CALLS=$((CALLS + 1))
    NEW_BYTES=$((TOTAL + BYTES))
    NEW_LIST_CALLS="$LIST_CALLS"
    [[ "$IS_LIST" = true ]] && NEW_LIST_CALLS=$((LIST_CALLS + 1))

    THRESHOLD="${WV_BUDGET_THRESHOLD:-20}"
    LIST_THRESHOLD="${WV_LIST_THRESHOLD:-5}"

    # Suppression: still tally, but never advise.
    if [[ "${WV_NONINTERACTIVE:-0}" = "1" ]] || [[ "${WV_BUDGET_DISABLE:-0}" = "1" ]]; then
        ADVISED=true
        LIST_ADVISED=true
    fi

    ADVISORY=""

    # List-specific advisory fires first (lower threshold, more targeted message).
    if [[ "$NEW_LIST_CALLS" -ge "$LIST_THRESHOLD" ]] && [[ "$LIST_ADVISED" != "true" ]]; then
        ADVISORY="wv list called ${NEW_LIST_CALLS}x this session — prefer targeted reads: wv show <id> | wv ready | wv query <preds> | wv search <topic>. Use wv list --all only for intentional full enumeration."
        LIST_ADVISED=true
    fi

    # Broad advisory for overall wv call volume (appended if both fire in same call).
    if [[ "$NEW_CALLS" -ge "$THRESHOLD" ]] && [[ "$ADVISED" != "true" ]]; then
        KB=$((NEW_BYTES / 1024))
        BROAD="wv called ${NEW_CALLS}x this session (~${KB}KB returned). Consider --mode=execute or narrower queries (wv show <id>, wv learnings --query=<term>) to keep context lean."
        ADVISORY="${ADVISORY:+${ADVISORY} | }${BROAD}"
        ADVISED=true
    fi

    # Persist updated tally.
    jq -n \
        --argjson calls "$NEW_CALLS" \
        --argjson bytes "$NEW_BYTES" \
        --argjson advised "$ADVISED" \
        --argjson list_calls "$NEW_LIST_CALLS" \
        --argjson list_advised "$LIST_ADVISED" \
        '{calls:$calls, bytes:$bytes, advised:$advised, list_calls:$list_calls, list_advised:$list_advised}' \
        > "$BUDGET_FILE" 2>/dev/null || true

    if [[ -n "$ADVISORY" ]]; then
        _potu_context "$ADVISORY"
    fi

    exit 0
)

[ "${WV_POTU_ONLY:-}" = budget ] && return 0

# ─── Edit linter (was post-edit-lint.sh) ─────────────────────────────────────
# Run linters and formatters on edited files
# - Python files: ruff (lint)
# - Markdown files: prettier (auto-format)
# - Other files: prettier (auto-format if supported)

# _restore_generated_regions <original> <formatted> -- prints <formatted> with
# every '<!-- BEGIN GENERATED ... -->' .. '<!-- END GENERATED ... -->' region
# replaced by the same region from <original>, byte for byte. Those regions
# belong to a generator whose --check compares them exactly; prettier reflowing
# the workflow-classes block in templates/WORKFLOW.md turned make check red
# after an unrelated prose edit (wv-5af710). Exits 3 without a result if the
# regions do not pair up in order, so the caller leaves the file alone.
_restore_generated_regions() {
    awk '
        NR == FNR {
            if ($0 ~ /^<!-- BEGIN GENERATED/) { inside = 1; n++; head[n] = $0 }
            if (inside) region[n] = region[n] $0 "\n"
            if (inside && $0 ~ /^<!-- END GENERATED/) inside = 0
            next
        }
        skipping { if ($0 ~ /^<!-- END GENERATED/) skipping = 0; next }
        /^<!-- BEGIN GENERATED/ {
            k++
            if (k > n || $0 != head[k]) { bad = 1; exit }
            printf "%s", region[k]; skipping = 1; next
        }
        { print }
        END { if (bad || k != n) exit 3 }
    ' "$1" "$2"
}

# _potu_lint_one <file> -- lint or format one edited file; prints an advisory
# message (plain text) when there is something to say.
_potu_lint_one() (
    set -e
    FILE_PATH="$1"

    # Python files: run ruff
    if [[ "$FILE_PATH" =~ \.py$ ]]; then
        if command -v ruff &> /dev/null && [ -f "$FILE_PATH" ]; then
            ISSUES=$(ruff check "$FILE_PATH" 2>&1 || true)
            if [ -n "$ISSUES" ] && [ "$ISSUES" != "All checks passed!" ]; then
                printf 'Ruff lint issues in %s:\n%s\n' "$FILE_PATH" "$ISSUES"
                exit 0
            fi
        fi
        # Also run the project's type checker on the containing module directory
        if command -v pyrefly &> /dev/null; then
            # Identify enclosing Python module (scripts/weave_quality, scripts/weave_gh, etc.)
            MODULE_DIR=""
            case "$FILE_PATH" in
                */weave_quality/*) MODULE_DIR="scripts/weave_quality" ;;
                */weave_gh/*)     MODULE_DIR="scripts/weave_gh" ;;
                tests/*)          MODULE_DIR="tests" ;;
            esac
            if [ -n "$MODULE_DIR" ]; then
                REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "$(pwd)")
                if ! PYREFLY_OUT=$(cd "$REPO_ROOT" && pyrefly check "$MODULE_DIR" --output-format=min-text 2>&1); then
                    printf 'Pyrefly type errors in %s:\n%s\n' "$MODULE_DIR" "$PYREFLY_OUT"
                    exit 0
                fi
            fi
        fi
        exit 0
    fi

    # Markdown and other supported files: run prettier — only within repo root
    # Guard prevents prettier from silently rewriting files outside the project
    # (e.g. ~/.claude/settings.json) which could strip fields it doesn't recognise.
    if [[ "$FILE_PATH" =~ \.(md|json|yaml|yml|js|ts|css|html)$ ]]; then
        REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
        if [ -n "$REPO_ROOT" ] && [[ "$FILE_PATH" == "$REPO_ROOT"/* ]]; then
            if command -v prettier &> /dev/null && [ -f "$FILE_PATH" ]; then
                if ! prettier --check "$FILE_PATH" &> /dev/null; then
                    FORMATTED=$(mktemp)
                    RESULT=$(mktemp)
                    # Format to a temp file and write back only a complete result, in
                    # place so the file keeps its mode.
                    if prettier "$FILE_PATH" > "$FORMATTED" 2>/dev/null; then
                        if grep -q '^<!-- BEGIN GENERATED' "$FILE_PATH"; then
                            _restore_generated_regions "$FILE_PATH" "$FORMATTED" > "$RESULT" || : > "$RESULT"
                        else
                            cp "$FORMATTED" "$RESULT"
                        fi
                        if [ -s "$RESULT" ] && ! cmp -s "$RESULT" "$FILE_PATH"; then
                            cat "$RESULT" > "$FILE_PATH"
                        fi
                    fi
                    rm -f "$FORMATTED" "$RESULT"
                fi
            fi
        fi
        exit 0
    fi

    # Shell/hook source edits: editing these without ./install.sh leaves the installed
    # copy stale, which fails the pre-commit drift gate ~3min in. Nudge immediately —
    # proactive L2 reminder (the cross-agent net is the pre-commit self-heal + the
    # bootstrap advisory; this is the cheap side win where the path is free).
    case "$FILE_PATH" in
        */scripts/*.sh|*/scripts/wv|*/.claude/hooks/*.sh)
            REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
            if [ -n "$REPO_ROOT" ] && [ -x "$REPO_ROOT/install.sh" ]; then
                printf "Edited installed source (%s) — run ./install.sh before committing, or wv doctor / the pre-commit drift gate will report 'hook drift (stale)'.\n" "$FILE_PATH"
                exit 0
            fi
            ;;
    esac

    exit 0
)

# Triggered after Edit/Write (and Codex apply_patch, one file at a time).
wv_potu_lint_guard() (
    set -e
    _potu_tag_hook
    INPUT="$1"

    # Skip linting if the tool call itself failed (tool_response.success = false).
    # PostToolUseFailure fires for hard failures; this guards soft/partial failures.
    # Use jq -e equality: 'jq -r ".x // true"' collapses explicit boolean false to
    # true (alternative-operator semantics on falsey values).
    if echo "$INPUT" | jq -e '.tool_response.success == false' >/dev/null 2>&1; then
        exit 0
    fi

    MESSAGES=""
    while IFS= read -r FILE_PATH; do
        [ -n "$FILE_PATH" ] || continue
        MSG=$(_potu_lint_one "$FILE_PATH" || true)
        [ -z "$MSG" ] || MESSAGES="${MESSAGES:+$MESSAGES
}$MSG"
    done < <(_potu_paths "$INPUT")
    [ -z "$MESSAGES" ] || _potu_context "$MESSAGES"
    exit 0
)

[ "${WV_POTU_ONLY:-}" = lint ] && return 0

# ─── Repo-scoped Claude memory capture (was post-memory-capture.sh) ──────────
# Capture-by-mechanism for repo-scoped Claude memory writes.
#
# When Claude writes a project memory file under
#   $HOME/.claude/projects/<repo-slug>/memory/*.md
# this guard proves the write belongs to THIS repo, then either records an
# advisory (default, dry) or imports it into the graph as a mem_status=candidate
# node (opt-in via WV_MEMORY_CAPTURE=1). It never promotes to active recall and
# never rewrites the write — PreToolUse stays allow/deny only; capture is a
# post-write import (PROPOSAL-wv-agent-memory-substrate S5).
#
# Repo-scope proof (resolves wv-4109ef path-key mismatch): the slug is derived
# from the LIVE repo root (tr '/' '-'), not a hardcoded key, so ~/Projects vs
# ~/Documents checkouts each match only their own Claude memory path.
wv_potu_memory_guard() (
    set -euo pipefail
    _potu_tag_hook
    INPUT="$1"

    _potu_source wv-resolve-project || exit 0
    _potu_source wv-hook-common || true
    _hc_refresh 2>/dev/null || true

    TOOL=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)
    case "$TOOL" in
        Edit|Write|NotebookEdit) ;;
        *) exit 0 ;;
    esac

    # Skip on tool failure (jq `// true` collapses explicit false → true, so test
    # explicit equality).
    if echo "$INPUT" | jq -e '.tool_response.success == false' >/dev/null 2>&1; then
        exit 0
    fi

    FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // .tool_input.filePath // .tool_input.path // ""' 2>/dev/null)
    [ -z "$FILE_PATH" ] && exit 0

    # Only repo-scoped Claude *memory* markdown files are capture sources.
    case "$FILE_PATH" in
        "$HOME"/.claude/projects/*/memory/*.md) ;;
        *) exit 0 ;;
    esac

    # Resolve the live repo root, rejecting $HOME (hook may fire from ~).
    REPO_ROOT="${WV_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
    if [ -z "$REPO_ROOT" ] || [ "$REPO_ROOT" = "$HOME" ] || [ "$REPO_ROOT" = "/root" ]; then
        exit 0
    fi

    # Repo-scope PROOF: the written path's slug segment must equal slug(REPO_ROOT).
    REPO_SLUG=$(printf '%s' "$REPO_ROOT" | tr '/' '-')
    PATH_SLUG="${FILE_PATH#"$HOME"/.claude/projects/}"
    PATH_SLUG="${PATH_SLUG%%/memory/*}"
    if [ "$PATH_SLUG" != "$REPO_SLUG" ]; then
        # A different repo's Claude memory — not ours to import.
        exit 0
    fi

    MEMORY_DIR="${FILE_PATH%/*}"

    # Default is dry: record an advisory the agent/operator can act on, no graph
    # write. Opt in with WV_MEMORY_CAPTURE=1 to import as candidate.
    if [ "${WV_MEMORY_CAPTURE:-0}" != "1" ]; then
        ADVISORY_DIR="${_HC_HOT_ZONE:-${WV_HOT_ZONE:-/tmp}}"
        hot_zone_ensure "$ADVISORY_DIR" 2>/dev/null || exit 0
        printf '%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$MEMORY_DIR" \
            >> "$ADVISORY_DIR/memory-capture-pending.tsv" 2>/dev/null || true
        _potu_context "Repo-scoped Claude memory write detected ($MEMORY_DIR). Graph is the durable authority — import with: wv memory import --source=claude --path='$MEMORY_DIR'. Set WV_MEMORY_CAPTURE=1 to auto-import as candidates."
        exit 0
    fi

    # Opt-in import: create mem_status=candidate nodes (never active recall).
    # Pair the import with this library's tree, not the project's working
    # tree: a protected lane must not run the candidate CLI (wv-971035).
    # Keep the source-before-installed guarantee (wv-706439, wv-b60cd5).
    # An installed library has no ../wv beside it and skips that candidate.
    WV_BIN=""
    for cand in "$(cd "$_POTU_LIB_DIR/.." 2>/dev/null && pwd)/wv" \
        "$HOME/.local/bin/wv" "$(command -v wv 2>/dev/null || true)"; do
        if [ -n "$cand" ] && [ -x "$cand" ] && [ -f "$cand" ]; then WV_BIN="$cand"; break; fi
    done
    [ -z "$WV_BIN" ] && exit 0

    "$WV_BIN" memory import --source=claude --path="$MEMORY_DIR" --repo-root="$REPO_ROOT" >/dev/null 2>&1 || true
    exit 0
)
