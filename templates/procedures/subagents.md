---
id: subagents
description: "Delegate bounded work while preserving graph context and keeping decisions with the parent."
fallback: "wv guide --procedure=subagents"
adapters: [codex, copilot]
visibility: shared
status: ready
---

# Subagent Delegation

Delegate work that produces intermediate output the parent will not need again: verification,
unfamiliar-code research, documentation generation, and bulk operations. Keep architecture decisions,
iterative debugging, and user-facing scope decisions in the parent context.

Claim the parent node first. Subagents inherit `WV_ACTIVE` and should load `wv context --json` before
acting, so they receive the node, blockers, ancestry, and relevant learnings. Use the host’s native
subagent mechanism; MCP clients use `weave_work` and `weave_context`.

Give each subagent a bounded task and return only its conclusion, evidence, and any new blocker. A
subagent must not silently broaden scope or close the parent node.
