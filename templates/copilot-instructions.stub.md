<!-- ── BEGIN WEAVE COPILOT.MD ── managed by wv init-repo, do not edit manually -->

# GitHub Copilot Instructions

This repository uses **Weave** for task tracking. Every code change must be tracked.

## Pre-flight (run before anything else)

```bash
if ! command -v wv >/dev/null 2>&1; then wv() { ./scripts/wv "$@"; }; fi
# ./scripts/wv appends existing $HOME/.local/bin and $HOME/.cargo/bin for user tools.
wv bootstrap --json   # single call: active/ready/blocked + learnings + context policy
```

If 0 active nodes, claim one before touching files:

```bash
wv search "<topic>"        # check for existing related work before claiming/creating
wv ready                  # list unblocked work
wv work <id>              # claim it
```

## Before every file edit

Call `weave_edit_guard` (MCP) before any edit. If blocked, claim a task first.

## Core loop

```bash
wv work <id>                                             # 1. claim
# ... edit files ...
git add <files> && git commit -m "..."                   # 2. commit BEFORE wv done
wv done <id> --learning="..." --no-overlap-check         # 3. close (no prompts)
wv sync --gh && git add .weave/                          # 4a. sync graph (may dirty .weave/)
git diff --cached --quiet || git commit -m "chore(weave): sync state [skip ci]"  # 4b. commit if dirty
git push                                                 # 4c. MANDATORY
```

> **Order matters**: commit first, then `wv done`, then sync+push. Never reverse steps 2–4.

## Shortcuts

```bash
# Trivial one-file work (no open GH issue needed):
wv quick "<description>" --learning="..."

# Done + sync in one step (check `wv status` for pending Git sync):
wv ship <id> --learning="..." --no-overlap-check

# Create a standalone node without a parent (persists intentional standalone metadata):
wv add "<description>" --standalone
# `wv health` reports these as intentional_standalones, not orphan_nodes.
```

## Sync modes

`wv sync --gh` accepts `--mode=fast|full|repair` (and an optional `--node=<id>` focus):

- `fast` — default for `wv ship` and session-end; bounded to focus + impacted set.
- `full` — explicit default for plain `wv sync --gh`; exhaustive reconcile.
- `repair` — resumes from `.weave/repair-checkpoint.json` after an interrupted/crashed sync.
  `wv recover` and the stop-hook recommend this when the checkpoint exists.

## Context pack for complex nodes

Before starting non-trivial work, load the context pack:

```bash
wv bootstrap --json        # preferred session-start snapshot (single call)
wv context <id> --json    # ancestors, blockers, pitfalls — cached per session
```

Use `wv touch <id> --intent="..."` for low-cost intent/progress updates between larger steps.

## Learnings format

Structured learnings are more useful for future sessions:

```
--learning="decision: X | pattern: Y | pitfall: Z"
```

For non-interactive agent flows, prefer `--no-overlap-check` on `wv done`/`wv ship` once
verification and learnings are ready.

## Code search

If `wv index` has been run, use hybrid code search instead of file browsing:

```bash
wv search --code "query"             # hybrid BM25 + cosine (CLI)
wv search --code "query" --mode=fts  # exact tokens / function names
```

MCP equivalent: `weave_code_search` (parameters: `query`, `mode`, `limit`, `graph`).

## Reference

- MCP: `weave_guide` (topics: workflow, github, learnings, context)
- CLI: `wv --help`, `wv help <command>`, or `~/.config/weave/WORKFLOW.md`
<!-- ── END WEAVE COPILOT.MD ── -->
