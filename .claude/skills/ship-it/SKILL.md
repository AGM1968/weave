---
name: ship-it
description:
  "When claiming a task, define done criteria upfront. Prevents perfectionism loops and scope creep
  by establishing clear completion boundaries."
---

# Ship It — Done Criteria Gate

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator. Use `/weave` instead
> for the full graph-first workflow. Direct invocation is deprecated and may be removed in a future
> release.

**Trigger:** When setting a node to `active` status (`wv update <id> --status=active`).

**Purpose:** Address failure mode #5 (no definition of done). Establishes clear, testable completion
criteria before implementation begins.

## Instructions

When invoked with a node ID (`/ship-it <wv-id>`):

### 1. Define Done Criteria

Create 3-5 testable criteria that define "complete":

- Each criterion must be binary (done or not done)
- Each must be verifiable (how do we check?)
- Focus on outcomes, not activities

**Good criteria:**

- "Login form accepts email and password"
- "Error message displays on invalid credentials"
- "Successful login redirects to /dashboard"

**Bad criteria:**

- "Make login work" (too vague)
- "Write good code" (not testable)
- "Improve UX" (subjective)

### 2. Define Non-Goals

Explicitly state what is OUT of scope:

- Prevents "while I'm here" additions
- Creates permission to say "that's a separate task"
- Reduces decision fatigue during implementation

### 3. Record in Metadata

```bash
wv update <id> --metadata='{
  "done_criteria": [
    "Criterion 1: specific testable outcome",
    "Criterion 2: specific testable outcome",
    "Criterion 3: specific testable outcome"
  ],
  "non_goals": [
    "Explicitly out of scope item 1",
    "Explicitly out of scope item 2"
  ],
  "acceptance_test": "How to verify all criteria are met"
}'
```

### 4. Confirm Before Proceeding

Output the criteria and ask for confirmation before implementation:

- **Ready to implement:** Criteria are clear and agreed
- **Needs refinement:** Criteria are unclear or incomplete
- **Scope too large:** Break into smaller tasks

## Output Format

**Example output:**

- **Task:** wv-a1b2 — Add user authentication
- **Done when:**
  1. Login form validates email format
  2. Password requires 8+ characters
  3. Failed login shows error message
  4. Successful login creates session cookie
  5. Protected routes redirect to /login
- **Not doing:**
  - Password reset flow (separate task)
  - OAuth providers (future feature)
  - Rate limiting (infrastructure task)
- **Acceptance test:** Manual login with valid/invalid credentials

## NEVER

- Start implementation without defined done criteria
- Add criteria mid-implementation (create new task instead)
- Include subjective criteria ("make it better")
- Scope creep into non-goals during implementation

## ALWAYS

- Define criteria BEFORE writing code
- Keep criteria list to 3-7 items (more = split the task)
- Include at least one non-goal to clarify boundaries
- Review criteria when task takes longer than expected

## Scope Check

If during implementation you discover:

- **New requirement:** Add as separate `wv add` node, not to current criteria
- **Blocker:** Update node metadata, consider blocking relationship
- **Scope creep:** Check against non-goals, defer if out of scope

```bash
# Discovered new work during implementation

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.

wv add "Handle edge case: expired session" --metadata='{"type":"task","priority":2}'
# Don't add to current task's done_criteria

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.

```

## Integration

This skill is called by:

- `/fix-issue` — Step 3 (Plan) should invoke `/ship-it`
- Pre-claim hook — Auto-invokes for features/epics
- Manual invocation when claiming any significant work

## Examples

### Example 1: Bug Fix

```bash
/ship-it wv-b2c3

# Task: Fix login timeout issue

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.

# Done criteria:

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.

#   1. Session timeout extended to 30 minutes

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.

#   2. Activity refreshes session expiry

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.

#   3. Existing tests pass

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.

# Non-goals:

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.

#   - Remember me functionality

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.

#   - Session analytics

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.

# Acceptance: Login, wait 25 min with activity, still logged in

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.

```

### Example 2: Feature

```bash
/ship-it wv-d4e5

# Task: Add CSV export to dashboard

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.

# Done criteria:

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.

#   1. Export button visible on dashboard

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.

#   2. Click downloads CSV file

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.

#   3. CSV contains all visible columns

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.

#   4. Filename includes date

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.

# Non-goals:

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.

#   - PDF export

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.

#   - Email delivery

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.

#   - Custom column selection

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.

# Acceptance: Click export, verify CSV opens in spreadsheet

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.

```

### Example 3: Refactor

```bash
/ship-it wv-f6g7

# Task: Extract auth middleware

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.

# Done criteria:

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.

#   1. Auth logic moved to middleware/auth.ts

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.

#   2. All routes use middleware instead of inline checks

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.

#   3. Existing tests pass unchanged

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.

#   4. No new dependencies added

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.

# Non-goals:

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.

#   - New auth features

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.

#   - Performance optimization

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.

#   - Additional test coverage

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.

# Acceptance: All auth tests green, manual login works

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.

```

## Metadata Schema

```json
{
  "done_criteria": [
    "Session timeout extended to 30 minutes",
    "Activity refreshes session expiry",
    "Existing tests pass"
  ],
  "non_goals": ["Remember me functionality", "Session analytics"],
  "acceptance_test": "Login, wait 25 min with activity, still logged in",
  "scope_size": "small|medium|large"
}
```

## Completion Checklist

Before closing a task, verify against done criteria:

```bash
# Review criteria

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.

wv show <id>

# Check each criterion

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.

# Criterion 1: done

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.

# Criterion 2: done

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.

# Criterion 3: done

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.


# All criteria met → proceed to /wv-verify-complete → wv done

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.

```

## Related Skills

- **/wv-verify-complete** — Verify criteria are actually met
- **/pre-mortem** — Identify risks before implementation
- **/wv-guard-scope** — Enforce scope during implementation
