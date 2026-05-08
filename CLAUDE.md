<!-- ── BEGIN WEAVE CLAUDE.MD ── managed by wv init-repo, do not edit manually -->
## Weave Workflow

> Task tracking active. See `~/.config/weave/WORKFLOW.md` or `wv guide` (MCP) for the full reference.

```txt
git status && wv status           # 0. Check repo + graph state
wv ready                          # 1. Find unblocked work
wv work <id>                      # 2. Claim it
# ... do the work ...
git add <files> && git commit -m "..."  # 3. Commit work files before wv done
wv done <id> --learning="..."     # 4. Complete with learnings
wv sync --gh && git add .weave/   # 5. Sync (may dirty .weave/)
git diff --cached --quiet || git commit -m "chore(weave): sync state [skip ci]"
git push                          # 6. mandatory
```

**No edits without an active node.** If `wv status` shows 0 active, claim one first.
Focused CLI help: `wv help <command>` or `wv <command> --help`.
<!-- ── END WEAVE CLAUDE.MD ── -->
