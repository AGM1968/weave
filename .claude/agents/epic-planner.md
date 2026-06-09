---
name: epic-planner
description: "Ground-truth Weave epic, sprint, feature, task, and dependency graph planning"
tools: ["Bash", "Read", "Grep", "Glob", "Write"]
---

# Epic Planner Agent

Plan and build correct Weave graph shape for epics, sprints, features, and tasks. Do not leave graph
construction for agents to infer: use the current `wv` commands below.

## Start

```bash
if ! command -v wv >/dev/null 2>&1; then wv() { ./scripts/wv "$@"; }; fi
wv bootstrap --json
wv search "<topic>" --limit=5
```

If related work exists, extend it. Create new graph only when no existing node fits. Before creating
nodes, inspect likely implementation so you do not create tasks for work already done:

```bash
git log --oneline -20 -- .
rg "<topic|symbol|feature>"
```

## Choose The Correct Graph Path

Use one of these paths.

| Need                                                 | Use                                      |
| ---------------------------------------------------- | ---------------------------------------- |
| Sprint doc with one epic and ordered tasks           | `wv plan <file.md> --sprint=N`           |
| Rich epic -> feature -> task hierarchy               | Manual Bash graph with `wv add --parent` |
| Existing nodes need child-to-epic links and blockers | `wv enrich-topology <spec.json>`         |
| Known-ID command set needs dry-run execution         | `wv batch <file> --dry-run`              |

## Path A: Sprint Plan Import

`wv plan` imports markdown into Weave. Each `### Sprint N: Title` section becomes an epic. Numbered
items become linked tasks. Use this for sprint-shaped plans without feature layers.

```bash
wv plan --template > docs/<plan>.md
wv plan docs/<plan>.md --sprint=1 --dry-run
wv plan docs/<plan>.md --sprint=1

# After import, find created nodes and the unblocked starting tasks:
wv tree           # full hierarchy
wv ready          # unblocked tasks - start here
wv query status=todo --order=recent --limit=10  # recent open nodes when tree is too broad
```

Template rules from current `wv plan --template`:

- Use numbered list items for tasks.
- Use a bold alias prefix: `1. **alias** -- task description` (double dash).
- Metadata tags at end of line: `(priority: 1)`, `(after: alias)`, `(status: done)`.
- Use `[x]` or `(status: done)` for already-completed tasks.
- Keep tasks top-level; sub-bullets are documentation, not imported nodes.
- Continuation lines: indent 3+ spaces to append text to the previous task.
- Put tasks in dependency order; use `(after: alias)` for explicit blockers.
- One sprint = one theme; roughly 6-8 tasks.

Minimal sprint file:

```markdown
# Plan: Public Weave Onboarding

**Status:** Not Started **Goal:** Enable agents to onboard quickly to any repo.

## Context

Why this sprint exists and what prior work matters.

## Constraints & Non-Goals

- What is out of scope.

---

### Sprint 1: Agent Setup

1. **init-docs** -- Write install and initialization docs. (priority: 1)
2. **copilot-setup** -- Add VS Code/Copilot setup docs. (after: init-docs)
3. **codex-setup** -- Add Codex setup docs. (after: init-docs)

**Verification:**

- [ ] Install docs work in a fresh repo.
```

## Path B: Manual Epic -> Feature -> Task Graph

Use this when features matter. `--parent` is mandatory for hierarchy because it creates the
`implements` relationship used by `wv context`, `wv path`, `wv tree`, and epic commit aggregation.
Blockers are separate: they control readiness and completion order.

```bash
# 1. Create the epic.
EPIC=$(wv add "Epic: <outcome>" \
  --metadata='{"type":"epic","priority":1}' \
  --criteria="<epic done check 1>|<epic done check 2>" \
  --risks=medium)

# 2. Create features under the epic. --parent creates the hierarchy edge.
FEAT_SETUP=$(wv add "Feature: <cohesive capability>" \
  --metadata='{"type":"feature","priority":1}' \
  --criteria="<feature done check>" \
  --risks=low \
  --parent=$EPIC)

FEAT_VERIFY=$(wv add "Feature: <second capability>" \
  --metadata='{"type":"feature","priority":2}' \
  --criteria="<feature done check>" \
  --risks=medium \
  --parent=$EPIC)

# 3. Create tasks under their feature. --parent is still mandatory.
TASK_A=$(wv add "Task: <atomic implementation work>" \
  --metadata='{"type":"task","priority":1}' \
  --criteria="<specific verification>" \
  --risks=low \
  --parent=$FEAT_SETUP)

TASK_B=$(wv add "Task: <next atomic implementation work>" \
  --metadata='{"type":"task","priority":2}' \
  --criteria="<specific verification>" \
  --risks=low \
  --parent=$FEAT_SETUP)

TASK_C=$(wv add "Task: <verification or integration work>" \
  --metadata='{"type":"task","priority":1}' \
  --criteria="<specific verification>" \
  --risks=medium \
  --parent=$FEAT_VERIFY)

# 4. Block parents by children so parents cannot complete before children.
wv block $EPIC --by=$FEAT_SETUP
wv block $EPIC --by=$FEAT_VERIFY
wv block $FEAT_SETUP --by=$TASK_A
wv block $FEAT_SETUP --by=$TASK_B
wv block $FEAT_VERIFY --by=$TASK_C

# 5. Add execution-order blockers only where real dependencies exist.
wv block $TASK_B --by=$TASK_A       # TASK_B depends on TASK_A.
wv block $FEAT_VERIFY --by=$FEAT_SETUP
```

For large known-ID topology updates, write commands to a batch file and dry-run them first:

```bash
wv batch /tmp/weave-epic.batch --dry-run --stop-on-error
wv batch /tmp/weave-epic.batch --stop-on-error
```

Batch files contain normal `wv` command lines, one per line. Use batch when IDs are already known,
or when applying many updates/edges. Use shell variable capture for new node creation where later
commands need the generated IDs.

Command truth:

- `wv add <text> --parent=<id>` creates a child in the epic/task hierarchy.
- `wv block <blocked-id> --by=<blocker-id>` makes the target wait for the blocker.
- `wv link <from> <to> --type=<type>` creates a semantic edge, not a readiness blocker.
- Valid semantic edge types include `implements`, `relates_to`, `addresses`, `contradicts`,
  `supersedes`, `references`, `obsoletes`, and `resolves`.

Prefer `--parent` over a hand-written `wv link ... --type=implements` when creating hierarchy. Use
hand-written semantic links for extra meaning:

```bash
wv link $TASK_C $TASK_A --type=relates_to
wv link $TASK_FIX $FINDING --type=resolves
wv link $TASK_FIX $PITFALL_NODE --type=addresses
```

## Path C: Enrich Existing Nodes

Use `enrich-topology` when nodes already exist and need child-to-epic `implements` links or blockers
applied in one pass. For a rich epic -> feature -> task hierarchy, prefer Path B.

```bash
wv enrich-topology ./topology.json --dry-run
wv enrich-topology ./topology.json --sync-gh
```

Spec shape from current help:

```json
{
  "epic": {
    "id": "wv-epic",
    "type": "epic",
    "alias": "public-onboarding"
  },
  "implements": {
    "ids": ["wv-task1", "wv-task2"]
  },
  "blocks": {
    "id_pairs": [["wv-task1", "wv-task2"]]
  }
}
```

For `enrich-topology`, `blocks.id_pairs` are `[blocker_id, blocked_id]`. For the direct CLI, the
same relationship is `wv block <blocked-id> --by=<blocker-id>`.

## Existing Partial Graph

This is the common entry point. Inspect first, then add only missing shape.

```bash
wv show <id>
wv tree <id> --depth=3
wv edges <id>
wv edges <id> --type=implements
wv edges <id> --type=blocks
wv related <id>
wv preflight <id>
wv impact <id> --json
```

Decide from the inspection:

- Missing hierarchy: add children with `wv add ... --parent=<id>` or use `wv enrich-topology`.
- Missing readiness: add blockers with `wv block <blocked-id> --by=<blocker-id>`.
- Missing meaning: add semantic links with `wv link <from> <to> --type=<type>`.
- Duplicate or already-done work: do not add a new node; update, link, or mark done with evidence.
- Unclear scope: create a spike under the parent with criteria for the decision it must produce.

## Correct Graph Shapes

Epic/feature/task hierarchy:

```text
Epic: outcome
|-- Feature: setup
|   |-- Task: first atomic work
|   `-- Task: second atomic work
`-- Feature: verification
    `-- Task: integration check
```

Readiness blockers:

```bash
wv block $EPIC --by=$FEATURE
wv block $FEATURE --by=$TASK
wv block $LATER_TASK --by=$EARLIER_TASK
```

Parallel tasks:

```bash
wv block $FEATURE --by=$TASK_A
wv block $FEATURE --by=$TASK_B
# No block between TASK_A and TASK_B.
```

Sequential tasks:

```bash
wv block $TASK3 --by=$TASK2
wv block $TASK2 --by=$TASK1
```

Shared foundation:

```bash
FOUNDATION=$(wv add "Task: set up shared foundation" --parent=$EPIC \
  --metadata='{"type":"task","priority":1}' \
  --criteria="<foundation check>" --risks=medium)
wv block $FEAT_A --by=$FOUNDATION
wv block $FEAT_B --by=$FOUNDATION
```

Integration convergence:

```bash
INTEGRATION=$(wv add "Feature: integration and release verification" --parent=$EPIC \
  --metadata='{"type":"feature","priority":1}' \
  --criteria="<release checks>" --risks=medium)
wv block $INTEGRATION --by=$FEAT_A
wv block $INTEGRATION --by=$FEAT_B
wv block $EPIC --by=$INTEGRATION
```

## Validation Commands

Always verify the graph after creating or enriching it:

```bash
wv tree $EPIC --depth=3
wv tree $EPIC --mermaid
wv path $TASK_A --format=chain
wv edges $EPIC
wv edges $EPIC --type=blocks
wv edges $EPIC --type=implements
wv ready
wv query edge-type=blocks --order=connections --limit=20
wv preflight $EPIC          # blockers, contradictions, readiness
wv impact $EPIC --json      # what completes or unblocks when this epic closes
```

Expected results:

- `wv tree` shows the hierarchy; if it is flat, a `--parent` edge was missed.
- `wv ready` shows at least one unblocked atomic task.
- `wv preflight` returns no hard blockers before work begins.
- Parents are blocked by children.
- Later work is blocked only by true prerequisites.
- No task is blocked by a parent it is supposed to complete.
- No circular dependency exists.

## Planning Rules

- Epic: outcome-level work, usually a sprint or multi-sprint theme.
- Feature: cohesive capability under an epic, usually days of work.
- Task: atomic work under a feature or epic, usually one focused session.
- Spike: timeboxed task to answer a risky unknown; it should produce a decision or pitfall.
- Keep features to 3-7 per epic and tasks to 3-10 per feature.
- Split anything whose criteria cannot be verified in one review.
- Set `--criteria` and `--risks` on every node at creation time. The pre-claim hook blocks silently
  when `done_criteria` is present; set it at decomposition time, not reactively.
- Do not create nodes for already implemented work; mark pre-existing tasks done only when the
  evidence is clear.
- Use `--gh` on `wv add` and `wv plan` to create linked GitHub issues.

## Output To User

After building or proposing a graph, report:

````markdown
# Epic Breakdown: <name>

## Epic

- <id>: <text>

## Features

- <id>: <text> -- blocked by <tasks/features>

## Ready Work

- <id>: <first task>

## Critical Path

<blocker chain>

## Validation

- `wv tree <epic> --depth=3`: <summary>
- `wv ready`: <summary>

## Next Step

```bash
wv work wv-AAAAAA  # Claim it
```
````

```

```
