<!-- ── BEGIN WEAVE CLAUDE.MD ── managed by wv init-repo, do not edit manually -->
## Weave Workflow

> Task tracking active. Canonical reference: `wv guide` or `~/.config/weave/WORKFLOW.md`.

```txt
if ! command -v wv >/dev/null 2>&1; then wv() { ./scripts/wv "$@"; }; fi
# ./scripts/wv appends existing $HOME/.local/bin and $HOME/.cargo/bin for user tools;
# the Weave Makefile targets apply the same PATH fallback for sandbox shells.
wv bootstrap --json               # 0. Session snapshot — replaces git status + wv status
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

`wv ship <id>` close + sync shortcut. `wv sync --gh` accepts `--mode=fast|full|repair`; use
`--mode=repair` to resume from `.weave/repair-checkpoint.json` after an interrupted sync.

**No edits without an active node.** If `wv status` shows 0 active, claim one first.
Discovery before claiming may read, search, and report only.
Focused CLI help: `wv help <command>` or `wv <command> --help`.
<!-- ── END WEAVE CLAUDE.MD ── -->
