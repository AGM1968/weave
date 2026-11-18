---
id: repo-onboarding
description:
  "Automates cold-start graph enrichment from a repo into Weave by auditing commits, generating
  PLAN.md, enriching nodes, and syncing GitHub. Use when onboarding an existing repo or
  bulk-enriching a graph for the first time."
fallback: "wv guide --procedure=repo-onboarding"
adapters: [claude, codex, copilot]
visibility: shared
claude_skill: plan-agent
---

# Repository Onboarding

Onboarding takes an existing repository with commit history to an enriched Weave graph: epics and
tasks with aliases, status, learnings, edges, Mermaid graphs and GitHub issues. It records what the
history shows; it is not epic decomposition of new work (`wv guide --procedure=epic-decompose`).

The onboarding agent maps, it does not implement. When a task reads "fix X", record whether X is
fixed; do not fix X.

## Prerequisites

- Weave installed (`wv health` runs)
- A git repository with commit history, initialised with `wv init-repo`
- GitHub CLI (`gh`) authenticated, for the `--gh` steps

## 1. Audit: map commits to planned tasks

Inputs are the git log, any existing plan or docs, and `wv list --all --json`.

```bash
git log --since="YYYY-MM-DD" --format="%H %s" > "$SCRATCH/commits.txt"   # any scratch path
```

Read an existing PLAN.md for its sprint structure and task descriptions. Without one, start from the
template and fill it by grouping commits by feature or sprint:

```bash
wv plan --template > docs/PLAN-enrichment.md
```

Import one sprint at a time, previewing first:

```bash
wv plan docs/PLAN.md --sprint=N --gh --dry-run
wv plan docs/PLAN.md --sprint=N --gh
```

For each sprint, build a commit-to-task table with a confidence per row:

| Commit SHA | Message            | Maps to task        | Confidence |
| ---------- | ------------------ | ------------------- | ---------- |
| abc1234    | fix: geodesic calc | Sprint 12: geodesic | HIGH       |

- **HIGH**: the commit message names the task
- **MEDIUM**: the commit touches files the task concerns
- **LOW**: an indirect relationship; flag it for manual review

## 2. Assess: determine each task's status

For each task node, check three kinds of evidence:

1. **Code presence**: does the implementation exist? (`wv search --code "<concept>"`, or grep)
2. **Tests**: do tests for it exist, and do they pass?
3. **Commits**: does a mapped commit complete the work?

| Status             | Evidence                                    |
| ------------------ | ------------------------------------------- |
| **Done**           | code exists, tests pass, commits identified |
| **Partially done** | code exists but is incomplete or untested   |
| **Not started**    | no implementation found                     |
| **N/A**            | superseded or no longer relevant            |

Record the evidence on the node. `wv update --metadata` merges into existing metadata and drops no
field:

```bash
wv update <id> --metadata='{
  "status_detail": "DONE -- implementation in src/module.py:120-180, tested in tests/test_module.py",
  "commit_refs": ["abc1234", "def5678"],
  "verification_method": "pytest tests/test_module.py passed"
}'
```

## 3. Enrich: aliases, learnings and edges

```bash
wv update <id> --alias=geodesic-fix                  # short, memorable name
wv link <task-id> <epic-id> --type=implements        # every node has a parent epic
wv block <task-id> --by=<blocker-id>                 # dependencies between tasks
wv done <id> --learning="decision: use pyproj.Geod for geodesic calculations | pattern: prefer vetted geospatial libraries over manual trig for accuracy | pitfall: manual trig shortcuts drift on longer routes"
wv batch-done <id1> <id2> <id3> --learning="sprint N complete"   # a group of related done tasks
```

`wv bulk-update` applies metadata to many nodes from JSON on stdin when one learning per node is not
needed.

## 4. Verify: render, check, sync

```bash
wv tree --mermaid <epic-id>   # done green, active gold, blocked red, todo gray
wv health                     # target 100/100; fix orphans and missing edges now
wv sync --gh                  # GitHub issue bodies carry the same Mermaid rendering
git add .weave/ && git commit -m "chore: enriched graph for sprint N" && git push
```

MCP `weave_tree` with `mermaid=true` returns the same Mermaid output. The graph is what makes Weave
more than a flat checklist: render it when an epic is created, during the work and at completion.

## 5. Iterate, sprint by sprint

Process sprints in order, running steps 1 to 4 for each, and commit and push after every sprint so
progress survives a lost session. Keep a session to 4 or 5 sprints: context limits end sessions
mid-task. Run `wv health` after each batch of operations.

## 6. Report

At the end of a session:

1. Run `wv status` and `wv health`.
2. Render the final Mermaid graph for all epics.
3. List the nodes that need manual review (LOW-confidence mappings).
4. Capture session-level learnings.

A report has this shape:

```text
Audit:   180 commits since 2025-06-01, 12 sprints in PLAN.md, 156/180 mapped to 79 tasks (87%)
Assess:  66 done, 8 partially done, 5 not started, 0 N/A
Enrich:  79 aliases, 66 closed with learnings, 77 edges (66 implements + 11 blocks)
Verify:  health 100/100, Mermaid for 12 epics, 79 issues synced
Iterate: 12 sprints in 3 sessions
Review:  3 LOW-confidence mappings flagged
```
