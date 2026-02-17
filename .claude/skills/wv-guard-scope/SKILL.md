---
name: wv-guard-scope
description:
  "Enforce scope boundaries and codebase conventions during implementation. Prevents while I'm here
  additions and pattern mismatches."
---

# wv-guard-scope — Scope and Convention Gate

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator. Use `/weave` instead
> for the full graph-first workflow. Direct invocation is deprecated and may be removed in a future
> release.

**Trigger:** During implementation when tempted to:

- Add features beyond current task scope
- Refactor unrelated code
- Introduce new patterns/libraries when existing ones work
- "Modernize" legacy code while fixing bugs

**Purpose:** Address failure mode #7 (imposes preferences instead of matching patterns). Keeps work
focused on task boundaries and consistent with existing codebase patterns.

## Instructions

When invoked during implementation (`/wv-guard-scope` or when scope drift detected):

### 1. Check Task Scope

Review the original task definition:

```bash
# Review done criteria

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.

wv show <current-task-id>

# Questions to ask:

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.

# - Does this change relate to the task text?

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.

# - Is it in the done_criteria list?

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.

# - Was it explicitly excluded in non_goals?

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.

```

**If outside scope:** Create new task, don't expand current one.

### 2. Check Codebase Conventions

Scan existing code for patterns:

- **Naming:** Do other files use `camelCase` or `snake_case`?
- **Error handling:** Try/catch or return codes?
- **Imports:** Relative (`./foo`) or absolute (`@/foo`)?
- **Libraries:** What's already used for this purpose?
- **Architecture:** Where do similar features live?

**Match existing patterns, even if you don't like them.**

### 3. Identify Scope Violations

Common violations:

| Violation                     | Example                        | Fix                                 |
| ----------------------------- | ------------------------------ | ----------------------------------- |
| **Feature creep**             | "Also add error notifications" | Create wv-XXXX for notifications    |
| **Refactor during fix**       | "Let's clean up this function" | Fix bug only, new task for refactor |
| **Library introduction**      | "Use lodash instead of native" | Use existing pattern unless broken  |
| **Modern patterns in legacy** | "Convert to async/await"       | Match existing promise style        |
| **Perfectionism**             | "Add 10 edge case handlers"    | Check done_criteria, ship first     |

### 4. Make the Call

**Stay in lane:**

- Fix only what's in scope
- Match existing conventions
- Create new tasks for improvements

**Exception (rare):**

- Blocker preventing task completion
- Security/data loss risk
- Must document why in commit message

## Output Format

When scope drift detected, output:

```text
 Scope Drift Detected

Current task: wv-XXXX — Fix login timeout
Proposed change: Add password strength validation

Analysis:
Not in done_criteria
Listed in non_goals
Should be: Create wv-YYYY for password validation

Action: Stay focused on timeout fix only
```

## NEVER

- Refactor while fixing bugs
- Add features while building features
- Introduce new libraries when existing ones work
- Modernize legacy code patterns "while you're there"
- Improve code quality outside the task scope

## ALWAYS

- Check done_criteria before adding anything
- Match existing codebase patterns and conventions
- Create new tasks for "while I'm here" urges
- Finish current task before starting discovered work
- Document convention choices in commit messages

## Examples

### Example 1: Feature Creep Prevention

```text
Task: Add CSV export button
Temptation: "Also add PDF and Excel export"

/wv-guard-scope check:
- done_criteria: CSV export only
- non_goals: Other formats listed
- Action: Create wv-XXXX "Add PDF export" (separate task)
```

### Example 2: Convention Matching

```text
Task: Fix date parsing bug
Codebase uses: moment.js for all date handling
Temptation: "Let's use modern date-fns"

/wv-guard-scope check:
- Existing pattern: moment.js in 47 files
- No blocker: moment works for this fix
- Action: Use moment.js to match codebase
- Note: Can propose date-fns migration separately
```

### Example 3: Refactor Temptation

```text
Task: Fix null pointer in getUserData
Temptation: "This function is messy, let's refactor it"

/wv-guard-scope check:
- done_criteria: Fix null pointer only
- Refactor not blocking fix
- Action: Add null check, create wv-YYYY "Refactor getUserData"
```

### Example 4: Pattern Mismatch

```text
Task: Add error handling to API endpoint
Codebase uses: Return codes {success: bool, error: string}
Temptation: "Exceptions are better, let's use try/catch"

/wv-guard-scope check:
- Pattern: 23 endpoints use return codes
- Not broken: Works fine
- Action: Use return codes to match existing pattern
```

## Integration

This skill is called:

- Manually during implementation when scope drift noticed
- By `/fix-issue` as reminder to check scope
- When tempted to add "just one more thing"

## Related Skills

- **/ship-it** — Defines scope upfront to prevent drift
- **/wv-clarify-spec** — Clarifies requirements before starting
- **/zero-in** — Focused search prevents over-exploration
