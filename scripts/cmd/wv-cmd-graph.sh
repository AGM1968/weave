#!/bin/bash
# wv-cmd-graph.sh — Graph traversal and edge commands
#
# Commands: block, link, unlink, resolve, related, edges, path, context
# Sourced by: wv entry point (after lib modules)
# Dependencies: wv-config.sh, wv-db.sh, wv-validate.sh, wv-cache.sh

# ═══════════════════════════════════════════════════════════════════════════
# cmd_block — Mark node as blocked by another
# ═══════════════════════════════════════════════════════════════════════════

cmd_block() {
    local id="${1:-}"
    local blocker=""
    local context="{}"
    local explicit_context=false

    shift || true
    while [ $# -gt 0 ]; do
        case "$1" in
            --by=*) blocker="${1#*=}" ;;
            --context=*) context="${1#*=}"; explicit_context=true ;;
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

    # Validate nodes exist
    local id_exists blocker_exists
    id_exists=$(db_query "SELECT COUNT(*) FROM nodes WHERE id='$id';")
    blocker_exists=$(db_query "SELECT COUNT(*) FROM nodes WHERE id='$blocker';")
    if [ "$id_exists" = "0" ]; then
        echo -e "${RED}Error: node $id not found${NC}" >&2
        return 1
    fi
    if [ "$blocker_exists" = "0" ]; then
        echo -e "${RED}Error: blocker node $blocker not found${NC}" >&2
        return 1
    fi

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

    # Validate JSON context if explicit
    if [ "$explicit_context" = "true" ]; then
        if ! echo "$context" | jq '.' >/dev/null 2>&1; then
            echo -e "${RED}Error: invalid JSON in --context${NC}" >&2
            return 1
        fi
    fi

    # Auto-context: generate alias-based summary when no explicit context
    if [ "$context" = "{}" ]; then
        local src_label tgt_label
        src_label=$(db_query "SELECT COALESCE(alias, substr(text,1,40)) FROM nodes WHERE id='$blocker';")
        tgt_label=$(db_query "SELECT COALESCE(alias, substr(text,1,40)) FROM nodes WHERE id='$id';")
        context=$(jq -nc --arg s "$src_label" --arg t "$tgt_label" \
            '{summary: ($s + " blocks " + $t), auto: true}')
    fi

    local ctx_escaped="${context//\'/\'\'}"

    if [ "$explicit_context" = "true" ]; then
        db_query "INSERT INTO edges (source, target, type, weight, context, created_at)
            VALUES ('$blocker', '$id', 'blocks', 1.0, '$ctx_escaped', CURRENT_TIMESTAMP)
            ON CONFLICT(source, target, type) DO UPDATE SET
                context = excluded.context, created_at = CURRENT_TIMESTAMP;"
    else
        db_query "INSERT OR IGNORE INTO edges (source, target, type, weight, context, created_at) VALUES ('$blocker', '$id', 'blocks', 1.0, '$ctx_escaped', CURRENT_TIMESTAMP);"
    fi
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

    # Auto-context: generate alias-based summary when no explicit context provided
    if [ "$context" = "{}" ]; then
        local src_label tgt_label
        src_label=$(db_query "SELECT COALESCE(alias, substr(text,1,40)) FROM nodes WHERE id='$from';")
        tgt_label=$(db_query "SELECT COALESCE(alias, substr(text,1,40)) FROM nodes WHERE id='$to';")
        context=$(jq -nc --arg s "$src_label" --arg t "$tgt_label" --arg e "$edge_type" \
            '{summary: ($s + " " + $e + " " + $t), auto: true}')
    fi

    # Escape single quotes in context JSON for SQL
    local ctx_escaped="${context//\'/\'\'}"

    # Insert or update edge (UPSERT guard: auto never clobbers explicit)
    db_query "INSERT INTO edges (source, target, type, weight, context, created_at)
        VALUES ('$from', '$to', '$edge_type', $weight, '$ctx_escaped', CURRENT_TIMESTAMP)
        ON CONFLICT(source, target, type) DO UPDATE SET
            weight = excluded.weight,
            context = CASE
                WHEN json_extract(excluded.context, '\$.auto') = 1
                  AND edges.context != '{}'
                  AND COALESCE(json_extract(edges.context, '\$.auto'), 0) != 1
                THEN edges.context
                ELSE excluded.context
            END,
            created_at = CURRENT_TIMESTAMP;"

    # Invalidate context cache for affected  nodes
    invalidate_context_cache "$from" "$to"

    echo -e "${GREEN}✓${NC} Linked: $from --[$edge_type]--> $to (weight: $weight)" >&2
}

# ═══════════════════════════════════════════════════════════════════════════
# cmd_unlink — Remove an edge between nodes and evict context cache
# ═══════════════════════════════════════════════════════════════════════════

cmd_unlink() {
    local from="${1:-}"
    local to="${2:-}"
    local edge_type=""

    shift 2 || {
        echo -e "${RED}Error: usage: wv unlink <from-id> <to-id> --type=<type>${NC}" >&2
        return 1
    }

    # Resolve aliases to IDs
    from=$(resolve_id "$from") || return 1
    to=$(resolve_id "$to") || return 1

    while [ $# -gt 0 ]; do
        case "$1" in
            --type=*) edge_type="${1#*=}" ;;
        esac
        shift
    done

    if [ -z "$from" ] || [ -z "$to" ] || [ -z "$edge_type" ]; then
        echo -e "${RED}Error: from, to, and --type are required${NC}" >&2
        echo -e "Usage: wv unlink <from-id> <to-id> --type=<type>" >&2
        return 1
    fi

    # Validate ID formats (SQL injection prevention)
    validate_id "$from" || return 1
    validate_id "$to" || return 1

    # Validate edge type
    validate_edge_type "$edge_type" || return 1

    # Check edge exists
    local count
    count=$(db_query "SELECT COUNT(*) FROM edges WHERE source='$from' AND target='$to' AND type='$edge_type';")
    if [ "$count" = "0" ]; then
        echo -e "${RED}Error: edge $from --[$edge_type]--> $to not found${NC}" >&2
        return 1
    fi

    db_query "DELETE FROM edges WHERE source='$from' AND target='$to' AND type='$edge_type';"

    # Evict context cache for both nodes
    invalidate_context_cache "$from" "$to"

    echo -e "${GREEN}✓${NC} Unlinked: $from --[$edge_type]--> $to" >&2
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

    # Build context from rationale if provided
    local resolve_ctx='{}'
    if [ -n "$rationale" ]; then
        resolve_ctx=$(jq -nc --arg r "$rationale" '{reason: $r}')
    fi
    local resolve_ctx_escaped="${resolve_ctx//\'/\'\'}"
    local has_rationale=false
    [ -n "$rationale" ] && has_rationale=true

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
            if [ "$has_rationale" = "true" ]; then
                db_query "INSERT INTO edges (source, target, type, weight, context, created_at)
                    VALUES ('$winner', '$loser', 'supersedes', 1.0, '$resolve_ctx_escaped', CURRENT_TIMESTAMP)
                    ON CONFLICT(source, target, type) DO UPDATE SET
                        context = excluded.context, created_at = CURRENT_TIMESTAMP;"
            else
                db_query "INSERT OR IGNORE INTO edges (source, target, type, weight, context, created_at) VALUES ('$winner', '$loser', 'supersedes', 1.0, '$resolve_ctx_escaped', CURRENT_TIMESTAMP);"
            fi

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
            if [ "$has_rationale" = "true" ]; then
                db_query "INSERT INTO edges (source, target, type, weight, context, created_at)
                    VALUES ('$new_id', '$node1', 'obsoletes', 1.0, '$resolve_ctx_escaped', CURRENT_TIMESTAMP)
                    ON CONFLICT(source, target, type) DO UPDATE SET
                        context = excluded.context, created_at = CURRENT_TIMESTAMP;"
                db_query "INSERT INTO edges (source, target, type, weight, context, created_at)
                    VALUES ('$new_id', '$node2', 'obsoletes', 1.0, '$resolve_ctx_escaped', CURRENT_TIMESTAMP)
                    ON CONFLICT(source, target, type) DO UPDATE SET
                        context = excluded.context, created_at = CURRENT_TIMESTAMP;"
            else
                db_query "INSERT OR IGNORE INTO edges (source, target, type, weight, context, created_at) VALUES ('$new_id', '$node1', 'obsoletes', 1.0, '$resolve_ctx_escaped', CURRENT_TIMESTAMP);"
                db_query "INSERT OR IGNORE INTO edges (source, target, type, weight, context, created_at) VALUES ('$new_id', '$node2', 'obsoletes', 1.0, '$resolve_ctx_escaped', CURRENT_TIMESTAMP);"
            fi

            # Mark both original nodes as done
            db_query "UPDATE nodes SET status='done', updated_at=CURRENT_TIMESTAMP WHERE id IN ('$node1', '$node2');"

            echo -e "${GREEN}✓${NC} Resolved: created merged node $new_id (obsoletes $node1 and $node2)"
            [ -n "$rationale" ] && echo "  Rationale: $rationale"
            ;;

        defer)
            # Remove contradiction edge
            db_query "DELETE FROM edges WHERE type='contradicts' AND ((source='$node1' AND target='$node2') OR (source='$node2' AND target='$node1'));"

            # Add relates_to edge instead (bidirectional)
            if [ "$has_rationale" = "true" ]; then
                db_query "INSERT INTO edges (source, target, type, weight, context, created_at)
                    VALUES ('$node1', '$node2', 'relates_to', 0.5, '$resolve_ctx_escaped', CURRENT_TIMESTAMP)
                    ON CONFLICT(source, target, type) DO UPDATE SET
                        context = excluded.context, created_at = CURRENT_TIMESTAMP;"
                db_query "INSERT INTO edges (source, target, type, weight, context, created_at)
                    VALUES ('$node2', '$node1', 'relates_to', 0.5, '$resolve_ctx_escaped', CURRENT_TIMESTAMP)
                    ON CONFLICT(source, target, type) DO UPDATE SET
                        context = excluded.context, created_at = CURRENT_TIMESTAMP;"
            else
                db_query "INSERT OR IGNORE INTO edges (source, target, type, weight, context, created_at) VALUES ('$node1', '$node2', 'relates_to', 0.5, '$resolve_ctx_escaped', CURRENT_TIMESTAMP);"
                db_query "INSERT OR IGNORE INTO edges (source, target, type, weight, context, created_at) VALUES ('$node2', '$node1', 'relates_to', 0.5, '$resolve_ctx_escaped', CURRENT_TIMESTAMP);"
            fi

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
    local depth=1

    shift || true
    while [ $# -gt 0 ]; do
        case "$1" in
            --type=*)      edge_type="${1#*=}" ;;
            --direction=*) direction="${1#*=}" ;;
            --depth=*)     depth="${1#*=}" ;;
            --json)        output_format="json" ;;
        esac
        shift
    done

    if [ -z "$id" ]; then
        echo -e "${RED}Error: node ID required${NC}" >&2
        echo "Usage: wv related <id> [--type=<type>] [--direction=outbound|inbound|both] [--depth=N] [--json]" >&2
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

    # N-hop traversal for depth > 1 (undirected BFS via recursive CTE)
    if [ "$depth" -gt 1 ] 2>/dev/null; then
        local type_cte_filter=""
        [ -n "$edge_type" ] && type_cte_filter="AND e.type = '$edge_type'"
        local cte_query="WITH RECURSIVE neighborhood(node_id, depth) AS (
            SELECT '$id', 0
            UNION
            SELECT
                CASE WHEN e.source = n.node_id THEN e.target ELSE e.source END,
                n.depth + 1
            FROM neighborhood n
            JOIN edges e ON (e.source = n.node_id OR e.target = n.node_id) $type_cte_filter
            WHERE n.depth < $depth
        )
        SELECT nd.node_id, MIN(nd.depth) as hop, nodes.text, nodes.status
        FROM neighborhood nd
        JOIN nodes ON nodes.id = nd.node_id
        WHERE nd.node_id != '$id'
        GROUP BY nd.node_id
        ORDER BY hop, nd.node_id;"

        if [ "$output_format" = "json" ]; then
            db_query_json "$cte_query"
            return $?
        fi

        local count=0
        local cur_hop=-1
        while IFS=$'\x1f' read -r node_id hop text status; do
            count=$((count + 1))
            if [ "$hop" != "$cur_hop" ]; then
                echo -e "${CYAN}── hop $hop ──${NC}"
                cur_hop="$hop"
            fi
            echo -e "  ${GREEN}$node_id${NC} [$status]: $text"
        done < <(db_ensure; sqlite3 -batch -cmd ".timeout 5000" -separator $'\x1f' "$WV_DB" "$cte_query")

        if [ "$count" = "0" ]; then
            echo "No related nodes found within $depth hops."
        fi
        return 0
    fi

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
# cmd_context helpers
# ═══════════════════════════════════════════════════════════════════════════

# _context_resolve_id — Resolve node ID from WV_ACTIVE or primary node
_context_resolve_id() {
    if [ -n "${WV_ACTIVE:-}" ]; then
        echo "$WV_ACTIVE"
        return 0
    fi
    local primary
    primary=$(get_primary_node 2>/dev/null || echo "")
    if [ -n "$primary" ]; then
        echo "$primary"
        return 0
    fi
    echo -e "${RED}Error: node ID required${NC}" >&2
    echo "Usage: wv context <id> --json" >&2
    echo "" >&2
    echo "Tip: Run 'wv work <id>' to set the primary node, or:" >&2
    echo "  export WV_ACTIVE=wv-xxxxxx" >&2
    return 1
}

# _context_gather_quality — Get code quality data for files touched by a node
_context_gather_quality() {
    local id="$1"
    local quality_json='{"code_quality":[],"quality_as_of":null}'

    # Source 1: commits whose message references this node ID
    local touched_files
    touched_files=$(git log --all --grep="$id" --name-only --format="" 2>/dev/null | sort -u)

    # Source 2: commits stored in node metadata (from onboarding / plan-agent enrichment)
    local meta_commits
    meta_commits=$(db_query "SELECT json_extract(metadata, '$.commits') FROM nodes WHERE id='$id';" 2>/dev/null)
    # Fall back to singular "commit" key (older onboarding format)
    if [ -z "$meta_commits" ] || [ "$meta_commits" = "null" ]; then
        local single_commit
        single_commit=$(db_query "SELECT json_extract(metadata, '$.commit') FROM nodes WHERE id='$id';" 2>/dev/null)
        if [ -n "$single_commit" ] && [ "$single_commit" != "null" ]; then
            meta_commits="[\"$single_commit\"]"
        fi
    fi
    if [ -n "$meta_commits" ] && [ "$meta_commits" != "null" ]; then
        local commit_files
        commit_files=$(echo "$meta_commits" | jq -r '.[]' 2>/dev/null | while IFS= read -r sha; do
            git show --name-only --format="" "$sha" 2>/dev/null
        done | sort -u)
        if [ -n "$commit_files" ]; then
            touched_files=$(printf '%s\n%s' "$touched_files" "$commit_files" | sort -u | grep -v '^$')
        fi
    fi

    # Source 3: touched_files metadata (common in tests and plan-enriched nodes)
    local meta_touched
    meta_touched=$(db_query "SELECT json_extract(metadata, '$.touched_files') FROM nodes WHERE id='$id';" 2>/dev/null)
    if [ -n "$meta_touched" ] && [ "$meta_touched" != "null" ]; then
        local touched_from_meta
        touched_from_meta=$(printf '%s' "$meta_touched" | jq -r '.[]?' 2>/dev/null)
        if [ -n "$touched_from_meta" ]; then
            touched_files=$(printf '%s\n%s' "$touched_files" "$touched_from_meta" | sort -u | grep -v '^$')
        fi
    fi

    if [ -n "$touched_files" ]; then
        local _hz_args=()
        [ -n "$WV_HOT_ZONE" ] && _hz_args=("--hot-zone" "$WV_HOT_ZONE")
        quality_json=$(echo "$touched_files" | _wv_quality_python "${_hz_args[@]}" context-files 2>/dev/null || echo '{"code_quality":[],"quality_as_of":null}')
    fi
    echo "$quality_json"
}

# ═══════════════════════════════════════════════════════════════════════════
# cmd_context — Build Context Pack for a node
# ═══════════════════════════════════════════════════════════════════════════

cmd_context() {
    local id=""
    local format="text"
    local mode_arg=""

    while [ $# -gt 0 ]; do
        case "$1" in
            --json)   format="json" ;;
            --mode=*) mode_arg="${1#--mode=}" ;;
            --*) ;; # skip other flags
            *) [ -z "$id" ] && id="$1" ;; # first non-flag arg is ID
        esac
        shift
    done
    local mode
    mode=$(wv_resolve_mode "$mode_arg")

    # Use WV_ACTIVE or primary node if no ID provided
    if [ -z "$id" ]; then
        id=$(_context_resolve_id)
        if [ -z "$id" ]; then
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
        cmd_context "$id" --json ${mode_arg:+"--mode=$mode_arg"} | jq .
        return $?
    fi

    # Cache setup (per session in tmpfs) — keyed by id+mode so different modes don't collide
    local cache_dir="$WV_HOT_ZONE/context_cache"
    mkdir -p "$cache_dir"
    local cache_file="$cache_dir/${id}-${mode}.json"

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

    # Unified self-blocking signal: is THIS node not-ready by status, deferral, or a
    # blocks edge? wv_blocking_reason is the single source shared with cmd_ready, so the
    # runtime's require_clear_context sees the same determination the ready queue uses —
    # closing the metadata-vs-edge dual representation (wv-f752a5).
    local self_block_json
    self_block_json=$(db_query_json "SELECT ($(wv_blocking_reason n)) AS blocked_reason FROM nodes n WHERE n.id='$id';")
    self_block_json="${self_block_json:-[]}"

    # Get blockers (nodes that block this one, excluding completed ones)
    local blockers_json
    blockers_json=$(db_query_json "
        SELECT n.id, n.text, n.status, json(n.metadata), e.context
        FROM edges e
        JOIN nodes n ON n.id = e.source
        WHERE e.target = '$id' AND e.type = 'blocks' AND n.status != 'done';
    ")
    blockers_json="${blockers_json:-[]}"

    # bootstrap mode: blockers only — skip all expensive traversals
    if [ "$mode" = "bootstrap" ]; then
        jq -n \
            --argjson node "$node_json" \
            --argjson blockers "$blockers_json" \
            --argjson self_block "$self_block_json" \
            '($self_block[0].blocked_reason // null) as $br
             | {node: ($node[0] | {id, text, status}),
                blocked: ($br != null),
                blocked_reason: $br,
                blockers: ($blockers | map({id, text, status}))}'
        return 0
    fi

    # Get ancestors (walk blocks + implements chains with cycle detection and depth limit)
    # blocks: source=blocker → target=blocked (walk from blocked to blocker)
    # implements: source=child → target=parent (walk from child to parent)
    # Uses ',id,' delimited path to prevent substring false-matches (wv-77cd fix)
    local ancestors_json
    ancestors_json=$(db_query_json "
        WITH RECURSIVE ancestry AS (
            SELECT id, text, status, metadata, 0 as depth, ',' || id || ',' as path
            FROM nodes WHERE id = '$id'
            UNION
            -- Walk blocks edges: blocker (source) → blocked (target)
            SELECT n.id, n.text, n.status, n.metadata, a.depth + 1, a.path || n.id || ','
            FROM nodes n
            JOIN edges e ON e.source = n.id
            JOIN ancestry a ON e.target = a.id
            WHERE e.type = 'blocks'
              AND a.depth < 100
              AND instr(a.path, ',' || n.id || ',') = 0
            UNION
            -- Walk implements edges: child (source) → parent (target)
            SELECT n.id, n.text, n.status, n.metadata, a.depth + 1, a.path || n.id || ','
            FROM nodes n
            JOIN edges e ON e.target = n.id
            JOIN ancestry a ON e.source = a.id
            WHERE e.type = 'implements'
              AND a.depth < 100
              AND instr(a.path, ',' || n.id || ',') = 0
        )
        SELECT DISTINCT id, text, status, json(metadata) as metadata FROM ancestry WHERE depth > 0 ORDER BY depth DESC;
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

    local finding_json
    finding_json=$(db_query_json "
        SELECT n.id, n.text, n.status, json(n.metadata) as metadata, e.type as edge
        FROM edges e
        JOIN nodes n
          ON (
              (e.source = '$id' AND n.id = e.target)
              OR (e.target = '$id' AND n.id = e.source)
          )
        WHERE e.type = 'resolves'
          AND n.id != '$id'
          AND json_extract(n.metadata, '$.type') = 'finding'
        ORDER BY n.updated_at DESC
        LIMIT 1;
    ")
    finding_json="${finding_json:-[]}"

    # Get pitfalls scoped to node's neighborhood (wv-517f fix)
    # Walk all edge types (blocks, implements, addresses, references) in both
    # directions to build the reachable set, then filter for pitfall nodes.
    # Depth-limited to 4 hops to prevent runaway traversal on large graphs.
    local pitfalls_json
    pitfalls_json=$(db_query_json "
        WITH RECURSIVE node_neighborhood AS (
            SELECT id, ',' || id || ',' as path, 0 as depth
            FROM nodes WHERE id = '$id'
            UNION
            SELECT n.id, a.path || n.id || ',', a.depth + 1
            FROM nodes n
            JOIN node_neighborhood a ON a.depth < 4
              AND instr(a.path, ',' || n.id || ',') = 0
            WHERE n.id IN (
                SELECT e.target FROM edges e WHERE e.source = a.id
                UNION ALL
                SELECT e.source FROM edges e WHERE e.target = a.id
            )
        )
        SELECT DISTINCT n.id, n.text, n.status, json(n.metadata)
        FROM nodes n
        WHERE json_extract(n.metadata, '$.pitfall') IS NOT NULL
          AND n.id IN (SELECT id FROM node_neighborhood)
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

    # discover mode: skip quality (expensive; rarely needed for planning)
    local quality_json='{"code_quality":[],"quality_as_of":null}'
    local skip_quality=false
    [ "$mode" = "discover" ] && skip_quality=true

    # Get code quality data for files touched by this node (execute/full only)
    if [ "$skip_quality" = false ]; then
        quality_json=$(_context_gather_quality "$id")
    fi

    # Compose Context Pack with field cleanup and limits (per proposal lines 222-237)
    # discover: cap ancestors at 5
    local _discover_mode="false"
    [ "$mode" = "discover" ] && _discover_mode="true"

    jq -n \
        --argjson node "$node_json" \
        --argjson blockers "$blockers_json" \
        --argjson ancestors "$ancestors_json" \
        --argjson related "$related_json" \
        --argjson finding "$finding_json" \
        --argjson pitfalls "$pitfalls_json" \
        --argjson contradictions "$contradictions_json" \
        --argjson quality "$quality_json" \
        --argjson discover_mode "$_discover_mode" \
        --argjson self_block "$self_block_json" \
        '($self_block[0].blocked_reason // null) as $br |
        {
            node: ($node[0] | {id, text, status}),
            blocked: ($br != null),
            blocked_reason: $br,
            blockers: ($blockers | map({id, text, status, context: (.context | fromjson? // .context)})),
            ancestors: (($ancestors | if $discover_mode then .[0:5] else . end) | map({
                id,
                text,
                status,
                learnings: (
                    (.metadata | if type == "string" then fromjson else . end) as $meta |
                    # Parse structured "decision: ... | pattern: ... | pitfall: ..." from learning string
                    (if $meta.learning then
                        ($meta.learning | split(" | ") | reduce .[] as $part (
                            {};
                            if ($part | startswith("decision: ")) then .decision = ($part | ltrimstr("decision: "))
                            elif ($part | startswith("pattern: ")) then .pattern = ($part | ltrimstr("pattern: "))
                            elif ($part | startswith("pitfall: ")) then .pitfall = ($part | ltrimstr("pitfall: "))
                            else .raw = ((.raw // "") + $part)
                            end
                        ) |
                        # If no structured fields were parsed, put the whole string in raw
                        if (.decision or .pattern or .pitfall) then . else {raw: $meta.learning} end)
                    else {} end) as $parsed |
                    {
                        decision: ($meta.decision // $parsed.decision // null),
                        pattern: ($meta.pattern // $parsed.pattern // null),
                        pitfall: ($meta.pitfall // $parsed.pitfall // null),
                        raw: ($parsed.raw // null)
                    } |
                    # Strip null fields, only include if at least one field is present
                    with_entries(select(.value != null)) |
                    if length > 0 then . else null end
                )
            })),
            finding: (
                ($finding[0]? | (.metadata | if type == "string" then fromjson else . end) as $meta |
                    ($meta.finding // {}) as $f |
                    {
                        id,
                        text,
                        status,
                        edge,
                        violation_type: ($f.violation_type // null),
                        root_cause: ($f.root_cause // null),
                        proposed_fix: ($f.proposed_fix // null),
                        confidence: ($f.confidence // null),
                        fixable: ($f.fixable // null),
                        evidence_sessions: ($f.evidence_sessions // null)
                    } | with_entries(select(.value != null))
                ) // null
            ),
            related: ($related[0:5] | map({id, text, edge, weight, context: (.context | fromjson? // .context)})),
            pitfalls: ($pitfalls[0:3] | map({
                id,
                text,
                pitfall: ((.metadata | if type == "string" then fromjson else . end).pitfall)
            })),
            contradictions: ($contradictions | map({id, text, status})),
            code_quality: $quality.code_quality,
            quality_as_of: $quality.quality_as_of
        }' | tee "$cache_file.tmp" && mv "$cache_file.tmp" "$cache_file" || rm -f "$cache_file.tmp"
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
    local node_cap="${WV_TREE_CAP:-50}"

    while [ $# -gt 0 ]; do
        case "$1" in
            --active)    show_active_only=true ;;
            --depth=*)   max_depth="${1#*=}" ;;
            --json)      json_output=true ;;
            --mermaid)   mermaid_output=true ;;
            --root=*)    root_filter="${1#*=}" ;;
            --all)       node_cap=0 ;;
            --*)         ;;
            *)           root_filter="$1" ;;
        esac
        shift
    done

    # Output budget (docs/PROPOSAL-wv-output-budget.md D1): cap nodes shown,
    # shallowest-first, so default output stays ~2k tokens. 0 = unbounded.
    case "$node_cap" in
        ''|*[!0-9]*) node_cap=50 ;;
    esac

    db_ensure

    # Resolve root filter before building any queries — same pattern as the mermaid path.
    # When --root is specified, CTE anchors at that node instead of the top-level heuristic.
    # This fixes the post-filter-on-root_id bug for text and JSON modes (mirrors 043ebf7 fix).
    local filter_root=""
    if [ -n "$root_filter" ]; then
        filter_root=$(db_query "SELECT id FROM nodes WHERE id='$(sql_escape "$root_filter")' OR alias='$(sql_escape "$root_filter")' LIMIT 1;" 2>/dev/null)
    fi
    local status_filter=""
    if [ "$show_active_only" = "true" ]; then
        status_filter="AND n.status = 'active'"
    fi
    local cte_anchor
    if [ -n "$filter_root" ]; then
        cte_anchor="WHERE n.id = '$(sql_escape "$filter_root")'"
    else
        cte_anchor="WHERE NOT EXISTS (
                SELECT 1 FROM edges e
                WHERE e.source = n.id AND e.type = 'implements'
            )
            $status_filter"
    fi

    # Build tree query using the resolved CTE anchor.
    # cte_anchor handles --root (explicit node), --active (heuristic + done filter), and default.
    local tree_cte="
        WITH RECURSIVE tree AS (
            SELECT n.id, n.text, n.status,
                   json_extract(n.metadata, '\$.type') as node_type,
                   0 as depth,
                   n.id as root_id
            FROM nodes n
            $cte_anchor

            UNION ALL

            -- Children: nodes that implement a parent already in the tree
            SELECT n.id, n.text, n.status,
                   json_extract(n.metadata, '\$.type') as node_type,
                   t.depth + 1,
                   t.root_id
            FROM nodes n
            JOIN edges e ON e.source = n.id AND e.type = 'implements'
            JOIN tree t ON e.target = t.id
            WHERE t.depth < $max_depth
        )"
    local tree_cte_alias="
        WITH RECURSIVE tree AS (
            SELECT n.id, n.text, n.status, n.alias,
                   json_extract(n.metadata, '\$.type') as node_type,
                   0 as depth,
                   n.id as root_id
            FROM nodes n
            $cte_anchor

            UNION ALL

            SELECT n.id, n.text, n.status, n.alias,
                   json_extract(n.metadata, '\$.type') as node_type,
                   t.depth + 1,
                   t.root_id
            FROM nodes n
            JOIN edges e ON e.source = n.id AND e.type = 'implements'
            JOIN tree t ON e.target = t.id
            WHERE t.depth < $max_depth
        )"

    # Capped subset keeps the shallowest nodes; hidden_children marks where
    # subtrees were cut so the reader knows which roots to expand.
    local cap_with=""
    local cap_src="tree"
    local hidden_expr="0"
    local total_nodes=0
    if [ "$node_cap" -gt 0 ]; then
        cap_with=", capped AS (SELECT * FROM tree ORDER BY depth, root_id, id LIMIT $node_cap)"
        cap_src="capped"
        hidden_expr="(SELECT COUNT(*) FROM tree t2
                JOIN edges e2 ON e2.source = t2.id AND e2.type = 'implements'
                WHERE e2.target = c.id AND t2.id NOT IN (SELECT id FROM capped))"
        total_nodes=$(db_query "$tree_cte SELECT COUNT(*) FROM tree;" 2>/dev/null)
        if [ -z "$total_nodes" ]; then
            total_nodes=0
        fi
    fi

    local query="
        ${tree_cte}${cap_with}
        SELECT c.id, c.text, c.status, c.node_type, c.depth, c.root_id,
               $hidden_expr as hidden_children
        FROM $cap_src c
        ORDER BY c.root_id, c.depth, c.id;
    "

    if [ "$json_output" = "true" ]; then
        local results
        results=$(db_query_json "
            ${tree_cte_alias}${cap_with}
            SELECT id, text, status, alias, node_type, depth, root_id
            FROM $cap_src
            ORDER BY root_id, depth, id;
        ")
        [ -z "$results" ] && echo "[]" || echo "$results"
        if [ "$node_cap" -gt 0 ] && [ "$total_nodes" -gt "$node_cap" ]; then
            echo "wv tree: showing $node_cap of $total_nodes nodes (use --all to lift the cap)" >&2
        fi
        return
    fi

    # Mermaid output: dependency graph with status colors
    # filter_root and cte_anchor already resolved above — shared with text/JSON paths.
    if [ "$mermaid_output" = "true" ]; then

        local mermaid_query="
            ${tree_cte_alias}${cap_with}
            SELECT id, text, status, alias, node_type, depth, root_id
            FROM $cap_src
            ORDER BY root_id, depth, id;
        "

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

        if [ "$node_cap" -gt 0 ] && [ "$total_nodes" -gt "$node_cap" ]; then
            echo ""
            echo "    %% showing $node_cap of $total_nodes nodes (use --all to lift the cap)"
        fi

        return
    fi

    # Text output: indented tree
    # Use ASCII unit separator (0x1F) instead of pipe — node text can contain '|'
    local prev_root=""
    db_ensure
    sqlite3 -batch -cmd ".timeout 5000" -separator $'\x1f' "$WV_DB" "$query" | while IFS=$'\x1f' read -r id text status node_type depth root_id hidden_children; do
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
        if [ "${hidden_children:-0}" -gt 0 ]; then
            echo -e "${indent}  ${YELLOW}+${hidden_children} more not shown (wv tree ${id})${NC}"
        fi
    done

    if [ "$node_cap" -gt 0 ] && [ "$total_nodes" -gt "$node_cap" ]; then
        echo ""
        echo -e "${YELLOW}Showing $node_cap of $total_nodes nodes — use --all for the full tree, or wv tree <id> for a subtree${NC}"
    fi
}

# ═══════════════════════════════════════════════════════════════════════════
# _impact_suites_for_files — map changed file paths to affected test suites
#
# Loads .weave/test-map.conf (ini-style: source_file = suite [suite ...]).
# Keys may be exact paths, glob patterns (src/**/*.py = suite), or directory
# prefixes ending in / (src/ = suite). A `* = suite` entry, or bare suite
# tokens under a `[default]` section, set a fail-safe default. Per-file
# precedence: exact > glob/prefix > naming heuristic > [default].
# Falls back to naming-convention heuristic when conf is absent or a file
# has no explicit/glob mapping:
#   scripts/cmd/wv-cmd-<X>.sh  →  tests/test-<X>.sh
#   scripts/lib/*.sh or scripts/wv  →  tests/run-all.sh
# Reads .weave/test-times.json for estimated suite cost.
# Outputs JSON: [{"name":"test-X.sh","last_cost_s":N}, ...]
# ═══════════════════════════════════════════════════════════════════════════

_impact_suites_for_files() {
    if [ $# -eq 0 ]; then echo '[]'; return 0; fi

    local map_conf="${WEAVE_DIR}/test-map.conf"
    local times_json="${WEAVE_DIR}/test-times.json"

    local times_data='{}'
    [ -f "$times_json" ] && times_data=$(cat "$times_json" 2>/dev/null || echo '{}')

    # Parse conf. Exact keys go in _fmap; pattern keys (containing glob
    # metacharacters * ? [ , or ending in / for a directory prefix) are kept
    # in insertion order in _pat_keys/_pat_vals so a consumer can map a whole
    # subtree with one line (src/**/*.py = suite, or src/ = suite). A `* = suite`
    # entry, or any suite tokens under a `[default]` section, become the
    # fail-safe default applied when nothing else matches a file.
    declare -A _fmap=()
    local _pat_keys=() _pat_vals=()
    local _default_suites=""
    if [ -f "$map_conf" ]; then
        local _in_default=false
        while IFS= read -r line; do
            # Strip leading whitespace; comments and blanks are noise
            line="${line#"${line%%[![:space:]]*}"}"
            [[ "$line" =~ ^# || -z "$line" ]] && continue
            # Section headers toggle the [default] accumulator
            if [[ "$line" =~ ^\[ ]]; then
                if [[ "$line" =~ ^\[default\] ]]; then _in_default=true; else _in_default=false; fi
                continue
            fi
            if [[ "$line" != *=* ]]; then
                # Bare suite tokens under [default]: treat as default suites
                [ "$_in_default" = true ] && _default_suites="${_default_suites:+$_default_suites }$line"
                continue
            fi
            local key="${line%%=*}"
            local val="${line#*=}"
            key="${key%"${key##*[![:space:]]}"}"  # rtrim key
            key="${key#"${key%%[![:space:]]*}"}"  # ltrim key
            val="${val#"${val%%[![:space:]]*}"}"  # ltrim val
            if [ "$key" = "*" ]; then
                _default_suites="${_default_suites:+$_default_suites }$val"
            elif [[ "$key" == *[\*\?\[]* || "$key" == */ ]]; then
                _pat_keys+=("$key"); _pat_vals+=("$val")
            else
                _fmap["$key"]="$val"
            fi
        done < "$map_conf"
    fi

    # Collect matched suites (deduped). Precedence per file:
    #   exact > glob/prefix > naming heuristic > [default] (fail safe).
    declare -A _seen=()
    for f in "$@"; do
        local suites=""
        if [ -n "${_fmap[$f]+x}" ]; then
            suites="${_fmap[$f]}"
        else
            # Glob/prefix keys — union all matching patterns
            local _i
            for _i in "${!_pat_keys[@]}"; do
                local _pk="${_pat_keys[$_i]}"
                if [[ "$_pk" == */ ]]; then
                    [[ "$f" == "$_pk"* ]] && suites="${suites:+$suites }${_pat_vals[$_i]}"
                else
                    # unquoted RHS is intentional: glob-match the conf key
                    # shellcheck disable=SC2053
                    if [[ "$f" == $_pk ]]; then
                        suites="${suites:+$suites }${_pat_vals[$_i]}"
                    fi
                fi
            done
            if [ -z "$suites" ]; then
                # Naming-convention heuristic (Weave's own layout)
                case "$f" in
                    scripts/cmd/wv-cmd-*.sh)
                        local base; base=$(basename "$f" .sh)
                        suites="tests/test-${base#wv-cmd-}.sh" ;;
                    scripts/lib/*.sh | scripts/wv)
                        suites="tests/test-hooks.sh tests/test-graph.sh" ;;
                    scripts/hooks/*)
                        suites="tests/test-hooks.sh" ;;
                    tests/test-*.sh)
                        suites="$f" ;;
                esac
            fi
            # Fail safe: a configured [default] suite beats running nothing
            [ -z "$suites" ] && suites="$_default_suites"
        fi
        local s
        for s in $suites; do
            _seen["$s"]=1
        done
    done

    # Emit JSON with cost. name = full suite path; cost lookup uses basename
    # (test-times.json is keyed by basename from serial-mode timing writes).
    local out='['
    local first=true
    local suite
    for suite in "${!_seen[@]}"; do
        local bname; bname=$(basename "$suite")
        local cost; cost=$(printf '%s' "$times_data" | jq -r --arg n "$bname" '.[$n] // 0' 2>/dev/null || echo 0)
        [ "$first" = "true" ] || out+=','
        out+=$(printf '{"name":"%s","last_cost_s":%s}' "$suite" "$cost")
        first=false
    done
    out+=']'
    echo "$out"
}

# ═══════════════════════════════════════════════════════════════════════════
# _impact_nodes_for_files — map file paths to seed node IDs via attribution
#
# For each path arg, queries canonical node_files rows first and legacy
# touched_files metadata as fallback. Returns newline-separated node IDs
# (deduped, active+todo+blocked by default; done too when include_done=true).
# Unknown paths produce no output — empty result is not an error.
# ═══════════════════════════════════════════════════════════════════════════

_impact_nodes_for_files() {
    if [ $# -eq 0 ]; then return 0; fi

    local include_done="${1:-false}"
    shift || true
    if [ $# -eq 0 ]; then return 0; fi

    local status_filter="'todo','active','blocked'"
    if [ "$include_done" = "true" ]; then
        status_filter="'todo','active','blocked','done'"
    fi

    local path_conditions=""
    local node_file_paths=""
    for fp in "$@"; do
        local esc_fp
        esc_fp=$(printf '%s' "$fp" | sed "s/'/''/g")
        if [ -n "$path_conditions" ]; then
            path_conditions+=" OR "
        fi
        if [ -n "$node_file_paths" ]; then
            node_file_paths+=","
        fi
        node_file_paths+="'${esc_fp}'"
        path_conditions+="EXISTS (
            SELECT 1 FROM json_each(json_extract(n.metadata, '$.touched_files'))
            WHERE value = '${esc_fp}'
        )"
    done

    db_query "
        SELECT DISTINCT node_id FROM (
            SELECT n.id AS node_id
            FROM nodes n
            JOIN node_files nf ON nf.node_id = n.id
            WHERE n.status IN (${status_filter})
              AND nf.path IN (${node_file_paths})

            UNION

            SELECT n.id AS node_id
            FROM nodes n
            WHERE n.status IN (${status_filter})
              AND json_extract(n.metadata, '$.touched_files') IS NOT NULL
              AND (${path_conditions})
        )
        ORDER BY node_id;
    " 2>/dev/null || true
}

# ═══════════════════════════════════════════════════════════════════════════
# cmd_impact — blast-radius analysis: which nodes does changing a seed affect?
# ═══════════════════════════════════════════════════════════════════════════

cmd_impact() {
    local depth=3
    local direction="both"
    local output_format="text"
    local full=false
    local include_done=false
    local include_quality=false
    local node_cap=50
    local file_seeds=()

    local seeds=()

    while [ $# -gt 0 ]; do
        case "$1" in
            --depth=*)      depth="${1#*=}" ;;
            --direction=*)  direction="${1#*=}" ;;
            --json)         output_format="json" ;;
            --suites)       output_format="suites" ;;
            --full)         full=true ;;
            --include-done) include_done=true ;;
            --all)          node_cap=10000 ;;
            --quality)      include_quality=true ;;
            --files=*)
                IFS=',' read -ra file_seeds <<< "${1#*=}" ;;
            -*)
                echo -e "${RED}Error: unknown flag '$1'${NC}" >&2; return 1 ;;
            *)
                seeds+=("$1") ;;
        esac
        shift
    done

    # --suites mode: lightweight file→suite mapping, no graph traversal
    if [ "$output_format" = "suites" ]; then
        if [ "${#file_seeds[@]}" -eq 0 ]; then
            echo -e "${RED}Error: --suites requires --files=<paths>${NC}" >&2
            return 1
        fi
        _impact_suites_for_files "${file_seeds[@]}"
        return $?
    fi

    # Resolve file seeds → node IDs (merged with any explicit ID seeds)
    if [ "${#file_seeds[@]}" -gt 0 ]; then
        db_ensure
        local file_nodes
        file_nodes=$(_impact_nodes_for_files "$include_done" "${file_seeds[@]}")
        while IFS= read -r nid; do
            [ -n "$nid" ] && seeds+=("$nid")
        done <<< "$file_nodes"
        if [ "${#seeds[@]}" -eq 0 ]; then
            # No graph node records these files in touched_files. Do NOT report a
            # bland "0 impacted" — that reads as "safe" and hides real coupling
            # (finding wv-70ea8e: a false 0-impacted gave bad pre-edit confidence
            # while the pre-commit test-map.conf router correctly found affected
            # suites). Fall back to test-map.conf so suites still surface, and warn
            # that the graph blast radius is unknown — not zero.
            local _suites_json
            _suites_json=$(_impact_suites_for_files "${file_seeds[@]}")
            if [ "$output_format" = "json" ]; then
                printf '{"seeds":[],"impacted":[],"unblocked":[],"affected_suites":%s,"summary":{"total_impacted":0,"total_unblocked":0},"source":"files","graph_seed_matched":false,"files":[%s]}\n' \
                    "$_suites_json" \
                    "$(printf '"%s",' "${file_seeds[@]}" | sed 's/,$//')"
            else
                echo -e "${YELLOW}⚠ No graph node records these files in touched_files — graph blast radius unknown, NOT 'safe'.${NC}" >&2
                echo "  files: ${file_seeds[*]}" >&2
                local _suite_names
                _suite_names=$(printf '%s' "$_suites_json" | jq -r '.[].name' 2>/dev/null | paste -sd' ' - 2>/dev/null || echo "")
                if [ -n "$_suite_names" ]; then
                    echo "  affected test suites (via test-map.conf): $_suite_names"
                else
                    echo "  no suites mapped either — consider 'wv touch <path>' on the owning node for graph attribution."
                fi
            fi
            return 0
        fi
    fi

    if [ "${#seeds[@]}" -eq 0 ]; then
        echo -e "${RED}Error: at least one seed node ID required (or --files=<path>)${NC}" >&2
        return 1
    fi

    case "$direction" in
        fwd|forward|rev|reverse|both) ;;
        *)
            echo -e "${RED}Error: invalid --direction '$direction' (fwd|rev|both)${NC}" >&2
            return 1 ;;
    esac

    # Normalize synonyms so cache keys don't fragment.
    case "$direction" in
        forward) direction="fwd" ;;
        reverse) direction="rev" ;;
    esac

    if ! [[ "$depth" =~ ^[1-9][0-9]*$ ]]; then
        echo -e "${RED}Error: --depth must be a positive integer, got '$depth'${NC}" >&2
        return 1
    fi

    db_ensure

    # Resolve aliases and validate each seed
    local resolved_seeds=()
    for raw in "${seeds[@]}"; do
        local sid
        sid=$(resolve_id "$raw") || return 1

        # Archived nodes are pruned from the live DB — absence = archived
        local node_status
        node_status=$(db_query "SELECT status FROM nodes WHERE id='$(sql_escape "$sid")';")
        if [ -z "$node_status" ]; then
            echo -e "${RED}Error: seed $sid not found (node may be archived)${NC}" >&2
            return 1
        fi

        # D10: done + fwd or both → error, unless caller explicitly includes done.
        if [ "$node_status" = "done" ] && \
           [ "$include_done" != "true" ] && \
           [ "$direction" != "rev" ] && [ "$direction" != "reverse" ]; then
            echo -e "${RED}Error: seed $sid is done; forward impact already discharged.${NC}" >&2
            echo "Use --direction=rev (retrospective) or --include-done to force traversal." >&2
            return 1
        fi

        resolved_seeds+=("$sid")
    done

    local walk_flags=("--depth=${depth}" "--direction=${direction}" "--node-cap=${node_cap}")
    [ "$full" = "true" ]         && walk_flags+=("--full")
    [ "$include_done" = "true" ] && walk_flags+=("--include-done")

    # Impact cache key includes all traversal/shape flags, including --quality.
    local edge_set="blocks,implements,addresses"
    [ "$full" = "true" ] && edge_set="${edge_set},obsoletes,references,resolves,supersedes"
    local sorted_seeds
    sorted_seeds=$(printf '%s\n' "${resolved_seeds[@]}" | sort -u | tr '\n' ',' | sed 's/,$//')
    local quality_key="0"
    [ "$include_quality" = "true" ] && quality_key="1"

    local cache_dir="$WV_HOT_ZONE/context_cache"
    mkdir -p "$cache_dir"
    local cache_key
    cache_key=$(printf '%s' "${sorted_seeds}|${depth}|${direction}|${edge_set}|${include_done}|${node_cap}|${quality_key}" | sha256sum | cut -c1-16)
    local cache_file="$cache_dir/impact-${cache_key}.json"

    local walk_json=""
    if [ -f "$cache_file" ]; then
        local cache_time db_time
        cache_time=$(stat -c %Y "$cache_file" 2>/dev/null || stat -f %m "$cache_file" 2>/dev/null || echo 0)
        db_time=$(stat -c %Y "$WV_DB" 2>/dev/null || stat -f %m "$WV_DB" 2>/dev/null || echo 0)
        if [ "$cache_time" -ge "$db_time" ]; then
            walk_json=$(cat "$cache_file")
        fi
    fi

    # Run CTE walk on cache miss.
    if [ -z "$walk_json" ]; then
        walk_json=$(_impact_walk "${resolved_seeds[@]}" "${walk_flags[@]}") || return 1
    fi

    # Sprint 2b: fold code quality per impacted node when explicitly requested.
    if [ "$include_quality" = "true" ]; then
        local quality_rows='[]'
        local impacted_id impacted_quality
        while IFS= read -r impacted_id; do
            [ -z "$impacted_id" ] && continue
            impacted_quality=$(_context_gather_quality "$impacted_id")
            quality_rows=$(printf '%s' "$quality_rows" | jq -c \
                --arg id "$impacted_id" \
                --argjson q "$impacted_quality" \
                '. + [{node_id:$id, code_quality:($q.code_quality // []), quality_as_of:($q.quality_as_of // null)}]')
        done < <(printf '%s' "$walk_json" | jq -r '.impacted[].node_id')

        walk_json=$(printf '%s' "$walk_json" | jq -c --argjson quality "$quality_rows" '
            .impacted |= map(
                . as $node
                | (first($quality[]? | select(.node_id == $node.node_id))) as $q
                | if $q
                  then . + {code_quality: ($q.code_quality // []), quality_as_of: ($q.quality_as_of // null)}
                  else . + {code_quality: [], quality_as_of: null}
                  end
            )
        ')
    fi

    # Persist cache after quality fold-in to keep parity by quality_key.
    if [ -n "$walk_json" ]; then
        printf '%s' "$walk_json" > "$cache_file"
    fi

    # Seeds info
    local seeds_in
    seeds_in=$(printf "'%s'," "${resolved_seeds[@]}")
    seeds_in="${seeds_in%,}"
    local seeds_json
    seeds_json=$(db_query_json "
        SELECT id AS node_id, COALESCE(alias,substr(text,1,40)) AS label, status
        FROM nodes WHERE id IN (${seeds_in});
    ")
    seeds_json="${seeds_json:-[]}"

    # Unblocked anti-join: todo/blocked nodes whose ONLY blockers are seeds
    local unblocked_json
    unblocked_json=$(db_query_json "
        SELECT n.id AS node_id, COALESCE(n.alias,substr(n.text,1,40)) AS label, n.status
        FROM nodes n
        WHERE n.status IN ('todo','blocked')
          AND n.id NOT IN (${seeds_in})
          AND EXISTS (
              SELECT 1 FROM edges e
              WHERE e.target=n.id AND e.type='blocks' AND e.source IN (${seeds_in})
          )
          AND NOT EXISTS (
              SELECT 1 FROM edges e
              WHERE e.target=n.id AND e.type='blocks' AND e.source NOT IN (${seeds_in})
          );
    ")
    unblocked_json="${unblocked_json:-[]}"

    # Affected suites from seed nodes' touched files
    local _files=()
    local _tf _f
    for sid in "${resolved_seeds[@]}"; do
        _tf=$(db_query "SELECT json_extract(metadata,'$.touched_files') FROM nodes WHERE id='$(sql_escape "$sid")';" 2>/dev/null)
        if [ -n "$_tf" ] && [ "$_tf" != "null" ]; then
            while IFS= read -r _f; do
                [ -n "$_f" ] && _files+=("$_f")
            done < <(printf '%s' "$_tf" | jq -r '.[]?' 2>/dev/null)
        fi
    done
    local suites_json='[]'
    [ "${#_files[@]}" -gt 0 ] && suites_json=$(_impact_suites_for_files "${_files[@]}")

    # Summary
    local n_imp n_unbl n_suit total_s
    n_imp=$(printf '%s' "$walk_json" | jq '.impacted|length')
    n_unbl=$(printf '%s' "$unblocked_json" | jq 'length')
    n_suit=$(printf '%s' "$suites_json" | jq 'length')
    total_s=$(printf '%s' "$suites_json" | jq '[.[].last_cost_s]|add//0')
    local summary="${n_imp} impacted, ${n_unbl} unblocked, ${n_suit} suites (~${total_s}s)"

    if [ "$output_format" = "json" ]; then
        printf '%s' "$walk_json" | jq \
            --argjson seeds    "$seeds_json" \
            --argjson unblocked "$unblocked_json" \
            --argjson suites   "$suites_json" \
                        --arg     include_quality "$include_quality" \
            --arg     summary  "$summary" \
            '{seeds:$seeds,
                            impacted:(.impacted|map(
                                                   {node_id:.node_id,label:.label,status:.status,min_depth:.min_depth,directions:.directions,
                                                    blocks_count:.blocks_count,missing_criteria:(.missing_criteria==1),
                                                    depth_from_root:.depth_from_root,cross_impl_deps:.cross_impl_deps,
                                                    risk_score:.risk_score,risk_factors:.risk_factors}
                                                   + (if $include_quality=="true"
                                                        then {code_quality:(.code_quality // []), quality_as_of:(.quality_as_of // null)}
                                                        else {}
                                                        end))),
              unblocked:$unblocked,
              edges:.edges,
              affected_suites:$suites,
              summary:$summary}'
    else
        echo "── Seeds ────────────────────────────────────────────────────────"
        printf '%s' "$seeds_json" | jq -r '.[] | "  \(.node_id)  [\(.status)]  \(.label)"'
        echo ""
        if [ "$n_imp" -eq 0 ]; then
            echo "No impacted nodes found."
        else
            printf '%s' "$walk_json" | jq -r '
                .impacted | group_by(.min_depth)[] |
                ("── Depth \(.[0].min_depth) " + ("─" * 48)),
                (.[] | "  \(.node_id)  [\(.status)]  \(.label)  \(.directions)  blocks:\(.blocks_count)  risk:\(.risk_score)\(if .missing_criteria==1 then "  !criteria" else "" end)")
            '
        fi
        local n_edges
        n_edges=$(printf '%s' "$walk_json" | jq '.edges|length')
        if [ "$n_edges" -gt 0 ]; then
            echo ""
            echo "── Edges ────────────────────────────────────────────────────────"
            printf '%s' "$walk_json" | jq -r '.edges[] | "  \(.source) → \(.target)  (\(.type))"'
        fi
        if [ "$n_unbl" -gt 0 ]; then
            echo ""
            echo "── Unblocked when seeds complete ────────────────────────────────"
            printf '%s' "$unblocked_json" | jq -r '.[] | "  \(.node_id)  [\(.status)]  \(.label)"'
        fi
        if [ "$n_suit" -gt 0 ]; then
            echo ""
            echo "── Affected suites ──────────────────────────────────────────────"
            printf '%s' "$suites_json" | jq -r '.[] | "  \(.name)  (~\(.last_cost_s)s)"'
        fi
        echo ""
        echo -e "${CYAN}${summary}${NC}"
    fi
}

# ═══════════════════════════════════════════════════════════════════════════
# _impact_walk — direction-aware multi-seed CTE walker
#
# Prereq: none (creates its own internal seed table per call).
# Outputs: JSON {"impacted":[...],"edges":[...]} to stdout.
#
# Args: <seed-id> [<seed-id> ...] [--depth=N] [--direction=fwd|rev|both]
#       [--include-done] [--full]
# ═══════════════════════════════════════════════════════════════════════════

_impact_walk() {
    local max_depth=3
    local direction="both"
    local include_done=false
    local full=false
    local node_cap=50
    local seeds=()

    while [ $# -gt 0 ]; do
        case "$1" in
            --depth=*)      max_depth="${1#*=}" ;;
            --direction=*)  direction="${1#*=}" ;;
            --node-cap=*)   node_cap="${1#*=}" ;;
            --include-done) include_done=true ;;
            --full)         full=true ;;
            *)              seeds+=("$1") ;;
        esac
        shift
    done

    if [ "${#seeds[@]}" -eq 0 ]; then
        echo '{"impacted":[],"edges":[]}'; return 0
    fi

    # Build VALUES list — seeds are pre-validated by cmd_impact()
    local seed_vals
    seed_vals=$(printf "('%s')," "${seeds[@]}")
    seed_vals="${seed_vals%,}"

    # Edge type set
    local etypes="'blocks','implements','addresses'"
    if [ "$full" = "true" ]; then
        etypes="${etypes},'resolves','references','supersedes','obsoletes'"
    fi

    # CTE direction branches — UNION ALL + path string, NOT UNION (Principle 2)
    local fwd_branch="
      UNION ALL
      SELECT e.target, i.depth + 1, 'forward', i.path || e.target || ','
      FROM impact i
      JOIN edges e ON e.source = i.node_id
      WHERE i.depth < ${max_depth}
        AND e.type IN (${etypes})
        AND instr(i.path, ',' || e.target || ',') = 0"

    local rev_branch="
      UNION ALL
      SELECT e.source, i.depth + 1, 'reverse', i.path || e.source || ','
      FROM impact i
      JOIN edges e ON e.target = i.node_id
      WHERE i.depth < ${max_depth}
        AND e.type IN (${etypes})
        AND instr(i.path, ',' || e.source || ',') = 0"

    local branches
    case "$direction" in
        fwd|forward)  branches="$fwd_branch" ;;
        rev|reverse)  branches="$rev_branch" ;;
        *)            branches="${fwd_branch}${rev_branch}" ;;
    esac

    # _iw_results stores ALL traversed nodes (including done intermediates) for edge tracing.
    # The done filter is applied only in the output JSON subquery (transparent-intermediate semantics).
    local output_done_filter="AND status != 'done'"
    [ "$include_done" = "true" ] && output_done_filter=""

    db_ensure

    sqlite3 -batch -cmd ".timeout 5000" "$WV_DB" <<SQL
CREATE TEMP TABLE _iw_seeds (id TEXT PRIMARY KEY);
INSERT OR IGNORE INTO _iw_seeds VALUES ${seed_vals};

-- All traversal-reached nodes except seeds; includes done intermediates for edge tracing.
CREATE TEMP TABLE _iw_results AS
WITH RECURSIVE impact(node_id, depth, direction, path) AS (
  SELECT id, 0, 'seed', ',' || id || ','
  FROM _iw_seeds

  ${branches}
)
SELECT i.node_id,
       MIN(i.depth)                                                  AS min_depth,
       CASE
         WHEN SUM(CASE WHEN i.direction = 'forward' THEN 1 ELSE 0 END) > 0
          AND SUM(CASE WHEN i.direction = 'reverse' THEN 1 ELSE 0 END) > 0 THEN 'both'
         WHEN SUM(CASE WHEN i.direction = 'forward' THEN 1 ELSE 0 END) > 0 THEN 'forward'
         ELSE 'reverse'
       END                                                           AS directions,
       COALESCE(n.alias, substr(n.text, 1, 40))                      AS label,
       n.status,
       n.text,
       (SELECT COUNT(*) FROM edges
        WHERE source = i.node_id AND type = 'blocks')                AS blocks_count,
       (json_extract(n.metadata, '$.done_criteria') IS NULL)         AS missing_criteria,
       json_extract(n.metadata, '$.type')                            AS node_type
FROM impact i
JOIN nodes n ON n.id = i.node_id
WHERE i.depth > 0
  AND i.node_id NOT IN (SELECT id FROM _iw_seeds)
GROUP BY i.node_id
ORDER BY min_depth, blocks_count DESC
LIMIT ${node_cap};

-- Scope for ancestry/risk computation: seeds + impacted nodes.
CREATE TEMP TABLE _iw_scope AS
SELECT id AS node_id FROM _iw_seeds
UNION
SELECT node_id FROM _iw_results;

-- Walk implements ancestry upward (child -> parent) for each scoped node.
CREATE TEMP TABLE _iw_root_walk AS
WITH RECURSIVE root_walk(start_id, node_id, depth, path) AS (
    SELECT node_id, node_id, 0, ',' || node_id || ','
    FROM _iw_scope

    UNION ALL

    SELECT rw.start_id,
                 e.target,
                 rw.depth + 1,
                 rw.path || e.target || ','
    FROM root_walk rw
    JOIN edges e ON e.source = rw.node_id
    WHERE e.type = 'implements'
        AND rw.depth < 64
        AND instr(rw.path, ',' || e.target || ',') = 0
)
SELECT start_id, node_id, depth
FROM root_walk;

CREATE TEMP TABLE _iw_roots AS
SELECT rw.start_id AS node_id,
             COALESCE(
                 (SELECT rw2.node_id
                    FROM _iw_root_walk rw2
                    WHERE rw2.start_id = rw.start_id
                    ORDER BY rw2.depth DESC
                    LIMIT 1),
                 rw.start_id
             ) AS root_id,
             MAX(rw.depth) AS depth_from_root
FROM _iw_root_walk rw
GROUP BY rw.start_id;

-- Sprint 2a risk scoring basis: depth_from_root + cross-subtree blockers.
CREATE TEMP TABLE _iw_scored AS
SELECT r.node_id,
             r.min_depth,
             r.directions,
             r.label,
             r.status,
             r.text,
             r.blocks_count,
             r.missing_criteria,
             r.node_type,
             COALESCE(rr.depth_from_root, 0) AS depth_from_root,
             (
                 SELECT COUNT(DISTINCT e.source)
                 FROM edges e
                 LEFT JOIN _iw_roots sr ON sr.node_id = e.source
                 WHERE e.type = 'blocks'
                     AND e.target = r.node_id
                     AND COALESCE(sr.root_id, e.source) != COALESCE(rr.root_id, r.node_id)
             ) AS cross_impl_deps
FROM _iw_results r
LEFT JOIN _iw_roots rr ON rr.node_id = r.node_id;

SELECT json_object(
  'impacted', COALESCE(
        (SELECT json_group_array(json_object(
                'node_id',          node_id,
                'min_depth',        min_depth,
                'directions',       directions,
                'label',            label,
                'status',           status,
                'text',             text,
                'blocks_count',     blocks_count,
                'missing_criteria', missing_criteria,
                'node_type',        node_type,
                'depth_from_root',  depth_from_root,
                'cross_impl_deps',  cross_impl_deps,
                'risk_score',       risk_score,
                'risk_factors', json_object(
                        'blocks_count',       blocks_contrib,
                        'depth_from_root',    depth_contrib,
                        'missing_criteria',   criteria_contrib,
                        'cross_impl_deps',    cross_contrib
                )
        ))
        FROM (
            SELECT node_id,
                         min_depth,
                         directions,
                         label,
                         status,
                         text,
                         blocks_count,
                         missing_criteria,
                         node_type,
                         depth_from_root,
                         cross_impl_deps,
                         ROUND(MIN(0.30, blocks_count * 0.10), 3) AS blocks_contrib,
                         ROUND(
                             CASE
                                 WHEN depth_from_root <= 0 THEN 0.25
                                 WHEN depth_from_root = 1 THEN 0.20
                                 WHEN depth_from_root = 2 THEN 0.15
                                 WHEN depth_from_root = 3 THEN 0.10
                                 ELSE 0.05
                             END,
                             3
                         ) AS depth_contrib,
                         ROUND(CASE WHEN missing_criteria = 1 THEN 0.25 ELSE 0.0 END, 3) AS criteria_contrib,
                         ROUND(MIN(0.20, cross_impl_deps * 0.10), 3) AS cross_contrib,
                         ROUND(
                             MIN(
                                 1.0,
                                 MIN(0.30, blocks_count * 0.10) +
                                 CASE
                                     WHEN depth_from_root <= 0 THEN 0.25
                                     WHEN depth_from_root = 1 THEN 0.20
                                     WHEN depth_from_root = 2 THEN 0.15
                                     WHEN depth_from_root = 3 THEN 0.10
                                     ELSE 0.05
                                 END +
                                 CASE WHEN missing_criteria = 1 THEN 0.25 ELSE 0.0 END +
                                 MIN(0.20, cross_impl_deps * 0.10)
                             ),
                             3
                         ) AS risk_score
            FROM _iw_scored
            WHERE 1=1 ${output_done_filter}
            ORDER BY min_depth, blocks_count DESC
        )),
    json('[]')
  ),
  'edges', COALESCE(
    (SELECT json_group_array(json_object(
        'source',  source,
        'target',  target,
        'type',    type,
        'weight',  weight,
        'context', json(COALESCE(context, '{}'))
        )) FROM edges
     WHERE source IN (SELECT id FROM _iw_seeds UNION SELECT node_id FROM _iw_results)
       AND target IN (SELECT id FROM _iw_seeds UNION SELECT node_id FROM _iw_results)),
    json('[]')
  )
);
SQL
}
