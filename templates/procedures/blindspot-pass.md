---
id: blindspot-pass
description: "Run a bounded unknown-taxonomy pass before implementation; separate facts, known gaps, prior learnings, and candidate blind spots."
fallback: "wv guide --procedure=blindspot-pass"
adapters: [claude, codex, copilot]
visibility: shared
status: ready
claude_skill: wv-blindspot-pass
---

# Blindspot Pass

Use this before implementation when the task has meaningful design, release, MCP, migration, or
cross-surface risk.

## Workflow

1. Claim or confirm the active node: `wv work <id>` or `wv status`.
2. Load session context: `wv bootstrap --json`.
3. Run the typed report: `wv discover <id> --json`.
4. Read the four buckets separately:
   - `known_knowns`: facts already in the prompt, node, criteria, or context.
   - `known_unknowns`: explicit blockers, risks, and related open findings.
   - `unknown_knowns`: prior decisions, patterns, and pitfalls from graph memory.
   - `unknown_unknown_candidates`: impact-derived or heuristic candidates that need probes.
5. Probe candidates cheaply before promoting them. Do not create a blocking finding from a candidate
   unless evidence lands.
6. If evidence confirms a real defect or risk, promote it to `type=finding` metadata and use a
   `blocks` edge only after the finding has meaning, probe, evidence, and valid `finding.*` fields.
7. Close with a learning that records the transition: dismissed, promoted to finding, resolved,
   or promoted to procedure.

## Release Example

```bash
wv discover <release-node> --json |
  jq '.unknown_knowns, .unknown_unknown_candidates'
```

If the report surfaces a release-note sanitizer candidate, probe with the release dry-run or fake
`gh` wrapper before publishing. A clean probe dismisses the candidate. A leaked node id promotes it
to a finding and may block the release node.

## MCP Example

```bash
wv discover <mcp-node> --json |
  jq '.known_unknowns, .unknown_unknown_candidates'
```

If the report surfaces MCP scope or startup-process candidates, probe the MCP contract, generated
README counts, and focused MCP parity tests. Treat process-state guesses as candidates until a
startup/status command or test produces evidence.
