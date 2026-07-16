#!/usr/bin/env bash
# Test-only staging primitive; it never modifies the source .weave directory.

wv_checkpoint_generation_stage() {
    local weave="$1" stage="$2" generation="$3"
    local state="$weave/state.sql" root="$weave/deltas"
    [ -f "$state" ] || { echo "checkpoint stage: missing state.sql" >&2; return 1; }
    case "$generation" in
        ""|"."|".."|*/*|*\\*|*[$'\n'$'\r']*) echo "checkpoint stage: unsafe generation id" >&2; return 1;;
    esac
    [[ "$generation" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] || { echo "checkpoint stage: unsafe generation id" >&2; return 1; }
    mkdir -p "$stage" || return 1
    local target="$stage/$generation" lock="$stage/.${generation}.lock" tmp work catalog entries candidate rel hash size kind state_hash manifest_hash archive legacy_catalog
    if ! mkdir "$lock"; then
        echo "checkpoint stage: generation already locked or exists" >&2
        return 1
    fi
    [ ! -e "$target" ] || { rmdir "$lock"; echo "checkpoint stage: generation already exists" >&2; return 1; }
    tmp=$(mktemp -d "$stage/.${generation}.tmp.XXXXXX") || { rmdir "$lock"; return 1; }
    work="$tmp/.work"
    mkdir -p "$work" "$tmp/legacy-deltas/v1" || { rm -rf "$tmp"; rmdir "$lock"; return 1; }
    catalog=$(mktemp "${TMPDIR:-/tmp}/wv-checkpoint-catalog.XXXXXX") || { rm -rf "$tmp"; rmdir "$lock"; return 1; }
    entries="$work/entries.jsonl"
    candidate="$work/candidate.db"
    : > "$entries" || { rm -rf "$tmp"; rm -f "$catalog"; rmdir "$lock"; return 1; }
    sqlite3 "$candidate" < "$state" || { echo "checkpoint stage: state replay failed" >&2; rm -rf "$tmp"; rm -f "$catalog"; rmdir "$lock"; return 1; }
    if ! wv_delta_catalog_scan "$root" > "$catalog"; then
        rm -rf "$tmp"; rm -f "$catalog"; rmdir "$lock"; return 1
    fi
    if [ -s "$catalog" ]; then
        while IFS= read -r -d '' rel && IFS= read -r -d '' hash && IFS= read -r -d '' size && IFS= read -r -d '' kind; do
            case "$kind" in
            legacy_sql) ;;
            *) echo "checkpoint stage: unsupported catalog entry: $rel ($kind)" >&2; rm -rf "$tmp"; rm -f "$catalog"; rmdir "$lock"; return 1;;
            esac
            archive="$tmp/legacy-deltas/v1/$rel"
            mkdir -p "$(dirname "$archive")" || { rm -rf "$tmp"; rm -f "$catalog"; rmdir "$lock"; return 1; }
            cp "$root/$rel" "$archive" || { rm -rf "$tmp"; rm -f "$catalog"; rmdir "$lock"; return 1; }
            [ "$(sha256sum "$archive" | awk '{print $1}')" = "$hash" ] || { echo "checkpoint stage: delta changed after scan: $rel" >&2; rm -rf "$tmp"; rm -f "$catalog"; rmdir "$lock"; return 1; }
            sqlite3 "$candidate" < "$archive" || { echo "checkpoint stage: delta replay failed: $rel" >&2; rm -rf "$tmp"; rm -f "$catalog"; rmdir "$lock"; return 1; }
            jq -n --arg key "$rel" --arg raw "$hash" --arg original "deltas/$rel" --arg archived "legacy-deltas/v1/$rel" \
              '{key:$key,value:{raw_sha256:$raw,original_path:$original,archived_path:$archived,disposition:"incorporated"}}' >> "$entries" || { rm -rf "$tmp"; rm -f "$catalog"; rmdir "$lock"; return 1; }
        done < "$catalog"
    fi
    sqlite3 "$candidate" .dump > "$tmp/state.sql" || { echo "checkpoint stage: candidate dump failed" >&2; rm -rf "$tmp"; rm -f "$catalog"; rmdir "$lock"; return 1; }
    state_hash=$(sha256sum "$tmp/state.sql" | awk '{print $1}') || { rm -rf "$tmp"; rm -f "$catalog"; rmdir "$lock"; return 1; }
    jq -s --arg gen "$generation" --arg state "$state_hash" \
      '{format:"weave.checkpoint.v1",generation:$gen,state_sha256:$state,incorporated_legacy_deltas:(map({(.key):.value})|add // {})}' "$entries" > "$tmp/manifest.json" || { rm -rf "$tmp"; rm -f "$catalog"; rmdir "$lock"; return 1; }
    legacy_catalog="$tmp/legacy-deltas/v1/catalog.json"
    jq -s --arg gen "$generation" \
      '{format:"weave.legacy-delta-catalog.v1",checkpoint_generation:$gen,entries:map(.value)}' "$entries" > "$legacy_catalog" || { rm -rf "$tmp"; rm -f "$catalog"; rmdir "$lock"; return 1; }
    manifest_hash=$(sha256sum "$tmp/manifest.json" | awk '{print $1}') || { rm -rf "$tmp"; rm -f "$catalog"; rmdir "$lock"; return 1; }
    jq -n --arg gen "$generation" --arg state "$state_hash" --arg manifest "$manifest_hash" \
      '{format:"weave.checkpoint-generation.v1",generation:$gen,state_path:"state.sql",manifest_path:"manifest.json",state_sha256:$state,manifest_sha256:$manifest}' > "$tmp/generation.json" || { rm -rf "$tmp"; rm -f "$catalog"; rmdir "$lock"; return 1; }
    jq -n --arg generation "$generation" --arg state "$state_hash" --arg manifest "$manifest_hash" \
      '{format:"weave.checkpoint-stage.v1",state:"staged",generation:$generation,state_sha256:$state,manifest_sha256:$manifest}' > "$tmp/journal.json" || { rm -rf "$tmp"; rm -f "$catalog"; rmdir "$lock"; return 1; }
    rm -rf "$work" || { rm -rf "$tmp"; rm -f "$catalog"; rmdir "$lock"; return 1; }
    if ! mv -T "$tmp" "$target"; then
        rm -rf "$tmp"; rm -f "$catalog"; rmdir "$lock"; return 1
    fi
    rm -f "$catalog"
    rmdir "$lock"
}

# Pure journal transition guard.  Callers persist the returned JSON themselves.
wv_checkpoint_stage_transition() {
    local journal="$1" next="$2" selector="${3:-}"
    command -v jq >/dev/null 2>&1 || return 1
    jq -e '
      type == "object" and
      (keys_unsorted | sort) == ["format","generation","manifest_sha256","state","state_sha256"] and
      .format == "weave.checkpoint-stage.v1" and
      (.state as $state | ($state | type == "string") and (["staged","published","selected","aborted"] | index($state) != null)) and
      (.generation | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")) and
      (.state_sha256 | type == "string" and test("^[a-f0-9]{64}$")) and
      (.manifest_sha256 | type == "string" and test("^[a-f0-9]{64}$"))
    ' "$journal" >/dev/null || { echo "checkpoint stage: invalid journal" >&2; return 1; }
    local current generation selected
    current=$(jq -r '.state' "$journal") || return 1
    generation=$(jq -r '.generation' "$journal") || return 1
    if [ "$current" = "published" ] && { [ "$next" = "selected" ] || [ "$next" = "aborted" ]; }; then
        [ -n "$selector" ] || { echo "checkpoint stage: selector required for published recovery" >&2; return 1; }
        [ -f "$selector" ] || { echo "checkpoint stage: missing selector" >&2; return 1; }
        jq -e '
          type == "object" and
          (keys_unsorted | sort) == ["format","generation"] and
          .format == "weave.checkpoint-current.v1" and
          (.generation | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$"))
        ' "$selector" >/dev/null || { echo "checkpoint stage: invalid selector" >&2; return 1; }
        selected=$(jq -r '.generation' "$selector") || return 1
        if [ "$selected" = "$generation" ]; then next="selected"; else next="aborted"; fi
    fi
    case "$current:$next" in
      staged:published|staged:aborted|published:selected|published:aborted) ;;
      *) echo "checkpoint stage: illegal transition" >&2; return 1;;
    esac
    jq --arg next "$next" '.state = $next' "$journal"
}
