---
id: prune-policy
description:
  "When a prune may run, what it may remove, and how long deletion tombstones are kept. Read before
  running wv prune, before touching cmd_prune or the tombstone table, and when a reload resurrects a
  node."
fallback: "wv guide --procedure=prune-policy"
adapters: [codex, copilot]
visibility: shared
---

# Prune Policy

A deletion is a durable fact. Every clone and consumer that may still replay the graph's history has
to learn of it, or the deleted rows come back. The graph records a deletion as a row in the
`tombstones` table (kind, id, lineage seq and actor), written in the same transaction as the DELETE,
shipped in `state.sql`, and re-enforced by `wv load` after every replay. The policy below decides
when such a fact may be created and how long it must be kept.

## Timing

- Only as an explicit command: a person or an agent types `wv prune`. It refuses when called from a
  hook (`WV_CALL_SOURCE=hook`). Session ends, commits and pushes do not prune.
- One scheduled slot: a release step, after the release has settled and before it is cut, with
  `--dry-run` first.
- `WV_AUTO_PRUNE` is retired. A graph over `WV_MAX_DB_SIZE` draws a warning that advises
  `wv prune --dry-run`, then `wv prune`; the switch announces that it does not prune.

Why: the one automated prune (session end, 48 hours) removed 615 done nodes that live work still
cited. Its tombstones were lost and every fresh load afterwards failed. It did not prevent a
mistake.

## Selection

`wv prune` starts from done nodes older than `--age` (default 30 days; 48 hours is what selected
the 615) and keeps:

| Kept                                                   | Why                                                                                                                            |
| ------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------ |
| finding and memory nodes                               | a finding is the record of a defect; a memory graduates project-locally                                                        |
| epic, plan and decision nodes                          | the record of intent and of rulings                                                                                            |
| a node with an unresolved pitfall                      | its lesson has not been applied yet                                                                                            |
| a node a live node references                          | an edge into it from a node outside the selection, or its id in that node's text or metadata (the direction `wv impact` reads) |
| a node whose GitHub issue is open or cannot be checked | the open issue is a live claim on it; an unanswerable `gh` fails closed                                                        |

`--dry-run` lists the candidates and a `kept` line per rule with its count. `--orphans-only` ignores
the age and selects done nodes with no edges, under the same exclusions.

## Tombstone retention

A tombstone may be compacted only once every replica that could replay the deleted row has seen it.
A replica that replays history from before the deletion, without the tombstone, brings the row back.

- In Weave the replicas are the clones declared in `.weave/clones/*.roster` and the consumers that
  load the graph. Each roster carries a `watermark <lineage seq>` line: the highest lineage seq that
  clone has acknowledged loading, written by the operator after `wv load` reports the load
  acknowledged there. A tombstone is compactable only when its lineage seq is below every roster's
  watermark AND below the 90-day floor. A writer prefix in the delta catalog that no roster accounts
  for blocks compaction: an undeclared replica may still replay.
- The 90-day floor is read from the delta catalog, which is dated: the floor is the highest lineage
  seq under any `.weave/deltas/<date>/v2/` directory dated 90 or more days ago. The tombstone table
  carries no timestamp of its own, and adding one would change the table text that `state.sql`
  byte-compares between a fresh and a migrated database.
- `wv prune --compact-tombstones [--dry-run]` applies the rule. It refuses when the roster check
  fails, when a roster has no watermark, or when `WV_TOMBSTONE_COMPACTION` is not `1`. A tombstone
  with lineage seq 0 (pre-cutover, age unknown) is never compacted. Keeping a tombstone too long
  costs a row; dropping one too early resurrects a node.

## Consumer defaults

A consumer gets the explicit-only rule, the selection rules and tombstones on every delete and
prune. Tombstone compaction ships off (`WV_TOMBSTONE_COMPACTION` unset): a consumer with one clone
has no replay window to manage, and the roster watermark has only been exercised in the build
repository.

## Resurrected nodes

A node that a reload brings back is not deleted again by hand. Check `tombstones` for its id. A
missing row means the prune that removed it lost its tombstone; the archive under `.weave/archive/`
holds what that prune removed. A present row means the resurrected copy outranks it on (lineage seq,
actor): a replay-order defect to file, not a prune to repeat.
