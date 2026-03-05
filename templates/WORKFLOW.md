# Weave Workflow Reference

Quick reference for `wv` — the task graph CLI for AI coding agents. Full docs: `wv guide` | Command
list: `wv --help`

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

## Key Commands

| Command                  | What it does                                 |
| ------------------------ | -------------------------------------------- |
| `wv ready`               | List unblocked work                          |
| `wv work <id>`           | Claim node (sets active)                     |
| `wv add "<text>" --gh`   | Create node + GitHub issue                   |
| `wv done <id>`           | Complete node (auto-closes linked GH issue)  |
| `wv ship <id>`           | Done + sync + push in one step               |
| `wv show <id>`           | Node details + blockers                      |
| `wv list`                | All non-done nodes                           |
| `wv tree`                | Epic → feature → task hierarchy              |
| `wv context <id> --json` | Context pack (blockers, ancestors, pitfalls) |
| `wv sync --gh`           | Persist state + sync GitHub issues           |
| `wv status`              | Compact status (active/ready/blocked counts) |
| `wv learnings`           | Show captured decisions, patterns, pitfalls  |

## Node Statuses

| Status             | Meaning                              |
| ------------------ | ------------------------------------ |
| `todo`             | Ready unless blocked                 |
| `active`           | Claimed, in progress                 |
| `done`             | Completed — auto-unblocks dependents |
| `blocked`          | Waiting on another node              |
| `blocked-external` | Waiting on external dep (API, human) |

## GitHub Integration

```bash
wv add "Fix auth bug" --gh          # Create node + GH issue (linked)
wv done <id>                        # Closes node AND linked GH issue
wv sync --gh                        # Sync all nodes ↔ GH issues
```

## Learnings Format

```bash
wv done <id> --learning="decision: what was chosen and why | pattern: reusable technique | pitfall: gotcha to avoid"
```

Good learnings are specific, actionable, and scoped to a concrete context.
