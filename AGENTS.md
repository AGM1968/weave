# AGENTS.md — Universal Agent Instructions

This repository uses **Weave** for task tracking. Every code change must be tracked in the graph.

## Before any edit

Use `wv` when it is on PATH; otherwise use the repo-local `./scripts/wv` wrapper. Run
`wv work <id>` to claim a task, or create a claim-ready node with
`wv add "<text>" --status=active --criteria="c1|c2" --risks=low`. If `wv status` shows 0 active
nodes, do not edit files. Discovery before claiming may read, search, and report only.

## Quick reference

```txt
if ! command -v wv >/dev/null 2>&1; then wv() { ./scripts/wv "$@"; }; fi
# ./scripts/wv appends existing $HOME/.local/bin and $HOME/.cargo/bin for user tools.
wv bootstrap --json               # 0. Session snapshot — replaces git status + wv status
wv search "<topic>"               # 1. Check for existing related work before claiming/creating
wv ready                          # 2. Find unblocked work
wv work <id>                      # 3. Claim it
# ... do the work ...
git add <files> && git commit -m "..."  # 4. Commit work files before wv done
wv done <id> --learning="..."     # 5. Complete with learnings
wv sync --gh && git add .weave/   # 6. Sync (may dirty .weave/)
git diff --cached --quiet || git commit -m "chore(weave): sync state [skip ci]"
git push                          # 7. mandatory
```

`wv ship <id>` close + sync shortcut. `wv sync --gh` accepts `--mode=fast|full|repair`; use
`--mode=repair` to resume from `.weave/repair-checkpoint.json` after an interrupted sync.

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
