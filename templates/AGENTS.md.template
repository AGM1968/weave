# AGENTS.md — Universal Agent Instructions

This repository uses **Weave** for task tracking. Every code change must be tracked in the graph.

## Before any edit

Run `wv work <id>` to claim a task, or `wv add "<text>" --status=active` to create one. If
`wv status` shows 0 active nodes, do not edit files.

## Quick reference

```txt
git status && wv status           # Check repo state + active node count
wv ready                          # Find unblocked work
wv work <id>                      # Claim it
# ... do the work ...
git add <files> && git commit -m "..."  # Commit work files before wv done
wv done <id> --learning="..."     # Complete with learnings
wv sync --gh && git add .weave/   # Sync (may dirty .weave/)
git diff --cached --quiet || git commit -m "chore(weave): sync state [skip ci]"
git push                          # mandatory
```

## Full documentation

- **MCP:** `weave_guide` (topics: workflow, github, learnings, context)
- **CLI:** `wv --help`, `wv help <command>`, or `~/.config/weave/WORKFLOW.md`
- **Claude Code:** See [CLAUDE.md](CLAUDE.md) for Claude-specific instructions
