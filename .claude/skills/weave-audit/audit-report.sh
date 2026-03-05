#!/bin/bash
# Weave Graph Audit Report
# Generates a comprehensive report of graph health and issues

set -euo pipefail

echo "=== Weave Graph Audit Report ==="
echo ""
echo "Generated: $(date)"
echo ""

echo "## Summary"
total=$(wv list --all --json 2>/dev/null | jq 'length' || echo "0")
active=$(wv list --status=active --json 2>/dev/null | jq 'length' || echo "0")
blocked=$(wv list --status=blocked --json 2>/dev/null | jq 'length' || echo "0")
todo=$(wv list --status=todo --json 2>/dev/null | jq 'length' || echo "0")
done=$(wv list --all --status=done --json 2>/dev/null | jq 'length' || echo "0")

echo "Total nodes: $total"
echo "Active: $active"
echo "Blocked: $blocked"
echo "Todo: $todo"
echo "Done: $done"
echo ""

echo "## Issues Found"
echo ""

echo "### Orphaned Nodes (todo >7 days)"
CUTOFF_DATE=$(date -d '7 days ago' '+%Y-%m-%d' 2>/dev/null || date -v-7d '+%Y-%m-%d' 2>/dev/null || echo "2020-01-01")
orphaned=$(wv list --json 2>/dev/null | jq -r --arg date "$CUTOFF_DATE" \
  '.[] | select(.status=="todo" and .created_at < $date) | "- \(.id): \(.text)"' | head -10)

if [ -n "$orphaned" ]; then
  echo "$orphaned"
else
  echo "None found ✓"
fi
echo ""

echo "### Stuck Active Nodes (>2 days)"
STUCK_DATE=$(date -d '2 days ago' '+%Y-%m-%d' 2>/dev/null || date -v-2d '+%Y-%m-%d' 2>/dev/null || echo "2020-01-01")
stuck=$(wv list --json 2>/dev/null | jq -r --arg date "$STUCK_DATE" \
  '.[] | select(.status=="active" and .updated_at < $date) | "- \(.id): \(.text)"' | head -10)

if [ -n "$stuck" ]; then
  echo "$stuck"
else
  echo "None found ✓"
fi
echo ""

echo "### Nodes Missing Type"
no_type=$(wv list --json 2>/dev/null | jq -r '.[] | select(.type == null) | "- \(.id): \(.text)"' | head -10)

if [ -n "$no_type" ]; then
  echo "$no_type"
else
  echo "All nodes have type ✓"
fi
echo ""

echo "### Nodes Missing Priority"
no_priority=$(wv list --json 2>/dev/null | jq -r '.[] | select(.priority == null) | "- \(.id): \(.text)"' | head -10)

if [ -n "$no_priority" ]; then
  echo "$no_priority"
else
  echo "All nodes have priority ✓"
fi
echo ""

echo "### Done Nodes Without Learnings"
no_learnings=$(wv list --all --json 2>/dev/null | jq -r '.[] | select(.status=="done") |
  select(
    (.metadata | fromjson | has("decision")) == false and
    (.metadata | fromjson | has("pattern")) == false and
    (.metadata | fromjson | has("pitfall")) == false
  ) | "- \(.id): \(.text)"' | head -10)

if [ -n "$no_learnings" ]; then
  echo "$no_learnings"
else
  echo "All completed nodes have learnings ✓"
fi
echo ""

echo "## Health Score"
echo ""

# Calculate health score (100 = perfect)
score=100

# Deduct for orphaned nodes
orphaned_count=$(wv list --json 2>/dev/null | jq --arg date "$CUTOFF_DATE" \
  '[.[] | select(.status=="todo" and .created_at < $date)] | length' || echo "0")
score=$((score - orphaned_count * 5))

# Deduct for stuck active nodes
stuck_count=$(wv list --json 2>/dev/null | jq --arg date "$STUCK_DATE" \
  '[.[] | select(.status=="active" and .updated_at < $date)] | length' || echo "0")
score=$((score - stuck_count * 10))

# Deduct for missing metadata
no_type_count=$(wv list --json 2>/dev/null | jq '[.[] | select(.type == null)] | length' || echo "0")
score=$((score - no_type_count * 2))

no_priority_count=$(wv list --json 2>/dev/null | jq '[.[] | select(.priority == null)] | length' || echo "0")
score=$((score - no_priority_count * 2))

# Deduct for missing learnings
no_learnings_count=$(wv list --all --json 2>/dev/null | jq '[.[] | select(.status=="done") |
  select(
    (.metadata | fromjson | has("decision")) == false and
    (.metadata | fromjson | has("pattern")) == false and
    (.metadata | fromjson | has("pitfall")) == false
  )] | length' || echo "0")
score=$((score - no_learnings_count * 3))

# Ensure score doesn't go below 0
[ "$score" -lt 0 ] && score=0

echo "Overall Health: $score/100"
echo ""

if [ "$score" -ge 90 ]; then
  echo "Status: ✅ Excellent - Graph is in great shape"
elif [ "$score" -ge 70 ]; then
  echo "Status: ✓ Good - Minor issues to address"
elif [ "$score" -ge 50 ]; then
  echo "Status: ⚠️  Fair - Some housekeeping needed"
else
  echo "Status: 🔴 Needs Attention - Significant issues found"
fi
echo ""

echo "## Recommendations"
echo ""

if [ "$orphaned_count" -gt 0 ]; then
  echo "1. Review $orphaned_count orphaned nodes and either complete or archive them"
fi

if [ "$stuck_count" -gt 0 ]; then
  echo "2. Update $stuck_count stuck active nodes or complete them"
fi

if [ "$no_type_count" -gt 0 ]; then
  echo "3. Add type metadata to $no_type_count nodes for better organization"
fi

if [ "$no_priority_count" -gt 0 ]; then
  echo "4. Add priority metadata to $no_priority_count nodes"
fi

if [ "$no_learnings_count" -gt 0 ]; then
  echo "5. Capture learnings for $no_learnings_count completed nodes (if non-trivial)"
fi

# Check if pruning is recommended
pruneable=$(wv list --all --json 2>/dev/null | jq --arg date "$(date -d '7 days ago' '+%Y-%m-%d' 2>/dev/null || date -v-7d '+%Y-%m-%d' 2>/dev/null || echo "2020-01-01")" \
  '[.[] | select(.status=="done" and .updated_at < $date)] | length' || echo "0")

if [ "$pruneable" -gt 0 ]; then
  echo "6. Run 'wv prune --age=168' to archive $pruneable old completed nodes"
fi

if [ "$score" -ge 90 ]; then
  echo ""
  echo "Graph is healthy! Keep up the good work."
fi

echo ""
echo "---"
echo "Next audit: $(date -d '+7 days' '+%Y-%m-%d' 2>/dev/null || date -v+7d '+%Y-%m-%d' 2>/dev/null || echo 'Next week')"
