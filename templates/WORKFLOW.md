# Weave Workflow Reference

Canonical reference for `wv` — the task graph CLI for AI coding agents. Full docs: `wv guide` (MCP)
| Command list: `wv --help`

## Core Workflow

```txt
wv ready                          # 1. Find unblocked work
wv work <id>                      # 2. Claim it (sets active)
# ... do the work ...
wv done <id> --learning="..."     # 3. Complete with learnings
wv sync                           # 4. Persist to .weave/
git push                          # 5. MANDATORY before session end
```

Never edit a file without an active node. If `wv status` shows 0 active, run `wv work <id>` first.

## Commands

| Command                   | What it does                                       | Key flags                                    |
| ------------------------- | -------------------------------------------------- | -------------------------------------------- |
| `wv ready`                | List unblocked work                                | `--json`, `--count`                          |
| `wv work <id>`            | Claim node (sets active)                           |                                              |
| `wv add "<text>"`         | Create node                                        | `--gh`, `--status=`, `--parent=`, `--alias=` |
| `wv done <id>`            | Complete node (auto-closes linked GH issue)        | `--learning="..."`                           |
| `wv ship <id>`            | Done + sync + push in one step                     | `--learning="..."`, `--gh`                   |
| `wv update <id>`          | Modify node                                        | `--status=`, `--text=`, `--alias=`           |
| `wv quick "<text>"`       | Track trivial work (create active → commit → done) | `--learning="..."`                           |
| `wv show <id>`            | Node details + blockers                            | `--json`                                     |
| `wv list`                 | All non-done nodes                                 | `--all`, `--status=`, `--json`               |
| `wv block <id> --by=<id>` | Add dependency edge                                | `--context='{...}'`                          |
| `wv tree`                 | Epic → feature → task hierarchy                    | `--active`, `--depth=N`, `--mermaid`         |
| `wv path <id>`            | Ancestry chain                                     | `--format=chain`                             |
| `wv plan <file>`          | Import markdown as epic + tasks                    | `--sprint=N`, `--gh`, `--dry-run`            |
| `wv context <id> --json`  | Context pack (blockers, ancestors, pitfalls)       | Cached per session                           |
| `wv search <query>`       | Full-text search                                   | `--json`                                     |
| `wv status`               | Compact status (active/ready/blocked counts)       |                                              |
| `wv learnings`            | Show captured decisions/patterns/pitfalls          | `--category=`, `--grep=`, `--dedup`          |
| `wv link <from> <to>`     | Create semantic edge                               | `--type=`, `--context='{...}'`               |
| `wv health`               | System health check with score                     | `--json`, `--verbose`, `--fix`               |
| `wv sync`                 | Dump to `.weave/state.sql`                         | `--gh` for GH sync, `--dry-run`              |
| `wv load`                 | Restore from `.weave/state.sql`                    | Run by session start hook                    |
| `wv prune`                | Archive done nodes >48h                            | `--age=`, `--dry-run`                        |
| `wv quality scan`         | Scan repo for complexity + churn                   | `--exclude=`, `--json`                       |
| `wv quality hotspots`     | Ranked hotspot report                              | `--top=N`, `--json`                          |

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

## GitHub Integration

```bash
wv add "Fix auth bug" --gh          # Create node + GH issue (linked)
wv done <id>                        # Closes node AND linked GH issue
wv sync --gh                        # Sync all nodes ↔ GH issues
```

Always use `--gh` when work should be visible in GitHub. `wv done` auto-closes linked issues.

## Learnings

```bash
wv done <id> --learning="decision: what was chosen | pattern: reusable technique | pitfall: gotcha to avoid"
```

Good learnings are specific, actionable, and scoped to a concrete context.

## Rules

1. **Track ALL work** — `wv work <id>` or `wv add "<text>" --status=active` before editing files.
   Use `--gh --parent=<epic-id>` to link. Never edit without an active node.
2. **No untracked fixes** — even one-line changes get a node. Use `wv quick "<what>"` for trivial
   work.
3. **GitHub workflow** — create with `--gh`, close with `wv done` (auto-closes issue). Check
   `gh issue list` before session end.
4. **Sync + push mandatory** — `wv sync --gh` then `git push` before session end. Commit
   incrementally after each logical unit, not all at the end.
5. **Check context** — run `wv context <id> --json` before starting complex work.
6. **IDs are `wv-xxxxxx`** (4-6 hex chars). Use exact IDs from `wv ready`.
7. **Capture learnings** — use `--learning="..."` on `wv done` for non-trivial work.
8. **Bound session scope** — limit to 4-5 tasks per session. Context limits kill sessions mid-task.
9. **No hook bypass** — never use `--no-verify` or `WV_SKIP_PRECOMMIT=1`.

**Violation check:** If `wv status` shows 0 active nodes, STOP and claim one first.

## Session End Behavior

The stop hook enforces git hygiene with two severity levels:

- **Uncommitted changes** → soft warning (does not block). You may still be working.
- **Unpushed commits** → hard block. You committed but forgot to push — run `git push`.

The `/close-session` skill handles the full protocol (sync, commit, push). Only invoke it when
you're actually done — the soft warning is not a signal to stop working.

## Skills

- `/weave [<id>|<text>]` — Graph-first orchestrator (primary interface)
- `/breadcrumbs [<id>]` — Session memory capsule
- `/close-session` — End-of-session sync + push protocol

## Agents

- **weave-guide** — Workflow best practices, anti-patterns
- **epic-planner** — Strategic planning (scope, dependencies, risks)
- **learning-curator** — Extract learnings, retrospective analysis
