---
name: trails
description:
  "Leaves an append-only trail of context notes for future sessions with current state, attempts,
  and next steps. Use when handing off work or ending a session to prevent context rot."
---

# Trails — Session Memory Capsule

**Note:** This skill remains user-accessible as an exception to the orchestrator consolidation.
Trails serve an orthogonal purpose (preserving context across sessions) that's independent of the
Weave workflow for task execution.

**Trigger:** `/trails`. Run before context compaction, at session end, or when switching between
tasks. (The `wv breadcrumbs` CLI remains a back-compat alias for one release; the slash command is
now `/trails`.)

**Purpose:** Address failure mode #6 (context rot over long sessions). Each capsule is appended to
an append-only trail, so the path of how the work evolved — including failed approaches — survives
across session boundaries or compaction events.

## Instructions

When invoked (`/trails` or `/trails <wv-id>`):

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

### 4. Append to the Trail

Trails are **append-only**: each capsule is added as a new entry in `metadata.trails[]`, so the path
of how the work evolved is preserved. Use `wv trails capsule` — do **not** use
`wv update --metadata`, which would overwrite the array rather than append to it. An `at` timestamp
is stamped automatically if you omit it.

```bash
wv trails capsule <id> --json='{
  "goal": "Add rate limiting to API endpoints",
  "state": "Middleware created, not yet integrated",
  "blocking": null,
  "files": ["src/middleware/rateLimit.ts", "src/app.ts"],
  "decisions": ["Using sliding window algorithm", "Redis for distributed state"],
  "discoveries": ["Existing middleware uses different pattern than expected"],
  "next": "Integrate middleware into app.ts",
  "remaining": ["Add tests", "Update docs"],
  "questions": ["What rate limits for premium users?"]
}'
```

The latest entry is the current capsule; `wv show <id>` and the pre-compact hook read newest-first.

## Output Format

**Example output:**

```markdown
## Trail: wv-a1b2

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

- End a session without appending a trail for active work
- Leave a trail entry vague ("was working on stuff")
- Skip the "next step" — this is the most important part
- Let the trail get stale (append when state changes significantly)

## ALWAYS

- Append a trail before context compaction
- Include specific file paths (not "the config file")
- Record the immediate next action (not just "continue work")
- Timestamp the entry

## Compaction Protocol

When pre-compact-context hook runs:

1. For each active node, generate a trail capsule
2. Store in node metadata (`metadata.trails[]`)
3. Include in compaction context

This ensures the compressed context retains working state.

## Session Handoff Protocol

When ending a session with work in progress:

1. Run `/trails` for active nodes
2. Include handoff summary in `/close-session`
3. Next session reads the trail from `wv show <id>`

## Integration

This skill is called by:

- `pre-compact-context.sh` hook — Auto-runs before compaction
- `/close-session` — Part of session end protocol
- Manual invocation when switching tasks or taking a break

## Examples

### Example 1: Mid-Feature Trail

```bash
/trails wv-b2c3

# Goal: Implement OAuth2 login
# State: Authorization flow working, token exchange failing
# Files: src/auth/oauth.ts, src/auth/tokens.ts
# Decisions: Use PKCE for security
# Next: Debug token exchange - check callback URL config
# Questions: Should we support refresh tokens?
```

### Example 2: Debugging Session

```bash
/trails wv-d4e5

# Goal: Fix memory leak in data processor
# State: Identified leak source, testing fix
# Files: src/processor/stream.ts
# Discoveries: Event listeners not cleaned up on error path
# Next: Add cleanup in finally block, run memory profiler
# Questions: Are there other similar patterns elsewhere?
```

### Example 3: Investigation Trail

```bash
/trails wv-f6g7

# Goal: Understand why tests are flaky
# State: Narrowed to timing issue in async tests
# Files: tests/integration/api.test.ts
# Discoveries: Race condition between setup and test execution
# Next: Add explicit waits or synchronization
# Remaining: Check other integration tests for same pattern
```

## Metadata Schema

Trails are stored append-only under `metadata.trails[]` (newest entries read first). Each entry:

```json
{
  "goal": "One sentence goal",
  "state": "Current progress description",
  "blocking": "Current blocker or null",
  "files": ["list", "of", "files"],
  "decisions": ["Decision 1: reason", "Decision 2: reason"],
  "discoveries": ["Things learned"],
  "next": "Immediate next action",
  "remaining": ["Other work items"],
  "questions": ["Open questions"],
  "at": "ISO timestamp"
}
```

Legacy single-snapshot `metadata.breadcrumbs` objects are seeded into `trails[0]` on `cmd_load`.

## Trail Quality Checklist

A good trail entry is:

- [ ] **Specific:** Contains file paths, not vague references
- [ ] **Actionable:** Next step is clear and executable
- [ ] **Complete:** Captures decisions and discoveries
- [ ] **Current:** Appended at the last significant change
- [ ] **Compact:** Fits in ~200 tokens

## Recovery Protocol

When starting a session and finding a stale trail:

1. Read the existing trail: `wv show <id>`
2. Verify state matches reality: check files mentioned
3. Append a fresh entry if state has changed
4. Continue from "next step" or reassess

## Related Skills

- **/close-session** — Uses trails for handoff
- **/wv-detect-loop** — The append-only trail makes "track failed approaches" real
- **/ship-it** — Done criteria complement trails
