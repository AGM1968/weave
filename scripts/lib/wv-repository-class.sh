#!/usr/bin/env bash
# Clone-local repository ownership boundary for scaffolding and projection writes.

WV_REPOSITORY_CLASSES="owned vendored-upstream"

_wv_repository_normalize_remote() {
    local url="${1:-}"
    url="${url#ssh://}"
    url="${url#git+ssh://}"
    url="${url#https://}"
    url="${url#http://}"
    url="${url#git://}"
    url="${url#git@}"
    if [[ "$url" == *:* ]] && [[ "$url" != */*:* ]]; then
        url="${url/:/\/}"
    fi
    url="${url%%\?*}"
    url="${url%/}"
    url="${url%.git}"
    printf '%s\n' "${url,,}"
}

_wv_repository_topology() {
    local repo="$1" entry key url tracking
    while IFS= read -r entry; do
        [ -n "$entry" ] || continue
        key="${entry%% *}"
        url="${entry#* }"
        printf '%s=%s\n' "$key" "$(_wv_repository_normalize_remote "$url")"
    done < <(git -C "$repo" config --local --get-regexp '^remote\..*\.(url|pushurl)$' 2>/dev/null | sort)
    tracking=$(git -C "$repo" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null || true)
    printf 'tracking:%s\n' "$tracking"
}

wv_repository_remote_fingerprint() {
    local repo="$1"
    _wv_repository_topology "$repo" | sha256sum | awk '{print $1}'
}

_wv_repository_autodetect() {
    local repo="$1" offline="${2:-0}"
    local remotes origin_url upstream_url tracking origin_id api
    remotes=$(git -C "$repo" remote 2>/dev/null || true)
    if [ -z "$remotes" ]; then
        WV_REPO_AUTO_CLASS="owned"
        WV_REPO_AUTO_SOURCE="autodetect:no-remotes"
        WV_REPO_AUTO_REASON="repository has no fetch remotes"
        return 0
    fi

    origin_url=$(git -C "$repo" remote get-url origin 2>/dev/null || true)
    upstream_url=$(git -C "$repo" remote get-url upstream 2>/dev/null || true)
    tracking=$(git -C "$repo" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null || true)
    if [ -n "$upstream_url" ] && [ "$(_wv_repository_normalize_remote "$upstream_url")" != "$(_wv_repository_normalize_remote "$origin_url")" ]; then
        WV_REPO_AUTO_CLASS="vendored-upstream"
        WV_REPO_AUTO_SOURCE="autodetect:upstream-remote"
        WV_REPO_AUTO_REASON="repository has a distinct upstream remote"
        return 0
    fi
    if [ -n "$tracking" ] && [ "${tracking%%/*}" != "origin" ]; then
        WV_REPO_AUTO_CLASS="vendored-upstream"
        WV_REPO_AUTO_SOURCE="autodetect:tracking-remote"
        WV_REPO_AUTO_REASON="current branch tracks non-origin remote ${tracking%%/*}"
        return 0
    fi

    origin_id=$(_wv_repository_normalize_remote "$origin_url")
    case "$origin_id" in
        github.com/*/*)
            if [ "$offline" != "1" ] && command -v gh >/dev/null 2>&1; then
                api=$(gh api "repos/${origin_id#github.com/}" \
                    --jq '[.fork, (.permissions.admin // false), (.permissions.maintain // false), (.permissions.push // false), (.parent.full_name // "")] | @tsv' \
                    2>/dev/null || true)
                if [ -n "$api" ]; then
                    local is_fork admin maintain push parent
                    IFS=$'\t' read -r is_fork admin maintain push parent <<< "$api"
                    if [ "$is_fork" = "true" ]; then
                        WV_REPO_AUTO_CLASS="vendored-upstream"
                        WV_REPO_AUTO_SOURCE="autodetect:github-fork"
                        WV_REPO_AUTO_REASON="GitHub reports fork${parent:+ of $parent}"
                        return 0
                    fi
                    if [ "$admin" = "true" ]; then
                        WV_REPO_AUTO_CLASS="owned"
                        WV_REPO_AUTO_SOURCE="autodetect:github-admin"
                        WV_REPO_AUTO_REASON="GitHub reports non-fork repository with admin permission"
                        return 0
                    fi
                    if [ "$maintain" != "true" ] && [ "$push" != "true" ]; then
                        WV_REPO_AUTO_CLASS="vendored-upstream"
                        WV_REPO_AUTO_SOURCE="autodetect:github-readonly"
                        WV_REPO_AUTO_REASON="GitHub reports non-owned read-only repository"
                        return 0
                    fi
                fi
            fi
            ;;
    esac

    WV_REPO_AUTO_CLASS="ambiguous"
    WV_REPO_AUTO_SOURCE="autodetect:unresolved-remote"
    if [ "$offline" = "1" ]; then
        WV_REPO_AUTO_REASON="remote-bearing repository cannot be classified safely offline"
    else
        WV_REPO_AUTO_REASON="remote-bearing repository ownership could not be verified"
    fi
}

wv_repository_classify() {
    local repo="$1" offline="${2:-0}" explicit stored_fingerprint fingerprint
    WV_REPO_CLASS="owned"
    WV_REPO_SOURCE="autodetect:no-git"
    WV_REPO_REASON="directory is not a Git repository and has no tracked-write surface"
    WV_REPO_FINGERPRINT=""
    WV_REPO_AUTO_CLASS="ambiguous"
    WV_REPO_AUTO_SOURCE="error"
    WV_REPO_AUTO_REASON="not evaluated"
    git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || {
        WV_REPO_AUTO_CLASS="$WV_REPO_CLASS"
        WV_REPO_AUTO_SOURCE="$WV_REPO_SOURCE"
        WV_REPO_AUTO_REASON="$WV_REPO_REASON"
        return 0
    }

    fingerprint=$(wv_repository_remote_fingerprint "$repo")
    WV_REPO_FINGERPRINT="$fingerprint"
    _wv_repository_autodetect "$repo" "$offline"
    explicit=$(git -C "$repo" config --local --get weave.repositoryClass 2>/dev/null || true)
    stored_fingerprint=$(git -C "$repo" config --local --get weave.repositoryClassRemoteFingerprint 2>/dev/null || true)
    case "$explicit" in
        vendored-upstream)
            WV_REPO_CLASS="vendored-upstream"
            WV_REPO_SOURCE="explicit-local"
            WV_REPO_REASON="repository-local vendored-upstream classification"
            ;;
        owned)
            if [ -n "$stored_fingerprint" ] && [ "$stored_fingerprint" = "$fingerprint" ]; then
                WV_REPO_CLASS="owned"
                WV_REPO_SOURCE="explicit-local"
                WV_REPO_REASON="repository-local owned classification with matching remote fingerprint"
            else
                WV_REPO_CLASS="ambiguous"
                WV_REPO_SOURCE="explicit-stale"
                WV_REPO_REASON="owned classification is missing or does not match the current remote topology"
            fi
            ;;
        "")
            WV_REPO_CLASS="$WV_REPO_AUTO_CLASS"
            WV_REPO_SOURCE="$WV_REPO_AUTO_SOURCE"
            WV_REPO_REASON="$WV_REPO_AUTO_REASON"
            ;;
        *)
            WV_REPO_CLASS="ambiguous"
            WV_REPO_SOURCE="explicit-invalid"
            WV_REPO_REASON="invalid repository-local class '$explicit'"
            ;;
    esac
}

wv_repository_class_json() {
    local repo="$1" offline="${2:-0}"
    wv_repository_classify "$repo" "$offline"
    jq -cn \
        --arg class "$WV_REPO_CLASS" \
        --arg source "$WV_REPO_SOURCE" \
        --arg reason "$WV_REPO_REASON" \
        --arg remote_fingerprint "$WV_REPO_FINGERPRINT" \
        --arg autodetected_class "$WV_REPO_AUTO_CLASS" \
        --arg autodetected_source "$WV_REPO_AUTO_SOURCE" \
        --arg autodetected_reason "$WV_REPO_AUTO_REASON" \
        '{class:$class,source:$source,reason:$reason,remote_fingerprint:$remote_fingerprint,autodetected_class:$autodetected_class,autodetected_source:$autodetected_source,autodetected_reason:$autodetected_reason}'
}

wv_repository_class_set() {
    local repo="$1" class="$2" acknowledge="${3:-0}"
    case "$class" in
        owned|vendored-upstream) ;;
        *) echo "wv: repository class must be owned or vendored-upstream" >&2; return 2 ;;
    esac
    git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || {
        echo "wv: repository classification requires a Git repository" >&2
        return 1
    }
    _wv_repository_autodetect "$repo" 0
    if [ "$class" = "owned" ] && [ "$WV_REPO_AUTO_CLASS" != "owned" ] && [ "$acknowledge" != "1" ]; then
        echo "wv: refusing owned override: $WV_REPO_AUTO_REASON" >&2
        echo "Re-run with --acknowledge-upstream-fork only if this remote-bearing repository is intentionally owned." >&2
        return 1
    fi
    git -C "$repo" config --local weave.repositoryClass "$class"
    git -C "$repo" config --local weave.repositoryClassRemoteFingerprint \
        "$(wv_repository_remote_fingerprint "$repo")"
}

wv_repository_require_owned() {
    local repo="$1" operation="${2:-repository write}" offline="${3:-0}"
    wv_repository_classify "$repo" "$offline"
    [ "$WV_REPO_CLASS" = "owned" ] && return 0
    echo "wv: refusing $operation in repository class '$WV_REPO_CLASS'" >&2
    echo "  evidence: $WV_REPO_REASON" >&2
    echo "  no repository scaffolding was written" >&2
    echo "  inspect: wv repo-class --json" >&2
    echo "  classify locally: wv repo-class set owned|vendored-upstream" >&2
    [ "$WV_REPO_AUTO_CLASS" != "vendored-upstream" ] || \
        echo "  owned forks require: wv repo-class set owned --acknowledge-upstream-fork" >&2
    return 1
}

wv_repository_audit_json() {
    local repo="$1" offline="${2:-0}" clean gate_passed remediation_required exposure_state
    local tmp_dir tracked_file markers_file history_file reachable_file residue_file rc=0
    local marker_ere='WEAVE-MANAGED|BEGIN WEAVE|weave\.codex\.v1|weave-(session|lite|inspect)|Weave (pre-commit|post-commit|prepare-commit)'
    wv_repository_classify "$repo" "$offline"
    tmp_dir=$(mktemp -d) || return 1
    tracked_file="$tmp_dir/tracked"
    markers_file="$tmp_dir/markers"
    history_file="$tmp_dir/history"
    reachable_file="$tmp_dir/reachable"
    residue_file="$tmp_dir/residue"
    git -C "$repo" ls-files 2>/dev/null | awk '
        /^\.weave\// ||
        $0 == ".codex/weave.json" || $0 == ".codex/hooks.json" ||
        $0 ~ /^\.claude\/skills\/(wv-|weave)/ ||
        $0 ~ /^\.claude\/agents\/(weave-guide|epic-planner|learning-curator)\.md$/ ||
        $0 ~ /^scripts\/hooks\/.*-weave\.sh$/ { print }
    ' > "$tracked_file"
    {
        git -C "$repo" grep -Il -E "$marker_ere" -- ':!*.lock' 2>/dev/null || true
        git -C "$repo" grep --cached -Il -E "$marker_ere" -- ':!*.lock' 2>/dev/null || true
    } | awk 'NF && !seen[$0]++' > "$markers_file"
    {
        git -C "$repo" log --all --reflog --full-history --format='%H' -- \
            .weave .codex/weave.json .codex/hooks.json \
            '.claude/skills/wv-*' '.claude/skills/weave*' \
            .claude/agents/weave-guide.md .claude/agents/epic-planner.md \
            .claude/agents/learning-curator.md 'scripts/hooks/*-weave.sh' 2>/dev/null || true
        git -C "$repo" log --all --reflog --full-history -m --format='%H' \
            -G "$marker_ere" 2>/dev/null || true
    } | awk 'NF && !seen[$0]++' > "$history_file"
    {
        git -C "$repo" log --branches --tags --remotes --full-history --format='%H' -- \
            .weave .codex/weave.json .codex/hooks.json \
            '.claude/skills/wv-*' '.claude/skills/weave*' \
            .claude/agents/weave-guide.md .claude/agents/epic-planner.md \
            .claude/agents/learning-curator.md 'scripts/hooks/*-weave.sh' 2>/dev/null || true
        git -C "$repo" log --branches --tags --remotes --full-history -m --format='%H' \
            -G "$marker_ere" 2>/dev/null || true
    } | awk 'NF && !seen[$0]++' > "$reachable_file"
    comm -23 <(sort -u "$history_file") <(sort -u "$reachable_file") > "$residue_file"

    clean=true
    gate_passed=true
    remediation_required=false
    exposure_state="clean"
    if [ "$WV_REPO_CLASS" != "owned" ]; then
        if [ -s "$tracked_file" ] || [ -s "$markers_file" ]; then
            clean=false
            gate_passed=false
            remediation_required=true
            exposure_state="current_exposure"
        elif [ -s "$reachable_file" ]; then
            clean=false
            gate_passed=false
            remediation_required=true
            exposure_state="reachable_exposure"
        elif [ -s "$residue_file" ]; then
            clean=false
            exposure_state="residue_only"
        fi
    fi
    jq -cn \
        --arg class "$WV_REPO_CLASS" --arg source "$WV_REPO_SOURCE" --arg reason "$WV_REPO_REASON" \
        --arg exposure_state "$exposure_state" \
        --argjson clean "$clean" --argjson gate_passed "$gate_passed" \
        --argjson remediation_required "$remediation_required" \
        --rawfile tracked "$tracked_file" --rawfile markers "$markers_file" \
        --rawfile history "$history_file" --rawfile reachable "$reachable_file" \
        --rawfile residue "$residue_file" \
        '{class:$class,source:$source,reason:$reason,clean:$clean,gate_passed:$gate_passed,
          exposure_state:$exposure_state,
          tracked_paths:($tracked|split("\n")|map(select(length>0))),
          marker_paths:($markers|split("\n")|map(select(length>0))),
          history_commits:($history|split("\n")|map(select(length>0))),
          remediation_required:$remediation_required,
          current_exposure:{tracked_paths:($tracked|split("\n")|map(select(length>0))),marker_paths:($markers|split("\n")|map(select(length>0)))},
          reachable_exposure:{history_commits:($reachable|split("\n")|map(select(length>0)))},
          residue:{commits:($residue|split("\n")|map(select(length>0))),prune_optional:true}}' \
        || rc=$?
    rm -rf "$tmp_dir"
    [ "$rc" -eq 0 ] || return "$rc"
    [ "$gate_passed" = true ]
}
