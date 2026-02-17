---
name: breadcrumbs
description:
  "Leave context notes for future sessions. Records current state, what was tried, and next steps.
  Prevents context rot across session boundaries."
---

# Breadcrumbs — Session Memory Capsule

**Note:** This skill remains user-accessible as an exception to the orchestrator consolidation.
Breadcrumbs serves an orthogonal purpose (preserving context across sessions) that's independent of
the Weave workflow for task execution.

**Trigger:** Before context compaction, at session end, or when switching between tasks.

**Purpose:** Address failure mode #6 (context rot over long sessions). Creates a compact, structured
snapshot that preserves working context across session boundaries or compaction events.

## Instructions

When invoked (`/breadcrumbs` or `/breadcrumbs <wv-id>`):

### 1. Capture Current State

Record where we are right now:

- **Current goal:** One sentence — what are we trying to accomplish?
- **Current state:** What's implemented/done so far?
- **Blocking issue:** What's preventing progress (if any)?

### 2. Capture Context

Record what we know:

- **Key files:** Which files are we working in?
- **Key decisions:** What have we decided and why?
- **Key discoveries:** What did we learn during this session?

### 3. Capture Next Steps

Record what comes next:

- **Immediate next:** The very next action to take
- **Remaining work:** What else needs to be done
- **Open questions:** Unresolved issues that need answers

### 4. Store in Node Metadata

```bash
wv update <id> --metadata='{
  "breadcrumbs": {
    "goal": "Add rate limiting to API endpoints",
    "state": "Middleware created, not yet integrated",
    "blocking": null,
    "files": ["src/middleware/rateLimit.ts", "src/app.ts"],
    "decisions": ["Using sliding window algorithm", "Redis for distributed state"],
    "discoveries": ["Existing middleware uses different pattern than expected"],
    "next": "Integrate middleware into app.ts",
    "remaining": ["Add tests", "Update docs"],
    "questions": ["What rate limits for premium users?"],
    "updated_at": "2026-02-03T08:45:00Z"
  }
}'
```

## Output Format

**Example output:**

```markdown
## Breadcrumbs: wv-a1b2

**Goal:** Add rate limiting to API endpoints

**State:** Middleware created, not yet integrated

- [x] Rate limit middleware written
- [x] Redis connection configured
- [ ] Integration with app.ts
- [ ] Tests

**Files touched:**

- src/middleware/rateLimit.ts (new)
- src/config/redis.ts (modified)

**Key decisions:**

- Sliding window algorithm (more fair than fixed window)
- Redis for state (supports multiple server instances)

**Discoveries:**

- Existing middleware uses callback pattern, ours uses async/await
- Need adapter or update existing middleware

**Next step:** Integrate middleware into app.ts after adapting pattern

**Open questions:**

- Different limits for premium vs free users?
- Should rate limit apply to authenticated endpoints only?

**Updated:** 2026-02-03 08:45
```

## NEVER

- End a session without updating breadcrumbs for active work
- Leave breadcrumbs vague ("was working on stuff")
- Skip the "next step" — this is the most important part
- Let breadcrumbs get stale (update when state changes significantly)

## ALWAYS

- Update breadcrumbs before context compaction
- Include specific file paths (not "the config file")
- Record the immediate next action (not just "continue work")
- Timestamp the breadcrumbs

## Compaction Protocol

When pre-compact-context hook runs:

1. For each active node, generate breadcrumbs
2. Store in node metadata
3. Include in compaction context

This ensures the compressed context retains working state.

## Session Handoff Protocol

When ending a session with work in progress:

1. Run `/breadcrumbs` for active nodes
2. Include handoff summary in `/close-session`
3. Next session reads breadcrumbs from `wv show <id>`

## Integration

This skill is called by:

- `pre-compact-context.sh` hook — Auto-runs before compaction
- `/close-session` — Part of session end protocol
- Manual invocation when switching tasks or taking a break

## Examples

### Example 1: Mid-Feature Breadcrumbs

```bash
/breadcrumbs wv-b2c3

# Goal: Implement OAuth2 login
# State: Authorization flow working, token exchange failing
# Files: src/auth/oauth.ts, src/auth/tokens.ts
# Decisions: Use PKCE for security
# Next: Debug token exchange - check callback URL config
# Questions: Should we support refresh tokens?
```

### Example 2: Debugging Session

```bash
/breadcrumbs wv-d4e5

# Goal: Fix memory leak in data processor
# State: Identified leak source, testing fix
# Files: src/processor/stream.ts
# Discoveries: Event listeners not cleaned up on error path
# Next: Add cleanup in finally block, run memory profiler
# Questions: Are there other similar patterns elsewhere?
```

### Example 3: Investigation Breadcrumbs

```bash
/breadcrumbs wv-f6g7

# Goal: Understand why tests are flaky
# State: Narrowed to timing issue in async tests
# Files: tests/integration/api.test.ts
# Discoveries: Race condition between setup and test execution
# Next: Add explicit waits or synchronization
# Remaining: Check other integration tests for same pattern
```

## Metadata Schema

```json
{
  "breadcrumbs": {
    "goal": "One sentence goal",
    "state": "Current progress description",
    "blocking": "Current blocker or null",
    "files": ["list", "of", "files"],
    "decisions": ["Decision 1: reason", "Decision 2: reason"],
    "discoveries": ["Things learned"],
    "next": "Immediate next action",
    "remaining": ["Other work items"],
    "questions": ["Open questions"],
    "updated_at": "ISO timestamp"
  }
}
```

## Breadcrumbs Quality Checklist

Good breadcrumbs are:

- [ ] **Specific:** Contains file paths, not vague references
- [ ] **Actionable:** Next step is clear and executable
- [ ] **Complete:** Captures decisions and discoveries
- [ ] **Current:** Updated within last significant change
- [ ] **Compact:** Fits in ~200 tokens

## Recovery Protocol

When starting a session and finding stale breadcrumbs:

1. Read existing breadcrumbs: `wv show <id>`
2. Verify state matches reality: check files mentioned
3. Update breadcrumbs if state has changed
4. Continue from "next step" or reassess

## Related Skills

- **/close-session** — Uses breadcrumbs for handoff
- **/wv-detect-loop** — Breadcrumbs help track failed approaches
- **/ship-it** — Done criteria complement breadcrumbs
