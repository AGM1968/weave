#!/bin/bash
# wv-validate.sh — ID generation, validation, and SQL escaping
#
# Sourced by: wv entry point (after wv-config.sh)
# Dependencies: wv-config.sh (for RED, NC colors)

# ═══════════════════════════════════════════════════════════════════════════
# ID Generation
# ═══════════════════════════════════════════════════════════════════════════

generate_id() {
    # Hash-based ID: wv-xxxxxx (6 hex chars from sha256 of timestamp + random)
    # v1.2+: 6 chars = 16M namespace. Legacy 4-char IDs remain valid.
    # EPOCHREALTIME (bash 5) keeps sub-second entropy where BSD date prints
    # %N literally. No hash is a refusal, never the id 'wv-' (wv-ed3eac).
    local seed hash
    seed="${EPOCHREALTIME:-$(date +%s)}$$${RANDOM}${RANDOM}"
    hash=$(printf '%s' "$seed" | sha256sum 2>/dev/null | cut -c1-6)
    if [[ ! "$hash" =~ ^[0-9a-f]{6}$ ]]; then
        echo "wv: cannot generate a node id: no sha256 tool (sha256sum or shasum) produced a digest" >&2
        return 1
    fi
    echo "wv-$hash"
}

# ═══════════════════════════════════════════════════════════════════════════
# ID Validation
# ═══════════════════════════════════════════════════════════════════════════

# Validate weave ID format (prevents SQL injection via malformed IDs)
# Returns 0 if valid, 1 if invalid
validate_id() {
    local id="$1"
    # Accept 4-char (legacy) and 6-char (v1.2+) IDs
    if [[ "$id" =~ ^wv-[a-f0-9]{4,6}$ ]]; then
        return 0
    fi
    # Check if it's a valid alias (alphanumeric + hyphens, 2-50 chars)
    if [[ "$id" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]{1,49}$ ]]; then
        # Verify alias exists in DB — prefer non-done nodes
        local resolved
        resolved=$(sqlite3 "$WV_DB" "SELECT id FROM nodes WHERE alias='$(sql_escape "$id")' ORDER BY CASE WHEN status='done' THEN 1 ELSE 0 END LIMIT 1;" 2>/dev/null)
        if [ -n "$resolved" ]; then
            return 0
        fi
    fi
    echo -e "${RED}Error: invalid node ID or alias '$id' (expected wv-XXXXXX or alias)${NC}" >&2
    return 1
}

# Resolve an alias or ID to the canonical wv-xxxxxx ID.
# Returns the input unchanged if it's already a wv-xxxxxx ID.
resolve_id() {
    local id="$1"
    # Accept 4-char (legacy) and 6-char (v1.2+) IDs
    if [[ "$id" =~ ^wv-[a-f0-9]{4,6}$ ]]; then
        echo "$id"
        return 0
    fi
    # Resolve alias — prefer non-done nodes when duplicates exist
    local resolved
    resolved=$(sqlite3 "$WV_DB" "SELECT id FROM nodes WHERE alias='$(sql_escape "$id")' ORDER BY CASE WHEN status='done' THEN 1 ELSE 0 END LIMIT 1;" 2>/dev/null)
    if [ -n "$resolved" ]; then
        echo "$resolved"
        return 0
    fi
    echo -e "${RED}Error: alias '$id' not found${NC}" >&2
    return 1
}

# ═══════════════════════════════════════════════════════════════════════════
# SQL Escaping
# ═══════════════════════════════════════════════════════════════════════════

# Escape text for SQL (single quotes)
sql_escape() {
    local text="$1"
    echo "${text//\'/\'\'}"
}

# Validate a metadata key name (callers splice these into SQLite JSON-path
# literals like '$.${key}' where escape-doubling would not help — the value
# must contain no quote or path-breaking chars).
# Usage: validate_metadata_key "$key" || return 1
validate_metadata_key() {
    local key="$1"
    if [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_.-]*$ ]]; then
        return 0
    fi
    echo -e "${RED}Error: invalid metadata key '$key' (must match [A-Za-z_][A-Za-z0-9_.-]*)${NC}" >&2
    return 1
}

# ═══════════════════════════════════════════════════════════════════════════
# Status Validation
# ═══════════════════════════════════════════════════════════════════════════

# Valid node statuses (tight enum). Every one must be in the status enum of
# contracts/node-field-registry-v1.json, which the Delta v2 writer and replayer
# enforce: blocked-external was outside it, so each move into or out of it lost
# its v2 sidecar (wv-38825f). tests/test-status-authority.sh pins the copies.
VALID_STATUSES="todo active done blocked blocked-external"

# Validate node status against allowed enum
# Usage: validate_status "active" || return 1
validate_status() {
    local status="$1"
    for valid in $VALID_STATUSES; do
        if [ "$status" = "$valid" ]; then
            return 0
        fi
    done
    echo -e "${RED}Error: invalid status '$status'${NC}" >&2
    echo "Valid statuses: $VALID_STATUSES" >&2
    return 1
}

# Valid risk_level values. The authority is contracts/node-field-registry-v1.json
# (fields.risk_level.value.enum). The Delta v2 writer (RISK_LEVELS in
# wv-delta.sh) and replayer (wv-delta-v2-replay.py) enforce the same set, and
# replay treats any other value as a hard integrity failure, so a value the
# CLI stored outside it made every later update of that node degrade silently
# to an SQL-only delta (wv-c0c51e). tests/test-risk-level-authority.sh pins all
# four copies to the contract.
VALID_RISK_LEVELS="none low medium high"

# validate_risk_level <value> <source-label>
validate_risk_level() {
    local value="$1" source="${2:-risk_level}" valid
    for valid in $VALID_RISK_LEVELS; do
        [ "$value" = "$valid" ] && return 0
    done
    echo -e "${RED}Error: $source must be one of ${VALID_RISK_LEVELS// /|} (got: $value)${NC}" >&2
    return 1
}

# validate_metadata_risk_level <metadata-json> <source-label>
# Refuse a metadata document that sets a risk_level the contract does not
# admit. Absent or null is fine; a patch that does not touch it is unaffected.
validate_metadata_risk_level() {
    local value
    value=$(printf '%s' "$1" | jq -r 'if type == "object" and has("risk_level") and .risk_level != null
        then (.risk_level | tostring) else empty end' 2>/dev/null) || return 0
    [ -z "$value" ] || validate_risk_level "$value" "${2:-metadata} risk_level"
}

# Node kinds (ontology S1, wv-f7dfd3). The authority is contracts/node-kinds-v1.json;
# tests/test-node-kind.sh pins these copies to it. The kind is stored in
# metadata.node_kind (metadata.kind is already the memory category) and mirrored
# to metadata.type for one release, so the generated type column, and an older
# wv reading the same committed graph, agree with it. unknown is written only by
# the backfill: it records that a node carried no evidence of its kind.
VALID_NODE_KINDS="epic feature task finding decision plan memory session_history unknown"
WRITABLE_NODE_KINDS="epic feature task finding decision plan memory session_history"

# jq definitions shared by creation and the backfill. A text prefix is a leading
# word followed by ( or :, in any case (epic(, Fix:). wv_prefix_kind maps a
# node's text to the kind its prefix names, or null when the text has none; a
# prefix the map does not name (fix(, docs:, finding( ...) is a task (D1, D2).
# wv_kinds is every kind, unknown included, so a second backfill keeps it.
# wv_backfill_kind applies the backfill precedence to one node row:
# node_kind, then type (a value outside the kinds becomes task), then the text
# prefix, then unknown. disagrees marks a prefix that names a different kind;
# mirror_mismatch marks a type an older wv changed without node_kind.
WV_KIND_JQ_DEFS='
def wv_kinds: ["epic", "feature", "task", "finding", "decision", "plan", "memory", "session_history", "unknown"];
def wv_kind_prefix_map: {epic: "epic", feature: "feature", decision: "decision", decide: "decision",
    plan: "plan", proposal: "plan", spec: "plan", milestone: "plan"};
def wv_text_prefix: ([(. // "") | ascii_downcase | capture("^\\s*(?<p>[a-z_-]+)[(:]")][0].p // null);
def wv_prefix_kind: wv_text_prefix as $p | if $p == null then null else (wv_kind_prefix_map[$p] // "task") end;
def wv_backfill_kind:
    (.metadata | if type == "string" then (fromjson? // {}) else (. // {}) end) as $m
    | (.text | wv_text_prefix) as $p
    | (.text | wv_prefix_kind) as $pk
    | (if ($m.node_kind | type) == "string" and (wv_kinds | index($m.node_kind)) != null
          then {kind: $m.node_kind, source: "node_kind"}
       elif $m.type != null then
          (if (wv_kinds | index($m.type | tostring)) != null then {kind: ($m.type | tostring), source: "type"}
           else {kind: "task", source: "type_outside_kinds"} end)
       elif $pk != null then {kind: $pk, source: "text_prefix"}
       else {kind: "unknown", source: "no_evidence"} end) as $r
    | {id, status, prefix: $p, type: $m.type, kind: $r.kind, source: $r.source,
       write: ($m.node_kind != $r.kind or $m.type != $r.kind),
       mirror_mismatch: ($m.node_kind != null and $m.type != null and $m.node_kind != $m.type),
       disagrees: ($p != null and ((((wv_kinds | index($p)) != null) and $p != $r.kind)
                                   or ($pk != "task" and $pk != $r.kind)))};
'

# validate_node_kind <value> <source-label> — a kind a command may write.
validate_node_kind() {
    local value="$1" source="${2:-kind}" valid
    for valid in $WRITABLE_NODE_KINDS; do
        [ "$value" = "$valid" ] && return 0
    done
    echo -e "${RED}Error: $source must be one of ${WRITABLE_NODE_KINDS// /|} (got: $value)${NC}" >&2
    echo "  A change type (fix, bug, refactor, docs ...) belongs in the text prefix, not the kind." >&2
    return 1
}

# wv_kind_patch_metadata <metadata-json> <source-label>
# Normalise a metadata document that touches the kind: node_kind or type alone
# is mirrored to the other, the two must agree, the value must be writable, and
# neither may be null (a merge patch would remove it). A document touching
# neither is echoed unchanged.
wv_kind_patch_metadata() {
    local metadata="$1" source="${2:-metadata}" verdict kind
    verdict=$(printf '%s' "$metadata" | jq -c '
        (has("node_kind")) as $hk | (has("type")) as $ht
        | if ($hk | not) and ($ht | not) then {touch: false}
          elif ($hk and .node_kind == null) or ($ht and .type == null) then {error: "null"}
          elif $hk and $ht and .node_kind != .type then {error: "conflict", node_kind: .node_kind, type: .type}
          else {touch: true, kind: ((if $hk then .node_kind else .type end) | tostring)} end') || {
        echo -e "${RED}Error: could not read the kind in ${source}${NC}" >&2
        return 1
    }
    case "$(jq -r '.error // (if .touch then "touch" else "none" end)' <<< "$verdict")" in
        none) printf '%s\n' "$metadata"; return 0 ;;
        null)
            echo -e "${RED}Error: ${source} cannot remove the node kind (node_kind/type set to null)${NC}" >&2
            return 1 ;;
        conflict)
            echo -e "${RED}Error: ${source} sets node_kind and type to different values ($(jq -r '"\(.node_kind) vs \(.type)"' <<< "$verdict"))${NC}" >&2
            echo "  type mirrors node_kind; set one of them, or use --kind=<kind>." >&2
            return 1 ;;
    esac
    kind=$(jq -r '.kind' <<< "$verdict")
    validate_node_kind "$kind" "${source} node kind" || return 1
    printf '%s' "$metadata" | jq -c --arg k "$kind" '. + {node_kind: $k, type: $k}'
}

# wv_kind_create_metadata <metadata-json> <text> <kind-flag> <source-label>
# The metadata a new node is stored with: its kind is --kind, else the
# metadata's node_kind or type, else the kind the text prefix names, else task
# (contracts/node-kinds-v1.json create.precedence).
wv_kind_create_metadata() {
    local metadata="$1" text="$2" kind_flag="$3" source="${4:-metadata}" kind
    if [ -n "$kind_flag" ]; then
        validate_node_kind "$kind_flag" "--kind" || return 1
        if ! printf '%s' "$metadata" | jq -se --arg k "$kind_flag" \
            'length == 1 and (.[0] | [.node_kind, .type] | map(select(. != null)) | all(. == $k))' >/dev/null 2>&1; then
            echo -e "${RED}Error: --kind=$kind_flag disagrees with the kind in ${source}${NC}" >&2
            return 1
        fi
        printf '%s' "$metadata" | jq -c --arg k "$kind_flag" '. + {node_kind: $k, type: $k}'
        return
    fi
    if printf '%s' "$metadata" | jq -se 'length == 1 and (.[0] | has("node_kind") or has("type"))' >/dev/null 2>&1; then
        wv_kind_patch_metadata "$metadata" "$source"
        return
    fi
    kind=$(jq -rn --arg t "$text" "$WV_KIND_JQ_DEFS"' $t | wv_prefix_kind // "task"') || return 1
    printf '%s' "$metadata" | jq -c --arg k "$kind" '. + {node_kind: $k, type: $k}'
}

# _wv_reject_arg <command> <argument>
# The default branch of a write-path argument parser (wv-86a96a): an argument
# no branch consumed fails the command before it writes, instead of being
# skipped while the success line prints (a typo such as --learnings= used to
# close a node and drop the learning). Always returns 1.
_wv_reject_arg() {
    echo -e "${RED}Error: unknown argument '$2' for wv $1${NC}" >&2
    echo "Run 'wv $1 --help' for usage." >&2
    return 1
}

# validate_metadata_canonical_numbers <metadata-json> <source-label>
# Refuse a metadata document holding a non-integer number (wv-855394).
# weave.canonical-json.v1 admits integers only, so the Delta v2 sidecar encoder
# rejects a float and every later write to the node degrades to an SQL-only
# delta. Judged by Python's parser, the one the encoder uses: jq reads 1.0 and
# 1e3 as integers, Python as floats. No python3 means no sidecar to protect.
validate_metadata_canonical_numbers() {
    command -v python3 >/dev/null 2>&1 || return 0
    local bad
    bad=$(printf '%s' "$1" | python3 -c '
import json, sys
found = []
def reject(token):
    found.append(token)
    return 0
try:
    json.loads(sys.stdin.read(), parse_float=reject, parse_constant=reject)
except ValueError:
    pass
print(" ".join(found[:3]))
' 2>/dev/null) || return 0
    [ -z "$bad" ] && return 0
    echo -e "${RED}Error: ${2:-metadata} holds a non-integer number ($bad); metadata numbers must be integers (weave.canonical-json.v1) - store a scaled integer (e.g. milliseconds) or a decimal string${NC}" >&2
    return 1
}

# ═══════════════════════════════════════════════════════════════════════════
# Edge Type Validation
# ═══════════════════════════════════════════════════════════════════════════

# Valid edge types (tight enum to prevent sprawl)
VALID_EDGE_TYPES="blocks relates_to implements contradicts supersedes references obsoletes addresses resolves"

# ═══════════════════════════════════════════════════════════════════════════
# Finding Schema Constants
# ═══════════════════════════════════════════════════════════════════════════

# Valid violation_type values for finding nodes.
# Sourced by both wv-cmd-core.sh (_finding_missing_fields) and
# pre-close-verification.sh so the enum stays in one place.
# measurement-gap added 2026-06-10 (wv-01c378): distinct observability-gap class the
# validator lagged; see docs/PATTERNS-rust-signatures.md Pattern C reconciliation.
#
# The list itself now comes from contracts/violation-vocabulary-v1.json, projected
# into wv-violation-vocabulary.gen.sh by scripts/gen-violation-vocabulary.sh. It is
# sourced HERE rather than from scripts/wv so the entry point stays out of the
# changed hash-bound surface; the fallback keeps a stale or partial install
# validating rather than accepting anything, since an empty enum would make every
# violation_type invalid and block every finding close.
_wv_vocabulary_projection="${BASH_SOURCE[0]%/*}/wv-violation-vocabulary.gen.sh"
if [ -f "$_wv_vocabulary_projection" ]; then
    # shellcheck source=scripts/lib/wv-violation-vocabulary.gen.sh
    . "$_wv_vocabulary_projection"
fi
unset _wv_vocabulary_projection
: "${FINDING_VIOLATION_TYPES:=historical:defect upstream:management-gap upstream:logic-bug upstream:schema-drift repo:hygiene repo:regression test:gap design:flaw measurement-gap}"
# A repository's own types (wv-60bf88): each top-level .weave/patterns/*.yaml
# declaring violation_type: project:<name> adds it, in this repository only.
# Builtins only, as every wv call sources this file; weave_quality's
# guides.project_types reads the same declaration for coaching.
if [ -n "${REPO_ROOT:-}" ] && [ -d "$REPO_ROOT/.weave/patterns" ]; then
    for _wv_pattern_file in "$REPO_ROOT"/.weave/patterns/*.yaml; do
        [ -f "$_wv_pattern_file" ] || continue
        mapfile -t _wv_pattern_lines < "$_wv_pattern_file" || continue
        for _wv_pattern_line in "${_wv_pattern_lines[@]}"; do
            if [[ "$_wv_pattern_line" =~ ^violation_type:[[:space:]]*(project:[a-z0-9]+(-[a-z0-9]+)*)[[:space:]]*$ ]]; then
                case " $FINDING_VIOLATION_TYPES " in
                    *" ${BASH_REMATCH[1]} "*) ;;
                    *) FINDING_VIOLATION_TYPES+=" ${BASH_REMATCH[1]}" ;;
                esac
                break
            fi
        done
    done
    unset _wv_pattern_file _wv_pattern_lines _wv_pattern_line
fi

# Valid session phase values — single source of truth.
# Written via wv_set_phase(); read by pre-action.sh + context-guard.sh.
PHASE_VALUES="discover execute closing"

# Validate edge type against allowed enum
# Usage: validate_edge_type "implements" || return 1
validate_edge_type() {
    local edge_type="$1"
    local valid=false

    for valid_type in $VALID_EDGE_TYPES; do
        if [ "$edge_type" = "$valid_type" ]; then
            valid=true
            break
        fi
    done

    if [ "$valid" = false ]; then
        echo -e "${RED}Error: invalid edge type '$edge_type'${NC}" >&2
        echo -e "Valid types: $VALID_EDGE_TYPES" >&2
        # Naming the closest type beats reprinting the whole enum. A dependency
        # edge is the common first guess and 'blocks' is its INVERSE, not its
        # synonym, so say which way round the arguments go rather than letting
        # the user create a silently reversed edge.
        case "$edge_type" in
            depends_on|depends|dependson|requires|needs|needed_by|blocked_by)
                echo -e "Hint: use 'blocks' with the arguments reversed — 'wv link <blocker> <blocked> --type=blocks' expresses '<blocked> depends on <blocker>'." >&2 ;;
            parent|parent_of|child|child_of|subtask|subtask_of)
                echo -e "Hint: parent links are 'implements', child first — 'wv link <child> <parent> --type=implements'." >&2 ;;
            fixes|fixed_by|closes|solves)
                echo -e "Hint: closest types are 'resolves' (task to its finding) and 'addresses' (source addresses a pitfall in target)." >&2 ;;
            duplicates|duplicate_of|replaces|replaced_by)
                echo -e "Hint: closest types are 'supersedes' (target replaces source) and 'obsoletes' (target makes source obsolete)." >&2 ;;
            related|related_to|relates|see_also|mentions|refs)
                echo -e "Hint: closest types are 'relates_to' and 'references'." >&2 ;;
        esac
        return 1
    fi

    return 0
}

# ═══════════════════════════════════════════════════════════════════════════
# Stdin Input
# ═══════════════════════════════════════════════════════════════════════════

# Answer whether stdin carries input a command may read, without consuming it.
# Usage: if stdin_has_input; then input=$(cat); fi
#
# Reading stdin unconditionally blocks until the writer closes it. A command
# with no other input source therefore waits forever when wv inherits an
# unrelated open descriptor on fd 0 — `sleep 20 | wv refs`, or a harness that
# leaves a pipe open — with no output and no timeout. That stalled
# tests/test-data.sh for 900s at the refs section and read as a concurrency
# fault (wv-f541e1). A terminal is not treated as piped input at all.
#
# `read -t 0` reports readability without reading a byte, so a caller may still
# consume the stream in full afterwards, whether by `cat` or by redirection.
# It answers immediately for a regular file, a redirect, and a closed pipe (EOF
# is a ready condition); only a pipe that is open with nothing in it is unknown,
# so that is the single case worth waiting on. The wait is bounded, and bounded
# on the FIRST byte only — a producer that has started still gets to finish.
stdin_has_input() {
    local timeout="${WV_STDIN_TIMEOUT:-2}"
    # A malformed override must not turn a bounded wait into an unbounded one,
    # nor into an arithmetic error at the comparison below.
    [[ "$timeout" =~ ^[0-9]+$ ]] || timeout=2

    [ -t 0 ] && return 1

    local waited=0
    local deadline=$((timeout * 10))
    while :; do
        read -t 0 && return 0
        [ "$waited" -ge "$deadline" ] && return 1
        sleep 0.1
        waited=$((waited + 1))
    done
}

# Credential shapes refused in graph text (wv-320587). Graph text is committed
# to .weave/ and mirrored to GitHub issues by wv sync --gh, so a token pasted
# into a node, a learning or a memory is published twice. Each entry is
# "<shape><TAB><ERE>"; order matters only for naming (sk-ant- before sk-).
# Shapes are whole tokens of a known form, not bare prefixes: the graph talks
# about ghp_ and AKIA without holding one. Every write path that persists free
# text runs this list (wv-320587 records the scope).
_WV_CREDENTIAL_SHAPES=(
    "github_token	(^|[^A-Za-z0-9_])(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{36}([^A-Za-z0-9]|$)"
    "github_pat	github_pat_[A-Za-z0-9_]{60,}"
    "anthropic_key	sk-ant-[A-Za-z0-9_-]{20,}"
    "openai_key	(^|[^A-Za-z0-9_-])sk-(proj-|svcacct-)?[A-Za-z0-9_-]{32,}"
    "aws_access_key	(^|[^A-Z0-9])(AKIA|ASIA)[0-9A-Z]{16}([^A-Z0-9]|$)"
    "private_key	-----BEGIN ([A-Z0-9]+ )*PRIVATE KEY-----"
    "slack_token	xox[abprs]-[A-Za-z0-9-]{10,}"
    "google_api_key	AIza[0-9A-Za-z_-]{35}"
    "url_credentials	[A-Za-z][A-Za-z0-9+.-]*://[^/[:space:]:@\"'<>]+:[^/[:space:]@\"'<>]+@[A-Za-z0-9.-]+"
    "bearer_token	[Bb]earer[[:space:]]+[A-Za-z0-9._~+/-]{24,}=*"
)

# wv_credential_regex — every shape as one ERE alternation, for scanning many
# lines in one grep (wv doctor's graph sweep).
wv_credential_regex() {
    local entry any=""
    for entry in "${_WV_CREDENTIAL_SHAPES[@]}"; do any="${any:+$any|}(${entry#*$'\t'})"; done
    printf '%s\n' "$any"
}

# wv_credential_shape <text> — print the first credential shape <text> holds
# and return 0, or return 1. One grep over every shape first, so text with no
# credential (nearly every call) costs one process.
wv_credential_shape() {
    local entry
    grep -qE -- "$(wv_credential_regex)" <<< "$1" 2>/dev/null || return 1
    for entry in "${_WV_CREDENTIAL_SHAPES[@]}"; do
        if grep -qE -- "${entry#*$'\t'}" <<< "$1" 2>/dev/null; then
            printf '%s\n' "${entry%%$'\t'*}"
            return 0
        fi
    done
    return 1
}

# wv_credential_refuse <where> <text> — 0 when <text> holds no credential;
# else name the shape (never the value) on stderr and return 1. Refused, not
# redacted: the caller retries without the secret, and stored text is never
# silently different from what was written.
wv_credential_refuse() {
    local shape
    shape=$(wv_credential_shape "$2") || return 0
    echo -e "${RED:-}Error: $1 holds a credential-shaped string ($shape); refused.${NC:-}" >&2
    echo "  Graph text is committed to .weave/ and mirrored to GitHub issues. Remove the secret and retry (wv-320587)." >&2
    return 1
}

# wv_credential_refuse_file <where> <path> — wv_credential_refuse over a file's
# content; an unreadable file is left to the caller's own error.
wv_credential_refuse_file() {
    [ -r "$2" ] || return 0
    wv_credential_refuse "$1" "$(cat -- "$2" 2>/dev/null)"
}
