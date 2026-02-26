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
| `wv add <text>`           | Create node (returns `wv-xxxxxx` ID)     | `--status=`, `--metadata=`, `--alias=`                |
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
| `wv quality scan`         | Scan repo for complexity + churn         | `--exclude=`, `--json`                                |
| `wv quality hotspots`     | Ranked hotspot report                    | `--top=N`, `--json` (includes ev, trend, ownership)   |
| `wv quality diff`         | Delta vs previous scan                   | `--json` (includes trend_direction per file)          |
| `wv quality functions`    | Per-function CC for file or directory    | `--json` (dispatch-tagged, threshold: CC ≤ 10)        |

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

### CRITICAL: Always use the Weave workflow for ALL changes and task management

1. **Track ALL work in Weave** — before writing any code, run `wv work <id>` or
   `wv add "<description>" --status=active --gh --parent=<epic-id>`. Use `--gh` to create a linked
   GitHub issue, `--parent` to prevent orphan nodes. Never make changes without an active Weave
   node.
2. **No untracked fixes** — even small fixes, doc edits, or one-line changes get a Weave node. Use
   `wv quick "<what you did>" --learning="..."` for trivial work.
3. **Use correct GitHub workflow** — prevent orphaned issues
   - Create with GitHub: `wv add "Title" --gh`
   - Close: `wv done <id>` (auto-closes linked GitHub issue)
   - Check sync status: `gh issue list` before session end
4. `wv sync --gh` then `git push` is **mandatory** before session end — run `/close-session`
   - **Commit incrementally** — after each logical unit of work (test passing, feature complete),
     commit and push. Don't accumulate all changes for session end.
5. **Check context** — run `wv context <id> --json` before starting complex work
6. Follow the context policy from session start (see below)
7. IDs are `wv-xxxxxx` (4-6 hex chars). Use exact IDs from `wv ready` output
8. Capture learnings for non-trivial work — use `--learning="..."` flag on `wv done`
9. **Bound session scope** — limit to 4-5 tasks per session. For epics, work a bounded subset then
   start a fresh session for the rest. Context/usage limits kill sessions mid-task — focused
   sessions with fewer tasks have higher completion rates.
10. **Plan mode bypass** — when given a detailed spec or release plan, do NOT skip the Weave
    workflow. Create child nodes per phase (`wv add --parent=<epic> --gh`), claim each before coding
    (`wv work`), close with learnings (`wv done --learning`). Never `--no-verify` or
    `WV_SKIP_PRECOMMIT=1` to bypass the pre-commit hook.

**Violation check:** If you are about to edit a file and `wv status` shows 0 active nodes, STOP and
create/claim a node first.

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
