#!/usr/bin/env bash
# Weave pre-commit hook: require active node before committing code changes
#
# Enforces the "track ALL work in Weave" rule from AGENTS.md.
# Allows graph-state-only commits and WIP checkpoints through.
#
# Skip with: git commit --no-verify (or WV_SKIP_PRECOMMIT=1)

# Stale-copy guard (wv-98f12b): .git/hooks/ holds a COPY of this file, refreshed
# only by install.sh / wv init-repo. When the repository carries the source and
# the copy differs, run the source instead of silently gating with old logic,
# and say so. WV_HOOK_REEXEC stops a second hop.
_wv_hook_src="$(git rev-parse --show-toplevel 2>/dev/null)/scripts/hooks/pre-commit-weave.sh"
if [ -z "${WV_HOOK_REEXEC:-}" ] && [ -f "$_wv_hook_src" ] && ! cmp -s "$_wv_hook_src" "$0"; then
    echo "Weave pre-commit: installed hook differs from scripts/hooks/pre-commit-weave.sh — running the source (refresh with ./install.sh)" >&2
    export WV_HOOK_REEXEC=1
    exec bash "$_wv_hook_src" "$@"
fi

hook_progress() {
    [ "${WV_HOOK_PROGRESS:-1}" = "0" ] && return 0
    printf '%s\n' "Weave pre-commit: $1" >&2
}

# hook_duration_ms <start_nanos> — wall-clock milliseconds elapsed since a
# `date +%s%N` timestamp (LL1). Returns 0 when nanosecond `date` is unavailable
# (literal "N" output) or the start is the 0 sentinel, so a ledger row never
# carries a bogus negative/garbage cost.
hook_duration_ms() {
    local _t0="$1" _t1 _d
    _t1=$(date +%s%N 2>/dev/null || echo 0)
    case "$_t0" in ''|*[!0-9]*) echo 0; return 0 ;; esac
    case "$_t1" in ''|*[!0-9]*) echo 0; return 0 ;; esac
    [ "$_t0" = "0" ] && { echo 0; return 0; }
    _d=$(( (_t1 - _t0) / 1000000 ))
    [ "$_d" -lt 0 ] && _d=0
    echo "$_d"
}

# The suite pool (run_hook_suites and its helpers) lives in
# scripts/lib/wv-gate-pool.sh, shared with the pre-push gate; it is sourced
# below with the other libraries.

# Prevent recursive hook execution when this hook launches test suites that
# perform their own git commits.
[ "${WV_PRECOMMIT_RUNNING:-0}" = "1" ] && exit 0

# Allow explicit bypass
[ "${WV_SKIP_PRECOMMIT:-0}" = "1" ] && exit 0

# Find wv
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || exit 0)
WV="$(command -v wv 2>/dev/null || echo "$REPO_ROOT/scripts/wv")"
[ ! -x "$WV" ] && exit 0

# Phase helper + enum (best effort). Resolve the lib dir like the wv binary does:
# repo-local scripts/lib/ (source checkout) first, then the installed location.
# Consumer repos run the installed binary and have NO scripts/lib/, so without
# this fallback wv_set_phase + validators silently vanish and the hook degrades
# to its weakest path — wrong phase resolution, no phase reset (finding wv-e754b0 O3).
# Beside this hook first (scripts/hooks/../lib), as pre-push and the suite pool
# below already do: a hook run from a checkout against another repository found
# no $REPO_ROOT/scripts/lib and gated with the INSTALLED helpers, so a source
# fix to wv-checkpoint-ci.sh never reached it (wv-29d13c). A copied .git/hooks
# entry has no ../lib and falls through as before.
_PC_LIB_DIR=""
for _pc_cand in "$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/../lib" \
    "$REPO_ROOT/scripts/lib" "$HOME/.local/lib/weave/lib"; do
    if [ -f "$_pc_cand/wv-config.sh" ]; then _PC_LIB_DIR="$_pc_cand"; break; fi
done
if [ -n "$_PC_LIB_DIR" ]; then
    source "$_PC_LIB_DIR/wv-validate.sh" 2>/dev/null || true
    source "$_PC_LIB_DIR/wv-config.sh" 2>/dev/null || true
    source "$_PC_LIB_DIR/wv-checkpoint-ci.sh" 2>/dev/null || true
fi
# The suite pool comes from beside THIS hook first (scripts/hooks/../lib, the
# source a checkout runs), so a hook run from a checkout never gates with an
# installed pool of a different version; a copied .git/hooks entry falls back
# to the resolved and installed lib dirs. Missing everywhere fails the gate at
# the call site, never silently skips suites.
for _pc_cand in "$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/../lib" \
    "$_PC_LIB_DIR" "$HOME/.local/lib/weave/lib"; do
    if [ -n "$_pc_cand" ] && [ -f "$_pc_cand/wv-gate-pool.sh" ]; then
        source "$_pc_cand/wv-gate-pool.sh"
        break
    fi
done

# Check what's being committed — if only graph state, always allow
# --no-renames throughout: rename detection lists only the new path, so a
# git mv hid the old path from routing and dropped the file from A/M filters
# (wv-29d13c).
STAGED_FILES=$(git diff --cached --name-only --no-renames 2>/dev/null)
[ -z "$STAGED_FILES" ] && exit 0

# Graph state (state.sql, nodes/edges jsonl, deltas, trails) is what wv writes
# as the graph changes, and it selects no suite. The rest of .weave/ --
# test-map.conf, quality.conf, patterns/, evidence/ -- is configuration someone
# edits on purpose, and its own test-map rows must fire: dropping every .weave/
# path let a map-only commit exit 0 with no suite (wv-a118d6). The allowlist is
# the one the checkpoint sites commit by (wv-2e6341), so the two cannot drift.
# NON_WEAVE_FILES keeps its name for the code below; it now means "staged files
# outside graph state".
if command -v wv_staged_non_graph_state >/dev/null 2>&1; then
    NON_WEAVE_FILES=$(wv_staged_non_graph_state "$REPO_ROOT")
else
    NON_WEAVE_FILES=$(echo "$STAGED_FILES" | grep -v '^\.weave/' || true)
    if echo "$STAGED_FILES" | grep -q '^\.weave/'; then
        echo "Weave pre-commit: graph-state helper not found (wv-checkpoint-ci.sh) — staged .weave/ files are not gated; refresh with ./install.sh" >&2
    fi
fi
[ -z "$NON_WEAVE_FILES" ] && exit 0

# Allow auto-checkpoint WIP commits (contain [skip ci] in message)
# The commit message file isn't available in pre-commit, so check env
# Auto-checkpoint sets WV_AUTO_CHECKPOINT_ACTIVE=1
[ "${WV_AUTO_CHECKPOINT_ACTIVE:-0}" = "1" ] && exit 0

# Allow formatting/style-only commits (whitespace-only diff)
if [ "${WV_STYLE_COMMIT:-0}" = "1" ]; then
    exit 0
fi
# If staged diff is whitespace-only, allow without active node
WS_DIFF=$(git diff --cached -w --stat 2>/dev/null)
FULL_DIFF=$(git diff --cached --stat 2>/dev/null)
if [ -z "$WS_DIFF" ] && [ -n "$FULL_DIFF" ]; then
    echo "ℹ Whitespace-only change — allowing without active node" >&2
    exit 0
fi

# ── Gate measurement (wv-ffda33) ── Armed only past the early exits above, so
# .weave-only and checkpoint commits do not drown real gate times. Every suite
# record this gate writes carries WV_GATE_PHASE/WV_GATE_ID, and the EXIT trap
# writes one gate record -- wall time, the estimate it announced, the suites it
# selected, and how it ended -- on success and on every failure path alike.
export WV_GATE_PHASE=pre-commit
WV_GATE_ID="pc-$(date +%s%N 2>/dev/null || date +%s)-$$"
export WV_GATE_ID
_pc_gate_t0=$(date +%s%N 2>/dev/null || echo 0)
_pc_gate_suites=""
_pc_gate_estimate_ms=""
_pc_gate_finish() {
    local rc=$?
    "$WV" test-record gate --gate --exit="$rc" --duration="$(hook_duration_ms "$_pc_gate_t0")" \
        --estimate="$_pc_gate_estimate_ms" --suites="$_pc_gate_suites" >/dev/null 2>&1 || true
    return "$rc"
}
trap _pc_gate_finish EXIT

# ── Self-heal install drift (cross-agent) ──
# Editing weave source (scripts/*.sh, .claude/hooks/*.sh) without reinstalling
# leaves the installed copies stale, which the drift gate only catches ~3min into
# the test suite. Reinstall up front so no harness — Claude, Codex, Copilot —
# eats that late failure. Only acts in the dev repo (install.sh present).
#
# Never under a test run (WV_CALL_SOURCE=test: the gate pool sets it for every
# suite, and suites export it). A suite that commits inside its fixture runs
# this hook, and the install below targets the REAL HOME, so a test run
# reinstalled the host from whatever the working tree held — an uncommitted
# edit, or a planted mutant (wv-75937a, cloud probe wv-0b9d5c).
if command -v _wv_source_drift >/dev/null 2>&1; then
    if _pc_drift=$(_wv_source_drift); then
        _pc_src=$(cat "${WV_CONFIG_DIR:-$HOME/.config/weave}/source-path" 2>/dev/null || echo "")
        if [ "${WV_CALL_SOURCE:-}" = "test" ]; then
            echo "Weave pre-commit: install drift ($_pc_drift) — not self-healing under a test run" >&2
        elif [ -n "$_pc_src" ] && [ -x "$_pc_src/install.sh" ]; then
            echo "Weave pre-commit: install drift ($_pc_drift) — self-healing via ./install.sh..." >&2
            # Self-heal must install to the REAL machine location regardless of
            # who/what triggered this hook. A test harness's exported isolation
            # vars (e.g. tests/test-hooks.sh sets WV_LIB_DIR=<repo>/scripts to
            # sandbox its own fixtures) leak into this subshell and previously
            # redirected the MCP build into a stray, untracked scripts/mcp/ tree
            # instead of ~/.local/lib/weave/mcp (found via wv-fa566a follow-up).
            if ( unset WV_LIB_DIR WV_CONFIG_DIR WV_HOT_ZONE WV_DB WV_PROJECT_DIR; cd "$_pc_src" && ./install.sh ) >/dev/null 2>&1; then
                echo "Weave pre-commit: install drift healed." >&2
            else
                echo "Weave pre-commit: ./install.sh failed — run it manually before committing." >&2
            fi
        fi
    fi
fi

# Run ruff linter on staged Python files (added/modified only — skip deletions)
STAGED_PY_FILES=$(git diff --cached --name-only --no-renames --diff-filter=AM 2>/dev/null | grep '\.py$' | grep -v '^\.weave/' || true)
if [ -n "$STAGED_PY_FILES" ]; then
    if command -v ruff > /dev/null 2>&1; then
        hook_progress "running ruff on staged Python files..."
        # shellcheck disable=SC2086
        RUFF_OUT=$(ruff check $STAGED_PY_FILES 2>&1 || true)
        if [ -n "$RUFF_OUT" ] && [ "$RUFF_OUT" != "All checks passed!" ]; then
            echo "" >&2
            echo "✗ ruff lint errors in staged files:" >&2
            echo "$RUFF_OUT" >&2
            echo "" >&2
            echo "  Fix with: ruff check --fix <file>  (then re-stage)" >&2
            echo "" >&2
            exit 1
        fi
    fi
fi

# The weave_quality pytest suite asserts the managed-rule manifest is complete
# and that every managed rule carries an executable example, so a rule YAML is
# inside its scope even when no Python file changes. Keyed on staged .py alone,
# it never ran for a rule-only commit: prose-significance-scaffold was added
# with its manifest entry but no example, and sat failing until an unrelated
# Python change happened to stage alongside it.
STAGED_QUALITY_RULES=$(git diff --cached --name-only --no-renames --diff-filter=AMD 2>/dev/null \
    | grep -E '^(templates/quality-patterns|\.weave/patterns)/managed/' || true)
if [ -n "$STAGED_PY_FILES" ] || [ -n "$STAGED_QUALITY_RULES" ]; then
    if [ -f "$REPO_ROOT/.venv/bin/python3" ]; then
        PYTHON3="$REPO_ROOT/.venv/bin/python3"
    else
        PYTHON3=$(command -v python3 2>/dev/null || echo "")
    fi
    if [ -n "$PYTHON3" ] && "$PYTHON3" -c "import pytest" >/dev/null 2>&1; then
        _pc_pytest_dirs=""
        for _pc_dir in "$REPO_ROOT/tests/weave_quality" "$REPO_ROOT/tests/weave_indexer"; do
            [ -d "$_pc_dir" ] && _pc_pytest_dirs="${_pc_pytest_dirs}${_pc_pytest_dirs:+ }$_pc_dir"
        done
        if [ -n "$_pc_pytest_dirs" ]; then
            hook_progress "running focused pytest checks for staged Python/rule changes..."
            # shellcheck disable=SC2086
            # Isolated from the commit's git environment: the tests build their
            # own repositories (wv-34ef3d).
            if ! gate_isolated "$PYTHON3" -m pytest $_pc_pytest_dirs -q --tb=short 2>&1; then
                echo "" >&2
                echo "✗ pytest tests failed — fix before committing." >&2
                exit 1
            fi
        fi
    fi
fi

# Run shellcheck on the STAGED CONTENT of shell files.
#
# Lint is not reachable through impact-selected suite routing: shellcheck lives
# in `make check`, so a lint regression in a file the map DOES route stays
# invisible behind green suites (b3f84bbb introduced SC1090 in pre-action.sh,
# a mapped file whose suites all passed, and it went two commits unnoticed).
#
# THE BLOB, NOT THE WORKING TREE. Naming staged files and letting shellcheck
# read them off disk checks whatever is in the worktree, so a dirty index behind
# a clean worktree committed content that was never linted.
#
# NUL-SAFE END TO END. An earlier version piped `-z` output through `tr '\0'
# '\n'`, which throws the safety away at the first step: a path containing a
# newline was silently skipped. `xargs` then split paths on spaces, turning one
# real file into two nonexistent ones and blocking the commit for files that
# were fine. Paths are read into an array with `mapfile -d ''` and passed as
# arguments to the linter — no tr, no xargs, no word splitting.
#
# FAILS CLOSED. If the temp dir or the materialisation cannot be produced, the
# commit is refused. Warning and continuing turns the gate off silently, which
# is the failure mode this whole gate exists to prevent.
if command -v shellcheck >/dev/null 2>&1; then
    _pc_sc_all=()
    mapfile -d '' -t _pc_sc_all < <(git diff --cached --name-only --diff-filter=ACMR -z 2>/dev/null)
    _pc_sc_files=()
    for _pc_f in "${_pc_sc_all[@]}"; do
        case "$_pc_f" in
            scripts/*.sh|.claude/*.sh|install.sh|install-mcp.sh|build-release.sh|scripts/wv-battery-wrapper)
                _pc_sc_files+=("$_pc_f") ;;
        esac
    done
    if [ "${#_pc_sc_files[@]}" -gt 0 ]; then
        hook_progress "running shellcheck on ${#_pc_sc_files[@]} staged shell file(s)..."
        _pc_sc_dir=$(mktemp -d "${TMPDIR:-/tmp}/wv-sc.XXXXXX" 2>/dev/null) || _pc_sc_dir=""
        # Checked BEFORE any --prefix is built: an empty value would make the
        # prefix "/" and materialise the index over the filesystem root.
        if [ -z "$_pc_sc_dir" ] || [ ! -d "$_pc_sc_dir" ]; then
            echo "✗ shellcheck gate: could not create a temp directory — refusing to commit unlinted content" >&2
            exit 1
        fi
        if ! printf '%s\0' "${_pc_sc_files[@]}" \
            | git checkout-index -f -z --stdin --prefix="$_pc_sc_dir/" 2>/dev/null; then
            rm -rf "$_pc_sc_dir"
            echo "✗ shellcheck gate: could not materialise the staged index — refusing to commit unlinted content" >&2
            exit 1
        fi
        [ -f "$REPO_ROOT/.shellcheckrc" ] && cp "$REPO_ROOT/.shellcheckrc" "$_pc_sc_dir/" 2>/dev/null
        _pc_sc_rc=0
        _pc_sc_out=$( cd "$_pc_sc_dir" && shellcheck --severity=warning -- "${_pc_sc_files[@]}" 2>&1 ) || _pc_sc_rc=$?
        rm -rf "$_pc_sc_dir"
        if [ "$_pc_sc_rc" -ne 0 ]; then
            echo "" >&2
            echo "✗ shellcheck findings in STAGED content:" >&2
            echo "$_pc_sc_out" >&2
            echo "" >&2
            echo "  These are the bytes being committed — the working tree may differ." >&2
            echo "  Fix, then re-stage. Project-wide suppressions live in .shellcheckrc" >&2
            echo "" >&2
            exit 1
        fi
    fi
fi

# Prose gate for staged markdown (wv-7816b4). Docs are not reachable through
# impact-selected suite routing -- most of docs/ maps to no suite at all -- so
# prose drift and markdown defects land unchecked. This session reflowed a doc
# to 100 columns, split `(kind, id, lineage_seq, lineage_actor)` across a line
# break inside a code span, and committed it; only a post-hoc scan caught it.
#
# THE BLOB, NOT THE WORKING TREE, for the same reason shellcheck above uses it.
#
# BASELINE-RELATIVE. Only findings the diff ADDS block. The repo carries
# hundreds of pre-existing hits (82 `, so` in CHANGELOG.md); failing on
# inherited debt would train the bypass reflex this gate exists to avoid.
#
# SOURCE-SCOPED. Every rule is `info` severity, so severity cannot separate a
# rendering defect from house style. Managed + custom rules (the curated AI-tell
# corpus) block; default rules advise.
#
# FAILS CLOSED on a materialisation it cannot produce, open on a missing
# scanner -- an unavailable optional tool must not wedge every commit.
_pc_md_all=()
mapfile -d '' -t _pc_md_all < <(git diff --cached --name-only --diff-filter=ACMR -z 2>/dev/null)
_pc_md_files=()
for _pc_f in "${_pc_md_all[@]}"; do
    case "$_pc_f" in
        *.md) _pc_md_files+=("$_pc_f") ;;
    esac
done
if [ "${#_pc_md_files[@]}" -gt 0 ] && [ -f "$REPO_ROOT/scripts/prose-gate.py" ]; then
    hook_progress "prose gate on ${#_pc_md_files[@]} staged markdown file(s)..."
    _pc_md_dir=$(mktemp -d "${TMPDIR:-/tmp}/wv-prose.XXXXXX" 2>/dev/null) || _pc_md_dir=""
    # Checked BEFORE any --prefix is built: an empty value would make the
    # prefix "/" and materialise the index over the filesystem root.
    if [ -z "$_pc_md_dir" ] || [ ! -d "$_pc_md_dir" ]; then
        echo "✗ prose gate: could not create a temp directory — refusing to commit unscanned content" >&2
        exit 1
    fi
    if ! printf '%s\0' "${_pc_md_files[@]}" \
        | git checkout-index -f -z --stdin --prefix="$_pc_md_dir/staged/" 2>/dev/null; then
        rm -rf "$_pc_md_dir"
        echo "✗ prose gate: could not materialise the staged index — refusing to commit unscanned content" >&2
        exit 1
    fi
    # HEAD baseline. A path absent here is a new file and baselines to empty,
    # which prose-gate.py handles; an unborn HEAD leaves the dir empty entirely.
    for _pc_f in "${_pc_md_files[@]}"; do
        mkdir -p "$_pc_md_dir/head/$(dirname "$_pc_f")" 2>/dev/null || true
        git show "HEAD:$_pc_f" > "$_pc_md_dir/head/$_pc_f" 2>/dev/null || \
            rm -f "$_pc_md_dir/head/$_pc_f" 2>/dev/null || true
    done
    _pc_md_rc=0
    WV_BIN="$WV" python3 "$REPO_ROOT/scripts/prose-gate.py" \
        "$_pc_md_dir/staged" "$_pc_md_dir/head" "${_pc_md_files[@]}" || _pc_md_rc=$?
    rm -rf "$_pc_md_dir"
    if [ "$_pc_md_rc" -ne 0 ]; then
        exit 1
    fi
fi

# ── Release leak guard (wv-4351d6) ──
# A shipped test that names a stripped Rust evidence path breaks
# tests/test-release.sh, yet a change to a test file selects only that file's
# own suite, so the check never ran on the commit that broke it (wv-eeaded).
# Where the repository carries the guard (the release builder's own source
# repository), any staged tests/ path or build-release.sh runs it against the
# STAGED index, not the working tree (wv-d6c692). Consumer repositories have no
# build-release.sh, so this is a no-op there.
#
# FAILS CLOSED on a materialisation it cannot produce, like the prose gate.
_pc_leak_hit=false
for _pc_f in "${_pc_md_all[@]}"; do
    case "$_pc_f" in tests/* | build-release.sh) _pc_leak_hit=true; break ;; esac
done
if [ "$_pc_leak_hit" = true ] && git ls-files --error-unmatch -- build-release.sh tests/test-shipped-test-refs.sh >/dev/null 2>&1; then
    hook_progress "release leak guard on the staged tests/..."
    _pc_leak_dir=$(mktemp -d "${TMPDIR:-/tmp}/wv-leak.XXXXXX" 2>/dev/null) || _pc_leak_dir=""
    if [ -z "$_pc_leak_dir" ] || [ ! -d "$_pc_leak_dir" ]; then
        echo "✗ release leak guard: could not create a temp directory — refusing to commit unchecked tests" >&2
        exit 1
    fi
    if ! git ls-files -z -- tests build-release.sh \
        | git checkout-index -f -z --stdin --prefix="$_pc_leak_dir/" 2>/dev/null; then
        rm -rf "$_pc_leak_dir"
        echo "✗ release leak guard: could not materialise the staged index — refusing to commit unchecked tests" >&2
        exit 1
    fi
    _pc_leak_rc=0
    bash "$_pc_leak_dir/tests/test-shipped-test-refs.sh" --scan "$_pc_leak_dir" || _pc_leak_rc=$?
    rm -rf "$_pc_leak_dir"
    if [ "$_pc_leak_rc" -ne 0 ]; then
        exit 1
    fi
fi

# Run fast shell workflow suites determined by wv impact --suites.
# Mapping is driven by .weave/test-map.conf + naming-convention heuristics.
# tests/run-all.sh is a meta-runner — skip it.
_pc_files_csv=$(printf '%s\n' "$NON_WEAVE_FILES" | paste -sd ',' -)
if [ -n "$_pc_files_csv" ]; then
    # The suite pool is required: without it a call below would print "command
    # not found" and the hook -- which does not run under set -e -- would carry
    # on and pass with no suite run (found by ultrareview follow-up).
    if ! command -v run_hook_suites >/dev/null 2>&1 || ! command -v gate_pool_estimates >/dev/null 2>&1 \
        || ! command -v gate_pool_launch_order >/dev/null 2>&1; then
        echo "✗ Weave pre-commit: the suite pool (wv-gate-pool.sh) was not found — refresh with ./install.sh" >&2
        exit 1
    fi
    _pc_suites_json=$("$WV" impact --suites --files="$_pc_files_csv" 2>/dev/null || echo '[]')
    _pc_suites_json=$(gate_pool_estimates "$_pc_suites_json")
    _pc_suite_count=$(printf '%s' "$_pc_suites_json" | jq 'length' 2>/dev/null || echo 0)
    # Push tier (wv-862ac0). A suite in the test map's [heavy] section is left
    # to the pre-push gate, which runs every heavy suite the pushed commits
    # select against the pushed tip and refuses the push until each is green.
    # Only when that gate is really installed in the hooks git will run: with
    # no Weave pre-push hook, deferring would mean the suite never runs, so it
    # runs here as it always did.
    _pc_heavy=$(jq -r '[.[] | select(.tier == "heavy") | .name] | join(", ")' <<< "$_pc_suites_json" 2>/dev/null || echo "")
    if [ -n "$_pc_heavy" ]; then
        # The same predicate wv done uses; an older library without it counts
        # as "not installed", which runs the heavy suites here -- the safe way.
        if command -v wv_prepush_gate_installed >/dev/null 2>&1 && wv_prepush_gate_installed; then
            hook_progress "deferred to the pre-push gate (heavy tier): $_pc_heavy"
            _pc_suites_json=$(jq -c '[.[] | select(.tier != "heavy")]' <<< "$_pc_suites_json" 2>/dev/null || echo '[]')
        else
            hook_progress "no Weave pre-push gate installed — running heavy-tier suites here: $_pc_heavy"
        fi
    fi
    _pc_light_count=$(printf '%s' "$_pc_suites_json" | jq 'length' 2>/dev/null || echo 0)
    if [ "${_pc_suite_count:-0}" -gt 0 ] && [ "${_pc_light_count:-0}" -eq 0 ]; then
        hook_progress "every selected suite is heavy-tier; nothing to run before commit"
    elif [ "${_pc_suite_count:-0}" -gt 0 ]; then
        _pc_gate_suites=$(printf '%s' "$_pc_suites_json" | jq -r '[.[].name] | join(",")' 2>/dev/null || echo "")
        _pc_selected=$(printf '%s' "$_pc_suites_json" | jq -r '[.[].name] | join(", ")' 2>/dev/null || echo "")
        _pc_selected_cost=$(printf '%s' "$_pc_suites_json" | jq '[.[].last_cost_s // 0] | add // 0' 2>/dev/null || echo 0)
        # Count suites with no recorded time so the total is not quoted as if it
        # covered them; an unmeasured suite contributes 0 and would silently
        # understate the wait.
        _pc_unmeasured=$(printf '%s' "$_pc_suites_json" | jq '[.[] | select((.last_cost_s // 0) <= 0)] | length' 2>/dev/null || echo 0)
        if [ "${_pc_unmeasured:-0}" -eq 0 ] 2>/dev/null; then
            # Only a fully measured total is recorded as the gate's estimate; a
            # partial sum would make the estimate error look better than it is.
            _pc_gate_estimate_ms=$(( ${_pc_selected_cost:-0} * 1000 ))
            hook_progress "impact-selected shell suites: $_pc_selected (~${_pc_selected_cost}s)"
        elif [ "${_pc_selected_cost:-0}" -gt 0 ] 2>/dev/null; then
            hook_progress "impact-selected shell suites: $_pc_selected (~${_pc_selected_cost}s measured, ${_pc_unmeasured} not yet measured)"
        else
            hook_progress "impact-selected shell suites: $_pc_selected (duration not yet measured)"
        fi
        _pc_launch=$(gate_pool_launch_order "$_pc_suites_json")
        run_hook_suites <<< "$_pc_launch"
    else
        # No suite matched any staged source file — the impact gate is inert for
        # this commit. Surface it so silent test-map rot becomes visible instead
        # of passing as if it were gated (add a glob/prefix or [default] entry to
        # .weave/test-map.conf, or run wv test-config to scaffold one).
        #
        # wv-734186: the message used to be identical whether .weave/test-map.conf
        # was entirely absent or present-but-non-matching -- a half-configured
        # gate looked exactly like an unconfigured one, and repeated on every
        # commit regardless. Distinguish the two, and name a sample of the
        # actual unmatched staged files (not just a count) in the second case.
        _pc_unmapped_count=$(printf '%s\n' "$NON_WEAVE_FILES" | grep -c . 2>/dev/null || echo 0)
        _pc_unmapped_sample=$(printf '%s\n' "$NON_WEAVE_FILES" | grep -v '^$' | head -3 | paste -sd ', ' -)
        if [ ! -f "$REPO_ROOT/.weave/test-map.conf" ]; then
            echo "⚠ impact gate inert: no .weave/test-map.conf found — $_pc_unmapped_count staged file(s) unmapped, no suite ran." >&2
            echo "  Run 'wv test-config' to scaffold one, or add a glob/prefix/[default] entry (e.g. 'src/ = tests/...')." >&2
        else
            echo "⚠ impact gate inert: .weave/test-map.conf exists but matched none of $_pc_unmapped_count staged file(s), no suite ran." >&2
            echo "  Unmatched: $_pc_unmapped_sample" >&2
            echo "  Add a glob/prefix/[default] entry covering them (e.g. 'src/ = tests/...') to .weave/test-map.conf." >&2
        fi
    fi
fi


# Phase-aware enforcement: allow commits in discover and closing phases.
# discover = exploring before claiming; closing = recording just-closed work.
# execute  = substantive work in progress (enforce active node).
# closing is bounded: after one commit (the wv-sync .weave/ commit), reset to
# discover so subsequent work requires a node claim before the next commit.
_PC_REPO_HASH=$(echo "$REPO_ROOT" | md5sum | cut -c1-8)
_PC_HOT_ZONE="${WV_HOT_ZONE:-/dev/shm/weave/${_PC_REPO_HASH}}"
_PC_PHASE=$(cat "${_PC_HOT_ZONE}/.session_phase" 2>/dev/null || echo "execute")

if [ "$_PC_PHASE" = "closing" ]; then
    command -v wv_set_phase >/dev/null 2>&1 && { wv_set_phase "discover" "$_PC_HOT_ZONE" || true; }
    exit 0
fi

# Check for active Weave nodes (execute phase only)
hook_progress "checking for an active Weave node..."
ACTIVE_COUNT=$("$WV" list --status=active --json 2>/dev/null | jq 'length' 2>/dev/null || echo "0")

if [ "$ACTIVE_COUNT" = "0" ] || [ -z "$ACTIVE_COUNT" ]; then
    cat >&2 << 'EOF'

╔══════════════════════════════════════════════════════════════╗
║  ⚠  No active Weave node — commit blocked                    ║
║                                                              ║
║  Every code change must be tracked. Either:                  ║
║    wv work <id>         # claim an existing task             ║
║    wv add "..." --gh    # create + track new work            ║
║                                                              ║
║  Then retry your commit.                                     ║
║                                                              ║
║  Bypass: git commit --no-verify                              ║
║          WV_SKIP_PRECOMMIT=1 git commit                      ║
╚══════════════════════════════════════════════════════════════╝

EOF
    exit 1
fi

exit 0
