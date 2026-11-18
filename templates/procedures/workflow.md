---
id: workflow
description: "Four-phase graph-first orchestrator. Use when there is any Weave-tracked work to do."
fallback: "wv guide --procedure=workflow"
adapters: [claude, codex, copilot]
visibility: shared
status: ready
claude_skill: weave
---

# Weave Workflow

The workflow lives in one place, the Weave workflow reference. Read it with `wv guide` and follow
its Work Loop: intake, context, execute, close. This entry states no rule of its own.

- Work a named node: `wv work <id>`, then `wv context <id> --json`.
- Work from a description: create the node, claim it, then read its context.
- Pick work: `wv bootstrap --json`, then choose from the ready work it lists.

The focused procedures are listed in the reference's Procedures section and open with
`wv guide --procedure=<id>`.
