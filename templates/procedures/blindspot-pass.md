---
id: blindspot-pass
description:
  "Run a bounded unknown-taxonomy pass before implementation; separate facts, known gaps, prior
  learnings, candidate blind spots, and the plan's own assumptions, verified before building on
  them. Use when requirements, environment, or prior conclusions are uncertain."
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
5. List the plan's own assumptions, which the graph cannot see: code ("function X exists and does
   Y"), API shape, behaviour, environment ("service Z is reachable") and data ("table has column
   A"). Tag each one:

   | Tag          | Meaning                                   | Action                        |
   | ------------ | ----------------------------------------- | ----------------------------- |
   | `verified`   | confirmed by reading code, docs or a test | none                          |
   | `unverified` | believed true, not checked                | check before building on it   |
   | `uncertain`  | more than one possibility                 | resolve before building on it |
   | `falsified`  | checked and found false                   | change the plan               |

   Check each `unverified` one with the cheapest probe that would fail if it were false (a search,
   `wv show <id>`, `git log` of the area, a canary run). Never build a critical path (auth, data,
   external services) on an unverified assumption, and never state a guess with the confidence of a
   verified fact. Record the result (`--metadata` merges):

   ```bash
   wv update <id> --metadata='{
     "assumptions": [
       {"claim": "Auth middleware exists", "status": "verified", "evidence": "src/middleware/auth.ts"},
       {"claim": "Tokens expire in 1h", "status": "unverified", "check": "read the auth config"}
     ],
     "confidence": "medium"
   }'
   ```

   Confidence is `high` when every key assumption is verified, `medium` when only low-risk ones are
   not, and `low` when a critical one is unverified: investigate before implementing.

6. Probe candidates cheaply before promoting them. Do not create a blocking finding from a candidate
   unless evidence lands.
   - When the task fixes a failure that has gone on for a long time, list every step that runs after
     the failure point. None of them has run since the failure began: each is a candidate. Run each
     one unstubbed, under adverse conditions (an unreachable remote, the host's time budget, a cold
     cache), before closing. See the long-standing failure example below.
7. If evidence confirms a defect or risk, promote it to `type=finding` metadata and use a
   `blocks` edge only after the finding has meaning, probe, evidence, and valid `finding.*` fields.
8. Close with a learning that records the transition: dismissed, promoted to finding, resolved, or
   promoted to procedure.

## Release Example

```bash
wv discover <release-node> --json |
  jq '.unknown_knowns, .unknown_unknown_candidates'
```

If the report surfaces a release-note sanitizer candidate, probe with the release dry-run or fake
`gh` wrapper before publishing. A clean probe dismisses the candidate. A leaked node id promotes it
to a finding and may block the release node.

## Long-standing Failure Example

The session-end routine was killed by a 1.5 s host budget on every exit for eight months
(wv-a32e69). Fixing the kill meant its later steps would run again for the first time since. Listing
them showed the local sync's auto-checkpoint pull: run against an unreachable remote it took 33 s
(five retries with backoff), past the new 30 s budget. The fix passed `WV_CHECKPOINT_PULL=0` and the
suite gained a case that runs the routine itself against an unreachable remote. Without the list,
the fix would have replaced one silent kill with another.

## MCP Example

```bash
wv discover <mcp-node> --json |
  jq '.known_unknowns, .unknown_unknown_candidates'
```

If the report surfaces MCP scope or startup-process candidates, probe the MCP contract, generated
README counts, and focused MCP parity tests. Treat process-state guesses as candidates until a
startup/status command or test produces evidence.
