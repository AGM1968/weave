# Weave — Graph-Based Workflow for AI Coding Agents

Token-optimized task tracking for agentic workflows. SQLite on tmpfs, managed by the `wv` CLI.

## Why Weave

| Aspect           | Traditional RAG               | Weave                               |
| ---------------- | ----------------------------- | ----------------------------------- |
| Retrieval        | Vector search + reranking     | Native grep/read (trail-following)  |
| Infrastructure   | Vector DB + embeddings + APIs | None (SQLite + tmpfs)               |
| Relationships    | Implicit (embeddings)         | Explicit (8 typed edge types)       |
| Token efficiency | Moderate (irrelevant chunks)  | High (context packs, not full dump) |
| Cross-references | Often missed                  | Semantic edges + graph traversal    |

## Installation

```bash
# One-line install (macOS/Linux)
curl -sSL https://raw.githubusercontent.com/AGM1968/weave/main/install.sh | bash

# Or clone and install locally
git clone https://github.com/AGM1968/weave
cd weave
./install.sh

# With MCP server for IDE integration
./install.sh --with-mcp
```

This installs:

- `wv` CLI and helper commands to `~/.local/bin/`
- MCP server for VS Code Copilot and Claude Code (optional, with `--with-mcp`)

**Requirements:** `sqlite3` (>= 3.35), `jq`, `git`. Optional: `gh` (for GitHub sync), `node` (for
MCP server).

Run `wv doctor` to verify your installation.

## Quick Start

**Prerequisites:** An existing git repo and `jq` installed.

### 1. Initialize your repo

```bash
cd /path/to/your/project
wv-init-repo --agent=copilot     # VS Code: .vscode/mcp.json + copilot-instructions.md
# Or: wv-init-repo --agent=claude   # Claude Code: hooks, skills, settings
# Or: wv-init-repo --agent=all      # Both agents in same repo
wv selftest                      # Verify everything works
```

This creates `.weave/` (graph storage), git hooks (commit enforcement), and agent-specific config.
Each repo gets its own isolated database on tmpfs.

### 2. Create a task

```bash
wv add "Fix login timeout bug" --gh    # Creates node + linked GitHub issue
```

### 3. Work on it

```bash
wv work wv-a1b2                        # Claim the task (sets active)
# ... make your code changes ...
wv done wv-a1b2 --learning="Session cookie expires before JWT — add refresh logic"
```

### 4. Build a task hierarchy

```bash
wv add "Auth overhaul" --alias=auth-epic --gh
wv add "Implement JWT" --alias=jwt --gh
wv link jwt auth-epic --type=implements
wv tree                                # View the hierarchy
```

### 5. Save and sync

```bash
wv sync --gh                           # Persist graph + sync GitHub issues
git push
```

Your AI coding agent follows the workflow automatically via generated instructions and MCP tools.

## Core Workflow

```text
wv ready          Find unblocked work
wv work <id>      Claim a task (one active at a time)
wv done <id>      Complete with --learning="..."
wv sync --gh      Persist graph + sync GitHub issues
git push          Push state to remote
```

**Commit enforcement:** A pre-commit hook blocks commits without an active Weave node. Override with
`git commit --no-verify` when needed.

## Command Reference

### Task Management

| Command                            | Description                     |
| ---------------------------------- | ------------------------------- |
| `wv add "text" --gh`               | Create node + GitHub issue      |
| `wv work <id>`                     | Claim task (sets active)        |
| `wv done <id> --learning="..."`    | Complete with captured learning |
| `wv quick "text" --learning="..."` | Create + close in one step      |
| `wv show <id>`                     | View node details               |
| `wv list --status=todo`            | List nodes by status            |
| `wv ready`                         | Show unblocked work             |
| `wv search "query"`                | Full-text search across nodes   |

### Graph Operations

| Command                                 | Description                 |
| --------------------------------------- | --------------------------- |
| `wv link <from> <to> --type=implements` | Create semantic edge        |
| `wv block <id> --by=<blocker>`          | Set dependency              |
| `wv tree`                               | View hierarchy              |
| `wv context <id> --json`                | Get full Context Pack       |
| `wv related <id>`                       | Show semantic relationships |
| `wv path <from> <to>`                   | Find path between nodes     |
| `wv edge-types`                         | List valid edge types       |

### Knowledge Capture

| Command                                | Description                     |
| -------------------------------------- | ------------------------------- |
| `wv learnings`                         | View all captured learnings     |
| `wv learnings --grep="topic"`          | Search learnings by keyword     |
| `wv audit-pitfalls`                    | Track resolved vs open pitfalls |
| `wv audit-pitfalls --only-unaddressed` | Show unresolved pitfalls only   |

### System

| Command          | Description                        |
| ---------------- | ---------------------------------- |
| `wv health`      | Graph health check (0-100 score)   |
| `wv doctor`      | Installation health check          |
| `wv mcp-status`  | MCP server health check            |
| `wv selftest`    | End-to-end smoke test              |
| `wv sync --gh`   | Persist graph + sync GitHub issues |
| `wv plan <file>` | Import markdown plan as tasks      |
| `wv prune`       | Archive old completed nodes        |

### Sprint Planning

```bash
wv plan --template                     # Scaffold a plan document
# Edit the plan...
wv plan plan.md --sprint=1 --gh        # Import as epic + tasks with GitHub issues
```

## Edge Types

8 semantic edge types for explicit relationships:

| Type          | Meaning                                |
| ------------- | -------------------------------------- |
| `blocks`      | Target blocked until source completes  |
| `implements`  | Target implements source concept       |
| `relates_to`  | General semantic relationship          |
| `references`  | Target references source               |
| `contradicts` | Conflicting decisions (triggers alert) |
| `supersedes`  | Target replaces source                 |
| `obsoletes`   | Target makes source obsolete           |
| `addresses`   | Source fixes pitfall in target         |

## Context Packs

Before starting work, get comprehensive context:

```bash
wv context wv-xxxx --json
```

Returns blockers, ancestors with learnings, related nodes, pitfalls, and contradictions. Cached per
session with automatic invalidation on graph changes.

## MCP Server

22 tools for IDE integration (VS Code Copilot, Claude Code):

| MCP Tool              | CLI Equivalent   | Description                         |
| --------------------- | ---------------- | ----------------------------------- |
| `weave_overview`      | `wv status`      | Session start overview              |
| `weave_work`          | `wv work`        | Claim node + return context         |
| `weave_ship`          | `wv ship`        | Complete + sync in one step         |
| `weave_quick`         | `wv quick`       | Create + close (trivial tasks)      |
| `weave_add`           | `wv add`         | Create a new node                   |
| `weave_done`          | `wv done`        | Mark complete with learnings        |
| `weave_batch_done`    | `wv batch-done`  | Complete multiple nodes at once     |
| `weave_update`        | `wv update`      | Modify node metadata/status/text    |
| `weave_list`          | `wv list`        | List nodes with filters             |
| `weave_search`        | `wv search`      | Full-text search                    |
| `weave_context`       | `wv context`     | Context Pack for a node             |
| `weave_link`          | `wv link`        | Create semantic edges               |
| `weave_tree`          | `wv tree`        | View epic hierarchy as a tree       |
| `weave_learnings`     | `wv learnings`   | Query captured learnings            |
| `weave_status`        | `wv status`      | Status summary                      |
| `weave_health`        | `wv health`      | Graph health check                  |
| `weave_preflight`     | `wv preflight`   | Pre-action checks for a node        |
| `weave_sync`          | `wv sync`        | Persist graph + optional GH sync    |
| `weave_resolve`       | `wv resolve`     | Resolve contradiction between nodes |
| `weave_breadcrumbs`   | `wv breadcrumbs` | Save/show/clear session breadcrumbs |
| `weave_plan`          | `wv plan`        | Import markdown plan as epic+tasks  |
| `weave_close_session` | `wv sync --gh`   | End-of-session cleanup              |

Install: `./install.sh --with-mcp` or `./install-mcp.sh`

Verify: `wv mcp-status`

## GitHub Integration

Bidirectional sync between Weave nodes and GitHub issues:

- `wv add "text" --gh` creates a linked GitHub issue
- `wv done <id>` auto-closes the linked issue with learnings + commit links
- `wv sync --gh` syncs all changes (status, labels, progress comments)
- Mermaid dependency graphs in epic issues
- `weave:active`, `weave:blocked`, `epic`, `feature` labels auto-applied

**Requirements:** `gh` CLI authenticated (`gh auth login`).

## Architecture

```text
AI Agent (Copilot / Claude Code)
        |
        v
   MCP Server (22 tools)  <-->  wv CLI
        |                          |
        v                          v
   SQLite on tmpfs           .weave/state.sql
   (/dev/shm/weave/<hash>)   (git-persisted)
        |
        v
   GitHub Issues (bidirectional sync)
```

- **Hot zone:** SQLite database on tmpfs for sub-millisecond queries
- **Cold storage:** `.weave/state.sql` dumped to git for persistence across reboots
- **Per-repo isolation:** Each repo gets a namespaced hot zone (md5 hash of repo root)
- **Auto-restore:** If hot zone DB is missing, auto-loads from `state.sql` on first access

## Upgrading

Weave auto-detects older installations:

- **Pre-v1.2 global hot zone:** If `/dev/shm/weave/brain.db` exists (old shared layout), it
  auto-migrates to the per-repo namespaced path on first access.
- **Schema migrations:** Run automatically on DB load (edges, aliases, FTS5, virtual columns).

To update: `wv-update` or re-run `./install.sh`.

## License

AGPL-3.0
