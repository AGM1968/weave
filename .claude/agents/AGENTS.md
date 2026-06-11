# Weave Agent Pack

These agent prompts are Claude-hosted today, but their content should describe the portable Weave
contract used by Claude, VS Code/Copilot, Codex, CI jobs, and local automation. Keep Weave's
identity intact: graph memory, semantic relationships, trails, recovery, and learnings are the
point.

## Start

Use the cheapest complete context surface first:

```bash
if ! command -v wv >/dev/null 2>&1; then wv() { ./scripts/wv "$@"; }; fi
wv bootstrap --json
```

Read these signals: active node, ready work, sync state, recent learnings, and context pack. If
there is no active node, use `wv search "<topic>" --limit=5`, `wv ready`, then `wv work <id>`.
Only create a new active node when no related node fits.

## Economy

- One bootstrap call beats separate `status`, `ready`, `context`, and `learnings` calls.
- Use targeted readers: `show`, `context`, `search`, `query`, `related`, `edges`, `learnings`.
- Avoid `wv list --all` except for intentional exhaustive audits.
- Prefer `wv query` for filtered graph reads, for example `wv query status=done HAS learning`.
- Use `wv analyze sessions --call-stats --since-days=1 --source=agent` to find expensive command
  patterns (window + source filter; unfiltered counts are dominated by cheap hook calls).
- Use `wv search --code` for indexed code discovery; use `rg` for exact filesystem search.

## Weave Memory Primitives

- Nodes: work, findings, epics, tasks, and spikes with criteria and risks.
- Edges: blockers plus semantic links such as `implements`, `addresses`, and `contradicts`.
- Context packs: bounded task context for agents.
- Trails: resumable handoff state across sessions.
- Learnings: decision, pattern, and pitfall memory attached to completed work.

## Close

```bash
git add <files>
git commit -m "<type>: <summary>"
wv done <id> --learning="decision: ... | pattern: ... | pitfall: ..."
wv sync --gh
git add .weave/
git diff --cached --quiet || git commit -m "chore(weave): sync state [skip ci]"
git push
```

`wv ship <id> --learning="..."` is acceptable for done + sync, but it still requires a Git push and
may require `wv recover` if interrupted.

## Subagents

| Agent | Purpose | Best trigger |
| --- | --- | --- |
| `weave-guide` | Workflow and command routing | User is unsure how to use Weave |
| `epic-planner` | Shape epics, sprints, and dependencies | New initiative needs breakdown |
| `learning-curator` | Extract decision/pattern/pitfall memory | Completed work lacks useful learning |

## Portability Rule

Do not bake Claude-only assumptions into Weave guidance. Consumer repositories may use Weave for
solo coding, team issue tracking, audits, retrospectives, CI-assisted maintenance, or long-running
agent work. Host wiring may differ, but the core lifecycle stays stable: bootstrap, claim, load
context, guard edits, implement, verify, commit, close with learning, sync, push.
