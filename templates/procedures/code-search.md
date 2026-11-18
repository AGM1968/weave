---
id: code-search
description:
  "Focused search: define the target before searching, search the graph and the code with bounded
  results, follow cross-references, and stop when the target is found. Use before broad exploration,
  when locating implementation or prior decisions, or when a task names node ids, issues or files."
fallback: "wv guide --procedure=code-search"
adapters: [claude, codex, copilot]
visibility: shared
claude_skill: zero-in
---

# Code Search

A search starts from a named target and stops when the target is found. Searching "to see what is
there" fills the context with files that are never used and pulls the work off its task.

## Define the target first

Before the first search, answer four questions:

- **What** is wanted: a specific function, pattern or concept, not "anything related".
- **Why**: how the result will be used.
- **When to stop**: the success condition, set before searching.
- **How many** results are useful: one exact match, the top five, or every instance.

"Find where JWT tokens are validated" and "find three examples of the error-handling pattern" are
targets; "see how authentication works" and "explore the API" are not.

## Search surfaces

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

## Bounded search order

Use the most specific tool first and widen only when it misses:

1. Code search: `wv search --code "<concept>"` (hybrid), `--mode=fts` for an exact name, flag or
   token, `--graph` to see which active nodes already touch the files. Results carry the file, line
   range and snippet.
2. Exact text search (ripgrep or grep) when code search misses or the file is not indexed; narrow it
   by file type or path.
3. A file-name listing (glob) only when the question is about structure.
4. Read only the lines a search returned, not whole files.

Boundaries:

- Read at most three to five files in full; take line ranges otherwise.
- Follow the directives of the session's context load policy, as `wv context-policy` states them.
- Stop as soon as the target is found; never keep searching after the answer is in hand.

## Report, then decide

Before widening a search, report it: the target, each search and its hit count, what was found
(`file:line`), whether that is enough, and the next step.

- **Found**: read only that section and go on with the task; note the location for later.
- **Not found**: check the terms (typo, synonym) and the assumption (wrong layer, different
  pattern); ask the owner whether the target exists.
- **Too many results**: add a type, path or glob filter, narrow the terms, or sample a few
  representative hits rather than all of them.

## Cross-references

When a task, node or document names other work, extract the references and follow them on purpose:

```bash
wv refs <file>                       # or: wv refs -t "<text>", or text on stdin
wv refs -t "<text>" --max=10 --json  # at most 10 per pass (the default)
wv refs <file> --link --from=<id>    # also record edges from <id> to the nodes it names
```

| Reference        | Suggested follow-up     |
| ---------------- | ----------------------- |
| `wv-xxxxxx`      | `wv show wv-xxxxxx`     |
| `#N`, `gh-N`     | `gh issue view N`       |
| `See Note N`     | `rg -n "Note N" docs/`  |
| `ADR-N`, `RFC-N` | `rg -l "ADR-N" docs/`   |
| a file path      | read the file (bounded) |

`wv refs` only suggests commands: review them, run the ones the task needs, and summarise what each
reference held. Do not recurse; extract again from a followed reference only when it is needed.

## Ready Re-ranking

`wv ready` re-ranks unblocked nodes by overlap between `metadata.touched_files` and the per-session
recent-edits ring (last 20 edited paths, stored on tmpfs by `wv-touched-files` hook). Boosted nodes
show a green `[touched N]` marker in text output; JSON output re-orders silently.

After editing `scripts/cmd/wv-cmd-data.sh`, nodes whose `touched_files` include that path float to
the top — work already warm in file context surfaces first. Falls back to `created_at ASC` when no
edits have been made yet.

This signal is passive: it updates automatically as you edit files. No configuration needed.

**When markers appear:** `[touched N]` fires only after the first file edit the host reports to
`wv hook dispatch` in the session (the `after_edit` event of `contracts/hook-events-v1.schema.json`,
whatever the host calls its edit tool) populates the recent-edits ring. Shell reads do not count.
Cold sessions and the first `wv ready` invocation show nodes in `created_at` order with no markers.
JSON output silently sorts by overlap when present; falls back to `created_at` order otherwise.
