---
name: wv-decompose-work
description: "Breaks down an epic into feature and task nodes with proper dependencies. Use when starting a new epic that needs task decomposition before work can begin."
---

# wv-decompose-work — Epic Breakdown Workflow

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator. Use `/weave` instead for
> the full graph-first workflow. Direct invocation is deprecated and may be removed in a future
> release.

Break down the epic described in: $ARGUMENTS

## Process

### 1. Understand the Epic

Ask clarifying questions if needed:

- What is the end goal of this epic?
- Who are the users/stakeholders?
- What are the success criteria?
- Are there any constraints (technical, timeline, resources)?
- What are the dependencies on other systems/teams?

### 1.5. Pre-Audit: Check Existing Implementation

Before creating nodes, check what is already implemented to avoid duplicate tasks:

```bash
# Recent commits touching related code
git log --oneline -20 -- .

# Search for files matching the epic's keywords
grep -r "<epic-keyword>" . --include="*.py" --include="*.sh" --include="*.ts" -l 2>/dev/null

# List expected implementation directories
ls <expected-dirs> 2>/dev/null
```

**Report findings before proceeding:**

- Already implemented → list files/commits found, mark those tasks as pre-solved
- Not yet implemented → confirm full breakdown is needed

**If significant existing work found:**

→ Show user: "Found `<N>` files / `<Y>` commits that may implement parts of this epic" → Ask:
"Proceed with full breakdown, or skip already-implemented tasks?" → Remove pre-solved items from the
breakdown — do not create nodes for work that is done

> Sprint 11 lesson: T5 ("Seed database") was created as a todo task but `seed_database.py` and
> `migration_002` already existed. Pre-audit would have prevented the duplicate node.

### 2. Identify Features

Break the epic into 3-7 major features:

- Each feature should be a cohesive piece of functionality
- Features should be relatively independent when possible
- Features represent days/weeks of work
- Use metadata: `{"type":"feature","priority":1-5}`

### 3. Break Features into Tasks

For each feature, create 3-10 tasks:

- Each task should be atomic (single unit of work)
- Tasks should be completable in hours, not days
- Tasks should have clear acceptance criteria
- Use metadata: `{"type":"task","priority":1-5}`

### 4. Create Weave Nodes

```bash
# Create epic

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.

EPIC=$(wv add "Epic: $ARGUMENTS" --metadata='{"type":"epic","priority":1}')

# Create features

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.

FEAT1=$(wv add "Feature: [first major capability]" --metadata='{"type":"feature","priority":1}')
FEAT2=$(wv add "Feature: [second major capability]" --metadata='{"type":"feature","priority":2}')
# ... more features

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.


# Create tasks for feature 1

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.

TASK1=$(wv add "Task: [specific implementation]" --metadata='{"type":"task","priority":1}')
TASK2=$(wv add "Task: [specific implementation]" --metadata='{"type":"task","priority":2}')
# ... more tasks

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.


# Repeat for other features

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.

```

### 5. Set Up Dependencies

```bash
# Epic blocked by all features

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.

wv block $EPIC --by=$FEAT1
wv block $EPIC --by=$FEAT2
# ... for all features

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.


# Each feature blocked by its tasks

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.

wv block $FEAT1 --by=$TASK1
wv block $FEAT1 --by=$TASK2
# ... for all tasks

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.


# If tasks depend on each other

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.

wv block $TASK2 --by=$TASK1  # Task 2 depends on Task 1
```

### 6. Visualize the Breakdown

```bash
# Show the full dependency tree

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.

wv path $EPIC --format=chain

# List all nodes in the hierarchy

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.

wv list --status=todo
```

### 7. Document the Plan

Create a summary showing:

- Epic goal and scope
- Features with brief descriptions
- Task breakdown per feature
- Dependency relationships
- Estimated priority order

## Example Breakdown

### Epic: "Build User Dashboard"

**Features:**

1. Dashboard Layout & Navigation
2. Data Visualization Components
3. User Preferences & Settings
4. Real-time Data Updates

<!-- markdownlint-disable MD036 -->

**Feature 1: Dashboard Layout & Navigation**

- Task: Design responsive grid layout
- Task: Implement navigation sidebar
- Task: Add breadcrumb navigation
- Task: Create dashboard header component

**Feature 2: Data Visualization Components**

- Task: Integrate charting library
- Task: Create line chart component
- Task: Create bar chart component
- Task: Add data filtering controls

**Dependencies:**

- Epic blocked by all 4 features
- Feature 1 tasks can run in parallel (mostly)
- Feature 2 tasks depend on charting library task completing first
- Feature 3 depends on Feature 1 (needs layout first)
- Feature 4 depends on Feature 2 (needs visualizations first)

## Output Format

Provide a structured breakdown:

```markdown
# Epic Breakdown: [Epic Name]

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator. Use `/weave` instead for
> the full graph-first workflow. Direct invocation is deprecated and may be removed in a future
> release.

## Epic Node

- **ID**: wv-XXXXXX
- **Description**: [Epic description]
- **Success Criteria**: [What defines completion]

## Features

### Feature 1: [Name]

- **ID**: wv-YYYYYY
- **Description**: [What this feature provides]
- **Priority**: [1-5]
- **Tasks**:
  - wv-ZZZZZZ: [Task description] (Priority: 1)
  - wv-AAAAAA: [Task description] (Priority: 2)
  - ...

### Feature 2: [Name]

...

## Dependency Graph

Epic (wv-XXXXXX) ├── Feature 1 (wv-YYYYYY) │ ├── Task 1.1 (wv-ZZZZZZ) │ ├── Task 1.2 (wv-AAAAAA) │
└── Task 1.3 (wv-BBBB) ├── Feature 2 (wv-CCCC) │ ├── Task 2.1 (wv-DDDD) │ └── Task 2.2 (wv-EEEE) └──
Feature 3 (wv-FFFF) └── Task 3.1 (wv-GGGG)

## Work Queue

Ready to start (in priority order):

1. wv-ZZZZZZ: Task 1.1 [High value, no blockers]
2. wv-AAAAAA: Task 1.2 [Can be done in parallel]
3. wv-DDDD: Task 2.1 [Critical path item]

## Estimated Timeline

- Sprint 1: Features 1 & 2 (10-15 days)
- Sprint 2: Features 3 & 4 (10-12 days)
- Total: ~25 days (assuming 1-2 developers)
```

## Best Practices

### Feature Granularity

**Good feature size:**

- User Authentication (login, signup, password reset)
- Dashboard Analytics (charts, metrics, exports)
- Settings Management (preferences, profile, notifications)

**Too broad:**

- "Complete the application" (should be epic)
- "Build all user features" (needs breakdown)

**Too narrow:**

- "Add one button" (should be task)
- "Fix typo in header" (trivial, no node needed)

### Task Granularity

**Good task size:**

- Create login form component (2-4 hours)
- Implement JWT token validation (2-3 hours)
- Write unit tests for auth service (2-3 hours)

**Too broad:**

- "Build entire auth system" (should be feature)
- "Complete user dashboard" (should be epic)

**Too narrow:**

- "Import React library" (trivial)
- "Add console.log for debugging" (temporary)

### Priority Assignment

**Priority 1 (Critical):**

- Blocks many other tasks
- Core functionality
- High business value
- Required for MVP

**Priority 2 (High):**

- Important functionality
- Blocks some tasks
- Good business value
- Should be in MVP

**Priority 3 (Medium):**

- Useful functionality
- Few dependencies
- Moderate value
- Nice to have in MVP

**Priority 4 (Low):**

- Enhancement
- No blockers
- Low immediate value
- Post-MVP

**Priority 5 (Nice to Have):**

- Polish
- Future consideration
- Can be deferred
- Not in current roadmap

## Common Patterns

### Sequential Dependencies

When tasks must be done in order:

```bash
wv block $TASK3 --by=$TASK2
wv block $TASK2 --by=$TASK1
# Work flows: Task1 → Task2 → Task3

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.

```

### Parallel Work

When tasks can be done independently:

```bash
# No blocking between tasks

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.

# All tasks in feature can be worked on simultaneously

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.

wv block $FEATURE --by=$TASK1
wv block $FEATURE --by=$TASK2
wv block $FEATURE --by=$TASK3
```

### Shared Foundation

When multiple features depend on common groundwork:

```bash
FOUNDATION=$(wv add "Task: Set up shared infrastructure" --metadata='{"type":"task","priority":1}')

wv block $FEAT1 --by=$FOUNDATION
wv block $FEAT2 --by=$FOUNDATION
wv block $FEAT3 --by=$FOUNDATION
# All features wait for foundation

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.

```

### Feature Ordering

When features build on each other:

```bash
wv block $FEAT3 --by=$FEAT2
wv block $FEAT2 --by=$FEAT1
# Feature order: F1 → F2 → F3

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.

```

## Validation

After creating the breakdown, verify:

- [ ] Epic has clear success criteria
- [ ] Features are cohesive and focused
- [ ] Tasks are atomic and actionable
- [ ] Dependencies make logical sense
- [ ] No circular dependencies
- [ ] Priority ordering is rational
- [ ] `wv ready` shows at least one unblocked task
- [ ] `wv path $EPIC` displays full tree

## Next Steps

After breakdown is complete:

1. Review with stakeholders if needed
2. Identify first task to claim: `wv ready`
3. Claim and start work: `wv update wv-XXXXXX --status=active`
4. Follow weave workflow for each task
5. Use `/fix-issue <id>` for structured implementation

## Related Skills

- **/fix-issue** - Implement individual tasks
- **/close-session** - End of session cleanup
- **/weave-audit** - Validate graph structure

## Related Agents

- **weave-guide** - Workflow best practices
- **epic-planner** - Help plan epic structure before breakdown
