# Memory System — v6.0 (Weave)

Token-optimized memory for agentic workflows using an in-memory graph system with SQLite + tmpfs,
managed by the `wv` CLI.

## Philosophy

> Weave's are trails.

With 200k+ token context windows, chunking/embedding overhead is unnecessary for project-specific
knowledge. Trail-following (`grep → read → resolve`) is more accurate and token-efficient than
vector search.

## How It Works

```text
┌─────────────────────────────────────────────────────────┐
│                    Claude Code Agent                    │
│  • Native grep/glob/read-file (trail-following)         │
│  • SessionStart hook → context-guard.sh                 │
└─────────────────────────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────┐
│              Weave In-Memory Graph (wv)                 │
│  • SQLite on tmpfs (/dev/shm) with mmap                 │
│  • 8 edge types: blocks, relates_to, implements, etc.   │
│  • Recursive CTEs for graph traversal                   │
│  • WAL mode for crash safety                            │
│  • .dump to SQL text for git persistence                │
│  • Git-backed storage (.weave/)                         │
└─────────────────────────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────┐
│                    GitHub Issues                        │
│  • Visibility for external tracking                     │
│  • Bidirectional sync via scripts                       │
└─────────────────────────────────────────────────────────┘
```

## Installation

```bash
# One-line install (macOS/Linux)
curl -sSL https://raw.githubusercontent.com/AGM1968/memory-system/main/install.sh | bash

# Or clone and install locally
git clone https://github.com/AGM1968/memory-system
cd memory-system
./install.sh

# With MCP server for IDE integration
./install.sh --with-mcp
```

This installs:

- `wv` CLI and helper commands to `~/.local/bin/`
- MCP server for VS Code and Claude Code (optional, with `--with-mcp`)

## Quick Start (5 minutes)

**Prerequisites:** An existing git repo and `jq` installed.

### 1. Initialize your repo (~1 min)

```bash
cd /path/to/your/project
wv-init-repo --agent=copilot     # VS Code: .vscode/mcp.json + copilot-instructions.md
# Or: wv-init-repo --agent=claude   # Claude Code: hooks, skills, settings
# Or: wv-init-repo --agent=all      # Both agents in same repo
wv-init-repo --update            # Update existing repo to latest skills/hooks/agents
wv selftest                      # Verify everything works (10/10 checks)
```

This creates `.weave/` (graph storage), git hooks (commit enforcement), and agent-specific config.
Each repo gets its own isolated database on tmpfs — multiple repos can run Weave simultaneously.

### 2. Create your first task (~1 min)

```bash
wv add "Fix login timeout bug" --gh  # Returns wv-a1b2 + creates GitHub issue
wv show wv-a1b2                      # View node details
```

The `--gh` flag creates a linked GitHub issue. `wv done` auto-closes it.

### 3. Work on it (~2 min)

```bash
wv work wv-a1b2                  # Sets status to active
# ... make your code changes ...
wv done wv-a1b2 --learning="pitfall: Session cookie expires before JWT"
```

### 4. Build a task hierarchy (~1 min)

```bash
wv add "Auth overhaul" --alias=auth-epic           # Epic
wv add "Implement JWT" --alias=jwt                  # Task
wv link jwt auth-epic --type=implements             # Link task to epic
wv block jwt --by=auth-epic                         # Set dependency
wv tree                                             # View the hierarchy
```

### 5. Save and sync

```bash
wv sync --gh                     # Persist graph + sync GitHub issues
git add .weave/                  # Stage graph state
git diff --cached --quiet || git commit -m "chore(weave): sync state [skip ci]"
git push                         # Push graph state to remote
```

**That's it.** Your AI coding agent (Copilot or Claude) will follow the workflow automatically via
the generated instructions and MCP tools.

## Token Saving Features

### 1. Context Load Policy

On session start, `context-guard.sh` emits a load policy based on repo size:

```txt
policy: MEDIUM
├─ Prefer grep before read
├─ Avoid full-file reads >500 lines
└─ Use read_range for large files
```

Policies: `HIGH` (fresh session) → `MEDIUM` (default) → `LOW` (large repo/history)

### 2. Reference Resolution

Extract cross-references and get follow-up commands:

```bash
wv refs docs/design.md
# References found:
#   1. wv-a1b2 → wv show wv-a1b2
#   2. #15     → gh issue view 15
#   3. ADR-003 → rg -l "ADR-003" docs/
```

Prevents the "Scenario" where cross-references are missed.

### 3. Learnings Capture

When closing nodes, capture reusable knowledge:

```bash
wv done <id> --learning="decision: Why this choice | pattern: Reusable technique"
```

Or update metadata separately:

```bash
wv update <id> --metadata='{"decision":"Use polling over websockets","pitfall":"Rate limits on API"}'
wv done <id>
```

### 4. Pitfall Tracking

Track which problems have been addressed and which remain open:

```bash
# View all pitfalls with resolution status
wv audit-pitfalls

# See only unresolved issues
wv audit-pitfalls --only-unaddressed

# Link fixes to problems (via metadata)
wv update wv-fix1 --metadata='{"addresses":["wv-problem1"],"decision":"Added retry logic","pattern":"Always handle transient errors"}'
wv done wv-fix1

# View relationships
wv learnings --node=wv-fix1 --show-graph
```

## Procedural Knowledge Layer

### Primary Interface: /weave Orchestrator

**`/weave`** — Graph-first workflow orchestrator with four phases:

```bash
/weave wv-xxxxxx            # Work on specific node
/weave "Fix authentication" # Create node and start work
/weave                      # Show ready work and pick one
```

**Four Phases:**

1. **INTAKE** — Select or create work
   - Validates node exists and is claimable
   - Creates new nodes from text descriptions
   - Shows ready work if no input provided

2. **CONTEXT** — Mandatory graph query
   - Generates Context Pack (blockers, ancestors, related, pitfalls)
   - Hard stop on contradictions
   - Surfaces relevant learnings from parent nodes

3. **EXECUTE** — Do the work
   - Enforces scope boundaries (wv-guard-scope)
   - Detects stuck loops (wv-detect-loop)
   - Monitors for scope expansion

4. **CLOSE** — Complete with learnings
   - Requires verification evidence (wv-verify-complete)
   - Captures decision/pattern/pitfall
   - Links to addressed pitfalls
   - Syncs to GitHub issues

The orchestrator automatically invokes internal skills (wv-clarify-spec, sanity-check, pre-mortem,
etc.) at appropriate workflow points.

### Independent Skills

Skills that operate outside the main workflow:

| Skill            | Purpose                                     | When                    |
| ---------------- | ------------------------------------------- | ----------------------- |
| `/breadcrumbs`   | Leave context notes for future sessions     | Before context rotation |
| `/zero-in`       | Focused search without context waste        | Code exploration        |
| `/close-session` | Session end protocol (sync + push + verify) | Before ending session   |

### Internal Skills (Deprecated for Direct Use)

These skills are now invoked automatically by `/weave` but remain available for backward
compatibility:

- `/fix-issue`, `/wv-decompose-work` (workflow)
- `/ship-it`, `/prove-it`, `/pre-mortem`, `/sanity-check` (verification)
- `/wv-guard-scope`, `/wv-clarify-spec`, `/wv-detect-loop` (execution control)
- `/resolve-refs`, `/weave-audit` (discovery)

**Recommendation:** Use `/weave` instead of calling these directly.

## Specialized Agents

Weave-specific agents for workflow guidance and planning:

| Agent              | Purpose                                                      |
| ------------------ | ------------------------------------------------------------ |
| `weave-guide`      | Workflow best practices, node creation guidelines            |
| `epic-planner`     | Strategic planning for epics (scope, features, dependencies) |
| `learning-curator` | Extract learnings from completed work, retrospectives        |

## Scripts

| Script             | Purpose                                       |
| ------------------ | --------------------------------------------- |
| `wv`               | Main CLI (add, done, work, list, sync, etc.)  |
| `wv-test`          | Isolated testing with auto-cleanup temp DB    |
| `context-guard.sh` | Session start with load policy (HIGH/MED/LOW) |

## Hooks

Automatic actions triggered by Claude Code events:

| Hook                       | Event                    | Purpose                                        |
| -------------------------- | ------------------------ | ---------------------------------------------- |
| `session-start-context.sh` | SessionStart             | Inject active Weave status + load policy       |
| `pre-action.sh`            | PreToolUse (Edit/Write)  | Enforce Context Pack before code modifications |
| `pre-compact-context.sh`   | PreCompact               | Extract breadcrumbs + learnings                |
| `session-end-sync.sh`      | SessionEnd               | Final Weave sync                               |
| `stop-check.sh`            | Stop                     | Block exit if uncommitted/unpushed changes     |
| `post-edit-lint.sh`        | PostToolUse (Edit/Write) | Run linters on edited files                    |

**Deprecated hooks (kept for backward compatibility):**

- `pre-claim-skills.sh` — Folded into `/weave` orchestrator
- `pre-close-verification.sh` -- Now a hard gate (exits 1 without verification metadata)

The `/weave` orchestrator handles workflow gates internally, removing the need for separate
claim/close hooks.

## Context Packs

Before starting work, get comprehensive context about a node and its relationships:

```bash
wv context wv-xxxxxx --json
```

**Returns a Context Pack containing:**

```json
{
  "node": {"id": "wv-xxxxxx", "text": "...", "status": "active"},
  "blockers": [],
  "ancestors": [{"id": "wv-parent", "learnings": {...}}],
  "related": [{"id": "wv-related", "edge": "implements", "weight": 0.8}],
  "pitfalls": [{"id": "wv-pitfall", "pitfall": "..."}],
  "contradictions": []
}
```

**Fields:**

- **blockers** — Dependencies that must complete first
- **ancestors** — Parent nodes with their captured learnings
- **related** — Semantic neighbors (max 5) via implements/references/relates_to
- **pitfalls** — Unaddressed relevant pitfalls (max 3)
- **contradictions** — Conflicting decisions (hard stop if non-empty)

**Features:**

- **Cached per session** — Second query is ~40% faster
- **Auto-invalidates** — Cache clears when edges change (block, link, done)
- **Graph-first enforcement** — `pre-action` hook requires Context Pack before code edits

Context Packs prevent working with stale information and surface relevant learnings automatically.

### Contradiction Resolution

When contradictions exist, resolve them before proceeding:

```bash
wv resolve <node1> <node2> --winner=<id>  # One decision supersedes the other
wv resolve <node1> <node2> --merge        # Create merged node
wv resolve <node1> <node2> --defer        # Change contradicts → relates_to
```

## Key Commands

### Core Workflow

```bash
wv ready                      # Show unblocked work
wv add "Title" --gh --alias=x # Create node + GitHub issue
wv work <id>                  # Claim task (sets active)
wv context <id> --json        # Get Context Pack before starting
wv done <id> --learning="..." # Complete work with learnings
wv delete <id> --force        # Remove node + edges permanently
wv bulk-update < nodes.json   # Update multiple nodes from JSON stdin
wv tree --mermaid             # Mermaid graph of epic hierarchy
wv sync --gh                  # Persist graph + sync GitHub issues
```

### Semantic Edges

```bash
# Create relationships between nodes
wv link <from> <to> --type=implements --weight=0.9
wv link <from> <to> --type=contradicts --context='{"reason":"different approaches"}'

# Traverse and inspect
wv related <id>               # Show all semantic relationships
wv related <id> --type=implements --direction=inbound  # What implements this?
wv edges <id>                 # Detailed edge inspection
wv edge-types                 # List valid edge types
```

**8 Edge Types:**

- `blocks` - Workflow dependency (target blocked by source)
- `relates_to` - General semantic relationship
- `implements` - Target implements source concept/spec
- `contradicts` - Target contradicts source
- `supersedes` - Target supersedes/replaces source
- `references` - Target references/mentions source
- `obsoletes` - Target makes source obsolete
- `addresses` - Source addresses/fixes pitfall in target

### Learnings & Pitfalls

```bash
# Capture learnings when closing work
wv done <id> --learning="decision: Key choice made | pattern: Reusable technique | pitfall: Specific mistake to avoid"

# Or update metadata separately for structured learnings
wv update <id> --metadata='{"decision":"...","pattern":"...","pitfall":"...","addresses":["wv-pitfall-id"]}'
wv done <id>

# View all learnings
wv learnings
wv learnings --node=<id>
wv learnings --node=<id> --show-graph  # Show resolution relationships

# Audit pitfall status
wv audit-pitfalls                      # All pitfalls
wv audit-pitfalls --only-unaddressed   # Unresolved only
wv audit-pitfalls --json               # Machine-readable output
```

## GitHub Actions (CI/CD)

Automated workflows using headless Claude Code:

| Workflow         | Trigger                      | Purpose                                  |
| ---------------- | ---------------------------- | ---------------------------------------- |
| `claude.yml`     | `@claude` mention            | Fix issues, answer questions from GitHub |
| `pr-review.yml`  | PR opened/updated            | Auto-review with code + security agents  |
| `sync-weave.yml` | Schedule (6h) + issue events | Bidirectional Weave ↔ GitHub sync        |

**Setup**: Run `/install-github-app` in Claude Code, or add `ANTHROPIC_API_KEY` secret manually.

## What Weave's are and do

| Aspect           | Traditional RAG               | This System                         |
| ---------------- | ----------------------------- | ----------------------------------- |
| Retrieval        | Vector search + reranking     | Native grep/read                    |
| Chunking         | Required (512-1024 tokens)    | Not needed (whole files)            |
| Cross-refs       | Often missed                  | Trail-following + semantic edges    |
| Infrastructure   | Vector DB + embeddings + APIs | None (SQLite + tmpfs)               |
| Token efficiency | Moderate (irrelevant chunks)  | High (99%+ savings on session init) |
| Relationships    | Implicit (embeddings)         | Explicit (typed edges)              |

## Documentation

- **[CLAUDE.md](CLAUDE.md)** — Agent instructions (Weave block + project knowledge)
- **[WORKFLOW.md](templates/WORKFLOW.md)** — Canonical Weave command reference (installed to
  `~/.config/weave/`)
- **[System Design](docs/WEAVE.md)** — Architecture, data model, CLI, MCP, and design decisions
- **[Development Guide](docs/DEVELOPMENT.md)** — Development workflow, testing, and debugging
- **[Contributing](CONTRIBUTING.md)** — How to contribute
- **[Test Suite](tests/README.md)** — Regression tests

## Features Implemented

### Code Quality (v1.9.0)

- Per-function cyclomatic complexity (`wv quality functions`) — CC per function with dispatch-exempt
  tagging, CC histogram distribution `[1-5, 6-10, 11-20, 21+]`, and Gini coefficient
- Essential complexity `ev` — AST-backed unstructured control-flow metric (`ev=1` = fully
  structured)
- Indentation SD — code-shape metric for Python AST + Bash heuristic
- Ownership fraction + minor-contributor count from git blame (gated: authors ≥ 3)
- Complexity trend direction via least-squares slope over 5-scan history
- Schema v2: `complexity_trend` table, new columns for ev, indent_sd, ownership
- `Makefile` — `make check` runs ruff + mypy + pylint + shellcheck + pytest in one step
- `shellcheck` clean: `.shellcheckrc` + all genuine bugs fixed; 0 warnings across all shell scripts

### Core Graph (v6.0)

- SQLite + tmpfs in-memory graph with <1ms queries
- 8 semantic edge types for explicit relationships
- FTS5 full-text search with BM25 ranking (`wv search`)
- JSON virtual columns for O(1) metadata filtering
- Recursive CTE traversal for dependency chains (`wv path`, transitive closure)
  - CTEs are conceptually loops over a queue of SQL results, not true recursion
  - Seed query fills the queue; recursive part runs once per result, adding back to queue
  - Uses `UNION` (not `UNION ALL`) for automatic deduplication in diamond dependencies
- Human-readable aliases alongside hex IDs
- Git-friendly persistence (.dump to SQL text)
- Cross-platform hot zone (Linux tmpfs, macOS/Windows SSD fallback)

### Agent Ergonomics (v6.0)

- Compound commands: `wv quick` (create+close), `wv ship` (done+sync+push)
- Auto-sync on write (60s throttle) -- no manual `wv sync` needed
- `wv delete` -- permanently remove nodes with cascade cleanup, archive, and GH issue close
- `wv bulk-update` -- update multiple nodes from JSON stdin with validation and dry-run
- `wv tree` -- epic-to-feature-to-task hierarchy view (`--mermaid` for Mermaid graphs, `--json`,
  `--active`, `--depth=N`)
- `wv plan` -- import structured markdown into graph as epic + tasks (`--gh` for GH issues,
  `--template` for scaffolding, alias/metadata/dependency syntax)
- Session breadcrumbs for cross-session continuity
- Init safety net with auto-restore on missing DB
- Learning filtering: `--category=`, `--grep=`, `--min-quality=`, `--dedup`
- Learning quality scoring with heuristic thresholds
- Write-time validation warnings (orphans, missing learnings)
- Health digest at session start

### Code Quality Scanner (v1.13.0)

- **Production scope by default** — quality score and hotspot report cover `production` files only.
  Files under `tests/`, `scripts/`, `dist/` etc. are auto-classified and excluded. Use `--scope=all`
  for inclusive reporting. Override per-project via `.weave/quality.conf` `[classify]` section.
- **Graduated per-function scoring** — 0.5pt penalty per CC unit over 10 (cap 8/fn), ev penalty over
  EV=4, −5/hotspot, −1/file Gini >0.7. No density normalization — penalties at face value.
- Per-function cyclomatic complexity: `wv quality functions <path>` — lists every function with CC,
  line range, and `[dispatch]` tag. Text output includes
  `Distribution: [1-5:N, 6-10:N, 11-20:N, 21+:N] Gini=X.XX`. JSON returns
  `{functions: [...], histogram: {...}, cc_gini: float}`
- **Essential complexity (ev)** — measures unstructured control flow: `ev=1` = fully structured;
  `ev > 4` = structurally tangled (independent of total CC)
- **Indentation SD** — standard deviation of indentation levels for Python + Bash: detects
  deep-nesting hotspots
- **Ownership fraction + minor contributors** — git authorship concentration, gated to `authors ≥ 3`
- **Complexity trend direction** — least-squares slope over up to 5 scans: deteriorating ↑ / stable
  ~ / refactored ↓
- **CC Gini coefficient** — `wv quality hotspots` includes `cc_gini` per file (0.0 = uniform, 1.0 =
  one monster function). Distinguishes concentrated vs spread complexity at equal WMC
- **Enhanced output** — hotspot text shows `ev=N`, `gini=X.XX`, and `trend=↑/↓/~`; `--json` adds all
  depth fields including `category_counts` and `scope`
- Schema v3 migration: adds `category` column — idempotent, safe on v1.7.x+ databases

### Durable Operations (v1.9.0)

- **Operation journal** — Append-only JSONL journal for crash-resilient ship/sync/delete
- **`wv recover`** — Resume incomplete operations from journal or `ship_pending` metadata
- **Recovery triggers** — Auto-recover on init/ship, warn on work
- **`wv doctor` check 14** — Detects incomplete journal operations
- **Quality scan atomicity** — Single-transaction scans roll back cleanly on crash

### MCP Server

31 MCP tools for IDE integration (TypeScript). Install with `./install-mcp.sh` or
`./install.sh --with-mcp`.

| MCP Tool                  | CLI Equivalent                         | Description                          |
| ------------------------- | -------------------------------------- | ------------------------------------ |
| `weave_overview`          | `wv status` + `wv health` + `wv ready` | Session start overview               |
| `weave_work`              | `wv work` + `wv context`               | Claim node + return context pack     |
| `weave_ship`              | `wv ship`                              | Done + sync + push in one step       |
| `weave_quick`             | `wv add` + `wv done` + `wv sync`       | Trivial one-step tasks               |
| `weave_preflight`         | `wv preflight`                         | Pre-action checks for a node         |
| `weave_add`               | `wv add`                               | Create a new node                    |
| `weave_done`              | `wv done`                              | Mark node complete with learnings    |
| `weave_batch_done`        | `wv batch-done`                        | Complete multiple nodes at once      |
| `weave_update`            | `wv update`                            | Modify node metadata/status/text     |
| `weave_delete`            | `wv delete`                            | Remove node permanently (force req.) |
| `weave_list`              | `wv list`                              | List nodes with status/format filter |
| `weave_show`              | `wv show`                              | Single-node detail view (JSON)       |
| `weave_search`            | `wv search`                            | Full-text search across nodes        |
| `weave_context`           | `wv context`                           | Context Pack for a node              |
| `weave_link`              | `wv link`                              | Create semantic edges between nodes  |
| `weave_tree`              | `wv tree`                              | Epic hierarchy as tree/Mermaid       |
| `weave_learnings`         | `wv learnings`                         | Query captured learnings             |
| `weave_status`            | `wv status`                            | Compact status summary               |
| `weave_health`            | `wv health`                            | Graph health check with score        |
| `weave_sync`              | `wv sync`                              | Persist graph + optional GH sync     |
| `weave_resolve`           | `wv resolve`                           | Resolve node contradictions          |
| `weave_breadcrumbs`       | `wv breadcrumbs`                       | Save/show/clear session breadcrumbs  |
| `weave_plan`              | `wv plan`                              | Import markdown plan as epic + tasks |
| `weave_guide`             | `wv guide`                             | Quick reference by topic             |
| `weave_close_session`     | End-of-session cleanup                 | Sync + commit + push                 |
| `weave_quality_scan`      | `wv quality scan`                      | Codebase quality metrics scan        |
| `weave_quality_hotspots`  | `wv quality hotspots`                  | Ranked hotspot report                |
| `weave_quality_diff`      | `wv quality diff`                      | Delta report vs previous scan        |
| `weave_quality_functions` | `wv quality functions`                 | Per-function CC report               |
| `weave_edit_guard`        | (pre-edit gate)                        | Returns error if no active node      |

**Setup:** `wv mcp-status` to verify, or `wv-init-repo --agent=copilot` to configure

### Graph-First Orchestrator

- `/weave` unified workflow with INTAKE/CONTEXT/EXECUTE/CLOSE phases
- Context Packs: comprehensive node context with blockers, ancestors, related, pitfalls
- Session-scoped caching with automatic invalidation on edge changes
- Contradiction resolution workflow (winner/merge/defer)
- Pre-action hook enforces Context Pack before code modifications

### Skills & Agents

- 16 active skills, most folded into `/weave` as internal implementation
- `/breadcrumbs` and `/zero-in` remain independent
- Hook-based automation (9 hooks across 6 event types)
- 3 specialized Weave agents (guide, planner, curator)

### Hook Determinism (v1.10.0+)

- Exit code hard blocks (exit 2) for enforcement gates — no user override possible
- Structured JSON output for "ask" decisions (`hookSpecificOutput`)
- DB health pre-flight in hooks — early exit in non-Weave repos
- PostToolUse success guard — lint only runs on successful tool calls
- Hooks promoted from `settings.local.json` to `settings.json` (project-wide enforcement)
- MCP matcher extended to cover `mcp__ide__executeCode`
- 10 Makefile wv targets for CI integration and discoverability
- Session start includes `wv health`, session end includes `git push`
- **VS Code hook support (v1.11.0)** — cross-environment path resolution
  (`${CLAUDE_PROJECT_DIR:-.}`), `chat.hooks.enabled` auto-setup via `wv-init-repo`
- **MCP `weave_edit_guard` (v1.11.0)** — pre-edit gate returning `isError: true` when no active node
  exists, closing the enforcement gap for VS Code Copilot and other MCP clients
- **Hardened `weave_preflight` (v1.11.0)** — returns `isError: true` for missing nodes,
  contradictions, and unresolved blockers

### GitHub Integration (v6.0)

- Bidirectional sync rewritten in Python (type-checked, 109 pytest cases)
- Structured issue bodies with `WEAVE:BEGIN/END` markers + content hash
- Mermaid dependency graphs in parent issues with children (preserved on close, single-source via
  `wv tree --mermaid`)
- Human-readable aliases in issue body context headers and Mermaid labels
- Rich close comments with learnings + commit links (auto-discovered from git log)
- Type and status labels (`weave:active`, `weave:blocked`, `epic`, etc.)
- Live progress comments on `wv work`/`wv done` (synchronous with log file)
- Issue templates with Weave ID field
- Sync-wide fcntl lock prevents concurrent sync corruption
- `@claude` GitHub Action wired to graph lifecycle

### Learnings & Knowledge Capture

- Decision/pattern/pitfall capture on node closure
- Systematic pitfall tracking with resolution status
- Bidirectional linking between fixes and problems
- Graph visualization of addressed/unaddressed pitfalls

### Token Efficiency

- **99.8% savings** on session start (10 tokens vs 4,148 for full dump)
- Passive context injection (~15-35 tokens)
- Path-to-root queries instead of full graph loads
- Context load policy (HIGH/MEDIUM/LOW)
- Auto-pruning keeps graph lean (<50MB)

## License

AGPL-3.0
