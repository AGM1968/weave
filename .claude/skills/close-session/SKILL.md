---
name: close-session
description: "Runs the end-of-session protocol to save, sync, and push work safely. Use when finishing a session or preparing to hand off work."
---

# Session Close Protocol

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator. Use `/weave` instead for
> the full graph-first workflow. Direct invocation is deprecated and may be removed in a future
> release.

**CRITICAL**: Work is NOT complete until `git push` succeeds.

## Mandatory Workflow

```bash
# 1. File issues for remaining work
wv add "..." --status=todo  # For anything needing follow-up

# 2. Run quality gates (if code changed)
# Tests, linters, builds as appropriate

# 3. Commit completed work while nodes are still active
#    prepare-commit-msg appends Weave-ID trailers during this step
git add <files>
git commit -m "descriptive work message"

# 4. Close completed nodes
wv done <id> --learning="decision: ... | pattern: ... | pitfall: ..."
# Or: wv batch-done <id1> <id2> ... --learning="shared sprint learning"

# 5. Sync and push
wv sync --gh              # Persist state AND sync to GitHub issues
git add .weave/           # Stage any GH metadata changes from sync
git diff --cached --quiet || git commit -m "chore(weave): sync state [skip ci]"
git push
git status  # MUST show "up to date with origin"
```

## Capture Learnings

For significant work:

```bash
wv done <id> --learning="decision: ... | pattern: ... | pitfall: ..." --no-overlap-check
# Or pre-structure the same fields in metadata first:
wv update <id> --metadata='{"decision":"...","pattern":"...","pitfall":"..."}'
wv done <id>
```

## Critical Rules

- NEVER stop before pushing — work stays stranded locally
- NEVER say "ready to push when you are" — YOU must push
- If push fails, resolve and retry until it succeeds

## Handoff

If work continues in another session:

- What was accomplished
- What remains to do
- Any blockers
