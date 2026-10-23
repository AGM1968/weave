#!/bin/bash
# wv-cmd-graph.sh — Graph traversal and edge commands
#
# Commands: block, link, unlink, resolve, related, edges, path, context, impact, discover
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
            *) _wv_reject_arg block "$1"; return 1 ;;
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
    id_exists=$(db_query "SELECT COUNT(*) FROM nodes WHERE id='$id';") || return 1
    blocker_exists=$(db_query "SELECT COUNT(*) FROM nodes WHERE id='$blocker';") || return 1
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
        wv_policy_verdict block_graph_acyclic deny yes "" "a node blocking itself can never become ready"
        echo -e "${RED}Error: a node cannot block itself${NC}" >&2
        return 1
    fi

    # Check for circular blocking (A blocks B, B blocks A)
    local reverse_exists
    reverse_exists=$(db_query "SELECT COUNT(*) FROM edges WHERE source='$id' AND target='$blocker' AND type='blocks';") || return 1
    if [ "$reverse_exists" != "0" ]; then
        wv_policy_verdict block_graph_acyclic deny yes "" "two nodes blocking each other can never become ready"
        echo -e "${RED}Error: circular block detected — $blocker is already blocked by $id${NC}" >&2
        return 1
    fi
    wv_policy_verdict block_graph_acyclic allow no "" "the edge closes no cycle"

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
        src_label=$(db_query "SELECT COALESCE(alias, substr(text,1,40)) FROM nodes WHERE id='$blocker';") || return 1
        tgt_label=$(db_query "SELECT COALESCE(alias, substr(text,1,40)) FROM nodes WHERE id='$id';") || return 1
        context=$(jq -nc --arg s "$src_label" --arg t "$tgt_label" \
            '{summary: ($s + " blocks " + $t), auto: true}') || return 1
    fi

    local ctx_escaped="${context//\'/\'\'}"

    # Dispatch runs in an OR-list: do not rely on implicit errexit. Both
    # writes must commit together or the closed connection rolls them back.
    local edge_sql
    if [ "$explicit_context" = "true" ]; then
        edge_sql="INSERT INTO edges (source, target, type, weight, context, created_at)
            VALUES ('$blocker', '$id', 'blocks', 1.0, '$ctx_escaped', CURRENT_TIMESTAMP)
            ON CONFLICT(source, target, type) DO UPDATE SET
                context = excluded.context, created_at = CURRENT_TIMESTAMP;"
    else
        edge_sql="INSERT OR IGNORE INTO edges (source, target, type, weight, context, created_at) VALUES ('$blocker', '$id', 'blocks', 1.0, '$ctx_escaped', CURRENT_TIMESTAMP);"
    fi
    db_query "BEGIN IMMEDIATE;
        $edge_sql
        UPDATE nodes SET status='blocked', updated_at=CURRENT_TIMESTAMP WHERE id='$id';
        COMMIT;" || return 1

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
            # wv-cccf70: every other flag in this CLI is hyphenated
            # (--verification-method), but VALID_EDGE_TYPES itself is
            # underscored (relates_to) to match the DB CHECK constraint --
            # accept the hyphenated spelling as an input alias here rather
            # than rename the canonical enum, which stores/reads underscored
            # values everywhere else (wv-db.sh schema, existing edges).
            --type=*) edge_type="${1#*=}"; edge_type="${edge_type//-/_}" ;;
            --weight=*) weight="${1#*=}" ;;
            --context=*) context="${1#*=}" ;;
            *) _wv_reject_arg link "$1"; return 1 ;;
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
    from_exists=$(db_query "SELECT COUNT(*) FROM nodes WHERE id='$from';") || return 1
    if [ "$from_exists" = "0" ]; then
        echo -e "${RED}Error: source node $from not found${NC}" >&2
        return 1
    fi

    local to_exists
    to_exists=$(db_query "SELECT COUNT(*) FROM nodes WHERE id='$to';") || return 1
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
        src_label=$(db_query "SELECT COALESCE(alias, substr(text,1,40)) FROM nodes WHERE id='$from';") || return 1
        tgt_label=$(db_query "SELECT COALESCE(alias, substr(text,1,40)) FROM nodes WHERE id='$to';") || return 1
        context=$(jq -nc --arg s "$src_label" --arg t "$tgt_label" --arg e "$edge_type" \
            '{summary: ($s + " " + $e + " " + $t), auto: true}') || return 1
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
            created_at = CURRENT_TIMESTAMP;" || return 1

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
            --type=*) edge_type="${1#*=}"; edge_type="${edge_type//-/_}" ;;
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
    count=$(db_query "SELECT COUNT(*) FROM edges WHERE source='$from' AND target='$to' AND type='$edge_type';") || return 1
    if [ "$count" = "0" ]; then
        echo -e "${RED}Error: edge $from --[$edge_type]--> $to not found${NC}" >&2
        return 1
    fi

    db_query "DELETE FROM edges WHERE source='$from' AND target='$to' AND type='$edge_type';" || return 1

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

            # Close the loser first, through the same receipt as wv done
            # (wv-957fc8): a refused close must leave the graph unchanged, not
            # rewire the contradiction around a node that is still open.
            _done_close "$loser" "" "metadata" "status='done', updated_at=CURRENT_TIMESTAMP" || return 1

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

            echo -e "${GREEN}✓${NC} Resolved: $winner supersedes $loser"
            [ -n "$rationale" ] && echo "  Rationale: $rationale"
            ;;

        merge)
            # Close both originals first, each through the same receipt as wv
            # done (wv-957fc8), before the merged node exists. If the second is
            # refused the first is already closed; say so rather than leave it
            # to be discovered.
            _done_close "$node1" "" "metadata" "status='done', updated_at=CURRENT_TIMESTAMP" || return 1
            if ! _done_close "$node2" "" "metadata" "status='done', updated_at=CURRENT_TIMESTAMP"; then
                echo -e "${RED}Error: $node2 could not be closed; $node1 is already closed and no merged node was created${NC}" >&2
                return 1
            fi

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

            echo -e "${GREEN}✓${NC} Resolved: created merged node $new_id (obsoletes $node1 and $node2)"
            [ -n "$rationale" ] && echo "  Rationale: $rationale"
            ;;

        defer)
            # A deferral closes nothing, so the close rules have nothing to judge.
            _close_rules_not_engaged "a deferred resolution closes neither node"
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
            --type=*)      edge_type="${1#*=}"; edge_type="${edge_type//-/_}" ;;
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
            --type=*) edge_type="${1#*=}"; edge_type="${edge_type//-/_}" ;;
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

    # Cache setup (per session in tmpfs) — keyed by id+mode so different modes don't collide.
    # Version suffix bumped on any payload-shape change (v3 -> v4: wv-22ca26 added
    # done_criteria/risks/risk_level to node and blocked_reason to the envelope) so a
    # pre-upgrade cache file on disk cannot mask the new fields — it just misses on the
    # new filename and gets regenerated, rather than being read and served stale-shaped.
    local cache_dir="$WV_HOT_ZONE/context_cache"
    mkdir -p "$cache_dir"
    local cache_file="$cache_dir/${id}-${mode}-v4.json"

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

        # Valid only if STRICTLY newer than any edge/node change: both clocks are
        # whole seconds, so a change in the same second as the cache write is
        # indistinguishable from one before it, and ">=" served the pre-change
        # pack -- a removed contradiction kept denying edits (wv-228099).
        if [ "$cache_time" -gt "$edge_time" ]; then
            cat "$cache_file"
            return 0
        fi
    fi

    # Get node details
    local node_json
    node_json=$(db_query_json "SELECT id, text, status, json(metadata) AS metadata, created_at, updated_at FROM nodes WHERE id='$id';")
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
        # wv-5850d4: same argv-size hazard as the full composer below — node
        # metadata alone can outgrow MAX_ARG_STRLEN — so read payloads from
        # files here too.
        local bootstrap_pack
        bootstrap_pack=$(mktemp -d "$cache_dir/.pack-XXXXXX") || return 1
        printf '%s' "$node_json"       > "$bootstrap_pack/node.json"
        printf '%s' "$blockers_json"   > "$bootstrap_pack/blockers.json"
        printf '%s' "$self_block_json" > "$bootstrap_pack/self_block.json"
        jq -n \
            --slurpfile _node "$bootstrap_pack/node.json" \
            --slurpfile _blockers "$bootstrap_pack/blockers.json" \
            --slurpfile _self_block "$bootstrap_pack/self_block.json" \
            '$_node[0] as $node |
             $_blockers[0] as $blockers |
             $_self_block[0] as $self_block |
             ($self_block[0].blocked_reason // null) as $br
             # wv-cccf70: {id,text,status} dropped done_criteria/risks/
             # risk_level entirely -- wv preflight was the only reliable
             # read path for has_done_criteria, confirmed exact match to
             # an external audit repro. Surface the gate-relevant subset
             # here too, not the full metadata blob (keeps this payload
             # small and stable rather than exposing every ad-hoc key).
             | {node: ($node[0] | . + {metadata: (.metadata | if type == "string" then fromjson else . end)} | {id, text, status,
                    done_criteria: (.metadata.done_criteria // []),
                    risks: (.metadata.risks // []),
                    risk_level: (.metadata.risk_level // null)}),
                blocked: ($br != null),
                blocked_reason: $br,
                blockers: ($blockers | map({id, text, status}))}'
        local bootstrap_rc=$?
        rm -rf "$bootstrap_pack"
        if [ "$bootstrap_rc" -ne 0 ]; then
            echo -e "${RED}Error: failed to compose bootstrap context for $id${NC}" >&2
        fi
        return "$bootstrap_rc"
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
        ORDER BY weight DESC
        LIMIT 5;
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
    #
    # wv-5850d4: two corrections here. (1) The LIMIT matches the composer's
    # $pitfalls[0:3] slice — without it a wide neighborhood (wv-a8c823: 217
    # nodes, 56 pitfall rows, ~140KB of metadata) fetched megabytes only to
    # discard all but three. (2) json(n.metadata) had no AS metadata alias, so
    # the column arrived as "json(n.metadata)" and the composer's .metadata was
    # always null — every pitfall rendered with pitfall: null.
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
        SELECT DISTINCT n.id, n.text, n.status, json(n.metadata) AS metadata
        FROM nodes n
        WHERE json_extract(n.metadata, '$.pitfall') IS NOT NULL
          AND n.id IN (SELECT id FROM node_neighborhood)
        ORDER BY n.updated_at DESC
        LIMIT 3;
    ")
    pitfalls_json="${pitfalls_json:-[]}"

    # Get contradictions (nodes with contradicts edges)
    # wv-5850d4: metadata dropped from the projection — the composer maps only
    # {id, text, status}, so it was pure payload weight.
    local contradictions_json
    contradictions_json=$(db_query_json "
        SELECT DISTINCT n.id, n.text, n.status
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

    # Bounded blindspot report for planning surfaces. Candidates remain
    # hypotheses: cmd_discover marks impact-derived rows as candidate state.
    local discovery_json='null'
    if [ "$mode" = "discover" ] || [ "$mode" = "execute" ] || [ "$mode" = "full" ]; then
        discovery_json=$(cmd_discover "$id" --json --depth=2 --limit=5 2>/dev/null || echo 'null')
        [ -z "$discovery_json" ] && discovery_json='null'
    fi

    # Compose Context Pack with field cleanup and limits (per proposal lines 222-237)
    # discover: cap ancestors at 5
    local _discover_mode="false"
    [ "$mode" = "discover" ] && _discover_mode="true"

    # wv-5850d4: payloads reach jq through files, never argv. A single --argjson
    # string over MAX_ARG_STRLEN (131072 on Linux) makes execve fail with E2BIG
    # before jq ever starts, which surfaced as empty stdout with exit 0. The
    # per-query LIMITs above keep the payloads small; --slurpfile makes their
    # size stop being a correctness boundary at all. Each file holds one JSON
    # value, so $_name[0] is the payload and the composer body is unchanged.
    local pack_dir
    pack_dir=$(mktemp -d "$cache_dir/.pack-XXXXXX") || return 1
    printf '%s' "$node_json"           > "$pack_dir/node.json"
    printf '%s' "$blockers_json"       > "$pack_dir/blockers.json"
    printf '%s' "$ancestors_json"      > "$pack_dir/ancestors.json"
    printf '%s' "$related_json"        > "$pack_dir/related.json"
    printf '%s' "$finding_json"        > "$pack_dir/finding.json"
    printf '%s' "$pitfalls_json"       > "$pack_dir/pitfalls.json"
    printf '%s' "$contradictions_json" > "$pack_dir/contradictions.json"
    printf '%s' "$quality_json"        > "$pack_dir/quality.json"
    printf '%s' "$discovery_json"      > "$pack_dir/discovery.json"
    printf '%s' "$self_block_json"     > "$pack_dir/self_block.json"

    jq -n \
        --slurpfile _node "$pack_dir/node.json" \
        --slurpfile _blockers "$pack_dir/blockers.json" \
        --slurpfile _ancestors "$pack_dir/ancestors.json" \
        --slurpfile _related "$pack_dir/related.json" \
        --slurpfile _finding "$pack_dir/finding.json" \
        --slurpfile _pitfalls "$pack_dir/pitfalls.json" \
        --slurpfile _contradictions "$pack_dir/contradictions.json" \
        --slurpfile _quality "$pack_dir/quality.json" \
        --slurpfile _discovery "$pack_dir/discovery.json" \
        --slurpfile _self_block "$pack_dir/self_block.json" \
        --argjson discover_mode "$_discover_mode" \
        '$_node[0] as $node |
        $_blockers[0] as $blockers |
        $_ancestors[0] as $ancestors |
        $_related[0] as $related |
        $_finding[0] as $finding |
        $_pitfalls[0] as $pitfalls |
        $_contradictions[0] as $contradictions |
        $_quality[0] as $quality |
        $_discovery[0] as $discovery |
        $_self_block[0] as $self_block |
        ($self_block[0].blocked_reason // null) as $br |
        {
            # wv-cccf70: same reasoning as the identical comment in
            # bootstrap mode above -- surface the gate-relevant metadata
            # subset here too.
            node: ($node[0] | . + {metadata: (.metadata | if type == "string" then fromjson else . end)} | {id, text, status,
                done_criteria: (.metadata.done_criteria // []),
                risks: (.metadata.risks // []),
                risk_level: (.metadata.risk_level // null)}),
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
            discovery: $discovery,
            code_quality: $quality.code_quality,
            quality_as_of: $quality.quality_as_of
        }' > "$cache_file.tmp"
    local compose_rc=$?
    rm -rf "$pack_dir"

    # wv-5850d4: the old form piped jq into tee, so the pipeline reported tee's
    # status and a failed compose returned 0 with nothing on stdout — a silent
    # miss for every caller of workflow rule 5. Fail loudly instead, and never
    # leave a truncated pack behind as a cache entry.
    if [ "$compose_rc" -ne 0 ]; then
        rm -f "$cache_file.tmp"
        echo -e "${RED}Error: failed to compose context pack for $id${NC}" >&2
        return "$compose_rc"
    fi

    mv "$cache_file.tmp" "$cache_file" || { rm -f "$cache_file.tmp"; return 1; }
    cat "$cache_file"
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
        [ -z "$results" ] && results="[]"
        if [ "$node_cap" -gt 0 ] && [ "$total_nodes" -gt "$node_cap" ]; then
            results=$(printf '%s\n' "$results" | jq \
                --argjson shown "$node_cap" --argjson total "$total_nodes" \
                '. + [{_meta:"truncation", shown:$shown, total:$total, truncated:true}]')
            echo "wv tree: showing $node_cap of $total_nodes nodes (use --all to lift the cap)" >&2
        fi
        echo "$results"
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
# prefixes ending in / (src/ = suite). Exact and matching pattern entries are
# unioned so adding a more-specific row cannot remove a broader safety suite.
# A `* = suite` entry, or bare suite tokens under a `[default]` section, sets a
# fail-safe default used after explicit mappings and the naming heuristic.
# Falls back to naming-convention heuristic when conf is absent or a file
# has no explicit/glob mapping:
#   scripts/cmd/wv-cmd-<X>.sh  →  tests/test-<X>.sh
#   scripts/lib/*.sh or scripts/wv  →  tests/run-all.sh
# Bare suite paths under a `[heavy]` section mark the push tier (wv-862ac0):
# routing is unchanged, but each suite is emitted with "tier":"heavy" or
# "light", and the pre-commit gate leaves heavy suites to the pre-push gate.
# Reads .weave/test-times.json for estimated suite cost.
# Outputs JSON: [{"name":"test-X.sh","last_cost_s":N,"tier":"light|heavy",
# "declared":true|false}, ...]. declared: a map row, pattern, [default] or
# [scanners] entry selected it, so the suite is an obligation; false: only the
# naming heuristic or a changed suite's own run did (wv-fb861c).
# An [inputs] section ("suite = glob ...") is skipped here: it declares a
# suite's complete input scope for result reuse, not a route (wv-f0bcc4).
# With --routes first, prints the route table instead: one "<file>\t<suite>"
# line per route, so a caller can invert it into each suite's inputs
# (wv test-status --inputs, wv-cb4913). One router, two views.
# _IMPACT_MAP_REVS (set by wv impact --map-rev=<rev>, repeatable) routes by
# the map each named commit or tree holds in git instead of the working-tree
# file, and unions the suites every map selects, so a transition keeps the
# routes of both sides (F5, wv-fe8007). A suite is heavy only when every map
# marks it heavy: a commit cannot move its own suite to the push tier.
# ═══════════════════════════════════════════════════════════════════════════

# _impact_map_at_rev <rev> — the .weave/test-map.conf blob <rev> holds:
# prints "<blob id>" or "none" when the rev has no map; 1 when the rev or the
# entry cannot be read, or the map is not a regular file. Never the working
# tree, and never a link: a link's blob is a pathname, which parsed as a map
# routed nothing (R4, wv-77b743).
_impact_map_at_rev() {
    local tree entry meta
    [ -n "${REPO_ROOT:-}" ] || return 1
    tree=$(git -C "$REPO_ROOT" rev-parse --verify --quiet "${1}^{tree}" 2>/dev/null) || return 1
    entry=$(git -C "$REPO_ROOT" ls-tree --full-tree "$tree" -- .weave/test-map.conf 2>/dev/null) || return 1
    if [ -z "$entry" ]; then echo none; return 0; fi
    meta=${entry%%$'\t'*}
    case "$meta" in
        "100644 blob "* | "100755 blob "*) printf '%s\n' "${meta##* }" ;;
        *)
            echo "wv: .weave/test-map.conf at $1 is not a regular file (${meta%% *}); links are not followed" >&2
            return 1 ;;
    esac
}

# The revisions whose maps route (wv impact --map-rev); empty: the working tree.
_IMPACT_MAP_REVS=()

_impact_suites_for_files() {
    local _routes_only=false
    if [ "${1:-}" = "--routes" ]; then _routes_only=true; shift; fi
    if [ $# -eq 0 ]; then [ "$_routes_only" = true ] || echo '[]'; return 0; fi

    local map_conf="${WEAVE_DIR}/test-map.conf"
    local times_json="${WEAVE_DIR}/test-times.json"

    local times_data='{}'
    [ -f "$times_json" ] && times_data=$(cat "$times_json" 2>/dev/null || echo '{}')

    # The maps that route: the working-tree file, or each named revision's.
    local -a _map_texts=() _map_labels=()
    local _conf_text="" _conf_rc=0
    if [ "${#_IMPACT_MAP_REVS[@]}" -gt 0 ]; then
        local _rev _blob _blobs=" "
        for _rev in "${_IMPACT_MAP_REVS[@]}"; do
            if ! _blob=$(_impact_map_at_rev "$_rev"); then
                echo "wv: cannot read .weave/test-map.conf at $_rev" >&2
                return 1
            fi
            # Two sides holding the same map route once.
            case "$_blobs" in *" $_blob "*) continue ;; esac
            _blobs+="$_blob "
            _conf_text=""
            if [ "$_blob" != none ]; then
                _conf_text=$(git -C "$REPO_ROOT" cat-file blob "$_blob" 2>/dev/null) || {
                    echo "wv: cannot read .weave/test-map.conf at $_rev" >&2
                    return 1
                }
            fi
            _map_texts+=("$_conf_text"); _map_labels+=("$_rev:.weave/test-map.conf")
        done
    else
        # A conf that exists but cannot be read is a failure, not an absent
        # conf: the naming heuristic would route fewer suites than the conf
        # says, and every gate would take that narrower set for the answer
        # (wv-cf48a9). A dangling symlink, or a .weave/ that cannot be
        # searched, is unavailable too, never absent (wv-b02828).
        _conf_text=$(wv_config_read "$map_conf") || _conf_rc=$?
        if [ "$_conf_rc" -ne 0 ] && [ "$_conf_rc" -ne 2 ]; then
            echo "wv: cannot read $map_conf" >&2
            return 1
        fi
        _map_texts+=("$_conf_text"); _map_labels+=("$map_conf")
    fi

    declare -A _seen=() _heavy_maps=() _declared=()
    local _mi _nmaps=${#_map_texts[@]}
    for _mi in "${!_map_texts[@]}"; do
        _conf_text=${_map_texts[$_mi]}
        map_conf=${_map_labels[$_mi]}

        # Parse conf. Exact keys go in _fmap; pattern keys (containing glob
        # metacharacters * ? [ , or ending in / for a directory prefix) are kept
        # in insertion order in _pat_keys/_pat_vals so a consumer can map a whole
        # subtree with one line (src/**/*.py = suite, or src/ = suite). A `* = suite`
        # entry, or any suite tokens under a `[default]` section, become the
        # fail-safe default applied when nothing else matches a file.
        declare -A _fmap=()
        local _pat_keys=() _pat_vals=()
        local _default_suites=""
        # [scanners] (wv-b21ca8): a suite that scans a whole tree, with the globs
        # it scans. Additive: after a file resolves as usual, [default] included,
        # every scanner whose scope matches it is added, so no row, heuristic or
        # fail-safe changes. One registry, not a row per scanned file.
        local _scan_suites=() _scan_scopes=()
        declare -A _heavy=()
        if [ -n "$_conf_text" ]; then
            local _in_default=false _in_scanners=false _in_heavy=false _in_inputs=false
            while IFS= read -r line; do
                # Strip leading whitespace; comments and blanks are noise
                line="${line#"${line%%[![:space:]]*}"}"
                [[ "$line" =~ ^# || -z "$line" ]] && continue
                # Section headers toggle the [default] accumulator
                if [[ "$line" =~ ^\[ ]]; then
                    _in_default=false; _in_scanners=false; _in_heavy=false; _in_inputs=false
                    if [[ "$line" =~ ^\[default\] ]]; then _in_default=true; fi
                    if [[ "$line" =~ ^\[scanners\] ]]; then _in_scanners=true; fi
                    if [[ "$line" =~ ^\[heavy\] ]]; then _in_heavy=true; fi
                    if [[ "$line" =~ ^\[inputs\] ]]; then _in_inputs=true; fi
                    continue
                fi
                # [inputs] declares a suite's complete input scope for result reuse
                # (wv test-status --inputs, wv-f0bcc4). It is never a route.
                [ "$_in_inputs" = true ] && continue
                if [ "$_in_heavy" = true ]; then
                    # Tier only: never a route, so a stray '=' line here is ignored
                    # rather than read as a mapping.
                    if [[ "$line" != *=* ]]; then
                        local _h
                        for _h in $line; do _heavy["$_h"]=1; done
                    fi
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
                if [ -z "$key" ]; then
                    echo "wv: $map_conf: a mapping with no source path: $line" >&2
                    return 1
                fi
                if [ "$_in_scanners" = true ]; then
                    _scan_suites+=("$key"); _scan_scopes+=("$val")
                    continue
                fi
                if [ "$key" = "*" ]; then
                    _default_suites="${_default_suites:+$_default_suites }$val"
                elif [[ "$key" == *[\*\?\[]* || "$key" == */ ]]; then
                    _pat_keys+=("$key"); _pat_vals+=("$val")
                else
                    _fmap["$key"]="$val"
                fi
            done <<< "$_conf_text"
        fi

        # Collect matched suites (deduped). Exact and every matching glob/prefix
        # entry are unioned, plus a changed test suite itself unless its own exact
        # row says otherwise; only a file with no match uses the naming
        # heuristic, then [default] as the fail-safe.
        local _h
        for _h in "${!_heavy[@]}"; do _heavy_maps["$_h"]=$(( ${_heavy_maps[$_h]:-0} + 1 )); done
        for f in "$@"; do
            # decl: what the map itself selects (rows, patterns, [default],
            # [scanners]); the naming heuristic and a changed suite's own run
            # are suggestions, not obligations (R3, wv-fb861c).
            local suites="" decl=""
            if [ -n "${_fmap[$f]+x}" ]; then
                suites="${_fmap[$f]}"; decl="$suites"
            fi
            # Glob/prefix keys — union all matching patterns, including when an
            # exact row exists. This is the monotonic routing invariant.
            local _i
            for _i in "${!_pat_keys[@]}"; do
                local _pk="${_pat_keys[$_i]}"
                if [[ "$_pk" == */ ]]; then
                    if [[ "$f" == "$_pk"* ]]; then
                        suites="${suites:+$suites }${_pat_vals[$_i]}"; decl="${decl:+$decl }${_pat_vals[$_i]}"
                    fi
                else
                    # unquoted RHS is intentional: glob-match the conf key
                    # shellcheck disable=SC2053
                    if [[ "$f" == $_pk ]]; then
                        suites="${suites:+$suites }${_pat_vals[$_i]}"; decl="${decl:+$decl }${_pat_vals[$_i]}"
                    fi
                fi
            done
            # A changed suite runs itself. A broader glob or prefix row adds to
            # that; only the suite's own exact row can redirect it, as for a suite
            # another suite drives (wv-a8ab96).
            if [[ "$f" == tests/test-*.sh && -z "${_fmap[$f]+x}" ]]; then
                suites="${suites:+$suites }$f"
            fi
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
                esac
            fi
            # Fail safe: a configured [default] suite beats running nothing
            [ -z "$suites" ] && suites="$_default_suites" && decl="$_default_suites"
            # Tree-wide scanners whose scope covers this file (wv-b21ca8)
            local _si _scope _scopes
            for _si in "${!_scan_suites[@]}"; do
                # read -ra splits without pathname expansion: an unquoted
                # $scopes would glob 'tests/*.sh' against the working directory
                # and miss a file that does not exist yet.
                read -ra _scopes <<< "${_scan_scopes[$_si]}"
                for _scope in "${_scopes[@]}"; do
                    # unquoted RHS is intentional: glob-match the scope
                    # shellcheck disable=SC2053
                    if [[ "$f" == $_scope ]]; then
                        suites="${suites:+$suites }${_scan_suites[$_si]}"; decl="${decl:+$decl }${_scan_suites[$_si]}"
                        break
                    fi
                done
            done
            local s
            for s in $suites; do
                [ "$_routes_only" = true ] && printf '%s\t%s\n' "$f" "$s"
                _seen["$s"]=1
            done
            for s in $decl; do _declared["$s"]=1; done
        done
    done
    [ "$_routes_only" = true ] && return 0

    # Emit JSON with cost. name = full suite path; cost lookup uses basename
    # (test-times.json is keyed by basename from serial-mode timing writes).
    local out='['
    local first=true
    local suite suite_esc
    for suite in "${!_seen[@]}"; do
        local bname; bname=$(basename "$suite")
        local cost; cost=$(printf '%s' "$times_data" | jq -r --arg n "$bname" '.[$n] // 0' 2>/dev/null || echo 0)
        local tier=light declared=false
        [ "${_heavy_maps[$suite]:-0}" -eq "$_nmaps" ] && tier=heavy
        [ -n "${_declared[$suite]+x}" ] && declared=true
        # Inside printf's arguments a failed escape would emit "name":"" with
        # status 0, a suite no gate can run (wv-3e6d45, wv-cf48a9).
        suite_esc=$(wv_json_escape "$suite") || return 1
        [ "$first" = "true" ] || out+=','
        out+=$(printf '{"name":"%s","last_cost_s":%s,"tier":"%s","declared":%s}' "$suite_esc" "$cost" "$tier" "$declared")
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
    # Hook VALIDATION runs before every branch, including the cached path and
    # any early exit. Sitting inside the cache-miss branch, it accepted an
    # unrecognised value silently whenever the walk was served from cache --
    # so "unknown values are rejected" was true only on the slow path, which
    # is the one a test is least likely to take twice. Only the fault EXECUTION
    # stays at the site it perturbs.
    local _impact_race=false
    if [ -n "${WV_TEST_IMPACT_RACE:-}" ]; then
        if [ "${WV_TEST_MODE:-}" != "1" ]; then
            echo "wv impact: WV_TEST_IMPACT_RACE is set but WV_TEST_MODE=1 is not — ignoring it" >&2
        elif [ "${WV_TEST_IMPACT_RACE}" = "1" ]; then
            _impact_race=true
        else
            echo -e "${RED}Error: WV_TEST_IMPACT_RACE='${WV_TEST_IMPACT_RACE}' is not a recognised value (1)${NC}" >&2
            return 1
        fi
    fi

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
            --map-rev=*)
                [ -n "${1#*=}" ] || { echo -e "${RED}Error: --map-rev needs a revision${NC}" >&2; return 1; }
                _IMPACT_MAP_REVS+=("${1#*=}") ;;
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
            # A router failure is not "no suites affected" (wv-cf48a9).
            _suites_json=$(_impact_suites_for_files "${file_seeds[@]}") || return 1
            if [ "$output_format" = "json" ]; then
                # jq builds the file list: a path holding a quote or backslash
                # made printf's hand-built array invalid JSON. The suite list
                # comes in on stdin, never argv, where a large payload hits
                # E2BIG (test-commit-refs pins the rule).
                printf '%s' "$_suites_json" | jq -c '{seeds: [], impacted: [], unblocked: [],
                    affected_suites: ., summary: {total_impacted: 0, total_unblocked: 0},
                    source: "files", graph_seed_matched: false, files: $ARGS.positional}' \
                    --args "${file_seeds[@]}" || return 1
            else
                # Distinguish "nothing records these files" from "only COMPLETED
                # work records them". The second is common and the old message
                # called it the first, then recommended an attribution command
                # that was already satisfied -- so following the advice changed
                # nothing and the operator had no way to tell why.
                local _done_nodes _done_count
                _done_nodes=$(_impact_nodes_for_files true "${file_seeds[@]}")
                # grep -c PRINTS 0 and EXITS 1 when nothing matches, so a
                # '|| echo 0' fallback appends a second zero and the arithmetic
                # test below then fails on "0\n0".
                _done_count=$(printf '%s\n' "$_done_nodes" | grep -c '[^[:space:]]' 2>/dev/null || true)
                _done_count=${_done_count:-0}
                if [ "${_done_count:-0}" -gt 0 ]; then
                    echo -e "${YELLOW}⚠ These files are recorded only on COMPLETED nodes — no open work is impacted.${NC}" >&2
                    echo "  files: ${file_seeds[*]}" >&2
                    echo "  ${_done_count} done node(s) record them; re-run with --include-done to list them." >&2
                else
                    echo -e "${YELLOW}⚠ No graph node records these files in touched_files — graph blast radius unknown, NOT 'safe'.${NC}" >&2
                    echo "  files: ${file_seeds[*]}" >&2
                fi
                local _suite_names
                _suite_names=$(printf '%s' "$_suites_json" | jq -r '.[].name' 2>/dev/null | paste -sd' ' - 2>/dev/null || echo "")
                if [ -n "$_suite_names" ]; then
                    echo "  affected test suites (via test-map.conf): $_suite_names"
                elif [ "${_done_count:-0}" -eq 0 ]; then
                    # Correct syntax: touch takes the node id and --files=, not a bare path.
                    echo "  no suites mapped either — attribute with 'wv touch <node-id> --files=${file_seeds[*]}', and run 'wv index .' if code search is also empty."
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
    [ "$full" = "true" ] && edge_set="${edge_set},relates_to,obsoletes,references,resolves,supersedes"
    local sorted_seeds
    sorted_seeds=$(printf '%s\n' "${resolved_seeds[@]}" | sort -u | tr '\n' ',' | sed 's/,$//')
    local quality_key="0"
    [ "$include_quality" = "true" ] && quality_key="1"

    local cache_dir="$WV_HOT_ZONE/context_cache"
    mkdir -p "$cache_dir"
    local cache_key
    cache_key=$(printf '%s' "${sorted_seeds}|${depth}|${direction}|${edge_set}|${include_done}|${node_cap}|${quality_key}" | sha256sum | cut -c1-16)
    # -v2: the certifying sequence moved INSIDE the file, so a v1 entry and its
    # sidecar must not be picked up by the new reader.
    local cache_file="$cache_dir/impact-${cache_key}-v2.json"

    local walk_json=""
    if [ -f "$cache_file" ]; then
        # Validate against the MUTATION COUNTER, not a timestamp and not the
        # database file's mtime. Timestamps cannot see a DELETE -- unlinking the
        # newest edge moved MAX(updated_at) BACKWARDS, so a cache written before
        # the deletion looked newer and was served with the deleted edge still
        # in it. The file mtime measures access, since SQLite journals on reads.
        # The certifying counter is the cache file's FIRST LINE, not a sidecar.
        # Two files cannot be published together, so a reader could pair one
        # publisher's walk with another's sequence; one file and one rename
        # cannot be torn.
        local cache_seq now_seq
        cache_seq=$(head -n 1 "$cache_file" 2>/dev/null || echo "")
        now_seq=$(wv_mutation_seq "$WV_DB" 2>/dev/null || echo "")
        case "${cache_seq}${now_seq}" in
            ''|*[!0-9]*) cache_seq=-1; now_seq=-2 ;;
        esac
        if [ "${cache_seq:--1}" = "${now_seq:--2}" ]; then
            walk_json=$(tail -n +2 "$cache_file")
        fi
    fi

    # Run CTE walk on cache miss. The sequence is read BEFORE the walk starts:
    # it is the graph the walk is about to observe, and publication below is
    # conditional on it still being that graph afterwards.
    local seq_before="" cache_filled=false
    if [ -z "$walk_json" ]; then
        cache_filled=true
        seq_before=$(wv_mutation_seq "$WV_DB" 2>/dev/null || echo "")
        # Move the graph DURING the walk: the window the publication check
        # below exists to close, which a test cannot otherwise hit
        # deterministically. Validation of the hook happened at the top of this
        # function; only the fault itself belongs here.
        if [ "$_impact_race" = true ]; then
            sqlite3 -cmd ".timeout 5000" "$WV_DB" \
                "UPDATE nodes SET updated_at = updated_at WHERE id IN (SELECT id FROM nodes LIMIT 1);" \
                >/dev/null 2>&1 || true
        fi
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

        # $quality_rows accumulates one entry per impacted node, so it grows with
        # the blast radius and is the argv-limit risk here; the per-node $q above
        # is one node's quality and stays small.
        local _q_file
        _q_file=$(mktemp "${TMPDIR:-/tmp}/wv-qual.XXXXXX") || return 1
        printf '%s' "$quality_rows" > "$_q_file"
        walk_json=$(printf '%s' "$walk_json" | jq -c --slurpfile _quality "$_q_file" '
            $_quality[0] as $quality |
            .impacted |= map(
                . as $node
                | (first($quality[]? | select(.node_id == $node.node_id))) as $q
                | if $q
                  then . + {code_quality: ($q.code_quality // []), quality_as_of: ($q.quality_as_of // null)}
                  else . + {code_quality: [], quality_as_of: null}
                  end
            )
        ')
        rm -f "$_q_file"
    fi

    # Persist cache after quality fold-in to keep parity by quality_key.
    #
    # Publication is conditional on the graph not having moved during
    # generation. Recording the sequence AFTER generating the walk certified
    # OLD content with the NEW counter: a mutation landing between the walk and
    # the record was invisible to every later reader, permanently, because the
    # cache then looked current forever. Re-read and compare; a mismatch means
    # this walk is already stale, so publish nothing and let the next call
    # rebuild. The write is a temp file plus a rename, so a reader sees either
    # the whole previous entry or the whole new one.
    if [ -n "$walk_json" ] && [ "$cache_filled" = true ]; then
        local seq_after
        seq_after=$(wv_mutation_seq "$WV_DB" 2>/dev/null || echo "")
        case "${seq_before}${seq_after}" in
            ''|*[!0-9]*) seq_before=-1; seq_after=-2 ;;
        esac
        if [ "$seq_before" = "$seq_after" ]; then
            local _cache_tmp="${cache_file}.tmp.$$"
            if { printf '%s\n' "$seq_after"; printf '%s' "$walk_json"; } > "$_cache_tmp" 2>/dev/null; then
                mv -f "$_cache_tmp" "$cache_file" 2>/dev/null || rm -f "$_cache_tmp" 2>/dev/null || true
            else
                rm -f "$_cache_tmp" 2>/dev/null || true
            fi
        fi
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
    if [ "${#_files[@]}" -gt 0 ]; then
        suites_json=$(_impact_suites_for_files "${_files[@]}") || return 1
    fi

    # Summary
    local n_imp n_unbl n_suit total_s
    n_imp=$(printf '%s' "$walk_json" | jq '.impacted|length')
    n_unbl=$(printf '%s' "$unblocked_json" | jq 'length')
    n_suit=$(printf '%s' "$suites_json" | jq 'length')
    total_s=$(printf '%s' "$suites_json" | jq '[.[].last_cost_s]|add//0')
    local summary="${n_imp} impacted, ${n_unbl} unblocked, ${n_suit} suites (~${total_s}s)"

    if [ "$output_format" = "json" ]; then
        # Payloads through files, not argv: an --argjson string over
        # MAX_ARG_STRLEN fails execve with E2BIG before jq starts, surfacing as
        # empty stdout with exit 0. These three grow with the graph.
        local _imp_dir
        _imp_dir=$(mktemp -d "${TMPDIR:-/tmp}/wv-imp.XXXXXX") || return 1
        printf '%s' "$seeds_json"     > "$_imp_dir/seeds.json"
        printf '%s' "$unblocked_json" > "$_imp_dir/unblocked.json"
        printf '%s' "$suites_json"    > "$_imp_dir/suites.json"
        printf '%s' "$walk_json" | jq \
            --slurpfile _seeds    "$_imp_dir/seeds.json" \
            --slurpfile _unblocked "$_imp_dir/unblocked.json" \
            --slurpfile _suites   "$_imp_dir/suites.json" \
                        --arg     include_quality "$include_quality" \
            --arg     summary  "$summary" \
            '$_seeds[0] as $seeds | $_unblocked[0] as $unblocked | $_suites[0] as $suites |
             {seeds:$seeds,
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
        _imp_rc=$?
        rm -rf "$_imp_dir"
        return "$_imp_rc"
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
# cmd_discover — compose query + impact signals into blindspot buckets
# ═══════════════════════════════════════════════════════════════════════════

cmd_discover() {
    local id="${1:-}"
    shift || true
    local output_format="json"
    local depth=2
    local limit=10

    if [ "$id" = "--help" ] || [ "$id" = "-h" ]; then
        echo "Usage: wv discover <id> --json [--depth=N] [--limit=N]"
        echo ""
        echo "Compose graph memory and impact output into the unknown-taxonomy"
        echo "report buckets: known_knowns, known_unknowns, unknown_knowns,"
        echo "and unknown_unknown_candidates."
        return 0
    fi
    if [ -z "$id" ]; then
        echo -e "${RED}Error: node ID required${NC}" >&2
        echo "Usage: wv discover <id> --json [--depth=N] [--limit=N]" >&2
        return 1
    fi

    while [ $# -gt 0 ]; do
        case "$1" in
            --json)      output_format="json" ;;
            --depth=*)   depth="${1#*=}" ;;
            --limit=*)   limit="${1#*=}" ;;
            --help|-h)
                echo "Usage: wv discover <id> --json [--depth=N] [--limit=N]"
                echo ""
                echo "Compose graph memory and impact output into the unknown-taxonomy"
                echo "report buckets: known_knowns, known_unknowns, unknown_knowns,"
                echo "and unknown_unknown_candidates."
                return 0
                ;;
            -*)
                echo -e "${RED}Error: unknown flag '$1'${NC}" >&2
                return 1 ;;
            *)
                echo -e "${RED}Error: unexpected argument '$1'${NC}" >&2
                return 1 ;;
        esac
        shift
    done

    if [ "$output_format" != "json" ]; then
        echo "Error: wv discover only supports --json output" >&2
        return 1
    fi
    if ! [[ "$depth" =~ ^[1-9][0-9]*$ ]]; then
        echo -e "${RED}Error: --depth must be a positive integer, got '$depth'${NC}" >&2
        return 1
    fi
    if ! [[ "$limit" =~ ^[1-9][0-9]*$ ]]; then
        echo -e "${RED}Error: --limit must be a positive integer, got '$limit'${NC}" >&2
        return 1
    fi

    db_ensure

    local sid
    sid=$(resolve_id "$id") || return 1

    local seed_json
    seed_json=$(db_query_json_v2 "SELECT id, text, status, metadata FROM nodes WHERE id='$(sql_escape "$sid")';")
    seed_json=$(printf '%s' "${seed_json:-[]}" | jq -c '.[0] // null')
    if [ "$seed_json" = "null" ]; then
        echo -e "${RED}Error: node $sid not found${NC}" >&2
        return 1
    fi

    local blockers_json findings_json learnings_json impact_json impact_direction impact_error
    blockers_json=$(db_query_json_v2 "
        SELECT b.id, b.text, b.status, b.metadata
        FROM edges e
        JOIN nodes b ON b.id = e.source
        WHERE e.target='$(sql_escape "$sid")'
          AND e.type='blocks'
          AND b.status != 'done'
        ORDER BY b.updated_at DESC
        LIMIT $limit;
    ")
    blockers_json="${blockers_json:-[]}"

    findings_json=$(db_query_json_v2 "
        SELECT DISTINCT f.id, f.text, f.status, f.metadata
        FROM nodes f
        JOIN edges e ON (e.source=f.id AND e.target='$(sql_escape "$sid")')
                    OR (e.target=f.id AND e.source='$(sql_escape "$sid")')
        WHERE f.status != 'done'
          AND (f.type='finding' OR json_extract(f.metadata, '\$.type')='finding')
        ORDER BY f.updated_at DESC
        LIMIT $limit;
    ")
    findings_json="${findings_json:-[]}"

    learnings_json=$(db_query_json_v2 "
        SELECT DISTINCT l.id, l.text, l.status, l.metadata
        FROM nodes l
        JOIN edges e ON (e.source=l.id AND e.target='$(sql_escape "$sid")')
                    OR (e.target=l.id AND e.source='$(sql_escape "$sid")')
        WHERE l.status='done'
          AND (json_extract(l.metadata, '\$.learning') IS NOT NULL
               OR json_extract(l.metadata, '\$.decision') IS NOT NULL
               OR json_extract(l.metadata, '\$.pattern') IS NOT NULL
               OR json_extract(l.metadata, '\$.pitfall') IS NOT NULL)
        ORDER BY l.updated_at DESC
        LIMIT $limit;
    ")
    learnings_json="${learnings_json:-[]}"

    impact_direction="both"
    if [ "$(printf '%s' "$seed_json" | jq -r '.status')" = "done" ]; then
        # Forward impact for completed work has already been discharged. A reverse
        # walk still gives discovery a useful retrospective view of dependencies
        # instead of silently degrading to an empty "impact unavailable" result.
        impact_direction="rev"
    fi
    if ! impact_json=$(cmd_impact "$sid" --json "--depth=$depth" "--direction=$impact_direction" 2>&1); then
        impact_error="$impact_json"
        impact_json=$(jq -n -c --arg error "$impact_error" \
            '{impacted:[], unblocked:[], affected_suites:[], summary:"impact unavailable", available:false, error:$error}')
    fi

    # Payloads reach jq through FILES, not argv. A single --argjson string over
    # MAX_ARG_STRLEN (131072 on Linux) makes execve fail with E2BIG before jq
    # starts, which surfaces as empty stdout with exit 0 — the same failure
    # cmd_context was fixed for in f3375783, measured in a consumer at 540
    # nodes. $impact alone embeds a full impact report and grows with the graph.
    local _disc_dir
    _disc_dir=$(mktemp -d "${TMPDIR:-/tmp}/wv-disc.XXXXXX") || return 1
    printf '%s' "$seed_json"      > "$_disc_dir/seed.json"
    printf '%s' "$blockers_json"  > "$_disc_dir/blockers.json"
    printf '%s' "$findings_json"  > "$_disc_dir/findings.json"
    printf '%s' "$learnings_json" > "$_disc_dir/learnings.json"
    printf '%s' "$impact_json"    > "$_disc_dir/impact.json"

    # The bounded coaching projection for exactly the findings this report
    # already carries -- the same renderer behind `wv findings list --detail`
    # and the ready digest, so the three surfaces cannot drift into three
    # dialects of one projection.
    #
    # Additive and optional: `coaching` appears only when a finding here holds
    # promoted occurrences, so every existing field keeps its meaning and a
    # consumer that does not know the key is unaffected. --embed keeps it silent
    # when there is nothing to coach; a renderer failure is never fatal to
    # discovery, which must keep working when coaching cannot be resolved.
    local _disc_coaching="null" _disc_finding_ids
    _disc_finding_ids=$(printf '%s' "$findings_json" | jq -r 'map(.id) | join(",")' 2>/dev/null || true)
    if [ -n "$_disc_finding_ids" ]; then
        _disc_coaching=$(_wv_findings_python coaching --embed --json \
            --node-ids="$_disc_finding_ids" --limit=2 2>/dev/null || true)
        # jq refuses an empty --argjson, and "nothing to coach" is the ordinary case.
        [ -n "$_disc_coaching" ] || _disc_coaching="null"
        printf '%s' "$_disc_coaching" | jq -e . >/dev/null 2>&1 || _disc_coaching="null"
    fi

    jq -n -c \
        --argjson _coaching "$_disc_coaching" \
        --arg schema "weave.discovery.v1" \
        --arg generated_by "wv discover" \
        --arg impact_direction "$impact_direction" \
        --slurpfile _seed "$_disc_dir/seed.json" \
        --slurpfile _blockers "$_disc_dir/blockers.json" \
        --slurpfile _findings "$_disc_dir/findings.json" \
        --slurpfile _learnings "$_disc_dir/learnings.json" \
        --slurpfile _impact "$_disc_dir/impact.json" \
        --argjson limit "$limit" '
        $_seed[0] as $seed |
        $_blockers[0] as $blockers |
        $_findings[0] as $findings |
        $_learnings[0] as $learnings |
        $_impact[0] as $impact |
        def item($category; $state; $source; $meaning; $probe; $evidence):
          {
            category: $category,
            state: $state,
            source: $source,
            meaning: $meaning,
            probe: $probe
          }
          + (if $evidence == null then {} else {evidence: $evidence} end);

        def node_ref($n):
          {node_id: $n.id, text: $n.text, status: $n.status};

        # db_query_json_v2 currently decodes JSON columns, but normalize here so
        # discovery remains correct if a query adapter returns metadata as text.
        def node_metadata($n):
          ($n.metadata
           | if type == "object" then .
             elif type == "string" then (fromjson? // {})
             else {}
             end);

        # Older nodes may store one criterion or risk as a scalar. Normalize
        # these metadata values before map-based report composition.
        def metadata_values($value):
          if ($value | type) == "array" then $value
          elif $value == null then []
          else [$value]
          end;

        # Preserve source diversity under a single bucket limit. With blockers,
        # risks, and findings present, round-robin selection prevents a long first
        # source from starving every later source.
        def interleave($arrays):
          [range(0; (($arrays | map(length) | max) // 0)) as $i
           | $arrays[]
           | .[$i] // empty];

        # learning_fields — surface explicit decision/pattern/pitfall keys, else
        # parse the canonical combined "decision: ... | pattern: ... | pitfall: ..."
        # learning string (wv done --learning=...). Falls back to raw text so the
        # tacit knowledge is never dropped from evidence.
        def learning_fields($meta):
          ($meta.learning // null) as $ls |
          (if ($ls | type) == "string" and ($ls | length) > 0 then
            ($ls | split(" | ") | reduce .[] as $part (
              {};
              if ($part | startswith("decision: ")) then .decision = ($part | ltrimstr("decision: "))
              elif ($part | startswith("pattern: ")) then .pattern = ($part | ltrimstr("pattern: "))
              elif ($part | startswith("pitfall: ")) then .pitfall = ($part | ltrimstr("pitfall: "))
              else .raw = ((.raw // "") + $part)
              end
            ))
          else {} end) as $parsed |
          {
            decision: ($meta.decision // $parsed.decision // null),
            pattern:  ($meta.pattern  // $parsed.pattern  // null),
            pitfall:  ($meta.pitfall  // $parsed.pitfall  // null)
          } as $fields |
          $fields
          + (if ($fields.decision == null and $fields.pattern == null and $fields.pitfall == null)
             then {raw: ($parsed.raw // $ls)} else {} end);

        metadata_values(node_metadata($seed).done_criteria) as $criteria |
        metadata_values(node_metadata($seed).risks) as $risks |
        {
          schema: $schema,
          generated_by: $generated_by,
          seed: node_ref($seed),
          known_knowns: (
            [item(
              "known_known";
              "observed";
              "active_node";
              ("Seed node: " + $seed.text);
              "Read the active node text, status, metadata, and context pack before implementation.";
              node_ref($seed)
            )]
            + ($criteria | map(. as $criterion | item(
                "known_known";
                "observed";
                "done_criteria";
                ("Done criterion: " + ($criterion | tostring));
                "Verify closure evidence against this criterion.";
                null
              )))
          )[0:$limit],
          known_unknowns: (
            interleave([
              ($blockers | map(. as $blocker | item(
                "known_unknown";
                "candidate";
                "blocks_edge";
                ("Open blocker: " + $blocker.text);
                "Resolve or explicitly defer the blocking node before closing the seed.";
                node_ref($blocker)
              ))),
              ($risks | map(. as $risk | item(
                  "known_unknown";
                  "candidate";
                  "risk_metadata";
                  ("Recorded risk: " + ($risk | tostring));
                  "Bound or mitigate this risk during implementation.";
                  null
                ))),
              ($findings | map(. as $finding | item(
                  "known_unknown";
                  "promoted_to_finding";
                  "query";
                  ("Related open finding: " + $finding.text);
                  "Inspect the finding metadata and either address, resolve, or defer it.";
                  node_ref($finding)
                )))
            ])
          )[0:$limit],
          unknown_knowns: (
            $learnings | map(. as $learning | item(
              "unknown_known";
              "observed";
              "query";
              ("Related learning: " + $learning.text);
              "Apply this prior decision, pattern, or pitfall if it fits the current work.";
              ({node_id: $learning.id} + learning_fields(node_metadata($learning)))
            ))
          )[0:$limit],
          unknown_unknown_candidates: (
            (($impact.impacted // []) | map(select(.node_id != $seed.id)) | map(. as $candidate | item(
              "unknown_unknown_candidate";
              "candidate";
              "impact";
              ("Impact candidate: " + ($candidate.label // $candidate.node_id) + " at depth " + ($candidate.min_depth | tostring) + " with risk " + ($candidate.risk_score | tostring));
              "Review why the impact walk reached this node; probe touched files, blockers, criteria, and affected suites before treating it as a finding.";
              {
                node_id: $candidate.node_id,
                status: $candidate.status,
                risk_score: $candidate.risk_score,
                risk_factors: $candidate.risk_factors,
                missing_criteria: $candidate.missing_criteria
              }
            )))
            + (($impact.affected_suites // []) | map(. as $suite | item(
                "unknown_unknown_candidate";
                "candidate";
                "impact";
                ("Affected suite candidate: " + $suite.name);
                "Run or consciously defer this suite if implementation touches the mapped surface.";
                $suite
              )))
          )[0:$limit],
          sources: {
            query: {
              blockers: ($blockers | length),
              related_findings: ($findings | length),
              related_learnings: ($learnings | length)
            },
            impact: {
              direction: $impact_direction,
              available: ($impact.available // true),
              error: ($impact.error // null),
              summary: ($impact.summary // null),
              impacted: (($impact.impacted // []) | length),
              affected_suites: (($impact.affected_suites // []) | length)
            }
          }
        }
        + (if $_coaching == null then {} else {coaching: $_coaching} end)
    '
    _disc_rc=$?
    rm -rf "$_disc_dir"
    return "$_disc_rc"
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
        etypes="${etypes},'relates_to','resolves','references','supersedes','obsoletes'"
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
