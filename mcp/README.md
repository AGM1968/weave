# Weave MCP Server

MCP (Model Context Protocol) server that exposes Weave graph operations to AI assistants. Supports
**scope-based tool filtering** for context-silo'd subagent architectures.

## Installation

```bash
cd mcp
npm install
npm run build
```

## Quick Start

### Single server (all tools)

```bash
node mcp/dist/index.js
```

### Scoped servers (subagent silos)

```bash
node mcp/dist/index.js --scope=graph    # write operations only
node mcp/dist/index.js --scope=session  # workflow operations only
node mcp/dist/index.js --scope=inspect  # read-only operations only
```

## Scope System

The `--scope` flag partitions the 31 available tools into focused subsets. This is designed for **VS
Code's multi-server MCP architecture**, where each Copilot subagent can be given a different server
with only the tools it needs — reducing context window usage and preventing cross-concern tool
confusion.

### Scope definitions

| Scope       | Tools                                                                                                                                                                                                                                                                | Purpose                                    |
| ----------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------ |
| **graph**   | `weave_add`, `weave_link`, `weave_done`, `weave_batch_done`, `weave_list`, `weave_resolve`, `weave_update`, `weave_delete` (8)                                                                                                                                     | Create/modify/delete nodes and edges       |
| **session** | `weave_work`, `weave_ship`, `weave_recover`, `weave_quick`, `weave_overview`, `weave_close_session`, `weave_breadcrumbs`, `weave_plan`, `weave_edit_guard` (9)                                                                                                    | Workflow lifecycle management              |
| **lite**    | `weave_overview`, `weave_guide`, `weave_edit_guard`, `weave_status`, `weave_work`, `weave_done` (6)                                                                                                                                                                | Minimal task-tracking surface              |
| **inspect** | `weave_context`, `weave_search`, `weave_status`, `weave_health`, `weave_preflight`, `weave_sync`, `weave_tree`, `weave_learnings`, `weave_guide`, `weave_show`, `weave_quality_scan`, `weave_quality_hotspots`, `weave_quality_diff`, `weave_quality_functions` (14) | Read-only observation and query            |
| **all**     | All 31 tools                                                                                                                                                                                                                                                         | Full access (default, backward-compatible) |

### Design rationale

When an AI agent spawns subagents (e.g., a research subagent, a coding subagent, a review subagent),
each subagent inherits the full MCP tool set. This creates problems:

1. **Context bloat** — 31 tool definitions (~7K tokens) compete for limited context window
2. **Tool confusion** — a read-only research subagent shouldn't see `weave_ship`
3. **Accidental mutations** — an inspect-only subagent could accidentally call `weave_done`

Scoped servers solve all three by exposing only relevant tools per subagent role. Out-of-scope tool
calls are rejected with a clear error message.

### Server naming

Scoped servers announce themselves with a suffixed name for easy identification:

| Scope     | Server name                |
| --------- | -------------------------- |
| `all`     | `weave-mcp-server`         |
| `graph`   | `weave-mcp-server-graph`   |
| `session` | `weave-mcp-server-session` |
| `inspect` | `weave-mcp-server-inspect` |

### Error handling

Calling a tool outside the active scope returns an MCP error:

```json
{
  "content": [
    { "type": "text", "text": "Error: Tool \"weave_done\" is not available in scope \"inspect\"" }
  ],
  "isError": true
}
```

Invalid scope values cause the server to exit immediately with a non-zero exit code:

```txt
Invalid scope "bogus". Valid: graph, session, lite, inspect, all
```

## Client Configuration

### VS Code Copilot (`.vscode/mcp.json`)

The committed repo configuration currently registers **two servers**:
- `weave` — full access (default, backward-compatible)
- `weave-inspect` — read-only queries for audit and analysis work

Additional scoped servers (`graph`, `session`, `lite`) are supported by the binary. `graph` and
`session` remain the intended narrower surfaces for upcoming runtime-agent specialisation, but they
are not part of the checked-in `.vscode/mcp.json` yet.

```jsonc
{
  "servers": {
    // Full access — backward compatible, use for general work
    "weave": {
      "type": "stdio",
      "command": "node",
      "args": ["${workspaceFolder}/mcp/dist/index.js"],
      "env": { "WV_PATH": "${workspaceFolder}/scripts/wv" },
    },
    // Read-only queries — for research/review subagents
    "weave-inspect": {
      "type": "stdio",
      "command": "node",
      "args": ["${workspaceFolder}/mcp/dist/index.js", "--scope=inspect"],
      "env": { "WV_PATH": "${workspaceFolder}/scripts/wv" },
    },
  },
}
```

Optional local additions if you want stricter scope isolation:

```jsonc
"weave-graph": {
  "type": "stdio",
  "command": "node",
  "args": ["${workspaceFolder}/mcp/dist/index.js", "--scope=graph"],
  "env": { "WV_PATH": "${workspaceFolder}/scripts/wv" }
},
"weave-session": {
  "type": "stdio",
  "command": "node",
  "args": ["${workspaceFolder}/mcp/dist/index.js", "--scope=session"],
  "env": { "WV_PATH": "${workspaceFolder}/scripts/wv" }
},
"weave-lite": {
  "type": "stdio",
  "command": "node",
  "args": ["${workspaceFolder}/mcp/dist/index.js", "--scope=lite"],
  "env": { "WV_PATH": "${workspaceFolder}/scripts/wv" }
}
```

### Claude Desktop (`~/.config/claude/claude_desktop_config.json`)

```json
{
  "mcpServers": {
    "weave": {
      "command": "node",
      "args": ["/path/to/memory-system/mcp/dist/index.js"],
      "env": {
        "WV_PATH": "/path/to/memory-system/scripts/wv"
      }
    },
    "weave-inspect": {
      "command": "node",
      "args": ["/path/to/memory-system/mcp/dist/index.js", "--scope=inspect"],
      "env": {
        "WV_PATH": "/path/to/memory-system/scripts/wv"
      }
    }
  }
}
```

## Available Tools

### Graph scope — write operations (8 tools)

| Tool               | Description                                             | Required params      |
| ------------------ | ------------------------------------------------------- | -------------------- |
| `weave_add`        | Create a new node, returns generated ID                 | `text`               |
| `weave_link`       | Create a semantic edge between two nodes                | `from`, `to`, `type` |
| `weave_done`       | Mark a node as complete, optionally record a learning   | `id`                 |
| `weave_batch_done` | Complete multiple nodes at once                         | `ids`                |
| `weave_update`     | Modify node metadata, status, text, or alias            | `id`                 |
| `weave_list`       | List nodes with optional status/all filters             | —                    |
| `weave_resolve`    | Resolve conflicting nodes (winner/merge/defer strategy) | `ids`, `strategy`    |
| `weave_delete`     | Permanently remove a node (requires `force=true`)       | `id`, `force`        |

### Session scope — workflow lifecycle (9 tools)

| Tool                  | Description                                           | Required params |
| --------------------- | ----------------------------------------------------- | --------------- |
| `weave_work`          | Claim a node, sets WV_ACTIVE for subagent inheritance | `id`            |
| `weave_ship`          | Complete node + sync to git layer in one step         | `id`            |
| `weave_recover`       | Resume incomplete ship/sync/delete operations         | —               |
| `weave_quick`         | Quick-add a node and immediately start working on it  | `text`          |
| `weave_overview`      | Status + health + context policy + ready work         | —               |
| `weave_breadcrumbs`   | Save, show, or clear session breadcrumbs              | —               |
| `weave_plan`          | Import markdown plan as epic + tasks with GH issues   | `file`          |
| `weave_close_session` | Sync + git status + unpushed commits + active warning | —               |
| `weave_edit_guard`    | Pre-edit guard: require an active node before edits   | —               |

### Inspect scope — read-only queries (14 tools)

| Tool                      | Description                                            | Required params |
| ------------------------- | ------------------------------------------------------ | --------------- |
| `weave_context`           | Full Context Pack: node details, blockers, ancestors   | —               |
| `weave_search`            | Full-text search across nodes (supports stemming)      | `query`         |
| `weave_tree`              | View epic hierarchy as a tree (JSON output)            | —               |
| `weave_learnings`         | Query captured learnings (patterns/decisions/pitfalls) | —               |
| `weave_status`            | Compact summary: active work, ready count, blocked     | —               |
| `weave_health`            | Graph health check with score and issues               | —               |
| `weave_preflight`         | Pre-work validation: blockers, context, readiness      | `id`            |
| `weave_sync`              | Persist graph to disk, optionally sync GitHub issues   | —               |
| `weave_guide`             | Quick reference by workflow topic                      | —               |
| `weave_show`              | Single-node detail view (JSON output)                  | `id`            |
| `weave_quality_scan`      | Codebase quality metrics scan (60s timeout)            | —               |
| `weave_quality_hotspots`  | Ranked hotspot report with limit and threshold         | —               |
| `weave_quality_diff`      | Delta report vs previous scan                          | —               |
| `weave_quality_functions` | Per-function CC report with dispatch tagging           | —               |

## Development

```bash
# Build
npm run build

# Run tests (24 tests: tool calls, scope filtering, error handling)
npm test

# Watch mode
npm run dev
```

### Test coverage

The test suite verifies:

- **Default scope (`all`)** — all 31 tools listed, tool calls work, unknown tools rejected
- **`--scope=graph`** — only 8 graph tools listed, out-of-scope calls rejected
- **`--scope=session`** — only 9 session tools listed
- **`--scope=inspect`** — only 14 inspect tools listed
- **New tool handlers** — weave_show, weave_delete (with force guard), quality tools

### Adding new tools

1. Add the tool definition to the `TOOLS` array in `index.ts`
2. Add a handler case in the `handleTool` switch
3. Add the tool name to the appropriate scope in `SCOPE_TOOLS`
4. Update the test tool count assertion

## Environment Variables

| Variable    | Description                         | Default       |
| ----------- | ----------------------------------- | ------------- |
| `WV_PATH`   | Path to wv CLI binary               | Auto-detected |
| `WV_ACTIVE` | Active node ID (inherited by tools) | —             |

## Agent Pairing

The table below shows the intended scoped pairing for specialised agents. In the current checked-in
VS Code configuration, `epic-planner` and `weave-guide` still run against the full `weave` server,
while `learning-curator` already uses `weave-inspect`.

| Agent file                           | Role                          | MCP scope | Tools available                                                                                                                                                                                                                                                 |
| ------------------------------------ | ----------------------------- | --------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `.claude/agents/epic-planner.md`     | Planning & graph construction | `weave-graph` (planned) / `weave` (current) | Primary tools are `weave_add`, `weave_link`, `weave_done`, `weave_batch_done`, `weave_update`, `weave_list`, `weave_resolve`, `weave_delete`                                                                        |
| `.claude/agents/weave-guide.md`      | Workflow lifecycle guidance   | `weave-session` (planned) / `weave` (current) | Primary tools are `weave_work`, `weave_ship`, `weave_recover`, `weave_quick`, `weave_overview`, `weave_breadcrumbs`, `weave_plan`, `weave_close_session`, `weave_edit_guard`                                      |
| `.claude/agents/learning-curator.md` | Read-only analysis & curation | `weave-inspect` | `weave_context`, `weave_search`, `weave_tree`, `weave_learnings`, `weave_status`, `weave_health`, `weave_preflight`, `weave_sync`, `weave_guide`, `weave_show`, `weave_quality_scan`, `weave_quality_hotspots`, `weave_quality_diff`, `weave_quality_functions` |

This keeps the roadmap visible without pretending the extra scoped servers are already wired into the
checked-in VS Code config. The learning curator gets the narrower read-only server today; the other
two agents are expected to move onto their scoped servers as runtime-agent support lands.

## Architecture

```txt
┌─────────────────────────────────────────────────────────┐
│                     VS Code Copilot                     │
│                                                         │
│  ┌───────────────┐ ┌───────────────┐ ┌───────────────┐  │
│  │ learning-     │ │ epic-         │ │ weave-        │  │
│  │ curator.md    │ │ planner.md    │ │ guide.md      │  │
│  │ (read/analyze)│ │ (plan/create) │ │ (workflow)    │  │
│  └──────┬────────┘ └──────┬────────┘ └──────┬────────┘  │
│         │                 │                 │           │
└─────────┼─────────────────┼─────────────────┼───────────┘
          │                 │                 │
     ┌────▼──────┐    ┌────▼──────┐    ┌─────▼─────┐
     │ --scope=  │    │ --scope=  │    │ --scope=  │
     │ inspect   │    │ graph     │    │ session   │
     │(14 tools) │    │ (8 tools) │    │ (9 tools) │
     └────┬──────┘    └────┬──────┘    └─────┬─────┘
          │                │                 │
          └────────────────┼─────────────────┘
                           │
                      ┌────▼─────┐
                      │  wv CLI  │
                      │ (SQLite) │
                      └──────────┘
```

All optional scoped servers share the same `wv` CLI and SQLite database — scoping is purely at the MCP
tool-listing layer, not at the data layer. Any server can execute any `wv` command internally; the
scope only controls which tools are **advertised and accepted** via the MCP protocol.
