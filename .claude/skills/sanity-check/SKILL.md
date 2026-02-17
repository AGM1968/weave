---
name: sanity-check
description:
  "Before building on assumptions, validate them. Prevents assumption cascades where one wrong guess
  leads to a completely wrong solution."
---

# Sanity Check — Assumption Validation Gate

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator. Use `/weave` instead
> for the full graph-first workflow. Direct invocation is deprecated and may be removed in a future
> release.

**Trigger:** Before implementation when the approach involves assumptions about code, APIs, or
behavior that haven't been verified.

**Purpose:** Address failure mode #2 (overconfidence without calibration). Makes assumptions
explicit, tags them as verified/unverified, and requires resolution before building on them.

## Instructions

When invoked with a node ID (`/sanity-check <wv-id>`):

### 1. List Assumptions

Identify all assumptions in the current plan:

- **Code assumptions:** "Function X exists and does Y"
- **API assumptions:** "Endpoint returns this shape"
- **Behavior assumptions:** "Users will do this"
- **Environment assumptions:** "Service Z is available"
- **Data assumptions:** "Table has column A"

### 2. Tag Each Assumption

| Tag               | Meaning                              | Action Required          |
| ----------------- | ------------------------------------ | ------------------------ |
| **verified**      | Confirmed by reading code/docs/tests | None                     |
| **unverified**    | Believed true but not checked        | Must verify before using |
| **uncertain**     | Multiple possibilities               | Must resolve ambiguity   |
| **falsified**     | Checked and found false              | Update plan              |

### 3. Verify Unverified Assumptions

For each unverified assumption, define the check:

```bash
# Example verification commands

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.

grep -r "functionName" src/           # Does function exist?
cat src/api/types.ts | head -50       # What's the API shape?
wv show wv-xxxx                       # What did we decide before?
git log --oneline -5 src/auth/        # Recent changes to area?
```

### 4. Assess Confidence

After verification, rate overall confidence:

- **High:** All key assumptions verified, approach is sound
- **Medium:** Some assumptions unverified but low-risk
- **Low:** Critical assumptions unverified, need more investigation

### 5. Record in Metadata

```bash
wv update <id> --metadata='{
  "assumptions": [
    {"claim": "Auth middleware exists", "status": "verified", "evidence": "src/middleware/auth.ts"},
    {"claim": "JWT tokens expire in 1h", "status": "unverified", "check": "Read auth config"}
  ],
  "unknowns": ["How are refresh tokens handled?"],
  "confidence": "medium",
  "timebox": "Re-evaluate after 30 min if stuck"
}'
```

## Output Format

**Example output:**

**Task:** wv-a1b2 — Add rate limiting to API

**Assumptions:**

| #   | Assumption                           | Status        | Evidence/Check        |
| --- | ------------------------------------ | ------------- | --------------------- |
| 1   | Express middleware pattern used      | verified      | Saw in src/app.ts     |
| 2   | Redis available for rate limit store | unverified    | Check docker-compose  |
| 3   | Rate limit config in env vars        | uncertain     | Could be config file  |
| 4   | Existing rate limiter package        | falsified     | No package.json entry |

**Unknowns:**

- How do we want to handle rate limit exceeded? (Need product decision)

**Confidence:** Medium — need to verify Redis availability

**Next:** Check docker-compose.yml for Redis, ask about rate limit UX

## NEVER

- Build on unverified assumptions for critical paths
- Assume code exists without checking (grep/find first)
- Present guesses with the same confidence as verified facts
- Skip sanity check because "it should work"

## ALWAYS

- List assumptions explicitly before implementation
- Verify assumptions touching: auth, data, external services
- Tag confidence level on plans and estimates
- Create verification steps for each unverified assumption

## Common Assumption Traps

### Trap 1: "The function exists"

```bash
# Don't assume, verify

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.

grep -r "functionName" src/
# If not found, plan changes

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.

```

### Trap 2: "The API returns this shape"

```bash
# Don't assume, verify

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.

cat src/types/api.ts | grep -A 20 "interface Response"
# Or check actual API response

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.

```

### Trap 3: "This is how it works"

```bash
# Don't assume, verify

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.

git log --oneline -10 src/module/
cat src/module/README.md
# Read the actual implementation

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.

```

### Trap 4: "The config supports this"

```bash
# Don't assume, verify

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.

grep -r "CONFIG_KEY" .
cat .env.example | grep FEATURE
```

## Integration

This skill is called by:

- `/fix-issue` — After planning, before implementation
- Manual invocation when plan involves uncertain areas
- When estimates feel uncertain

## Examples

### Example 1: API Integration

```bash
/sanity-check wv-b2c3

# Task: Integrate with Stripe API

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.

# Assumptions:

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.

#   1. Stripe SDK installed → check package.json

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.

#   2. API keys in env → check .env.example

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.

#   3. Webhook endpoint exists → grep for /webhook

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.

#   4. Test mode available → Stripe always has test mode

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.

# Confidence: Low until SDK and keys verified

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.

```

### Example 2: Refactoring

```bash
/sanity-check wv-d4e5

# Task: Extract utility functions

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.

# Assumptions:

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.

#   1. Functions have no side effects → read each function

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.

#   2. No circular imports will result → check import graph

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.

#   3. Tests exist for these functions → found in utils.test.ts

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.

#   4. All callers use named imports → some use default

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.

# Confidence: Medium, need to verify side effects

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.

```

## Metadata Schema

```json
{
  "assumptions": [
    {
      "claim": "What we believe to be true",
      "status": "verified|unverified|uncertain|falsified",
      "evidence": "How we verified (if verified)",
      "check": "How to verify (if unverified)"
    }
  ],
  "unknowns": ["Questions we can't answer yet"],
  "confidence": "low|medium|high",
  "confidence_reason": "Why this confidence level",
  "timebox": "When to re-evaluate if stuck"
}
```

## Decision Gate

After sanity check:

- **Proceed:** High confidence, assumptions verified
- **Investigate:** Medium confidence, verify key assumptions first
- **Pause:** Low confidence, need more information
- **Pivot:** Critical assumptions falsified, change approach

## Related Skills

- **/pre-mortem** — Risk assessment (what could go wrong)
- **/wv-clarify-spec** — Clarify requirements (what are we building)
- **/zero-in** — Focused search to verify assumptions
