# Weave Agents

Specialized subagents for Weave workflow. Spawn via whatever agent-spawning mechanism your host
supports (Agent tool, MCP client subagent, shell subprocess, etc.).

## Session start (always)

```bash
if ! command -v wv >/dev/null 2>&1; then wv() { ./scripts/wv "$@"; }; fi
# ./scripts/wv appends existing $HOME/.local/bin and $HOME/.cargo/bin for user tools.
wv bootstrap --json   # single call: active/ready/blocked + recent learnings + context policy
```

Key signals to check: `active` count (must claim before editing), `git_sync` status, `ready` list,
`context_policy` (HIGH/MEDIUM/LOW — governs file read depth), recent `learnings`.

## Session close (always)

```bash
git add <files> && git commit -m "..."          # commit work first
wv done <id> --learning="decision: ... | pattern: ... | pitfall: ..."
wv sync --gh && git add .weave/                 # sync; may dirty .weave/
git diff --cached --quiet || git commit -m "chore(weave): sync state [skip ci]"
git push                                        # mandatory
```

For a quick close: `wv ship <id> --learning="..."` (done + sync, still requires push after).

## Operating rules

- **No edits without an active node.** `wv status` shows 0 active -> `wv work <id>` first.
- Discovery before claiming may read, search, and report only.
- **Claim before creating.** `wv search "<topic>"` before `wv add` to avoid duplicates.
- **Set criteria+risks at creation time**, not reactively at claim time.
- **Commit before `wv done`** — pre-commit hook blocks after node is closed.
- **Context pack before complex work:** `wv context <id> --json`

## Subagent catalog

| Agent            | Purpose            | Trigger                           |
| ---------------- | ------------------ | --------------------------------- |
| weave-guide      | Workflow guidance  | Unsure how to use Weave           |
| epic-planner     | Strategic planning | Starting a new epic or sprint     |
| learning-curator | Knowledge capture  | After completing significant work |

## Code search

If `wv index` has been run, prefer hybrid code search over grep/glob for discovery:

```bash
wv search --code "query"                  # hybrid BM25 + cosine (CLI)
wv search --code "query" --mode=fts       # exact tokens / function names
wv search --code "query" --graph          # include active Weave nodes per file
```

MCP equivalent: `weave_code_search` (parameters: `query`, `mode`, `limit`, `graph`).
