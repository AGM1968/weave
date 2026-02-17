---
name: close-session
description: "End-of-session protocol to ensure work is saved and pushed"
---

# Session Close Protocol

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.

**CRITICAL**: Work is NOT complete until `git push` succeeds.

## Mandatory Workflow

```bash
# 1. File issues for remaining work

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.

wv add "..." --status=todo  # For anything needing follow-up

# 2. Run quality gates (if code changed)

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.

# Tests, linters, builds as appropriate

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.


# 3. Close completed nodes

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.

wv done <id1> <id2> ...

# 4. Sync and push

> **INTERNAL SKILL** — This skill is now part of the `/weave` orchestrator.
> Use `/weave` instead for the full graph-first workflow.
> Direct invocation is deprecated and may be removed in a future release.

git add <files>
wv sync --gh              # Persist state AND sync to GitHub issues
git add .weave/           # Stage any GH metadata changes from sync
git commit -m "descriptive message"
git push
git status  # MUST show "up to date with origin"
```

## Capture Learnings

For significant work:

```bash
wv done <id> --learning="Brief learning note"
# Or with structured learnings (captured in metadata):
wv update <id> --metadata='{"learning":{"decision":"...","pattern":"...","pitfall":"..."}}'
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
