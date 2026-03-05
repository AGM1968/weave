---
name: weave-audit
description: "Validates Weave graph integrity, identifies issues, and suggests fixes. Use when auditing graph health, dependencies, or workflow correctness."
---

# Weave Graph Audit

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator. Use `/weave` instead
> for the full graph-first workflow. Direct invocation is deprecated and may be removed in a future
> release.

Audit the Weave graph for integrity issues, stale work, and structural problems.

## Audit Categories

### 1. Orphaned Nodes

Find nodes that are `todo` but never claimed:

```bash
# Check for old unclaimed work

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.

wv list --json | jq -r '.[] | select(.status=="todo") | "\(.id): \(.text) (created: \(.created_at))"'

# Find nodes older than 7 days still in todo

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.

wv list --json | jq -r --arg date "$(date -d '7 days ago' '+%Y-%m-%d' 2>/dev/null || date -v-7d '+%Y-%m-%d')" \
  '.[] | select(.status=="todo" and .created_at < $date) | "\(.id): \(.text)"'
```

**Action:** Either claim and complete, or delete if no longer relevant.

### 2. Stuck Active Nodes

Find nodes stuck in `active` status:

```bash
# List all active nodes

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.

wv list --status=active

# Check which have been active for >2 days

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.

wv list --json | jq -r --arg date "$(date -d '2 days ago' '+%Y-%m-%d' 2>/dev/null || date -v-2d '+%Y-%m-%d')" \
  '.[] | select(.status=="active" and .updated_at < $date) | "\(.id): \(.text) (active since: \(.updated_at))"'
```

**Action:** Complete if done, update status if still in progress, or unblock if stuck.

### 3. Circular Dependencies

Find potential circular dependencies:

```bash
# For each blocked node, check if its blocker is also blocked by it

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.

for node in $(wv list --status=blocked --json | jq -r '.[].id'); do
  wv show $node --json | jq -r '
    .[] |
    .blockers // [] |
    .[] |
    "\(.id) potentially blocks parent"
  ' 2>/dev/null
done
```

**Action:** Break the cycle by identifying true dependency order.

### 4. Nodes Without Metadata

Find nodes missing useful metadata:

```bash
# Find nodes with empty metadata

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.

wv list --json | jq -r '.[] | select(.metadata == "{}") | "\(.id): \(.text)"'

# Find nodes missing 'type' field

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.

wv list --json | jq -r '.[] | select(.type == null) | "\(.id): \(.text) (no type)"'

# Find nodes missing 'priority' field

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.

wv list --json | jq -r '.[] | select(.priority == null) | "\(.id): \(.text) (no priority)"'
```

**Action:** Add metadata for better organization and filtering.

### 5. Blocked Nodes with Completed Blockers

Find nodes that should be unblocked:

```bash
# Check if any blocked nodes have all blockers completed

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.

wv list --status=blocked | while read -r line; do
  id=$(echo "$line" | awk '{print $1}' | tr -d '[]')
  if wv show "$id" 2>/dev/null | grep -q "Blocked by:"; then
    echo "Check $id - may have completed blockers"
  fi
done
```

**Action:** Update status to `todo` if blockers are done.

### 6. Nodes Without Learnings

Find completed nodes missing learnings:

```bash
# List done nodes without learnings

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.

wv list --all --json | jq -r '.[] | select(.status=="done") |
  select(.metadata | fromjson |
    has("decision") == false and
    has("pattern") == false and
    has("pitfall") == false
  ) | "\(.id): \(.text)"'
```

**Action:** Retrospectively add learnings if the work was non-trivial.

### 7. Duplicate or Similar Nodes

Find potentially duplicate work:

```bash
# Find nodes with very similar text

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.

wv list --json | jq -r '.[].text' | sort | uniq -d

# Find nodes with same type and similar priority

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.

wv list --json | jq -r 'group_by(.type, .priority) | .[] |
  select(length > 3) |
  "Multiple \(.[0].type) nodes at priority \(.[0].priority): \(length) found"'
```

**Action:** Consolidate if truly duplicate, or add distinguishing metadata.

## Full Audit Report

Run a comprehensive audit:

```bash
#!/bin/bash
echo "=== Weave Graph Audit Report ==="
echo ""
echo "Generated: $(date)"
echo ""

echo "## Summary"
echo "Total nodes: $(wv list --all --json | jq 'length')"
echo "Active: $(wv list --status=active --json | jq 'length')"
echo "Blocked: $(wv list --status=blocked --json | jq 'length')"
echo "Todo: $(wv list --status=todo --json | jq 'length')"
echo "Done: $(wv list --all --status=done --json | jq 'length')"
echo ""

echo "## Issues Found"
echo ""

echo "### Orphaned Nodes (todo >7 days)"
wv list --json | jq -r --arg date "$(date -d '7 days ago' '+%Y-%m-%d' 2>/dev/null || date -v-7d '+%Y-%m-%d')" \
  '.[] | select(.status=="todo" and .created_at < $date) | "- \(.id): \(.text)"' | head -10
echo ""

echo "### Stuck Active Nodes (>2 days)"
wv list --json | jq -r --arg date "$(date -d '2 days ago' '+%Y-%m-%d' 2>/dev/null || date -v-2d '+%Y-%m-%d')" \
  '.[] | select(.status=="active" and .updated_at < $date) | "- \(.id): \(.text)"' | head -10
echo ""

echo "### Nodes Missing Type"
wv list --json | jq -r '.[] | select(.type == null) | "- \(.id): \(.text)"' | head -10
echo ""

echo "### Nodes Missing Priority"
wv list --json | jq -r '.[] | select(.priority == null) | "- \(.id): \(.text)"' | head -10
echo ""

echo "### Done Nodes Without Learnings"
wv list --all --json | jq -r '.[] | select(.status=="done") |
  select(.metadata | fromjson |
    has("decision") == false and
    has("pattern") == false and
    has("pitfall") == false
  ) | "- \(.id): \(.text)"' | head -10
echo ""

echo "## Recommendations"
echo ""
echo "1. Review orphaned nodes and either complete or archive them"
echo "2. Update stuck active nodes or complete them"
echo "3. Add metadata (type, priority) to nodes for better organization"
echo "4. Capture learnings for completed nodes"
echo "5. Run 'wv prune' to archive old completed nodes"
echo ""
```

Save this as `.claude/skills/weave-audit/audit-report.sh` and run:

```bash
bash .claude/skills/weave-audit/audit-report.sh
```

## Automated Fixes

### Auto-Archive Old Completed Nodes

```bash
# Preview what would be archived

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.

wv prune --age=168 --dry-run  # 7 days

# Archive nodes completed >7 days ago

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.

wv prune --age=168
```

### Auto-Add Missing Metadata

```bash
# Add default type to nodes without one

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.

for id in $(wv list --json | jq -r '.[] | select(.type == null) | .id'); do
  wv update $id --metadata='{"type":"task","priority":3}'
  echo "Added default metadata to $id"
done
```

### Auto-Unblock Nodes

For nodes blocked by completed work, manually verify then unblock:

```bash
# This requires manual verification - don't automate blindly

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.

wv update wv-XXXXXX --status=todo  # If blockers are confirmed done
```

## Validation Checks

After making fixes, verify:

```bash
# Check no circular dependencies (manual inspection)

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.

wv list --status=blocked

# Verify ready queue has work

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.

wv ready

# Ensure graph is consistent

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.

wv status

# Verify sync is clean

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.

wv sync
git status
```

## Best Practices for Graph Hygiene

### Daily

- Review `wv ready` queue
- Claim and start work on high-priority items
- Complete active nodes or update status
- Capture learnings when closing nodes

### Weekly

- Run weave-audit to identify issues
- Review orphaned nodes (todo >7 days)
- Check for stuck active nodes
- Add missing metadata
- Prune old completed nodes

### Monthly

- Full graph audit with report
- Review and consolidate duplicate nodes
- Archive completed work >30 days
- Update documentation if patterns emerge

## Common Issues and Solutions

### Issue: Too Many Orphaned Nodes

**Symptom:** Dozens of `todo` nodes that never get claimed

**Solution:**

1. Review and delete no-longer-relevant nodes
2. Consolidate similar nodes
3. Add priority to help triage
4. Block low-priority work by higher priority

### Issue: Circular Dependencies

**Symptom:** Two nodes each blocking the other

**Solution:**

1. Identify which is the true dependency
2. Remove one of the blocking edges
3. May need to break one node into two sequential nodes

### Issue: Missing Learnings

**Symptom:** Many completed nodes without decision/pattern/pitfall

**Solution:**

1. Review git commits for those nodes
2. Retrospectively add learnings if significant
3. Make learnings capture mandatory in workflow
4. Use `wv done --learning="..."` to capture learnings

### Issue: No Priority Information

**Symptom:** Can't determine what to work on next

**Solution:**

1. Add priority metadata to all nodes
2. Use priority 1 for critical path
3. Use priority 5 for nice-to-haves
4. Filter ready queue by priority

## Integration with Other Tools

### With Git Hooks

```bash
# In pre-commit hook

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.

if wv list --status=active --json | jq -e 'length > 0' > /dev/null; then
  echo "Warning: You have active Weave nodes. Consider completing them."
fi
```

### With GitHub Actions

```yaml
# .github/workflows/weave-audit.yml

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.

name: Weave Audit

on:
  schedule:
    - cron: "0 9 * * MON" # Every Monday at 9am

jobs:
  audit:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Run Weave Audit
        run: |
          bash .claude/skills/weave-audit/audit-report.sh > audit-report.md
          # Optionally create issue if problems found
```

### With Close-Session Skill

The `/close-session` skill should run a quick audit:

```bash
# Check for active nodes

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.

if [ "$(wv list --status=active --json | jq 'length')" -gt 0 ]; then
  echo " Active nodes found - review before ending session"
  wv list --status=active
fi

# Check for uncommitted learnings

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.

wv learnings --json | jq -e 'length' > /dev/null || echo " No recent learnings captured"
```

## Output Format

When running `/weave-audit`, provide:

```markdown
# Weave Graph Audit Results

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator. Use `/weave` instead
> for the full graph-first workflow. Direct invocation is deprecated and may be removed in a future
> release.

## Summary

- Total Nodes: 45
- Active: 2
- Blocked: 3
- Todo: 15
- Done: 25

## Issues Found

### Critical (requires immediate attention)

- [CRITICAL] wv-XXXXXX: Circular dependency detected
- [CRITICAL] wv-YYYYYY: Stuck active for 5 days

### Warning (should address soon)

- [WARNING] 10 nodes missing priority metadata
- [WARNING] 3 orphaned nodes older than 7 days
- [WARNING] 5 completed nodes without learnings

### Info (minor housekeeping)

- [INFO] 15 nodes can be archived (completed >7 days ago)
- [INFO] 8 nodes missing type metadata

## Recommendations

1. **Immediate:** Fix circular dependency in wv-XXXXXX
2. **This week:** Review 3 orphaned nodes
3. **This week:** Add priority to 10 nodes
4. **Monthly:** Run `wv prune` to archive old nodes

## Next Steps

1. Run suggested fixes (shown above)
2. Verify with `wv status` and `wv ready`
3. Schedule next audit for [date]
```

## Quick Audit Commands

```bash
# Quick health check

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.

wv status && wv ready --count

# Find immediate issues

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.

wv list --status=active | head -5
wv list --status=blocked | head -5

# Count nodes by type

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.

wv list --json | jq -r '.[].type' | sort | uniq -c

# List high-priority work

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.

wv list --json | jq -r '.[] | select(.priority <= 2) | "\(.id): \(.text) (P\(.priority))"'
```

## Related Skills

- **/close-session** - Includes basic audit before session end
- **/wv-decompose-work** - Creates well-structured hierarchies to prevent issues

## Related Agents

- **weave-guide** - Workflow best practices to prevent issues
- **epic-planner** - Plan work structure before creating nodes
