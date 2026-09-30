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
    local seed="$(date +%s%N)$$${RANDOM}"
    local hash=$(echo -n "$seed" | sha256sum | cut -c1-6)
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

# Valid node statuses (tight enum)
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
