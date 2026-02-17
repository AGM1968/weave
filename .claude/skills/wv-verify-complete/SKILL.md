---
name: wv-verify-complete
description: "When completing work, require verification evidence before closing. Prevents looks right over works right."
---

# Verify Complete — Verification Gate

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator. Use `/weave` instead
> for the full graph-first workflow. Direct invocation is deprecated and may be removed in a future
> release.

**Trigger:** Before running `wv done` on any non-trivial node.

**Purpose:** Address failure mode #3 (hallucination without verification). Ensures claims are backed
by evidence, not assumptions.

## Instructions

When invoked with a node ID (`/wv-verify-complete <wv-id>`):

### 1. Identify Verification Method

Choose the strongest applicable method:

| Method        | When to Use                     | Evidence Required          |
| ------------- | ------------------------------- | -------------------------- |
| **Test**      | Tests exist for this area       | Command + pass output      |
| **Build**     | Compiled language / bundler     | Clean build output         |
| **Typecheck** | TypeScript, Python mypy, etc.   | No type errors             |
| **Lint**      | Style/quality checks configured | Clean lint output          |
| **Runtime**   | Manual verification needed      | Steps + observed behavior  |
| **Diff**      | Code review of changes          | Before/after + explanation |

### 2. Execute Verification

Run the appropriate command(s):

```bash
# Examples by project type
pnpm test              # JavaScript/TypeScript
pytest                 # Python
cargo test             # Rust
go test ./...          # Go
pnpm run build         # Build check
pnpm run typecheck     # Type check
ruff check .           # Python lint
```

### 3. Capture Evidence

Record verification in node metadata:

```bash
wv update <id> --metadata='{
  "verification": {
    "method": "test|build|typecheck|lint|runtime|diff",
    "command": "command that was run",
    "result": "pass|fail",
    "evidence": "key output snippet or observation",
    "verified_at": "ISO timestamp"
  }
}'
```

### 4. Gate Decision

- **PASS:** Verification succeeded → proceed to `wv done`
- **FAIL:** Verification failed → fix issues, re-verify
- **NO TESTS:** Document manual verification steps explicitly

## Output Format

````markdown
## Verification: wv-XXXX

**Method:** test **Command:** `pnpm test src/auth` **Result:** PASS

**Evidence:**

```text
PASS src/auth/login.test.ts ✓ should authenticate valid credentials (12ms) ✓ should reject invalid
password (8ms)

Test Suites: 1 passed, 1 total Tests: 2 passed, 2 total
```
````

**Verified at:** 2026-02-03T08:15:00Z

## NEVER

- Close a node claiming "should work" without running verification
- Accept "no errors in editor" as sufficient evidence
- Skip verification for "trivial" changes that touch shared code
- Claim tests pass without actually running them

## ALWAYS

- Run at least one executable check (test/build/lint/typecheck)
- If no automated checks exist, document manual verification steps
- Include command output or observations as evidence
- Record verification in node metadata before closing

## Escalation

If verification is not possible:

1. Document why (no tests, environment issue, etc.)
2. Add `metadata.verification.method = "deferred"`
3. Create follow-up node: `wv add "Add tests for <area>" --metadata='{"type":"task"}'`
4. Proceed with explicit acknowledgment of verification gap

## Integration

This skill is called by:

- `/fix-issue` — Step 5 (Verify) should invoke `/wv-verify-complete`
- Pre-close gate hook — Blocks `wv done` if `metadata.verification` missing
- Manual invocation when completing any significant work

## Examples

### Example 1: Test Verification

```bash
/wv-verify-complete wv-a1b2

# Agent runs: pnpm test src/utils/parser.test.ts
# Output: 5 tests passed
# Updates metadata with verification evidence
# Proceeds to wv done
```

### Example 2: Build Verification (No Tests)

```bash
/wv-verify-complete wv-c3d4

# No tests for this area
# Agent runs: pnpm run build
# Output: Build successful, no errors
# Agent runs: pnpm run typecheck
# Output: No type errors
# Records both as verification evidence
```

### Example 3: Manual Verification

```bash
/wv-verify-complete wv-e5f6

# UI change, no automated tests
# Agent documents:
#   - Opened browser to /dashboard
#   - Clicked "Export" button
#   - CSV downloaded with correct data
#   - Verified 3 rows matched database
# Records as runtime verification with steps
```

## Metadata Schema

```json
{
  "verification": {
    "method": "test",
    "command": "pnpm test src/auth",
    "result": "pass",
    "evidence": "5 tests passed in 1.2s",
    "verified_at": "2026-02-03T08:15:00Z",
    "files_checked": ["src/auth/login.ts", "src/auth/login.test.ts"]
  }
}
```

## Related Skills

- **/ship-it** — Define done criteria before implementation
- **/fix-issue** — Calls wv-verify-complete as part of workflow
- **/close-session** — Final verification before session end
