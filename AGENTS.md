# AGENTS.md — Universal Agent Instructions

This repository uses **Weave** for task tracking. Every code change must be tracked in the graph.

## Before any edit

Use `wv` when it is on PATH; otherwise use the repo-local `./scripts/wv` wrapper. Run
`wv work <id>` to claim a task, or create a claim-ready node with
`wv add "<text>" --status=active --criteria="c1|c2" --risks=low`. If `wv status` shows 0 active
nodes, do not edit files. Discovery before claiming may read, search, and report only.

Open a file with your harness's native file-read before editing it. Shell reads (`cat`/`grep`/`sed`)
and code-search find the spot but do not satisfy harness edit-guards — editing a file you only
inspected via a shell command is blocked ("File has not been read"). Grep/partial-read to locate;
native-read the file you will change.

To reopen a previously completed node: `wv work <id> --reopen` (plain `wv work` on a done node
returns an error).

## Quick reference

```txt
if ! command -v wv >/dev/null 2>&1; then wv() { "$HOME/.local/bin/wv" "$@"; }; fi
# Fallback for a shell where ~/.local/bin is not yet on PATH (sandboxed
# agents, fresh shells before the next login). This repo does not vendor
# weave's own scripts/wv -- wv is installed globally by install.sh.
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

## Procedures

Procedures are the agent-neutral guidance every harness reads; run a procedure's fallback command for
its full text. Discovery routing (the smallest route that resolves an uncertainty) is
`wv guide --procedure=discovery-routing`. `wv init-repo --update` refreshes the index below, and
only inside its markers; delete the markers to opt this file out.

<!-- BEGIN WEAVE PROCEDURES -->
<!-- END WEAVE PROCEDURES -->

## Graph memory

Durable memory lives in the Weave graph, not in this file. Read the active memories with
`wv memory recall --agent=all --json` (or `wv show <id>` for one), and capture a new one with
`wv remember <text>`; `wv bootstrap --json` carries the same index at session start.

## Full documentation

- **MCP:** `weave_guide` (topics: workflow, github, learnings, context, routing, mcp, verification, instrumentation, config, discovery)
- **CLI:** `wv --help`, `wv help <command>`, or `~/.config/weave/WORKFLOW.md`
- **Agent-specific instructions:** See the project's `CLAUDE.md`, `.github/copilot-instructions.md`, or equivalent for host-specific guidance
