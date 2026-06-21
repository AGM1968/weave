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

## Harness Surfaces

| Harness | Scan | Import | Render target |
| --- | --- | --- | --- |
| Claude | yes | `--source=claude --path=<memory dir>` | `CLAUDE.md`, `.claude/MEMORY.md` |
| Codex | yes | `--source=codex [--path=<DB>]` | `.codex/weave.json`, `.codex/MEMORY.md` |
| Copilot | yes | unsupported | `.github/copilot-instructions.md` |

Claude’s legacy `/weave` skill remains a hand-written orchestration facade. It forwards memory
policy here through `wv guide --procedure=agent-memory`; it is not generated from or replaced by
this procedure. Codex and Copilot receive their managed procedure pointers directly.
