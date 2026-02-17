# AGENTS.md — Universal Agent Instructions

This file provides instructions for AI coding agents working in this repository. For Claude-specific
details, see [CLAUDE.md](CLAUDE.md).

## Overview

This is the **Memory System (Weave)** — an in-memory graph for AI coding agents. All work is tracked
as nodes in a SQLite graph. Use the `wv` CLI for everything.

## Core Workflow

```bash
wv ready                          # 1. Find unblocked work
wv work <id>                      # 2. Claim it (sets WV_ACTIVE for subagents)
# ... do the work ...
wv done <id> --learning="..."     # 3. Complete with learning
wv sync --gh && git push          # 4. MANDATORY before session end (--gh syncs GitHub issues)
```

## Essential Commands

| Command                  | Purpose                                |
| ------------------------ | -------------------------------------- |
| `wv ready`               | List unblocked tasks                   |
| `wv work <id>`           | Claim task, enable subagent context    |
| `wv add <text> --gh`     | Create node + GitHub issue (linked)    |
| `wv done <id>`           | Complete node                          |
| `wv delete <id>`         | Permanently remove node + edges        |
| `wv bulk-update`         | Update multiple nodes from JSON stdin  |
| `wv context <id> --json` | Get full context pack for a node       |
| `wv status`              | Quick status summary                   |
| `wv show <id>`           | Node details                           |
| `wv search <query>`      | Full-text search                       |
| `wv health`              | System health check                    |
| `wv plan <file>`         | Import markdown as epic + tasks        |
| `wv tree`                | Epic hierarchy (`--mermaid`, `--json`) |
| `wv link <from> <to>`    | Create semantic edge between nodes     |
| `wv prune`               | Archive old done nodes                 |
| `wv sync --gh`           | Persist graph + sync GitHub issues     |

## MCP Server

For AI tools that support MCP (Model Context Protocol), a server is available:

```bash
cd mcp && npm install && npm run build
```

**Available MCP tools (22):**

| Tool                  | Purpose                                    |
| --------------------- | ------------------------------------------ |
| `weave_quick`         | Create + close in one call (trivial tasks) |
| `weave_work`          | Claim node + return context pack           |
| `weave_ship`          | Done + sync in one step                    |
| `weave_overview`      | Status + health + breadcrumbs + ready work |
| `weave_search`        | Full-text search                           |
| `weave_add`           | Create node                                |
| `weave_done`          | Complete node                              |
| `weave_batch_done`    | Complete multiple nodes in one call        |
| `weave_update`        | Modify node metadata/status/text/alias     |
| `weave_context`       | Get context pack                           |
| `weave_list`          | List nodes                                 |
| `weave_link`          | Create edges                               |
| `weave_tree`          | View epic hierarchy as a tree              |
| `weave_learnings`     | Query captured learnings                   |
| `weave_status`        | Status summary                             |
| `weave_health`        | Health check                               |
| `weave_preflight`     | Pre-action checks for a node               |
| `weave_sync`          | Persist graph + optional GH sync           |
| `weave_resolve`       | Resolve contradiction between nodes        |
| `weave_breadcrumbs`   | Save/show/clear session breadcrumbs        |
| `weave_plan`          | Import markdown plan as epic + tasks       |
| `weave_close_session` | End-of-session cleanup                     |

Prefer compound tools (`weave_quick`, `weave_work`, `weave_ship`, `weave_overview`) over composing
multiple basic tools — they reduce round-trips from 2-3 calls to 1.

## Rules

**MANDATORY: Every code change, bug fix, or task MUST follow this workflow. No exceptions.**

1. **Track ALL work in Weave** — before writing any code, run `wv work <id>` or
   `wv add "<description>" --status=active --gh`. Use `--gh` to create a linked GitHub issue. Never
   make changes without an active Weave node.
2. **No untracked fixes** — even small fixes, doc edits, or one-line changes get a Weave node. Use
   `wv quick "<what you did>" --learning="..."` for trivial work.
3. **Capture learnings** — use `--learning="..."` flag on `wv done`. Include
   decision/pattern/pitfall.
4. **Sync before session end** — `wv sync --gh && git push` is mandatory
5. **Check context** — run `wv context <id> --json` before starting complex work
6. **Bound session scope** — limit to 4-5 tasks per session. For epics, work a subset then start a
   fresh session. Context limits kill sessions mid-task; focused sessions complete more reliably.

**Violation check:** If you are about to edit a file and `wv status` shows 0 active nodes, STOP and
create/claim a node first.

## Development Pitfalls

- **Source vs installed:** Edit files in `scripts/`, never `~/.local/bin/` or `~/.local/lib/weave/`.
  A PreToolUse hook blocks installed-path edits. After source edits, run `./install.sh` to sync.
- **GitHub sync:** Use `wv sync --gh` (Python module). The legacy `scripts/sync-weave-gh.sh` bash
  script is deprecated — it causes duplicate issues and missing metadata.
- **Metadata key in JSON:** `wv show --json` returns metadata under `"json(metadata)"` (not
  `"metadata"`). Parse with: `jq '.[0]."json(metadata)" | fromjson | .field'`. Note:
  `wv list --json` aliases it as `"metadata"` so `.metadata | fromjson` works there.
- **Commit incrementally:** Commit and push after each logical unit of work. Don't accumulate all
  changes for session end — context/usage limits can terminate sessions mid-task, losing work. The
  PreCompact hook auto-commits as a safety net.
- **Prefer implementation:** When a task is well-defined, start coding immediately. Keep plans to
  <10 lines. Don't over-plan.
- **Graph hygiene:** Run `wv health` periodically. Orphan nodes (no edges) should be linked to a
  parent epic with `wv link <task> <epic> --type=implements`, or pruned with `wv prune` if stale.
  Target: 100/100 health score.
- **Plan import:** Use `wv plan <file.md> --sprint=N --gh` to import structured plans into the graph
  with GitHub issues. Use `wv plan --template` to scaffold a new plan document.

## Skills

This repo includes procedural skills in `.claude/skills/`. Key skills:

- `/weave` — Graph-first workflow orchestrator (INTAKE → CONTEXT → EXECUTE → CLOSE)
- `/fix-issue` — End-to-end issue resolution
- `/breadcrumbs` — Leave context for future sessions

See [CLAUDE.md](CLAUDE.md) for full skill documentation.

## Project Structure

```text
scripts/wv          # Main CLI entrypoint
scripts/lib/        # Shared library functions
scripts/cmd/        # Command implementations
mcp/                # MCP server (TypeScript)
.weave/             # Git-persisted graph state
.claude/skills/     # Procedural skills
docs/               # Documentation and proposals
tests/              # Test suites
```

## Getting Started

```bash
# Install
./install.sh

# Verify
wv health

# Start working
wv ready
wv work <id>
```
