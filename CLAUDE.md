# Weave — Task Graph for AI Agents

Work is tracked as nodes in a SQLite graph — use `wv` for everything.

## Workflow

```txt
wv ready                          # 1. Find unblocked work
wv work <id>                      # 2. Claim it (or wv update <id> --status=active)
# ... do the work ...
wv done <id> --learning="..."     # 3. Complete with learnings
wv sync                           # 4. Persist to .weave/
git push                          # 5. MANDATORY before session end
```

**Note:** Use `--learning="..."` to capture decision/pattern/pitfall for non-trivial work.

## Node Statuses

| Status    | Meaning                             |
| --------- | ----------------------------------- |
| `todo`    | Default. Ready unless blocked       |
| `active`  | Claimed, in progress                |
| `done`    | Completed. Auto-unblocks dependents |
| `blocked` | Waiting on another node             |

Lifecycle: `todo` -> `active` -> `done`. Set `blocked` via `wv block`.

## Commands

| Command                   | Usage                                    | Notes                                                 |
| ------------------------- | ---------------------------------------- | ----------------------------------------------------- |
| `wv ready`                | List unblocked work                      | `--json`, `--count`                                   |
| `wv add <text>`           | Create node (returns `wv-xxxx` ID)       | `--status=`, `--metadata=`, `--alias=`                |
| `wv work <id>`            | Claim node (sets active)                 | Shorthand for `wv update --status=active`             |
| `wv done <id>`            | Complete node                            | Auto-unblocks dependents                              |
| `wv update <id>`          | Modify node                              | `--status=`, `--text=`, `--alias=`                    |
| `wv block <id> --by=<id>` | Add dependency edge                      | Sets target to `blocked`                              |
| `wv show <id>`            | Node details + blockers                  | `--json`                                              |
| `wv list`                 | All non-done nodes                       | `--all`, `--status=`, `--json`                        |
| `wv path <id>`            | Ancestry chain (recursive CTE)           | `--format=chain` for `A -> B -> C`                    |
| `wv tree`                 | Epic -> feature -> task hierarchy        | `--active`, `--depth=N`, `--json`                     |
| `wv plan <file>`          | Import markdown section as epic + tasks  | `--sprint=N`, `--gh`, `--template`, `--dry-run`       |
| `wv context <id>`         | Context Pack for node (--json only)      | Cached per session, see below                         |
| `wv status`               | Compact status (~15-35 tokens)           | Used by session start hook                            |
| `wv learnings`            | Show captured decision/pattern/pitfall   | `--category=`, `--grep=`, `--min-quality=`, `--dedup` |
| `wv health`               | System health check with score           | `--json`, `--verbose`, `--history[=N]`                |
| `wv prune`                | Archive done nodes >48h                  | `--age=`, `--dry-run`                                 |
| `wv search <query>`       | FTS5 full-text search                    | `--json`                                              |
| `wv sync`                 | Dump to `.weave/state.sql`               | `--gh` for GH sync, `--dry-run`                       |
| `wv load`                 | Restore from `.weave/state.sql`          | Run by session start hook                             |

## Context Packs

Use `wv context <id> --json` to get a comprehensive view of a node before starting work:

```bash
wv context wv-1234 --json | jq .
```

**Key features:**

- **Cached per session** - Second call is ~40% faster
- **Auto-invalidates** - Cache clears when edges change (block, link, done)
- **Limited output** - Top 5 related, top 3 pitfalls (prevents context explosion)
- **Nested learnings** - Ancestors include decision/pattern/pitfall from metadata

## GitHub Integration

When work should be tracked in GitHub, use the correct workflow to ensure sync:

```bash
wv add "Fix authentication bug" --gh  # Creates node + GH issue, links them
wv done wv-XXXX --learning="..."      # Closes node + linked GH issue
```

- `wv done` closes GitHub issues automatically when `gh_issue` metadata is present
- Creating nodes with `--gh` ensures proper linking

## Learnings

Capture learnings for non-trivial work using `wv done --learning`:

```bash
wv done <id> --learning="decision: What was chosen and why | pattern: Reusable technique | pitfall: Specific mistake to avoid"
```

**Decision:** Key choice made and reasoning.
**Pattern:** Reusable approach.
**Pitfall:** Specific gotcha to avoid.

View learnings: `wv learnings` or `wv learnings --node=<id>`

## Rules

1. **Use `wv` for ALL task tracking** — not markdown, not TODO comments, not mental notes
   - Before starting ANY work: Check `wv ready` for available tasks
   - When making changes: Create a node with `wv add` or claim existing with `wv work <id>`
   - After completing work: Close with `wv done <id> --learning="..."`
2. **Use correct GitHub workflow** — prevent orphaned issues
   - Create with GitHub: `wv add "Title" --gh`
   - Close: `wv done <id>` (auto-closes linked GitHub issue)
3. `wv sync` then `git push` is **mandatory** before session end — run `/close-session`
4. Follow the context policy from session start (see below)
5. IDs are `wv-xxxx` (4 hex chars). Use exact IDs from `wv ready` output
6. Capture learnings for non-trivial work — use `--learning="..."` flag on `wv done`

## Context Load Policy

Emitted by `context-guard.sh` on session start. Obey it:

- **HIGH**: Read files <500 lines whole. Grep first for larger files.
- **MEDIUM**: Always grep before read. No full reads >500 lines. Use line ranges.
- **LOW**: Always grep first. Only read <200 line slices. Summarize, don't quote.

## On-Demand Skills

- `/weave [<id>|<text>]` — Graph-first orchestrator (INTAKE, CONTEXT, EXECUTE, CLOSE phases)
- `/breadcrumbs [<id>]` — Session memory capsule (context notes for future sessions)
- `/close-session` — End-of-session sync + push protocol

## Weave Agents

Specialized agents for Weave workflow guidance:

- **weave-guide** — Workflow best practices, node creation guidelines, anti-patterns
- **epic-planner** — Strategic planning for epics (scope, features, dependencies, risks)
- **learning-curator** — Extract learnings from completed work, retrospective analysis

Use the Task tool with appropriate subagent_type when you need specialized Weave guidance.
