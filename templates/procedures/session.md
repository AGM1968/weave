---
id: session
description:
  "Session-context management — the 5-option framework, rewind habit, compact steering, session
  phases, scope and token awareness. Use when a session grows long or context is tight."
fallback: "wv guide --procedure=session"
adapters: [claude, codex, copilot]
visibility: shared
status: ready
claude_skill: wv-session
---

# Session Context Management

Every turn is a branching point. Default “continue” accumulates context rot — performance degrades
under long context. Make a deliberate choice.

## The 5-Option Framework

| Option | When to use | Action |
| --- | --- | --- |
| **Continue** | Current approach is working and context is fresh | Keep going. |
| **Rewind** | Failed approach, tool error, wrong path, or dead end | Return to before the attempt. |
| **Compact** | Context is growing but direction is clear | Compact with an explicit focus and drop list. |
| **Clear** | Task is complete and the next task is unrelated | Save a trail, start fresh, reload the relevant context. |
| **Subagent** | Work produces intermediate output the parent will not need | Delegate and retain only the conclusion. |

## Rewind After a Failed Approach

Do not keep correcting in a polluted context. Failed calls and dead ends consume attention that
compaction cannot reliably recover.

Rewind when the first approach fails, when a tool produces irrelevant error output, or when the
architecture is discovered to be wrong after meaningful exploration.

1. Before a risky attempt, save a trail: `wv trails save --message="About to try X; state is Y"`.
2. After failure, use the host’s rewind/undo feature to return before the attempt.
3. Capture the lesson when closing the node: `wv done <id> --learning="pitfall: X failed because Y"`.
4. Start the replacement approach with the restored context.

If the host has no rewind feature, save a trail, clear the session, and reload the active node’s
context pack instead.

## Compact Steering

Compaction is lossy. Steer it before the context limit:

```text
/compact focus on: <active task description>, current approach, open blockers
         drop: completed work, exploratory dead ends, verbose tool output
```

After compaction, re-establish the critical state:

```bash
wv status
wv context <id> --json
```

## Session Phases

The enforcement layer has three phases:

| Phase | Meaning |
| --- | --- |
| `discover` | Read and search are allowed; edit-class tools still require a claimed node. |
| `execute` | An active node is required for substantive edits. `wv work <id>` enters this phase. |
| `closing` | `wv done <id>` has closed the node and follow-up commit/sync work is permitted. |

The phase is stored in the hot zone. A node inherited from a prior session must be explicitly
re-claimed; stale-node checks prevent accidental continuation of abandoned work.

## Two Sessions in One Repository

Sessions in one checkout share its hot zone, its git index and its working tree. Weave guards the
graph: each session's claims, Primary node and commit trailers are its own, and `wv load` and
another session's writes wait for each other. Nothing guards the working tree. Two sessions that
each hold a claim there can overwrite each other's uncommitted edits, and Weave refuses that
second claim. `wv work` names the other session's claim and prints the command for a linked
worktree:

```bash
git worktree add -b <branch> ../<repo>-<name> HEAD
```

Start the second session inside the worktree. It has its own hot zone, index and working tree, and
its commits reach the main branch like any other branch's. Worktrees share the repository's git
hooks: upgrade Weave only when no session's commit or push gate is running.

## Session Scope and Token Awareness

Keep a session to roughly 4–5 related tasks. Start fresh when work is independent, the context has
been compacted repeatedly, or prior exploration is obscuring the current task.

Use `wv bootstrap --json` once at session start and `wv status` for routine checks. To inspect actual
tool-output cost, enable call logging and use:

```bash
export WV_CALL_LOG=~/.local/share/weave/wv_calls.jsonl
wv analyze sessions --call-stats --top=5 --since-days=1 --source=agent
```

Prefer targeted reads (`wv query`, `wv search`, `wv context`) over broad graph dumps.
