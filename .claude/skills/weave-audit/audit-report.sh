#!/usr/bin/env bash
# Weave graph audit report: what wv health scores, plus the work-queue checks
# it does not (old unclaimed todo, stuck active, done without a learning).
# Read-only. Installed beside the graph-hygiene procedure; run it in the repo.
set -euo pipefail

STALE_TODO_DAYS="${WV_AUDIT_TODO_DAYS:-7}"
STUCK_ACTIVE_DAYS="${WV_AUDIT_ACTIVE_DAYS:-2}"
SHOW="${WV_AUDIT_SHOW:-10}"

command -v wv >/dev/null 2>&1 || { echo "audit-report: wv not found on PATH" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "audit-report: jq not found on PATH" >&2; exit 1; }

cutoff() { # days -> UTC date, GNU or BSD date
    date -u -d "$1 days ago" '+%Y-%m-%d' 2>/dev/null || date -u -v-"$1"d '+%Y-%m-%d'
}
TODO_CUTOFF=$(cutoff "$STALE_TODO_DAYS")
ACTIVE_CUTOFF=$(cutoff "$STUCK_ACTIVE_DAYS")

# One read of the graph; every section filters this snapshot.
nodes=$(wv list --all --json)
# wv health exits nonzero when its status is not healthy; the report is still
# complete, so judge the payload instead: no score means no report.
health=$(wv health --json 2>/dev/null) || true
jq -e '.score | numbers' <<< "$health" >/dev/null 2>&1 \
    || { echo "audit-report: wv health --json returned no score" >&2; exit 1; }

# section <title> <jq condition over one node>: the count, then the first $SHOW
# matches. jq truncates the list itself: piping into head would SIGPIPE jq and,
# under pipefail, abort the report on any graph with more matches than shown.
section() {
    local title="$1" condition="$2"
    jq -r --arg todo "$TODO_CUTOFF" --arg active "$ACTIVE_CUTOFF" --argjson show "$SHOW" --arg title "$title" "
        [.[] | select($condition)] as \$hits
        | \"### \(\$title): \(\$hits | length)\",
          (\$hits[:\$show][] | \"- \(.id): \(.text[:100])\")" <<< "$nodes"
    echo ""
}

# A learning is stored as metadata.learning or as decision/pattern/pitfall keys.
# A memory or session-history node is itself the record, so it is not counted.
# shellcheck disable=SC2016  # $k is a jq variable
LEARNED='(.metadata | (try fromjson catch {}) | (has("learning") or has("decision") or has("pattern") or has("pitfall")
    or ((.node_kind // .type) as $k | $k == "memory" or $k == "session_history")))'

echo "# Weave Graph Audit"
echo ""
echo "Generated: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo ""
echo "## Summary"
echo ""
jq -r 'group_by(.status)[] | "- \(.[0].status): \(length)"' <<< "$nodes"
echo "- total: $(jq 'length' <<< "$nodes")"
jq -r '"- wv health: \(.score)/100 (\(.status))"' <<< "$health"
echo ""
echo "## Findings"
echo ""
# shellcheck disable=SC2016  # $todo and $active are jq variables, not shell
section "Todo unclaimed for more than $STALE_TODO_DAYS days" '.status == "todo" and .created_at < $todo'
# shellcheck disable=SC2016  # jq variable
section "Active and untouched for more than $STUCK_ACTIVE_DAYS days" '.status == "active" and .updated_at < $active'
section "Done without a learning" ".status == \"done\" and ($LEARNED | not)"
echo "### wv health issues"
jq -r '(.issues // {}) | to_entries
    | map(select((.value | type) == "number" and .value > 0 and .key != "intentional_standalones"))
    | if length == 0 then "- none" else .[] | "- \(.key): \(.value)" end' <<< "$health"
jq -r '(.issues.orphan_ids // []) | select(length > 0) | "  orphans: \(join(" "))"' <<< "$health"
echo ""
echo "Next: wv guide --procedure=graph-hygiene (classify orphans before wv prune)."
