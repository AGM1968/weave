#!/bin/bash
# wv-cmd-graph.sh — Graph traversal and edge commands
#
# Commands: block, link, resolve, related, edges, path, context
# Sourced by: wv entry point (after lib modules)
# Dependencies: wv-config.sh, wv-db.sh, wv-validate.sh, wv-cache.sh

# ═══════════════════════════════════════════════════════════════════════════
# cmd_block — Mark node as blocked by another
# ═══════════════════════════════════════════════════════════════════════════

cmd_block() {
    local id="${1:-}"
    local blocker=""

    shift || true
    while [ $# -gt 0 ]; do
        case "$1" in
            --by=*) blocker="${1#*=}" ;;
        esac
        shift
    done

    if [ -z "$id" ] || [ -z "$blocker" ]; then
        echo -e "${RED}Error: usage: wv block <id> --by=<blocker-id>${NC}" >&2
        return 1
    fi

    # Validate ID formats (SQL injection prevention)
    validate_id "$id" || return 1
    validate_id "$blocker" || return 1

    # Prevent self-blocking
    if [ "$id" = "$blocker" ]; then
        echo -e "${RED}Error: a node cannot block itself${NC}" >&2
        return 1
    fi

    # Check for circular blocking (A blocks B, B blocks A)
    local reverse_exists
    reverse_exists=$(db_query "SELECT COUNT(*) FROM edges WHERE source='$id' AND target='$blocker' AND type='blocks';")
    if [ "$reverse_exists" != "0" ]; then
        echo -e "${RED}Error: circular block detected — $blocker is already blocked by $id${NC}" >&2
        return 1
    fi

    db_query "INSERT OR IGNORE INTO edges (source, target, type, weight, context, created_at) VALUES ('$blocker', '$id', 'blocks', 1.0, '{}', CURRENT_TIMESTAMP);"
    db_query "UPDATE nodes SET status='blocked', updated_at=CURRENT_TIMESTAMP WHERE id='$id';"

    # Invalidate context cache for affected nodes
    invalidate_context_cache "$id" "$blocker"

    echo -e "${GREEN}✓${NC} $id is now blocked by $blocker"

    # Live progress notification to GitHub
    gh_notify "$id" "block" --blocker="$blocker"
}

# ═══════════════════════════════════════════════════════════════════════════
# cmd_link — Create an edge between nodes
# ═══════════════════════════════════════════════════════════════════════════

cmd_link() {
    local from="${1:-}"
    local to="${2:-}"
    local edge_type=""
    local weight="1.0"
    local context="{}"

    shift 2 || {
        echo -e "${RED}Error: usage: wv link <from-id> <to-id> --type=<type> [--weight=<weight>] [--context=<json>]${NC}" >&2
        echo -e "Valid types: $VALID_EDGE_TYPES" >&2
        return 1
    }

    # Resolve aliases to IDs
    from=$(resolve_id "$from") || return 1
    to=$(resolve_id "$to") || return 1

    while [ $# -gt 0 ]; do
        case "$1" in
            --type=*) edge_type="${1#*=}" ;;
            --weight=*) weight="${1#*=}" ;;
            --context=*) context="${1#*=}" ;;
        esac
        shift
    done

    # Validate required arguments
    if [ -z "$from" ] || [ -z "$to" ] || [ -z "$edge_type" ]; then
        echo -e "${RED}Error: from, to, and --type are required${NC}" >&2
        echo -e "Usage: wv link <from-id> <to-id> --type=<type> [--weight=<weight>] [--context=<json>]" >&2
        return 1
    fi

    # Validate ID formats (SQL injection prevention)
    validate_id "$from" || return 1
    validate_id "$to" || return 1

    # Validate edge type
    validate_edge_type "$edge_type" || return 1

    # Validate weight is a number between 0.0 and 1.0
    if ! [[ "$weight" =~ ^[0-9]*\.?[0-9]+$ ]]; then
        echo -e "${RED}Error: weight must be a number${NC}" >&2
        return 1
    fi
    if (( $(echo "$weight < 0 || $weight > 1" | bc -l 2>/dev/null || echo 0) )); then
        echo -e "${RED}Error: weight must be between 0.0 and 1.0${NC}" >&2
        return 1
    fi

    # Validate nodes exist
    local from_exists
    from_exists=$(db_query "SELECT COUNT(*) FROM nodes WHERE id='$from';")
    if [ "$from_exists" = "0" ]; then
        echo -e "${RED}Error: source node $from not found${NC}" >&2
        return 1
    fi

    local to_exists
    to_exists=$(db_query "SELECT COUNT(*) FROM nodes WHERE id='$to';")
    if [ "$to_exists" = "0" ]; then
        echo -e "${RED}Error: target node $to not found${NC}" >&2
        return 1
    fi

    # Validate JSON context
    if ! echo "$context" | jq '.' >/dev/null 2>&1; then
        echo -e "${RED}Error: invalid JSON in --context${NC}" >&2
        return 1
    fi

    # Escape single quotes in context JSON for SQL
    local ctx_escaped="${context//\'/\'\'}"

    # Insert or update edge
    db_query "INSERT INTO edges (source, target, type, weight, context, created_at)
        VALUES ('$from', '$to', '$edge_type', $weight, '$ctx_escaped', CURRENT_TIMESTAMP)
        ON CONFLICT(source, target, type) DO UPDATE SET
            weight = excluded.weight,
            context = excluded.context,
            created_at = CURRENT_TIMESTAMP;"

    # Invalidate context cache for affected  nodes
    invalidate_context_cache "$from" "$to"

    echo -e "${GREEN}✓${NC} Linked: $from --[$edge_type]--> $to (weight: $weight)" >&2
}

# ═══════════════════════════════════════════════════════════════════════════
# cmd_resolve — Resolve contradictions between nodes
# ═══════════════════════════════════════════════════════════════════════════

cmd_resolve() {
    if [ $# -lt 2 ]; then
        echo -e "${RED}Error: usage: wv resolve <node1> <node2> --winner=<id> | --merge | --defer [--rationale=<text>]${NC}" >&2
        return 1
    fi
    
    local node1="$1"
    local node2="$2"
    local mode=""
    local winner=""
    local rationale=""

    shift 2

    while [ $# -gt 0 ]; do
        case "$1" in
            --winner=*) mode="winner"; winner="${1#*=}" ;;
            --merge) mode="merge" ;;
            --defer) mode="defer" ;;
            --rationale=*) rationale="${1#*=}" ;;
        esac
        shift
    done

    # Validate required arguments
    if [ -z "$node1" ] || [ -z "$node2" ]; then
        echo -e "${RED}Error: two node IDs required${NC}" >&2
        return 1
    fi

    if [ -z "$mode" ]; then
        echo -e "${RED}Error: resolution mode required (--winner, --merge, or --defer)${NC}" >&2
        return 1
    fi

    # Validate nodes exist
    for nid in "$node1" "$node2"; do
        local exists
        exists=$(db_query "SELECT COUNT(*) FROM nodes WHERE id='$nid';")
        if [ "$exists" = "0" ]; then
            echo -e "${RED}Error: node $nid not found${NC}" >&2
            return 1
        fi
    done

    # Check if contradiction edge exists (either direction)
    local edge_exists
    edge_exists=$(db_query "
        SELECT COUNT(*) FROM edges
        WHERE type='contradicts'
        AND ((source='$node1' AND target='$node2')
          OR (source='$node2' AND target='$node1'));
    ")

    if [ "$edge_exists" = "0" ]; then
        echo -e "${YELLOW}Warning: no contradiction edge exists between $node1 and $node2${NC}" >&2
        echo "Proceeding with resolution anyway..."
    fi

    # Execute resolution based on mode
    case "$mode" in
        winner)
            # Validate winner is one of the two nodes
            if [ "$winner" != "$node1" ] && [ "$winner" != "$node2" ]; then
                echo -e "${RED}Error: --winner must be either $node1 or $node2${NC}" >&2
                return 1
            fi

            local loser
            if [ "$winner" = "$node1" ]; then
                loser="$node2"
            else
                loser="$node1"
            fi

            # Remove contradiction edge
            db_query "DELETE FROM edges WHERE type='contradicts' AND ((source='$node1' AND target='$node2') OR (source='$node2' AND target='$node1'));"

            # Add supersedes edge: winner supersedes loser
            db_query "INSERT OR IGNORE INTO edges (source, target, type, weight, context, created_at) VALUES ('$winner', '$loser', 'supersedes', 1.0, '{}', CURRENT_TIMESTAMP);"

            # Mark loser as done/obsolete
            db_query "UPDATE nodes SET status='done', updated_at=CURRENT_TIMESTAMP WHERE id='$loser';"

            echo -e "${GREEN}✓${NC} Resolved: $winner supersedes $loser"
            [ -n "$rationale" ] && echo "  Rationale: $rationale"
            ;;

        merge)
            # Create new merged node
            local merged_text="Merged: $(db_query "SELECT text FROM nodes WHERE id='$node1';" | head -1) + $(db_query "SELECT text FROM nodes WHERE id='$node2';" | head -1)"
            local new_id=$(generate_id)

            db_query "INSERT INTO nodes (id, text, status, metadata, created_at) VALUES ('$new_id', '$merged_text', 'todo', '{}', CURRENT_TIMESTAMP);"

            # Remove contradiction edge
            db_query "DELETE FROM edges WHERE type='contradicts' AND ((source='$node1' AND target='$node2') OR (source='$node2' AND target='$node1'));"

            # Add obsoletes edges: both nodes obsoleted by merger
            db_query "INSERT OR IGNORE INTO edges (source, target, type, weight, context, created_at) VALUES ('$new_id', '$node1', 'obsoletes', 1.0, '{}', CURRENT_TIMESTAMP);"
            db_query "INSERT OR IGNORE INTO edges (source, target, type, weight, context, created_at) VALUES ('$new_id', '$node2', 'obsoletes', 1.0, '{}', CURRENT_TIMESTAMP);"

            # Mark both original nodes as done
            db_query "UPDATE nodes SET status='done', updated_at=CURRENT_TIMESTAMP WHERE id IN ('$node1', '$node2');"

            echo -e "${GREEN}✓${NC} Resolved: created merged node $new_id (obsoletes $node1 and $node2)"
            [ -n "$rationale" ] && echo "  Rationale: $rationale"
            ;;

        defer)
            # Remove contradiction edge
            db_query "DELETE FROM edges WHERE type='contradicts' AND ((source='$node1' AND target='$node2') OR (source='$node2' AND target='$node1'));"

            # Add relates_to edge instead (bidirectional)
            db_query "INSERT OR IGNORE INTO edges (source, target, type, weight, context, created_at) VALUES ('$node1', '$node2', 'relates_to', 0.5, '{}', CURRENT_TIMESTAMP);"
            db_query "INSERT OR IGNORE INTO edges (source, target, type, weight, context, created_at) VALUES ('$node2', '$node1', 'relates_to', 0.5, '{}', CURRENT_TIMESTAMP);"

            echo -e "${GREEN}✓${NC} Resolved: contradiction deferred, marked as related ($node1 <-> $node2)"
            [ -n "$rationale" ] && echo "  Rationale: $rationale"
            ;;
    esac

    # Invalidate context cache for affected nodes
    invalidate_context_cache "$node1" "$node2" "${winner:-}" "${new_id:-}"
}

# ═══════════════════════════════════════════════════════════════════════════
# cmd_related — Show nodes related to a given node
# ═══════════════════════════════════════════════════════════════════════════

cmd_related() {
    local id="${1:-}"
    local edge_type=""
    local direction="both"
    local output_format="text"

    shift || true
    while [ $# -gt 0 ]; do
        case "$1" in
            --type=*) edge_type="${1#*=}" ;;
            --direction=*) direction="${1#*=}" ;;
            --json) output_format="json" ;;
        esac
        shift
    done

    if [ -z "$id" ]; then
        echo -e "${RED}Error: node ID required${NC}" >&2
        echo "Usage: wv related <id> [--type=<type>] [--direction=outbound|inbound|both] [--json]" >&2
        return 1
    fi

    # Validate ID format (SQL injection prevention)
    validate_id "$id" || return 1

    # Validate edge type if provided
    if [ -n "$edge_type" ]; then
        validate_edge_type "$edge_type" || return 1
    fi

    # Validate node exists
    local exists
    exists=$(db_query "SELECT COUNT(*) FROM nodes WHERE id='$id';")
    if [ "$exists" = "0" ]; then
        echo -e "${RED}Error: node $id not found${NC}" >&2
        return 1
    fi

    # Build type filter
    local type_filter=""
    if [ -n "$edge_type" ]; then
        type_filter="AND e.type = '$edge_type'"
    fi

    # Build query based on direction
    local query=""
    case "$direction" in
        outbound)
            query="SELECT e.target as node_id, n.text, e.type, e.weight, e.context, 'outbound' as direction
                   FROM edges e
                   JOIN nodes n ON n.id = e.target
                   WHERE e.source = '$id' $type_filter
                   ORDER BY e.type, e.weight DESC;"
            ;;
        inbound)
            query="SELECT e.source as node_id, n.text, e.type, e.weight, e.context, 'inbound' as direction
                   FROM edges e
                   JOIN nodes n ON n.id = e.source
                   WHERE e.target = '$id' $type_filter
                   ORDER BY e.type, e.weight DESC;"
            ;;
        both)
            query="SELECT * FROM (
                       SELECT e.target as node_id, n.text, e.type, e.weight, e.context, 'outbound' as direction
                       FROM edges e
                       JOIN nodes n ON n.id = e.target
                       WHERE e.source = '$id' $type_filter
                       UNION ALL
                       SELECT e.source as node_id, n.text, e.type, e.weight, e.context, 'inbound' as direction
                       FROM edges e
                       JOIN nodes n ON n.id = e.source
                       WHERE e.target = '$id' $type_filter
                   ) ORDER BY type, weight DESC;"
            ;;
        *)
            echo -e "${RED}Error: invalid direction '$direction'${NC}" >&2
            echo "Valid: outbound, inbound, both" >&2
            return 1
            ;;
    esac

    if [ "$output_format" = "json" ]; then
        db_query_json "$query"
    else
        # Use unit separator — node text can contain '|'
        local count=0
        while IFS=$'\x1f' read -r node_id text type weight context dir; do
            count=$((count + 1))
            local arrow
            if [ "$dir" = "outbound" ]; then
                arrow="--[$type]-->"
            else
                arrow="<--[$type]--"
            fi

            echo -e "${CYAN}$arrow${NC} ${GREEN}$node_id${NC}: $text"
            echo -e "    weight: $weight"
            if [ "$context" != "{}" ]; then
                echo -e "    context: $context"
            fi
            echo ""
        done < <(db_ensure; sqlite3 -batch -cmd ".timeout 5000" -separator $'\x1f' "$WV_DB" "$query")

        if [ "$count" = "0" ]; then
            echo "No related nodes found."
        fi
    fi
}

# ═══════════════════════════════════════════════════════════════════════════
# cmd_edges — Show all edges for a node
# ═══════════════════════════════════════════════════════════════════════════

cmd_edges() {
    local id="${1:-}"
    local edge_type=""
    local output_format="text"

    shift || true
    while [ $# -gt 0 ]; do
        case "$1" in
            --type=*) edge_type="${1#*=}" ;;
            --json) output_format="json" ;;
        esac
        shift
    done

    if [ -z "$id" ]; then
        echo -e "${RED}Error: node ID required${NC}" >&2
        echo "Usage: wv edges <id> [--type=<type>] [--json]" >&2
        return 1
    fi

    # Validate ID format (SQL injection prevention)
    validate_id "$id" || return 1

    # Validate edge type if provided
    if [ -n "$edge_type" ]; then
        validate_edge_type "$edge_type" || return 1
    fi

    # Validate node exists
    local exists
    exists=$(db_query "SELECT COUNT(*) FROM nodes WHERE id='$id';")
    if [ "$exists" = "0" ]; then
        echo -e "${RED}Error: node $id not found${NC}" >&2
        return 1
    fi

    # Build type filter
    local type_filter=""
    if [ -n "$edge_type" ]; then
        type_filter="AND e.type = '$edge_type'"
    fi

    # Query all edges involving this node
    local query="SELECT e.source, e.target, e.type, e.weight, e.context, e.created_at,
                        CASE WHEN e.source = '$id' THEN 'outbound' ELSE 'inbound' END as direction,
                        CASE WHEN e.source = '$id' THEN e.target ELSE e.source END as other_id,
                        n.text as other_text
                 FROM edges e
                 LEFT JOIN nodes n ON n.id = CASE WHEN e.source = '$id' THEN e.target ELSE e.source END
                 WHERE (e.source = '$id' OR e.target = '$id') $type_filter
                 ORDER BY e.type, e.weight DESC, e.created_at DESC;"

    if [ "$output_format" = "json" ]; then
        db_query_json "$query"
    else
        local count=0
        echo -e "${CYAN}Edges for $id:${NC}"
        echo ""

        while IFS='|' read -r source target type weight context created_at direction other_id other_text; do
            count=$((count + 1))

            # Format the edge
            if [ "$direction" = "outbound" ]; then
                echo -e "${GREEN}$count.${NC} $source --[${YELLOW}$type${NC}]--> $target"
            else
                echo -e "${GREEN}$count.${NC} $source <--[${YELLOW}$type${NC}]-- $target"
            fi

            echo -e "   Other node: ${CYAN}$other_id${NC}: $other_text"
            echo -e "   Weight: $weight"

            if [ "$context" != "{}" ] && [ -n "$context" ]; then
                echo -e "   Context: $context"
            fi

            if [ -n "$created_at" ]; then
                echo -e "   Created: $created_at"
            fi

            echo ""
        done < <(db_query "$query")

        if [ "$count" = "0" ]; then
            echo "No edges found."
        else
            echo -e "${CYAN}Total: $count edges${NC}"
        fi
    fi
}

# ═══════════════════════════════════════════════════════════════════════════
# cmd_path — Show ancestry chain for a node
# ═══════════════════════════════════════════════════════════════════════════

cmd_path() {
    local id="${1:-}"
    local format="text"

    shift || true
    while [ $# -gt 0 ]; do
        case "$1" in
            --format=*) format="${1#*=}" ;;
        esac
        shift
    done

    if [ -z "$id" ]; then
        echo -e "${RED}Error: node ID required${NC}" >&2
        return 1
    fi

    # Validate ID format (SQL injection prevention)
    validate_id "$id" || return 1

    # Validate node exists
    local exists
    exists=$(db_query "SELECT COUNT(*) FROM nodes WHERE id='$id';")
    if [ "$exists" = "0" ]; then
        echo -e "${RED}Error: node $id not found${NC}" >&2
        return 1
    fi

    # Recursive CTE for ancestry chain (with cycle detection and depth limit)
    # Uses ',id,' delimited path to prevent substring false-matches (wv-77cd fix)
    local query="
        WITH RECURSIVE ancestry AS (
            SELECT id, text, 0 as depth, ',' || id || ',' as path
            FROM nodes WHERE id = '$id'
            UNION
            SELECT n.id, n.text, a.depth + 1, a.path || n.id || ','
            FROM nodes n
            JOIN edges e ON e.source = n.id
            JOIN ancestry a ON e.target = a.id
            WHERE e.type = 'blocks'
              AND a.depth < 100
              AND instr(a.path, ',' || n.id || ',') = 0
        )
        SELECT DISTINCT id, text FROM ancestry ORDER BY depth DESC;
    "

    if [ "$format" = "chain" ]; then
        db_query "$query" | awk -F'|' '{printf "%s%s", sep, $2; sep=" → "} END {print ""}'
    else
        db_query "$query" | while IFS='|' read -r nid text; do
            echo "$nid: $text"
        done
    fi
}

# ═══════════════════════════════════════════════════════════════════════════
# cmd_context — Build Context Pack for a node
# ═══════════════════════════════════════════════════════════════════════════

cmd_context() {
    local id=""
    local format="text"

    while [ $# -gt 0 ]; do
        case "$1" in
            --json) format="json" ;;
            --*) ;; # skip other flags
            *) [ -z "$id" ] && id="$1" ;; # first non-flag arg is ID
        esac
        shift
    done

    # Use WV_ACTIVE if no ID provided (subagent context inheritance)
    if [ -z "$id" ]; then
        if [ -n "${WV_ACTIVE:-}" ]; then
            id="$WV_ACTIVE"
        else
            echo -e "${RED}Error: node ID required${NC}" >&2
            echo "Usage: wv context <id> --json" >&2
            echo "" >&2
            echo "Tip: Set WV_ACTIVE to enable automatic context inheritance:" >&2
            echo "  export WV_ACTIVE=wv-xxxxxx  # or use: wv work <id>" >&2
            return 1
        fi
    fi

    # Validate ID format (SQL injection prevention)
    validate_id "$id" || return 1

    # Validate node exists
    local exists
    exists=$(db_query "SELECT COUNT(*) FROM nodes WHERE id='$id';")
    if [ "$exists" = "0" ]; then
        echo -e "${RED}Error: node $id not found${NC}" >&2
        return 1
    fi

    if [ "$format" != "json" ]; then
        echo -e "${RED}Error: context command only supports --json output${NC}" >&2
        return 1
    fi

    # Cache setup (per session in tmpfs)
    local cache_dir="$WV_HOT_ZONE/context_cache"
    mkdir -p "$cache_dir"
    local cache_file="$cache_dir/${id}.json"

    # Check cache validity (invalidate on edge changes or node updates)
    if [ -f "$cache_file" ]; then
        # Get cache timestamp
        local cache_time
        cache_time=$(stat -c %Y "$cache_file" 2>/dev/null || stat -f %m "$cache_file" 2>/dev/null)

        # Get latest edge change time affecting this node
        local edge_time
        edge_time=$(db_query "
            SELECT MAX(CAST(strftime('%s', updated_at) AS INTEGER))
            FROM (
                SELECT updated_at FROM nodes WHERE id='$id'
                UNION ALL
                SELECT n.updated_at FROM edges e JOIN nodes n ON (n.id = e.source OR n.id = e.target)
                WHERE e.source = '$id' OR e.target = '$id'
            );
        " 2>/dev/null || echo "0")
        edge_time="${edge_time:-0}"

        # Cache is valid if newer than any edge/node changes
        if [ "$cache_time" -ge "$edge_time" ]; then
            cat "$cache_file"
            return 0
        fi
    fi

    # Get node details
    local node_json
    node_json=$(db_query_json "SELECT id, text, status, json(metadata), created_at, updated_at FROM nodes WHERE id='$id';")
    node_json="${node_json:-[]}"

    # Get blockers (nodes that block this one, excluding completed ones)
    local blockers_json
    blockers_json=$(db_query_json "
        SELECT n.id, n.text, n.status, json(n.metadata)
        FROM edges e
        JOIN nodes n ON n.id = e.source
        WHERE e.target = '$id' AND e.type = 'blocks' AND n.status != 'done';
    ")
    blockers_json="${blockers_json:-[]}"

    # Get ancestors (recursive blocking chain with cycle detection and depth limit)
    # Uses ',id,' delimited path to prevent substring false-matches (wv-77cd fix)
    local ancestors_json
    ancestors_json=$(db_query_json "
        WITH RECURSIVE ancestry AS (
            SELECT id, text, status, metadata, 0 as depth, ',' || id || ',' as path
            FROM nodes WHERE id = '$id'
            UNION ALL
            SELECT n.id, n.text, n.status, n.metadata, a.depth + 1, a.path || n.id || ','
            FROM nodes n
            JOIN edges e ON e.source = n.id
            JOIN ancestry a ON e.target = a.id
            WHERE e.type = 'blocks'
              AND a.depth < 100
              AND instr(a.path, ',' || n.id || ',') = 0
        )
        SELECT DISTINCT id, text, status, json(metadata) FROM ancestry WHERE depth > 0 ORDER BY depth DESC;
    ")
    ancestors_json="${ancestors_json:-[]}"

    # Get related nodes (non-blocking edges)
    local related_json
    related_json=$(db_query_json "
        SELECT e.target as id, n.text, n.status, e.type as edge, e.weight, e.context
        FROM edges e
        JOIN nodes n ON n.id = e.target
        WHERE e.source = '$id' AND e.type != 'blocks'
        UNION ALL
        SELECT e.source as id, n.text, n.status, e.type as edge, e.weight, e.context
        FROM edges e
        JOIN nodes n ON n.id = e.source
        WHERE e.target = '$id' AND e.type != 'blocks'
        ORDER BY weight DESC;
    ")
    related_json="${related_json:-[]}"

    # Get pitfalls scoped to node's ancestry chain (wv-517f fix)
    # Only include pitfalls from ancestor nodes or nodes connected to ancestors,
    # not unrelated global pitfalls.
    local pitfalls_json
    pitfalls_json=$(db_query_json "
        WITH RECURSIVE node_ancestry AS (
            SELECT id, ',' || id || ',' as path
            FROM nodes WHERE id = '$id'
            UNION ALL
            SELECT n.id, a.path || n.id || ','
            FROM nodes n
            JOIN edges e ON e.source = n.id
            JOIN node_ancestry a ON e.target = a.id
            WHERE e.type = 'blocks'
              AND instr(a.path, ',' || n.id || ',') = 0
        )
        SELECT DISTINCT n.id, n.text, n.status, json(n.metadata)
        FROM nodes n
        WHERE json_extract(n.metadata, '$.pitfall') IS NOT NULL
          AND (n.id IN (SELECT id FROM node_ancestry)
               OR n.id IN (SELECT e2.target FROM edges e2 WHERE e2.source IN (SELECT id FROM node_ancestry))
               OR n.id IN (SELECT e2.source FROM edges e2 WHERE e2.target IN (SELECT id FROM node_ancestry)))
        ORDER BY n.updated_at DESC;
    ")
    pitfalls_json="${pitfalls_json:-[]}"

    # Get contradictions (nodes with contradicts edges)
    local contradictions_json
    contradictions_json=$(db_query_json "
        SELECT DISTINCT n.id, n.text, n.status, json(n.metadata)
        FROM edges e
        JOIN nodes n ON (n.id = e.target OR n.id = e.source)
        WHERE e.type = 'contradicts'
          AND (e.source = '$id' OR e.target = '$id')
          AND n.id != '$id'
        ORDER BY n.updated_at DESC;
    ")
    contradictions_json="${contradictions_json:-[]}"

    # Compose Context Pack with field cleanup and limits (per proposal lines 222-237)
    jq -n \
        --argjson node "$node_json" \
        --argjson blockers "$blockers_json" \
        --argjson ancestors "$ancestors_json" \
        --argjson related "$related_json" \
        --argjson pitfalls "$pitfalls_json" \
        --argjson contradictions "$contradictions_json" \
        '{
            node: ($node[0] | {id, text, status}),
            blockers: ($blockers | map({id, text, status})),
            ancestors: ($ancestors | map({
                id,
                text,
                status,
                learnings: (
                    (.metadata | if type == "string" then fromjson else . end) as $meta |
                    {
                        decision: ($meta.decision // null),
                        pattern: ($meta.pattern // null),
                        pitfall: ($meta.pitfall // null)
                    } |
                    # Only include learnings object if at least one field is present
                    if (.decision or .pattern or .pitfall) then . else null end
                )
            })),
            related: ($related[0:5] | map({id, text, edge, weight})),
            pitfalls: ($pitfalls[0:3] | map({
                id,
                text,
                pitfall: ((.metadata | if type == "string" then fromjson else . end).pitfall)
            })),
            contradictions: ($contradictions | map({id, text, status}))
        }' | tee "$cache_file"
}

# ═══════════════════════════════════════════════════════════════════════════
# cmd_tree — Show epic-to-feature-to-task hierarchy via implements edges
# ═══════════════════════════════════════════════════════════════════════════

cmd_tree() {
    local show_active_only=false
    local max_depth=99
    local json_output=false
    local mermaid_output=false
    local root_filter=""

    while [ $# -gt 0 ]; do
        case "$1" in
            --active)    show_active_only=true ;;
            --depth=*)   max_depth="${1#*=}" ;;
            --json)      json_output=true ;;
            --mermaid)   mermaid_output=true ;;
            --root=*)    root_filter="${1#*=}" ;;
            --*)         ;;
            *)           root_filter="$1" ;;
        esac
        shift
    done

    db_ensure

    # Build the full tree using a recursive CTE on implements edges.
    # Roots are nodes that are NOT the source of any implements edge
    # (i.e., nothing implements them FROM this node — they have no parent).
    local query="
        WITH RECURSIVE tree AS (
            -- Roots: nodes that don't implement any other node
            SELECT n.id, n.text, n.status,
                   json_extract(n.metadata, '\$.type') as node_type,
                   0 as depth,
                   n.id as root_id
            FROM nodes n
            WHERE NOT EXISTS (
                SELECT 1 FROM edges e
                WHERE e.source = n.id AND e.type = 'implements'
            )
            AND n.status != 'done'

            UNION ALL

            -- Children: nodes that implement a parent
            SELECT n.id, n.text, n.status,
                   json_extract(n.metadata, '\$.type') as node_type,
                   t.depth + 1,
                   t.root_id
            FROM nodes n
            JOIN edges e ON e.source = n.id AND e.type = 'implements'
            JOIN tree t ON e.target = t.id
            WHERE t.depth < $max_depth
        )
        SELECT id, text, status, node_type, depth, root_id
        FROM tree
        ORDER BY root_id, depth, id;
    "

    # Also get done roots if not --active
    if [ "$show_active_only" = "false" ]; then
        query="
            WITH RECURSIVE tree AS (
                SELECT n.id, n.text, n.status,
                       json_extract(n.metadata, '\$.type') as node_type,
                       0 as depth,
                       n.id as root_id
                FROM nodes n
                WHERE NOT EXISTS (
                    SELECT 1 FROM edges e
                    WHERE e.source = n.id AND e.type = 'implements'
                )

                UNION ALL

                SELECT n.id, n.text, n.status,
                       json_extract(n.metadata, '\$.type') as node_type,
                       t.depth + 1,
                       t.root_id
                FROM nodes n
                JOIN edges e ON e.source = n.id AND e.type = 'implements'
                JOIN tree t ON e.target = t.id
                WHERE t.depth < $max_depth
            )
            SELECT id, text, status, node_type, depth, root_id
            FROM tree
            ORDER BY root_id, depth, id;
        "
    fi

    if [ "$json_output" = "true" ]; then
        local results
        results=$(db_query_json "
            WITH RECURSIVE tree AS (
                SELECT n.id, n.text, n.status,
                       json_extract(n.metadata, '\$.type') as node_type,
                       0 as depth,
                       n.id as root_id
                FROM nodes n
                WHERE NOT EXISTS (
                    SELECT 1 FROM edges e
                    WHERE e.source = n.id AND e.type = 'implements'
                )
                $([ "$show_active_only" = "true" ] && echo "AND n.status != 'done'")

                UNION ALL

                SELECT n.id, n.text, n.status,
                       json_extract(n.metadata, '\$.type') as node_type,
                       t.depth + 1,
                       t.root_id
                FROM nodes n
                JOIN edges e ON e.source = n.id AND e.type = 'implements'
                JOIN tree t ON e.target = t.id
                WHERE t.depth < $max_depth
            )
            SELECT id, text, status, node_type, depth, root_id
            FROM tree
            ORDER BY root_id, depth, id;
        ")
        [ -z "$results" ] && echo "[]" || echo "$results"
        return
    fi

    # Mermaid output: dependency graph with status colors
    if [ "$mermaid_output" = "true" ]; then
        local mermaid_query="
            WITH RECURSIVE tree AS (
                SELECT n.id, n.text, n.status, n.alias,
                       json_extract(n.metadata, '\$.type') as node_type,
                       0 as depth,
                       n.id as root_id
                FROM nodes n
                WHERE NOT EXISTS (
                    SELECT 1 FROM edges e
                    WHERE e.source = n.id AND e.type = 'implements'
                )
                $([ "$show_active_only" = "true" ] && echo "AND n.status != 'done'")

                UNION ALL

                SELECT n.id, n.text, n.status, n.alias,
                       json_extract(n.metadata, '\$.type') as node_type,
                       t.depth + 1,
                       t.root_id
                FROM nodes n
                JOIN edges e ON e.source = n.id AND e.type = 'implements'
                JOIN tree t ON e.target = t.id
                WHERE t.depth < $max_depth
            )
            SELECT id, text, status, alias, node_type, depth, root_id
            FROM tree
            ORDER BY root_id, depth, id;
        "
        # Resolve root filter if provided
        local filter_root=""
        if [ -n "$root_filter" ]; then
            filter_root=$(db_query "SELECT id FROM nodes WHERE id='$(sql_escape "$root_filter")' OR alias='$(sql_escape "$root_filter")' LIMIT 1;" 2>/dev/null)
        fi

        echo "graph TD"
        echo "    classDef done fill:#2da44e,stroke:#1a7f37,color:white"
        echo "    classDef active fill:#bf8700,stroke:#9a6700,color:white"
        echo "    classDef blocked fill:#cf222e,stroke:#a40e26,color:white"
        echo "    classDef todo fill:#656d76,stroke:#424a53,color:white"
        echo ""

        # Collect node IDs for inter-node edge queries
        local tree_ids=()
        local edges_output=""

        sqlite3 -batch -cmd ".timeout 5000" -separator $'\x1f' "$WV_DB" "$mermaid_query" | while IFS=$'\x1f' read -r id text status alias node_type depth root_id; do
            # Filter to specific root if requested
            if [ -n "$filter_root" ] && [ "$root_id" != "$filter_root" ]; then
                continue
            fi
            # Mermaid-safe ID: replace - with _
            local mid="${id//-/_}"
            # Label: prefer alias, fall back to truncated text
            local label="${alias:-$text}"
            label="${label:0:60}"
            # Escape Mermaid special chars — quotes protect against shape-syntax
            label="${label//\"/\'}"
            label="${label//\[/(}"
            label="${label//\]/)}"
            label="${label//\`/}"
            # Status class
            local sclass="todo"
            case "$status" in
                done) sclass="done" ;;
                active) sclass="active" ;;
                blocked|blocked-external) sclass="blocked" ;;
            esac
            echo "    ${mid}[\"${label}\"]:::${sclass}"
        done

        echo ""

        # Build list of rendered node IDs for edge filtering
        local rendered_ids
        rendered_ids=$(sqlite3 -batch -cmd ".timeout 5000" -separator $'\x1f' "$WV_DB" "$mermaid_query" | while IFS=$'\x1f' read -r id text status alias node_type depth root_id; do
            if [ -n "$filter_root" ] && [ "$root_id" != "$filter_root" ]; then
                continue
            fi
            echo "'$id'"
        done | paste -sd, -)

        if [ -z "$rendered_ids" ]; then
            rendered_ids="''"
        fi

        # Edges: implements (parent -> child) — filtered to rendered nodes
        local impl_edges
        impl_edges=$(db_query "SELECT source, target FROM edges WHERE type='implements' AND source IN ($rendered_ids) AND target IN ($rendered_ids);")
        if [ -n "$impl_edges" ]; then
            echo "$impl_edges" | while IFS='|' read -r src tgt; do
                echo "    ${tgt//-/_} --> ${src//-/_}"
            done
        fi

        # Edges: blocks (dashed) — filtered to rendered nodes
        local block_edges
        block_edges=$(db_query "SELECT source, target FROM edges WHERE type='blocks' AND source IN ($rendered_ids) AND target IN ($rendered_ids);")
        if [ -n "$block_edges" ]; then
            echo "$block_edges" | while IFS='|' read -r src tgt; do
                echo "    ${src//-/_} -.->|blocks| ${tgt//-/_}"
            done
        fi

        return
    fi

    # Text output: indented tree
    # Use ASCII unit separator (0x1F) instead of pipe — node text can contain '|'
    local prev_root=""
    db_ensure
    sqlite3 -batch -cmd ".timeout 5000" -separator $'\x1f' "$WV_DB" "$query" | while IFS=$'\x1f' read -r id text status node_type depth root_id; do
        # Look up target_version from metadata for epic nodes
        local target_version=""
        if [ "$node_type" = "epic" ] || [ "$depth" = "0" ]; then
            target_version=$(sqlite3 -batch "$WV_DB" "SELECT json_extract(metadata, '\$.target_version') FROM nodes WHERE id='$id';" 2>/dev/null || true)
            [ "$target_version" = "null" ] && target_version=""
        fi
        # Status indicator
        local indicator
        case "$status" in
            done)    indicator="${GREEN}✓${NC}" ;;
            active)  indicator="${YELLOW}●${NC}" ;;
            blocked|blocked-external) indicator="${RED}✗${NC}" ;;
            *)       indicator="${CYAN}○${NC}" ;;
        esac

        # Type label
        local type_label="${node_type:-task}"
        type_label=$(echo "$type_label" | tr '[:lower:]' '[:upper:]' | cut -c1)$(echo "$type_label" | cut -c2-)

        # Version suffix for epics
        local version_suffix=""
        if [ -n "$target_version" ]; then
            version_suffix=" ${CYAN}[${target_version}]${NC}"
        fi

        # Indentation
        local indent=""
        for ((i=0; i<depth; i++)); do
            indent="${indent}  "
        done

        # Blank line between root trees
        if [ "$depth" = "0" ] && [ -n "$prev_root" ]; then
            echo ""
        fi
        prev_root="$root_id"

        echo -e "${indent}${indicator} ${type_label}: ${text} ${CYAN}(${id})${NC} [${status}]${version_suffix}"
    done
}
