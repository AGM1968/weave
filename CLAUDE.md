<!-- ── BEGIN WEAVE CLAUDE.MD ── managed by wv init-repo, do not edit manually -->
## Weave Workflow

> Task tracking active. See `~/.config/weave/WORKFLOW.md` or `wv guide` (MCP) for the full reference.

```txt
git status && wv status           # 0. Check repo + graph state
wv search "<topic>"               # 1. Check for existing related work before claiming/creating
wv ready                          # 2. Find unblocked work
wv work <id>                      # 3. Claim it
# ... do the work ...
git add <files> && git commit -m "..."  # 4. Commit work files before wv done
wv done <id> --learning="..."     # 5. Complete with learnings
wv sync --gh && git add .weave/   # 6. Sync (may dirty .weave/)
git diff --cached --quiet || git commit -m "chore(weave): sync state [skip ci]"
git push                          # 7. mandatory
```

`wv ship <id>` is the close + sync shortcut for finishing a node. It does not push; if `wv status`
still reports pending Git sync, handle that separately or inspect it with `wv doctor` / `wv recover`.

`wv sync --gh` accepts `--mode=fast|full|repair` (and an optional `--node=<id>` focus). `fast` is
the default for `wv ship` and session-end (bounded scope); `full` is the explicit default for plain
`wv sync --gh`; use `--mode=repair` to resume from `.weave/repair-checkpoint.json` after an
interrupted sync — `wv recover` and the stop-hook recommend it when the checkpoint exists.

**No edits without an active node.** If `wv status` shows 0 active, claim one first.
Focused CLI help: `wv help <command>` or `wv <command> --help`.
<!-- ── END WEAVE CLAUDE.MD ── -->
