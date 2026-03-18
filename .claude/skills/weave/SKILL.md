---
name: weave
description: "Four-phase graph-first orchestrator. Use when there is any Weave-tracked work to do."
---

# /weave — Graph-First Orchestrator

**Purpose:** Unified entry point for all Weave-tracked work. Ensures graph-first workflow with
Context Pack generation, blocker validation, and learning capture.

**Current Implementation:** All four phases (INTAKE, CONTEXT, EXECUTE, CLOSE)

> **Delegation design** (unimplemented): See `docs/DESIGN-weave-delegation.md` for tier routing,
> Haiku subagent tasks, and result caching design.

### Subagent Context Inheritance (WV_ACTIVE)

When spawning subagents, pass the active node context via `WV_ACTIVE` environment variable:

**Pattern:**

1. Parent claims work with `wv work <id>` (sets node to active)
2. Parent exports `WV_ACTIVE=<id>` (or uses `eval "$(wv work <id> --quiet)"`)
3. Subagent calls `wv context --json` (automatically uses WV_ACTIVE)
4. Subagent receives full Context Pack: node + blockers + ancestors + learnings

**Example workflow:**

```bash
# Parent agent claims work and sets context
eval "$(wv work wv-a1b2 --quiet)"

# Subagent (inherits WV_ACTIVE from environment)
context=$(wv context --json)
node_text=$(echo "$context" | jq -r '.node.text')
blockers=$(echo "$context" | jq -r '.blockers | length')
```

**When spawning via runSubagent:**

Include WV_ACTIVE in the prompt for subagents that need graph context:

```text
runSubagent(
  description: "Analyze blockers for current node",
  prompt: "Current work context:
           WV_ACTIVE: $WV_ACTIVE

           Run: wv context --json

           Analyze the blockers array and report which must be resolved first."
)
```

**Benefits:**

- Subagents automatically get relevant Context Pack
- No need to pass node ID explicitly in every prompt
- Consistent context across deep agent hierarchies
- Works with any tool that spawns child processes

## Usage

```bash
/weave <id>        # Work a specific node
/weave <text>      # Create node from description
/weave             # Show ready work, pick one
```

## Iteration Model

The orchestrator is a state machine with defined transitions:

```text
┌─────────────────────────────────────────────────────────────┐
│                    WeaveOrchestrator                        │
├─────────────┬─────────────┬─────────────┬──────────────────┤
│   INTAKE    │   CONTEXT   │   EXECUTE   │      CLOSE       │
│             │   (graph)   │             │                  │
│ wv add/ready│ wv context  │ do work     │ wv done          │
└─────────────┴─────────────┴─────────────┴──────────────────┘
        │                         │
        │    ◄────────────────────┤ (new blocker/contradiction)
        │                         │
        └─────────────────────────┘ (scope expansion → new node)
```

**Normal flow:** INTAKE → CONTEXT → EXECUTE → CLOSE

**Iteration triggers (EXECUTE → CONTEXT):**

| Trigger         | Graph Change                 | Action                                   |
| --------------- | ---------------------------- | ---------------------------------------- |
| New blocker     | `wv block` called            | Re-query context, resolve blocker first  |
| Contradiction   | `wv link --type=contradicts` | Hard stop, resolve via `wv resolve`      |
| Scope expansion | Child node created           | Block current on child, work child first |

**Re-entry (INTAKE → new node):**

When scope expands significantly, create a new node and restart from INTAKE for that node. Current
node remains blocked until child completes.

## Phase 1: INTAKE — Select or Create Work

**Goal:** Ensure valid, claimable work is selected before starting.

### Input Modes

| Mode | Command | Steps |
|------|---------|-------|
| Node ID | `/weave wv-xxxxxx` | Validate → claim (`wv update <id> --status=active`) → CONTEXT |
| Text | `/weave "Fix bug"` | Create (`wv add "<text>" --status=active`) → CONTEXT |
| None | `/weave` | Show `wv ready --json` → user picks → Mode 1 or 2 |

**Claimable:** `todo` or `blocked`. `active` = warn but allow. `done` = block.
**Vague text** (<5 words, no action verb): invoke `/wv-clarify-spec` first.

### Agent Pre-Launch Validation

Before spawning any weave agent (`epic-planner`, `learning-curator`, `weave-guide`):
1. Read `.claude/agents/<name>.md`
2. Verify `tools` field includes `"Bash"`
3. On fail → abort spawn, fall back to inline execution

## Phase 2: CONTEXT — Mandatory Graph Query

**Goal:** Build context before any planning or coding.

1. `wv context <id> --json`
2. **Contradictions** → HARD STOP, resolve via `wv resolve` before proceeding
3. **Unresolved blockers** → STOP, work blocker first or remove dependency
4. Surface ancestors, related nodes, pitfalls, high-weight references
5. Cache Context Pack (invalidates on edge changes)

## Phase 3: EXECUTE — Do the Work

**Pre-conditions** (enforced by `pre-action.sh` hook):
- Active node exists
- No unresolved contradictions or blockers

**Edge enforcement:**

| Edge Type | Weight | Action |
|-----------|--------|--------|
| `references` | ≥0.7 | Must read before editing |
| `implements` | any | Verify against spec |
| `supersedes`/`obsoletes` | any | Warn, do not proceed without override |

**Scope control:** If editing unrelated files → create child node (iteration trigger).
**Stuck detection:** Same approach fails 2× → pivot strategy or create blocker node.

## Phase 4: CLOSE — Complete with Learnings

### ⛔ Mandatory Pre-Close Gate

**DO NOT call `wv done` until:**

1. **Learning-curator invoked** (non-trivial work):
   - `runSubagent(learning-curator)` with node text + files changed + work summary
   - Learnings must contain: `decision:` | `pattern:` | `pitfall:`
   - Trivial only (doc typo, breadcrumbs): `--skip-learnings`

2. **Verification evidence captured** (enforced by `pre-close-verification.sh` hook):
   - Tests pass / build succeeds / manual verification
   - Trivial only: `--skip-verification`

```text
✗ WRONG:  wv done wv-XXXX --learning="fixed the bug"
✓ RIGHT:  runSubagent(learning-curator) → structured learnings
          wv done wv-XXXX --learning="decision: ... | pattern: ... | pitfall: ..."
```

### Close and Sync

```bash
wv done <id> --learning="pattern: ..."
wv sync --gh && git push
```

### Recovery (v1.9.0)

If `wv ship` or `wv sync` is interrupted, `wv recover` resumes from the journal.
