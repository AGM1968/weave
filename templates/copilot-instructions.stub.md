# GitHub Copilot Instructions

This repository uses **Weave** for task tracking. Every code change must be tracked.

## Pre-flight (run before anything else)

```bash
git status && wv status   # check for uncommitted work + active node count
```

If `wv status` shows 0 active nodes, claim one before touching files:

```bash
wv ready                  # list unblocked work
wv work <id>              # claim it
```

## Before every file edit

Call `weave_edit_guard` (MCP) before any edit. If blocked, claim a task first.

## Core loop

```bash
wv work <id>                               # 1. claim
# ... edit files ...
git add <files> && git commit -m "..."     # 2. commit BEFORE wv done
echo "s" | wv done <id> --learning="..."  # 3. close (pipe to skip similarity prompt)
wv sync --gh && git push                   # 4. MANDATORY — sync graph + push
```

> **Order matters**: commit first, then `wv done`, then sync+push. Never reverse steps 2–4.

## Shortcuts

```bash
# Trivial one-file work (no open GH issue needed):
wv quick "<description>" --learning="..."

# Done + sync + push in one step:
echo "s" | wv ship <id> --learning="..."
```

## Terminal discipline

`wv done` and `wv ship` have an interactive similarity-checker that **blocks VS Code terminals**.
Always pipe input:

```bash
echo "s" | wv done <id> --learning="..."   # correct
wv done <id> --learning="..."              # will hang in VS Code terminal
```

## Code quality — run before every commit

```bash
make format   # auto-fix formatting in place
make lint     # check for errors (must be clean before committing)
```

CI will fail if lint is not clean. Always run `make format` after edits, then `make lint` to
confirm.

## Context pack for complex nodes

Before starting non-trivial work, load the context pack:

```bash
wv context <id> --json    # ancestors, blockers, pitfalls — cached per session
```

## Learnings format

Structured learnings are more useful for future sessions:

```
--learning="decision: X | pattern: Y | pitfall: Z"
```

## Reference

- MCP: `weave_guide` (topics: workflow, github, learnings, context)
- CLI: `~/.config/weave/WORKFLOW.md`
