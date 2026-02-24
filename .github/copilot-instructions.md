# GitHub Copilot Instructions

This repository uses the **Weave** graph-based workflow system. **Every code change must follow this
workflow. No exceptions.** A git pre-commit hook enforces this — commits are blocked if no Weave
node is active.

## Session Start (MANDATORY)

Run these before doing any work:

```bash
wv status                    # Check active/ready/blocked counts
wv learnings                 # Review captured patterns and pitfalls
wv ready                     # Find unblocked work
wv guide                     # Workflow quick reference (topics: workflow, github, learnings, context)
```

Or via MCP: call `weave_overview` which returns status + health + ready work in one call. Use
`weave_guide` (topic: workflow|github|learnings|context) to get a workflow reference without leaving
your client.

## Before Every Task

```bash
wv work <id>                             # Claim an existing task, OR:
wv add "<description>" --gh --parent=<id>  # Create node + GH issue + link to parent
wv context <id> --json                   # Understand dependencies and blockers
wv plan <file> --sprint=N --gh           # Import markdown plan as epic + tasks with GH issues
wv plan --template                       # Scaffold a new plan document
```

**Rules:**

- Always use `--gh` when creating nodes — every task needs a GitHub issue
- Always run `wv context <id> --json` before complex work
- Check learnings with `wv learnings --grep="<topic>"` for relevant prior decisions

## During Work

- One active node at a time
- Commit incrementally after each logical unit — don't accumulate
- Edit source files in `scripts/`, never installed copies in `~/.local/`
- After editing scripts, run `./install.sh` to sync installed copies

## Mermaid Graphs (REQUIRED for epics and features)

When working on epics or multi-task features, generate Mermaid dependency/progress graphs. This is
what makes Weave a graph system, not a flat checklist.

**When to generate:** At epic creation, during work (progress updates), at completion.

**How:** Use `wv tree --mermaid` (CLI) or MCP `weave_tree` with `mermaid=true`:

```bash
wv tree --mermaid                    # Full graph with status colors
wv tree --mermaid --root=<epic-id>   # Subtree for one epic
```

The output includes aliases as labels, status coloring (done=green, active=gold, blocked=red,
todo=gray), implements edges, and blocks edges. GitHub issue bodies also use this same output for
consistent rendering via `wv sync --gh`.

- Use `renderMermaidDiagram` if available, otherwise fenced code block in breadcrumbs

## Completing Work

```bash
wv done <id> --learning="<decision/pattern/pitfall>"
# Or use ship to done + sync + push in one step:
# IMPORTANT: commit code before ship — ship closes the node, blocking subsequent commits
git add <files> && git commit -m "..."
wv ship <id> --learning="<decision/pattern/pitfall>"  # Auto-detects GH-linked nodes
wv ship <id> --gh --learning="..."                     # Force GH sync
```

Always capture a learning. Include what worked, what didn't, or what future sessions should know.
Ask: "What would a future session get wrong without this?"

## Session End (MANDATORY)

```bash
wv sync --gh && git push     # Sync graph + GitHub issues, then push
```

**Not** `wv sync` — the `--gh` flag syncs GitHub issues. Without it, nodes created with `--gh` won't
have their status reflected on GitHub.

## MCP Tools

If your client supports MCP, prefer compound tools over CLI for multi-step operations:

<!-- markdownlint-disable MD060 -->

| Tool              | Equivalent CLI                         | Use for            |
| ----------------- | -------------------------------------- | ------------------ |
| `weave_overview`  | `wv status` + `wv health` + `wv ready` | Session start      |
| `weave_work`      | `wv work <id>` + `wv context <id>`     | Claiming tasks     |
| `weave_ship`      | `wv ship <id>`                         | Completing tasks   |
| `weave_preflight` | `wv preflight <id>`                    | Pre-action checks  |
| `weave_quick`     | `wv add` + `wv done` + `wv sync`       | Trivial one-step   |
| `weave_tree`      | `wv tree --json`                       | Epic hierarchy     |
| `weave_learnings` | `wv learnings --json`                  | Check prior work   |
| `weave_plan`      | `wv plan <file> --sprint=N`            | Import plan        |
| `weave_guide`     | `wv guide --topic=<topic>`             | Workflow quick ref |

For CLI operations via terminal: `wv` works — but the workflow steps above are still mandatory.

## Common Pitfalls

1. **Forgetting `--gh` or `--parent`** — Creates orphan nodes with no GitHub issue or parent link
2. **Skipping learnings** — Repeating mistakes that prior sessions already documented
3. **`wv sync` without `--gh`** — GitHub issues don't get updated
4. **Not reinstalling after script edits** — Installed copies drift from source
5. **Piping `db_query_json` into `jq`** — Causes SIGPIPE under `set -eo pipefail`; use intermediate
   variable
6. **Orphan nodes** — Run `wv health` to detect. Fix with
   `wv link <orphan> <epic> --type=implements` or `wv prune` for junk
7. **Plan mode bypass** — When given a release plan or spec, do NOT batch-execute without tracking.
   Create child nodes per phase (`wv add --parent=<epic> --gh`), claim before coding (`wv work`),
   close with learnings (`wv done --learning`). Never bypass the pre-commit hook.

## Full Documentation

- AGENTS.md — Universal agent instructions (workflow rules, commands, project structure)
- CLAUDE.md — Detailed workflow + hook documentation
- docs/WEAVE.md — Complete system specification
