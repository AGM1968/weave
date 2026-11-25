#!/bin/bash
# wv-cmd-procedures.sh — a repository's own procedures, as wv guide and wv doctor read them
#
# Commands: (helpers)
# Sourced by: wv entry point (autoloaded on first use)
# Dependencies: wv-config.sh (REPO_ROOT); wv-cmd-doctor.sh (_doctor_record)
#
# Repository-owned procedures live in .weave/procedures (wv-fc71f0, memory
# graduation S1). Kept out of wv-cmd-ops.sh so a change here routes only to the
# suites that give a repository procedures of its own: cmd_guide and doctor
# call into this module only when .weave/procedures holds one, so no other
# suite ever loads it.

# _wv_repo_procedure_file <id> — the repository's .weave/procedures/<id>.md,
# validated. It replaces the package procedure of the same id here; like a
# project coaching guide, one that fails the contract is an error, never a
# silent fall back to the package copy.
_wv_repo_procedure_file() {
    local procedure="$1" config_dir="${WV_CONFIG_DIR:-$HOME/.config/weave}" procedure_file problems
    procedure_file="$REPO_ROOT/.weave/procedures/${procedure}.md"
    if [ ! -x "$config_dir/gen-procedures.sh" ]; then
        echo "Error: cannot validate repository procedure '$procedure': $config_dir/gen-procedures.sh is not installed" >&2
        return 1
    fi
    if ! problems=$("$config_dir/gen-procedures.sh" --source="${procedure_file%/*}" --check 2>&1 >/dev/null); then
        echo "Error: repository procedures fail the procedure contract:" >&2
        printf '%s\n' "$problems" >&2
        return 1
    fi
    printf '%s\n' "$procedure_file"
}

# _doctor_repo_procedures <root> — a repository's own procedures (wv-fc71f0):
# valid under the contract, which package procedures they replace, and whether
# their projections are current. Projection is explicit (wv init-repo --update),
# so staleness is reported here: the installed projector writes into a scratch
# copy of the agent surfaces and the copy is compared, keeping the projection
# format in the projector alone. Only surfaces that already carry a managed
# projection are compared, so a harness the repository never set up is not
# reported. Silent when the repository has no procedures of its own.
_doctor_repo_procedures() {
    local root="$1" src="$1/.weave/procedures" config_dir="${WV_CONFIG_DIR:-$HOME/.config/weave}"
    local out file id count=0 replaced="" stale=""
    compgen -G "$src/*.md" >/dev/null || return 0
    if [ ! -x "$config_dir/gen-procedures.sh" ] || [ ! -x "$config_dir/project-procedures.sh" ]; then
        _doctor_record "repo-procedures" "fail" "procedure validator or projector not installed in $config_dir — run ./install.sh"
        return 0
    fi
    if ! out=$("$config_dir/gen-procedures.sh" --source="$src" --check 2>&1 >/dev/null); then
        _doctor_record "repo-procedures" "fail" "$(printf '%s' "$out" | head -3 | tr '\n' ' ')"
        return 0
    fi
    for file in "$src"/*.md; do
        count=$((count + 1))
        id=$(basename "$file" .md)
        [ -f "$config_dir/procedures/$id.md" ] && replaced="${replaced:+$replaced, }$id"
    done
    # The comparison is the doctor module's (_doctor_projection_stale, shared with
    # the package-projection check, wv-5505c2).
    if ! stale=$(_doctor_projection_stale "$root" "$config_dir"); then
        _doctor_record "repo-procedures" "fail" "projection refused: $stale"
        return 0
    fi
    if [ -n "$stale" ]; then
        _doctor_record "repo-procedures" "warn" "projection out of date in $(_doctor_projection_agents "$stale") — run: wv init-repo --update (refreshes every adapter surface present)"
    else
        _doctor_record "repo-procedures" "pass" "$count repository procedure(s) valid, projections current${replaced:+; replacing package: $replaced}"
    fi
}
