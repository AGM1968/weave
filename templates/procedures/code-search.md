---
id: code-search
description:
  "Two-surface code/graph search and how wv ready re-ranks unblocked work by recent-edit overlap.
  Use when locating implementation or prior decisions, or to understand ready-list ordering."
fallback: "wv guide --procedure=code-search"
adapters: [codex, copilot]
visibility: shared
---

# Code Search

Two search surfaces, different signals:

| Command                      | Searches     | Use for                                             |
| ---------------------------- | ------------ | --------------------------------------------------- |
| `wv search "<topic>"`        | Graph nodes  | Prior decisions, findings, learnings, task history  |
| `wv search --code "<query>"` | Source files | Implementation location, function names, call sites |

Hybrid hunt pattern (highest signal):

```bash
wv search "auth"             # 1. What decisions/findings exist about auth?
wv search --code "auth"      # 2. Where is auth implemented?
wv learnings --grep="auth"   # 3. What pitfalls were hit?
```

Run `wv index` once per repo to enable `--code` mode (builds BM25 + vector index).

**No-index code search** — consumer's choice:

- `weave_code_search` (MCP) — Weave built-in, same hybrid ranking
- Semble: `semble search "<query>" <dir>` (CLI) or `mcp__semble__search` (MCP, pass `repo` param)
- Any tool works: ripgrep, semgrep, ast-grep, language server — Weave has no opinion here

## Ready Re-ranking

`wv ready` re-ranks unblocked nodes by overlap between `metadata.touched_files` and the per-session
recent-edits ring (last 20 edited paths, stored on tmpfs by `wv-touched-files` hook). Boosted nodes
show a green `[touched N]` marker in text output; JSON output re-orders silently.

After editing `scripts/cmd/wv-cmd-data.sh`, nodes whose `touched_files` include that path float to
the top — work already warm in file context surfaces first. Falls back to `created_at ASC` when no
edits have been made yet.

This signal is passive: it updates automatically as you edit files. No configuration needed.

**When markers appear:** `[touched N]` fires only after the first `PostToolUse` hook in the session
populates the recent-edits ring (Edit/Write tool calls; Bash reads do not count). Cold sessions and
the first `wv ready` invocation show nodes in `created_at` order with no markers. JSON output
silently sorts by overlap when present; falls back to `created_at` order otherwise.
