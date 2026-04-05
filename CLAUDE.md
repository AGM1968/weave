# Memory System v6.0 (Weave)

In-memory graph for AI coding agents. Work is tracked as nodes in a SQLite graph on tmpfs — use `wv`
for everything. Full reference: `wv --help` | Skills: `/dev-guide` (development), `/weave`
(workflow)

## Workflow

```txt
wv ready                          # 1. Find unblocked work
wv work <id>                      # 2. Claim it
# ... do the work ...
wv done <id> --learning="..."     # 3. Complete with learnings
wv sync --gh && git add .weave/   # 4. Sync (may dirty .weave/)
git diff --cached --quiet || git commit -m "chore(weave): sync state [skip ci]"
git push                          # mandatory
```

**No edits without an active node.** If `wv status` shows 0 active, claim or create one first.

## Rules

1. **Track ALL work** — `wv work <id>` or `wv add "<text>" --status=active` before editing files.
   Use `--gh` for GitHub-linked work, `--parent=<id>` to prevent orphans.
2. **No untracked fixes** — even one-line changes get a node. Use `wv quick "<text>"` for trivial.
3. **GitHub workflow** — create with `--gh`, close with `wv done` (auto-closes linked issue).
4. **Sync + push mandatory** — `wv sync --gh`, then `git add .weave/ && git diff --cached --quiet
   || git commit`, then `git push` before session end. Commit incrementally after each logical
   unit, not all at the end.
5. **Check context** — `wv context <id> --json` before complex work.
6. **Capture learnings** — `--learning="decision: ... | pattern: ... | pitfall: ..."` on `wv done`.
7. **Bound scope** — 4-5 tasks per session. Context limits kill sessions mid-task.
8. **No hook bypass** — never `--no-verify` or `WV_SKIP_PRECOMMIT=1`.
9. Follow the **context load policy** from session start (HIGH/MEDIUM/LOW).
10. **Graph records intent, conversation implements it** — before discussing what to do next, create
    the node. Intent not in the graph does not survive a crash or reboot. (Canonical rule + example
    in `templates/WORKFLOW.md` §Rules)

## Context Load Policy

Emitted by `context-guard.sh` on session start. Obey it:

- **HIGH**: Read files <500 lines whole. Grep first for larger files.
- **MEDIUM**: Always grep before read. No full reads >500 lines. Use line ranges.
- **LOW**: Always grep first. Only read <200 line slices. Summarize, don't quote.

## Development (this repo only)

- **Source vs installed:** Edit `scripts/`, never `~/.local/bin/`. Run `./install.sh` to sync.
- **GitHub sync:** `wv sync --gh` (Python module). Legacy bash script is deprecated.
- **Prefer implementation:** Start coding when task is clear. Plans <10 lines.
- **Testing:** `make check` before committing. See `/dev-guide` for full test/release workflow.

## Session End

The stop hook has two modes:

- **Uncommitted changes** → soft warning (stderr), does not block.
- **Unpushed commits** → hard block. Run `git push` or invoke `/close-session`.
