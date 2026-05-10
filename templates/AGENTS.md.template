# AGENTS.md — Universal Agent Instructions

This repository uses **Weave** for task tracking. Every code change must be tracked in the graph.

## Before any edit

Run `wv work <id>` to claim a task, or create a claim-ready node with
`wv add "<text>" --status=active --criteria="c1|c2" --risks=low`. If `wv status` shows 0 active
nodes, do not edit files.

## Quick reference

```txt
git status && wv status           # Check repo state + active node count
wv search "<topic>"               # Check for existing related work before claiming/creating
wv ready                          # Find unblocked work
wv work <id>                      # Claim it
# ... do the work ...
git add <files> && git commit -m "..."  # Commit work files before wv done
wv done <id> --learning="..."     # Complete with learnings
wv sync --gh && git add .weave/   # Sync (may dirty .weave/)
git diff --cached --quiet || git commit -m "chore(weave): sync state [skip ci]"
git push                          # mandatory
```

`wv ship <id>` is the close + sync shortcut for finishing a node. It does not push; if `wv status`
still reports pending Git sync, handle that separately or inspect it with `wv doctor` / `wv recover`.

## Code search

If `wv index` has been run, prefer hybrid code search over grep/glob for discovery:

```bash
wv search --code "query"                  # hybrid BM25 + cosine (CLI)
wv search --code "query" --mode=fts       # exact tokens / function names
wv search --code "query" --graph          # include active Weave nodes per file
```

MCP equivalent: `weave_code_search` (parameters: `query`, `mode`, `limit`, `graph`).

## Full documentation

- **MCP:** `weave_guide` (topics: workflow, github, learnings, context)
- **CLI:** `wv --help`, `wv help <command>`, or `~/.config/weave/WORKFLOW.md`
- **Agent-specific instructions:** See the project's `CLAUDE.md`, `.github/copilot-instructions.md`, or equivalent for host-specific guidance
