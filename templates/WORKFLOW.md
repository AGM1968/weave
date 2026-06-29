# Weave Workflow Reference

Canonical reference for `wv` — the task graph CLI for AI coding agents. Full docs: `wv guide` (MCP)
| Command list: `wv --help` | Focused help: `wv help <command>` or `wv <command> --help`

## Core Workflow

```txt
wv bootstrap --json               # 0. Session snapshot — status + active + context + ready + learnings
wv search "<topic>"               # 1. Check for existing related work before claiming/creating
wv ready                          # 2. Find unblocked work
wv work <id>                      # 3. Claim it (sets active, enters execute phase)
# ... do the work ...
git commit                        # 4. Commit work files — prepare-commit-msg appends Weave-ID: <id>
wv done <id> --learning="..."     # 5. Complete with learnings (requires attributed commit + evidence)
wv sync --gh                      # 6. Sync graph + GH (may dirty .weave/)
git add .weave/ && git commit     # 7. Commit graph state if dirty
git push                          # 8. MANDATORY before session end
```

Never edit a file without an active node. If `wv status` shows 0 active, run `wv work <id>` or
create a node first.

Open a file with your harness's native file-read before editing it. Shell reads (`cat`/`grep`/`sed`)
and code-search find the spot but do **not** satisfy harness edit-guards — editing a file you only
inspected via a shell command is blocked ("File has not been read"). Grep/partial-read to locate;
native-read the file you will change.

`wv bootstrap --json` replaces 7 separate calls at session start (see Token Awareness). For a quick
mid-session check, use `wv status` (~31 tokens). `git status && wv status` is the manual fallback
when bootstrap is unavailable.

**Sandbox shells:** if `wv` is not on PATH (e.g. Codex sandboxes omit `~/.local/bin`), use the
repo-local `./scripts/wv` wrapper — it appends `$HOME/.local/bin` and `$HOME/.cargo/bin` itself. The
Weave Makefile targets apply the same PATH fallback, so `make wv-*` and `make check` work without
shell configuration.

**Step 4 — commit attribution:** The `prepare-commit-msg` git hook (installed by `wv-init-repo`)
appends `Weave-ID: <id>` to every commit message automatically. `wv done` verifies this attribution
exists; if the hook was not installed, add the trailer manually or run
`git commit --amend -m "$(git log -1 --format=%B) Weave-ID: <id>"` before closing.

<!-- BEGIN GENERATED: workflow-classes -->
## Command Classes

This table is generated from `templates/workflow-classes.conf`. The pre-action hook uses the same compiled data.

| Class | Members | Enforcement |
| --- | --- | --- |
| Safe lifecycle/read commands | `add,work,ready,status,list,show,sync,load,doctor,bootstrap,search,context,quick,recover` | Bypass pre-action active-node check |
| Close lifecycle commands | `done,ship` | Require active-node check |
| Pre-action hook adapter tool names | `Edit,Write,NotebookEdit,mcp__ide__executeCode,create_file,replace_string_in_file,insert_edit_into_file,multi_replace_string_in_file,edit_notebook_file` | Require active-node check |
| Claude Code runtime path prefixes | `$HOME/.claude/` | Excluded from project-work enforcement |
<!-- END GENERATED: workflow-classes -->

## Commands

| Command                    | What it does                                                                                                           | Key flags                                                                                                      |
| -------------------------- | ---------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------- |
| `wv ready`                 | List unblocked work                                                                                                    | `--json`, `--count`                                                                                            |
| `wv work <id>`             | Claim node (sets active); use `--reopen` for done nodes                                                                | `[--reopen]` to explicitly reopen a done node back to tracked work                                             |
| `wv add "<text>"`          | Create node                                                                                                            | `--gh`, `--status=`, `--parent=`, `--alias=`, `--standalone`                                                   |
| `wv done <id>`             | Complete node (auto-closes linked GH issue)                                                                            | `--learning="..."`, `--no-overlap-check`, `--no-gh`                                                            |
| `wv ship <id>`             | Done + sync in one step; pending Git sync is surfaced separately                                                       | `--learning="..."`, `--no-gh`, `--no-overlap-check`                                                            |
| `wv update <id>`           | Modify node                                                                                                            | `--status=`, `--text=`, `--alias=`, `--metadata=`, `--metadata-file=`, `--echo`                                |
| `wv overview`              | Compact graph/session snapshot                                                                                         | `--json`                                                                                                       |
| `wv help <command>`        | Focused help for one command                                                                                           | Also available as `wv <command> --help`                                                                        |
| `wv bootstrap`             | Session-start composite: status + active + context + ready + learnings                                                 | `--json` (run-cached, 45s TTL)                                                                                 |
| `wv touch`                 | Fire-and-forget intent write (zero stdout)                                                                             | `--intent="TEXT"`, `--files=path1,path2` (record edited paths in node_files)                                   |
| `wv quick "<text>"`        | Track trivial work (create active → commit → done)                                                                     | `--learning="..."`                                                                                             |
| `wv show <id>`             | Node details + blockers                                                                                                | `--json`                                                                                                       |
| `wv list`                  | Non-done nodes — capped 50 (~120 tok). Always emits alternatives footer. Prefer `wv ready` / `wv query` / `wv search`. | `--all`, `--status=`, `--json`                                                                                 |
| `wv block <id> --by=<id>`  | Add dependency edge                                                                                                    | `--context='{...}'`                                                                                            |
| `wv tree`                  | Epic → feature → task hierarchy                                                                                        | `--active`, `--depth=N`, `--mermaid`                                                                           |
| `wv path <id>`             | Ancestry chain                                                                                                         | `--format=chain`                                                                                               |
| `wv plan <file>`           | Import markdown as epic + tasks                                                                                        | `--sprint=N`, `--gh`, `--dry-run`                                                                              |
| `wv context <id> --json`   | Context pack (blockers, ancestors, pitfalls)                                                                           | Cached per session                                                                                             |
| `wv search <query>`        | Full-text search across graph nodes                                                                                    | `--json`, `--status=`                                                                                          |
| `wv index [path]`          | Index code files into brain.db for hybrid search                                                                       | `--ext=`, `--no-embed`, `--json`                                                                               |
| `wv search --code <query>` | Hybrid code search (BM25 + cosine RRF) over indexed chunks                                                             | `--mode=hybrid\|fts\|vector`, `--graph`, `--json`                                                              |
| `wv status`                | Compact status (active/ready/blocked counts)                                                                           |                                                                                                                |
| `wv learnings`             | Show captured decisions/patterns/pitfalls                                                                              | `--category=`, `--grep=`, `--dedup`                                                                            |
| `wv link <from> <to>`      | Create semantic edge                                                                                                   | `--type=`, `--context='{...}'`                                                                                 |
| `wv unlink <from> <to>`    | Remove a semantic edge                                                                                                 | `--type=`                                                                                                      |
| `wv edges <id>`            | Inspect all edges touching a node                                                                                      | `--type=`, `--json`                                                                                            |
| `wv related <id>`          | Explore N-hop neighborhood of a node                                                                                   | `--type=`, `--direction=`, `--depth=N`, `--json`                                                               |
| `wv refs <file\|-t text>`  | Extract Weave node references from text; optionally create edges                                                       | `--link`, `--from=<id>`, `--json`, `--max=N`                                                                   |
| `wv health`                | System health check with score                                                                                         | `--json`, `--verbose`, `--fix`, `--history[=N]`                                                                |
| `wv audit-pitfalls`        | List all pitfall learnings with resolution status                                                                      |                                                                                                                |
| `wv guide`                 | Workflow quick reference (in-terminal cheat sheet)                                                                     | `--topic=workflow\|github\|learnings\|context\|routing\|mcp\|verification\|instrumentation\|config\|discovery` |
| `wv reindex`               | Rebuild the full-text search index                                                                                     |                                                                                                                |
| `wv sync`                  | Dump to `.weave/state.sql`                                                                                             | `--gh` for GH sync, `--mode=fast\|full\|repair`, `--node=<id>`, `--dry-run`                                    |
| `wv load`                  | Restore from `.weave/state.sql`                                                                                        | Run by session start hook                                                                                      |
| `wv prune`                 | Archive done nodes >48h                                                                                                | `--age=`, `--orphans-only`, `--dry-run`                                                                        |
| `wv unarchive <id>`        | Restore a pruned node from `.weave/archive/` to live graph                                                             | `--dry-run`                                                                                                    |
| `wv quality scan`          | Scan repo for complexity + churn                                                                                       | `--exclude=`, `--json`                                                                                         |
| `wv quality hotspots`      | Ranked hotspot report                                                                                                  | `--top=N`, `--json`                                                                                            |
| `wv findings <sub>`        | Historical finding promotion/list workflow                                                                             | `list`, `promote`                                                                                              |
| `wv query [pred...]`       | Predicate-based graph reader (key=val, HAS, MATCH, IN, edge-type=)                                                     | `--format=table\|json\|short`, `--limit=N`, `--order=recent\|hygiene`                                          |
| `wv session-summary`       | Session hygiene score (0-100) + nodes created/completed/learnings                                                      |                                                                                                                |
| `wv digest`                | One-line health summary (cheaper than `wv health`)                                                                     | `--json`                                                                                                       |
| `wv cache`                 | Claude prompt-cache diagnostics (read vs creation ratio per session)                                                   | `--sessions=N`, `--all`, `--json`                                                                              |
| `wv hotzone list`          | List all active graph DB directories with node count and owner                                                         | `--json`                                                                                                       |
| `wv hotzone gc`            | Remove orphan hot-zone directories (no matching live repo)                                                             | `--dry-run`                                                                                                    |
| `wv compact`               | Delete replayed delta files after safety checks                                                                        | `--older-than=Nd`, `--dry-run`                                                                                 |
| `wv doctor`                | Installation health check (deps, hooks, ghost settings, matchers)                                                      | `--json`, `--repair`                                                                                           |
| `wv recover`               | Resume interrupted ship/sync flows; list orphaned active nodes                                                         | `--auto`, `--session`, `--json`                                                                                |
| `wv delete <id>`           | Permanently remove a node (closes linked GH issue)                                                                     | `--force`, `--dry-run`, `--no-gh`                                                                              |
| `wv preflight <id>`        | Machine-readable blockers, contradictions, readiness check for a node                                                  | returns JSON                                                                                                   |
| `wv clean-ghosts`          | Remove edges that reference deleted nodes                                                                              | `--dry-run`                                                                                                    |
| `wv edge-types`            | List valid semantic edge types with live edge counts                                                                   | `--stats`, `--json`                                                                                            |
| `wv self-update`           | Refresh installed wv from source clone recorded at install time                                                        |                                                                                                                |

`--standalone` persists `metadata.standalone=true`. `wv health` excludes intentional standalones
from `orphan_nodes` and reports them separately as `intentional_standalones`.

## Node Statuses

| Status             | Meaning                              |
| ------------------ | ------------------------------------ |
| `todo`             | Ready unless blocked                 |
| `active`           | Claimed, in progress                 |
| `done`             | Completed — auto-unblocks dependents |
| `blocked`          | Waiting on another node              |
| `blocked-external` | Waiting on external dep (API, human) |

Lifecycle: `todo` → `active` → `done`. Set `blocked` via `wv block`.

## Context Packs

Run `wv context <id> --json` before starting complex work:

- **Cached per session** — second call is ~40% faster
- **Auto-invalidates** — cache clears when edges change
- **Limited output** — top 5 related, top 3 pitfalls (prevents context explosion)
- **Nested learnings** — ancestors include decision/pattern/pitfall from metadata

## Edge Context

Edges carry a `context` JSON field. Auto-generated summaries use node aliases and are marked
`auto: true`. For edges with semantic meaning, provide explicit context:

```bash
wv link wv-A wv-B --type=blocks --context='{"reason":"Auth API must deploy before client"}'
wv block wv-A --by=wv-B --context='{"reason":"Depends on schema migration"}'
wv resolve A B --winner=A --rationale="Winner has broader scope"
```

- **Auto-context** (`{"summary":"fix-auth blocks deploy","auto":true}`) — scannable at a glance
- **Explicit context** (`{"reason":"..."}`) — semantic, non-derivable, always preserved on re-link
- **Backfill** — `wv health --fix` enriches all empty edges with auto-context

## Procedures

Procedures are harness-agnostic how-to content kept out of standing context. Each lives once as a
canonical source (`templates/procedures/<id>.md` → installed `$CONFIG_DIR/procedures/<id>.md`) and
is projected into each harness's native surface (Claude skill, `.codex/weave.json`, Copilot
instructions). Every procedure resolves anywhere via its fallback command, which serves the
installed canonical body — so a pointer never breaks after `wv init-repo`.

| Procedure        | Description                                                              | Fallback                              |
| ---------------- | ------------------------------------------------------------------------ | ------------------------------------- |
| `session`        | Session-context management — 5-option framework, rewind, compact, phases | `wv guide --procedure=session`        |
| `agent-memory`   | Agent memory model and per-agent memory surfaces                         | `wv guide --procedure=agent-memory`   |
| `repair`         | Turn workflow defects into tracked remediation                           | `wv guide --procedure=repair`         |
| `subagents`      | Delegate bounded work with inherited graph context                       | `wv guide --procedure=subagents`      |
| `rules`          | Advisory workflow discipline                                             | `wv guide --procedure=rules`          |
| `epic-decompose` | Break an epic into features and tasks with parent edges and blocking     | `wv guide --procedure=epic-decompose` |
| `quality-gate`   | Recover from a GraphPolicyViolation (CC threshold) blocking `wv done`    | `wv guide --procedure=quality-gate`   |
| `graph-hygiene`  | Health checks, pruning, orphan classification, stale-node cleanup        | `wv guide --procedure=graph-hygiene`  |
| `precommit-gate` | Impact-scoped pre-commit test gate + CI `.weave/` hygiene                | `wv guide --procedure=precommit-gate` |
| `code-search`    | Two-surface code/graph search and `wv ready` re-ranking                  | `wv guide --procedure=code-search`    |

All procedure bodies live only in their canonical file and are reachable through their fallback.

## GitHub Integration

```bash
wv add "Fix auth bug" --gh          # Create node + GH issue (linked)
wv done <id>                        # Closes node AND linked GH issue
wv sync --gh                        # Sync all nodes ↔ GH issues
```

Always use `--gh` when work should be visible in GitHub. `wv done` auto-closes linked issues.

### Sync modes (`--mode=fast|full|repair`)

`wv sync --gh` accepts a mode flag that controls scope and recovery behaviour:

| Mode     | When                                                                 | Behaviour                                                                                                             |
| -------- | -------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------- |
| `fast`   | Default for `wv ship` and `session-end-sync.sh`                      | Bounded to focus node + parent + children + blockers; skips Phase 2/3                                                 |
| `full`   | Manual exhaustive reconcile; suspected drift; bulk import            | Walks every node and issue (slowest, most thorough)                                                                   |
| `repair` | After a timeout/Ctrl-C/crash mid-sync — `wv recover` recommends this | Same scope as `full` but resumes from `.weave/repair-checkpoint.json`; SIGINT/SIGTERM print the resume hint to stderr |

The checkpoint is removed on clean completion. To reset it manually:

```bash
rm -f .weave/repair-checkpoint.json
wv sync --gh --mode=full
```

## Learnings

```bash
wv done <id> --learning="decision: what was chosen | pattern: reusable technique | pitfall: gotcha to avoid"
```

Good learnings are specific, actionable, and scoped to a concrete context.

## Enforcement

Hooks and the CLI enforce active-node, close, and verification invariants. For advisory workflow
discipline and repair/delegation guidance, use the Procedures index above.

## Repair Workflow

When execution reveals a real workflow problem (broken hook, stale guidance, close-time friction, or
a missing guardrail), turn the defect into tracked remediation rather than fixing it silently:

1. Fix it in the current node only if it directly blocks safe completion.
2. Otherwise create a tracked repair node: `wv add "task: ..." --gh --parent=<feature-or-epic>`.
3. If current work depends on the fix, block it: `wv block <current-id> --by=<repair-id>`.
4. Save a trail before continuing:
   `wv trails save --msg="Detected workflow issue, created repair node, next step is ..."`.

For a GitHub sync interrupted by a timeout, Ctrl-C, or crash, resume with
`wv sync --gh --mode=repair` (see Sync modes above).

### Resumable close (`needs_human_verification`)

When `wv done` cannot auto-verify a close, the node is not lost: it is captured in a `pending_close`
state and flagged `needs_human_verification` rather than blocking the agent. Resume the close with
explicit human approval once the evidence is in hand. This keeps non-interactive agent flows from
hanging on close-time prompts while preserving the verification gate.

## Session End Behavior

The stop hook has one hard block; everything else soft-warns:

- **Active node open** → hard block. Close with `wv done <id> --learning="..."` first.
- **Uncommitted changes** → soft warning, does not block.
- **Unpushed commits / dirty .weave/** → soft warning. Run `git push` or `/close-session`.

No network calls in the hook (wv sync / git push belong in `/close-session`, not stop hook). The
`/close-session` skill handles the full protocol (sync, commit, push). Only invoke it when you're
actually done — a soft warning is not a signal to stop working.

## Skills

- `/weave [<id>|<text>]` — Graph-first orchestrator (primary interface)
- `/trails [<id>]` — Session memory capsule
- `/close-session` — End-of-session sync + push protocol

### Local Skills

Create project-specific skills by adding a `SKILL.md` file in `.claude/skills/<name>/`:

```bash
mkdir -p .claude/skills/my-skill
cat > .claude/skills/my-skill/SKILL.md << 'EOF'
---
name: my-skill
description: "What it does. Use when <trigger condition>."
---

# My Skill

Instructions here. Agents that support .claude/skills/ discover this automatically.
EOF
```

- **Skills** are auto-discovered from `.claude/skills/` by supporting agents (Claude Code, etc.) —
  no registration needed
- **Agents without skill support** (e.g. VS Code Copilot) use MCP tools or `copilot-instructions.md`
  instead
- Local skills are committed to git and shared with your team
- `wv init-repo --update` preserves user-created skills (only updates Weave-shipped ones)

## Agents

The default `weave` MCP server exposes all 40 tools. When `weave-inspect` is also registered,
read-only agents can use its 17-tool inspect subset.

- **weave-guide** — Workflow best practices, anti-patterns (session lifecycle tools)
- **epic-planner** — Strategic planning, scope, dependencies, risks (graph mutation tools)
- **learning-curator** — Extract learnings, retrospective analysis (read-only inspect tools)
