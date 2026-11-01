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
wv memory review <id> --verdict=promote|merge|reject|verify --reason=<why> [--target=<active id>]
wv memory review <active id> --verdict=graduate --reason=<why> --target=<repo path>
wv memory review --apply [--dry-run]
wv memory crystallize --apply-reviewed
wv memory recall [--agent=current|all|<name>]
wv memory render --agent=all|current|<agent>
```

Imported memory starts as `mem_status=candidate`; it is excluded from both `recall` and `ready`.
`crystallize --dry-run` classifies candidates without mutation. `--apply-reviewed` promotes only
explicitly reviewed candidates, marks verified stale references as `stale`, and marks exact source
hash collisions as `superseded`. Contradictory candidates remain candidates and get one finding per
pair; read both claims, correct or supersede the stale one, or close the finding when they agree,
and the next run no longer holds the candidate back. Fuzzy overlap is reported, never applied
automatically.

A reviewer records a verdict on each candidate with `wv memory review`. Recording changes nothing
else; `review --apply` acts on the recorded verdicts. `promote` marks the candidate reviewed; the
next `crystallize --apply-reviewed` then promotes it after its own checks. `merge` supersedes the
candidate onto an existing active memory and lists it in that memory's `merge_from`, whose text the
reviewer then amends. `reject` retires the candidate (`mem_status=rejected`) with its reason.
`verify` leaves it a candidate until the claim is checked and a final verdict recorded.

`graduate` is the one verdict on an active memory: the lesson now lives in one of the repository's
own surfaces, named by `--target`. That is a procedure in `.weave/procedures/<id>.md`, a guide in
`.weave/guides/<id>.md`, a detector in `.weave/patterns/<id>.yaml`, or a Markdown document git
tracks. The target must resolve inside the repository and parse under its surface's contract, when
the verdict is recorded and again when it is applied. Apply sets `mem_status=graduated` and
`graduated_to`: render and `wv bootstrap` drop the memory, and `recall` still returns it.

`wv doctor` warns when the rendered memory block exceeds `.weave/policy.conf`
`[memory] block_budget_bytes` (default 8192) and names graduation candidates. It also flags memories
that may hold time-bound state (pending or dated language, a cited node now done or gone) for
re-verification. Neither warning changes a memory.

Imports are idempotent: unchanged source hashes are skipped, Claude's `MEMORY.md` index is not
imported, and a changed source supersedes its earlier candidate. The graph remains authoritative:
import pulls in, crystallize curates, and render projects the active set back out.

Active memory is append-only for claims. When a claim changes, record the new one with
`wv remember "<text>" --supersedes=<id>`: the old memory stays as `mem_status=superseded` with
`superseded_by`, linked by a `supersedes` edge, and render shows only the successor, whose
`verified_at` is the date of the new verification. Editing a claim in place leaves the old
`verified_at` on new text. Only wording that does not change the claim (typos, prose-rule fixes) is
edited in place. A session handoff is a trail (`wv trails save`), not a memory: it records the state
at one moment, and that state moves on.

After any memory change, re-render every projection together with `wv memory render --agent=all` and
commit them with the graph state that produced them.

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
- `wv memory crystallize --dry-run|--apply-reviewed --json` returns `{mode, candidates, results}`.
  Each result has `id`, `action`, and `reviewed`; optional fields (`duplicate_of`, `dup_kind`,
  `contradicts`, `stale_reason`, `finding`) appear only when relevant.

Trail entries are evidence for this same lifecycle, not a parallel store. A reusable trail insight
should become a candidate memory through the same provenance, deduplication, staleness, and review
checks as harness-native imports.

Export is a downstream boundary, not another lifecycle owner. `PROPOSAL-wv-knowledge-export.md`
defines `wv export knowledge` as a future read-only `weave-knowledge/v1` package over settled graph
knowledge: active memory, structured learnings, findings, and verified completed work. It must read
the `type=memory` / `mem_status=active` shape frozen here, exclude candidates/stale/superseded
memory, and never promote or mutate memory. Import/review/promotion stay under the memory lifecycle.

## Harness Surfaces

| Harness | Scan | Import                                | Render target                                                                 |
| ------- | ---- | ------------------------------------- | ----------------------------------------------------------------------------- |
| Claude  | yes  | `--source=claude --path=<memory dir>` | `CLAUDE.md`                                                                   |
| Codex   | yes  | `--source=codex [--path=<DB>]`        | `.codex/weave.json`, `AGENTS.md` (when it has the block)                      |
| Copilot | yes  | unsupported                           | `.github/copilot-instructions.md` (it also reads `AGENTS.md` and `CLAUDE.md`) |

The projections carry an index: one line per memory, its `metadata.hook` or else its first sentence.
A memory with `metadata.resident` set to `full` keeps its whole text. Read any memory in full with
`wv memory recall --agent=all --json` or `wv show <id>`. `.claude/MEMORY.md` and `.codex/MEMORY.md`
are no harness's instruction file and `--agent=all` no longer writes them; `--agent=claude-memory`
or `--agent=codex-memory` still renders one on request.

Claude’s legacy `/weave` skill remains a hand-written orchestration facade. It forwards memory
policy here through `wv guide --procedure=agent-memory`; it is not generated from or replaced by
this procedure. Codex and Copilot receive their managed procedure pointers directly.
