# Weave Workflow Reference

Canonical reference for `wv` — the task graph CLI for AI coding agents. Full docs: `wv guide` (MCP)
| Command list: `wv --help`

## Core Workflow

```txt
git status && wv status           # 0. Pre-flight — check state before acting
wv ready                          # 1. Find unblocked work
wv work <id>                      # 2. Claim it (sets active)
# ... do the work ...
git commit                        # 3. Commit work files (before wv done)
wv done <id> --learning="..."     # 4. Complete with learnings
wv sync --gh                      # 5. Sync graph + GH (may dirty .weave/)
git add .weave/ && git commit     # 6. Commit graph state if dirty
git push                          # 7. MANDATORY before session end
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

## Epic Decomposition

Epics with no child edges produce a **flat graph** — `wv context`, `wv path`, and commit aggregation
all break silently. Always link sub-tasks at creation time:

```bash
# 1. Create the epic
EPIC=$(wv add "Epic: big feature" --metadata='{"type":"epic","priority":1}')

# 2. Create features linked to the epic — --parent creates the implements edge
FEAT=$(wv add "Feature: sub-capability" --metadata='{"type":"feature"}' --parent=$EPIC)

# 3. Create tasks linked to their feature
TASK=$(wv add "Task: specific work" --metadata='{"type":"task"}' --parent=$FEAT)

# 4. Set blocking order (epic unblocked only when features done)
wv block $EPIC --by=$FEAT
wv block $FEAT --by=$TASK
```

**Rules:**

- `--parent=` is **mandatory** for every feature and task — never optional
- Use `/wv-decompose-work` skill for structured breakdowns
- Run `/weave-audit` — reports epics with no children and deducts score

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

## Repair Workflow

When you detect a real workflow issue during execution (drift, missing guardrail, broken prompt/doc,
close-time friction), turn it into tracked remediation immediately:

1. **Decide whether it belongs in the current node**
   - Fix it in the current node only if it is required to complete the current task safely.
   - Otherwise create follow-up work instead of expanding scope silently.
2. **Create remediation work in the graph**
   - Use `wv add "Task: ..." --gh --parent=<feature-or-epic>` for discovered repair work.
   - If the current task cannot finish without the repair, block it:
     `wv block <current> --by=<new>`.
   - If the repair is related but not blocking, link it with
     `wv link <new> <current> --type=relates_to`.
3. **Leave breadcrumbs for the next step**
   - Save what was detected, what was created, and what should happen next with
     `wv breadcrumbs save`.
4. **Avoid unattended close-time stalls**
   - For non-interactive agent flows, prefer recording pending-close state and surfacing
     `needs_human_verification` rather than blocking indefinitely on stdin prompts.
   - Humans can resume and approve explicitly; agents should stop in a resumable state, not hang.

## Rules

1. **Track ALL work** — `wv work <id>` or `wv add "<text>" --status=active` before editing files.
   Use `--gh` for GitHub-linked work. Use `--parent=<epic-id>` for sub-tasks — this is
   **mandatory**, not optional (see Epic Decomposition). Never edit without an active node.
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
10. **No duplicate background commands** — before issuing any long-running command (`make check`,
    `wv sync --gh`, `npm run build`, `git push`), verify it is not already running. If a command
    goes to background, wait for its completion notification before re-issuing. Running the same
    command twice causes double syncs, wasted CI time, and conflicting writes.
11. **Graph records intent, conversation implements it** — before discussing what to do next, create
    the node. Intent not in the graph does not survive a crash or reboot.

    ```
    # Correct: node first, then discuss
    wv add "sync-state visibility" --parent=<epic>  →  then plan and implement

    # Wrong: intent lives only in chat
    "Item 2 is sync-state visibility — here's the plan..."  [session ends — intent lost]
    ```

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

Instructions here. Claude Code discovers this automatically.
EOF
```

- **Claude Code** auto-discovers skills from `.claude/skills/` — no registration needed
- **VS Code Copilot** does not see skills (use MCP tools or `copilot-instructions.md` instead)
- Local skills are committed to git and shared with your team
- `wv init-repo --update` preserves user-created skills (only updates Weave-shipped ones)

## Agents

All agents use the main `weave` MCP server (all 31 tools). Each specializes in a subset:

- **weave-guide** — Workflow best practices, anti-patterns (session lifecycle tools)
- **epic-planner** — Strategic planning, scope, dependencies, risks (graph mutation tools)
- **learning-curator** — Extract learnings, retrospective analysis (read-only inspect tools)
