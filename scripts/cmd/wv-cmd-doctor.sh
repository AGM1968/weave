#!/bin/bash
# wv-cmd-doctor.sh — installation and graph diagnostics
#
# Commands: doctor, pattern-audit
# Sourced by: wv entry point (autoloaded on first use)
# Dependencies: wv-config.sh, wv-db.sh, wv-validate.sh, wv-cmd-orient.sh (wv provenance helpers)
#
# Moved unchanged from wv-cmd-ops.sh (wv-71933b, the wv-c153c4 split) so a change
# here routes only to the suites that exercise doctor and pattern-audit.

# ═══════════════════════════════════════════════════════════════════════════
# cmd_doctor — Installation health check
# ═══════════════════════════════════════════════════════════════════════════

# Shared state for _doctor_record (avoids nested function dynamic scoping)
_dr_pass=0 _dr_fail=0 _dr_warn=0 _dr_total=0 _dr_results="" _dr_format="text"

# Which installed git hooks are Weave's: one definition with the installers
# (wv-3a7368), so doctor never calls a hook custom that they refresh as Weave's.
# shellcheck source=scripts/lib/wv-git-hook-signature.sh
source "${WV_LIB_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/lib/wv-git-hook-signature.sh"

# Count durable Codex memory-pipeline rows scoped to THIS repo. Codex's
# memories_*.sqlite stage1_outputs is the durable-memory analog to Claude's
# memory/*.md (thread/state/rollout DBs are session evidence, not durable
# memory, and are deliberately excluded — same scope as the Claude *.md-only
# check). Conservative: only count rows attributable via a cwd column; schemas
# without repo identity are skipped rather than guessed at.
_doctor_codex_memory_rows() {
    local repo_root="$1"
    local codex_dir="$HOME/.codex" db cols n total=0
    [ -d "$codex_dir" ] || { echo 0; return 0; }
    while IFS= read -r db; do
        [ -s "$db" ] || continue
        sqlite3 "$db" "SELECT name FROM sqlite_master WHERE type='table' AND name='stage1_outputs';" 2>/dev/null | grep -qx stage1_outputs || continue
        cols=$(sqlite3 "$db" "PRAGMA table_info('stage1_outputs');" 2>/dev/null | awk -F'|' '{print $2}' | tr '\n' ' ')
        case " $cols " in
            *" cwd "*)
                n=$(sqlite3 "$db" "SELECT COUNT(*) FROM stage1_outputs WHERE cwd='$(sql_escape "$repo_root")';" 2>/dev/null || echo 0)
                ;;
            *)
                n=0
                ;;
        esac
        [ -n "$n" ] && total=$((total + n))
    done < <(find "$codex_dir" -maxdepth 1 -type f -name "memories_*.sqlite" -print 2>/dev/null | sort)
    echo "$total"
}

# _doctor_memory_kept <harness> <label> — the store is kept outside the graph
# by a recorded choice; appends it to the caller's choices (wv-27131a).
_doctor_memory_kept() {
    local why
    [ -n "${WEAVE_DIR:-}" ] || return 1
    why=$(wv_memory_outside_graph "$WEAVE_DIR" "$1" 2>/dev/null) || return 1
    choices+=("$2 kept outside the graph by choice (.weave/policy.conf): $why")
}

_doctor_memory_authority() {
    # Duplicate-authoritative-memory risk (PROPOSAL-wv-agent-memory-substrate S5,
    # generalized in F1/wv-4c1efd): durable harness memory for THIS repo that is
    # not represented in the graph is a dual-authority leak — the graph is the
    # authority, harness files/DBs are evidence/projections. Report-only.
    #
    # Per-harness durable-memory analog (sessions are excluded as evidence):
    #   Claude  : ~/.claude/projects/<slug>/memory/*.md  (content-hash match)
    #   Codex   : ~/.codex/memories_*.sqlite stage1_outputs rows for this repo
    #   Copilot : none — VS Code workspace storage is chat/session + index-cache
    #             evidence (proposal §VS Code Copilot), not a durable memory store.
    local root slug memdir
    root=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
    [ -z "$root" ] && return 0
    if [ ! -f "${WV_DB:-}" ]; then
        _doctor_record "memory authority" "pass" "no graph db for this repo"
        return 0
    fi

    local any_store=0
    local warnings=() problems=() choices=()

    # A repository may keep a harness's memory outside the graph by choice,
    # recorded with a reason in .weave/policy.conf [memory] (wv-27131a, ruling
    # D3 on wv-80fa17). The advisory then reports the choice, not an import.
    local kept_names="" policy_text policy_rc=0 name
    if [ -n "${WEAVE_DIR:-}" ]; then
        policy_text=$(wv_config_read "$WEAVE_DIR/policy.conf") || policy_rc=$?
        if [ "$policy_rc" -eq 0 ]; then
            kept_names=$(wv_policy_value "$policy_text" memory outside_graph)
            for name in ${kept_names//,/ }; do
                case "$name" in
                    claude|codex) ;;
                    *) problems+=(".weave/policy.conf [memory] outside_graph names '$name'; known: claude, codex") ;;
                esac
            done
            if [ -n "$kept_names" ] && [ -z "$(wv_policy_value "$policy_text" memory reason)" ]; then
                problems+=(".weave/policy.conf [memory] outside_graph = $kept_names records no choice without a reason: add reason = ...")
            fi
        elif [ "$policy_rc" -ne 2 ]; then
            problems+=(".weave/policy.conf cannot be read")
        fi
    fi

    # Claude: memory/*.md vs graph source_hash (precise per-file match).
    slug=$(printf '%s' "$root" | tr '/' '-')
    memdir="$HOME/.claude/projects/$slug/memory"
    if [ -d "$memdir" ]; then
        local c_total=0 c_unimported=0 f h c_values="" c_matched
        local -a c_hashes=()
        local -A c_known=()
        for f in "$memdir"/*.md; do
            [ -f "$f" ] || continue
            c_total=$((c_total + 1))
            any_store=1
            h=$(sha256sum "$f" 2>/dev/null | awk '{print $1}')
            [ -z "$h" ] && continue
            c_hashes+=("$h")
            c_values+="${c_values:+,}('$h')"
        done
        # One query for every file (wv-d737f9): a sqlite3 process per memory
        # file, each scanning every node's metadata, was ~7 s of doctor. IN
        # compares exactly as the per-file = did; a failed query matches
        # nothing, as each failed per-file query did.
        if [ "${#c_hashes[@]}" -gt 0 ]; then
            c_matched=$(db_query "WITH f(h) AS (VALUES $c_values) SELECT h FROM f WHERE h IN (SELECT json_extract(metadata,'\$.source_hash') FROM nodes);" 2>/dev/null || true)
            while IFS= read -r h; do
                [ -n "$h" ] && c_known[$h]=1
            done <<< "$c_matched"
            for h in "${c_hashes[@]}"; do
                [ -n "${c_known[$h]:-}" ] || c_unimported=$((c_unimported + 1))
            done
        fi
        if [ "$c_unimported" -gt 0 ] && ! _doctor_memory_kept claude "Claude memory"; then
            warnings+=("$c_unimported/$c_total Claude memory file(s) — import: wv memory import --source=claude --path=$memdir, or record keeping it outside the graph in .weave/policy.conf [memory] with a reason")
        fi
    fi

    # Codex: durable memory-pipeline rows for this repo. A matching graph
    # candidate imported from memory_db evidence represents the row set for this
    # repo; otherwise report the import command that closes the authority gap.
    local cdx_rows cdx_rep
    cdx_rows=$(_doctor_codex_memory_rows "$root")
    if [ "${cdx_rows:-0}" -gt 0 ]; then
        any_store=1
        cdx_rep=$(db_query "SELECT COUNT(*) FROM nodes WHERE json_extract(metadata,'\$.source_agent')='codex' AND json_extract(metadata,'\$.source_kind')='memory_db' AND json_extract(metadata,'\$.repo_root')='$(sql_escape "$root")';" 2>/dev/null || echo 0)
        [ -z "$cdx_rep" ] && cdx_rep=0
        if [ "$cdx_rep" -lt "$cdx_rows" ] && ! _doctor_memory_kept codex "Codex memory"; then
            warnings+=("$((cdx_rows - cdx_rep))/$cdx_rows Codex memory-pipeline row(s) — import: wv memory import --source=codex, or record keeping it outside the graph in .weave/policy.conf [memory] with a reason")
        fi
    fi

    local msg=""
    [ "${#problems[@]}" -eq 0 ] || msg=$(printf '%s; ' "${problems[@]}")
    [ "${#warnings[@]}" -eq 0 ] || msg+="dual authority risk: $(printf '%s; ' "${warnings[@]}")"
    msg="${msg%; }"
    if [ -n "$msg" ]; then
        _doctor_record "memory authority" "warn" "$msg"
    elif [ "$any_store" -eq 0 ]; then
        _doctor_record "memory authority" "pass" "no harness memory store for this repo"
    elif [ "${#choices[@]}" -gt 0 ]; then
        msg=$(printf '%s; ' "${choices[@]}")
        _doctor_record "memory authority" "pass" "${msg%; }"
    else
        _doctor_record "memory authority" "pass" "harness memory all represented in graph"
    fi
}

# _doctor_commit_refs — orphaned commit-provenance advisory (wv-fc4ac2).
#
# `wv done` records the SHAs carrying a node's Weave-ID; an amend, reset,
# rebase or gc later strips them out from under the graph and nothing notices
# (wv-55d2de). This is the surface that makes the count visible without being
# asked for. Advisory only: existing orphans are a cleanup job (wv-3ce8d9),
# not an installation fault, and --repair deliberately does NOT prune them —
# discarding recorded provenance is a deliberate act, not a repair.
# _doctor_install_provenance — can this install say which fixes it has?
#
# VERSION cannot answer that. Fixes land continuously between bumps, so an
# install can be many commits behind while reporting an identical version
# string, and nothing on the consumer side reveals it. install.sh records the
# source commit; this reports it, and compares against the source checkout when
# that is still reachable.
_doctor_install_provenance() {
    # Honour WV_LIB_DIR: hardcoding the default path checked a DIFFERENT install
    # than the one running whenever the library lives elsewhere, so the report
    # described something the caller was not using.
    # Honour WV_LIB_DIR for a relocated INSTALL, but not when it points at the
    # source checkout: running from source, WV_LIB_DIR is scripts/, and reading
    # provenance from there describes the working tree rather than any installed
    # copy. Hardcoding the default was wrong for a relocated install; using it
    # blindly is wrong in dev mode. Distinguish the two.
    # Resolution lives in wv_install_provenance_file (wv-config.sh) so doctor and
    # wv --version can never describe different installs; the reasoning above is
    # kept there with it.
    local prov
    prov=$(wv_install_provenance_file 2>/dev/null || true)
    if [ -z "$prov" ] || [ ! -f "$prov" ]; then
        _doctor_record "install provenance" "warn" \
            "not recorded — re-run ./install.sh so this install can report which commit it came from"
        return 0
    fi
    local desc icommit ipath
    desc=$(grep -m1 '^describe=' "$prov" 2>/dev/null | cut -d= -f2-)
    icommit=$(grep -m1 '^commit=' "$prov" 2>/dev/null | cut -d= -f2-)
    ipath=$(grep -m1 '^source_path=' "$prov" 2>/dev/null | cut -d= -f2-)

    # Compare against the source it came from, when that is still present.
    if [ -n "$ipath" ] && [ -d "$ipath/.git" ] && [ -n "$icommit" ]; then
        local head behind
        head=$(git -C "$ipath" rev-parse HEAD 2>/dev/null || echo "")
        if [ -n "$head" ] && [ "$head" != "$icommit" ]; then
            behind=$(git -C "$ipath" rev-list --count "$icommit..$head" 2>/dev/null || echo "?")
            _doctor_record "install provenance" "warn" \
                "installed at ${desc:-unknown}; source is $behind commit(s) ahead — re-run ./install.sh"
            return 0
        fi
    fi
    # A dirty install is not a healthy one: it cannot be reproduced from any
    # commit, so reporting it as a clean pass hid exactly the case where the
    # running code does not correspond to anything in the history.
    local idirty
    idirty=$(grep -m1 '^dirty=' "$prov" 2>/dev/null | cut -d= -f2-)
    if [ "$idirty" = "true" ]; then
        _doctor_record "install provenance" "warn" \
            "${desc:-unknown} — installed from a DIRTY tree, so it matches no commit; reinstall from a clean checkout to make it reproducible"
        return 0
    fi
    _doctor_record "install provenance" "pass" "${desc:-unknown}"
}

_doctor_commit_refs() {
    if ! git rev-parse --git-dir >/dev/null 2>&1; then
        _doctor_record "commit refs" "pass" "not a git repository — nothing to verify against"
        return 0
    fi
    if ! declare -f cmd_commit_refs >/dev/null 2>&1; then
        _doctor_record "commit refs" "warn" "wv commit-refs unavailable in this install"
        return 0
    fi

    local summary orphaned nodes total
    summary=$(cmd_commit_refs --json 2>/dev/null || echo "")
    if [ -z "$summary" ]; then
        _doctor_record "commit refs" "warn" "sweep failed — run: wv commit-refs"
        return 0
    fi
    orphaned=$(printf '%s' "$summary" | jq -r '.totals.orphaned // 0' 2>/dev/null || echo 0)
    nodes=$(printf '%s' "$summary" | jq -r '.totals.orphaned_nodes // 0' 2>/dev/null || echo 0)
    total=$(printf '%s' "$summary" | jq -r '.totals.refs // 0' 2>/dev/null || echo 0)
    local ckpt reg unk
    ckpt=$(printf '%s' "$summary" | jq -r '.totals.orphaned_checkpoint // 0' 2>/dev/null || echo 0)
    reg=$(printf '%s' "$summary" | jq -r '.totals.orphaned_regular // 0' 2>/dev/null || echo 0)
    unk=$(printf '%s' "$summary" | jq -r '.totals.orphaned_unknown // 0' 2>/dev/null || echo 0)

    # Checkpoint churn is the DESIGNED steady state: auto-checkpoint commits are
    # superseded constantly, so their refs go unreachable as a matter of course.
    # Reporting that identically to a regular ref going unreachable made the
    # advisory a permanent warning, and a permanent warning is where a real
    # provenance loss hides. Only regular or unclassifiable orphans warn.
    if [ "${reg:-0}" -gt 0 ] 2>/dev/null || [ "${unk:-0}" -gt 0 ] 2>/dev/null; then
        # Why they are orphaned comes before the prune it offers (wv-6d53ec).
        local why
        why=$(printf '%s' "$summary" | jq -r '
            [ .refs[]? | select((.class == "unreachable" or .class == "missing") and .kind != "checkpoint")
              | (.reason // "unclassified") ]
            | group_by(.)
            | map("\(length) \({not_in_clone: "not in this clone", not_a_commit: "not a commit"}[.[0]] // .[0])")
            | join(", ")' 2>/dev/null || echo "")
        _doctor_record "commit refs" "warn" \
            "$((reg + unk)) non-checkpoint ref(s) orphaned of $total across $nodes node(s) (plus $ckpt expected checkpoint)${why:+: $why} — inspect: wv commit-refs; remove: wv commit-refs --prune"
    elif [ "${orphaned:-0}" -gt 0 ] 2>/dev/null; then
        _doctor_record "commit refs" "pass" \
            "$total recorded ref(s); $ckpt orphaned checkpoint ref(s) — expected churn, clear with: wv commit-refs --prune"
    else
        _doctor_record "commit refs" "pass" "$total recorded ref(s), none orphaned"
    fi
}

# _doctor_graph_credentials — node text, metadata and edge context holding a
# credential-shaped string (wv-320587). Names each node and shape, never the
# value. A warning, not a repair: the text may already be in git history and
# GitHub issues, so the credential is rotated first, then the node rewritten.
_doctor_graph_credentials() {
    if [ ! -f "${WV_DB:-}" ] || ! declare -F wv_credential_regex >/dev/null; then
        _doctor_record "graph credentials" "warn" "credential scan unavailable (no graph or no scanner)"
        return 0
    fi
    local rows hits line shape found=""
    rows=$(db_query "SELECT id || char(9) || replace(replace(text || ' ' || COALESCE(metadata, ''), char(10), ' '), char(13), ' ') FROM nodes
                     UNION ALL SELECT source || char(9) || replace(COALESCE(context, ''), char(10), ' ') FROM edges;" 2>/dev/null) || {
        _doctor_record "graph credentials" "warn" "graph could not be read for the credential scan"
        return 0
    }
    hits=$(grep -E -- "$(wv_credential_regex)" <<< "$rows" 2>/dev/null || true)
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        shape=$(wv_credential_shape "${line#*$'\t'}") || continue
        found="${found:+$found, }${line%%$'\t'*} ($shape)"
    done <<< "$hits"
    if [ -n "$found" ]; then
        _doctor_record "graph credentials" "warn" \
            "credential-shaped text in: $found — rotate the credential (it may be in git history and GitHub issues), then rewrite the node with wv update"
    else
        _doctor_record "graph credentials" "pass" "no credential-shaped text in node text, metadata or edge context"
    fi
}

_doctor_local_procedure_command_refs() {
    local procedures_dir="$1" file id matches=""
    [ -d "$procedures_dir" ] || return 0

    for file in "$procedures_dir"/*.md; do
        [ -f "$file" ] || continue
        if awk '
            BEGIN { section=0; visibility="local"; command_ref=0 }
            /^---[[:space:]]*$/ { section++; next }
            section == 1 && /^visibility:/ {
                value=$0
                sub(/^visibility:[[:space:]]*/, "", value)
                sub(/[[:space:]]*#.*/, "", value)
                visibility=value
            }
            section >= 2 && $0 ~ /(^|[^.\/:[:alnum:]_-])wv[[:space:]]+[^[:space:]]/ {
                command_ref=1
            }
            END { exit !(visibility == "local" && command_ref) }
        ' "$file"; then
            id=$(awk -F': *' '/^id:/{print $2; exit}' "$file")
            [ -n "$id" ] || id=$(basename "$file" .md)
            matches="${matches:+$matches, }$id"
        fi
    done

    printf '%s' "$matches"
}

# _doctor_check_edge_invariants — stored edges that break their type's invariant
# and closed parents over open children nothing accounts for (ontology S2,
# wv-76b361). The query is the one wv link and wv done refuse by; history is
# reported here, never refused on read (D4). Each detail names up to five.
_doctor_check_edge_invariants() {
    local edges children n list
    if ! edges=$(db_query "SELECT invariant || ':' || source || '->' || target || ' (' || type || ')'
            FROM ($(wv_edge_violations_sql "SELECT source, target, type FROM edges"))
            ORDER BY type, invariant, source, target;" 2>/dev/null); then
        _doctor_record "edge invariants" "warn" "could not evaluate the edge invariants"
    elif [ -n "$edges" ]; then
        n=$(wc -l <<< "$edges")
        list=$(head -5 <<< "$edges" | tr '\n' ';' | sed 's/;$//; s/;/; /g')
        _doctor_record "edge invariants" "warn" "$n stored edge(s) break their type's invariant: $list$([ "$n" -gt 5 ] && echo '; ...') — see contracts/edge-types-v1.json"
    else
        _doctor_record "edge invariants" "pass" "every stored edge keeps its type's invariant"
    fi
    if ! children=$(db_query "SELECT p.id || '>' || c.id FROM edges e
            JOIN nodes p ON p.id = e.target JOIN nodes c ON c.id = e.source
            WHERE e.type = 'implements' AND p.status = 'done' AND $(wv_unaccounted_child_sql c e.target)
            ORDER BY p.id, c.id;" 2>/dev/null); then
        _doctor_record "closed parents" "warn" "could not evaluate closed parents over open children"
    elif [ -n "$children" ]; then
        n=$(wc -l <<< "$children")
        list=$(head -5 <<< "$children" | tr '\n' ' ' | sed 's/ $//')
        _doctor_record "closed parents" "warn" "$n open child(ren) under a closed parent, not parked, re-parented or resolved (parent>child): $list$([ "$n" -gt 5 ] && echo ' ...')"
    else
        _doctor_record "closed parents" "pass" "no closed parent over an unaccounted open child"
    fi
}

_doctor_record() {
    local name="$1" status="$2" detail="$3"
    _dr_total=$((_dr_total + 1))
    case "$status" in
        pass) _dr_pass=$((_dr_pass + 1)) ;;
        fail) _dr_fail=$((_dr_fail + 1)) ;;
        warn) _dr_warn=$((_dr_warn + 1)) ;;
    esac
    if [ "$_dr_format" = "json" ]; then
        # Details carry paths, commands and error text: escaped, or one quote
        # in a detail makes the whole --json report unparsable.
        _dr_results="${_dr_results:+$_dr_results,}$(printf '{"check":"%s","status":"%s","detail":"%s"}' "$name" "$status" "$(wv_json_escape "$detail")")"
    else
        local icon
        case "$status" in
            pass) icon="${GREEN}✓${NC}" ;;
            fail) icon="${RED}✗${NC}" ;;
            warn) icon="${YELLOW}⊘${NC}" ;;
        esac
        echo -e "  $icon $name: $detail"
    fi
}

# _doctor_entry_script — the wv script this process runs.
_doctor_entry_script() {
    if [ -f "$0" ]; then echo "$0"; else echo "${SCRIPT_DIR:-.}/wv"; fi
}

# _doctor_check_lib_refs <label> — every library a component names must exist.
# The required set is read from the code, not typed: each wv-*.sh / wv-*.py
# named outside a comment in the entry script, the libraries, the command
# modules and the git-hook sources, less command modules (checked below by
# what they define) and names whose parent path component is a hooks directory
# however spelled (hooks/, $_hooks_dir/, ${HOOKS_DIR}/): hook files, not
# libraries. $HOOK_DIR/../lib/wv-x.sh keeps lib/ as its parent and counts.
# A new library is required the moment something loads it; a typed list had to
# be remembered and was not (wv-587469).
_doctor_check_lib_refs() {
    local label="$1" entry refs r found=0 total=0 missing=""
    entry=$(_doctor_entry_script)
    refs=$(for f in "$entry" "$WV_LIB_DIR"/lib/*.sh "$WV_LIB_DIR"/cmd/*.sh "$WV_LIB_DIR"/hooks/*.sh; do
               [ -f "$f" ] && grep -v '^[[:space:]]*#' "$f"
           done 2>/dev/null | grep -oE '[^/[:space:]"'"'"']*/?wv-[a-z0-9-]+\.(sh|py)\b' \
           | awk -F/ '{ parent = (NF > 1) ? tolower($(NF-1)) : ""
                        name = $NF; sub(/^[^w]*/, "", name)
                        if (parent !~ /hook/ && name ~ /^wv-/ && name !~ /^wv-cmd-/) print name }' | sort -u)
    for r in $refs; do
        total=$((total + 1))
        if [ -f "$WV_LIB_DIR/lib/$r" ]; then
            found=$((found + 1))
        else
            missing="${missing:+$missing, }$r"
        fi
    done
    if [ -n "$missing" ]; then
        _doctor_record "$label" "fail" "$found/$total referenced libraries present (missing: $missing)"
    else
        _doctor_record "$label" "pass" "$found/$total referenced libraries present"
    fi
}

# _doctor_check_cmd_defs <label> — every cmd_* the dispatcher calls must be
# defined by some module. With command modules loaded on first use, a missing
# module shows only as its commands failing, so this is the check that names
# it. Assignments and expansions (local cmd_func=..., $cmd_func) are not calls.
_doctor_check_cmd_defs() {
    local label="$1" entry calls c found=0 total=0 missing=""
    entry=$(_doctor_entry_script)
    # shellcheck disable=SC2016  # the bracket expression [^$...] matches a literal $ in source text
    calls=$(grep -v '^[[:space:]]*#' "$entry" 2>/dev/null \
        | grep -oE '(^|[^$a-zA-Z0-9_{])cmd_[a-z0-9_]+[=]?' | grep -v '=$' \
        | grep -oE 'cmd_[a-z0-9_]+' | sort -u)
    for c in $calls; do
        total=$((total + 1))
        if grep -qE -- "^$c\(\)" "$entry" "$WV_LIB_DIR"/cmd/*.sh "$WV_LIB_DIR"/lib/*.sh 2>/dev/null; then
            found=$((found + 1))
        else
            missing="${missing:+$missing, }$c"
        fi
    done
    if [ -n "$missing" ]; then
        _doctor_record "$label" "fail" "$found/$total dispatched commands defined (undefined: $missing)"
    else
        _doctor_record "$label" "pass" "$found/$total dispatched commands defined"
    fi
}

_doctor_agent_python_exec() {
    local python_command="$1"
    shift

    [ -n "$python_command" ] || return 127
    PYTHONPATH="${WV_LIB_DIR:-}" "$python_command" "$@"
}

_doctor_check_agent_env() {
    local python_command
    python_command=$(_bootstrap_python_command)

    if [ -z "$python_command" ]; then
        _doctor_record "agent python" "fail" "no python command resolved for agent flows"
        _doctor_record "agent pytest" "fail" "cannot verify pytest without an agent python command"
        _doctor_record "agent imports" "fail" "cannot verify imports without an agent python command"
        return
    fi

    local python_detail="$python_command"
    if [ -x "$python_command" ]; then
        _doctor_record "agent python" "pass" "$python_detail"
    else
        _doctor_record "agent python" "fail" "$python_detail not executable"
    fi

    local pytest_version
    pytest_version=$(_doctor_agent_python_exec "$python_command" -m pytest --version 2>/dev/null | head -1 || true)
    if [ -n "$pytest_version" ]; then
        _doctor_record "agent pytest" "pass" "$pytest_version"
    else
        _doctor_record "agent pytest" "warn" "pytest missing for $python_detail — install project dev dependencies"
    fi

    local import_status
    import_status=$(_doctor_agent_python_exec "$python_command" -c 'import weave_gh, weave_indexer, weave_quality, weave_search; print("imports ok")' 2>/dev/null || true)
    if [ "$import_status" = "imports ok" ]; then
        _doctor_record "agent imports" "pass" "weave_gh weave_indexer weave_quality weave_search"
    else
        _doctor_record "agent imports" "warn" "PYTHONPATH/WV_LIB_DIR import path not ready for agent modules"
    fi
}

_doctor_check_codex_mcp() {
    if ! command -v codex >/dev/null 2>&1; then
        _doctor_record "codex mcp" "warn" "codex command not found; skip MCP scope check"
        return
    fi

    local mcp_list
    mcp_list=$(codex mcp list 2>/dev/null || true)
    if [ -z "$mcp_list" ]; then
        _doctor_record "codex mcp" "warn" "no Codex MCP registrations detected; optional: wv init-repo --agent=codex --codex-mcp"
        return
    fi

    local has_lite has_inspect has_full
    has_lite=false
    has_inspect=false
    has_full=false
    grep -q '^weave-lite[[:space:]]' <<< "$mcp_list" && has_lite=true
    grep -q '^weave-inspect[[:space:]]' <<< "$mcp_list" && has_inspect=true
    grep -q '^weave[[:space:]]' <<< "$mcp_list" && has_full=true

    if [ "$has_full" = true ] && { [ "$has_lite" = true ] || [ "$has_inspect" = true ]; }; then
        _doctor_record "codex mcp" "warn" "stale full weave MCP still registered alongside lite/inspect; remove it with: codex mcp remove weave"
    elif [ "$has_lite" = true ]; then
        _doctor_record "codex mcp" "pass" "weave-lite registered (recommended Codex default)"
    elif [ "$has_inspect" = true ]; then
        _doctor_record "codex mcp" "pass" "weave-inspect registered (read-only Codex scope)"
    elif [ "$has_full" = true ]; then
        _doctor_record "codex mcp" "warn" "full weave MCP registered; prefer weave-lite/inspect and use CLI for GitHub/network/write operations"
    else
        _doctor_record "codex mcp" "warn" "Weave MCP not registered for Codex; optional: wv init-repo --agent=codex --codex-mcp"
    fi
}

# Detect the project Codex hook config and surface trust guidance. Codex hook
# trust is reviewed inside Codex itself (via /hooks) and is not reliably
# inspectable from outside the running session, so a present + complete
# config still warns "pending trust" rather than "pass" (see
# docs/PROPOSAL-codex-hooks-rust-dispatch.md test plan item 10).
_doctor_check_codex_hooks() {
    local git_root hooks_file contract_file
    git_root=$(git rev-parse --show-toplevel 2>/dev/null)
    if [ -z "$git_root" ]; then
        _doctor_record "codex hooks" "warn" "not in a git repo; skip"
        return
    fi
    hooks_file="$git_root/.codex/hooks.json"
    contract_file="$git_root/.codex/weave.json"

    if [ ! -f "$hooks_file" ]; then
        if [ -f "$contract_file" ] && jq -e '(.hooks.enabled // 0) == 1' "$contract_file" >/dev/null 2>&1; then
            _doctor_record "codex hooks" "warn" ".codex/weave.json records hooks enabled but .codex/hooks.json is missing; run: wv init-repo --agent=codex --codex-hooks --force"
        else
            _doctor_record "codex hooks" "warn" "no project Codex hooks; optional: wv init-repo --agent=codex --codex-hooks"
        fi
        return
    fi

    if ! jq -e 'type == "object" and (.hooks | type) == "object"' "$hooks_file" >/dev/null 2>&1; then
        _doctor_record "codex hooks" "fail" ".codex/hooks.json is present but is not valid JSON with a top-level hooks object"
        return
    fi

    local missing="" ev
    for ev in SessionStart PreToolUse PostToolUse PreCompact Stop; do
        jq -e --arg ev "$ev" '(.hooks[$ev] // []) | length > 0' "$hooks_file" >/dev/null 2>&1 || missing="${missing:+$missing, }$ev"
    done
    if [ -n "$missing" ]; then
        _doctor_record "codex hooks" "warn" ".codex/hooks.json is stale, missing event(s): $missing -- regenerate with wv init-repo --agent=codex --codex-hooks --force"
        return
    fi

    # A blocking event that still runs dispatch with --json blocks with exit 1,
    # which Codex reads as a failed hook, so the guard is advisory only
    # (wv-5b774a); the generated config uses --format=host.
    local advisory=""
    for ev in PreToolUse Stop; do
        jq -e --arg ev "$ev" '[.hooks[$ev][]?.hooks[]?.command // empty | select(test("hook dispatch") and (test("--format=host") | not))] | length > 0' \
            "$hooks_file" >/dev/null 2>&1 && advisory="${advisory:+$advisory, }$ev"
    done
    if [ -n "$advisory" ]; then
        _doctor_record "codex hooks" "warn" ".codex/hooks.json is stale, $advisory dispatch without --format=host cannot block in Codex -- regenerate with wv init-repo --agent=codex --codex-hooks --force"
        return
    fi

    _doctor_record "codex hooks" "warn" ".codex/hooks.json covers SessionStart/PreToolUse/PostToolUse/PreCompact/Stop -- pending trust; review and trust with /hooks in Codex before it enforces"
}

# _doctor_hook_budgets <config> -- "Event=secs ..." for every event a hook config
# registers: the largest timeout among its hooks, or "unset" when any hook in
# the event has none. Reads nested (Claude Code, Codex) and flat (VS Code) forms.
_doctor_hook_budgets() {
    jq -r '.hooks // {} | to_entries | map(
            .key as $ev
            | [.value[]? | if has("hooks") then .hooks[]? else . end]
            | "\($ev)=" + (if length == 0 then "none"
                elif any(.[]; (.timeout | type) != "number") then "unset"
                else (map(.timeout) | max | tostring) end)
          ) | join(" ")' "$1" 2>/dev/null
}

# _doctor_check_host_hooks -- the host hook contract (wv-0f70b5). Each host
# changes its hook budgets without notice: Claude Code 2.1.74 cut SessionEnd to
# 1.5 s and the session-end routine failed on every exit for eight months
# unnoticed (wv-a32e69). For each host on PATH this records its version and the
# per-event timeouts of the hook config it reads, warns on a hook with no
# explicit timeout or one past the host's documented cap, and warns when the
# host's version differs from the one recorded at the last doctor run
# ($WV_CONFIG_DIR/host-versions.json), so a host upgrade shows up as a difference.
_doctor_check_host_hooks() {
    local git_root record prev_json new_json host bin ver cfg budgets old caps detail status
    local cap ev limit got
    git_root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
    record="${WV_CONFIG_DIR:-$HOME/.config/weave}/host-versions.json"
    prev_json=$(jq -c 'if type == "object" then . else {} end' "$record" 2>/dev/null) || prev_json='{}'
    [ -n "$prev_json" ] || prev_json='{}'
    new_json="$prev_json"
    # WV_DOCTOR_HOSTS narrows the hosts probed (tests use one fake host).
    for host in ${WV_DOCTOR_HOSTS:-claude codex code amp pi}; do
        bin=$(command -v "$host" 2>/dev/null) || continue
        ver=$(timeout 10 "$bin" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9][0-9A-Za-z.+-]*' | head -1)
        [ -n "$ver" ] || ver="unknown"
        case "$host" in
            claude) cfg="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"; caps="SessionEnd:60" ;;
            codex)  cfg="$git_root/.codex/hooks.json"; caps="SessionEnd:3" ;;
            code)   cfg="$git_root/.github/hooks/weave.json"; caps="" ;;
            *)      cfg=""; caps="" ;;
        esac
        status="pass"
        if [ -n "$cfg" ] && [ -f "$cfg" ]; then
            budgets=$(_doctor_hook_budgets "$cfg")
            [ -n "$budgets" ] || budgets="no hooks registered"
            case " $budgets " in
                *=unset*) status="warn"
                          budgets="$budgets (a hook without an explicit timeout runs on the host's default budget)" ;;
            esac
            for cap in $caps; do
                ev=${cap%%:*} limit=${cap#*:}
                got=$(printf '%s\n' "$budgets" | grep -oE -- "(^| )$ev=[0-9]+" | grep -oE '[0-9]+$' || true)
                if [ -n "$got" ] && [ "$got" -gt "$limit" ]; then
                    status="warn"
                    budgets="$budgets ($ev ${got}s exceeds $host's ${limit}s cap)"
                fi
            done
        elif [ -n "$cfg" ]; then
            budgets="no Weave hook config"
        else
            budgets="Weave ships no hooks for this host"
        fi
        detail="$host $ver; hook budgets (s): $budgets"
        old=$(jq -r --arg h "$host" '.[$h] // empty' <<<"$prev_json")
        if [ -n "$old" ] && [ "$old" != "$ver" ]; then
            status="warn"
            detail="$detail; version changed from $old since the last doctor run -- check $host's changelog for hook budget changes and re-time the lifecycle hooks"
        fi
        _doctor_record "host hooks" "$status" "$detail"
        new_json=$(jq -c --arg h "$host" --arg v "$ver" '.[$h] = $v' <<<"$new_json")
    done
    if [ "$new_json" != "$prev_json" ]; then
        if ! { mkdir -p "$(dirname "$record")" &&
               printf '%s\n' "$new_json" > "$record.tmp.$$" &&
               mv -f "$record.tmp.$$" "$record"; } 2>/dev/null; then
            rm -f "$record.tmp.$$" 2>/dev/null
        fi
    fi
    return 0
}

# _doctor_check_git_hook label src_path installed_path marker install_cmd
# Records pass/warn via _doctor_record. Shared by pre-commit and prepare-commit-msg checks.
_doctor_check_git_hook() {
    local label="$1" src="$2" installed="$3" grep_pattern="$4" install_cmd="$5"
    # git skips a hook without the execute bit: a current copy it will not run
    # is no gate at all (wv-76c726, the doctor side of wv-ecae1c).
    if [ -f "$installed" ] && [ ! -x "$installed" ] && wv_git_hook_is_weave "$installed" "$grep_pattern"; then
        _doctor_record "$label" "warn" "installed but not executable, so git skips it — chmod +x $installed"
        return 0
    fi
    if [ -f "$installed" ]; then
        if [ -f "$src" ] && cmp -s "$src" "$installed" 2>/dev/null; then
            _doctor_record "$label" "pass" "Weave hook installed and current"
        elif [ ! -f "$src" ] && wv_git_hook_is_weave "$installed" "$grep_pattern"; then
            _doctor_record "$label" "pass" "Weave hook installed (managed by wv init-repo)"
        elif wv_git_hook_is_weave "$installed" "$grep_pattern"; then
            _doctor_record "$label" "warn" "stale — $install_cmd"
        else
            _doctor_record "$label" "warn" "exists but not the Weave version — $install_cmd"
        fi
    else
        _doctor_record "$label" "warn" "not installed — $install_cmd"
    fi
}

# _doctor_check_hook_module <module source> <hooks dir> — a module the Weave
# pre-commit hook loads from beside itself (wv-758b3a) is installed there and
# current. Only where this repository carries the source (Weave's own) and the
# installed pre-commit is Weave's; a consumer never has one, so no row.
_doctor_check_hook_module() {
    local src="$1" hooks="$2" name installed
    [ -f "$src" ] || return 0
    wv_git_hook_is_weave "$hooks/pre-commit" "Weave pre-commit" || return 0
    name=$(basename "$src")
    installed="$hooks/$name"
    if [ ! -f "$installed" ]; then
        _doctor_record "pre-commit module" "warn" "$name missing beside the pre-commit hook — run ./install.sh"
    elif ! cmp -s "$src" "$installed" 2>/dev/null; then
        _doctor_record "pre-commit module" "warn" "$name beside the pre-commit hook is stale — run ./install.sh"
    else
        _doctor_record "pre-commit module" "pass" "$name installed beside the pre-commit hook and current"
    fi
}

# _doctor_check_hot_zone_orphans — warn about hot-zone dirs with no matching repo owner.
# Args: hot_zone path
_doctor_check_hot_zone_orphans() {
    local hot_zone="$1"
    local hz_parent; hz_parent=$(dirname "$hot_zone")
    [ -d "$hz_parent" ] || return 0
    local orphan_count=0 d owner
    for d in "$hz_parent"/*/; do
        [ -f "${d}brain.db" ] || continue
        owner=$(cat "${d}.repo_root" 2>/dev/null || echo "")
        if [ -n "$owner" ] && [ ! -d "$owner" ]; then
            orphan_count=$((orphan_count + 1))
        elif [ -z "$owner" ]; then
            [ "${d%/}" != "$hot_zone" ] && orphan_count=$((orphan_count + 1))
        fi
    done
    if [ "$orphan_count" -gt 0 ]; then
        _doctor_record "orphan hot-zones" "warn" \
            "$orphan_count unmatched dir(s) under $hz_parent — run: wv hotzone gc"
    fi
}

# _doctor_check_hot_zone_shadow — warn when this repo has a brain.db under a
# placement root it does not resolve to (wv-854b4a). Placement adopts the zone
# already holding this repo's database (wv-b831e3), and wv refuses to run when
# two non-empty ones exist, so what this can still see is an empty one: what
# sqlite3 leaves after opening a guessed path, which on 2026-09-25 read as a
# split brain. Reports only: placement is not changed here.
# Candidates are compared by file identity, not path: the /tmp zone's neutral
# name is a symlink to its legacy directory (wv-95bddf), so one live database
# has two paths, and advising removal of either would remove the live graph
# (wv-6f2eed). A file two names reach is reported once.
# Args: live hot_zone path. WV_DOCTOR_PLACEMENT_ROOTS overrides the roots (tests).
_doctor_check_hot_zone_shadow() {
    local hot_zone="$1" repo_root repo_hash uid root cand seen also="" found=0
    local -a reported=()
    repo_root="${WV_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null)}"
    [ -n "$repo_root" ] || return 0
    repo_hash=$(echo "$repo_root" | md5sum | cut -c1-8)
    uid=$(id -u 2>/dev/null || echo "$UID")
    for root in ${WV_DOCTOR_PLACEMENT_ROOTS:-/tmp/weave-hotzone-${uid} /tmp/weave-codex-${uid} /dev/shm/weave /tmp/weave-${uid}}; do
        [ "$root/$repo_hash" = "$hot_zone" ] && continue
        cand="$root/$repo_hash/brain.db"
        [ -f "$cand" ] || continue
        if [ "$cand" -ef "$hot_zone/brain.db" ]; then
            also="$cand"
            continue
        fi
        for seen in "${reported[@]}"; do
            [ "$cand" -ef "$seen" ] && continue 2
        done
        reported+=("$cand")
        found=1
        if [ ! -s "$cand" ]; then
            _doctor_record "hot-zone shadow" "warn" \
                "empty $cand (left by opening a guessed path); remove it. Live DB: $hot_zone/brain.db (wv hotzone db)"
        else
            _doctor_record "hot-zone shadow" "warn" \
                "second brain.db for this repo at $cand; live DB is $hot_zone/brain.db (wv hotzone db). Placement adopts the zone holding a database (wv-b831e3). Remove neither yet: the copies may have diverged and syncing both does not merge them (wv-a73141). Back up both (sqlite3 <db> \".backup '<file>'\"), run wv hotzone diff $hot_zone/brain.db $cand, carry what the live copy lacks into it, then remove the other"
        fi
    done
    [ "$found" -eq 0 ] && _doctor_record "hot-zone shadow" "pass" \
        "no brain.db for this repo outside $hot_zone${also:+ (also reached as $also: the same file, not a copy)}"
    return 0
}

# _doctor_check_hot_zone_names — report both names of the /tmp zone and which
# one is the physical directory (wv-7e1e49). During the rename transition the
# legacy name stays physical and the neutral name is an alias to it
# (wv-95bddf); a reader should not have to infer that from ls. Reports only:
# hot_zone_check and hot_zone_ensure decide what is used or refused, and the
# alias verdict is theirs, hot_zone_dir_problem, so the two cannot disagree
# (wv-9d2cd2: a looser comparison here passed an alias the guard refuses).
_doctor_check_hot_zone_names() {
    case "${OSTYPE:-}" in darwin*) return 0 ;; esac
    type _hot_zone_linux_zones >/dev/null 2>&1 || return 0
    _hot_zone_linux_zones
    local n="$_HZ_NEUTRAL" l="$_HZ_LEGACY" problem
    if [ -L "$n" ]; then
        problem=$(hot_zone_dir_problem "$n" "$l")
        if [ -n "$problem" ]; then
            _doctor_record "hot-zone names" "warn" \
                "$n $problem; wv refuses it as a hot-zone base"
        elif [ ! -e "$l" ] && [ ! -L "$l" ]; then
            _doctor_record "hot-zone names" "pass" \
                "$n is an alias of $l, which is absent; the next wv call that opens the zone recreates it as the physical directory"
        else
            _doctor_record "hot-zone names" "pass" \
                "physical: $l (legacy name, kept while hosts run mixed versions); $n is an alias of it"
        fi
    elif [ -d "$n" ] && [ -d "$l" ] && [ ! -L "$l" ]; then
        if [ -n "$_HZ_TMP_CONFLICT" ]; then
            _doctor_record "hot-zone names" "warn" \
                "$n and $l are separate directories that both hold databases; wv refuses to pick one"
        elif _hot_zone_populated "${_HZ_ZONES[0]}"; then
            _doctor_record "hot-zone names" "pass" \
                "physical: ${_HZ_ZONES[0]} (the one holding databases); $n and $l are separate directories"
        else
            _doctor_record "hot-zone names" "pass" \
                "physical: ${_HZ_ZONES[0]} (neither holds a database, so the legacy directory is the default authority); $n and $l are separate directories"
        fi
    elif [ -d "$n" ]; then
        if [ -L "$l" ]; then
            _doctor_record "hot-zone names" "pass" "physical: $n; legacy name $l is a symlink"
        else
            _doctor_record "hot-zone names" "pass" "physical: $n; legacy name $l absent"
        fi
    elif [ -d "$l" ] && [ ! -L "$l" ]; then
        _doctor_record "hot-zone names" "pass" \
            "physical: $l (legacy name); the alias $n is added on the next wv call that opens the zone"
    else
        _doctor_record "hot-zone names" "pass" \
            "neither $n nor $l exists; first use creates $l and the alias $n"
    fi
    return 0
}

# _doctor_check_graph_load — fail when the last wv load on this hot zone was not
# acknowledged (wv-2f55dd). A failed load keeps the snapshot but rolls back the
# delta replay, so every change made only in deltas since the last state.sql is
# missing; on 2026-11-09 one ran unnoticed for nine hours behind a single warning
# line (wv-5e5f18). The attempt record is wv load's own (_weave_load_attempt).
_doctor_check_graph_load() {
    [ -n "${WV_DB:-}" ] && [ -f "$WV_DB" ] || return 0
    local row state at reasons
    row=$(sqlite3 -readonly -separator $'\t' "$WV_DB" \
        "SELECT state, at, reasons FROM _weave_load_attempt WHERE id = 1;" 2>/dev/null) || return 0
    [ -n "$row" ] || return 0
    IFS=$'\t' read -r state at reasons <<< "$row"
    case "$state" in
        complete) _doctor_record "graph load" "pass" "last load acknowledged ($at)" ;;
        failed)   _doctor_record "graph load" "fail" \
                      "last load not acknowledged ($at): $reasons — changes made only in deltas are missing; run wv load for the failing operation" ;;
        *)        _doctor_record "graph load" "warn" "last load did not finish (state $state, $at)" ;;
    esac
}

# _doctor_check_delta_v2_catalog — fail when a committed Delta v2 op carries a
# hard disposition (wv-99c85a). wv load rolls the WHOLE v2 batch back on the
# first one and, unless WV_DELTA_V2_STRICT=1, only warns and falls back to v1,
# so one bad op silently disables v2 replay on every clone on every load. The
# static pass (wv-delta-v2-replay.py --check) needs no database.
_doctor_check_delta_v2_catalog() {
    [ -n "${WEAVE_DIR:-}" ] && [ -d "$WEAVE_DIR/deltas" ] || return 0
    # mapfile, not a read loop: read takes a pipe one byte at a time
    # (wv-12dce0). find prints no empty path, so the list is the same.
    local -a ops=()
    mapfile -t ops < <(find "$WEAVE_DIR/deltas" -path '*/v2/*.json' -type f 2>/dev/null)
    [ "${#ops[@]}" -gt 0 ] || return 0

    local replay_py="${WV_LIB_DIR:-$SCRIPT_DIR}/lib/wv-delta-v2-replay.py"
    [ -f "$replay_py" ] || replay_py="$SCRIPT_DIR/lib/wv-delta-v2-replay.py"
    if [ ! -f "$replay_py" ]; then
        _doctor_record "delta v2 catalog" "warn" "replay evaluator not found; ${#ops[@]} op(s) unchecked"
        return 0
    fi
    local out rc=0 verdict
    # The list goes on stdin, not as arguments (wv-a05dcd): the catalog grows.
    out=$(printf '%s\n' "${ops[@]}" | python3 "$replay_py" --check --ops-from=- 2>/dev/null) || rc=$?
    verdict=$(printf '%s' "$out" | jq -r '
        if (.failures | length) == 0 then "ok"
        else "\(.failures | length) of \(.checked) op(s) fail: \(.failures[0].path | split("/") | .[-1]) (\(.failures[0].disposition): \(.failures[0].reason))"
        end' 2>/dev/null) || verdict=""
    if [ "$rc" -eq 0 ] && [ "$verdict" = "ok" ]; then
        _doctor_record "delta v2 catalog" "pass" "${#ops[@]} op(s) pass replay validation"
    elif [ "$rc" -eq 2 ] && [ -n "$verdict" ]; then
        _doctor_record "delta v2 catalog" "fail" \
            "$verdict — wv load rolls back ALL v2 replay and falls back to v1 on every clone"
    else
        _doctor_record "delta v2 catalog" "warn" "replay --check could not run (rc=$rc)"
    fi
}

# _doctor_check_install_drift — compare source scripts/ tree with installed ~/.local/lib/weave/.
_doctor_check_install_drift() {
    local source_path_file="$HOME/.config/weave/source-path"
    [ -f "$source_path_file" ] || return 0
    local src_root; src_root=$(cat "$source_path_file" 2>/dev/null || echo "")
    [ -n "$src_root" ] && [ -d "$src_root/scripts/cmd" ] || return 0
    local lib_dir="$HOME/.local/lib/weave"
    local drifted_count=0 src_file rel installed_file
    for src_file in "$src_root/scripts/cmd/"*.sh "$src_root/scripts/lib/"*.sh "$src_root/scripts/wv"; do
        [ -f "$src_file" ] || continue
        rel="${src_file#"$src_root/scripts/"}"
        installed_file="$lib_dir/$rel"
        [ "$rel" = "wv" ] && installed_file="$HOME/.local/bin/wv"
        if [ ! -f "$installed_file" ]; then
            drifted_count=$((drifted_count + 1))
        elif [ "$(md5sum "$src_file" 2>/dev/null | awk '{print $1}')" != \
              "$(md5sum "$installed_file" 2>/dev/null | awk '{print $1}')" ]; then
            drifted_count=$((drifted_count + 1))
        fi
    done
    if [ "$drifted_count" -eq 0 ]; then
        _doctor_record "install drift" "pass" "source and installed lib match"
    else
        _doctor_record "install drift" "warn" "$drifted_count file(s) differ — run: wv self-update"
    fi
}

# _doctor_check_verification — surface the P6 verification-gate layer (finding wv-e754b0 O2).
# Repo-scoped. The gate ships inert by default and nothing else tells a user it is off,
# what files it still needs, or that a raw sqlite3 UPDATE silently resets on reboot (tmpfs).
_doctor_check_verification() {
    [ -z "${WEAVE_DIR:-}" ] && return 0
    [ -n "${WV_DB:-}" ] && [ -f "$WV_DB" ] || return 0

    local conf="$WEAVE_DIR/quality.conf" tmap="$WEAVE_DIR/test-map.conf" tg
    tg=$(sqlite3 "$WV_DB" "SELECT value FROM policy_thresholds WHERE key='test_gate';" 2>/dev/null)
    [ -z "$tg" ] && tg="0"
    tg="${tg%.0}"   # sqlite may render the integer as 1.0

    local conf_has_gate=false
    grep -qE '^[[:space:]]*test_gate[[:space:]]*=' "$conf" 2>/dev/null && conf_has_gate=true

    # 1. gate state — test_gate=0 is the shipped default, so report it as pass+hint, not a failure.
    case "$tg" in
        0) _doctor_record "verification gate" "pass" "test_gate=0 (off — advisory; enable: wv config enable test-gate)" ;;
        1) _doctor_record "verification gate" "pass" "test_gate=1 (warn — soft advisory on wv done)" ;;
        2) _doctor_record "verification gate" "pass" "test_gate=2 (block — hard gate on wv done)" ;;
        *) _doctor_record "verification gate" "warn" "test_gate=$tg (unrecognised; expected 0|1|2)" ;;
    esac

    # 2. durability — a gate enabled only in the tmpfs DB resets on reboot (not in state.sql).
    if [ "$tg" != "0" ] && [ "$conf_has_gate" = false ]; then
        _doctor_record "verification config" "warn" "test_gate=$tg in DB but not in .weave/quality.conf [thresholds] — session-only, resets on reboot. Fix: wv config enable test-gate"
    elif [ "$conf_has_gate" = true ]; then
        _doctor_record "verification config" "pass" "durable in .weave/quality.conf [thresholds]"
    fi

    # 3. test-map required for the gate to classify anything when live.
    if [ "$tg" != "0" ]; then
        local tmap_rc=0
        wv_config_read "$tmap" >/dev/null || tmap_rc=$?
        if [ "$tmap_rc" -eq 0 ]; then
            _doctor_record "test-map" "pass" ".weave/test-map.conf present"
        elif [ "$tmap_rc" -ne 2 ]; then
            _doctor_record "test-map" "fail" ".weave/test-map.conf exists but cannot be read (unreadable, a directory, or a dangling symlink) — every gate refuses until it can"
        else
            _doctor_record "test-map" "warn" ".weave/test-map.conf absent — touched files classify 'unknown', gate inert even when on. See: wv guide --topic=verification"
        fi
    fi

    # 3b. provisioning mode (transition rule 5, wv-0ee3f4): how many routes the
    # newest gate records ran in checkout mode, a labelled transition state
    # until each is declared in .weave/gate-provision.json. Read from wv analyze
    # gates, the one place the gate log is aggregated.
    local prov
    if prov=$(cmd_analyze_gates --json 2>/dev/null | jq -c '.provisioning // empty' 2>/dev/null) && [ -n "$prov" ]; then
        if [ "$(jq -r '.gates_recorded' <<< "$prov")" = "0" ]; then
            _doctor_record "gate provisioning" "pass" "no gate record carries per-route modes yet"
        else
            _doctor_record "gate provisioning" "pass" "$(jq -r '"\(.routes) route(s): \(.frozen) frozen, \(.checkout) in checkout mode"
                + (if .checkout > 0 then " (\(.checkout_routes[:3] | join(", "))\(if .checkout > 3 then ", ..." else "" end)); declare them in .weave/gate-provision.json to run frozen" else "" end)' <<< "$prov")"
        fi
    fi

    # 4. ledger freshness — informational row count.
    local rows
    rows=$(sqlite3 "$WV_DB" "SELECT COUNT(*) FROM test_results;" 2>/dev/null)
    [ -z "$rows" ] && rows=0
    _doctor_record "test ledger" "pass" "$rows test_results row(s) recorded"
    return 0
}

cmd_doctor() {
    _dr_format="text"
    local _dr_repair=false
    local _dr_agent=false
    while [ $# -gt 0 ]; do
        case "$1" in
            --json)   _dr_format="json" ;;
            --repair) _dr_repair=true ;;
            --agent)  _dr_agent=true ;;
        esac
        shift
    done

    # Only --repair writes repository scaffolding; say so rather than leave the
    # ownership rule silent on every plain doctor (wv-15422b). Only the doctor
    # operation records it: ship-agent runs doctor in-process as a readiness
    # probe, where this rule is not the call's to decide.
    if [ "$_dr_repair" != "true" ] && [ "${_WV_ATTEMPT_OPERATION:-doctor}" = "doctor" ]; then
        wv_policy_verdict repository_write_requires_owned allow no "" "no repair requested, so nothing is written"
    fi
    if [ "$_dr_repair" = "true" ]; then
        local _dr_repo_root _dr_persistent_root
        _dr_repo_root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
        wv_repository_require_owned "$_dr_repo_root" "wv doctor --repair" || return 1
        if [ -n "${WEAVE_DIR:-}" ]; then
            _dr_persistent_root=$(dirname "$WEAVE_DIR")
            if [ -L "$WEAVE_DIR" ]; then
                echo "wv: refusing wv doctor --repair through symlinked Weave directory: $WEAVE_DIR" >&2
                return 1
            fi
            wv_repository_require_owned "$_dr_persistent_root" "wv doctor --repair" || return 1
        fi
    fi

    _dr_pass=0 _dr_fail=0 _dr_warn=0 _dr_total=0 _dr_results=""

    # Match the cold-start contract of graph commands. A committed state.sql is
    # the persistent authority after reboot or inside a fresh container; testing
    # the absent cache instead made Doctor's result depend on whether another wv
    # command happened to run first. Do not initialise an unconfigured repo here:
    # hydration is limited to a real committed snapshot and the default DB path.
    local _dr_hydration_failed=false
    if command -v sqlite3 >/dev/null 2>&1 &&
       [ -n "${WV_DB:-}" ] && [ ! -f "$WV_DB" ] &&
       [ -z "${WV_DB_CUSTOM:-}" ] && [ -f "$WEAVE_DIR/state.sql" ]; then
        db_ensure >/dev/null || _dr_hydration_failed=true
    fi

    [ "$_dr_format" = "text" ] && echo "Weave Doctor — Installation Health"

    if [ "$_dr_hydration_failed" = true ]; then
        _doctor_record "database hydration" "fail" \
            "could not restore the hot-zone database from .weave/state.sql"
    fi

    # Keep check order stable; helpers share this call's repair/format state
    # through Bash's dynamic scope (wv-813b05).
    _doctor_check_prerequisites
    _doctor_check_storage
    _doctor_check_repository_state
    _doctor_check_surfaces

    if [ "$_dr_agent" = true ]; then
        _doctor_check_agent_env
        _doctor_check_codex_mcp
        _doctor_check_codex_hooks
        _doctor_check_host_hooks
    fi

    # Summary
    if [ "$_dr_format" = "json" ]; then
        local overall="pass"
        [ "$_dr_fail" -gt 0 ] && overall="fail"
        printf '{"overall":"%s","passed":%d,"failed":%d,"warnings":%d,"total":%d,"checks":[%s]}\n' \
            "$overall" "$_dr_pass" "$_dr_fail" "$_dr_warn" "$_dr_total" "$_dr_results"
    else
        echo ""
        if [ "$_dr_fail" -gt 0 ]; then
            echo -e "Result: ${RED}${_dr_pass}/${_dr_total} passed${NC} (${_dr_fail} failed, ${_dr_warn} warnings)"
        elif [ "$_dr_warn" -gt 0 ]; then
            echo -e "Result: ${GREEN}${_dr_pass}/${_dr_total} passed${NC} (${_dr_warn} warnings)"
        else
            echo -e "Result: ${GREEN}${_dr_pass}/${_dr_total} passed${NC}"
        fi
    fi

    [ "$_dr_fail" -gt 0 ] && return 1
    return 0
}

_doctor_check_prerequisites() {
    # 1. sqlite3 present
    if command -v sqlite3 >/dev/null 2>&1; then
        local sq_ver
        sq_ver=$(sqlite3 --version 2>/dev/null | awk '{print $1}')
        _doctor_record "sqlite3" "pass" "$sq_ver"
        # 2. sqlite3 version >= 3.35
        local sq_major sq_minor
        sq_major=$(echo "$sq_ver" | cut -d. -f1)
        sq_minor=$(echo "$sq_ver" | cut -d. -f2)
        if [ "$sq_major" -gt 3 ] 2>/dev/null || { [ "$sq_major" -eq 3 ] && [ "$sq_minor" -ge 35 ]; } 2>/dev/null; then
            _doctor_record "sqlite3 version" "pass" ">= 3.35"
        else
            _doctor_record "sqlite3 version" "warn" "$sq_ver < 3.35"
        fi
        # 3. FTS5
        local fts5
        fts5=$(sqlite3 ":memory:" "SELECT sqlite_compileoption_used('ENABLE_FTS5');" 2>/dev/null || echo "0")
        if [ "$fts5" = "1" ]; then
            _doctor_record "FTS5" "pass" "available"
        else
            _doctor_record "FTS5" "warn" "not available"
        fi
    else
        _doctor_record "sqlite3" "fail" "not found"
    fi

    # 4. jq present
    if command -v jq >/dev/null 2>&1; then
        _doctor_record "jq" "pass" "$(jq --version 2>/dev/null)"
    else
        _doctor_record "jq" "fail" "not found"
    fi

    # 5. git present
    if command -v git >/dev/null 2>&1; then
        _doctor_record "git" "pass" "$(git --version 2>/dev/null | awk '{print $3}')"
    else
        _doctor_record "git" "fail" "not found"
    fi

    # 6. gh present (optional)
    if command -v gh >/dev/null 2>&1; then
        _doctor_record "gh" "pass" "$(gh --version 2>/dev/null | head -1 | awk '{print $3}')"
    else
        _doctor_record "gh" "warn" "not found (optional)"
    fi

    # 6b. ast-grep present (optional — enables structural_scan)
    if command -v ast-grep >/dev/null 2>&1; then
        local ag_ver
        local ag_path
        ag_path=$(command -v ast-grep)
        ag_ver=$(ast-grep --version 2>/dev/null | awk '{print $NF}')
        _doctor_record "structural_scan" "pass" "enabled (ast-grep $ag_ver at $ag_path)"
    else
        _doctor_record "structural_scan" "warn" "disabled (ast-grep not found — install manually or run ./install.sh --with-ast-grep)"
    fi

    return 0
}

_doctor_check_storage() {
    # 7. Hot zone exists
    local hot_zone="${WV_HOT_ZONE:-}"
    if [ -z "$hot_zone" ]; then
        hot_zone=$(resolve_hot_zone 2>/dev/null)
    fi
    local runtime_label
    runtime_label=$(resolve_runtime_label 2>/dev/null || echo "native")
    case "$runtime_label" in
        codex)
            _doctor_record "runtime" "pass" \
                "sandbox-agent — using /tmp hot zone because /dev/shm may not persist between tool calls"
            ;;
        container)
            _doctor_record "runtime" "pass" \
                "container — using /tmp hot zone by default"
            ;;
        *)
            _doctor_record "runtime" "pass" "native"
            ;;
    esac
    if [ -d "$hot_zone" ]; then
        # 8. Hot zone space
        local avail_kb
        avail_kb=$(df -k "$hot_zone" 2>/dev/null | awk 'NR==2 {print $4}')
        local avail_mb=$((avail_kb / 1024))
        if check_free_space "$hot_zone"; then
            _doctor_record "hot zone" "pass" "$hot_zone (${avail_mb}MB free)"
        else
            _doctor_record "hot zone" "warn" "$hot_zone (${avail_mb}MB free — low)"
        fi
        # 8b. Orphan hot-zone count (dirs with no matching .repo_root owner)
        _doctor_check_hot_zone_orphans "$hot_zone"
        # 8c. This repo's brain.db under a placement root it does not use
        _doctor_check_hot_zone_shadow "$hot_zone"
        # 8d. The /tmp zone's two names and which is physical
        _doctor_check_hot_zone_names
    else
        _doctor_record "hot zone" "fail" "not found: $hot_zone"
    fi

    # 8c. This owner's session phase file contains a known value (wv-43d6be)
    local _phase_file
    _phase_file=$(resolve_phase_file "$hot_zone") || true
    if [ -f "$_phase_file" ]; then
        local _phase_val
        _phase_val=$(cat "$_phase_file" 2>/dev/null | tr -d '[:space:]')
        local _phase_valid=false
        local _pv
        for _pv in ${PHASE_VALUES:-discover execute closing}; do
            [ "$_phase_val" = "$_pv" ] && _phase_valid=true && break
        done
        if [ "$_phase_valid" = true ]; then
            _doctor_record "session phase" "pass" "$_phase_val"
        else
            _doctor_record "session phase" "warn" "unknown value '$_phase_val' in .session_phase (expected: ${PHASE_VALUES:-discover execute closing})"
        fi
    fi

    # 9-10. Database accessible + integrity
    if [ -n "${WV_DB:-}" ] && [ -f "$WV_DB" ]; then
        local db_test
        db_test=$(sqlite3 "$WV_DB" "SELECT 1;" 2>/dev/null)
        if [ "$db_test" = "1" ]; then
            local integrity
            integrity=$(sqlite3 "$WV_DB" "PRAGMA integrity_check;" 2>/dev/null)
            if [ "$integrity" = "ok" ]; then
                _doctor_record "database" "pass" "accessible, integrity OK"
            else
                _doctor_record "database" "fail" "integrity check failed"
            fi
        else
            _doctor_record "database" "fail" "not accessible"
        fi
    else
        _doctor_record "database" "warn" "no active database"
    fi

    # 10a. Writer-lineage schema shape.
    #
    # PRAGMA integrity_check validates the pages against themselves; it says
    # nothing about whether the columns the delta writer needs are there. During
    # the rc.11 consumer outage (wv-e1556b) this command reported "database:
    # accessible, integrity OK" and passed 35 of 38 checks while every wv sync
    # aborted on `no such column: lineage_seq` — nodes was migrated, edges was
    # not, and nothing here looked. Shape is asked of db_lineage_shape, the same
    # classifier db_migrate_lineage repairs from, so doctor and the migration
    # cannot disagree about the database in front of them.
    if [ -n "${WV_DB:-}" ] && [ -f "$WV_DB" ]; then
        local _lin_nodes _lin_edges
        _lin_nodes=$(db_lineage_shape nodes)
        _lin_edges=$(db_lineage_shape edges)
        # One verdict for the pair, from the same classifier the migration uses.
        # Reading the two shapes independently — an `||` on no-table — passed a
        # database whose nodes were canonical and whose edges did not exist,
        # while sync aborted and commit-refs could not persist. A table that has
        # not been created is benign only when neither has.
        case "$(db_lineage_pair_verdict "$_lin_nodes" "$_lin_edges")" in
        canonical)
            _doctor_record "lineage schema" "pass" "nodes and edges carry (lineage_actor, lineage_seq)"
            ;;
        preinit)
            _doctor_record "lineage schema" "warn" "graph tables not created yet (nodes=$_lin_nodes, edges=$_lin_edges)"
            ;;
        *)
            _doctor_record "lineage schema" "fail" "nodes=$_lin_nodes, edges=$_lin_edges — sync and commit-refs cannot persist; recover with: rm -rf \"\$WV_HOT_ZONE\" && wv load"
            ;;
        esac
    fi

    # 10a. The last graph load was acknowledged (wv-2f55dd).
    _doctor_check_graph_load

    # 10a'. Delta v2 catalog integrity.
    _doctor_check_delta_v2_catalog

    # 10b. FTS5 index integrity.
    #
    # rank=1 compares the external-content index WITH nodes, detecting missing
    # entries as well as stale ones (wv-ccd364). The plain self-check passed
    # both missing-entry and orphan incidents. Keep the orphan probe to name
    # the stranded-rowid class caused by INSERT OR REPLACE (wv-d2e6c6).
    if [ -n "${WV_DB:-}" ] && [ -f "$WV_DB" ]; then
        local fts5_ok fts5_orphans fts5_rc=0
        fts5_ok=$(sqlite3 "$WV_DB" \
            "INSERT INTO nodes_fts(nodes_fts,rank) VALUES('integrity-check',1);" 2>&1) || fts5_rc=$?
        fts5_orphans=$(sqlite3 "$WV_DB" \
            "CREATE VIRTUAL TABLE temp.wv_fv USING fts5vocab(main, nodes_fts, instance);
             SELECT count(DISTINCT doc) FROM temp.wv_fv
             WHERE doc NOT IN (SELECT rowid FROM nodes);" 2>/dev/null || echo "")
        [ -n "$fts5_orphans" ] || fts5_orphans=0
        if [ "$fts5_rc" -eq 0 ] && [ -z "$fts5_ok" ] && [ "$fts5_orphans" -eq 0 ] 2>/dev/null; then
            _doctor_record "FTS5 index" "pass" "integrity OK; index agrees with node content"
        else
            local _fts5_why="corrupt or inconsistent with node content"
            [ "$fts5_orphans" -gt 0 ] 2>/dev/null \
                && _fts5_why="${fts5_orphans} orphaned index entries (rowids with no node)"
            if [ "$_dr_repair" = "true" ]; then
                # 'rebuild' re-derives from nodes for an external-content table,
                # so it discards orphans outright.
                sqlite3 "$WV_DB" \
                    "INSERT INTO nodes_fts(nodes_fts) VALUES('rebuild');" 2>/dev/null
                local fts5_recheck fts5_orphans_recheck fts5_recheck_rc=0
                fts5_recheck=$(sqlite3 "$WV_DB" \
                    "INSERT INTO nodes_fts(nodes_fts,rank) VALUES('integrity-check',1);" 2>&1) || fts5_recheck_rc=$?
                fts5_orphans_recheck=$(sqlite3 "$WV_DB" \
                    "CREATE VIRTUAL TABLE temp.wv_fv2 USING fts5vocab(main, nodes_fts, instance);
                     SELECT count(DISTINCT doc) FROM temp.wv_fv2
                     WHERE doc NOT IN (SELECT rowid FROM nodes);" 2>/dev/null || echo "")
                [ -n "$fts5_orphans_recheck" ] || fts5_orphans_recheck=0
                if [ "$fts5_recheck_rc" -eq 0 ] && [ -z "$fts5_recheck" ] && [ "$fts5_orphans_recheck" -eq 0 ] 2>/dev/null; then
                    _doctor_record "FTS5 index" "pass" "repaired (rebuilt)"
                else
                    _doctor_record "FTS5 index" "fail" "repair failed — manual: wv reindex"
                fi
            else
                _doctor_record "FTS5 index" "fail" "${_fts5_why} — run: wv doctor --repair"
            fi
        fi
    fi

    # 10c. FTS5 learning-index integrity (wv-ddb359: nodes_learning_fts is a
    # separate FTS5 table from nodes_fts, checked in 10b -- a corruption
    # confined to it is otherwise invisible to both PRAGMA integrity_check
    # and 10b's nodes_fts-only check. Repair is DROP + recreate, not
    # 'rebuild': nodes_learning_fts owns its content in its own shadow
    # table (unlike nodes_fts's content=nodes), so 'rebuild' would only
    # re-derive the index FROM that shadow table and preserve any
    # corruption living there. See db_reindex_fts5.
    if [ -n "${WV_DB:-}" ] && [ -f "$WV_DB" ]; then
        local learning_fts5_available
        learning_fts5_available=$(sqlite3 "$WV_DB" \
            "SELECT sqlite_compileoption_used('ENABLE_FTS5');" 2>/dev/null || echo "0")
        if [ "$learning_fts5_available" = "1" ]; then
            local learning_table_exists learning_fts_ok
            learning_table_exists=$(sqlite3 "$WV_DB" \
                "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='nodes_learning_fts';" 2>/dev/null)
            if [ "$learning_table_exists" = "1" ]; then
                learning_fts_ok=$(sqlite3 "$WV_DB" \
                    "INSERT INTO nodes_learning_fts(nodes_learning_fts) VALUES('integrity-check');" 2>&1)
            else
                # A missing table is itself the failure signal here (db_ensure
                # keeps it present via db_migrate_fts5_learning's CREATE IF NOT
                # EXISTS) -- not a reason to skip the check, or the exact
                # dropped-table corruption class this check exists for goes
                # undetected.
                learning_fts_ok="missing: nodes_learning_fts table does not exist"
            fi
            if [ -z "$learning_fts_ok" ]; then
                _doctor_record "FTS5 learning index" "pass" "integrity OK"
            else
                if [ "$_dr_repair" = "true" ]; then
                    sqlite3 "$WV_DB" "DROP TABLE IF EXISTS nodes_learning_fts;" 2>/dev/null
                    db_migrate_fts5_learning
                    local learning_recheck
                    learning_recheck=$(sqlite3 "$WV_DB" \
                        "INSERT INTO nodes_learning_fts(nodes_learning_fts) VALUES('integrity-check');" 2>&1)
                    if [ -z "$learning_recheck" ]; then
                        _doctor_record "FTS5 learning index" "pass" "repaired (dropped + rebuilt)"
                    else
                        _doctor_record "FTS5 learning index" "fail" "repair failed — manual: wv reindex"
                    fi
                else
                    _doctor_record "FTS5 learning index" "fail" "corrupt or missing — run: wv doctor --repair"
                fi
            fi
        fi
    fi

    return 0
}

# _hook_common_named <file> — the file exists and one of its executable lines
# (not a comment) names wv-hook-common. One process: grep -v | grep -q under
# pipefail reads a long file's early match as failure, the writer taking SIGPIPE.
_hook_common_named() { # predicate
    [ -f "$1" ] && awk '!/^[[:space:]]*#/ && /wv-hook-common/ { found = 1; exit } END { exit !found }' "$1"
}

# _hook_common_unwired <project-root> — the required Claude Code hooks that do
# not load wv-hook-common, one path per line, relative to the root. A hook
# passes when an executable line names it, or when the hook sources a library
# whose executable lines do: since cf8ff1425 the lifecycle and tool-use hooks
# are thin adapters and their library loads it (owner ruling on wv-b80a86). A
# library resolves as the adapters resolve it: ../lib beside the hook, the
# checkout's scripts/lib, then the installed ~/.config/weave/lib. Comments do
# not count; pre-action.sh passed on one before. Shared by wv doctor and
# pattern-audit Check 4.
_hook_common_unwired() {
    local root="$1" rel hook lib dir
    for rel in .claude/hooks/pre-action.sh .claude/hooks/session-start-context.sh \
        .claude/hooks/session-end-sync.sh .claude/hooks/stop-check.sh \
        .claude/hooks/pre-compact-context.sh .claude/hooks/wv-touched-files.sh \
        .claude/hooks/context-guard.sh; do
        hook="$root/$rel"
        _hook_common_named "$hook" && continue
        if [ -f "$hook" ]; then
            for lib in $(grep -v '^[[:space:]]*#' "$hook" \
                | grep -E '(^|[[:space:];&|])(\.|source)[[:space:]]' \
                | grep -oE 'wv-[a-z0-9-]+\.sh' | sort -u); do
                for dir in "${hook%/*}/../lib" "$root/scripts/lib" "${HOME}/.config/weave/lib"; do
                    [ -r "$dir/$lib" ] || continue
                    _hook_common_named "$dir/$lib" && continue 3
                    break
                done
            done
        fi
        echo "$rel"
    done
}

_doctor_check_repository_state() {
    # Ownership is the resolved identity (session-qualified where the harness
    # carries a session id, wv-99978b). Other sessions and actors may be
    # working legitimately; even --repair must leave their claims untouched.
    local claim_actor claim_rows
    claim_actor=$(resolve_agent_id)
    if [ ! -f "${WV_DB:-}" ]; then
        _doctor_record "claim ownership" "warn" "current actor: $claim_actor; unavailable: no active database"
    elif ! claim_rows=$(db_query "SELECT id || ': ' || json_extract(metadata, '$.claimed_by')
        FROM nodes WHERE status='active'
        AND COALESCE(json_extract(metadata, '$.claimed_by'), '') != ''
        AND json_extract(metadata, '$.claimed_by') != '$(sql_escape "$claim_actor")'
        ORDER BY id;" 2>/dev/null); then
        _doctor_record "claim ownership" "warn" "current actor: $claim_actor; unavailable: active claim query failed"
    elif [ -n "$claim_rows" ]; then
        _doctor_record "claim ownership" "warn" "current actor: $claim_actor; active claims held by other actors (advisory):
$claim_rows
Inspect before explicitly authorizing per-node takeover with wv work ID --force; reservations still apply. No claims migrated."
    else
        _doctor_record "claim ownership" "pass" "current actor: $claim_actor; no active claims held by other actors"
    fi

    # 11-12. Module checks
    # Derived, not typed (wv-587469): the typed lists named 12 libraries and 5
    # of the 10 command modules, so a missing findings/analyze/indexer/query/hook
    # module, wv-gate-pool.sh or wv-checkpoint-ci.sh passed.
    _doctor_check_lib_refs "lib modules"
    _doctor_check_cmd_defs "cmd modules"

    # S0 provisioning advisory: inspect literals, never execute routed scripts.
    local gate_paths
    if ! gate_paths=$(python3 -I "$WV_LIB_DIR/lib/wv-gate-paths.py" "$REPO_ROOT" 2>&1); then
        _doctor_record "gate ignored paths" "warn" "$gate_paths"
    elif [ -n "$gate_paths" ]; then
        _doctor_record "gate ignored paths" "warn" "$gate_paths"
    else
        _doctor_record "gate ignored paths" "pass" "no literal ignored-path references found; computed paths are not evaluated"
    fi

    # 12b. Hook-common wiring check (Sprint 1 pattern crystallization); the
    # rule is _hook_common_unwired's, shared with pattern-audit Check 4.
    local _doctor_hooks_total=7
    local _doctor_hooks_ok=0
    local _doctor_hooks_missing=""
    local _doctor_project_root
    _doctor_project_root=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
    if [ -n "$_doctor_project_root" ] && [ -d "$_doctor_project_root/.claude/hooks" ]; then
        local _doctor_unwired
        _doctor_unwired=$(_hook_common_unwired "$_doctor_project_root")
        _doctor_hooks_ok=$((_doctor_hooks_total - $(grep -c . <<< "$_doctor_unwired")))
        _doctor_hooks_missing=$(paste -sd, - <<< "$_doctor_unwired" | sed 's/,/, /g')
        if [ "$_doctor_hooks_ok" -eq "$_doctor_hooks_total" ]; then
            _doctor_record "hook-common wiring" "pass" "$_doctor_hooks_ok/$_doctor_hooks_total hooks source wv-hook-common.sh"
        else
            _doctor_record "hook-common wiring" "warn" "$_doctor_hooks_ok/$_doctor_hooks_total hooks wired (missing: $_doctor_hooks_missing)"
        fi
    fi

    # 13. .weave dir
    if [ -d "${WEAVE_DIR:-}" ]; then
        _doctor_record ".weave" "pass" "present"
    else
        _doctor_record ".weave" "warn" "not found"
    fi

    # 14. Journal health: check for incomplete operations
    if journal_has_incomplete 2>/dev/null; then
        local journal_info
        journal_info=$(journal_recover --json 2>/dev/null || echo '{}')
        local journal_op
        journal_op=$(echo "$journal_info" | jq -r '.operation.op // "unknown"' 2>/dev/null)
        _doctor_record "journal" "warn" "incomplete '$journal_op' operation — run 'wv recover'"
    else
        _doctor_record "journal" "pass" "clean (no incomplete operations)"
    fi

    # 14-hooks. Lifecycle runs that started and never finished, and operations
    # wv work cleared as stale (wv-ca3ffe): both are failures nothing else reports.
    local _dr_hz _dr_unfinished _dr_cleared
    _dr_hz="${WV_HOT_ZONE:-$(dirname "${WV_DB:-/nonexistent/x}")}"
    _dr_unfinished=$( # a subshell: sourcing hook-common refreshes _HC_* state
        _lib="${WV_LIB_DIR:-$SCRIPT_DIR}/lib/wv-hook-common.sh"
        [ -f "$_lib" ] || _lib="$SCRIPT_DIR/lib/wv-hook-common.sh"
        # shellcheck source=/dev/null
        . "$_lib" >/dev/null 2>&1 && wv_hook_unfinished_runs "$_dr_hz" |
            awk '{printf "%s%s x%s", (NR > 1 ? ", " : ""), $1, $2}')
    if [ -n "$_dr_unfinished" ]; then
        _doctor_record "hook runs" "warn" "unfinished lifecycle runs in the last 7 days: $_dr_unfinished -- a host timeout or kill cut them short; compare wv doctor --agent hook budgets with how long the hook takes"
    else
        _doctor_record "hook runs" "pass" "every recorded lifecycle run in the last 7 days finished"
    fi
    _dr_cleared=$(awk -v since="$(( $(date +%s) - 604800 ))" '$1 >= since { n++ } END { print n + 0 }' \
        "$_dr_hz/cleared-ops.log" 2>/dev/null || echo 0)
    if [ "${_dr_cleared:-0}" -gt 0 ] 2>/dev/null; then
        _doctor_record "cleared operations" "warn" "wv work cleared $_dr_cleared unfinished operation(s) older than 30 min in the last 7 days (latest: $(tail -1 "$_dr_hz/cleared-ops.log" 2>/dev/null | awk '{print $2}')) -- they did not complete"
    fi

    # 14a. Node-state advisory: deferral-metadata-vs-status divergence. Per-install
    # mirror of pattern-audit Check 6 — a todo node carrying active deferral metadata
    # (deferred/blocked_until/blocked_on) with no non-done blocks edge, so status does
    # not reflect the deferral. A parked node (deferred with a deferred_reason) is a
    # todo state by design and is not counted (wv-5515e9). Both reports share
    # wv_deferral_divergent_sql. Advisory only.
    # See docs/PROPOSAL-graph-as-policy-boundary.md.
    if [ -f "${WV_DB:-}" ]; then
        local _deferred_ready
        _deferred_ready=$(db_query "
            SELECT COUNT(*) FROM nodes n WHERE $(wv_deferral_divergent_sql n);
        " 2>/dev/null || echo "0")
        if [ "${_deferred_ready:-0}" -gt 0 ] 2>/dev/null; then
            _doctor_record "node-state" "warn" "$_deferred_ready node(s) carry deferral metadata while status='todo' — status must reflect it; see 'wv pattern-audit' (Check 6); fix with status=blocked-external, a blocks edge, or park it with a deferred_reason"
        else
            _doctor_record "node-state" "pass" "no deferral-metadata-vs-status divergence"
        fi
        _doctor_check_edge_invariants
    fi

    # 14a-bis. Duplicate-authoritative-memory risk: durable Claude/Codex harness
    # memory for this repo not represented in the graph (S5, generalized F1).
    _doctor_memory_authority
    # Memory budget and expiry (wv-986c3d): wv-cmd-graduate.sh loads only when
    # the graph holds an active memory.
    [ -z "$( [ -f "${WV_DB:-}" ] && db_query "SELECT 1 FROM nodes WHERE $(wv_kind_sql) = 'memory'
        AND COALESCE(json_extract(metadata,'\$.mem_status'),'active') = 'active' LIMIT 1;" 2>/dev/null)" ] \
        || _doctor_memory_budget

    # 14a-quinquies. Can this install report which fixes it carries?
    _doctor_install_provenance

    # 14a-quater. Commit-provenance drift: SHAs recorded on nodes that no ref
    # reaches any more (amended/reset/rebased/gc'd) -- wv-55d2de.
    _doctor_commit_refs

    # 14a-sexies. A credential already in graph text, from before the write
    # paths refused one or from a raw write (wv-320587).
    _doctor_graph_credentials

    # 14a-ter. Managed pattern-rule shadow advisory: mirrors 'wv quality
    # patterns list' own warning (a project-local custom rule sharing a
    # managed rule's id, silently never applied -- see
    # scripts/weave_quality/__main__.py's _shadowed_managed_pattern_ids)
    # without re-deriving the detection logic here (wv-3a0a40) -- invokes
    # the SAME Python entry point patterns list itself uses
    # (_wv_quality_python, sourced from wv-cmd-quality.sh) and captures
    # its own stderr, where that command already prints the warning
    # unconditionally in both --json and text mode. Gated on the
    # .overridden marker file's own existence first (cheap short-circuit
    # -- _shadowed_managed_pattern_ids returns immediately without it
    # too, but this also skips the rule-load work entirely on a repo with
    # no managed-pattern reconcile history at all). Advisory only.
    if [ -f "${WEAVE_DIR:-}/patterns/managed/.overridden" ]; then
        local -a _shadow_py_args=()
        [ -n "$WV_HOT_ZONE" ] && _shadow_py_args+=("--hot-zone" "$WV_HOT_ZONE")
        _shadow_py_args+=("patterns" "list" "--json")
        # Capture ONLY stderr (2>&1 duplicates fd2 into the command-
        # substitution's own capture pipe BEFORE >/dev/null retargets fd1
        # away from it -- no external pipe to grep involved, so $? below
        # is _wv_quality_python's own exit status, not a pipeline tail's
        # (see feedback_pipe_masks_exit_code) -- capturing an unpiped
        # status is exactly why this doesn't reuse the piped form the
        # first version of this check had.
        local _shadow_stderr
        _shadow_stderr=$(_wv_quality_python "${_shadow_py_args[@]}" 2>&1 >/dev/null)
        local _shadow_status=$?
        if [ "$_shadow_status" -ne 0 ]; then
            # wv-92ca0e: a failed delegate means shadowing was never
            # actually evaluated -- never report pass for an unevaluated
            # check (e.g. a malformed local rule breaks patterns list
            # entirely, well before it would even reach shadow detection).
            _doctor_record "pattern-shadow" "warn" "could not evaluate managed-rule shadowing -- 'wv quality patterns list' failed (exit $_shadow_status); run it directly for detail"
        elif grep -q "shadows an available" <<< "$_shadow_stderr"; then
            local _shadow_count
            _shadow_count=$(echo "$_shadow_stderr" | grep -c "shadows an available")
            _doctor_record "pattern-shadow" "warn" "$_shadow_count managed rule(s) shadowed by a local copy — run 'wv quality patterns list' for detail"
        else
            _doctor_record "pattern-shadow" "pass" "no managed-rule shadowing detected"
        fi
    fi

    # 14a-ter-bis. Managed pattern-rule completeness (wv-8d16bd, external
    # code review round 3 re-audit): a manifest id whose file exists in
    # NEITHER tier (managed/ nor the project-local override) is not
    # shadowed, it is MISSING -- exactly the state left behind by deleting
    # a shadowing local copy without rerunning 'wv init-repo --update'
    # afterward (24 rules -> 23 in the reported audit). The pattern-shadow
    # check above only re-derives cmd_patterns_list's OWN warning, which
    # stops firing entirely once the id drops out of active_ids -- it
    # would report a false "pass" for a rule that quietly vanished.
    # Checked against the union of .overridden (shadowed ids) and
    # .manifest (currently-synced ids) -- every id either reconcile has
    # ever placed or knowingly skipped; both already store the bare
    # "<id>.yaml" filename.
    if [ -f "${WEAVE_DIR:-}/patterns/managed/.overridden" ] || [ -f "${WEAVE_DIR:-}/patterns/managed/.manifest" ]; then
        local _mc_missing="" _mc_id
        while IFS= read -r _mc_id; do
            [ -z "$_mc_id" ] && continue
            if [ ! -f "${WEAVE_DIR:-}/patterns/managed/$_mc_id" ] && [ ! -f "${WEAVE_DIR:-}/patterns/$_mc_id" ]; then
                _mc_missing="${_mc_missing:+$_mc_missing, }${_mc_id%.yaml}"
            fi
        done < <(cat "${WEAVE_DIR:-}/patterns/managed/.overridden" "${WEAVE_DIR:-}/patterns/managed/.manifest" 2>/dev/null | sort -u)
        if [ -n "$_mc_missing" ]; then
            _doctor_record "managed-pattern-completeness" "warn" "manifest id(s) missing from BOTH the managed and custom tiers (deleted without a resync?): $_mc_missing — run 'wv init-repo --update'"
        else
            _doctor_record "managed-pattern-completeness" "pass" "every known managed-pattern id resolves in one tier"
        fi
    fi

    # 14a-quinquies. Coaching guide advisories, mirroring the managed-pattern
    # family above. A project override under .weave/guides/ outranks the package
    # guide of the same id, so a stale override silently outranks an improved one
    # indefinitely -- the same failure the pattern-shadow record exists to surface.
    if [ -d "${WEAVE_DIR:-}/guides" ]; then
        local _gs_shadowed="" _gs_file _gs_name _gs_pkg
        _gs_pkg="$(_wv_python_module_path weave_quality 2>/dev/null)/weave_quality/guides"
        for _gs_file in "${WEAVE_DIR:-}"/guides/*.md; do
            [ -f "$_gs_file" ] || continue
            _gs_name="$(basename "$_gs_file")"
            [ -f "$_gs_pkg/$_gs_name" ] || continue
            _gs_shadowed="${_gs_shadowed:+$_gs_shadowed, }${_gs_name%.md}"
        done
        if [ -n "$_gs_shadowed" ]; then
            _doctor_record "guide-shadow" "warn" "project guide(s) shadowing a package guide of the same id: $_gs_shadowed — confirm the override is still wanted"
        else
            _doctor_record "guide-shadow" "pass" "no project guide is shadowing a package guide"
        fi
    fi

    # Guide validity and coaching completeness (wv-7730bd), computed by the
    # shipped parser and resolver ('python3 -m weave_quality.guides doctor') from
    # the module copy coaching selects, against this project's root -- never a
    # second validator in shell. Validity (every .weave/guides/*.md parses and
    # resolves where it is selected) is recorded apart from guide-shadow, a
    # preference, and from completeness, the canonical types that coach only
    # through _uncoached. Both records fail closed: a nonzero exit, output that
    # is not a complete report, or a report from a module copy other than the
    # one selected is a failed check, never a skipped one. Complete means every
    # entry has its shape too, and the verdicts come from the arrays' lengths:
    # judged by the rendered names, invalid:[{}] or fallback_only:[null]
    # rendered nothing and both records passed (wv-13dec1).
    local _gd_pypath _gd_out _gd_rc=0 _gd_err="" _gd_want _gd_got
    _gd_pypath="$(_wv_python_module_path weave_quality 2>/dev/null)"
    _gd_out=$(_wv_agent_python_exec_module weave_quality.guides "$_gd_pypath" \
        doctor --project-root "$REPO_ROOT" 2>/dev/null) || _gd_rc=$?
    if [ "$_gd_rc" -ne 0 ]; then
        _gd_err="guides doctor exited $_gd_rc: $(printf '%s' "$_gd_out" | jq -r '.error // "no error reported"' 2>/dev/null || printf 'no error reported')"
    elif ! printf '%s' "$_gd_out" | jq -e '
            def str: type == "string" and length > 0;
            def count: type == "number" and . >= 0 and . == floor;
            (.canonical_types | count) and .canonical_types > 0
            and (.project_guides_checked | count)
            and (.invalid | type == "array"
                and all(.[]; type == "object" and (.file | str) and (.error | str)
                    and (.errors | type == "array" and length > 0 and all(.[]; str))))
            and (.unresolved | type == "array"
                and all(.[]; type == "object" and (.violation_type | str)
                    and (.language == null or (.language | str)) and (.error | str)))
            and all(.unused, .examples, .fallback_only; type == "array" and all(.[]; str))
            and (.module | str)' >/dev/null 2>&1; then
        _gd_err="guides doctor printed no complete report"
    else
        _gd_want=$(readlink -f "$_gd_pypath/weave_quality/guides.py" 2>/dev/null || true)
        _gd_got=$(printf '%s' "$_gd_out" | jq -r '.module')
        [ -n "$_gd_want" ] && [ "$_gd_got" = "$_gd_want" ] \
            || _gd_err="guides doctor ran $_gd_got, not the selected copy ${_gd_want:-(unresolved under $_gd_pypath)}"
    fi
    local _gd_bad _gd_unused _gd_n _gd_canon _gd_fallback _gd_dead _gd_counts
    local _gd_nbad _gd_nunused _gd_nfallback
    if [ -z "$_gd_err" ]; then
        # One read, checked: a failed extraction is a failed check, not a
        # zero count.
        _gd_counts=$(printf '%s' "$_gd_out" | jq -r '[(.invalid | length) + (.unresolved | length),
            (.unused | length), (.fallback_only | length),
            ([.unresolved[] | select(.language == null)] | length),
            .project_guides_checked, .canonical_types] | @tsv' 2>/dev/null) \
            && read -r _gd_nbad _gd_nunused _gd_nfallback _gd_dead _gd_n _gd_canon <<< "$_gd_counts" \
            && [ -n "$_gd_canon" ] \
            || _gd_err="guides doctor report could not be read"
    fi
    if [ -n "$_gd_err" ]; then
        _doctor_record "guide-validity" "fail" "$_gd_err"
        _doctor_record "guide-completeness" "fail" "not computed: $_gd_err"
    else
        # Each failure carries the parser's own error, which names the field or
        # section. A list of file names alone left a consumer whose pre-rc.14
        # guide failed with nothing to fix (wv-ba21bd), and every violation in
        # the file, not the first: one fault per run cost a consumer three
        # runs on one guide (wv-273b2d).
        _gd_bad=$(printf '%s' "$_gd_out" | jq -r '[(.invalid[] | .file as $f
                | .errors[] | if startswith($f + ":") then . else $f + ": " + . end),
            (.unresolved[] | .violation_type + (if .language then " (" + .language + ")" else "" end)
                + ": " + .error)] | join("; ")')
        _gd_unused=$(printf '%s' "$_gd_out" | jq -r '.unused | join(", ")')
        if [ "$_gd_nbad" -gt 0 ]; then
            _doctor_record "guide-validity" "fail" "coaching would fail for: $_gd_bad — fix the named field or section, or remove the guide (format: .weave/guides.README.md)"
        elif [ "$_gd_nunused" -gt 0 ]; then
            _doctor_record "guide-validity" "warn" "project guide(s) no catalogued type selects: $_gd_unused — rename to the vocabulary's guide basename or remove"
        else
            _doctor_record "guide-validity" "pass" "$_gd_n project guide(s) checked; each parses and resolves where it is selected"
        fi
        _gd_fallback=$(printf '%s' "$_gd_out" | jq -r '.fallback_only | join(", ")')
        if [ "$_gd_dead" -gt 0 ]; then
            _doctor_record "guide-completeness" "fail" "$_gd_dead of $_gd_canon canonical violation type(s) resolve to no guide (see guide-validity)"
        elif [ "$_gd_nfallback" -gt 0 ]; then
            _doctor_record "guide-completeness" "warn" "canonical violation type(s) coaching only through the _uncoached fallback: $_gd_fallback"
        else
            _doctor_record "guide-completeness" "pass" "all $_gd_canon canonical violation types coach through a guide of their own"
        fi
    fi

    # 14a-quater. Procedure visibility semantic-drift advisory: local is the
    # safe default, but a local procedure that documents the installed `wv`
    # command may actually describe consumer behavior and warrants periodic
    # review for promotion to shared. Scan body content only so the required
    # frontmatter fallback (`wv guide --procedure=...`) does not self-match.
    # Repository-development invocations (`./scripts/wv`) are intentionally
    # excluded. Advisory only.
    local _pv_drift
    _pv_drift=$(_doctor_local_procedure_command_refs "${WV_CONFIG_DIR:-$HOME/.config/weave}/procedures")
    if [ -n "$_pv_drift" ]; then
        _doctor_record "procedure-visibility" "warn" "local procedure(s) reference consumer wv commands: $_pv_drift — review visibility: shared"
    else
        _doctor_record "procedure-visibility" "pass" "no local procedures reference consumer wv commands"
    fi
    # Repository-owned procedures (wv-fc71f0): wv-cmd-procedures.sh loads only
    # when the repository has some, which keeps its narrow routes sound. A
    # repository without any still has the package procedures projected; that
    # comparison lives here, in the doctor module (wv-5505c2).
    if compgen -G "${REPO_ROOT:-/nonexistent}/.weave/procedures/*.md" >/dev/null; then
        _doctor_repo_procedures "$REPO_ROOT"
    elif [ -n "${REPO_ROOT:-}" ]; then
        _doctor_package_projections "$REPO_ROOT"
    fi

    # 14a-quinquies. Closed-node uncommitted dirt attribution (wv-e48993):
    # pre-close-verification.sh now scopes its blocking check to the closing
    # node's OWN touched_files, so genuinely foreign dirt no longer blocks
    # `wv done` (and is no longer misattributed under the wrong node's
    # Weave-ID). That fixed the false-block/misattribution bug, but it also
    # means a session can close every node it owns and still leave real work
    # uncommitted with nothing reporting it afterward -- this check closes
    # that gap. Advisory only; attributes current non-.weave dirt to the
    # most recently closed node whose touched_files overlaps it, when one
    # exists.
    local _cd_dirty
    # --no-renames (wv-b96ada): a staged rename lists only its new path, so the
    # old path - the one a closed node touched - never reached attribution.
    _cd_dirty=$(
        {
            git diff --no-renames --name-only 2>/dev/null
            git diff --no-renames --cached --name-only 2>/dev/null
            git ls-files --others --exclude-standard 2>/dev/null
        } | sort -u | grep -v '^$' \
          | grep -v '^\.weave/' \
          | grep -v '^\.claude/hooks/' \
          | grep -v '^\.claude/skills/' \
          | grep -v '^\.claude/agents/' || true
    )
    if [ -z "$_cd_dirty" ]; then
        _doctor_record "closed-node-dirt" "pass" "no uncommitted non-.weave files"
    else
        local _cd_count _cd_active_owned _cd_remainder _cd_remainder_count
        local _cd_done_owned _cd_done_remainder _cd_unattributed
        _cd_count=$(echo "$_cd_dirty" | grep -c .)
        # wv-822bea/wv-950080 (distribution re-audit): the prior "stop at the
        # first candidate node whose touched_files overlaps ANY dirty path"
        # logic false-passed a mixed dirty set (e.g. one file explained by an
        # active node, a second file that is genuinely done-owned or
        # unattributed) as soon as the active node matched, without ever
        # looking at whether it explained the REST of the dirt. It also used
        # `grep -Ff` (substring) rather than exact path equality, so
        # ownership of "foo" could wrongly explain "foo.txt". Fixed: build
        # the full set of paths owned by ANY currently-active node (union of
        # the uncapped node_files table and the capped metadata.touched_files
        # display copy, exact-line matched via comm), subtract that from the
        # dirty set, and only classify what's LEFT — never short-circuit on
        # the first match.
        _cd_active_owned=$(db_query "
            SELECT nf.path FROM node_files nf JOIN nodes n ON n.id = nf.node_id WHERE n.status='active'
            UNION
            SELECT je.value FROM nodes n, json_each(COALESCE(json_extract(n.metadata,'\$.touched_files'), '[]')) je WHERE n.status='active';
        " 2>/dev/null | sort -u)
        _cd_remainder=$(comm -23 <(printf '%s\n' "$_cd_dirty" | sort -u) <(printf '%s\n' "$_cd_active_owned" | sort -u))
        if [ -z "$_cd_remainder" ]; then
            _doctor_record "closed-node-dirt" "pass" "all $_cd_count uncommitted non-.weave file(s) explained by currently active node(s) own work"
        else
            _cd_remainder_count=$(echo "$_cd_remainder" | grep -c .)
            _cd_done_owned=$(db_query "
                SELECT nf.path FROM node_files nf JOIN nodes n ON n.id = nf.node_id WHERE n.status='done'
                UNION
                SELECT je.value FROM nodes n, json_each(COALESCE(json_extract(n.metadata,'\$.touched_files'), '[]')) je WHERE n.status='done';
            " 2>/dev/null | sort -u)
            _cd_done_remainder=$(comm -12 <(printf '%s\n' "$_cd_remainder" | sort -u) <(printf '%s\n' "$_cd_done_owned" | sort -u))
            _cd_unattributed=$(comm -23 <(printf '%s\n' "$_cd_remainder" | sort -u) <(printf '%s\n' "$_cd_done_owned" | sort -u))
            if [ -n "$_cd_done_remainder" ] && [ -n "$_cd_unattributed" ]; then
                _doctor_record "closed-node-dirt" "warn" "$_cd_remainder_count non-.weave file(s) uncommitted beyond any active node's own work: $(echo "$_cd_done_remainder" | grep -c .) likely from already-closed node(s) (touched_files/node_files overlap), $(echo "$_cd_unattributed" | grep -c .) with no clear owner — commit or discard"
            elif [ -n "$_cd_done_remainder" ]; then
                _doctor_record "closed-node-dirt" "warn" "$_cd_remainder_count non-.weave file(s) still uncommitted beyond any active node's own work, likely from already-closed node(s) (touched_files/node_files overlap) — commit or discard"
            else
                _doctor_record "closed-node-dirt" "warn" "$_cd_remainder_count non-.weave file(s) still uncommitted with no clear owner among active/done nodes — commit or discard"
            fi
        fi
    fi

    # 14b. Explicit git-state pending windows (.weave dirty / ahead of upstream)
    local git_pending_json git_sync_pending git_sync_state git_sync_action git_sync_reason git_sync_hint
    git_pending_json=$(_detect_git_pending 2>/dev/null || echo '{}')
    git_sync_pending=$(echo "$git_pending_json" | jq -r '.pending // false' 2>/dev/null || echo "false")
    git_sync_state=$(echo "$git_pending_json" | jq -r '.state // "clean"' 2>/dev/null || echo "clean")
    git_sync_action=$(echo "$git_pending_json" | jq -r '.action // "none"' 2>/dev/null || echo "none")
    git_sync_reason=$(echo "$git_pending_json" | jq -r '.reason // "clean"' 2>/dev/null || echo "clean")
    git_sync_hint=$(echo "$git_pending_json" | jq -r '.hint // "no action required"' 2>/dev/null || echo "no action required")
    if [ "$git_sync_pending" = "true" ]; then
        if [ "$git_sync_state" = "recoverable" ]; then
            _doctor_record "git sync" "warn" "$git_sync_action ($git_sync_reason) — $git_sync_hint"
        else
            _doctor_record "git sync" "warn" "$git_sync_state ($git_sync_reason) — $git_sync_hint"
        fi
    else
        _doctor_record "git sync" "pass" "clean"
    fi

    return 0
}

# _doctor_has_managed_projection <root> — a surface of ROOT carries a projection
# Weave manages (a managed Claude skill, a managed Codex entry, or the procedures
# block in AGENTS.md or copilot-instructions). Only those surfaces are compared,
# so a harness the repository never set up is not reported.
_doctor_has_managed_projection() {
    local root="$1"
    grep -rqsF -- 'WEAVE-MANAGED-SKILL' "$root/.claude/skills" && return 0
    grep -qsF 'BEGIN WEAVE PROCEDURES' "$root/AGENTS.md" "$root/.github/copilot-instructions.md" && return 0
    [ -f "$root/.codex/weave.json" ] \
        && jq -e '[.procedures[]? | select(.managed == true)] | length > 0' "$root/.codex/weave.json" >/dev/null 2>&1
}

# _doctor_projection_stale <root> <config_dir> — print the managed surfaces of
# ROOT whose projection differs from what the installed projector writes now,
# comma-separated (empty when current). The projector writes into a scratch copy
# of the surfaces, keeping the projection format in the projector alone. On a
# projector refusal, print its reason and return 1. Shared by the repository
# procedures check (wv-cmd-procedures.sh) and the package one below.
_doctor_projection_stale() {
    local root="$1" config_dir="$2" tmp rel out stale=""
    tmp=$(mktemp -d) || return 0
    for rel in .claude/skills .codex/weave.json .github/copilot-instructions.md AGENTS.md; do
        [ -e "$root/$rel" ] || continue
        mkdir -p "$tmp/$(dirname "$rel")"
        cp -a "$root/$rel" "$tmp/$rel"
    done
    if ! out=$("$config_dir/project-procedures.sh" --repo="$root" --out="$tmp" --agent=all 2>&1 >/dev/null); then
        rm -rf "$tmp"
        printf '%s' "$out" | head -2 | tr '\n' ' '
        return 1
    fi
    grep -rqsF -- 'WEAVE-MANAGED-SKILL' "$root/.claude/skills" \
        && ! diff -rq "$tmp/.claude/skills" "$root/.claude/skills" >/dev/null 2>&1 \
        && stale=".claude/skills"
    [ -f "$root/.codex/weave.json" ] \
        && jq -e '[.procedures[]? | select(.managed == true)] | length > 0' "$root/.codex/weave.json" >/dev/null 2>&1 \
        && ! cmp -s "$tmp/.codex/weave.json" "$root/.codex/weave.json" && stale="${stale:+$stale, }.codex/weave.json"
    for rel in .github/copilot-instructions.md AGENTS.md; do
        grep -qsF 'BEGIN WEAVE PROCEDURES' "$root/$rel" && ! cmp -s "$tmp/$rel" "$root/$rel" \
            && stale="${stale:+$stale, }$rel"
    done
    rm -rf "$tmp"
    printf '%s' "$stale"
}

# _doctor_package_projections <root> — in a repository with no procedures of its
# own (the usual consumer), whether the package procedures' projections are
# current (wv-5505c2). An install that changed a package procedure, with no
# wv init-repo --update after it, left the surfaces stale with doctor silent.
# Silent when nothing is projected; a projector refusal (an unverified repository
# class) is not reported, since the check cannot judge and nothing of the
# repository's own is at stake.
_doctor_package_projections() {
    local root="$1" config_dir="${WV_CONFIG_DIR:-$HOME/.config/weave}" stale
    _doctor_has_managed_projection "$root" || return 0
    if [ ! -x "$config_dir/project-procedures.sh" ]; then
        _doctor_record "procedure-projections" "fail" "procedure projector not installed in $config_dir — run ./install.sh"
        return 0
    fi
    stale=$(_doctor_projection_stale "$root" "$config_dir") || return 0
    if [ -n "$stale" ]; then
        _doctor_record "procedure-projections" "warn" "projection out of date in $stale — run: wv init-repo --update"
    else
        _doctor_record "procedure-projections" "pass" "package procedure projections current"
    fi
}

_doctor_check_surfaces() {
    # ── Surface-contract checks ──────────────────────────────────────────────

    # 15. Hook source vs installed drift: compare .claude/hooks/ with ~/.config/weave/hooks/
    local source_hooks_dir="${WEAVE_DIR:+$(dirname "$WEAVE_DIR")}/.claude/hooks"
    # Fallback: walk up from WV_LIB_DIR to find .claude/hooks
    if [ ! -d "$source_hooks_dir" ] && [ -n "${WV_LIB_DIR:-}" ]; then
        local candidate
        candidate=$(dirname "$WV_LIB_DIR")
        [ -d "$candidate/.claude/hooks" ] && source_hooks_dir="$candidate/.claude/hooks"
    fi
    local installed_hooks_dir="$HOME/.config/weave/hooks"
    if [ -d "$source_hooks_dir" ] && [ -d "$installed_hooks_dir" ]; then
        local drifted=""
        # Forward: repo-local hooks stale vs installed (catches wv self-update without init-repo --update)
        for src in "$source_hooks_dir"/*.sh; do
            local fname
            fname=$(basename "$src")
            local dst="$installed_hooks_dir/$fname"
            if [ ! -f "$dst" ]; then
                drifted="${drifted:+$drifted, }$fname (missing)"
            elif [ "$(md5sum "$src" 2>/dev/null | awk '{print $1}')" != "$(md5sum "$dst" 2>/dev/null | awk '{print $1}')" ]; then
                drifted="${drifted:+$drifted, }$fname (stale)"
            fi
        done
        # Reverse: new hooks in installed not yet in repo (added in a newer release)
        for dst in "$installed_hooks_dir"/*.sh; do
            local fname
            fname=$(basename "$dst")
            [ -f "$source_hooks_dir/$fname" ] || \
                drifted="${drifted:+$drifted, }$fname (new — not in repo)"
        done
        if [ -z "$drifted" ]; then
            _doctor_record "hook drift" "pass" "source and installed hooks match"
        else
            if [ "$_dr_repair" = "true" ]; then
                local _repaired=0
                for src in "$installed_hooks_dir"/*.sh; do
                    [ -f "$src" ] || continue
                    local _fname
                    _fname=$(basename "$src")
                    cp "$src" "$source_hooks_dir/$_fname" && _repaired=$((_repaired + 1))
                done
                _doctor_record "hook drift" "pass" "repaired ($_repaired hooks synced from ~/.config/weave/hooks/)"
            else
                _doctor_record "hook drift" "warn" "run: wv init-repo --update — drifted: $drifted"
            fi
        fi
    else
        _doctor_record "hook drift" "warn" "cannot compare — source or installed hooks dir missing"
    fi

    # 16. wv-runtime wrapper retired (S2) — standalone repo uses python -m weave_runtime
    _doctor_record "wv-runtime" "pass" "retired — use python -m weave_runtime (standalone repo)"

    # 17. Git commit hooks installed and match the repo-managed Weave versions
    local git_root
    git_root=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
    # Checked where git runs hooks from (wv-76c726): $git_root/.git/hooks is
    # wrong in a linked worktree (.git is a file) and under core.hooksPath.
    local _dr_hooks="" _dr_hooks_path=""
    if [ -n "$git_root" ]; then
        _dr_hooks=$(git -C "$git_root" rev-parse --git-path hooks 2>/dev/null || true)
        case "$_dr_hooks" in ""|/*) ;; *) _dr_hooks="$git_root/$_dr_hooks" ;; esac
        _dr_hooks_path=$(git -C "$git_root" config --get core.hooksPath 2>/dev/null || true)
        if [ -n "$_dr_hooks_path" ]; then
            _doctor_record "hooks path" "warn" "core.hooksPath=$_dr_hooks_path: git runs hooks only from there and install.sh does not write to it — call the Weave hooks from it"
        fi
    fi
    if [ -n "$git_root" ] && [ -n "$_dr_hooks" ]; then
        _doctor_check_git_hook \
            "pre-commit hook" \
            "$git_root/scripts/hooks/pre-commit-weave.sh" \
            "$_dr_hooks/pre-commit" \
            "Weave pre-commit" \
            "install -m 755 scripts/hooks/pre-commit-weave.sh $_dr_hooks/pre-commit"
        _doctor_check_hook_module "$git_root/scripts/hooks/pre-commit-recovery.sh" "$_dr_hooks"
        _doctor_check_git_hook \
            "prepare-commit-msg hook" \
            "$git_root/scripts/hooks/prepare-commit-msg-weave.sh" \
            "$_dr_hooks/prepare-commit-msg" \
            "Weave: append Weave-ID trailers" \
            "install -m 755 scripts/hooks/prepare-commit-msg-weave.sh $_dr_hooks/prepare-commit-msg"
        # post-commit was retired (wv-56c823): a Weave copy still installed runs
        # the dead deferred-suite queue on every commit. A custom hook is not ours.
        local _dr_pc_hook
        _dr_pc_hook="$_dr_hooks/post-commit"
        if [ -f "$_dr_pc_hook" ] && grep -qF "Weave post-commit" "$_dr_pc_hook" 2>/dev/null; then
            _doctor_record "post-commit hook" "warn" "retired Weave post-commit hook still installed — run ./install.sh (dev repo) or wv init-repo --update"
        fi
        # The heavy tier (wv-862ac0): without it installed, pre-commit runs the
        # [heavy] suites itself, so a missing copy is slow, not unsafe.
        _doctor_check_git_hook \
            "pre-push hook" \
            "$git_root/scripts/hooks/pre-push-weave.sh" \
            "$_dr_hooks/pre-push" \
            "Weave pre-push" \
            "install -m 755 scripts/hooks/pre-push-weave.sh $_dr_hooks/pre-push"
        # Binds a commit's publication to the tree pre-commit judged
        # (wv-5f9d1c): without it, pre-commit admission is check-then-use.
        _doctor_check_git_hook \
            "reference-transaction hook" \
            "$git_root/scripts/hooks/reference-transaction-weave.sh" \
            "$_dr_hooks/reference-transaction" \
            "Weave reference-transaction" \
            "install -m 755 scripts/hooks/reference-transaction-weave.sh $_dr_hooks/reference-transaction"
    fi

    # 18. Ghost settings: check for chat.hooks.enabled in .vscode/settings.json
    if [ -n "$git_root" ] && [ -f "$git_root/.vscode/settings.json" ]; then
        if grep -q '"chat.hooks.enabled"' "$git_root/.vscode/settings.json" 2>/dev/null; then
            _doctor_record "ghost settings" "warn" '.vscode/settings.json contains chat.hooks.enabled — may interfere with Claude Code hooks'
        else
            _doctor_record "ghost settings" "pass" "no known ghost settings detected"
        fi
    fi

    # 19. Claude settings hook matcher coverage (PreToolUse covers Edit/Write/Bash)
    local claude_settings="$HOME/.claude/settings.json"
    if [ -f "$claude_settings" ]; then
        local matcher
        matcher=$(jq -r '.hooks.PreToolUse[]? | select(.hooks[]?.command | contains("pre-action")) | .matcher // ""' "$claude_settings" 2>/dev/null | head -1)
        if [ -n "$matcher" ]; then
            local missing_tools=""
            for tool in Edit Write Bash; do
                grep -q -- "$tool" <<< "$matcher" || missing_tools="${missing_tools:+$missing_tools, }$tool"
            done
            if [ -z "$missing_tools" ]; then
                _doctor_record "hook matchers" "pass" "Edit, Write, Bash covered"
            else
                _doctor_record "hook matchers" "warn" "missing: $missing_tools — run ./install.sh"
            fi
        else
            _doctor_record "hook matchers" "warn" "pre-action hook not registered in ~/.claude/settings.json — run ./install.sh"
        fi
    fi

    # 20. Installed lib vs source drift (only when installed from a local git clone)
    _doctor_check_install_drift

    # 21. Active wv provenance vs recommended repo-local wrapper
    local _dr_repo_wv _dr_invoked_wv _dr_provenance _dr_canonical_wv
    _dr_repo_wv=$(_bootstrap_repo_wv_path)
    _dr_invoked_wv=$(_bootstrap_invoked_wv_path)
    _dr_canonical_wv=$(_bootstrap_canonical_wv_path)
    _dr_provenance=$(_bootstrap_wv_provenance "$_dr_invoked_wv")
    if [ -z "$_dr_canonical_wv" ]; then
        _doctor_record "wv provenance" "warn" "unable to resolve active wv command"
    elif [ -n "$_dr_repo_wv" ] && [ -x "$_dr_repo_wv" ] && [ -n "$_dr_invoked_wv" ] && [ "$_dr_repo_wv" != "$_dr_invoked_wv" ]; then
        _doctor_record "wv provenance" "warn" "invoked $_dr_invoked_wv ($_dr_provenance); repo-local wrapper available at $_dr_repo_wv"
    else
        _doctor_record "wv provenance" "pass" "$_dr_canonical_wv ($_dr_provenance)"
    fi

    # 22. Verification-gate layer (P6) — repo-scoped; no-op outside a repo.
    _doctor_check_verification

    return 0
}

# ═══════════════════════════════════════════════════════════════════════════
# cmd_pattern_audit — CI regression net for control-plane patterns
# Checks:
#   1. Every dispatch entry is in cache read, write, or exempt list.
#   2. Domain enum strings have exactly one definition (no silent drift).
#   3. No raw echo writes to .session_phase outside wv_set_phase.
#   4. Required Claude hooks source wv-hook-common.sh.
#   5. pre-action.sh stays a thin dispatcher (<= 60 lines).
#   6. Node-state invariant: no node declares deferral in metadata
#      (deferred/blocked_on) while still in the ready queue (todo + no
#      non-done blocks edge). See docs/PROPOSAL-graph-as-policy-boundary.md.
#   7. No non-predicate function ends in a bare `[ cond ] && cmd` tail.
#   8. Raw sqlite3 reads of quality.db stay inside blessed quality helpers.
# See docs/PROPOSAL-wv-pattern-crystallization.md for context.
# ═══════════════════════════════════════════════════════════════════════════

cmd_pattern_audit() {
    local format="text"
    local strict=0

    while [ $# -gt 0 ]; do
        case "$1" in
            --json)   format="json" ;;
            --strict) strict=1 ;;
            --help|-h)
                echo "Usage: wv pattern-audit [--json] [--strict]"
                echo ""
                echo "  --json    machine-readable output"
                echo "  --strict  exit 1 if any issues found (for CI use)"
                return 0 ;;
            *) echo -e "${RED}Unknown option: $1${NC}" >&2; return 1 ;;
        esac
        shift
    done

    local issues=0
    local findings_json="[]"

    # ── Check 1: capability registry totality ───────────────────────────────
    # Every command in the dispatch table must have a row in
    # contracts/command-capabilities.json, which _wv_cap_known projects. An
    # unclassified command is a latent cache-invalidation bug and an evidence
    # hole at once: nothing decides whether the run cache may serve it, and E1
    # cannot say whether it mutates.

    # Self-reference the checkout actually running this check, not whatever
    # "wv" happens to resolve on PATH — a stale/newer installed binary can
    # have a different dispatch table than a git-worktree or historical-tag
    # checkout, producing a false FAIL (wv-dfaa75). Same fallback convention
    # as _hook_active_id/_wv_concurrent_session.
    local wv_bin
    wv_bin="${WV:-${WV_CLI:-$SCRIPT_DIR/wv}}"
    local wv_script
    wv_script=$(readlink -f "$wv_bin" 2>/dev/null || echo "$wv_bin")

    local dispatch_cmds unclassified_cmds=""
    if [ -f "$wv_script" ]; then
        while IFS= read -r cmd; do
            [ -z "$cmd" ] && continue
            if ! _wv_cap_known "$cmd" 2>/dev/null; then
                unclassified_cmds="${unclassified_cmds:+$unclassified_cmds|}$cmd"
            fi
        done < <(grep -E '^\s+[a-z][a-zA-Z_-]+\)' "$wv_script" \
                   | sed 's/[[:space:]]//g; s/).*$//' \
                   | grep -vE '^\-|\*|^esac' \
                   | sort -u)
    fi

    if [ -n "$unclassified_cmds" ]; then
        local unclassified_list
        unclassified_list=$(echo "$unclassified_cmds" | tr '|' '\n' | sort)
        if [ "$format" = "text" ]; then
            echo -e "${RED}✗ Check 1 FAIL: commands with no capability registry row:${NC}"
            echo "$unclassified_list" | while read -r c; do echo "    $c"; done
            echo -e "  Add a row to contracts/command-capabilities.json, then:"
            echo -e "    python3 scripts/weave_registry.py validate && python3 scripts/weave_registry.py generate"
        fi
        local count
        count=$(echo "$unclassified_cmds" | tr '|' '\n' | wc -l | tr -d ' ')
        local cmds_readable
        cmds_readable=$(echo "$unclassified_cmds" | tr '|' ',')
        findings_json=$(echo "$findings_json" | jq \
            --arg detail "unclassified commands: $cmds_readable" --argjson n "$count" \
            '. + [{"check":"cache_classification","status":"fail","detail":$detail,"count":$n}]')
        issues=$((issues + count))
    else
        [ "$format" = "text" ] && echo -e "${GREEN}✓ Check 1 PASS: every dispatch command has a capability registry row${NC}"
        findings_json=$(echo "$findings_json" | jq \
            '. + [{"check":"cache_classification","status":"pass","detail":"all commands classified","count":0}]')
    fi

    # ── Check 2: domain enum duplicate detection ────────────────────────────
    # Known domain enums must have exactly one definition. More than one means
    # a consumer copy has drifted or been forgotten when the canonical moved.

    # Resolve roots for scripts + hook checks.
    local _scripts_root _project_root _git_root
    _git_root=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
    if [ -n "$_git_root" ] && [ -d "$_git_root/scripts" ]; then
        _project_root="$_git_root"
        _scripts_root="$_git_root/scripts"
    elif [ -n "${WV_PROJECT_DIR:-}" ] && [ -d "${WV_PROJECT_DIR}/scripts" ]; then
        _project_root="$WV_PROJECT_DIR"
        _scripts_root="${WV_PROJECT_DIR}/scripts"
    elif [ -n "${WV_LIB_DIR:-}" ] && [ -d "$(dirname "$WV_LIB_DIR")" ]; then
        _scripts_root=$(cd "$(dirname "$WV_LIB_DIR")" 2>/dev/null && pwd -P)
        _project_root=$(cd "${_scripts_root}/.." 2>/dev/null && pwd -P)
    else
        _scripts_root=$(dirname "$wv_script" 2>/dev/null || echo "")
        _project_root=$(cd "${_scripts_root}/.." 2>/dev/null && pwd -P)
    fi

    local enum_issues=0
    local enum_detail=""

    local -a KNOWN_ENUMS
    KNOWN_ENUMS=(
        "VALID_STATUSES"
        "VALID_EDGE_TYPES"
        "FINDING_VIOLATION_TYPES"
    )

    for enum_name in "${KNOWN_ENUMS[@]}"; do
        local def_count def_files
        # Count assignment lines: VAR_NAME="..." (not references like $VAR_NAME or --arg VAR_NAME)
        local search_root="${_project_root:-}/scripts"
        [ -d "$search_root" ] || search_root="${_scripts_root:-}"
        if [ -n "$search_root" ] && [ -d "$search_root" ]; then
            def_files=$(grep -rl -- "^${enum_name}=" "$search_root" 2>/dev/null | sort | tr '\n' ' ' | sed 's/[[:space:]]*$//')
            def_count=$(echo "$def_files" | tr ' ' '\n' | grep -c '[^[:space:]]' 2>/dev/null) || def_count=0
        else
            def_files=""
            def_count=0
        fi

        if [ "$def_count" -gt 1 ]; then
            if [ "$format" = "text" ]; then
                echo -e "${RED}✗ Check 2 FAIL: ${enum_name} defined in ${def_count} files — drift risk:${NC}"
                echo "$def_files" | tr ' ' '\n' | while read -r f; do [ -n "$f" ] && echo "    $f"; done
            fi
            enum_detail="${enum_detail:+$enum_detail; }${enum_name} in ${def_count} files"
            enum_issues=$((enum_issues + 1))
            issues=$((issues + 1))
        elif [ "$def_count" -eq 0 ]; then
            if [ "$format" = "text" ]; then
                echo -e "${YELLOW}⚠ Check 2 WARN: ${enum_name} not found — may be renamed or removed${NC}"
            fi
        else
            [ "$format" = "text" ] && echo -e "${GREEN}✓ Check 2 PASS: ${enum_name} — single definition${NC}"
        fi
    done

    if [ "$enum_issues" -eq 0 ]; then
        findings_json=$(echo "$findings_json" | jq \
            '. + [{"check":"enum_duplicates","status":"pass","detail":"all domain enums have single definition","count":0}]')
    else
        findings_json=$(echo "$findings_json" | jq \
            --arg detail "$enum_detail" --argjson n "$enum_issues" \
            '. + [{"check":"enum_duplicates","status":"fail","detail":$detail,"count":$n}]')
    fi

    # ── Check 3: phase writes must route via wv_set_phase ──────────────────
    local phase_write_hits
    local _phase_search_a="$_project_root/scripts"
    local _phase_search_b="$_project_root/.claude/hooks"
    [ -d "$_phase_search_a" ] || _phase_search_a="$_scripts_root"
    phase_write_hits=$(grep -RIn --include='*.sh' -E 'echo[[:space:]].*>[[:space:]]*[^[:space:]]*\.session_phase' \
        "$_phase_search_a" "$_phase_search_b" 2>/dev/null \
        | awk -F: '$3 !~ /^[[:space:]]*#/' \
        | grep -v 'scripts/lib/wv-config.sh' \
        | grep -v '/tests/' \
        || true)

    if [ -n "$phase_write_hits" ]; then
        local phase_issue_count
        phase_issue_count=$(echo "$phase_write_hits" | grep -c .) || phase_issue_count=0
        if [ "$format" = "text" ]; then
            echo -e "${RED}✗ Check 3 FAIL: raw .session_phase writes detected (use wv_set_phase):${NC}"
            echo "$phase_write_hits" | while IFS= read -r hit; do [ -n "$hit" ] && echo "    $hit"; done
        fi
        findings_json=$(echo "$findings_json" | jq \
            --arg detail "raw .session_phase writes outside wv_set_phase" --argjson n "$phase_issue_count" \
            '. + [{"check":"phase_writes","status":"fail","detail":$detail,"count":$n}]')
        issues=$((issues + phase_issue_count))
    else
        [ "$format" = "text" ] && echo -e "${GREEN}✓ Check 3 PASS: .session_phase writes route through wv_set_phase${NC}"
        findings_json=$(echo "$findings_json" | jq \
            '. + [{"check":"phase_writes","status":"pass","detail":"no raw .session_phase writes found","count":0}]')
    fi

    # ── Check 4: required hooks load wv-hook-common.sh ─────────────────────
    # Directly or through the library an adapter sources; the rule is
    # _hook_common_unwired's, shared with wv doctor (wv-b80a86).
    local _hooks_dir="$_project_root/.claude/hooks"
    if [ -d "$_hooks_dir" ]; then
        local hook_unwired hook_missing hook_missing_count
        local hook_total=7
        hook_unwired=$(_hook_common_unwired "$_project_root")
        hook_missing_count=$(grep -c . <<< "$hook_unwired") || hook_missing_count=0
        hook_missing=$(paste -sd, - <<< "$hook_unwired" | sed 's/,/, /g')

        if [ "$hook_missing_count" -gt 0 ]; then
            if [ "$format" = "text" ]; then
                echo -e "${RED}✗ Check 4 FAIL: required hooks missing wv-hook-common sourcing:${NC}"
                echo "    $hook_missing"
            fi
            findings_json=$(echo "$findings_json" | jq \
                --arg detail "missing hook-common source in: $hook_missing" --argjson n "$hook_missing_count" \
                '. + [{"check":"hook_common_sourcing","status":"fail","detail":$detail,"count":$n}]')
            issues=$((issues + hook_missing_count))
        else
            [ "$format" = "text" ] && echo -e "${GREEN}✓ Check 4 PASS: all required hooks source wv-hook-common.sh${NC}"
            findings_json=$(echo "$findings_json" | jq \
                --arg detail "all $hook_total required hooks source wv-hook-common.sh" \
                '. + [{"check":"hook_common_sourcing","status":"pass","detail":$detail,"count":0}]')
        fi
    else
        [ "$format" = "text" ] && echo -e "${YELLOW}⚠ Check 4 WARN: .claude/hooks not found — skipped${NC}"
        findings_json=$(echo "$findings_json" | jq \
            '. + [{"check":"hook_common_sourcing","status":"warn","detail":".claude/hooks not found; check skipped","count":0}]')
    fi

    # ── Check 5: pre-action.sh thin-dispatcher contract (≤ 60 lines) ────────
    local _pa_hook="$_project_root/.claude/hooks/pre-action.sh"
    if [ -f "$_pa_hook" ]; then
        local pa_lines
        pa_lines=$(wc -l < "$_pa_hook")
        if [ "$pa_lines" -gt 60 ]; then
            if [ "$format" = "text" ]; then
                echo -e "${RED}✗ Check 5 FAIL: pre-action.sh is $pa_lines lines (limit 60)${NC}"
            fi
            findings_json=$(echo "$findings_json" | jq \
                --argjson n "$pa_lines" \
                '. + [{"check":"thin_dispatcher","status":"fail","detail":"pre-action.sh exceeds 60-line limit","count":$n}]')
            issues=$((issues + 1))
        else
            [ "$format" = "text" ] && echo -e "${GREEN}✓ Check 5 PASS: pre-action.sh is $pa_lines lines (limit 60)${NC}"
            findings_json=$(echo "$findings_json" | jq \
                --argjson n "$pa_lines" \
                '. + [{"check":"thin_dispatcher","status":"pass","detail":"pre-action.sh within 60-line thin-dispatcher limit","count":$n}]')
        fi
    else
        [ "$format" = "text" ] && echo -e "${YELLOW}⚠ Check 5 WARN: pre-action.sh not found — skipped${NC}"
        findings_json=$(echo "$findings_json" | jq \
            '. + [{"check":"thin_dispatcher","status":"warn","detail":"pre-action.sh not found; check skipped","count":0}]')
    fi

    # ── Check 6: node-state invariant — deferral must be graph state, not metadata ──
    # A node carrying active deferral metadata (wv_deferral_metadata_predicate:
    # deferred=true / blocked_until future / blocked_on set) while status='todo' with no
    # inbound non-done blocks edge is a state inconsistency: status must be the
    # authoritative signal. Since wv-1f09a6 the read surfaces (cmd_ready/cmd_context via
    # wv_blocking_reason) already treat such a node as blocked — but its status still
    # claims 'todo', so status lies. This check enforces that status reflects the
    # deferral, keeping the metadata form from being a second, unreconciled
    # representation. Uses the SAME canonical predicate as wv_blocking_reason so the
    # checker and the reader cannot drift. Promotes findings wv-8bb0f4 / wv-f752a5 to an
    # enforced gate. A parked node (deferred with a deferred_reason) keeps status todo
    # by design and is exempt; the query is wv doctor's node-state query (wv-5515e9).
    # See docs/PROPOSAL-graph-as-policy-boundary.md.
    local divergent_nodes=""
    if [ -f "$WV_DB" ]; then
        divergent_nodes=$(db_query "
            SELECT id FROM nodes n WHERE $(wv_deferral_divergent_sql n);
        " 2>/dev/null || echo "")
    fi
    if [ -n "$divergent_nodes" ]; then
        local divergent_list dcount
        divergent_list=$(echo "$divergent_nodes" | tr '\n' ' ' | sed 's/ *$//')
        dcount=$(echo "$divergent_nodes" | grep -c .)
        if [ "$format" = "text" ]; then
            echo -e "${RED}✗ Check 6 FAIL: $dcount node(s) carry deferral metadata while status='todo' (status must reflect the deferral):${NC}"
            echo "$divergent_nodes" | while read -r nid; do [ -n "$nid" ] && echo "    $nid"; done
            echo -e "  Encode deferral as state: status=blocked-external (or add a blocks edge), not metadata.deferred/blocked_until/blocked_on alone; to park a node, give metadata.deferred a deferred_reason."
        fi
        findings_json=$(echo "$findings_json" | jq \
            --arg detail "deferred-but-ready nodes: $divergent_list" --argjson n "$dcount" \
            '. + [{"check":"node_state_deferral","status":"fail","detail":$detail,"count":$n}]')
        issues=$((issues + dcount))
    else
        [ "$format" = "text" ] && echo -e "${GREEN}✓ Check 6 PASS: no deferred-but-ready node-state divergence${NC}"
        findings_json=$(echo "$findings_json" | jq \
            '. + [{"check":"node_state_deferral","status":"pass","detail":"deferral encoded as status/edges, not metadata-only","count":0}]')
    fi

    # ── Check 7: no bare [ cond ] && cmd as a function's last statement ─────
    # Such a tail returns 1 when the condition is false; under set -euo
    # pipefail a caller in a plain context aborts. This class shipped >=5
    # bugs (graph learnings + audit finding A3-2). Predicate helpers are
    # exempt by name (^_?(is|has|can)_) or a '# predicate' annotation on the
    # definition line. A '|| ...' alternative on the tail makes it safe.
    local _pa7_scope="$_project_root/scripts"
    if [ -d "$_pa7_scope" ]; then
        # shellcheck disable=SC2016  # $0 and $n are awk fields inside the awk program
        local _pa7_awk='
/^(function[ \t]+)?[A-Za-z_][A-Za-z0-9_]*\(\)[ \t]*[{(][ \t]*(#.*)?$/ {
    fname=$0; sub(/\(\).*/,"",fname); sub(/^function[ \t]+/,"",fname)
    annotated = ($0 ~ /#[ \t]*predicate/) ? 1 : 0
    # A subshell body, name() ( ... ), ends at a column-0 ")" (wv-b80a86).
    body=$0; sub(/^[^(]*\(\)[ \t]*/,"",body); closer = substr(body,1,1) == "{" ? "}" : ")"
    infunc=1; last=""; lastnr=0; next
}
infunc && substr($0,1,1) == closer && $0 ~ /^[})][ \t]*(#.*)?$/ {
    if (last ~ /^[ \t]*\[\[?[^]]*\]\]?[ \t]*&&/ && last !~ /\|\|/ \
        && fname !~ /^_?(is|has|can)_/ && !annotated)
        printf "%s:%d: %s\n", FILENAME, lastnr, fname
    infunc=0; next
}
infunc {
    line=$0; sub(/^[ \t]+/,"",line)
    if (line != "" && line !~ /^#/) { last=$0; lastnr=FNR }
}'
        local _pa7_files tail_hits=""
        _pa7_files=$(find "$_pa7_scope" -name '*.sh' -not -path '*/tests/*' -not -path '*/archive/*' 2>/dev/null)
        [ -f "$_pa7_scope/wv" ] && _pa7_files="${_pa7_files}${_pa7_files:+
}$_pa7_scope/wv"
        if [ -n "$_pa7_files" ]; then
            tail_hits=$(echo "$_pa7_files" | xargs -r awk "$_pa7_awk" 2>/dev/null || true)
        fi
        if [ -n "$tail_hits" ]; then
            local tail_count
            tail_count=$(echo "$tail_hits" | grep -c .) || tail_count=0
            if [ "$format" = "text" ]; then
                echo -e "${RED}✗ Check 7 FAIL: $tail_count function(s) end in a bare [ cond ] && cmd tail:${NC}"
                echo "$tail_hits" | while IFS= read -r hit; do [ -n "$hit" ] && echo "    $hit"; done
                echo -e "  Convert to if/fi, append '|| true', or mark genuine predicates with '# predicate' on the definition line."
            fi
            findings_json=$(echo "$findings_json" | jq \
                --arg detail "$(echo "$tail_hits" | tr '\n' ' ' | sed 's/ *$//')" --argjson n "$tail_count" \
                '. + [{"check":"function_tail_returns","status":"fail","detail":$detail,"count":$n}]')
            issues=$((issues + tail_count))
        else
            [ "$format" = "text" ] && echo -e "${GREEN}✓ Check 7 PASS: no non-predicate function ends in a bare [ cond ] && cmd tail${NC}"
            findings_json=$(echo "$findings_json" | jq \
                '. + [{"check":"function_tail_returns","status":"pass","detail":"no errexit-fragile function tails","count":0}]')
        fi
    else
        [ "$format" = "text" ] && echo -e "${YELLOW}⚠ Check 7 WARN: $_pa7_scope not found — skipped${NC}"
        findings_json=$(echo "$findings_json" | jq \
            '. + [{"check":"function_tail_returns","status":"warn","detail":"scripts dir not found - skipped","count":0}]')
    fi

    # ── Check 8: quality.db sqlite3 access must stay behind blessed helpers ─
    # The quality readiness bug class recurs when callers hand-roll direct
    # sqlite3 probes against quality.db and drift from the owner schema in
    # scripts/weave_quality. Keep shell-side access in explicitly reviewed
    # helpers; new raw call sites must either move into one of these helpers or
    # justify a new blessed owner here.
    local _pa8_scope="$_project_root/scripts"
    if [ -d "$_pa8_scope" ]; then
        # shellcheck disable=SC2016  # $0 and $n are awk fields inside the awk program
        local _pa8_awk='
function allowed(fn) {
    return fn == "_bootstrap_agent_tools_json" ||
           fn == "_preflight_policy_readiness" ||
           fn == "_done_refresh_file_metrics" ||
           fn == "_done_refresh_trend_signals"
}
# Both bodies, name() { and name() ( (wv-b80a86). A line is charged to the
# last definition above it; a column-0 brace cannot end one here, since the awk
# programs in cmd_pattern_audit carry their own.
/^(function[ \t]+)?[A-Za-z_][A-Za-z0-9_]*\(\)[ \t]*[{(]/ {
    fname=$0; sub(/\(\).*/,"",fname); sub(/^function[ \t]+/,"",fname); next
}
{
    if ($0 ~ /^[ \t]*#/) next
    if (fname == "cmd_pattern_audit") next
    if ($0 ~ /sqlite3/ && ($0 ~ /quality\.db/ || $0 ~ /quality_db/)) {
        if (FILENAME ~ /\/scripts\/weave_quality\//) next
        if (allowed(fname)) next
        printf "%s:%d:%s: %s\n", FILENAME, FNR, fname, $0
    }
}'
        local _pa8_files quality_hits=""
        _pa8_files=$(find "$_pa8_scope" -type f \( -name '*.sh' -o -name 'wv' \) \
            -not -path '*/tests/*' -not -path '*/archive/*' 2>/dev/null)
        if [ -n "$_pa8_files" ]; then
            quality_hits=$(echo "$_pa8_files" | xargs -r awk "$_pa8_awk" 2>/dev/null || true)
        fi
        if [ -n "$quality_hits" ]; then
            local quality_count
            quality_count=$(echo "$quality_hits" | grep -c .) || quality_count=0
            if [ "$format" = "text" ]; then
                echo -e "${RED}✗ Check 8 FAIL: $quality_count raw sqlite3 quality.db access(es) outside blessed helpers:${NC}"
                echo "$quality_hits" | while IFS= read -r hit; do [ -n "$hit" ] && echo "    $hit"; done
                echo -e "  Move probes into _preflight_policy_readiness/_bootstrap_agent_tools_json or the quality owner module."
            fi
            findings_json=$(echo "$findings_json" | jq \
                --arg detail "$(echo "$quality_hits" | tr '\n' ' ' | sed 's/ *$//')" --argjson n "$quality_count" \
                '. + [{"check":"quality_db_sqlite_owner","status":"fail","detail":$detail,"count":$n}]')
            issues=$((issues + quality_count))
        else
            [ "$format" = "text" ] && echo -e "${GREEN}✓ Check 8 PASS: raw sqlite3 quality.db access stays in blessed helpers${NC}"
            findings_json=$(echo "$findings_json" | jq \
                '. + [{"check":"quality_db_sqlite_owner","status":"pass","detail":"quality.db sqlite3 access is owner-scoped","count":0}]')
        fi
    else
        [ "$format" = "text" ] && echo -e "${YELLOW}⚠ Check 8 WARN: $_pa8_scope not found — skipped${NC}"
        findings_json=$(echo "$findings_json" | jq \
            '. + [{"check":"quality_db_sqlite_owner","status":"warn","detail":"scripts dir not found - skipped","count":0}]')
    fi

    # ── Check 9: harness memory stores stay behind blessed helpers ──────────
    # The agent-memory substrate (PROPOSAL-wv-agent-memory-substrate) makes the
    # graph the single authority; per-harness stores are evidence/projections.
    # Harness-store paths ($HOME/.claude/projects, VS Code workspaceStorage, the
    # ~/.codex session/state/memory DBs) must only be read by the blessed
    # scan/import/telemetry/doctor helpers. A new site in a recall/render/
    # bootstrap path is a latent dual-authority leak — a harness file becoming
    # authoritative memory. New readers must justify a blessed entry here.
    local _pa9_scope="$_project_root/scripts"
    if [ -d "$_pa9_scope" ]; then
        # shellcheck disable=SC2016  # $0 and $n are awk fields inside the awk program
        local _pa9_awk='
function allowed(fn) {
    return fn == "_memory_scan_claude" ||
           fn == "_memory_scan_codex" ||
           fn == "_memory_scan_copilot" ||
           fn == "_memory_import_claude_dir" ||
           fn == "_health_cache_summary" ||
           fn == "cmd_cache" ||
           fn == "_doctor_memory_authority" ||
           fn == "_doctor_codex_memory_rows" ||
           # The Claude memory capture guard: it matches a written path against
           # the repo-scoped memory layout and imports only that (wv-b80a86).
           fn == "wv_potu_memory_guard" ||
           # Crash-recovery prompt harvest: the host'"'"'s transcript_path first,
           # Claude Code'"'"'s per-project transcript directory only when the host
           # sends none; it reads transcripts, never memory (wv-b80a86).
           fn == "wv_session_start_context"
}
# Both bodies, name() { and name() (: missing the subshell form charged
# wv_potu_memory_guard'"'"'s reads to _restore_generated_regions, the definition
# above it (wv-b80a86). A line is charged to the last definition above it.
/^(function[ \t]+)?[A-Za-z_][A-Za-z0-9_]*\(\)[ \t]*[{(]/ {
    fname=$0; sub(/\(\).*/,"",fname); sub(/^function[ \t]+/,"",fname); next
}
{
    if ($0 ~ /^[ \t]*#/) next
    if (fname == "cmd_pattern_audit") next
    if ($0 ~ /\.claude\/projects|workspaceStorage|\.codex\/(sessions|state_|memories_|history)/) {
        if (allowed(fname)) next
        printf "%s:%d:%s: %s\n", FILENAME, FNR, fname, $0
    }
}'
        local _pa9_files harness_hits=""
        _pa9_files=$(find "$_pa9_scope" -type f \( -name '*.sh' -o -name 'wv' \) \
            -not -path '*/tests/*' -not -path '*/archive/*' 2>/dev/null)
        if [ -n "$_pa9_files" ]; then
            harness_hits=$(echo "$_pa9_files" | xargs -r awk "$_pa9_awk" 2>/dev/null || true)
        fi
        if [ -n "$harness_hits" ]; then
            local harness_count
            harness_count=$(echo "$harness_hits" | grep -c .) || harness_count=0
            if [ "$format" = "text" ]; then
                echo -e "${RED}✗ Check 9 FAIL: $harness_count harness-store access(es) outside blessed memory helpers:${NC}"
                echo "$harness_hits" | while IFS= read -r hit; do [ -n "$hit" ] && echo "    $hit"; done
                echo -e "  Move harness reads into the scan/import helpers, or add a justified entry to Check 9's allowed()."
            fi
            findings_json=$(echo "$findings_json" | jq \
                --arg detail "$(echo "$harness_hits" | tr '\n' ' ' | sed 's/ *$//')" --argjson n "$harness_count" \
                '. + [{"check":"memory_authority_owner","status":"fail","detail":$detail,"count":$n}]')
            issues=$((issues + harness_count))
        else
            [ "$format" = "text" ] && echo -e "${GREEN}✓ Check 9 PASS: harness memory stores stay behind blessed helpers${NC}"
            findings_json=$(echo "$findings_json" | jq \
                '. + [{"check":"memory_authority_owner","status":"pass","detail":"harness-store access is owner-scoped","count":0}]')
        fi
    else
        [ "$format" = "text" ] && echo -e "${YELLOW}⚠ Check 9 WARN: $_pa9_scope not found — skipped${NC}"
        findings_json=$(echo "$findings_json" | jq \
            '. + [{"check":"memory_authority_owner","status":"warn","detail":"scripts dir not found - skipped","count":0}]')
    fi

    # ── Summary ─────────────────────────────────────────────────────────────
    if [ "$format" = "json" ]; then
        jq -n \
            --argjson findings "$findings_json" \
            --argjson total_issues "$issues" \
            '{"pattern_audit":{"issues":$total_issues,"findings":$findings}}'
    else
        echo ""
        if [ "$issues" -eq 0 ]; then
            echo -e "${GREEN}Pattern audit: PASS (0 issues)${NC}"
        else
            echo -e "${RED}Pattern audit: FAIL ($issues issue(s))${NC}"
        fi
    fi

    [ "$strict" -eq 1 ] && [ "$issues" -gt 0 ] && return 1
    return 0
}
