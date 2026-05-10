# Weave Agents

Specialized subagents for Weave workflow. Spawn via whatever agent-spawning mechanism your
host supports (Agent tool, MCP client subagent, shell subprocess, etc.).

| Agent            | Purpose                        | Trigger                          |
| ---------------- | ------------------------------ | -------------------------------- |
| weave-guide      | Workflow guidance               | Unsure how to use Weave          |
| epic-planner     | Strategic planning              | Starting a new epic or sprint    |
| learning-curator | Knowledge capture               | After completing significant work|

## Code search

If `wv index` has been run, prefer hybrid code search over grep/glob for discovery:

```bash
wv search --code "query"                  # hybrid BM25 + cosine (CLI)
wv search --code "query" --mode=fts       # exact tokens / function names
wv search --code "query" --graph          # include active Weave nodes per file
```

MCP equivalent: `weave_code_search` (parameters: `query`, `mode`, `limit`, `graph`).
