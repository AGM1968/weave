---
name: wv-detect-loop
description: "When stuck in a loop of failed approaches, stop retrying and try a different strategy. Prevents infinite loops on the same failed approach."
---

# Detect Loop — Loop Breaker

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator. Use `/weave` instead
> for the full graph-first workflow. Direct invocation is deprecated and may be removed in a future
> release.

**Trigger:** After 2-3 failed attempts at the same approach, or when making repeated edits to the
same file without progress.

**Purpose:** Address failure mode #4 (infinite loops on failed approaches). Forces strategic
reassessment instead of continued retrying.

## Instructions

When invoked (`/wv-detect-loop` or `/wv-detect-loop <wv-id>`):

### 1. Acknowledge the Loop

Stop. Recognize the pattern:

- Same error appearing multiple times
- Same file edited repeatedly without resolution
- Time spent exceeds estimate with no progress
- Frustration/thrashing signal

### 2. Document Failed Attempts

List what has been tried:

```markdown
## Failed Approaches

1. **Attempt 1:** [What was tried]
   - Result: [What happened]
   - Why it failed: [Root cause if known]

2. **Attempt 2:** [What was tried]
   - Result: [What happened]
   - Why it failed: [Root cause if known]

3. **Attempt 3:** [What was tried]
   - Result: [What happened]
   - Why it failed: [Root cause if known]
```

### 3. Analyze the Pattern

Ask:

- Are we solving the right problem?
- Are we missing context or information?
- Is there a simpler approach?
- Should we step back and understand more?

### 4. Generate Alternative Strategies

List 2-3 fundamentally different approaches:

| Strategy      | Pros | Cons | Effort |
| ------------- | ---- | ---- | ------ |
| Alternative 1 | ...  | ...  | S/M/L  |
| Alternative 2 | ...  | ...  | S/M/L  |
| Alternative 3 | ...  | ...  | S/M/L  |

### 5. Choose Smallest Falsifiable Experiment

Pick the approach that:

- Tests a key assumption quickly
- Has lowest cost to try
- Gives clear signal (works/doesn't work)

### 6. Decision Options

- **Pivot:** Try different approach
- **Investigate:** Need more understanding before continuing
- **Split:** Break problem into smaller pieces
- **Escalate:** Ask for help / create blocking node
- **Defer:** Come back with fresh context

## Output Format

**Example output:**

**Stuck on:** wv-a1b2 — Fix authentication timeout

**Time spent:** 45 minutes (estimate was 30)

**Failed approaches:**

1. Increased timeout value → Still timing out
2. Added retry logic → Same error, just delayed
3. Checked network config → All settings correct

**Pattern:** Treating symptom (timeout) not cause

**Root cause hypothesis:** Token refresh failing silently

**Next experiment:** Add logging to token refresh, verify tokens are valid

**Decision:** Investigate (add debug logging before more fixes)

## NEVER

- Retry the exact same approach more than twice
- Keep editing the same file without understanding why previous edits failed
- Assume "one more try" will work
- Continue past 2x the estimated time without reassessing

## ALWAYS

- Stop and run `/wv-detect-loop` after 2-3 failed attempts
- Document what was tried (prevents re-trying same thing)
- Consider if we're solving the right problem
- Try the smallest possible experiment next

## Loop Detection Heuristics

Recognize you're in a loop when:

- Same error message 3+ times
- Same file edited 4+ times in sequence
- Same command run 3+ times with same failure
- Time spent > 2x estimate
- Emotional signal: frustration, "just one more try"

## Escalation Paths

### Path 1: Need More Information

```bash
# Create investigation node
wv add "Investigate: understand X behavior" --metadata='{"type":"task","priority":1}'
wv block <current-node> --by=<investigation-node>
```

### Path 2: Problem Too Big

```bash
# Split into smaller pieces
wv add "Subtask: isolate the failing component" --metadata='{"type":"task"}'
wv add "Subtask: fix isolated issue" --metadata='{"type":"task"}'
wv add "Subtask: integrate fix" --metadata='{"type":"task"}'
```

### Path 3: Need Help

```bash
# Create blocker for external input
wv add "Blocked: need input on X" --metadata='{"type":"blocker"}'
wv block <current-node> --by=<blocker-node>
```

### Path 4: Fresh Context

```bash
# Defer to new session
wv update <id> --status=todo
wv update <id> --metadata='{"deferred_reason":"need fresh context","failed_approaches":[...]}'
# End session, come back later
```

## Integration

This skill is triggered by:

- Manual invocation when feeling stuck
- Heuristic detection (future: hook after N failed edits)
- Time-based check (active node > 2x estimate)

## Examples

### Example 1: Test Failure Loop

```bash
/wv-detect-loop wv-b2c3

# Stuck on: Make test pass
# Failed approaches:
#   1. Fixed assertion → different failure
#   2. Fixed that assertion → original failure back
#   3. Mock the dependency → timeout instead
# Pattern: Whack-a-mole with symptoms
# Root cause: Test setup is missing required state
# Next: Read test setup for similar passing tests
```

### Example 2: Build Error Loop

```bash
/wv-detect-loop wv-d4e5

# Stuck on: Fix TypeScript errors
# Failed approaches:
#   1. Add type annotation → new error
#   2. Use 'as any' → type error elsewhere
#   3. Update type definition → breaks other files
# Pattern: Type system fighting us
# Root cause: Fundamental type mismatch in design
# Decision: Step back, draw type flow, redesign interface
```

### Example 3: Integration Failure Loop

```bash
/wv-detect-loop wv-f6g7

# Stuck on: API returning 500
# Failed approaches:
#   1. Check request format → format is correct
#   2. Check auth header → auth is valid
#   3. Check server logs → no useful info
# Pattern: Black box debugging without visibility
# Next experiment: Add request logging to server
# Decision: Investigate (improve observability first)
```

## Metadata Schema

```json
{
  "stuck_at": "2026-02-03T08:30:00Z",
  "time_spent_minutes": 45,
  "failed_approaches": [
    { "attempt": "Description", "result": "What happened", "why_failed": "Analysis" }
  ],
  "root_cause_hypothesis": "Best guess at actual problem",
  "next_experiment": "Smallest test of hypothesis",
  "decision": "pivot|investigate|split|escalate|defer"
}
```

## Prevention

To avoid getting stuck:

- Define done criteria upfront (`/ship-it`)
- Assess risks before starting (`/pre-mortem`)
- Verify assumptions before building (`/sanity-check`)
- Time-box exploration (30 min max before reassess)

## Related Skills

- **/sanity-check** — Verify assumptions that may be wrong
- **/pre-mortem** — Identify risks that may be causing issues
- **/wv-clarify-spec** — Clarify what we're actually trying to do
