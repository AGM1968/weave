#!/bin/bash
# wv-cmd-graduate.sh — where a graduated memory's lesson may live
#
# Commands: (helpers)
# Sourced by: wv entry point (autoloaded on first use)
# Dependencies: wv-config.sh (REPO_ROOT); wv-cmd-python.sh (_wv_python_module_path,
#   _wv_agent_python_exec_module); wv-cmd-procedures.sh (_wv_repo_procedure_file)
#
# A graduate verdict (wv-a8f91e, memory graduation S3) retires an active memory
# because one of the repository's own surfaces now carries its lesson. Kept out
# of wv-cmd-core.sh so a change here routes only to the suites that run it: review
# loads this module only for a graduate verdict, and doctor (memory budget and
# expiry, wv-986c3d) only when the graph holds an active memory, so only the
# suites in its test-map row reach it.

# _memory_graduate_target <path> — prints the target as a path relative to the
# repository root, or explains on stderr why it cannot carry a lesson and
# returns 1. A target is one of the repository's own surfaces and must parse
# there: a procedure under .weave/procedures (the procedure contract), a guide
# under .weave/guides (the guide parser), a detector under .weave/patterns (the
# pattern validator), or a git-tracked Markdown document. The resolved path
# decides, so a symlink or .. cannot lead outside the repository.
_memory_graduate_target() {
    local target="$1" root real rel id pypath out
    if [ -z "$target" ]; then
        echo "Error: --verdict=graduate needs --target=<repo path> naming what carries the lesson" >&2
        return 1
    fi
    case "$target" in
        /*) echo "Error: --target is a path inside the repository, relative to its root; $target is absolute" >&2; return 1 ;;
    esac
    root=$(wv_realpath_existing "$REPO_ROOT") || { echo "Error: repository root $REPO_ROOT cannot be resolved" >&2; return 1; }
    if ! real=$(wv_realpath_existing "$root/$target") || [ ! -f "$real" ]; then
        echo "Error: --target $target is not a file in this repository" >&2
        return 1
    fi
    case "$real" in
        "$root"/*) rel="${real#"$root"/}" ;;
        *) echo "Error: --target $target resolves outside the repository" >&2; return 1 ;;
    esac
    case "$rel" in
        .weave/procedures/*/*) ;;
        .weave/procedures/*.md)
            id=$(basename "$rel" .md)
            _wv_repo_procedure_file "$id" >/dev/null || return 1
            printf '%s\n' "$rel"
            return 0
            ;;
        .weave/guides/*/*) ;;
        .weave/guides/*.md)
            pypath=$(_wv_python_module_path weave_quality 2>/dev/null)
            out=$(_wv_agent_python_exec_module weave_quality.guides "$pypath" doctor --project-root "$root" 2>/dev/null) \
                && jq -se 'length == 1 and (.[0] | .invalid | type == "array")' >/dev/null 2>&1 <<< "$out" \
                || { echo "Error: cannot check guide $rel: the guide doctor did not report" >&2; return 1; }
            if jq -se --arg f "${rel##*/}" 'length == 1 and (.[0] | any(.invalid[]; .file == $f))' >/dev/null <<< "$out"; then
                echo "Error: guide $rel does not parse: $(jq -r --arg f "${rel##*/}" '.invalid[] | select(.file == $f) | .error' <<< "$out")" >&2
                return 1
            fi
            printf '%s\n' "$rel"
            return 0
            ;;
        .weave/patterns/*/*) ;;
        .weave/patterns/*.yaml)
            pypath=$(_wv_python_module_path weave_quality 2>/dev/null)
            out=$(_wv_agent_python_exec_module weave_quality "$pypath" patterns validate "$root" --json 2>/dev/null)
            if ! jq -se --arg p "$real" 'length == 1 and (.[0] | any(.rules[]; .path == $p and .status == "valid"))' >/dev/null 2>&1 <<< "$out"; then
                echo "Error: detector $rel does not validate: $(jq -r --arg p "$real" '[.rules[]? | select(.path == $p) | .error // .status] | first // "not reported"' <<< "$out" 2>/dev/null)" >&2
                return 1
            fi
            printf '%s\n' "$rel"
            return 0
            ;;
        .weave/*) ;;
        *.md)
            if git -C "$root" ls-files --error-unmatch -- "$rel" >/dev/null 2>&1; then
                printf '%s\n' "$rel"
                return 0
            fi
            echo "Error: --target $rel is not tracked; a document carries a lesson only once git does" >&2
            return 1
            ;;
    esac
    echo "Error: --target $rel is not a surface that carries a lesson: .weave/procedures/<id>.md, .weave/guides/<id>.md, .weave/patterns/<id>.yaml, or a tracked .md document" >&2
    return 1
}

# _doctor_memory_budget — memory graduation S4 (wv-986c3d). Advisory: it records
# pass or warn, never fail, so doctor still exits 0. Doctor calls it only when
# the graph holds an active memory, so a graph without one never loads this
# module (test-cli-autoload pins that).
#   memory budget  the rendered WEAVE:MEMORY block (graph-only memories are
#                  not in it, wv-287b39) against .weave/policy.conf
#                  [memory] block_budget_bytes. The default, 8192, is what
#                  wv-91f0ca's 16 KiB AGENTS.md target leaves once the rest of
#                  that file is counted. Over budget, it names graduation
#                  candidates: memories whose text names a repository procedure
#                  or guide, the three longest index lines, the three oldest
#                  verified_at.
#   memory expiry  memories that may hold time-bound state, for re-verification
#                  (consumer finding O): pending or awaiting language and dated
#                  state (as of, updated, until <date>), with any cited node now
#                  done; and a cited node absent from the graph. Flagged, never
#                  retired: a settled negative reads the same to a matcher.
_doctor_memory_budget() {
    local budget=8192 value="" note="" policy_text memories entries bytes surfaces candidates
    local cited known flagged count f base
    if [ -f "$WEAVE_DIR/policy.conf" ] && policy_text=$(wv_config_read "$WEAVE_DIR/policy.conf" 2>/dev/null); then
        value=$(wv_policy_value "$policy_text" memory block_budget_bytes)
    fi
    if [ -n "$value" ]; then
        case "$value" in
            *[!0-9]*) note="; .weave/policy.conf [memory] block_budget_bytes = $value is not a byte count, so the default applies" ;;
            *) budget=$((10#$value)) ;;
        esac
    fi
    memories=$(_memory_recall_json 2>/dev/null) || memories='[]'
    entries=$(_memory_index_entries <<< "$memories" 2>/dev/null) || entries='[]'
    bytes=$(( $(_memory_markdown_block "$entries" | wc -c) ))

    # A repository procedure or guide id, named in a memory's text, marks a
    # lesson that surface may already carry. The seeded example guide is no one's.
    surfaces=$(for f in "$REPO_ROOT"/.weave/procedures/*.md "$REPO_ROOT"/.weave/guides/*.md; do
            [ -f "$f" ] || continue
            base="${f##*/}"
            printf '%s\n' "${base%%.*}"
        done | grep -vx 'example-violation' | jq -Rsc 'split("\n") | map(select(length > 0)) | unique')
    # Memories, surfaces and citations grow with the graph and the repository:
    # --slurpfile, not --argjson (wv-200d36).
    if [ "$bytes" -gt "$budget" ] || [ -n "$note" ]; then
        candidates=$(jq -rn --slurpfile m <(printf '%s' "$memories") --slurpfile e <(printf '%s' "$entries") --slurpfile s <(printf '%s' "$surfaces") '
            $m[0] as $m | $e[0] as $e | $s[0] as $s
            | ($e | map(.id)) as $shown
            | [ $m[] | . as $x | select(any($shown[]; . == $x.id))
                | [ $s[] | . as $id | select($x.text | test("(^|[^A-Za-z0-9_-])" + ($id | gsub("[.]"; "\\.")) + "([^A-Za-z0-9_-]|$)")) ] as $hit
                | select($hit | length > 0) | "\($x.id) (\($hit | join(", ")))" ] as $carried
            | [ $e | sort_by(-(.text | utf8bytelength)) | .[0:3][] | "\(.id) (\(.text | utf8bytelength) B)" ] as $longest
            | [ $e | sort_by(.metadata.verified_at // "") | .[0:3][] | "\(.id) (\((.metadata.verified_at // "unknown")[0:10]))" ] as $oldest
            | [ (if ($carried | length) > 0 then "carried by a repository procedure or guide: " + ($carried | join(", ")) else empty end),
                "longest: " + ($longest | join(", ")),
                "oldest verified: " + ($oldest | join(", ")) ] | join("; ")')
    fi
    if [ "$bytes" -gt "$budget" ]; then
        _doctor_record "memory budget" "warn" "memory block is $bytes bytes, over the $budget-byte budget (.weave/policy.conf [memory] block_budget_bytes); graduation candidates: $candidates; graduate with: wv memory review <id> --verdict=graduate --target=<repo path>, or keep one in recall only with: wv memory review <id> --verdict=exposure --exposure=graph-only --reason=TEXT$note"
    elif [ -n "$note" ]; then
        _doctor_record "memory budget" "warn" "memory block is $bytes of $budget bytes$note"
    else
        _doctor_record "memory budget" "pass" "memory block is $bytes of $budget bytes"
    fi

    # The ids match wv-[a-f0-9]{6}, so they are safe to quote into SQL.
    cited=$(jq -r '[.[].text | match("wv-[a-f0-9]{6}"; "g") | .string] | unique | .[]' <<< "$memories" | sed "s/.*/'&'/" | paste -sd, -)
    known=""
    [ -z "$cited" ] || known=$(db_query_json "SELECT id, status FROM nodes WHERE id IN ($cited);" 2>/dev/null \
        | jq -c 'map({key: .id, value: .status}) | from_entries' 2>/dev/null)
    [ -n "$known" ] || known='{}'
    flagged=$(jq -c --slurpfile m <(printf '%s' "$memories") --slurpfile k <(printf '%s' "$known") -n '
        $k[0] as $k
        | [ $m[0][] | . as $x
          | ([.text | match("(?i)\\b(pending|awaiting|waiting (for|on)|not yet|blocked on|in progress|unanswered|(as of|updated?|until) [0-9]{4}-[0-9]{2}-[0-9]{2})\\b"; "g") | .string | ascii_downcase]
              | reduce .[] as $w ([]; if any(.[]; . == $w) then . else . + [$w] end)) as $t
          | ([.text | match("wv-[a-f0-9]{6}"; "g") | .string] | unique | map(select(. != $x.id))) as $c
          | ($c | map(select($k[.] == "done"))) as $done
          | ($c | map(select($k[.] == null))) as $gone
          | [ (if ($t | length) > 0 then ($t | join(", ")) + (if ($done | length) > 0 then "; cites done " + ($done | join(", ")) else "" end) else empty end),
              (if ($gone | length) > 0 then "cites " + ($gone | join(", ")) + ", not in the graph" else empty end) ] as $why
          | select(($why | length) > 0) | "\($x.id) (\($why | join("; ")))" ]')
    count=$(jq 'length' <<< "$flagged")
    if [ "${count:-0}" -gt 0 ]; then
        _doctor_record "memory expiry" "warn" "$count memory(ies) may hold time-bound state; re-verify each, then supersede it (wv remember --supersedes=<id>) or leave it: $(jq -r 'join(", ")' <<< "$flagged")"
    else
        _doctor_record "memory expiry" "pass" "no active memory holds pending or dated state or cites a node the graph lacks"
    fi
}
