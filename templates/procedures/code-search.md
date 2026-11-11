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

To find where a name is defined, search for the bare name: `wv search --code cmd_done` prints
`Definition of cmd_done:` with every defining `file:line` (shell functions, Python `def`/`class`,
TypeScript functions, classes and arrow consts) ahead of the ranked results, or says none was found;
`--json` carries it as `definition`. It reads the definition table `wv index` builds with the
chunks.

The `--code` index lives in the hot zone, not in `.weave/`: a reboot or a fresh zone empties it.
Session start rebuilds an empty index in the background without embeddings (BM25, a few seconds),
and rebuilds one made for an older HEAD in the mode it was built in; `wv search --code` reports
`chunks: empty` until that finishes. Set `WV_SESSION_INDEX=0` to turn this off and run `wv index`
yourself.

Embeddings (vector and hybrid ranking) are optional. They need `model2vec` (`>=0.8.1,<0.9.0`) in the
interpreter `wv` runs Python with: the repository's `.venv/bin/python3` when present, else `python3`
on `PATH`. The first embedding run downloads `minishlab/potion-code-16M` (about 32 MB) and needs
network access once. Run `wv index` without `--no-embed` to add them; later session-start rebuilds
keep them. Without `model2vec`, or offline, `wv index` stores no embeddings and says so, and search
falls back to BM25.

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
