---
name: zero-in
description:
  "Focused search protocol to prevent over-exploration and context overload. Target, bound, report,
  decide."
---

# Zero In — Focused Search Protocol

**Note:** This skill remains user-accessible as an exception to the orchestrator consolidation.
Zero-in is a search protocol that's independent of the Weave workflow for task execution.

**Trigger:** Before searching when:

- About to grep broadly ("search the entire codebase")
- Exploring without specific target ("see what's there")
- Risk of reading too many files
- Context budget is a concern

**Purpose:** Prevent over-exploration that leads to context overload and distraction. Keeps searches
targeted and actionable.

## Instructions

When invoked before search (`/zero-in` or when about to explore broadly):

### 1. Define Search Target

**Before any tool use**, answer:

```text
WHAT am I looking for?
→ Specific function, pattern, or concept (not "anything related")

WHY do I need it?
→ How will this information be used?

WHEN will I stop?
→ Define success criteria upfront

HOW MANY results are useful?
→ 1 exact match? Top 5? All instances?
```

**Bad targets:**

- "See how authentication works" (too broad)
- "Find all the code" (unbounded)
- "Explore the API" (no endpoint)

**Good targets:**

- "Find where JWT tokens are validated" (specific)
- "Locate the function that handles /api/login" (bounded)
- "Get examples of error handling pattern" (3-5 samples)

### 2. Bounded Search Strategy

Use tools in order of specificity:

**1. Grep first** (most targeted)

```bash
# Find specific pattern
grep "validateJWT" --output_mode=files_with_matches

# Narrow scope with type filter
grep "handleLogin" --type=ts
```

**2. Glob if needed** (structure search)

```bash
# Find files by name pattern
glob "**/auth/**/*.ts"
```

**3. Read strategically** (limited files)

```bash
# Read only what's needed
read src/auth/validate.ts --limit=100
```

**Set boundaries:**

- Max 3-5 files to read fully
- Use `--limit` to avoid full file reads
- Stop when target is found

### 3. Report Findings

Document what was found:

```markdown
## Zero-In Results

**Target:** Find JWT validation function **Search:** grep "validateJWT" → 2 matches **Found:**
src/auth/jwt.ts:45 validateJWT()

**Enough?** Yes **Next:** Read jwt.ts lines 40-60
```

### 4. Decision Point

**Found target:**

- Read specific sections only
- Proceed with task
- Document location for later

**Not found:**

- Refine search terms (typo? synonym?)
- Check assumptions (wrong layer? different pattern?)
- Ask user if target exists

**Too many results:**

- Add filters (--type, --glob, path restriction)
- Narrow search terms
- Sample representative results (not all)

## Output Format

When applying zero-in protocol:

```markdown
## Zero-In Search: wv-XXXX

**Target:** Where is user session stored?

**Strategy:**

1. grep "session" --type=ts → 47 files (too many)
2. grep "session.\*store" --type=ts → 8 files (better)
3. grep "SessionStore" --type=ts → 2 files

**Found:**

- src/store/SessionStore.ts (main implementation)
- src/types/session.d.ts (types)

**Action:** Read SessionStore.ts lines 1-100 **Stop:** Target found, no further exploration needed
```

## NEVER

- Search "to see what's there" without specific target
- Read entire files when you need one function
- Explore broadly before defining target
- Continue searching after finding answer

## ALWAYS

- Define target before first grep
- Use most specific tool first (grep → glob → read)
- Set boundaries (max files, line limits)
- Stop when target is found
- Report findings before expanding search

## Examples

### Example 1: Focused Function Search

```text
Scattered approach:
glob "**/*.ts" → 247 files
read src/auth/login.ts (entire file)
read src/auth/validate.ts (entire file)
read src/middleware/auth.ts (entire file)
"Let me explore auth to understand it"

Zero-in approach:
Target: "Find function that validates login credentials"
grep "validateLogin\|verifyCredentials" --type=ts
→ src/auth/validate.ts:validateCredentials()
read src/auth/validate.ts --offset=50 --limit=30
Found: Lines 50-80 contain the function
Stop: Target acquired
```

### Example 2: Pattern Discovery

```text
Over-exploration:
"How does error handling work?"
grep "error" → 892 matches
read 15 files looking for patterns
Spent 10 minutes, now confused

Zero-in approach:
Target: "Find 3 examples of error handling pattern"
grep "catch.*error" --type=ts --head_limit=5
→ 5 matches found
read first 3 files, context around catch blocks
Found: try/catch with logger.error(err.message)
Stop: Pattern identified from 3 examples
```

### Example 3: API Endpoint Location

```text
Broad search:
glob "**/*routes*" → 45 files
read each route file
"Where are all the API endpoints?"

Zero-in approach:
Target: "Find handler for POST /api/users"
grep "'/api/users'" --type=ts
→ src/routes/users.ts:23
read src/routes/users.ts --offset=20 --limit=40
Found: POST handler at lines 23-45
Stop: Specific endpoint found
```

## Context Budget Awareness

When context policy is MEDIUM or LOW:

- **HIGH:** Can read files <500 lines, grep first for larger
- **MEDIUM:** Always grep first, read <500 lines, use --limit
- **LOW:** Grep only, read <200 line slices, summarize don't quote

Zero-in protocol adapts:

```bash
# HIGH policy
grep → read full file if <500 lines

# MEDIUM policy
grep → read --limit=200

# LOW policy
grep → read --offset=X --limit=100 (specific section only)
```

## Integration

This skill is called:

- Before broad searches ("find all X")
- When context budget is tight
- Before reading multiple files
- When exploration risks distraction

## Related Skills

- **/wv-guard-scope** — Enforces scope during implementation
- **/wv-clarify-spec** — Clarifies what to search for
- **/wv-detect-loop** — Pivots when search strategy isn't working
