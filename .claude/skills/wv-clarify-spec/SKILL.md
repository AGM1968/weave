---
name: wv-clarify-spec
description: "Clarifies vague requirements before implementation and turns unclear tasks into actionable specifications. Use when acceptance criteria, scope, or constraints are ambiguous."
---

# wv-clarify-spec — Requirements Clarification

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator. Use `/weave` instead
> for the full graph-first workflow. Direct invocation is deprecated and may be removed in a future
> release.

**Trigger:** Before starting work when:

- Task description is vague ("make it better", "improve performance")
- Success criteria unclear ("users should like it")
- Multiple interpretations possible
- You're about to assume what user wants

**Purpose:** Prevent wasted work on wrong assumptions. Forces explicit clarification of vague
requirements before code is written.

## Instructions

When invoked with unclear requirements (`/wv-clarify-spec` or before claiming vague task):

### 1. Identify Ambiguity

Questions that reveal vagueness:

```text
Can I describe this task in one concrete sentence?
Do I know exactly what "done" looks like?
Would two developers implement this differently?
Am I about to assume user intent?
```

If any answer is uncertain → clarify first.

### 2. Apply 5W+C Framework

Ask systematically:

**WHAT exactly needs to happen?**

- Specific behavior, not abstract goal
- Input → Process → Output
- Edge cases included?

**WHY is this needed?**

- Real user problem being solved
- Alternative solutions considered?
- What happens if we don't do this?

**WHO is the user?**

- Specific persona or role
- Their context and constraints
- What are they trying to accomplish?

**WHEN does this apply?**

- Always, or specific conditions?
- Dependencies on other features?
- Timing constraints?

**WHERE in the system?**

- Which components affected?
- Integration points?
- Does it match existing patterns?

**CONSTRAINTS?**

- Performance requirements?
- Compatibility needs?
- Technical limitations?

### 3. Transform to Specification

Convert vague → concrete:

**Vague:** "Make login faster" **Clarified:**

- What: Reduce login API response time from 2s to <500ms
- Why: Users complain about slow login (ticket #123)
- Who: All authenticated users
- When: Every login attempt
- Where: /api/auth/login endpoint
- Constraints: Must maintain current security (JWT, bcrypt)

### 4. Confirm or Escalate

**If you can clarify:** Document in task metadata, proceed **If you can't:** Use `AskUserQuestion`
to get clarification from user

## Output Format

When clarifying a vague requirement:

```markdown
## Rubber Duck Analysis: wv-XXXXXX

**Original (vague):** "Improve the dashboard"

**Clarified:**

- WHAT: Add last-login timestamp to user dashboard card
- WHY: Users can't tell if their session is stale (security concern)
- WHO: All logged-in users viewing dashboard
- WHEN: On every dashboard load
- WHERE: Dashboard.tsx user card component
- CONSTRAINTS: Must use existing auth service, no new API calls

**Specification:**

1. Display "Last login: [timestamp]" below username
2. Format: "2 hours ago" (relative time using date-fns)
3. Fetch from existing user.lastLogin field
4. Gray text, 12px font, matches existing style

**Ready to implement:** Yes
```

## NEVER

- Start coding with vague requirements
- Assume what "better" or "improve" means
- Guess user intent without asking
- Accept "you know what I mean" as specification

## ALWAYS

- Challenge vague language ("better" → "specific metric?")
- Document clarifications in task metadata
- Use AskUserQuestion when you can't clarify alone
- Confirm specification before writing code

## Examples

### Example 1: Vague Performance Request

```text
Original: "The API is too slow"

Rubber Duck:
- WHAT slow? All endpoints or specific one? → /api/search
- HOW slow? → 5 seconds average response time
- WHY problem? → Users abandoning search
- WHAT target? → <1 second p95
- CONSTRAINTS? → Can't change database schema this sprint

Specification:
Optimize /api/search endpoint from 5s to <1s p95 response time
by adding Redis cache layer (no schema changes).

Ready: Yes
```

### Example 2: Ambiguous Feature

```text
Original: "Add notifications"

Rubber Duck:
- WHAT notifications? → Email, push, in-app? → In-app only
- WHEN shown? → Real-time or batch? → Real-time on events
- WHICH events? → Comments, mentions, or all? → Comments only
- HOW persist? → Database or ephemeral? → 30-day retention
- WHO sees? → All users or opt-in? → Opt-in via settings

Specification:
Add real-time in-app notifications for comment events.
Store in notifications table (30d TTL). Opt-in via user settings.
WebSocket for live updates, badge count in header.

Ready: Yes
```

### Example 3: Can't Clarify Alone

```text
Original: "Make the UI more modern"

Rubber Duck attempts:
- WHAT modern? → Don't know specific changes wanted
- WHY now? → Unclear business driver
- WHICH pages? → All or specific areas?

Cannot clarify → Use AskUserQuestion:

"Which aspects need modernizing?"
Options:
1. Color scheme (current is blue/gray)
2. Component style (buttons, cards)
3. Layout/spacing
4. Typography

[Defers to user for decision]
```

## Integration

This skill is called:

- Before claiming tasks with vague descriptions
- When `/ship-it` criteria are unclear
- Before `/fix-issue` planning when problem is ambiguous
- Proactively when you notice assumption-making

## Related Skills

- **/ship-it** — Uses clarified requirements to define done criteria
- **/wv-guard-scope** — Enforces clarified scope during implementation
- **/sanity-check** — Validates assumptions after clarification
