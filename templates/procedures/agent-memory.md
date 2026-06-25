---
id: agent-memory
description:
  "Agent memory model and per-agent memory surfaces — what to capture, where each harness stores it,
  and how runtime-memory capture relates to the graph. Use when deciding what belongs in memory vs
  the graph."
fallback: "wv guide --procedure=agent-memory"
adapters: [codex, copilot]
visibility: shared
status: ready
---

# Agent Memory

Weave keeps durable memory in the graph, not in per-agent files. The graph is authoritative;
per-agent memory files are harness state that is scanned/imported into the graph and rendered back
out as projections. Recall and crystallization are agent-agnostic. Scan, import, and render retain
per-agent provenance only where the harness requires it.

## Memory Lifecycle

```bash
wv memory scan --source=claude|codex|copilot|all
wv memory import --source=claude --path=<DIR>
wv memory import --source=codex [--path=<DB>]
wv memory crystallize --dry-run
wv memory crystallize --apply-reviewed
wv memory recall [--agent=current|all|<name>]
wv memory render --agent=all|current|<agent>
```

Imported memory starts as `mem_status=candidate`; it is excluded from both `recall` and `ready`.
`crystallize --dry-run` classifies candidates without mutation. `--apply-reviewed` promotes only
explicitly reviewed candidates, marks verified stale references as `stale`, and marks exact source
hash collisions as `superseded`. Contradictory candidates remain candidates and create a review
signal; fuzzy overlap is reported, never applied automatically.

Imports are idempotent: unchanged source hashes are skipped. The graph remains authoritative:
import pulls in, crystallize curates, and render projects the active set back out.

## JSON Contract

The public lifecycle surface is `wv memory`; `wv query` may power reads underneath, but it must not
own lifecycle side effects. Refactors must preserve these machine-readable envelopes:

- `wv remember <text> --json` returns one graph node object with `id`, `text`, `status`, and
  `metadata`. Required metadata: `type=memory`, `mem_status=active`, `source_agent`,
  `source_kind=remember`, and `verified_at`.
- `wv memory recall --agent=<caller> --json` returns a JSON array of active graph-memory nodes.
  `--agent` is caller provenance only; it must never filter the recalled set.
- `wv memory render --agent=<projection> --json` returns `{projection, paths, path, entries}` and
  writes generated projections whose authority remains `weave-graph` and lifecycle field remains
  `metadata.mem_status`.
- `wv memory scan --source=<agent> --json` returns observation objects with `source_agent`,
  `source_kind`, `source_path`, and `repo_root`; scan observes evidence and does not create memory.
- `wv memory import --source=<agent> --json` returns `{imported, count, skipped}` and creates
  `mem_status=candidate` nodes with provenance metadata. Re-importing the same source hash skips.
- `wv memory crystallize --dry-run|--apply-reviewed --json` returns
  `{mode, candidates, results}`. Each result has `id`, `action`, and `reviewed`; optional fields
  (`duplicate_of`, `dup_kind`, `contradicts`, `stale_reason`, `finding`) appear only when relevant.

Trail entries are evidence for this same lifecycle, not a parallel store. A reusable trail insight
should become a candidate memory through the same provenance, deduplication, staleness, and review
checks as harness-native imports.

Export is a downstream boundary, not another lifecycle owner. `PROPOSAL-wv-knowledge-export.md`
defines `wv export knowledge` as a future read-only `weave-knowledge/v1` package over settled graph
knowledge: active memory, structured learnings, findings, and verified completed work. It must read
the `type=memory` / `mem_status=active` shape frozen here, exclude candidates/stale/superseded
memory, and never promote or mutate memory. Import/review/promotion stay under the memory lifecycle.

## Harness Surfaces

| Harness | Scan | Import | Render target |
| --- | --- | --- | --- |
| Claude | yes | `--source=claude --path=<memory dir>` | `CLAUDE.md`, `.claude/MEMORY.md` |
| Codex | yes | `--source=codex [--path=<DB>]` | `.codex/weave.json`, `.codex/MEMORY.md` |
| Copilot | yes | unsupported | `.github/copilot-instructions.md` |

Claude’s legacy `/weave` skill remains a hand-written orchestration facade. It forwards memory
policy here through `wv guide --procedure=agent-memory`; it is not generated from or replaced by
this procedure. Codex and Copilot receive their managed procedure pointers directly.
