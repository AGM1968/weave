---
name: fix-issue
description: "Fixes a GitHub issue or Weave node end-to-end using procedural gates. Use when a tracked issue requires implementation, verification, and closure."
---

# Fix Issue Workflow

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator. Use `/weave` instead
> for the full graph-first workflow. Direct invocation is deprecated and may be removed in a future
> release.

End-to-end issue resolution with skill-based gates to prevent common failure modes.

## Usage

```bash
/fix-issue <wv-id or gh-issue>
```

## Workflow

### 1. Understand the Issue

Run `wv show $ARGUMENTS` or `gh issue view $ARGUMENTS` to get details.

**Gate: /wv-clarify-spec** - If requirements are vague, clarify before proceeding.

Questions to ask:

- What exactly needs to change?
- What's the success criteria?
- Are there constraints or non-goals?

### 2. Claim the Work

For Weave nodes: `wv update $ARGUMENTS --status=active`

**Gates:**

- **/ship-it** - Define done criteria upfront (prevents scope creep)
- **/pre-mortem** - Identify risks and rollback plan (prevents failure)

The PreToolUse hook will suggest these automatically, but run manually if needed:

```bash
/ship-it $ARGUMENTS
/pre-mortem $ARGUMENTS
```

### 3. Locate Relevant Code

**Gate: /zero-in** - Use focused search to find files without wasting context.

Search protocol:

1. Define what you're looking for (specific function, pattern, error)
2. Use grep for content, glob for structure
3. Read only what's needed
4. Stop at earliest success

### 4. Plan Implementation

**Gate: /sanity-check** - Validate assumptions before building on them.

Before coding:

- Check existing patterns and conventions
- Verify dependencies and imports
- Confirm approach with node's done_criteria

### 5. Implement Changes

**Gate: /wv-guard-scope** - Match codebase conventions and respect scope.

During implementation:

- Fix only what's in scope
- Match existing code style and patterns
- Create new nodes for discovered work
- Don't refactor while fixing

### 6. Verify the Fix

**Gate: /wv-verify-complete** - Require evidence that the fix works.

Verification methods:

- Run relevant tests
- Manual testing for UI/behavior changes
- Check for regressions
- Verify done_criteria are met

Capture verification evidence in node metadata.

### 7. Commit and Close

Create descriptive commit with issue reference:

```bash
git add <files>
git commit -m "$(cat <<'EOF'
fix: <short description>

<detailed explanation>
Fixes: <issue reference>

Co-Authored-By: Claude Sonnet 4.5 <noreply@anthropic.com>
EOF
)"
```

Close the node with learnings:

```bash
wv done $ARGUMENTS --learning="pattern: ..."
```

**Gate: /wv-verify-complete** - PreToolUse hook will suggest this if no verification captured.

## Skill Gates Summary

| Phase         | Skill               | Purpose                          | When                      |
| ------------- | ------------------- | -------------------------------- | ------------------------- |
| Understand    | /wv-clarify-spec    | Clarify vague requirements       | If requirements unclear   |
| Claim         | /ship-it            | Define done criteria             | Before setting to active  |
| Claim         | /pre-mortem         | Identify risks and rollback      | Before setting to active  |
| Locate        | /zero-in            | Focused search without waste     | During code exploration   |
| Plan          | /sanity-check       | Validate assumptions             | Before implementation     |
| Implement     | /wv-guard-scope     | Match conventions, respect scope | During coding             |
| Verify        | /wv-verify-complete | Require verification evidence    | Before closing node       |
| Stuck         | /wv-detect-loop     | Break out of retry loops         | After 2-3 failed attempts |
| Context shift | /breadcrumbs        | Leave notes for next session     | Before ending session     |

## Anti-Patterns to Avoid

1. **Assumption cascade** - Don't guess; validate with /sanity-check
2. **Scope creep** - Stay focused; use /wv-guard-scope
3. **Infinite retry** - Stop and reassess with /wv-detect-loop
4. **Over-exploration** - Search with purpose using /zero-in
5. **"Looks right"** - Verify with /wv-verify-complete before closing
6. **Context rot** - Leave /breadcrumbs before compaction

## Integration

The procedural skills are enforced through:

- **PreToolUse hooks** - Suggest /ship-it and /pre-mortem on claim, /wv-verify-complete on close
- **Manual invocation** - Call skills explicitly during workflow
- **PreCompact hook** - Auto-extracts breadcrumbs for context preservation

## Example

```bash
# 1. Understand

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.

gh issue view 42
# Requirements vague? Run: /wv-clarify-spec

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.


# 2. Claim with gates

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.

wv update wv-abc1 --status=active
# Hook suggests: /ship-it wv-abc1 && /pre-mortem wv-abc1

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.


# 3. Locate with focus

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.

# Use /zero-in: "Find the authentication middleware"

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.

grep -r "auth.*middleware" src/

# 4. Plan and validate

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.

# Use /sanity-check: "Verify Express middleware pattern"

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.


# 5. Implement

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.

# Use /wv-guard-scope: Match existing patterns, defer refactors

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.


# 6. Verify

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.

npm test -- auth.test.js
# Capture evidence: /wv-verify-complete wv-abc1

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.


# 7. Close with learnings

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.

git commit -m "fix: handle null user in auth middleware"
wv done wv-abc1 --learning="pattern: ..."
```
