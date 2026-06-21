---
id: graph-hygiene
description:
  "Keep the graph healthy — health checks, pruning stale done nodes, classifying orphans, and
  clearing test/smoke pollution. Use periodically or after a sync that bulk-closed nodes."
fallback: "wv guide --procedure=graph-hygiene"
adapters: [codex, copilot]
visibility: shared
---

# Graph Hygiene

Run `wv health` periodically to catch drift. Key maintenance commands:

```bash
wv health                        # score + orphan/ghost-edge counts
wv prune --age=7d --dry-run      # preview stale done nodes
wv prune --age=7d                # archive done nodes not updated in 7 days
wv prune --orphans-only          # archive done nodes with no edges (ignores age)
wv unarchive <id> --dry-run      # preview restoring a pruned node
wv unarchive <id>                # restore a pruned node to the live graph
```

**`--orphans-only` vs `--age=`:**

- `--age=Nd` uses `updated_at` — misses nodes touched today by `wv sync --gh`
- `--orphans-only` targets unlinked done nodes regardless of age — use this after a sync that
  bulk-closed nodes, or after a graph repair session

**Before pruning, classify orphans first:**

1. Garbage/test fixtures → `wv delete <id>`
2. Real work without a parent → `wv link <id> <epic> --type=implements`
3. Legitimate standalones (releases, chores) → create them with `--standalone`, or annotate retained
   history with `wv update <id> --metadata='{"standalone":true}'`; `wv health` reports these as
   `intentional_standalones`, not `orphan_nodes`
4. Archive intentional standalones only when you actually want them removed from the live graph →
   `wv prune --orphans-only`

**Stale test/smoke nodes** pollute `wv ready` and the ready-work signal. Audit periodically:

```bash
wv list --status=todo --json \
    | jq -r '.[] | select(.text | test("^(smoke|Bench|Test)"; "i")) | .id + ": " + .text'
```

Delete with `wv delete <id> --force`.
