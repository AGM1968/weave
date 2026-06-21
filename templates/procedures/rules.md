---
id: rules
description: "Advisory workflow discipline: graph intent, verification, scoped sessions, and safe retries."
fallback: "wv guide --procedure=rules"
adapters: [codex, copilot]
visibility: shared
status: ready
---

# Advisory Workflow Rules

Enforced invariants remain in hooks and the CLI; this procedure covers the judgment around them.

- Track work before edits, create follow-up nodes for untracked fixes, and record intent in the graph.
- Load `wv context <id> --json` before complex work and verify assumptions before relying on them.
- Capture structured learnings for non-trivial work; commit incrementally; sync and push at session end.
- Keep sessions bounded to related work. Do not bypass hooks or duplicate long-running commands.
- When decomposing a proposal, use its sprint labels verbatim and set criteria/risks before claiming.
