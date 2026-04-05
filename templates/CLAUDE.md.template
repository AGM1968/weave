<!-- ── BEGIN WEAVE CLAUDE.MD ── managed by wv init-repo, do not edit manually -->
## Weave Workflow

> Task tracking active. See `~/.config/weave/WORKFLOW.md` or `wv guide` (MCP) for the full reference.

```txt
wv ready                          # 1. Find unblocked work
wv work <id>                      # 2. Claim it
# ... do the work ...
wv done <id> --learning="..."     # 3. Complete with learnings
wv sync --gh && git add .weave/   # 4. Sync (may dirty .weave/)
git diff --cached --quiet || git commit -m "chore(weave): sync state [skip ci]"
git push                          # mandatory
```

**No edits without an active node.** If `wv status` shows 0 active, claim one first.
<!-- ── END WEAVE CLAUDE.MD ── -->
