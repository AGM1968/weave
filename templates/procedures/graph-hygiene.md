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
wv prune --dry-run               # preview: done nodes older than 30 days, and what each rule kept
wv prune                         # archive them, writing a deletion tombstone per node and edge
wv prune --orphans-only          # archive done nodes with no edges (ignores age)
wv unarchive <id> --dry-run      # preview restoring a pruned node
wv unarchive <id>                # restore a pruned node to the live graph
```

`wv prune` is an explicit command: it never runs from a hook or a session end, and it keeps
findings, memories, epics, plans, decisions, unresolved pitfalls, nodes a live node still references
and nodes whose GitHub issue is open. The full policy is `wv guide --procedure=prune-policy`.

**`--orphans-only` vs `--age=`:**

- `--age=Nd` uses `updated_at` — misses nodes touched today by `wv sync --gh`; the default is 30d
- `--orphans-only` targets unlinked done nodes regardless of age — use this after a sync that
  bulk-closed nodes, or after a graph repair session

**Before pruning, classify orphans first:**

1. Garbage/test fixtures → `wv delete <id>`
2. Work without a parent → `wv link <id> <epic> --type=implements`
3. Legitimate standalones (releases, chores) → create them with `--standalone`, or annotate retained
   history with `wv update <id> --metadata='{"standalone":true}'`; `wv health` reports these as
   `intentional_standalones`, not `orphan_nodes`
4. Archive intentional standalones only when you want them removed from the live graph →
   `wv prune --orphans-only`

**Stale test/smoke nodes** pollute `wv ready` and the ready-work signal. Audit periodically:

```bash
wv list --status=todo --json \
    | jq -r '.[] | select(.text | test("^(smoke|Bench|Test)"; "i")) | .id + ": " + .text'
```

Delete with `wv delete <id> --force`.
