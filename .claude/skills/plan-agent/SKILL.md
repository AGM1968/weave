---
name: plan-agent
description: "Automates cold-start graph enrichment from a repo into Weave by auditing commits, generating PLAN.md, enriching nodes, and syncing GitHub. Use when onboarding an existing repo or bulk-enriching a graph for the first time."
---

# /plan-agent -- Cold-Start Graph Builder

**Purpose:** Automate the ~200 manual steps needed to go from an existing repo with commit history
to a fully enriched Weave graph with aliases, learnings, metadata, Mermaid graphs, and GitHub sync.

**Trigger:** When onboarding an existing repository into Weave for the first time, or when bulk
enriching a graph from commit history.

## Prerequisites

- Weave installed (`wv health` returns OK)
- Git repo with commit history
- GitHub CLI (`gh`) authenticated
- Repository initialized with `wv-init-repo`

## Phases

### Phase 1: AUDIT -- Map commits to planned tasks

**Input:** Git log, existing PLAN.md (or docs), and `wv list --all --json`.

**Steps:**

1. Extract commit history with metadata:

   ```bash
   git log --oneline --since="YYYY-MM-DD" --format="%H %s" > /tmp/commits.txt
   ```

2. If a PLAN.md exists, parse it to understand sprint structure and task descriptions. If no plan
   exists, generate one:

   ```bash
   wv plan --template > docs/PLAN-enrichment.md
   ```

   Then populate it from commit history patterns (group commits by feature/sprint).

3. Import plan into graph:

   ```bash
   wv plan docs/PLAN.md --sprint=N --gh --dry-run    # preview first
   wv plan docs/PLAN.md --sprint=N --gh               # import
   ```

4. For each sprint, build a commit-to-task mapping table:

   | Commit SHA | Message            | Maps to Task        | Confidence |
   | ---------- | ------------------ | ------------------- | ---------- |
   | abc1234    | fix: geodesic calc | Sprint 12: geodesic | HIGH       |

   Confidence levels:
   - HIGH: commit message directly references the task
   - MEDIUM: commit touches files relevant to the task
   - LOW: indirect relationship, needs manual review

### Phase 2: ASSESS -- Determine task status

For each task node, determine status by examining:

1. **Code presence:** Does the implementation exist in the codebase?

   ```bash
   grep -rn "relevant_function" src/    # search for implementation
   ```

2. **Test coverage:** Do tests exist and pass?

   ```bash
   find tests/ -name "*relevant*"       # search for test files
   ```

3. **Commit evidence:** Is there a commit that completes this work? Reference the commit-to-task
   mapping from Phase 1.

Status mapping:

- **DONE:** Code exists, tests pass, commit links identified
- **PARTIALLY DONE:** Code exists but incomplete or untested
- **NOT STARTED:** No implementation found
- **N/A:** Task is superseded or no longer relevant

Record findings in metadata:

```bash
wv update <id> --metadata='{
  "status_detail": "DONE -- implementation in src/module.py:120-180, tested in tests/test_module.py",
  "commit_refs": ["abc1234", "def5678"],
  "verification_method": "pytest tests/test_module.py passed"
}'
```

### Phase 3: ENRICH -- Add aliases, learnings, and references

For each node:

1. **Set alias** (short, memorable name):

   ```bash
   wv update <id> --alias=geodesic-fix
   ```

2. **Add learning** when closing done nodes:

   ```bash
   wv done <id> --learning="pattern: pyproj.Geod replaces manual trig for geodesic accuracy"
   ```

3. **Link to parent epic:**

   ```bash
   wv link <task-id> <epic-id> --type=implements
   ```

4. **Set blocking edges** where tasks have dependencies:

   ```bash
   wv block <task-id> --by=<blocker-id>
   ```

5. Use `wv batch-done` for groups of related completed tasks:

   ```bash
   wv batch-done wv-a1b2 wv-c3d4 wv-e5f6 --learning="sprint N complete"
   ```

### Phase 4: VERIFY -- Render and validate

1. **Render Mermaid graph** for each epic:

   ```bash
   wv tree --mermaid <epic-id>
   ```

   Or use MCP `weave_tree` with `mermaid=true` for the same output:
   - done = green, active = gold, blocked = red, todo = gray
   - GitHub issue bodies use this same output via `wv sync --gh`

2. **Health check:**

   ```bash
   wv health    # target: 100/100
   ```

   Fix any issues (orphans, missing edges).

3. **Sync to GitHub:**

   ```bash
   wv sync --gh
   git add -A && git commit -m "chore: enriched graph for sprint N"
   git push
   ```

### Phase 5: ITERATE -- Repeat per sprint

Process sprints in order. For each sprint:

1. Run Phase 1-4
2. Commit and push after each sprint (incremental progress)
3. Update the Mermaid progress graph after each sprint

### Phase 6: REPORT -- Session summary

At session end:

1. Run `wv status` and `wv health`
2. Render final Mermaid graph showing all epics
3. List any nodes that need manual review (LOW confidence mappings)
4. Capture session-level learnings

## Automation Targets

These are the highest-value automation opportunities identified from dogfooding:

1. **Commit-to-task mapping:** Parse git log and match commits to task descriptions using keyword
   overlap. Currently requires manual inspection of each commit.

2. **Code-presence scanning:** For each task, search the codebase for relevant
   functions/classes/patterns to auto-determine DONE/NOT-STARTED status.

3. **Batch metadata enrichment:** Apply aliases, learnings, and status_detail to multiple nodes in
   one operation. The `wv update --metadata` merge (not replace) and `wv batch-done` features enable
   this.

4. **Mermaid generation:** `wv tree --mermaid` generates the graph automatically. Use
   MCP `weave_tree` with `mermaid=true` for the same Mermaid output. GitHub issue bodies
   also use this same rendering via `wv sync --gh` for consistency.

## Anti-Patterns (from dogfooding)

- **Writing code instead of mapping:** The plan-agent should ENRICH the graph, not implement code
  fixes. If a task is "fix X", the agent records that X is or isn't fixed -- it doesn't fix X.

- **Replacing metadata:** Always use merge semantics (`wv update --metadata` now merges by default).
  Never lose existing metadata fields.

- **Skipping Mermaid graphs:** The graph visualization is what makes Weave valuable over flat
  checklists. Generate Mermaid at epic creation, during work, and at completion.

- **Orphan nodes:** Every node must be linked to a parent epic. Run `wv health` after each batch of
  operations.

- **Giant sessions:** Limit to 4-5 sprints per session. Context limits kill sessions mid-task.
  Commit and push incrementally.

## Example Invocation

```text
/plan-agent earth-engine-analysis --since=2025-06-01

Phase 1: AUDIT
  Found 180 commits since 2025-06-01
  Found 12 sprints in existing PLAN.md
  Mapped 156/180 commits to 79 tasks (87% coverage)

Phase 2: ASSESS
  66 DONE, 8 PARTIALLY DONE, 5 NOT STARTED, 0 N/A

Phase 3: ENRICH
  79 aliases set
  66 nodes closed with learnings
  77 edges created (66 implements + 11 blocks)

Phase 4: VERIFY
  Health: 100/100
  Mermaid graphs rendered for 12 epics
  GitHub sync: 79 issues synced

Phase 5: ITERATE
  12 sprints processed in 3 sessions

Phase 6: REPORT
  Final graph: 79 nodes, 77 edges, 100/100 health
  3 LOW-confidence mappings flagged for review
```
