#!/bin/bash
# wv-resolve-runtime.sh — side-effect-free runtime resolution helpers
#
# Source-only contract:
# - Do not add top-level commands, path setup, mkdir, echo, or set statements.
# - Do not read WV_HOT_ZONE or WV_DB at source time.
# - Keep process-local memoization inside is_container().

# Check if a path has enough free space (in KB)
check_free_space() {
    local path="$1"
    local min_kb="${2:-${WV_MIN_SHM:-102400}}"
    local avail_kb
    avail_kb=$(df -k "$path" 2>/dev/null | awk 'NR==2 {print $4}')
    [ -n "$avail_kb" ] && [ "$avail_kb" -ge "$min_kb" ] 2>/dev/null
}

# Detect if running inside a container
is_container() {
    if [ -z "${_WV_CONTAINER:-}" ]; then
        if [ -f /.dockerenv ] || [ -f /run/.containerenv ] \
            || grep -qE 'docker|containerd|podman' /proc/1/cgroup 2>/dev/null \
            || [ -n "${CI:-}" ]; then
            _WV_CONTAINER=yes
        else
            _WV_CONTAINER=no
        fi
    fi
    [ "${_WV_CONTAINER:-no}" = "yes" ]
}

is_codex_runtime() {
    # Sandboxed agent shells (Codex/Copilot/Claude Code) do not reliably persist
    # /dev/shm between tool invocations; route them to the persistent /tmp zone.
    [ -n "${CODEX_THREAD_ID:-}" ] || [ "${CODEX_CI:-}" = "1" ] \
        || [ "${COPILOT_AGENT:-}" = "1" ] || [ -n "${CLAUDE_CODE_SSE_PORT:-}" ]
}

resolve_runtime_label() {
    if is_codex_runtime; then
        echo "codex"
    elif is_container; then
        echo "container"
    else
        echo "native"
    fi
}

canonicalize_runtime_path() {
    local path="$1"
    [ -z "$path" ] && return 0

    if [ -d "$path" ]; then
        (cd "$path" 2>/dev/null && pwd -P) || echo "$path"
    elif [ -e "$path" ]; then
        local path_dir path_base
        path_dir=$(dirname "$path")
        path_base=$(basename "$path")
        local canonical_dir
        canonical_dir=$( (cd "$path_dir" 2>/dev/null && pwd -P) || echo "$path_dir" )
        echo "${canonical_dir}/${path_base}"
    else
        echo "$path"
    fi
}

resolve_env_override_hot_zone() {
    if [ -n "${WV_HOT_ZONE:-}" ]; then
        echo "$WV_HOT_ZONE"
    elif [ -n "${WV_DB:-}" ]; then
        dirname "$WV_DB"
    fi
}

resolve_hot_zone_owner_file() {
    local hot_zone="$1"
    [ -n "$hot_zone" ] && echo "${hot_zone}/.repo_root" || true
}

read_hot_zone_owner() {
    local hot_zone="$1"
    local owner_file
    owner_file=$(resolve_hot_zone_owner_file "$hot_zone")
    [ -n "$owner_file" ] || return 0
    [ -f "$owner_file" ] || return 0
    cat "$owner_file" 2>/dev/null || echo ""
}

hot_zone_matches_repo() {
    local hot_zone="$1"
    local repo_root="$2"
    local owner=""

    [ -z "$hot_zone" ] && return 0
    if [ -z "$repo_root" ]; then
        repo_root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
    fi
    repo_root=$(canonicalize_runtime_path "$repo_root")

    owner=$(read_hot_zone_owner "$hot_zone")
    # No owner file → unknown; treat as matching (new or test hot zone).
    # Do NOT fall back to WV_PROJECT_DIR here — that made every ownerless hot zone
    # appear to match the current repo, preventing leaked-override detection when the
    # hot zone had an owner file pointing to a different repo but WV_PROJECT_DIR was set.
    [ -z "$owner" ] && return 0

    owner=$(canonicalize_runtime_path "$owner")
    [ "$owner" = "$repo_root" ]
}

# Cross-platform hot zone detection
resolve_hot_zone() {
    if [ -n "${WV_HOT_ZONE:-}" ]; then
        echo "${WV_HOT_ZONE}"
        return
    fi

    # Per-UID fallback dirs avoid shared-parent /tmp/weave races on multi-user
    # hosts (security review L1, 2026-04-19). /dev/shm/weave still uses the
    # classic name because /dev/shm is already 1777 and weave creates its own
    # 700-mode subdir there.
    local uid
    local min_shm_kb="${WV_MIN_SHM:-102400}"
    local weave_dir="${WEAVE_DIR:-${WV_PROJECT_DIR:-$PWD}/.weave}"

    uid=$(id -u 2>/dev/null || echo "$UID")
    case "$(uname -s)" in
        Linux*)
            if is_codex_runtime; then
                echo "/tmp/weave-codex-${uid}"
            elif is_container; then
                echo "wv: container detected, using /tmp (safe default)" >&2
                echo "/tmp/weave-${uid}"
            elif [ -d "/dev/shm" ] && [ -w "/dev/shm" ] && check_free_space "/dev/shm"; then
                echo "/dev/shm/weave"
            else
                [ -d "/dev/shm" ] && [ -w "/dev/shm" ] && \
                    echo "wv: /dev/shm has <${min_shm_kb}KB free, falling back to /tmp" >&2
                echo "/tmp/weave-${uid}"
            fi
            ;;
        Darwin*)
            echo "${TMPDIR:-/tmp}/weave-${uid}"
            ;;
        MINGW*|CYGWIN*|MSYS*)
            echo "${TEMP:-/tmp}/weave-${uid}"
            ;;
        *)
            echo "$weave_dir"
            ;;
    esac
}

# shellcheck disable=SC2120  # optional positional override args; callers use env-var defaults
resolve_repo_hot_zone() {
    if [ -n "${WV_HOT_ZONE:-}" ]; then
        echo "$WV_HOT_ZONE"
        return
    fi

    local base_hot_zone="${1:-}"
    local repo_root="${2:-${WV_PROJECT_DIR:-}}"

    if [ -z "$base_hot_zone" ]; then
        base_hot_zone=$(resolve_hot_zone)
    fi
    if [ -z "$repo_root" ]; then
        repo_root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
        # Reject home dir — same boundary as wv-config.sh.
        if [ "$repo_root" = "$HOME" ] || [ "$repo_root" = "/root" ]; then
            repo_root=""
        fi
    fi

    if [ -n "$repo_root" ] && [ "$repo_root" != "/" ]; then
        local repo_hash
        repo_hash=$(echo "$repo_root" | md5sum | cut -c1-8)
        echo "${base_hot_zone}/${repo_hash}"
    else
        echo "$base_hot_zone"
    fi
}

resolve_unix_clock_parts() {
    local epoch_ns=""
    local epoch_sec=""
    local epoch_subsec=""
    local split=0

    epoch_ns=$(date +%s%N 2>/dev/null || echo "")
    if [[ "$epoch_ns" =~ ^[0-9]{10,}$ ]]; then
        split=$(( ${#epoch_ns} - 9 ))
        epoch_sec="${epoch_ns:0:split}"
        epoch_subsec="${epoch_ns:split:9}"
        printf '%s %s\n' "$epoch_sec" "$epoch_subsec"
        return 0
    fi

    if command -v python3 >/dev/null 2>&1; then
        epoch_ns=$(python3 -c 'import time; print(time.time_ns())' 2>/dev/null || echo "")
        if [[ "$epoch_ns" =~ ^[0-9]{10,}$ ]]; then
            split=$(( ${#epoch_ns} - 9 ))
            epoch_sec="${epoch_ns:0:split}"
            epoch_subsec="${epoch_ns:split:9}"
            printf '%s %s\n' "$epoch_sec" "$epoch_subsec"
            return 0
        fi
    fi

    epoch_sec=$(date +%s 2>/dev/null || echo "0")
    printf '%s %09d\n' "$epoch_sec" 0
}

resolve_delta_filename_prefix() {
    local outvar="${1:-}"
    local clock_parts epoch_sec epoch_subsec stamp_key prefix

    clock_parts=$(resolve_unix_clock_parts)
    epoch_sec="${clock_parts%% *}"
    epoch_subsec="${clock_parts##* }"
    stamp_key="${epoch_sec}-${epoch_subsec}"

    if [ "${_WV_DELTA_STAMP_KEY:-}" = "$stamp_key" ]; then
        _WV_DELTA_STAMP_SEQ=$(( ${_WV_DELTA_STAMP_SEQ:-0} + 1 ))
    else
        _WV_DELTA_STAMP_KEY="$stamp_key"
        _WV_DELTA_STAMP_SEQ=0
    fi

    printf -v prefix '%010d-%09d-%06d' "$epoch_sec" "$epoch_subsec" "${_WV_DELTA_STAMP_SEQ:-0}"
    if [ -n "$outvar" ]; then
        printf -v "$outvar" '%s' "$prefix"
    else
        printf '%s\n' "$prefix"
    fi
}

resolve_db() {
    if [ -n "${WV_DB:-}" ]; then
        echo "$WV_DB"
        return
    fi

    local hot_zone="${1:-}"
    if [ -z "$hot_zone" ]; then
        hot_zone=$(resolve_repo_hot_zone)
    fi
    echo "${hot_zone}/brain.db"
}

resolve_primary_file() {
    if [ -n "${WV_PRIMARY_FILE:-}" ]; then
        echo "$WV_PRIMARY_FILE"
        return
    fi

    local hot_zone="${1:-}"
    if [ -z "$hot_zone" ]; then
        hot_zone=$(resolve_repo_hot_zone)
    fi
    echo "${hot_zone}/primary"
}

resolve_active_primary() {
    local db_path="${1:-}"
    local hot_zone="${2:-}"
    local primary_file="${3:-}"
    local primary_id=""
    local fallback_id=""

    if [ -z "$hot_zone" ]; then
        hot_zone=$(resolve_repo_hot_zone)
    fi
    if [ -z "$db_path" ]; then
        db_path=$(resolve_db "$hot_zone")
    fi
    if [ -z "$primary_file" ]; then
        primary_file=$(resolve_primary_file "$hot_zone")
    fi
    [ -f "$db_path" ] || return 0

    if [ -f "$primary_file" ]; then
        primary_id=$(cat "$primary_file" 2>/dev/null || echo "")
        if [ -n "$primary_id" ]; then
            local escaped_primary
            escaped_primary=${primary_id//\'/\'\'}
            local primary_status
            primary_status=$(sqlite3 "$db_path" "SELECT status FROM nodes WHERE id='${escaped_primary}' LIMIT 1;" 2>/dev/null || echo "")
            if [ "$primary_status" = "active" ]; then
                echo "$primary_id"
                return 0
            fi
            rm -f "$primary_file" 2>/dev/null || true
        fi
    fi

    fallback_id=$(sqlite3 "$db_path" "SELECT id FROM nodes WHERE status='active' ORDER BY updated_at DESC LIMIT 1;" 2>/dev/null || echo "")
    [ -n "$fallback_id" ] && echo "$fallback_id"
    return 0
}

is_attribution_tool() {
    case "${1:-}" in
        Edit|Write|NotebookEdit|create_file|replace_string_in_file|insert_edit_into_file|multi_replace_string_in_file|edit_notebook_file)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# Backward-compatible alias while callers migrate to resolve_hot_zone().
detect_hot_zone() {
    resolve_hot_zone
}
