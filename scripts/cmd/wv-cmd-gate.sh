#!/bin/bash
# wv-cmd-gate.sh — the commands the commit gate runs: config, test-record, test-status
#
# Commands: config, test-record, test-status
# Sourced by: wv entry point (autoloaded on first use)
# Dependencies: wv-config.sh, wv-db.sh, wv-validate.sh, wv-checkpoint-ci.sh, wv-cmd-graph.sh
#
# Moved out of wv-cmd-ops.sh unchanged (wv-56fca6). The gate's pool and hook call
# these three commands, and test-record and test-status read and write the reuse
# ledger, so this module is an invoking file in scripts/hooks/gate-roles.json:
# a change to it reruns its candidate lane's suites. Keeping them apart lets the
# rest of wv-cmd-ops.sh (doctor, bootstrap, health, pattern-audit) leave that set.

# _test_file_fingerprint <path> — content fingerprint of a SINGLE file for the
# test_results ledger. git blob hash (pure function of content; identical whether
# computed by the producer here or the consumer in _done_refresh_test_status),
# with an mtime:size fallback for untracked files or when git is unavailable.
# This is the single fingerprint definition both sides share — there is no
# combined-over-a-set key for either side to reconstruct.
_test_file_fingerprint() {
    local f="$1" h
    h=$(git hash-object "$f" 2>/dev/null)
    [ -z "$h" ] && h=$(stat -c '%Y:%s' "$f" 2>/dev/null || echo "missing")
    printf '%s' "$h"
}

# _test_file_fingerprint_staged <path> — fingerprint the blob currently in the
# Git index. A pre-commit freshness probe must describe the bytes Git will
# commit, not a possibly different working-tree copy. Deleted/missing index
# entries use the same "missing" sentinel as the current-file fallback above.
_test_file_fingerprint_staged() {
    local f="$1" h
    h=$(git rev-parse --verify ":$f" 2>/dev/null || true)
    [ -z "$h" ] && h="missing"
    printf '%s' "$h"
}

# ── Input keys (wv-cb4913, gate-latency S5; wv-f0bcc4) ── The gate reuses a
# suite's result when the bytes the suite reads are the bytes it was green on.
# A file that differs from a base commit is keyed by its mode and blob; every
# other file is pinned by the base itself. A suite's key hashes the base, the
# test-map.conf the router reads, the suite's own file, and its keyed changes:
#   - a suite with a complete input scope declared under [inputs] in
#     test-map.conf: the changed files in that scope or routed to it, so a
#     retry after a one-file fix reruns only the suites that file feeds;
#   - any other suite: every changed file. Routing is not an input manifest:
#     a route records that a suite caught a planted break in a file, not that
#     the suite reads nothing else (scripts/weave_quality/__main__.py selects
#     test-quality.sh and imports prose_shape.py, which routes elsewhere), and
#     a fresh gate runs a selected suite against every staged file.
# An [inputs] scope is a claim of completeness; declare one only with evidence
# of what the suite reads.

# The newest input-key rows test-record keeps per suite.
_TEST_INPUT_ROWS=20

# _test_input_base — the commit input keys are relative to: the merge-base with
# the upstream, so a commit landing on top of a green run does not reset every
# key; else HEAD; else the empty tree (unborn branch).
_test_input_base() {
    local up mb
    if up=$(git rev-parse --verify -q '@{u}' 2>/dev/null) && [ -n "$up" ] \
        && mb=$(git merge-base HEAD "$up" 2>/dev/null) && [ -n "$mb" ]; then
        printf '%s\n' "$mb"
        return 0
    fi
    git rev-parse --verify -q HEAD 2>/dev/null || git hash-object -t tree /dev/null
}

# _test_input_scopes — "<suite>\t<globs>" for each [inputs] entry of the
# working-tree test-map.conf.
_test_input_scopes() {
    awk '/^[[:space:]]*\[/ { sec = $0; gsub(/[[:space:]]/, "", sec); next }
         sec == "[inputs]" && /=/ && !/^[[:space:]]*#/ {
             k = $0; sub(/[[:space:]]*=.*/, "", k); gsub(/^[[:space:]]+/, "", k)
             v = $0; sub(/^[^=]*=[[:space:]]*/, "", v)
             print k "\t" v }' "$WEAVE_DIR/test-map.conf" 2>/dev/null
}

# _test_input_keys <staged|worktree> <suite>... — prints "<key>\t<suite>" per
# suite. staged keys what the commit carries: the index's mode and blob, and
# missing for a path the index lacks even if it is still on disk, since the
# commit will not have it. worktree keys what a suite started now would read.
# A result recorded with a worktree key matches a staged key only when the
# index holds exactly the files tested, modes included.
#
# Absence is an input ("missing"); failing to observe is not. Each acquisition
# -- the index listing, every blob hash, the key hash itself -- is checked and
# its output validated, and any failure makes the key uncomputable (return 1),
# so the caller runs the suite. Read as missing or unreadable, a failed
# listing or a short hash batch minted the same key for different content
# (wv-3fab34).
_test_input_keys() {
    local mode="$1"; shift
    [ $# -gt 0 ] || return 0
    local top base changed paths routes conf_fp suite p g fm scopes keyed
    top=$(git rev-parse --show-toplevel 2>/dev/null) || return 1
    base=$(_test_input_base) || return 1
    # Every input below is required: a listing, conf hash or route table that
    # failed would key a suite on fewer inputs than it has, and a green result
    # for the narrower key would be reused (wv-cf48a9). The key is then
    # uncomputable and the caller runs the suite. PIPESTATUS carries git's
    # status out past tr.
    local cached=()
    [ "$mode" = staged ] && cached=(--cached)
    changed=$(git -C "$top" diff "${cached[@]}" --name-only --no-renames -z "$base" 2>/dev/null \
        | tr '\0' '\n'; exit "${PIPESTATUS[0]}") || return 1
    # Graph state is never routed by either gate, so it is no suite's input.
    changed=$(printf '%s\n' "$changed" | wv_non_graph_state_paths)
    # The router reads the working-tree conf in both modes, so that is what
    # decides which inputs a suite has.
    local conf_rc=0
    wv_config_read "$WEAVE_DIR/test-map.conf" >/dev/null || conf_rc=$?
    case "$conf_rc" in
        0) conf_fp=$(git hash-object -- "$WEAVE_DIR/test-map.conf" 2>/dev/null) || return 1
           _test_input_is_blob "$conf_fp" || return 1 ;;
        2) conf_fp=missing ;;
        *) return 1 ;;
    esac
    paths=$({ printf '%s\n' "$changed"; printf '%s\n' "$@"; } | grep -v '^$' | LC_ALL=C sort -u)
    # c[path] = "<mode> <blob>", or unset for missing. The index's entries
    # first: the staged content, and the worktree's mode when core.fileMode
    # is off (git then ignores the executable bit, so must this).
    declare -A c=() idx=()
    local m b listing
    listing=$(git -C "$top" ls-files -s -z -- 2>/dev/null | tr '\0' '\n'; exit "${PIPESTATUS[0]}") || return 1
    while IFS=$'\t' read -r fm p; do
        [ -n "$p" ] || continue
        # "<mode> <blob> <stage>": anything else is a listing this cannot trust.
        [[ "$fm" =~ ^[0-7]{6}\ [0-9a-f]{40}([0-9a-f]{24})?\ [0-3]$ ]] || return 1
        read -r m b _ <<< "$fm"
        idx["$p"]="$m $b"
    done < <(awk -F'\t' 'NR == FNR { want[$0] = 1; next } ($2 in want)' <(printf '%s\n' "$paths") - <<< "$listing")
    if [ "$mode" = staged ]; then
        for p in "${!idx[@]}"; do c["$p"]="${idx[$p]}"; done
    else
        local filemode regular=() blobs=() i d
        filemode=$(git -C "$top" config --bool core.fileMode 2>/dev/null || echo true)
        # git diff cannot see into a directory it cannot search: a file added
        # since the base under one is listed as nothing at all, and every key
        # then omits it. So each directory holding a tracked file must be
        # observable -- searchable, or observably absent.
        while IFS= read -r d; do
            [ -n "$d" ] || continue
            if [ -d "$top/$d" ]; then
                [ -x "$top/$d" ] || return 1
            elif ! wv_path_absent "$top/$d"; then
                return 1
            fi
        done < <(cut -f2 <<< "$listing" | sed -n 's|/[^/]*$||p' | LC_ALL=C sort -u)
        local target hash
        while IFS= read -r p; do
            [ -n "$p" ] || continue
            if [ -L "$top/$p" ]; then
                target=$(readlink -- "$top/$p") || return 1
                hash=$(printf '%s' "$target" | tr -d '\n' | git hash-object --stdin 2>/dev/null) || return 1
                _test_input_is_blob "$hash" || return 1
                c["$p"]="120000 $hash"
            elif [ -f "$top/$p" ]; then
                regular+=("$p")
            elif ! wv_path_absent "$top/$p"; then
                # A directory or special file where a file was, or a path
                # whose absence cannot be observed: not "missing".
                return 1
            fi
        done <<< "$paths"
        if [ "${#regular[@]}" -gt 0 ]; then
            local hashed
            hashed=$(printf '%s\n' "${regular[@]}" | git -C "$top" hash-object --stdin-paths 2>/dev/null; \
                exit "${PIPESTATUS[1]}") || return 1
            mapfile -t blobs <<< "$hashed"
            # One blob per requested path, each a blob id: a short batch left
            # the rest keyed by a sentinel whatever their content.
            [ "${#blobs[@]}" -eq "${#regular[@]}" ] || return 1
            for i in "${!regular[@]}"; do
                _test_input_is_blob "${blobs[$i]}" || return 1
                p="${regular[$i]}"
                if [ "$filemode" = false ]; then
                    fm="${idx[$p]%% *}"; fm="${fm:-100644}"
                elif [ -x "$top/$p" ]; then
                    fm=100755
                else
                    fm=100644
                fi
                c["$p"]="$fm ${blobs[$i]}"
            done
        fi
    fi
    routes=""
    if [ -n "$changed" ]; then
        local changed_args=()
        mapfile -t changed_args <<< "$changed"
        routes=$(_impact_suites_for_files --routes "${changed_args[@]}") || return 1
    fi
    declare -A scope=()
    while IFS=$'\t' read -r suite g; do
        [ -n "$suite" ] && scope["$suite"]="$g"
    done < <(_test_input_scopes)
    for suite in "$@"; do
        [ -n "$suite" ] || continue
        if [ -n "${scope[$suite]+x}" ]; then
            # Declared: changed files in the scope, plus any routed to it.
            read -ra scopes <<< "${scope[$suite]}"
            keyed=$( {
                awk -F'\t' -v s="$suite" '$2 == s { print $1 }' <<< "$routes"
                while IFS= read -r p; do
                    [ -n "$p" ] || continue
                    for g in "${scopes[@]}"; do
                        # unquoted RHS is intentional: glob-match the scope
                        # shellcheck disable=SC2053
                        if { [[ "$g" == */ ]] && [[ "$p" == "$g"* ]]; } || [[ "$p" == $g ]]; then
                            printf '%s\n' "$p"; break
                        fi
                    done
                done <<< "$changed"
            } )
        else
            keyed="$changed"
        fi
        local key
        key=$( {
            printf 'base %s\nconf %s\n' "$base" "$conf_fp"
            { printf '%s\n' "$suite"; printf '%s\n' "$keyed"; } | grep -v '^$' | LC_ALL=C sort -u \
                | while IFS= read -r p; do printf '%s\t%s\n' "${c[$p]:-missing}" "$p"; done
        } | git hash-object --stdin 2>/dev/null) || return 1
        _test_input_is_blob "$key" || return 1
        printf '%s\t%s\n' "$key" "$suite"
    done
}

# _test_input_is_blob <id> — a full SHA-1 or SHA-256 object id.
_test_input_is_blob() {
    [[ "$1" =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ ]]
}


# ═══════════════════════════════════════════════════════════════════════════
# cmd_config — front door for the two durable opt-in seams (finding wv-e754b0)
# ═══════════════════════════════════════════════════════════════════════════
# Users should never have to memorise an env-var name or a config-file path:
#   - Global knobs (WV_CALL_LOG, ...) -> $WV_CONFIG_DIR/config.env, sourced by
#     wv-config.sh on EVERY CLI + hook invocation (survives reboot; no env
#     inheritance dependency — resolves the session-analysis split-brain).
#   - Repo gate policy (test_gate) -> $WEAVE_DIR/quality.conf [thresholds],
#     loaded into the tmpfs policy_thresholds table by _load_quality_config.
#     A raw sqlite3 UPDATE is session-only (tmpfs, not in state.sql); the
#     [thresholds] section is the ONLY durable path.

_config_env_file() { echo "${WV_CONFIG_DIR:-$HOME/.config/weave}/config.env"; }

# _config_env_set KEY VALUE — upsert KEY="VALUE" in config.env (deduped, quoted).
_config_env_set() {
    local key="$1" val="$2" file tmp
    if ! [[ "$key" =~ ^WV_[A-Z0-9_]+$ ]]; then
        echo "wv config: invalid key '$key' (expected WV_[A-Z0-9_]+)" >&2
        return 1
    fi
    file=$(_config_env_file)
    if ! mkdir -p "$(dirname "$file")"; then
        echo "wv config: cannot create config directory $(dirname "$file")" >&2
        return 1
    fi
    if ! tmp=$(mktemp); then
        echo "wv config: cannot create temporary config file" >&2
        return 1
    fi
    {
        echo "# Weave global knobs — sourced by wv on every invocation (CLI + hooks)."
        echo "# Managed by 'wv config set/enable'."
    } > "$tmp" || { echo "wv config: cannot write temporary config file" >&2; rm -f "$tmp"; return 1; }
    # Carry forward existing assignments except the key being set (and drop old comments).
    if [ -f "$file" ]; then
        grep -vE '^[[:space:]]*#' "$file" 2>/dev/null | grep -vE -- "^[[:space:]]*${key}=" >> "$tmp" || true
    fi
    echo "${key}=\"${val}\"" >> "$tmp" || { echo "wv config: cannot write temporary config file" >&2; rm -f "$tmp"; return 1; }
    if ! mv "$tmp" "$file"; then
        echo "wv config: cannot update $file" >&2
        rm -f "$tmp"
        return 1
    fi
    return 0
}

# _config_env_unset KEY — remove a KEY assignment from config.env.
_config_env_unset() {
    local key="$1" file tmp
    file=$(_config_env_file)
    [ -f "$file" ] || return 0
    if ! tmp=$(mktemp); then
        echo "wv config: cannot create temporary config file" >&2
        return 1
    fi
    grep -vE -- "^[[:space:]]*${key}=" "$file" > "$tmp" 2>/dev/null || true
    if ! mv "$tmp" "$file"; then
        echo "wv config: cannot update $file" >&2
        rm -f "$tmp"
        return 1
    fi
    return 0
}

# _config_set_threshold KEY VALUE — upsert KEY = VALUE under [thresholds] in
# the repo's quality.conf (creates the section/file as needed). Durable seam.
_config_set_threshold() {
    local key="$1" val="$2" file="${WEAVE_DIR:-}/quality.conf"
    if [ -z "${WEAVE_DIR:-}" ]; then
        echo "wv config: not inside a Weave repo (no .weave dir) — gate policy is repo-scoped" >&2
        return 1
    fi
    mkdir -p "$WEAVE_DIR"
    python3 - "$file" "$key" "$val" <<'PY'
import os, re, sys
path, key, val = sys.argv[1], sys.argv[2], sys.argv[3]
lines = open(path, encoding="utf-8").read().splitlines() if os.path.exists(path) else []
out, in_thr, seen_thr, done = [], False, False, False
for line in lines:
    m = re.match(r'^\[([a-z_]+)\]', line.strip())
    if m:
        if in_thr and not done:
            out.append(f"{key} = {val}"); done = True
        in_thr = (m.group(1) == "thresholds")
        seen_thr = seen_thr or in_thr
        out.append(line); continue
    if in_thr and re.match(rf'^\s*{re.escape(key)}\s*=', line):
        if not done:
            out.append(f"{key} = {val}"); done = True
        continue
    out.append(line)
if in_thr and not done:
    out.append(f"{key} = {val}"); done = True
if not seen_thr:
    if out and out[-1].strip():
        out.append("")
    out += ["[thresholds]", f"{key} = {val}"]
open(path, "w", encoding="utf-8").write("\n".join(out) + "\n")
PY
}

_config_enable_session_analysis() {
    local path="${WV_CALL_LOG_DEFAULT:-$HOME/.local/share/weave/wv_calls.jsonl}"
    mkdir -p "$(dirname "$path")"
    _config_env_set WV_CALL_LOG "$path" || return 1
    echo -e "${GREEN}✓${NC} session-analysis enabled"
    echo "  call log: $path"
    echo "  config:   $(_config_env_file)"
    echo "  Takes effect next wv invocation (CLI + hooks). Read: wv analyze sessions --call-stats"
    return 0
}

# _scaffold_test_map — write a commented starter .weave/test-map.conf when absent.
# Detects the repo stack (Python/Rust/Node/shell) and emits language-specific
# examples. No-op if test-map.conf already exists. Never auto-enforced — the user
# must edit and uncomment entries before the gate classifies any file.
_scaffold_test_map() {
    local tmap="${WEAVE_DIR}/test-map.conf"
    [ -f "$tmap" ] && return 0

    local repo_root; repo_root=$(dirname "$WEAVE_DIR")
    # Header common to all stacks
    local body
    # shellcheck disable=SC2016  # template text written into a generated test-map; its $(...) is for that file
    body='# .weave/test-map.conf — source file to test suite mapping
# Format ([map] section, INI-style):
#   source_file = suite [suite ...]
# source_file: path relative to repo root. Three key forms (most specific wins):
#   exact      src/app/models.py = suite      single file
#   glob       src/**/*.py       = suite      shell glob (matches files in subdirs)
#   prefix     src/              = suite       any file under a directory (trailing /)
# suite:       path to a runnable shell script relative to repo root
#
# A `* = suite` line, or suites listed under a [default] section, run when no
# other key matches a file — so the gate fails *safe* (runs a broad suite)
# instead of *open* (runs nothing). Per-file precedence:
#   union(exact, matching glob/prefix) > naming heuristic > [default].
# Unioning explicit matches means a specific row cannot remove a broader suite.
# A file matching nothing (and no [default]) makes the pre-commit gate inert
# for it and now prints a one-line notice rather than passing silently.
#
# Uncomment and adapt the entries below.

[map]
'
    local added=0

    if [ -f "$repo_root/pyproject.toml" ] || [ -f "$repo_root/setup.cfg" ] || [ -f "$repo_root/setup.py" ]; then
        added=1
        # shellcheck disable=SC2016  # template text written into a generated test-map; its $(...) is for that file
        body+='# Python (pyproject.toml / setup.cfg detected)
# Create a wrapper that sets up the env and runs pytest, e.g. scripts/run-tests.sh:
#   #!/usr/bin/env bash
#   set -e; cd "$(git rev-parse --show-toplevel)" && python -m pytest tests
# Then map the whole source tree with one prefix (or glob) line:
# src/         = scripts/run-tests.sh
# src/**/*.py  = scripts/run-tests.sh
# Or set a fail-safe default for anything unmapped:
# *            = scripts/run-tests.sh

'
    fi

    if [ -f "$repo_root/Cargo.toml" ]; then
        added=1
        # shellcheck disable=SC2016  # template text written into a generated test-map; its $(...) is for that file
        body+='# Rust (Cargo.toml detected)
# Create a wrapper, e.g. scripts/run-tests.sh:
#   #!/usr/bin/env bash
#   set -e; cd "$(git rev-parse --show-toplevel)" && cargo test
# Then map source files:
# src/lib.rs   = scripts/run-tests.sh
# src/main.rs  = scripts/run-tests.sh

'
    fi

    if [ -f "$repo_root/package.json" ]; then
        added=1
        # shellcheck disable=SC2016  # template text written into a generated test-map; its $(...) is for that file
        body+='# Node.js (package.json detected)
# Create a wrapper, e.g. scripts/run-tests.sh:
#   #!/usr/bin/env bash
#   set -e; cd "$(git rev-parse --show-toplevel)" && npm test
# Then map source files:
# src/index.js = scripts/run-tests.sh
# src/app.ts   = scripts/run-tests.sh

'
    fi

    if [ -f "$repo_root/Makefile" ]; then
        added=1
        if grep -qE '^test[[:space:]]*:' "$repo_root/Makefile" 2>/dev/null; then
            body+='# Shell / Makefile (test target detected)
# Map each source script to its test counterpart:
# scripts/my-cmd.sh = tests/test-my-cmd.sh

'
        else
            body+='# Makefile detected — map shell scripts to their test files:
# scripts/my-cmd.sh = tests/test-my-cmd.sh

'
        fi
    fi

    if [ "$added" = "0" ]; then
        body+='# Example: map a source file to its test script
# scripts/my-command.sh = tests/test-my-command.sh

'
    fi

    printf '%s' "$body" > "$tmap"
    echo -e "  ${GREEN}✓${NC} scaffolded ${WEAVE_DIR}/test-map.conf — edit to match your project layout"
    echo "     see: wv guide --topic=verification"
}

_config_enable_test_gate() {
    local mode_val=1 label="warn"
    case "${1:-warn}" in
        warn|1)        mode_val=1; label="warn (advisory)" ;;
        block|2|--block) mode_val=2; label="block (hard)" ;;
        off|0)         mode_val=0; label="off" ;;
        *) echo "wv config: test-gate mode must be warn|block|off" >&2; return 1 ;;
    esac
    _config_set_threshold test_gate "$mode_val" || return 1
    _load_quality_config 2>/dev/null || true
    echo -e "${GREEN}✓${NC} verification gate set to ${label} (test_gate=${mode_val})"
    echo "  durable in: ${WEAVE_DIR}/quality.conf [thresholds]  (commit it to share the policy)"
    if [ "$mode_val" != "0" ]; then
        _scaffold_test_map
    fi
    return 0
}

# _config_key_source KEY — print the file that provides the effective value for KEY,
# or "(builtin default)" if not set in any layer. Checks config.env (global knobs)
# then quality.conf [thresholds] (repo gate). Used by --show-origin.
_config_key_source() {
    local key="$1"
    local env_file; env_file=$(_config_env_file)
    if grep -qE -- "^[[:space:]]*${key}=" "$env_file" 2>/dev/null; then
        echo "$env_file"; return 0
    fi
    if [ -n "${WEAVE_DIR:-}" ] && grep -qE -- "^[[:space:]]*${key}[[:space:]]*=" "${WEAVE_DIR}/quality.conf" 2>/dev/null; then
        echo "${WEAVE_DIR}/quality.conf"; return 0
    fi
    echo "builtin default"
}

_config_list() {
    local show_origin=0
    [ "${1:-}" = "--show-origin" ] && show_origin=1
    local file; file=$(_config_env_file)
    echo "Global knobs ($file):"
    if [ -f "$file" ] && grep -qvE '^[[:space:]]*(#|$)' "$file" 2>/dev/null; then
        if [ "$show_origin" = "1" ]; then
            grep -vE '^[[:space:]]*(#|$)' "$file" | sed "s|^|  |;s|\$|    ($file)|"
        else
            grep -vE '^[[:space:]]*(#|$)' "$file" | sed 's/^/  /'
        fi
    else
        echo "  (none set)"
    fi
    echo ""
    local origin_env=""; [ "$show_origin" = "1" ] && origin_env="    ($file)"
    if [ -n "${WV_CALL_LOG:-}" ]; then
        echo -e "session-analysis: ${GREEN}enabled${NC} -> ${WV_CALL_LOG}${origin_env}"
    else
        echo "session-analysis: disabled  (enable: wv config enable session-analysis)"
    fi
    local _suite_log="${WV_SUITE_LOG:-${WV_SUITE_LOG_DEFAULT:-$HOME/.local/share/weave/suite_runs.jsonl}}"
    local suite_src=""; [ "$show_origin" = "1" ] && { [ -n "${WV_SUITE_LOG:-}" ] && suite_src="    ($file)" || suite_src="    (builtin default)"; }
    if [ -n "${WV_SUITE_LOG:-}" ]; then
        echo -e "suite-history:    ${GREEN}always on${NC} -> ${_suite_log} (custom: WV_SUITE_LOG)${suite_src}"
    else
        echo "suite-history:    always on -> ${_suite_log}  (override: wv config set WV_SUITE_LOG <path>)${suite_src}"
    fi
    if [ -n "${WEAVE_DIR:-}" ]; then
        local tg quality_file="${WEAVE_DIR}/quality.conf"
        tg=$(sqlite3 "$WV_DB" "SELECT value FROM policy_thresholds WHERE key='test_gate';" 2>/dev/null)
        local gate_src=""
        if [ "$show_origin" = "1" ]; then
            if grep -qE '^[[:space:]]*test_gate[[:space:]]*=' "$quality_file" 2>/dev/null; then
                gate_src="    ($quality_file)"
            else
                gate_src="    (builtin default)"
            fi
        fi
        echo "verification-gate: test_gate=${tg:-?} (0=off 1=warn 2=block) [repo: $WEAVE_DIR]${gate_src}"
        if [ "$show_origin" = "0" ]; then
            if grep -qE '^[[:space:]]*test_gate[[:space:]]*=' "$quality_file" 2>/dev/null; then
                echo "                   durable (set in .weave/quality.conf [thresholds])"
            elif [ "${tg:-0}" != "0" ]; then
                echo -e "                   ${YELLOW}session-only${NC} — not in quality.conf; resets on reboot"
            fi
        fi
    fi
    return 0
}

_config_help() {
    cat <<'EOF'
Usage: wv config <subcommand>

  list [--show-origin]         Show current global knobs + feature state
  get <KEY> [--show-origin]    Print the effective value of a knob (and its source layer)
  set <KEY> <VALUE>            Set a global knob (WV_*) in config.env
  unset <KEY>                  Remove a global knob from config.env
  enable session-analysis      Turn on wv call logging (durable, CLI + hooks)
  disable session-analysis     Turn it off
  enable test-gate [warn|block] Make the verification gate durable in quality.conf
  disable test-gate            Set test_gate=0 (durable)

Global knobs live in ~/.config/weave/config.env (override dir: WV_CONFIG_DIR).
The verification gate is repo-scoped (.weave/quality.conf [thresholds]).
--show-origin annotates each value with the config file that provides it.
EOF
    return 0
}

cmd_config() {
    local sub="${1:-list}"
    shift || true
    case "$sub" in
        list|show)
            # Only --show-origin is read; anything else was dropped (wv-016983).
            local _cfg_arg
            for _cfg_arg in "$@"; do
                [ "$_cfg_arg" = "--show-origin" ] || { _wv_reject_arg "config $sub" "$_cfg_arg"; return 1; }
            done
            _config_list "${1:-}" ;;
        get)
            if [ -z "${1:-}" ]; then echo "wv config get: need a KEY" >&2; return 1; fi
            local _gkey="$1"
            if [ "${2:-}" = "--show-origin" ]; then
                local _src; _src=$(_config_key_source "$_gkey")
                echo "${!_gkey:-}    ($_src)"
            else
                echo "${!_gkey:-}"
            fi ;;
        set)
            if [ -z "${1:-}" ] || [ -z "${2:-}" ]; then echo "wv config set: need KEY VALUE" >&2; return 1; fi
            _config_env_set "$1" "$2" || return $?
            echo -e "${GREEN}✓${NC} set $1 (effective next invocation)" ;;
        unset)
            if [ -z "${1:-}" ]; then echo "wv config unset: need a KEY" >&2; return 1; fi
            _config_env_unset "$1" || return $?
            echo -e "${GREEN}✓${NC} unset $1" ;;
        enable)
            case "${1:-}" in
                session-analysis) _config_enable_session_analysis ;;
                test-gate)        shift || true; _config_enable_test_gate "${1:-warn}" ;;
                *) echo "wv config enable: unknown feature '${1:-}' (session-analysis|test-gate)" >&2; return 1 ;;
            esac ;;
        disable)
            case "${1:-}" in
                session-analysis) _config_env_unset WV_CALL_LOG && echo -e "${GREEN}✓${NC} session-analysis disabled" ;;
                test-gate)        _config_enable_test_gate off ;;
                *) echo "wv config disable: unknown feature '${1:-}' (session-analysis|test-gate)" >&2; return 1 ;;
            esac ;;
        help|--help|-h) _config_help ;;
        *) echo "wv config: unknown subcommand '$sub'" >&2; _config_help >&2; return 1 ;;
    esac
}

# ── durable suite-run history (LL2) ─────────────────────────────────────────
# The tmpfs test_results table is current-state-only and wiped by `wv load`. This
# append-only JSONL log lives on disk so suite-run history (for measuring
# commit-time friction) survives wv load + reboot. The path is overridable via
# `wv config set WV_SUITE_LOG <path>`; default under the user data dir.
_suite_log_path() {
    echo "${WV_SUITE_LOG:-${WV_SUITE_LOG_DEFAULT:-$HOME/.local/share/weave/suite_runs.jsonl}}"
}

# _durable_log_writable: false for a test run (WV_CALL_SOURCE=test) that has not
# pointed the logs somewhere of its own. Suites that drive the commit hooks in
# throwaway repos were appending their runs to the user's durable history
# (repo "project" rows since May, and gate rows once wv-ffda33 added them).
# Writers only: readers such as wv analyze still read whatever path is set.
_durable_log_writable() {
    [ "${WV_CALL_SOURCE:-}" != "test" ] || [ -n "${WV_SUITE_LOG:-}" ] || [ -n "${WV_GATE_LOG:-}" ]
}

# _suite_log_append <suite> <files_csv> <exit> <duration_ms> <sha> [estimate_ms]
#                   [started_ms] [ended_ms] [clock]
# One JSONL line per suite RUN (not per file). Best-effort: a logging failure must
# never break a commit hook. jq -cn guarantees valid JSON + escaping, so a path
# containing a quote can neither corrupt the log nor inject a field. Records only
# repo-relative paths + outcome metadata — never file content, env, or secrets —
# and `repo` is a basename so no absolute $HOME/username path leaks (no PII).
_suite_log_append() {
    local suite="$1" files="$2" exit_code="$3" duration_ms="$4" sha="$5" estimate_ms="${6:-}"
    local started_ms="${7:-}" ended_ms="${8:-}" clock="${9:-}"
    _durable_log_writable || return 0
    local log_path; log_path=$(_suite_log_path)
    [ -n "$log_path" ] || return 0
    mkdir -p "$(dirname "$log_path")" 2>/dev/null || return 0
    # exit_code/duration_ms are pre-coerced to digits by the caller; default-guard
    # anyway so a stray value can never make --argjson abort the whole line.
    case "$exit_code" in ''|*[!0-9]*) exit_code=0 ;; esac
    case "$duration_ms" in ''|*[!0-9]*) duration_ms=0 ;; esac
    case "$estimate_ms" in ''|*[!0-9]*) estimate_ms=null ;; esac
    # started_ms/ended_ms (wv-4666cb): when the suite started and exited, epoch
    # ms, as the gate's worker read them. ts is when this line is written, which
    # for a gate is after its last suite ends. Unknown is absent, never 0.
    case "$started_ms" in ''|0|*[!0-9]*) started_ms=null ;; esac
    case "$ended_ms" in ''|0|*[!0-9]*) ended_ms=null ;; esac
    # clock (wv-b17a85): the clock duration_ms was measured on (wv-clock.sh).
    # Only monotonic leaves out a suspend; absent on rows from before it.
    _clock_kind_valid "$clock" || clock=""
    local repo=""
    [ -n "${REPO_ROOT:-}" ] && repo=$(basename "$REPO_ROOT")
    # phase/gate_id (wv-ffda33) come from the gate that ran the suite, so one
    # gate's runs can be grouped exactly instead of guessed from a shared sha.
    jq -cn \
        --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --arg repo "$repo" \
        --arg suite "$suite" \
        --arg files "$files" \
        --argjson exit "$exit_code" \
        --argjson duration_ms "$duration_ms" \
        --arg sha "$sha" \
        --arg phase "${WV_GATE_PHASE:-}" \
        --arg gate_id "${WV_GATE_ID:-}" \
        --arg execution_mode "${WV_GATE_EXECUTION_MODE:-}" \
        --argjson estimate_ms "$estimate_ms" \
        --argjson started_ms "$started_ms" \
        --argjson ended_ms "$ended_ms" \
        --arg clock "$clock" \
        '{ts:$ts, repo:$repo, suite:$suite, files:$files, exit:$exit, duration_ms:$duration_ms, sha:$sha}
         + (if $clock != "" then {clock:$clock} else {} end)
         + (if $phase != "" then {phase:$phase} else {} end)
         + (if $gate_id != "" then {gate_id:$gate_id} else {} end)
         + (if $execution_mode != "" then {execution_mode:$execution_mode} else {} end)
         + (if $estimate_ms != null then {estimate_ms:$estimate_ms} else {} end)
         + (if $started_ms != null then {started_ms:$started_ms} else {} end)
         + (if $ended_ms != null then {ended_ms:$ended_ms} else {} end)' \
        >> "$log_path" 2>/dev/null || true
}

# _clock_kind_valid <kind> — one of the kinds wv-clock.sh declares.
_clock_kind_valid() {
    case "${1:-}" in monotonic|boottime|wall|unknown) return 0 ;; *) return 1 ;; esac
}

# _gate_log_path: the per-gate log sits beside the suite log, so every isolation
# that redirects WV_SUITE_LOG (tests set it) redirects this too (wv-ffda33).
_gate_log_path() {
    local suite_log; suite_log=$(_suite_log_path)
    echo "${WV_GATE_LOG:-$(dirname "$suite_log")/gate_runs.jsonl}"
}

# _gate_log_append <phase> <gate_id> <exit> <duration_ms> <estimate_ms> <suites_csv> <sha> [started_ms]
#                  [suite_modes] [lanes_json] [lanes_ms] [lanes_started_ms]
#                  [pressure_start] [pressure_end] [clock]
# One JSONL line per gate INVOCATION: its wall time, what it ran, what it
# expected to take, and how it ended. Best-effort like the suite log.
# started_ms (wv-4666cb) is the gate's start in epoch ms, the origin its suites'
# ended_ms are measured from; absent where unknown. suite_modes ("suite=mode,...")
# becomes provisioning: {suite: frozen|checkout}, each selected route's mode,
# which wv analyze gates and wv doctor count (transition rule 5, wv-0ee3f4).
# lanes_json (wv-3dbc11) is the candidate lanes' [{path, reused, ms, jobs, rc}];
# with lanes_ms (their wall time) and lanes_started_ms it makes the time after
# the protected pass attributable: protected_ms = lanes_started_ms - started_ms.
# A gate that ran no lane carries none of these fields.
# pressure_start and pressure_end (wv-58b10e) are "cpu,io": the host's
# cumulative PSI some-stall totals in microseconds when the gate started and
# ended (gate_pressure_totals, wv-gate-pool.sh). Together they become pressure: {cpu_some_ms, io_some_ms, cpu_some_share, io_some_share},
# the time some task stalled on CPU or IO during the gate and its share of the
# gate's wall time. The gate's own parallel suites contend too, so a share is
# host load including the gate, not interference alone. Absent where either
# reading is missing or the counters went backwards.
# clock (wv-b17a85) is the clock duration_ms and lanes_ms were measured on.
_gate_log_append() {
    local phase="$1" gate_id="$2" exit_code="$3" duration_ms="$4" estimate_ms="$5" suites="$6" sha="$7"
    local started_ms="${8:-}" suite_modes="${9:-}" lanes="${10:-}" lanes_ms="${11:-}" lanes_started_ms="${12:-}"
    local pressure_start="${13:-}" pressure_end="${14:-}" pressure=null clock="${15:-}"
    _durable_log_writable || return 0
    local log_path; log_path=$(_gate_log_path)
    mkdir -p "$(dirname "$log_path")" 2>/dev/null || return 0
    case "$exit_code" in ''|*[!0-9]*) exit_code=1 ;; esac
    case "$duration_ms" in ''|*[!0-9]*) duration_ms=0 ;; esac
    case "$estimate_ms" in ''|*[!0-9]*) estimate_ms=null ;; esac
    case "$started_ms" in ''|0|*[!0-9]*) started_ms=null ;; esac
    case "$lanes_ms" in ''|*[!0-9]*) lanes_ms=null ;; esac
    case "$lanes_started_ms" in ''|0|*[!0-9]*) lanes_started_ms=null ;; esac
    jq -se 'length == 1 and (.[0] | type == "array" and length > 0)' >/dev/null 2>&1 <<< "$lanes" || lanes=null
    _clock_kind_valid "$clock" || clock=""
    if [[ "$pressure_start" =~ ^[0-9]+,[0-9]+$ ]] && [[ "$pressure_end" =~ ^[0-9]+,[0-9]+$ ]]; then
        pressure=$(jq -cn --arg s "$pressure_start" --arg e "$pressure_end" --argjson d "$duration_ms" '
            ($s | split(",") | map(tonumber)) as $a | ($e | split(",") | map(tonumber)) as $b
            | if $b[0] < $a[0] or $b[1] < $a[1] then null
              else (($b[0] - $a[0]) / 1000 | floor) as $c | (($b[1] - $a[1]) / 1000 | floor) as $i
                   | {cpu_some_ms:$c, io_some_ms:$i}
                     + (if $d > 0 then {cpu_some_share:($c / $d * 1000 | round / 1000),
                                        io_some_share:($i / $d * 1000 | round / 1000)} else {} end)
              end') || pressure=null
    fi
    local repo=""
    [ -n "${REPO_ROOT:-}" ] && repo=$(basename "$REPO_ROOT")
    jq -cn \
        --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --arg repo "$repo" --arg phase "$phase" --arg gate_id "$gate_id" \
        --arg execution_mode "${WV_GATE_EXECUTION_MODE:-}" \
        --argjson exit "$exit_code" --argjson duration_ms "$duration_ms" \
        --argjson estimate_ms "$estimate_ms" --arg suites "$suites" --arg sha "$sha" \
        --argjson started_ms "$started_ms" --arg suite_modes "$suite_modes" \
        --argjson lanes "$lanes" --argjson lanes_ms "$lanes_ms" --argjson lanes_started_ms "$lanes_started_ms" \
        --argjson pressure "$pressure" --arg clock "$clock" \
        '{ts:$ts, repo:$repo, phase:$phase, gate_id:$gate_id, exit:$exit, duration_ms:$duration_ms,
          estimate_ms:$estimate_ms, suites:($suites | split(",") | map(select(. != ""))), sha:$sha}
         + (if $clock != "" then {clock:$clock} else {} end)
         + (if $execution_mode != "" then {execution_mode:$execution_mode} else {} end)
         + (if $started_ms != null then {started_ms:$started_ms} else {} end)
         + ($suite_modes | split(",") | map(select(test("^[^=]+=(frozen|checkout)$")) | split("="))
            | if length > 0 then {provisioning: (map({key: .[0], value: .[1]}) | from_entries)} else {} end)
         + (if $lanes != null then {lanes:$lanes} else {} end)
         + (if $lanes != null and $lanes_ms != null then {lanes_ms:$lanes_ms} else {} end)
         + (if $lanes != null and $lanes_started_ms != null then {lanes_started_ms:$lanes_started_ms}
              + (if $started_ms != null and $lanes_started_ms >= $started_ms
                 then {protected_ms:($lanes_started_ms - $started_ms)} else {} end)
            else {} end)
         + (if $pressure != null then {pressure:$pressure} else {} end)' \
        >> "$log_path" 2>/dev/null || true
}

# cmd_test_record <suite> [--files=a,b] [--exit=N] [--commit=SHA] [--duration=MS]
# Records a suite outcome in the test_results ledger (producer shim). Writes ONE
# row per --files entry, keyed (suite, path), with that file's fingerprint and the
# shared exit code — so the consumer can ask per-file "is this content fresh?".
# Idempotent per (suite, path): a re-run overwrites the prior row (latest wins).
# With no --files, records a single sentinel row (path='') under the HEAD sha.
# --duration=MS is the suite run's cost (LL1); the suite ran once, so
# every per-file row from that run carries the same shared duration. Omitted or
# non-numeric coerces to 0 (the "unmeasured" sentinel, matching the prior baseline).
# --clock=KIND names the clock it was measured on (monotonic | boottime | wall |
# unknown, wv-clock.sh); the durable log carries it and estimates read only
# monotonic rows (wv-b17a85). Any other value is dropped, never guessed.
# Side effect (LL2): also appends ONE durable JSONL history line per run to the
# on-disk suite log (_suite_log_append) so run history survives `wv load`/reboot,
# unlike the tmpfs table. Never fails the caller — a recording error must not break
# a commit hook.
cmd_test_record() {
    local suite="${1:-}"
    shift || true
    # Mode is supplied by the recorder, never inherited from a parent gate.
    # Nested tests that record manual observations retain their own semantics.
    local WV_GATE_EXECUTION_MODE=""
    local files="" exit_code="0" commit_sha="" duration_ms="0" estimate_ms=""
    local gate_mode=false gate_phase="${WV_GATE_PHASE:-}" gate_id="${WV_GATE_ID:-}" gate_suites="" gate_suite_modes=""
    local start_fps="" start_given=false inputs_key="" started_ms="" ended_ms="" snapshot_plan=""
    local gate_lanes="" gate_lanes_ms="" gate_lanes_started_ms="" gate_pressure_start="" gate_pressure_end="" clock=""
    local arg
    for arg in "$@"; do
        case "$arg" in
            --files=*)    files="${arg#--files=}" ;;
            --started-ms=*) started_ms="${arg#--started-ms=}" ;;
            --ended-ms=*)   ended_ms="${arg#--ended-ms=}" ;;
            --inputs-key=*) inputs_key="${arg#--inputs-key=}" ;;
            --snapshot-plan=*) snapshot_plan="${arg#--snapshot-plan=}" ;;
            --execution-mode=*) WV_GATE_EXECUTION_MODE="${arg#--execution-mode=}" ;;
            --start-fingerprints=*) start_fps="${arg#--start-fingerprints=}"; start_given=true ;;
            --exit=*)     exit_code="${arg#--exit=}" ;;
            --commit=*)   commit_sha="${arg#--commit=}" ;;
            --duration=*) duration_ms="${arg#--duration=}" ;;
            --estimate=*) estimate_ms="${arg#--estimate=}" ;;
            --clock=*)    clock="${arg#--clock=}" ;;
            --gate)       gate_mode=true ;;
            --phase=*)    gate_phase="${arg#--phase=}" ;;
            --gate-id=*)  gate_id="${arg#--gate-id=}" ;;
            --suites=*)   gate_suites="${arg#--suites=}" ;;
            --suite-modes=*) gate_suite_modes="${arg#--suite-modes=}" ;;
            --lanes=*)    gate_lanes="${arg#--lanes=}" ;;
            --lanes-ms=*) gate_lanes_ms="${arg#--lanes-ms=}" ;;
            --lanes-started-ms=*) gate_lanes_started_ms="${arg#--lanes-started-ms=}" ;;
            --pressure-start=*) gate_pressure_start="${arg#--pressure-start=}" ;;
            --pressure-end=*) gate_pressure_end="${arg#--pressure-end=}" ;;
            *) ;;
        esac
    done

    if [ -z "$suite" ]; then
        echo "Usage: wv test-record <suite> [--files=a,b] [--exit=N] [--commit=SHA] [--duration=MS] [--estimate=MS] [--started-ms=EPOCH_MS] [--ended-ms=EPOCH_MS] [--clock=KIND]" >&2
        echo "       wv test-record gate --gate --phase=P --gate-id=ID --exit=N --duration=MS [--estimate=MS] [--suites=a,b] [--started-ms=EPOCH_MS] [--lanes=JSON --lanes-ms=MS --lanes-started-ms=EPOCH_MS] [--pressure-start=CPU_US,IO_US --pressure-end=CPU_US,IO_US] [--clock=KIND]" >&2
        return 1
    fi

    # --gate records one gate invocation in the gate log and nothing else: a gate
    # is not a suite, so it must not add a ledger row or a suite-log line.
    case "$WV_GATE_EXECUTION_MODE" in
        ''|frozen|checkout) ;;
        mixed) [ "$gate_mode" = true ] || { echo "wv test-record: invalid execution mode" >&2; return 1; } ;;
        *) echo "wv test-record: invalid execution mode" >&2; return 1 ;;
    esac
    if [ "$gate_mode" = true ]; then
        [ -z "$commit_sha" ] && commit_sha=$(git rev-parse --short HEAD 2>/dev/null || echo "")
        _gate_log_append "${gate_phase:-manual}" "$gate_id" "$exit_code" "$duration_ms" \
            "$estimate_ms" "$gate_suites" "$commit_sha" "$started_ms" "$gate_suite_modes" \
            "$gate_lanes" "$gate_lanes_ms" "$gate_lanes_started_ms" "$gate_pressure_start" "$gate_pressure_end" "$clock"
        return 0
    fi

    # Coerce a non-numeric exit code to 1 (treat as failure) rather than corrupt the row.
    case "$exit_code" in
        ''|*[!0-9]*) exit_code=1 ;;
    esac
    # Coerce a non-numeric/empty duration to 0 rather than corrupt the row (cost-blind
    # is the prior baseline, so 0 is the safe "unmeasured" sentinel).
    case "$duration_ms" in
        ''|*[!0-9]*) duration_ms=0 ;;
    esac

    [ -z "$commit_sha" ] && commit_sha=$(git rev-parse --short HEAD 2>/dev/null || echo "")
    local suite_esc commit_esc
    suite_esc=$(sql_escape "$suite")
    commit_esc=$(sql_escape "$commit_sha")

    # Durable history: one append-only JSONL line per run, survives wv load (LL2).
    # The tmpfs upserts below remain the gate's current-state view.
    _suite_log_append "$suite" "$files" "$exit_code" "$duration_ms" "$commit_sha" "$estimate_ms" \
        "$started_ms" "$ended_ms" "$clock"
    # Mutable checkout tools are not captured by any content key. Keep the
    # measured outcome, but never certify per-file, legacy or frozen readiness.
    [ "$WV_GATE_EXECUTION_MODE" != checkout ] || return 0

    # --inputs-key=K: the suite's input key when it started (wv test-status
    # --inputs), recorded at path '@inputs:K' for the gate's reuse check
    # (wv-cb4913). One row per key, latest outcome wins, so returning to bytes
    # that already passed (a reverted fix) is recognised; the newest
    # _TEST_INPUT_ROWS per suite are kept. The caller passes changed-during-run
    # when the key moved under the suite: that run describes no key, so it
    # records none.
    if [ -n "$inputs_key" ] && [ "$inputs_key" != changed-during-run ]; then
        db_query "INSERT OR REPLACE INTO test_results(suite, path, fingerprint, exit_code, ran_at, commit_sha, duration_ms)
                  VALUES ('$suite_esc', '@inputs:$(sql_escape "$inputs_key")', '$(sql_escape "$inputs_key")', $exit_code, datetime('now'), '$commit_esc', $duration_ms);
                  DELETE FROM test_results WHERE suite='$suite_esc' AND path LIKE '@inputs:%'
                      AND rowid NOT IN (SELECT rowid FROM test_results WHERE suite='$suite_esc' AND path LIKE '@inputs:%'
                                        ORDER BY ran_at DESC, rowid DESC LIMIT $_TEST_INPUT_ROWS);" \
                  >/dev/null 2>&1 || true
    fi

    # Advisory observation only: its namespace is deliberately outside
    # @inputs, so no reuse reader can admit it. Bind it to the already-frozen
    # plan rather than reading live HEAD after a potentially lengthy run.
    if [ -n "$snapshot_plan" ]; then
        local observation
        observation=$(jq -sec --arg s "$suite" --arg k "$inputs_key" 'if length == 1 then .[0] else error("expected one JSON value") end |
            . as $p | .suites[$s] as $s
            | select($s.identity.context == "prepush" and $s.key == $k
                and ($k | test("^snapshot-v1:[0-9a-f]{64}$")))
            | {tree: $p.tree, base: $p.base, input_base: $s.identity.input_base, key: $k}
            ' "$snapshot_plan" 2>/dev/null) || observation=""
        if [ -n "$observation" ]; then
            db_query "INSERT OR REPLACE INTO test_results(suite, path, fingerprint, exit_code, ran_at, commit_sha, duration_ms)
                VALUES ('$suite_esc', '@snapshot-observation:prepush', '$(sql_escape "$observation")',
                    $exit_code, datetime('now'), '$commit_esc', $duration_ms);" >/dev/null 2>&1 || true
        fi
    fi

    if [ -z "$files" ]; then
        # Whole-suite run with no file set: one sentinel row keyed on HEAD.
        local head_fp
        head_fp=$(git rev-parse --short=16 HEAD 2>/dev/null || echo "nofiles")
        db_query "INSERT OR REPLACE INTO test_results(suite, path, fingerprint, exit_code, ran_at, commit_sha, duration_ms)
                  VALUES ('$suite_esc', '', '$(sql_escape "$head_fp")', $exit_code, datetime('now'), '$commit_esc', $duration_ms);" \
                  >/dev/null 2>&1 || true
        return 0
    fi

    # One row per file. printf '%s\n' guarantees a trailing newline so `read` does
    # not drop the last field.
    # --start-fingerprints=FILE holds the "<fp>\t<path>" lines `wv test-status
    # --fingerprints` printed before the suite started (wv-5da0e8). The result is
    # true only of that content: a file whose bytes now differ, or that the
    # snapshot lacks, changed during the run or was never captured, so its row
    # gets a fingerprint no content can match and reads as stale, never green.
    local f fp start_fp
    while IFS= read -r f; do
        [ -z "$f" ] && continue
        fp=$(_test_file_fingerprint "$f")
        if [ "$start_given" = true ]; then
            start_fp=$(awk -F'\t' -v p="$f" '$2 == p { print $1; exit }' "$start_fps" 2>/dev/null || true)
            if [ "$start_fp" != "$fp" ]; then
                echo "wv test-record: $f changed during the $suite run; not recorded as tested" >&2
                fp="changed-during-run"
            fi
        fi
        db_query "INSERT OR REPLACE INTO test_results(suite, path, fingerprint, exit_code, ran_at, commit_sha, duration_ms)
                  VALUES ('$suite_esc', '$(sql_escape "$f")', '$(sql_escape "$fp")', $exit_code, datetime('now'), '$commit_esc', $duration_ms);" \
                  >/dev/null 2>&1 || true
    done < <(printf '%s\n' "$files" | tr ',' '\n')
    return 0
}

# cmd_test_status <suite> --files=a,b [--staged] [--quiet]
#
# Read-only freshness predicate over the canonical test_results ledger. Exit 0
# only when EVERY named file has a row for the suite whose fingerprint matches
# the selected content and whose exit code is zero. Missing rows, failed rows,
# stale fingerprints, and an empty file set all return non-zero, so callers can
# safely degrade to running the real suite.
#
# --staged compares against index blobs and is the pre-commit form. Without it,
# the command compares the working tree, matching wv done's freshness consumer.
#
# wv test-status --fingerprints --files=a,b prints "<fp>\t<path>" per file, the
# working-tree fingerprint test-record would write. A gate takes it before its
# suites start and hands it to test-record --start-fingerprints (wv-5da0e8).
#
# wv test-status --inputs --suites=a,b [--staged] prints "<state>\t<key>\t<suite>"
# per suite: each suite's input key (_test_input_keys) and the state of the
# '@inputs:<key>' ledger row for it: green, red (the latest run on those exact
# inputs failed), stale (rows only for other inputs) or unknown. One call answers the whole gate's reuse
# question (wv-cb4913): the per-file form costs a process per file per suite.
cmd_test_status() {
    local suite="" files="" staged=false quiet=false fingerprints=false arg
    local inputs=false suites="" snapshot_plan=""
    for arg in "$@"; do
        case "$arg" in
            --files=*) files="${arg#--files=}" ;;
            --suites=*) suites="${arg#--suites=}" ;;
            --snapshot-plan=*) snapshot_plan="${arg#--snapshot-plan=}" ;;
            --inputs) inputs=true ;;
            --staged) staged=true ;;
            --quiet) quiet=true ;;
            --fingerprints) fingerprints=true ;;
            -*)
                echo "wv test-status: unknown option '$arg'" >&2
                return 2
                ;;
            *)
                if [ -n "$suite" ]; then
                    echo "wv test-status: unexpected argument '$arg'" >&2
                    return 2
                fi
                suite="$arg"
                ;;
        esac
    done

    if [ "$fingerprints" = true ] && [ -n "$files" ]; then
        local fp_file
        while IFS= read -r fp_file; do
            [ -z "$fp_file" ] && continue
            printf '%s\t%s\n' "$(_test_file_fingerprint "$fp_file")" "$fp_file"
        done < <(printf '%s\n' "$files" | tr ',' '\n')
        return 0
    fi

    if [ "$inputs" = true ]; then
        local suite_list=() keys rows mode=worktree
        IFS=',' read -ra suite_list <<< "$suites"
        if [ -n "$suite" ] || [ "${#suite_list[@]}" -eq 0 ]; then
            echo "Usage: wv test-status --inputs --suites=a,b [--staged]" >&2
            return 2
        fi
        [ "$staged" = true ] && mode=staged
        if [ -n "$snapshot_plan" ]; then
            keys=$(jq -ser --arg suites "$suites" 'if length == 1 then .[0] else error("expected one JSON value") end |
                .suites as $plan | $suites | split(",")[] as $suite
                | $plan[$suite].key as $key
                | if ($key | type == "string" and test("^snapshot-v1:[0-9a-f]{64}$"))
                  then [$key, $suite] | @tsv else error("missing frozen suite key") end
                ' "$snapshot_plan") || return 1
        else
            keys=$(_test_input_keys "$mode" "${suite_list[@]}") || return 1
        fi
        [ -n "$keys" ] || return 1
        rows=$(db_query "SELECT suite || char(9) || fingerprint || char(9) || exit_code
                         FROM test_results WHERE path LIKE '@inputs:%';" 2>/dev/null || true)
        awk -F'\t' 'NR == FNR { if (NF == 3) { seen[$1] = 1; ex[$1 "\t" $2] = $3 } next }
            NF == 2 {
                st = "unknown"
                if (($2 "\t" $1) in ex) st = (ex[$2 "\t" $1] == "0") ? "green" : "red"
                else if ($2 in seen) st = "stale"
                print st "\t" $1 "\t" $2
            }' <(printf '%s\n' "$rows") - <<< "$keys"
        return 0
    fi

    if [ -z "$suite" ] || [ -z "$files" ]; then
        echo "Usage: wv test-status <suite> --files=a,b [--staged] [--quiet]" >&2
        echo "       wv test-status --fingerprints --files=a,b" >&2
        echo "       wv test-status --inputs --suites=a,b [--staged]" >&2
        return 2
    fi

    local suite_esc overall="green" processed=0 f path_esc cur_fp row row_fp row_exit state
    suite_esc=$(sql_escape "$suite")
    while IFS= read -r f; do
        [ -z "$f" ] && continue
        processed=$((processed + 1))
        path_esc=$(sql_escape "$f")
        if [ "$staged" = true ]; then
            cur_fp=$(_test_file_fingerprint_staged "$f")
        else
            cur_fp=$(_test_file_fingerprint "$f")
        fi
        row=$(db_query "SELECT fingerprint || char(31) || exit_code
                        FROM test_results
                        WHERE suite='$suite_esc' AND path='$path_esc'
                        LIMIT 1;" 2>/dev/null || true)
        if [ -z "$row" ]; then
            state="unknown"
        else
            row_fp="${row%%$'\x1f'*}"
            row_exit="${row#*$'\x1f'}"
            if [ "$row_fp" != "$cur_fp" ]; then
                state="stale"
            elif [ "$row_exit" = "0" ]; then
                state="green"
            else
                state="red"
            fi
        fi
        [ "$state" = "green" ] || overall="$state"
        [ "$quiet" = true ] || printf '%s\t%s\n' "$state" "$f"
    done < <(printf '%s\n' "$files" | tr ',' '\n')

    [ "$processed" -gt 0 ] || return 2
    [ "$overall" = "green" ]
}
