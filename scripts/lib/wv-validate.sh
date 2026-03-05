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
        # Verify alias exists in DB
        local resolved
        resolved=$(sqlite3 "$WV_DB" "SELECT id FROM nodes WHERE alias='$(sql_escape "$id")' LIMIT 1;" 2>/dev/null)
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
    local resolved
    resolved=$(sqlite3 "$WV_DB" "SELECT id FROM nodes WHERE alias='$(sql_escape "$id")' LIMIT 1;" 2>/dev/null)
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

# ═══════════════════════════════════════════════════════════════════════════
# Edge Type Validation
# ═══════════════════════════════════════════════════════════════════════════

# Valid edge types (tight enum to prevent sprawl)
VALID_EDGE_TYPES="blocks relates_to implements contradicts supersedes references obsoletes addresses"

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
        return 1
    fi

    return 0
}
