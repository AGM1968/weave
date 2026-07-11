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

The `--scope` flag partitions the 45 available tools into focused subsets. This is designed for **VS
Code's multi-server MCP architecture**, where each Copilot subagent can be given a different server
with only the tools it needs — reducing context window usage and preventing cross-concern tool
confusion.

### Scope definitions

| Scope       | Tools                                                                                                                                                                                                                                                                                                                                                                                                          | Purpose                                    |
| ----------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------ |
| **graph**   | `weave_add`, `weave_link`, `weave_unlink`, `weave_block`, `weave_unarchive`, `weave_done`, `weave_batch_done`, `weave_list`, `weave_resolve`, `weave_update`, `weave_touch`, `weave_record_edit`, `weave_delete` (13)                                                                                                                                                                                        | Create/modify/delete nodes and edges       |
| **session** | `weave_work`, `weave_ready`, `weave_ship`, `weave_recover`, `weave_quick`, `weave_overview`, `weave_bootstrap`, `weave_close_session`, `weave_trails`, `weave_breadcrumbs` (deprecated alias), `weave_plan`, `weave_edit_guard` (12)                                                                                                                                                                           | Workflow lifecycle management              |
| **lite**    | `weave_overview`, `weave_bootstrap`, `weave_guide`, `weave_edit_guard`, `weave_status`, `weave_work`, `weave_done` (7)                                                                                                                                                                                                                                                                                         | Minimal task-tracking surface              |
| **inspect** | `weave_context`, `weave_search`, `weave_query`, `weave_status`, `weave_ready`, `weave_impact`, `weave_health`, `weave_preflight`, `weave_bootstrap`, `weave_sync`, `weave_tree`, `weave_learnings`, `weave_guide`, `weave_show`, `weave_quality_scan`, `weave_quality_hotspots`, `weave_quality_diff`, `weave_quality_functions`, `weave_structural_search`, `weave_quality_patterns`, `weave_code_search`, `weave_index` (22) | Read-only observation and query            |
| **all**     | All 45 tools                                                                                                                                                                                                                                                                                                                                                                                                   | Full access (default, backward-compatible) |

### Scope lifecycle

The checked-in lifecycle is client-managed stdio: the MCP client starts each configured server
process and restart/cleanup is done by restarting the client. `mcp/contract.json` is the
machine-readable source of truth for these mappings.

| Server          | Scope     | Start when                                                                                    | Intended clients                                  | Shipped |
| --------------- | --------- | --------------------------------------------------------------------------------------------- | ------------------------------------------------- | ------- |
| `weave`         | `all`     | Default server for general interactive work or clients that cannot select narrower scopes      | Copilot chat, general MCP clients                 | yes     |
| `weave-session` | `session` | Workflow lifecycle clients that need claim, edit guard, close, recovery, or handoff tools     | Copilot chat, workflow subagents                  | yes     |
| `weave-lite`    | `lite`    | Constrained contexts that need only bootstrap/status/work/done/edit-guard basics              | Copilot chat, Codex optional, constrained agents  | yes     |
| `weave-inspect` | `inspect` | Read-only research, review, audit, search, health, and quality inspection workflows           | Copilot chat, read-only subagents, review agents  | yes     |
| `weave-graph`   | `graph`   | Optional local server for agents intentionally creating, linking, updating, or deleting graph nodes | Planning and graph-construction agents       | no      |

### Design rationale

When an AI agent spawns subagents (e.g., a research subagent, a coding subagent, a review subagent),
each subagent inherits the full MCP tool set. This creates problems:

1. **Context bloat** — 45 tool definitions compete for limited context window
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

The machine-readable MCP lifecycle/config contract lives at `mcp/contract.json`. It names the
supported scopes, shipped server entries, intended clients, required/recommended environment
variables, startup report schema, and default network policy. Treat it as the operator-facing source
of truth when wiring MCP clients outside the generated `.mcp.json`/`.vscode/mcp.json` files.

### VS Code Copilot (`.mcp.json`)

The committed repo configuration currently registers **four servers**:

- `weave` — full access (default, backward-compatible)
- `weave-session` — workflow lifecycle tools only
- `weave-lite` — minimal task-tracking surface
- `weave-inspect` — read-only queries for audit and analysis work

The `graph` scoped server remains an optional local addition when you want a write-only MCP surface
for specialised subagents.

```jsonc
{
  "servers": {
    // Full access — backward compatible, use for general work
    "weave": {
      "type": "stdio",
      "command": "node",
      "args": ["${workspaceFolder}/mcp/dist/index.js"],
      "env": {
        "WV_PATH": "${workspaceFolder}/scripts/wv",
        "WV_PROJECT_ROOT": "${workspaceFolder}",
        "WV_AGENT_ID": "copilot-${workspaceFolderBasename}",
      },
    },
    // Workflow lifecycle only — claim/ship/close-session/edit-guard surfaces
    "weave-session": {
      "type": "stdio",
      "command": "node",
      "args": ["${workspaceFolder}/mcp/dist/index.js", "--scope=session"],
      "env": {
        "WV_PATH": "${workspaceFolder}/scripts/wv",
        "WV_PROJECT_ROOT": "${workspaceFolder}",
        "WV_AGENT_ID": "copilot-${workspaceFolderBasename}",
      },
    },
    // Minimal task-tracking surface for lighter-weight Copilot subagents
    "weave-lite": {
      "type": "stdio",
      "command": "node",
      "args": ["${workspaceFolder}/mcp/dist/index.js", "--scope=lite"],
      "env": {
        "WV_PATH": "${workspaceFolder}/scripts/wv",
        "WV_PROJECT_ROOT": "${workspaceFolder}",
        "WV_AGENT_ID": "copilot-${workspaceFolderBasename}",
      },
    },
    // Read-only queries — for research/review subagents
    "weave-inspect": {
      "type": "stdio",
      "command": "node",
      "args": ["${workspaceFolder}/mcp/dist/index.js", "--scope=inspect"],
      "env": {
        "WV_PATH": "${workspaceFolder}/scripts/wv",
        "WV_PROJECT_ROOT": "${workspaceFolder}",
        "WV_AGENT_ID": "copilot-${workspaceFolderBasename}",
      },
    },
  },
}
```

`WV_PROJECT_ROOT` pins all `wv` subprocess calls to the intended repository, so edit guards and
other workflow checks do not depend on the MCP server's inherited cwd. `WV_AGENT_ID` pins the MCP
server's Weave claim identity so Copilot does not inherit ambiguous host markers from another agent
session.

Optional local additions if you want stricter scope isolation:

```jsonc
"weave-graph": {
  "type": "stdio",
  "command": "node",
  "args": ["${workspaceFolder}/mcp/dist/index.js", "--scope=graph"],
  "env": {
    "WV_PATH": "${workspaceFolder}/scripts/wv",
    "WV_PROJECT_ROOT": "${workspaceFolder}",
    "WV_AGENT_ID": "copilot-${workspaceFolderBasename}"
  }
},
"weave-session": {
  "type": "stdio",
  "command": "node",
  "args": ["${workspaceFolder}/mcp/dist/index.js", "--scope=session"],
  "env": {
    "WV_PATH": "${workspaceFolder}/scripts/wv",
    "WV_PROJECT_ROOT": "${workspaceFolder}",
    "WV_AGENT_ID": "copilot-${workspaceFolderBasename}"
  }
},
"weave-lite": {
  "type": "stdio",
  "command": "node",
  "args": ["${workspaceFolder}/mcp/dist/index.js", "--scope=lite"],
  "env": {
    "WV_PATH": "${workspaceFolder}/scripts/wv",
    "WV_PROJECT_ROOT": "${workspaceFolder}",
    "WV_AGENT_ID": "copilot-${workspaceFolderBasename}"
  }
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
        "WV_PATH": "/path/to/memory-system/scripts/wv",
        "WV_PROJECT_ROOT": "/path/to/your/repo",
        "WV_AGENT_ID": "mcp-your-repo"
      }
    },
    "weave-inspect": {
      "command": "node",
      "args": ["/path/to/memory-system/mcp/dist/index.js", "--scope=inspect"],
      "env": {
        "WV_PATH": "/path/to/memory-system/scripts/wv",
        "WV_PROJECT_ROOT": "/path/to/your/repo",
        "WV_AGENT_ID": "mcp-your-repo"
      }
    }
  }
}
```

## Available Tools

### Graph scope — write operations (13 tools)

| Tool               | Description                                                                                                                                                                                                 | Required params      |
| ------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------- |
| `weave_add`        | Create a new node, returns generated ID                                                                                                                                                                     | `text`               |
| `weave_link`       | Create a semantic edge between two nodes                                                                                                                                                                    | `from`, `to`, `type` |
| `weave_done`       | Mark a node as complete, optionally record a learning. Accepts `learning` (raw string) and/or typed `decision`/`pattern`/`pitfall` params — when both are provided, raw is appended after structured params | `id`                 |
| `weave_batch_done` | Complete multiple nodes at once. Same learning merge behavior as `weave_done`                                                                                                                               | `ids`                |
| `weave_update`     | Modify node metadata, status, text, or alias                                                                                                                                                                | `id`                 |
| `weave_touch`      | Fire-and-forget metadata or intent update                                                                                                                                                                   | `id`                 |
| `weave_list`       | List nodes with optional status/all filters                                                                                                                                                                 | —                    |
| `weave_resolve`    | Resolve conflicting nodes (winner/merge/defer strategy)                                                                                                                                                     | `ids`, `strategy`    |
| `weave_delete`     | Permanently remove a node (requires `force=true`)                                                                                                                                                           | `id`, `force`        |

### Session scope — workflow lifecycle (12 tools)

| Tool                  | Description                                                                                                                                    | Required params |
| --------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------- | --------------- |
| `weave_work`          | Claim a node, sets WV_ACTIVE for subagent inheritance. Pass `reopen=true` to reopen a done node — omitting it on a done node returns an error. | `id`            |
| `weave_ready`         | List unblocked nodes ready to claim                                                                                                            | —               |
| `weave_ship`          | Bounded local close + sync. GitHub sync is returned as a CLI fallback unless explicitly enabled. Same learning merge as `weave_done`           | `id`            |
| `weave_recover`       | Resume incomplete ship/sync/delete operations                                                                                                  | —               |
| `weave_quick`         | Quick-add a node and immediately start working on it                                                                                           | `text`          |
| `weave_overview`      | Status + health + context policy + ready work                                                                                                  | —               |
| `weave_bootstrap`     | Single-call session snapshot: status + context + ready + learnings                                                                             | —               |
| `weave_trails`        | Save, show, or clear session trails (append-only handoff notes)                                                                                | —               |
| `weave_plan`          | Import markdown plan as epic + tasks with GH issues                                                                                            | `file`          |
| `weave_close_session` | Bounded local sync + repo-status check + unpushed commit/active-node warnings                                                                  | —               |
| `weave_edit_guard`    | Pre-edit guard: require an active node before edits                                                                                            | —               |

### Inspect scope — read-only queries (22 tools)

| Tool                      | Description                                                     | Required params |
| ------------------------- | --------------------------------------------------------------- | --------------- |
| `weave_context`           | Full Context Pack: node details, blockers, ancestors            | —               |
| `weave_search`            | Full-text search across nodes (supports stemming)               | `query`         |
| `weave_query`             | Structured node query by status, type, or metadata              | —               |
| `weave_tree`              | View epic hierarchy as a tree (JSON output)                     | —               |
| `weave_learnings`         | Query captured learnings (patterns/decisions/pitfalls)          | —               |
| `weave_status`            | Compact summary: active work, ready count, blocked              | —               |
| `weave_ready`             | List unblocked nodes ready to claim                             | —               |
| `weave_health`            | Graph health check with score and issues                        | —               |
| `weave_preflight`         | Pre-work validation: blockers, context, readiness               | `id`            |
| `weave_bootstrap`         | Single-call session snapshot for read-only clients              | —               |
| `weave_sync`              | Persist graph to disk; GitHub sync uses CLI fallback by default | —               |
| `weave_guide`             | Quick reference by workflow topic                               | —               |
| `weave_show`              | Single-node detail view (JSON output)                           | `id`            |
| `weave_quality_scan`      | Codebase quality metrics scan (60s timeout)                     | —               |
| `weave_quality_hotspots`  | Ranked hotspot report with limit and threshold                  | —               |
| `weave_quality_diff`      | Delta report vs previous scan                                   | —               |
| `weave_quality_functions` | Per-function CC report with dispatch tagging                    | —               |
| `weave_quality_patterns`  | Structural + prose pattern scan/list                            | —               |
| `weave_structural_search` | Structural code search via ast-grep patterns                    | `pattern`       |
| `weave_code_search`       | Semantic code search via local index                            | `query`         |
| `weave_index`             | Build or update the local code search index                     | —               |

## Development

```bash
# Build
npm run build

# Run tests (tool calls, scope filtering, error handling)
npm test

# Watch mode
npm run dev
```

### Test coverage

The test suite verifies:

- **Default scope (`all`)** — all 45 tools listed, tool calls work, unknown tools rejected
- **`--scope=graph`** — only 13 graph tools listed, out-of-scope calls rejected
- **`--scope=session`** — only 12 session tools listed
- **`--scope=inspect`** — only 22 inspect tools listed
- **New tool handlers** — weave_show, weave_delete (with force guard), quality tools

Codex sandbox note: `npm --prefix mcp run build` is a reliable in-sandbox compile check, but the
full Vitest MCP integration suite spawns stdio servers and nested `wv` calls and can hang silently
inside Codex. Run the full MCP suite from the host shell or SSH dev shell; use the Codex build check
plus targeted code review as the fallback signal.

### Adding new tools

1. Add the tool definition to the `TOOLS` array in `index.ts`
2. Add a handler case in the `handleTool` switch
3. Add the tool name to the appropriate scope in `SCOPE_TOOLS`
4. Update `mcp/contract.json` scope counts and lifecycle metadata
5. Update the README tool inventory if the human-readable list changed

## Environment Variables

| Variable               | Description                                                                   | Default             |
| ---------------------- | ----------------------------------------------------------------------------- | ------------------- |
| `WV_PATH`              | Path to wv CLI binary                                                         | Auto-detected       |
| `WV_PROJECT_ROOT`      | Repo root passed to MCP-spawned `wv` commands                                 | Current process cwd |
| `WV_AGENT_ID`          | Explicit Weave claim/provenance identity for MCP-spawned `wv` commands        | Auto-detected       |
| `WV_ACTIVE`            | Active node ID (inherited by tools)                                           | —                   |
| `WV_MCP_CALL_LOG`      | JSONL sink for per-response MCP telemetry                                     | Disabled            |
| `WV_MCP_ALLOW_NETWORK` | Allow MCP lifecycle tools to run GitHub/network sync directly (`1` = enabled) | Disabled            |
| `WV_MCP_STARTUP_REPORT` | Emit structured startup JSON to stderr (`1` = enabled)                       | Disabled            |

Startup/readiness checks:

```bash
node mcp/dist/index.js --scope=lite --health-check
```

The health check prints a `weave-mcp-startup.v1` JSON object with scope, tool count, `wv` path,
project root, agent identity, telemetry settings, and process id, then exits without starting the
stdio server.

`--instrument` prints payload and call summaries to stderr for local debugging.
`WV_MCP_CALL_LOG=/path/to/mcp_calls.jsonl` persists each MCP response as JSONL with `source=mcp`,
tool name, scope, payload bytes, elapsed ms, and response metadata.

MCP lifecycle tools keep the mounted server responsive by default: `weave_done`, `weave_batch_done`,
and `weave_ship` close locally with `--no-gh`, while `weave_sync` and `weave_close_session` run
local sync only. When GitHub sync is requested, the response includes the CLI command to run outside
MCP. Set `WV_MCP_ALLOW_NETWORK=1` only for MCP clients where long GitHub/network calls are
acceptable.

## Agent Pairing

The table below shows the intended scoped pairing for specialised agents. In the current checked-in
VS Code configuration, `epic-planner` and `weave-guide` still run against the full `weave` server,
while `learning-curator` already uses `weave-inspect`.

| Agent file                           | Role                          | MCP scope                                     | Tools available                                                                                                                                                                                                                                                                                                                                                                                           |
| ------------------------------------ | ----------------------------- | --------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `.claude/agents/epic-planner.md`     | Planning & graph construction | `weave-graph` (planned) / `weave` (current)   | Primary tools are `weave_add`, `weave_link`, `weave_done`, `weave_batch_done`, `weave_update`, `weave_list`, `weave_resolve`, `weave_delete`                                                                                                                                                                                                                                                              |
| `.claude/agents/weave-guide.md`      | Workflow lifecycle guidance   | `weave-session` (planned) / `weave` (current) | Primary tools are `weave_work`, `weave_ship`, `weave_recover`, `weave_quick`, `weave_overview`, `weave_bootstrap`, `weave_trails`, `weave_plan`, `weave_close_session`, `weave_edit_guard`                                                                                                                                                                                                                |
| `.claude/agents/learning-curator.md` | Read-only analysis & curation | `weave-inspect`                               | `weave_context`, `weave_search`, `weave_query`, `weave_tree`, `weave_learnings`, `weave_status`, `weave_ready`, `weave_health`, `weave_preflight`, `weave_bootstrap`, `weave_sync`, `weave_guide`, `weave_show`, `weave_quality_scan`, `weave_quality_hotspots`, `weave_quality_diff`, `weave_quality_functions`, `weave_quality_patterns`, `weave_structural_search`, `weave_code_search`, `weave_index` |

This keeps the roadmap visible without pretending the extra scoped servers are already wired into
the checked-in VS Code config. The learning curator gets the narrower read-only server today; the
other two agents are expected to move onto their scoped servers as runtime-agent support lands.

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
     │(22 tools) │    │(13 tools) │    │(12 tools) │
     └────┬──────┘    └────┬──────┘    └─────┬─────┘
          │                │                 │
          └────────────────┼─────────────────┘
                           │
                      ┌────▼─────┐
                      │  wv CLI  │
                      │ (SQLite) │
                      └──────────┘
```

All optional scoped servers share the same `wv` CLI and SQLite database — scoping is purely at the
MCP tool-listing layer, not at the data layer. Any server can execute any `wv` command internally;
the scope only controls which tools are **advertised and accepted** via the MCP protocol.
