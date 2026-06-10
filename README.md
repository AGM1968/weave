# Weave — Graph-Based Workflow for AI Coding Agents

Token-optimized task tracking for agentic workflows. SQLite on tmpfs, managed by the `wv` CLI.

This is the `weave(public)` README produced by `build-release.sh`; it omits the in-repo runtime and
other local-only paths from the full memory-system tree.

## Why Weave

| Aspect           | Traditional RAG                | Weave                                                 |
| ---------------- | ------------------------------ | ----------------------------------------------------- |
| Retrieval        | Vector search + reranking      | Explicit graph traversal + earned local hybrid search |
| Infrastructure   | Vector DB + embeddings + APIs  | SQLite + tmpfs; optional local index (no cloud APIs)  |
| Relationships    | Implicit (embeddings)          | Explicit (8 typed edge types)                         |
| Token efficiency | Moderate (irrelevant chunks)   | High (context packs, not full dump)                   |
| Cross-references | Often missed                   | Semantic edges + graph traversal                      |
| Code search      | External RAG pipeline required | Built-in (`wv search --code`); extend with any tool   |

Code search was added as the codebase matured — BM25+cosine RRF locally, no cloud API required.
External tools (semble, ripgrep, semgrep, ast-grep) are additive; consumers extend with whatever
fits their stack.

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

# Upgrade
wv self-update

# Uninstall
wv uninstall                         # remove installed files (see output for manual cleanup steps)
rm -rf ~/.config/weave               # also remove config/hooks/skills (optional — contains user data)
```

This installs:

- `wv` CLI and helper commands to `~/.local/bin/`
- MCP server for VS Code Copilot and other MCP clients (optional, with `--with-mcp`)

Claude Code uses `wv` CLI + hooks rather than MCP.

**Requirements:** `sqlite3` (>= 3.35), `jq`, `git`. Optional: `gh` (for GitHub sync), `node` (for
MCP server).

Run `wv doctor` to verify your installation.

## Quick Start

**Prerequisites:** An existing git repo and `jq` installed.

### 1. Initialize your repo

```bash
cd /path/to/your/project
wv init-repo --agent=copilot     # VS Code: .vscode/mcp.json (+ legacy .mcp.json) + instructions
# Or: wv init-repo --agent=claude   # Claude Code: hooks, skills, settings
# Or: wv init-repo --agent=all      # Claude, Copilot, and Codex in same repo
wv init-repo --update            # Update existing repo to latest skills/hooks/agents
wv selftest                      # Verify everything works
```

The standalone wrapper `wv-init-repo` is still installed for compatibility, but `wv init-repo` is
the canonical form used in help and workflow docs.

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
git add <files> && git commit -m "fix: login timeout"
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
git add .weave/                        # Stage graph state
git diff --cached --quiet || git commit -m "chore(weave): sync state [skip ci]"
git push
```

Your AI coding agent follows the workflow automatically via generated instructions and MCP tools.

## Core Workflow

```text
wv bootstrap --json                     Session snapshot (replaces git status + wv status)
wv ready                                Find unblocked work
wv work <id>                            Claim a task (one active at a time)
git add <files> && git commit -m "..." Commit work files before closing
wv done <id> --learning="..."          Complete with captured learning
wv sync --gh                            Persist graph + sync GitHub issues
git add .weave/ && git diff --cached --quiet || git commit -m "chore(weave): sync state [skip ci]"
git push                                Push state to remote
```

Focused CLI help: `wv help <command>` or `wv <command> --help`.

**Commit enforcement:** A pre-commit hook blocks commits without an active Weave node. Use
`wv quick` for trivial one-step work instead of bypassing the hook during normal workflow.

## Command Reference

### Task Management

| Command                            | Description                        |
| ---------------------------------- | ---------------------------------- |
| `wv add "text" --gh`               | Create node + GitHub issue         |
| `wv work <id>`                     | Claim task (sets active)           |
| `wv done <id> --learning="..."`    | Complete with captured learning    |
| `wv ship <id> --learning="..."`    | Complete + sync in one step        |
| `wv quick "text" --learning="..."` | Create + close in one step         |
| `wv bootstrap --json`              | Single-call session snapshot       |
| `wv overview --json`               | Compact graph/session snapshot     |
| `wv touch <id> --intent="..."`     | Zero-output intent update          |
| `wv help <command>`                | Focused help for one command       |
| `wv show <id>`                     | View node details                  |
| `wv query status=todo`             | Targeted node lookup               |
| `wv ready`                         | Show unblocked work                |
| `wv search "query"`                | Full-text search across nodes      |
| `wv search --code "query"`         | Hybrid code search (source files)  |
| `wv index`                         | Index source files for code search |

### Search

Two tools serve different sources — use both before filing work:

| Tool                       | Source       | When to use                                         |
| -------------------------- | ------------ | --------------------------------------------------- |
| `wv search "query"`        | Graph nodes  | Prior decisions, findings, learnings, task history  |
| `wv search --code "query"` | Source files | Implementation location, function names, call sites |

```bash
wv index                              # Index source files once (enables --code mode)
wv search "auth"                      # What decisions/learnings exist about auth?
wv search --code "auth_middleware"    # Where is auth implemented in source?
wv search --code "query" --graph      # Include active Weave nodes per matched file
```

**No-index alternatives** — consumer's choice, no `wv index` required:

- `weave_code_search` (Weave MCP tool) — same hybrid ranking, no external dep
- **Semble** — dedicated code search: `semble search "<query>" <dir>` (CLI) or `mcp__semble__search`
  (MCP, pass `repo` param)
- Any other tool: ripgrep, semgrep, ast-grep, language server search — Weave has no opinion

### Graph Operations

| Command                                 | Description                                               |
| --------------------------------------- | --------------------------------------------------------- |
| `wv link <from> <to> --type=implements` | Create semantic edge                                      |
| `wv block <id> --by=<blocker>`          | Set dependency                                            |
| `wv tree`                               | View hierarchy                                            |
| `wv context <id> --json`                | Get full Context Pack                                     |
| `wv related <id>`                       | Show semantic relationships                               |
| `wv related <id> --depth=2`             | N-hop neighborhood traversal                              |
| `wv path <id>`                          | Show ancestry path                                        |
| `wv edge-types`                         | List valid edge types                                     |
| `wv edge-types --stats`                 | Edge counts per type                                      |
| `wv query edge-type=blocks`             | Nodes with blocking edges                                 |
| `wv query --order=connections`          | Most-connected nodes first                                |
| `wv impact <id>`                        | Blast radius: impacted nodes, risk score, affected suites |
| `wv impact --files=a,b`                 | Blast radius seeded from changed file paths               |

### Knowledge Capture

| Command                                | Description                     |
| -------------------------------------- | ------------------------------- |
| `wv learnings`                         | View all captured learnings     |
| `wv learnings --grep="topic"`          | Search learnings by keyword     |
| `wv audit-pitfalls`                    | Track resolved vs open pitfalls |
| `wv audit-pitfalls --only-unaddressed` | Show unresolved pitfalls only   |
| `wv findings list`                     | List finding nodes with summary |
| `wv findings promote`                  | Promote learnings into findings |

Finding nodes use `metadata.type="finding"` plus nested
`finding.{violation_type, root_cause, proposed_fix, confidence, fixable}` data. `confidence` is
`high|medium|low`.

### System

| Command                     | Description                                                                                            |
| --------------------------- | ------------------------------------------------------------------------------------------------------ |
| `wv health`                 | Graph health check (0-100 score)                                                                       |
| `wv quality scan`           | Scan repo for code quality metrics                                                                     |
| `wv quality hotspots`       | Ranked hotspot report (ev, trend, cc_gini)                                                             |
| `wv quality diff`           | Delta report vs previous scan                                                                          |
| `wv quality functions`      | Per-function CC with histogram + Gini                                                                  |
| `wv quality promote`        | Create nodes from top findings                                                                         |
| `wv quality patterns`       | Structural pattern scan/list/promote (requires ast-grep)                                               |
| `wv clean-ghosts`           | Delete ghost edges (legacy compatibility)                                                              |
| `wv doctor`                 | Installation health check                                                                              |
| `wv test-record <suite>`    | Record a suite outcome in the test ledger (`--files=a,b --exit=N`); feeds the test gate                |
| `wv hotzone --db`           | Print the resolved brain.db path (for raw sqlite3 inspection)                                          |
| `wv mcp-status`             | MCP server health check                                                                                |
| `wv selftest`               | End-to-end smoke test                                                                                  |
| `wv sync --gh`              | Persist graph + sync GitHub issues                                                                     |
| `wv plan <file>`            | Import markdown plan as tasks                                                                          |
| `wv enrich-topology <spec>` | Apply graph topology from JSON spec                                                                    |
| `wv prune [--age=Nd]`       | Archive old completed nodes (deduplicates against today's archive; `--dry-run` shows accurate preview) |

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
wv bootstrap --json
wv context wv-xxxxxx --json
```

Returns blockers, ancestors with learnings, related nodes, pitfalls, and contradictions.

- **Session-cached** — second call returns instantly from stamp-file cache
- **Auto-invalidates** — cache clears when edges change (`wv link`, `wv block`, `wv resolve`)
- **Bounded output** — top 5 related, top 3 pitfalls (prevents context explosion)
- **Low-cost progress writes** — use `wv touch <id> --intent="..."` between larger steps without
  emitting extra output

## MCP Server

40 tools for IDE integration via 2 server instances:

- **`weave`** (scope=all, 40 tools) — full tool set for Copilot Chat
- **`weave-inspect`** (scope=inspect, 19 tools) — read-only subset for analysis subagents
- **`--scope=lite`** (7 tools) — lightweight profile for constrained contexts

> **Claude Code** does not use MCP — it interacts with Weave via `wv` CLI and enforcement hooks. MCP
> servers are consumed by VS Code Copilot Chat only.

| MCP Tool                  | CLI Equivalent                         | Description                              |
| ------------------------- | -------------------------------------- | ---------------------------------------- |
| `weave_overview`          | `wv status` + `wv health` + `wv ready` | Session start overview                   |
| `weave_bootstrap`         | `wv bootstrap --json`                  | Single-call session context              |
| `weave_work`              | `wv work`                              | Claim node + return context              |
| `weave_ship`              | `wv ship-agent --no-gh`                | Bounded local close + sync               |
| `weave_quick`             | `wv quick`                             | Create + close (trivial tasks)           |
| `weave_add`               | `wv add`                               | Create a new node                        |
| `weave_done`              | `wv done`                              | Mark complete with learnings             |
| `weave_batch_done`        | `wv batch-done`                        | Complete multiple nodes at once          |
| `weave_update`            | `wv update`                            | Modify node metadata/status/text         |
| `weave_touch`             | `wv touch`                             | Fire-and-forget metadata or intent       |
| `weave_delete`            | `wv delete`                            | Remove node permanently (force req.)     |
| `weave_list`              | `wv list`                              | Broad node listing; prefer query flow    |
| `weave_show`              | `wv show`                              | Single-node detail view (JSON)           |
| `weave_search`            | `wv search`                            | Full-text search                         |
| `weave_context`           | `wv context`                           | Context Pack for a node                  |
| `weave_link`              | `wv link`                              | Create semantic edges                    |
| `weave_unlink`            | `wv unlink`                            | Remove semantic edge                     |
| `weave_block`             | `wv block`                             | Add blocking dependency                  |
| `weave_unarchive`         | `wv unarchive`                         | Restore pruned node from archive         |
| `weave_ready`             | `wv ready`                             | List unblocked work                      |
| `weave_query`             | `wv query`                             | Predicate-based node query               |
| `weave_recover`           | `wv recover`                           | Resume interrupted sync                  |
| `weave_code_search`       | `wv search --code`                     | Hybrid BM25+cosine code search           |
| `weave_index`             | `wv index`                             | Index code files for hybrid search       |
| `weave_tree`              | `wv tree`                              | View hierarchy (supports `--mermaid`)    |
| `weave_learnings`         | `wv learnings`                         | Query captured learnings                 |
| `weave_status`            | `wv status`                            | Status summary                           |
| `weave_health`            | `wv health`                            | Graph health check                       |
| `weave_preflight`         | `wv preflight`                         | Pre-action checks for a node             |
| `weave_sync`              | `wv sync`                              | Persist graph; GH sync uses CLI fallback |
| `weave_resolve`           | `wv resolve`                           | Resolve contradiction between nodes      |
| `weave_trails`            | `wv trails`                            | Save/show/clear session trails           |
| `weave_plan`              | `wv plan`                              | Import markdown plan as epic+tasks       |
| `weave_guide`             | `wv guide`                             | Workflow quick reference                 |
| `weave_close_session`     | `wv sync`                              | Bounded local sync + repo checks         |
| `weave_quality_scan`      | `wv quality scan`                      | Codebase quality metrics scan            |
| `weave_quality_hotspots`  | `wv quality hotspots`                  | Ranked hotspot report                    |
| `weave_quality_diff`      | `wv quality diff`                      | Delta report vs previous scan            |
| `weave_quality_functions` | `wv quality functions`                 | Per-function CC report                   |
| `weave_quality_patterns`  | `wv quality patterns scan/list`        | Structural pattern findings              |
| `weave_edit_guard`        | (pre-edit gate)                        | Returns error if no active node          |

Install: `./install.sh --with-mcp` or `./install-mcp.sh`

Verify: `wv mcp-status`

## Hook Determinism

Hooks enforce workflow rules deterministically — the AI agent cannot bypass structural constraints:

- **Hard blocks (exit 2)** — No active node, contradictions, and installed-path edits are
  unconditionally blocked. No user override possible.
- **Structured JSON** — "Ask" decisions output machine-readable JSON for model consumption.
- **DB pre-flight** — Hooks exit early in non-Weave repos (no spurious errors).
- **PostToolUse guard** — Lint only runs after successful tool calls.
- **Global hook architecture (v1.15.0)** — All hooks are registered in `~/.claude/settings.json`
  (global) by `install.sh`. Per-project `.claude/settings.json` contains only permissions — no
  `hooks` key (shallow merge limitation: project hooks shadow global hooks entirely).
- **10 Makefile wv targets** — CI integration and discoverability.
- **MCP `weave_edit_guard`** — Pre-edit gate for VS Code Copilot and other MCP clients.

## Code Quality

Built-in code quality analysis with zero dependencies beyond Python stdlib and git:

```bash
wv quality scan                         # Scan repo for complexity + churn metrics
wv quality hotspots --top=5             # Top hotspot files (production scope by default)
wv quality hotspots --scope=all         # Include test + script files
wv quality diff                         # Compare current vs previous scan with trend arrows
wv quality functions src/myfile.py      # Per-function CC with dispatch tagging
wv quality promote --top=3              # Create Weave nodes from top findings
```

Quality data is stored in `quality.db` on tmpfs (alongside the graph DB), never git-tracked, and
fully rebuildable from source. Integrated into the existing workflow:

- **`wv health`** shows scan score and hotspot count
- **`wv context`** enriches Context Packs with hotspot data for touched files
- **Production scope by default** — the quality score and hotspot report reflect `production` files
  only. Test files, scripts, and generated output are classified automatically by path heuristics
  (`tests/`, `test_*.py`, `scripts/`, `dist/`) and excluded from scoring. Use `--scope=all` to
  include everything. Override classification per-project via `.weave/quality.conf`:
  ```ini
  [classify]
  production = scripts/mylib/   # promote library code living under scripts/
  ```
- **Hotspot scoring** uses `normalize(complexity) x normalize(churn)` — files that are both complex
  and frequently changed surface first
- **Per-function CC** — `wv quality functions` lists every function with CC, line range, and a
  `[dispatch]` tag for match/case + flat if/elif chains exempt from the CC ≤ 10 threshold. JSON
  output includes a bucket histogram `[1-5, 6-10, 11-20, 21+]` and **CC Gini coefficient** (0.0 =
  uniform, 1.0 = one monster function holds all complexity)
- **Essential complexity `ev`** — unstructured control-flow metric: `ev=1` = fully structured;
  `ev > 4` = structurally tangled (independent of total CC)
- **Indentation SD** — standard deviation of indentation levels for Python and Bash: detects deep
  nesting that CC alone misses
- **Ownership metrics** — per-file git authorship concentration: `ownership_fraction` and
  `minor_contributors`. Only flagged when `total_authors ≥ 3` to avoid noise on solo projects
- **Complexity trend direction** — least-squares slope over up to 5 scans classifies each file as
  `deteriorating ↑`, `stable ~`, or `refactored ↓`
- **Python files** use AST-backed cyclomatic complexity (regex fallback if parse fails)
- **Bash files** use `ast-grep` AST-accurate CC as the primary backend, with regex heuristic
  fallback when `ast-grep` is absent. The active backend is recorded in `scan_meta`
- **TypeScript/TSX files** use `ast-grep` for CC and function detection. Files are skipped
  gracefully when `ast-grep` is absent — install via `cargo install ast-grep` or OS package
- **Structural patterns** — `wv quality patterns scan` runs ast-grep rules against the codebase to
  surface recurring anti-patterns (bare except, shell=True, unquoted variables). Findings are stored
  for 2 scans and can be promoted to Weave nodes
- **Quality gate** — `wv done` blocks if any file linked to the node has a function above the
  language CC threshold (py=25, sh=100, ts=15). Run `wv quality functions <file>` to identify
  violations. Exempt paths (monolithic scripts, archived code) via `.weave/quality.conf`:
  ```ini
  [exempt]
  install.sh    # full path match
  archive/      # directory prefix (trailing / required)
  ```
  Full reference: `scripts/weave_quality/README.md` § Quality Gate.

## Verification Gates

`wv done` is the single owner of the "is this work correct?" decision. Other surfaces _run_ checks
and _record_ their outcomes; `wv done` _reads_ them and decides — it never invokes a linter or test
runner, so closing stays fast.

| Surface         | Role                                                         | Blocks?                           |
| --------------- | ------------------------------------------------------------ | --------------------------------- |
| **pre-commit**  | lint + active-node hygiene; runs fast/impact suites; records | hygiene only (tests are advisory) |
| **post-commit** | runs deferred slow suites; records                           | never (advisory)                  |
| **wv done**     | reads recorded signals; enforces the gate                    | yes, per configured threshold     |

Three gates run at close, each enforced only for files the node touched (`[exempt]` paths skipped):
complexity (`mccabe_max`, on by default), trend (`trend_deteriorating`, off), and test correctness
(`test_gate`, off).

**Test gate (`test_gate`).** Suites record their outcome per file —
`wv test-record <suite> --files=a,b --exit=N` (the commit hooks do this automatically; fingerprint =
git blob hash). `.weave/test-map.conf` maps files to suites, so Weave records exit codes without
running your suites itself. At close, each touched file is **green** (recorded pass, unchanged),
**red** (recorded fail), **stale** (changed since the run), or **unknown** (no record — never
blocks). Levels: `0` off · `1` warn (advisory) · `2` block.

For staged Python files, pre-commit also runs optional focused pytest dirs when present:
`tests/weave_quality/` and `tests/weave_indexer/`. Consumer repos do not need to create those dirs;
repo-local suites should be routed through `.weave/test-map.conf` instead.

Enable durably with `wv config enable test-gate warn` (or `block`), which writes a `[thresholds]`
section to `.weave/quality.conf` (re-applied on every `wv load`, so it survives reboots — a raw
`sqlite3` change does not, and `wv doctor` flags that case):

```ini
[thresholds]
test_gate = 1            # 0=off (default), 1=warn, 2=block
```

Non-code node types (`finding`, `epic`, `session_history`) are never test-gated;
`--skip-verification` suppresses the warn advisory. Full reference: `wv guide --topic=verification`.

## Opt-in instrumentation

Instrumentation ships **off** by default. CLI features are enabled through one front door —
`wv config` — so you never have to memorise an env-var name or a config path. MCP server telemetry
uses an explicit server environment variable because MCP clients own the launched process
environment. `wv config list` shows current CLI state; `wv guide --topic=instrumentation` has the
full reference.

| Feature           | Enable                                     | What it does                                                         | Stored in                          |
| ----------------- | ------------------------------------------ | -------------------------------------------------------------------- | ---------------------------------- |
| Session analysis  | `wv config enable session-analysis`        | Logs each `wv` call so `wv analyze sessions --call-stats` can report | `~/.config/weave/config.env`       |
| Verification gate | `wv config enable test-gate [warn\|block]` | Durable `test_gate` for `wv done` (see Verification Gates)           | `.weave/quality.conf [thresholds]` |
| MCP telemetry     | `WV_MCP_CALL_LOG=/path/to/mcp_calls.jsonl` | Logs MCP tool payload bytes, elapsed ms, scope, and error status     | MCP client/server environment      |

Global knobs live in `~/.config/weave/config.env` (override the dir with `WV_CONFIG_DIR`) and are
read from disk on **every** invocation — the CLI and harness-spawned hooks alike — so enablement
survives reboot and never depends on shell env inheritance. Disable with
`wv config disable <feature>`.

## GitHub Integration

Bidirectional sync between Weave nodes and GitHub issues:

- `wv add "text" --gh` creates a linked GitHub issue
- `wv done <id>` auto-closes the linked issue with learnings + commit links
- `wv sync --gh` syncs all changes (status, labels, progress comments)
- Mermaid dependency graphs in parent issues with children (single-source via `wv tree --mermaid`)
- `weave:active`, `weave:blocked`, `epic`, `feature` labels auto-applied

**Requirements:** `gh` CLI authenticated (`gh auth login`).

## Architecture

```text
Copilot Chat (@copilot)           Claude Code (@claude / CLI)
        |                                 |
        v                                 v
   MCP Server (2 instances)          wv CLI + hooks
        |                                 |
        +------------+--------------------+
                     |
                     v
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

## Multi-Developer Support

Weave is still optimized for **single-developer + AI agent** workflows, but the local graph now
ships the core primitives needed for small multi-developer or multi-agent teams sharing one repo.

Current multi-developer baseline:

- **Level 1 is shipped** — `wv sync` writes per-agent delta SQL into `.weave/deltas/`, `wv load`
  replays those deltas after the baseline, and same-row conflicts resolve last-writer-wins per row
  instead of whole-file loss.
- **Level 2 is shipped** — `wv work` stamps `metadata.claimed_by` using `WV_AGENT_ID` with atomic
  compare-and-swap, and `wv ready` hides nodes claimed by other agents unless `--all` is used.
- **Graph maintenance is no longer blocked on missing unlink support** — `wv unlink` shipped in
  v1.37.0 for removing edges without deleting nodes.

Remaining limitations for multi-developer teams:

- Same-row or same-field concurrent edits are still last-writer-wins; there is no per-field merge
  yet.
- Claim recovery is still manual (`--force`, `wv recover`, or GitHub coordination); there is no
  heartbeat or stale-claim reaper yet.
- GitHub remains the main cross-machine human coordination surface.

### Current Status

Multi-developer support now breaks down into three progressive levels:

| Level | Capability                         | Status  | Notes                                                       |
| ----- | ---------------------------------- | ------- | ----------------------------------------------------------- |
| 1     | Delta merge via git                | Shipped | v1.24.0; hardened in v1.36.0                                |
| 2     | Agent identity + claim enforcement | Shipped | v1.26.0; CAS claims in `wv work`, claim-aware `wv ready`    |
| 3     | Per-field merge + conflicts        | Future  | Requires warp-core and later contradiction/conflict tooling |

Levels 1-2 are pure Bash and already build on the shipped delta tracking and metadata
infrastructure. Level 3 remains the open design frontier for same-field conflict resolution.

## Community

- Questions and ideas: [Discussions](https://github.com/AGM1968/weave/discussions)
- Bug reports: [Issues](https://github.com/AGM1968/weave/issues)

## License

AGPL-3.0
