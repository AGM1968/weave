# Weave Development Guide

Guide for developing and testing Weave CLI changes.

## The Installed vs Local Script Problem

**Pitfall:** Editing `scripts/wv` but testing with the installed `~/.local/bin/wv` leads to
confusion when changes don't appear.

### Solution: Development Workflow

When developing Weave CLI changes:

```bash
# Option 1: Test with explicit path (RECOMMENDED)
./scripts/wv ready

# Option 2: Reinstall after each change
./install.sh  # Reinstalls to ~/.local/bin/

# Option 3: Temporarily override PATH
export PATH="$(pwd)/scripts:$PATH"
wv ready  # Now uses local ./scripts/wv
```

### Quick Check

```bash
# Which wv are you using?
which wv
# Returns: /home/user/.local/bin/wv (installed)
# Or:      /home/user/Projects/memory-system/scripts/wv (local)

# Test with local version explicitly
./scripts/wv --version

# After changes, always test with explicit path first
./scripts/wv <command>
```

## Development Testing Checklist

### Before Committing Code Changes

```bash
# 1. Test with local script
./scripts/wv <new-feature>

# 2. Run on test database
WV_DB=/tmp/test-weave.db ./scripts/wv init
WV_DB=/tmp/test-weave.db ./scripts/wv add "Test node"

# 3. Test installed version (optional)
./install.sh
wv <new-feature>

# 4. Run any relevant tests
# (if test suite exists)

# 5. Verify no syntax errors
bash -n scripts/wv
shellcheck scripts/wv  # if available
```

### Testing Hook Changes

Hooks live in `.claude/hooks/` as source and are installed globally to `~/.config/weave/hooks/` by
`install.sh`. Under Alt-A (v1.15.0+), all hooks run from the global location — there are no
per-project hook copies.

```bash
# After editing hooks, sync to global location
./install.sh  # Copies .claude/hooks/*.sh → ~/.config/weave/hooks/
              # Also re-registers all hooks in ~/.claude/settings.json

# Test a hook directly (pass a simulated payload via stdin)
echo '{"tool_name":"Write","tool_input":{"file_path":"/tmp/test.py"}}' | \
  ~/.config/weave/hooks/pre-action.sh

# Verify hooks are registered in global settings
jq '.hooks | length' ~/.claude/settings.json
```

### Testing Skills

Skills live in `.claude/skills/`:

```bash
# After editing skill markdown
./install.sh  # Copies to ~/.config/weave/skills/

# Skills are loaded by Claude Code automatically
# Just reload the project or restart Claude Code session
```

## SQLite Development

### In-Memory Database Location

```bash
# Default hot zone
ls -la /dev/shm/weave/brain.db

# Check which DB is being used
echo $WV_DB
# Returns: /dev/shm/weave/brain.db (or custom path)

# Inspect directly
sqlite3 /dev/shm/weave/brain.db "SELECT * FROM nodes LIMIT 5;"
```

### Schema Changes

When modifying schema:

```bash
# 1. Update schema in wv_init_db()
# 2. Add migration function if needed
# 3. Test migration on fresh DB
rm /dev/shm/weave/brain.db
./scripts/wv init

# 4. Test migration on existing DB
./scripts/wv load  # Should run migrations
```

## Mermaid Rendering Architecture

Weave generates Mermaid dependency graphs for GitHub issue bodies, CLI output, and MCP clients. All
surfaces share a single canonical source to prevent drift.

### Single-Source Rendering

The authoritative Mermaid output comes from `wv tree --mermaid`:

```bash
wv tree --mermaid                    # Full graph
wv tree --mermaid --root=wv-1234     # Subtree rooted at a specific node
```

This produces a `graph TD` flowchart with:

- Status-colored nodes (done=green, active=gold, blocked=red, todo=gray)
- Human-readable aliases as labels (falls back to truncated text)
- `implements` edges (solid) and `blocks` edges (dashed red)

### GitHub Sync Integration

The Python `render_mermaid_from_tree()` function in `scripts/weave_gh/rendering.py` calls
`wv tree --mermaid --root=<id>` via subprocess. If the CLI call fails (e.g., no children), it falls
back to the in-process `render_mermaid_graph()` renderer:

```python
mermaid = render_mermaid_from_tree(root_id)  # Try CLI first
if not mermaid:
    mermaid = render_mermaid_graph(nodes)     # Fallback
```

### MCP Integration

The MCP `weave_tree` tool accepts `mermaid` (boolean) and `root` (string) parameters, passing
`--mermaid` and `--root=<id>` to the CLI.

### Label Escaping Rules

Mermaid labels must be safe for the Mermaid parser:

1. **Double-quote inside brackets**: `node["My label"]` not `node[My label]`
2. **Strip backticks**: Mermaid v10+ interprets backticks as markdown-mode delimiters
3. **Replace parentheses/brackets**: `(`, `)`, `[`, `]` in label text become `-` to avoid
   shape-syntax collisions

Both the bash renderer (`wv-cmd-graph.sh`) and the Python fallback (`rendering.py`) apply these
rules.

## Common Development Tasks

### One-Command Graph Enrichment

Use `wv enrich-topology` to apply canonical epic/task topology from a JSON spec in one step.

```bash
# Preview actions (no graph changes)
wv enrich-topology templates/TOPOLOGY-ENRICH.json.template --dry-run

# Apply links/blocks and sync issue bodies
wv enrich-topology templates/TOPOLOGY-ENRICH.json.template --sync-gh
```

Spec supports resolving by Weave IDs or GitHub issue numbers (`gh_issue`/`gh_pairs`). This is the
recommended way to keep human and agent workflows consistent for graph curation.

### Adding a New Command

1. Add case in `main()` function
2. Implement `cmd_<name>()` function
3. Add to `cmd_help()` usage text
4. Test with `./scripts/wv <new-command>`
5. Update CLAUDE.md and docs

### Adding a New Skill

1. Create `.claude/skills/<skill-name>/SKILL.md`
2. Add YAML frontmatter with name and description
3. Add to `install.sh` (both cp and curl sections)
4. Test with `/skill-name` in Claude Code
5. Update README.md skills table

### Adding a New Hook

1. Create `.claude/hooks/<hook-name>.sh`
2. Add to `install.sh` (both `cp` and `curl` sections under `SHIP_FILES`)
3. Add the event/matcher/command entry to the `build_hooks_json()` function in `install.sh`
4. Run `./install.sh` to copy to `~/.config/weave/hooks/` and re-register in
   `~/.claude/settings.json`
5. Add tool permission to `.claude/settings.local.json` if needed (gitignored, personal)
6. Test with appropriate trigger event

**Alt-A architecture (v1.15.0+):** All hook registrations live in `~/.claude/settings.json`
(global). Per-project `.claude/settings.json` must have **no `hooks` key** — any hooks key
completely shadows the global hooks file (shallow spread; coexistence is impossible). `wv init-repo`
writes a permissions-only `settings.json` and actively strips stale hooks keys.

**Hook path convention:** Hooks use absolute paths at install time (written by `install.sh` via
`jq --arg h "$hooks_dir"`). Do NOT use `$CLAUDE_PROJECT_DIR` or relative paths in hook command
strings — these do not expand correctly in Claude Code's settings engine.

**VS Code product distinction:**

- **Claude Code VS Code extension** (`anthropic.claude-code`): reads `~/.claude/settings.json`
  directly, fires all hook events with full parity to the CLI. No extra VS Code setting needed.
- **GitHub Copilot** (`github.copilot-chat`): a separate product that does not process
  `~/.claude/settings.json`. Enforcement is cooperative only: `weave_edit_guard` MCP tool (advisory)
  and the git pre-commit hook (hard block). See `.github/copilot-instructions.md`.

## Testing Crash Sentinel

The crash sentinel (v1.16.0) detects abruptly terminated sessions. A sentinel file at
`$WV_HOT_ZONE/.session_sentinel` is written by `session-start-context.sh` and cleared by
`session-end-sync.sh`. Presence at next session start = previous session crashed.

### Running Crash Sentinel Tests

```bash
bash tests/test-crash-sentinel.sh     # 38 tests, ~13s
```

Covers: sentinel lifecycle, crash detection, auto-breadcrumb, `wv recover --session`, reboot
recovery, and the 5-criterion crash benchmark simulation.

### Manual Crash Test

```bash
# 1. Start a Claude Code session (writes sentinel)
# 2. Kill it: Ctrl+C or kill the process
# 3. Start a new session — should see:
#    "CRASH DETECTED — previous session ended abruptly at <timestamp>"
#    "Recovery breadcrumb generated"
# 4. Verify: wv breadcrumbs show
# 5. List orphaned nodes: wv recover --session
```

### Sentinel Lifecycle

| Event            | Action                             | File                     |
| ---------------- | ---------------------------------- | ------------------------ |
| Session start    | Write sentinel (two-phase)         | session-start-context.sh |
| Session end      | Delete sentinel (after sync+push)  | session-end-sync.sh      |
| Crash detected   | Read old sentinel, auto-breadcrumb | session-start-context.sh |
| Reboot (no file) | Check active nodes, soft warning   | session-start-context.sh |

## Debugging

### Enable Trace Mode

```bash
# See all SQL queries
set -x
./scripts/wv ready
set +x

# Or use bash debug
bash -x ./scripts/wv ready
```

### Check Database State

```bash
# List all nodes
sqlite3 /dev/shm/weave/brain.db "SELECT id, text, status FROM nodes;"

# Check edges
sqlite3 /dev/shm/weave/brain.db "SELECT * FROM edges;"

# Verify metadata
sqlite3 /dev/shm/weave/brain.db "SELECT id, metadata FROM nodes WHERE id='wv-xxxxxx';"

# Check indexes
sqlite3 /dev/shm/weave/brain.db "SELECT name FROM sqlite_master WHERE type='index';"
```

### Common Issues

#### "Database is locked"

```bash
# Find process holding lock
lsof /dev/shm/weave/brain.db

# Kill if stale
pkill -f weave
```

#### `[ test ] && cmd` under `set -e`

The `wv` entry point sets `set -euo pipefail`. The pattern `[ "$var" = true ] && do_something` is
**fatal** when `$var` is not `true` — the `[ ]` test returns exit code 1, which `set -e` treats as a
failure. This is safe mid-function (the next statement resets `$?`), but **at the end of a
function** it becomes the function's return code, killing the caller.

```bash
# BAD — returns 1 when _journaled=false, kills caller under set -e
[ "$_journaled" = true ] && journal_complete "$step"

# GOOD — if/fi returns 0 when condition is false
if [ "$_journaled" = true ]; then journal_complete "$step"; fi
```

Fixed in v1.16.1: `cmd_sync` used the bad pattern at lines 292-293, causing every `wv ship` to leave
an incomplete journal entry.

#### "Permission denied" on hooks

```bash
# Make executable
chmod +x .claude/hooks/*.sh
```

#### Changes not appearing

```bash
# Remember: installed vs local script!
which wv  # Check which one you're using
./scripts/wv <cmd>  # Use explicit path
```

## Testing Migrations

When adding database migrations:

```bash
# Save current state
wv sync
cp .weave/state.sql .weave/state.sql.backup

# Test migration on old data
./scripts/migrate-something.sh

# Verify
wv list --json | jq '.[].new_field'

# If broken, restore
sqlite3 /dev/shm/weave/brain.db < .weave/state.sql.backup
```

## Release Process

Weave has two repositories:

- **memory-system** (private) -- source/development repo at `AGM1968/memory-system`
- **weave** (public) -- clean distribution repo at `AGM1968/weave`, built from memory-system

### Version Locations

Version must be bumped in **8 locations simultaneously**:

| File                          | Purpose                                                      |
| ----------------------------- | ------------------------------------------------------------ |
| `scripts/lib/VERSION`         | Primary -- used by `wv --version`                            |
| `pyproject.toml`              | Python weave_gh module version                               |
| `mcp/package.json`            | MCP server npm package version                               |
| `mcp/package-lock.json`       | npm lockfile (run `npm install --package-lock-only` in mcp/) |
| `mcp/src/index.ts`            | MCP server version string (line ~1349)                       |
| `CHANGELOG.md`                | Release notes header                                         |
| `docs/WEAVE.md`               | Doc version + last updated date                              |
| `templates/Makefile.template` | Template comment                                             |

### Pre-Release Checklist

```bash
# 1. Bump version in all 8 locations
echo "X.Y.Z" > scripts/lib/VERSION
# Edit pyproject.toml "version" field
# Edit mcp/package.json "version" field
cd mcp && npm install --package-lock-only  # Updates mcp/package-lock.json
# Edit mcp/src/index.ts version: "X.Y.Z"  ← must match package.json
# Update CHANGELOG.md: add ## [X.Y.Z] - YYYY-MM-DD section
# Update docs/WEAVE.md: version + last updated date
# Update templates/Makefile.template: comment version

# 2. Update docs if features changed
# AGENTS.md, README.md, README.public.md, docs/WEAVE.md

# 4. Run tests
./tests/run-all.sh

# 5. Verify installer
./build-release.sh --verify

# 6. Commit
git add -A && git commit -m "vX.Y.Z: <summary>"
git push
```

### Building a Release

**For major/minor releases** (many files changed): use `build-release.sh` for a clean rebuild.

**For patch releases** (few files changed): copy only the changed files to the weave repo
incrementally — faster and preserves weave repo git history.

#### Patch Release (recommended for bug fixes)

```bash
# 1. Bump version in all 8 locations in memory-system (see Version Locations above)
# 2. Run make check
poetry run make check

# 4. Commit and tag in memory-system
git add -A && git commit -m "chore: bump to vX.Y.Z"
git tag vX.Y.Z && git push && git push origin vX.Y.Z
gh release create vX.Y.Z --title "vX.Y.Z" --notes "..."  # on memory-system

# 5. Copy only the changed files to weave repo
cp scripts/weave_gh/phases.py   /path/to/weave/scripts/weave_gh/phases.py
cp scripts/lib/VERSION          /path/to/weave/scripts/lib/VERSION
cp mcp/package.json             /path/to/weave/mcp/package.json
cp mcp/src/index.ts             /path/to/weave/mcp/src/index.ts
cp CHANGELOG.md                 /path/to/weave/CHANGELOG.md
# IMPORTANT: do NOT copy pyproject.toml — weave repo has dev deps stripped.
# Only bump the version field:
sed -i 's/version = "OLD"/version = "NEW"/' /path/to/weave/pyproject.toml

# 6. Commit, tag, push weave repo
cd /path/to/weave
git add -A && git commit -m "chore: bump to vX.Y.Z\n\n<fix summary>"
git tag vX.Y.Z && git push && git push origin vX.Y.Z
gh release create vX.Y.Z --title "vX.Y.Z" --notes "..."  # on weave repo
```

#### Full Release (major/minor, or first release after large changes)

```bash
# Standard build (to dist/)
./build-release.sh

# Build to public repo location with tarball (preserves .git/)
./build-release.sh --output=/path/to/weave --tar

# Full release: build + tag source + tar + GitHub Release
./build-release.sh --output=/path/to/weave --release

# Commit and push (normal git workflow — .git/ is preserved)
cd /path/to/weave
git add -A && git commit -m "vX.Y.Z: <summary>"
git tag vX.Y.Z && git push && git push origin vX.Y.Z
gh release create vX.Y.Z --title "Weave X.Y.Z" --notes "..."
```

### build-release.sh Flags

| Flag           | Effect                                                                            |
| -------------- | --------------------------------------------------------------------------------- |
| `--output=DIR` | Output directory (default: `dist/weave-<version>/`)                               |
| `--tar`        | Create `.tar.gz` archive alongside the directory                                  |
| `--verify`     | Install to temp dir and run selftest after build                                  |
| `--tag`        | Create annotated git tag `v<version>` on source repo, push it                     |
| `--release`    | Full release flow (implies `--tag --tar`): tag source, tar, create GitHub Release |
| `--dry-run`    | Preview shipping manifest without building                                        |

### Updating Dev Machines After a Release

`wv-update` downloads from `AGM1968/weave` GitHub releases/raw content. It has two failure modes:

1. **CDN caching** — GitHub's raw content may serve stale files for several minutes after a push.
   `wv-update` may install the previous version even after the new release exists.
2. **Version already current** — if the installed version matches what's in `VERSION` on main,
   `wv-update` skips the install.

**For development builds** (pre-release commits on main), always use:

```bash
cd ~/Documents/memory-system
git pull
./install.sh   # Installs directly from local clone, bypasses GitHub CDN
```

**For released versions** after CDN propagation (usually a few minutes):

```bash
wv-update   # Safe once GitHub reflects the new release
```

**Verify the fix is installed** (don't rely on version number alone for patch releases):

```bash
grep 'specific_function_or_pattern' ~/.local/lib/weave/weave_gh/phases.py
```

### Pitfalls

- **build-release.sh uses rsync** -- it builds to a temp dir then `rsync --delete --exclude=.git`
  into the output directory. This preserves `.git/` in the target repo while removing stale files.
  No force push needed after a full rebuild.
- **Do NOT copy pyproject.toml directly to weave repo** -- the weave repo has dev deps stripped by
  the build script. Only update the `version` field in-place with `sed`.
- **build-release.sh wipes live DB if run from project dir without isolation** -- the `--verify`
  step runs `wv init --force` in an isolated temp directory to prevent this. See learning
  `pitfall-db-isolation`.
- **Version drift** -- all 8 version locations must match. Check them explicitly before release.
- **TOML stripping uses Python** -- sed/regex fail because TOML array values contain `[` characters.
  The build script uses a Python line-by-line parser to strip `[dependency-groups]` and `[tool.*]`
  sections.
- **wv-update CDN lag** -- after pushing to AGM1968/weave, wait a few minutes before running
  `wv-update` on other machines, or use `git pull && ./install.sh` from memory-system instead.

## Useful Aliases

Add to your shell profile:

```bash
# Use local wv during development
alias wv-dev='./scripts/wv'

# Quick DB inspect
alias wv-db='sqlite3 /dev/shm/weave/brain.db'

# Test with clean DB
alias wv-test='WV_DB=/tmp/test-weave.db ./scripts/wv'
```

## Related Documentation

- [System Design](WEAVE.md) - Architecture and design reference
- [CLAUDE.md](../CLAUDE.md) - User-facing workflow
- [CONTRIBUTING.md](../CONTRIBUTING.md) - Contribution guidelines

## Multi-Developer Workflow

Weave supports multiple developers working on the same repository. The design is **local-first**:
each developer's hot zone (tmpfs) is independent, and GitHub issues provide the shared view.

### How It Works

1. **Each developer runs `wv init-repo`** (or standalone `wv-init-repo`) on their clone. This is
   idempotent -- safe to re-run. Use `wv init-repo --update` after Weave upgrades to refresh skills,
   agents, and copilot-instructions.
2. **`.weave/state.sql`** is committed to git and serves as the persistent snapshot.
3. **`.gitattributes`** uses `merge=ours` for `.weave/` files -- the local dump always wins on merge
   conflicts (the hot zone DB is the source of truth, not the committed file).
4. **GitHub issues** (created via `--gh` flag) are the shared coordination layer. All developers see
   the same issues regardless of local graph state.
5. **`wv sync --gh`** round-trips node text/status/metadata via GitHub issues, but **does not
   round-trip edges** (`implements`, `blocks`, etc.). Edge topology is persisted in
   `.weave/state.sql`.

### Setup for a New Developer

```bash
# 1. Clone the repo
git clone <repo-url> && cd <repo>

# 2. Install Weave (one-time, system-wide)
# Get install.sh from the memory-system repo, then:
./install.sh                  # Core CLI
./install.sh --with-mcp       # Optional: MCP server for Copilot/Claude

# 3. Initialize Weave in this repo
wv init-repo --agent=copilot  # For VS Code Copilot
wv init-repo --agent=claude   # For Claude Code (default)
wv init-repo --agent=all      # Both
wv init-repo --update         # After Weave upgrades: refresh skills/agents/instructions

# 4. Verify
wv health                     # Should show healthy state
wv status                     # See active/ready counts
```

### Daily Workflow

```bash
# Start of day: pull latest and reload graph
git pull
wv load                       # Reload from .weave/state.sql if hot zone is stale

# Do work (normal Weave workflow)
wv ready                      # Find unblocked work
wv work <id>                  # Claim a task
# ... code ...
wv done <id> --learning="..." # Complete

# End of day: sync and push
wv sync --gh                  # Persist graph + update GitHub issues
git push
```

### Conflict Resolution

Since `.weave/state.sql` uses `merge=ours`, merge conflicts are automatically resolved by keeping
the local version. After pulling remote changes:

```bash
git pull                      # merge=ours keeps local state.sql
wv load                       # restore local hot-zone DB from .weave/state.sql
wv sync --gh                  # sync node fields with GitHub issues
```

If another developer closed a GitHub issue you also have locally, `wv sync --gh` Phase 2
(GH-to-Weave) will detect the closure and update your local node.

**Important:** `wv sync --gh` cannot reconstruct missing edge topology from GitHub. If your graph
looks flat (`wv tree` empty/flat, many orphans), recover from the authoritative machine's
`.weave/state.sql` and run `wv load` before syncing.

### Two-Machine Safety Protocol

For setups like "build machine + development machine", use one authoritative graph source.

1. Pick one machine as the **graph authority** for `.weave/state.sql`.
2. On the non-authoritative machine, pull repo updates and run `wv load` before any `wv sync --gh`.
3. Only run `wv sync --gh` after both machines have converged on the same `.weave/state.sql`.
4. If either machine shows edge loss (`wv health` orphan spike, `wv tree` flattening), stop syncs,
   copy authoritative `.weave/state.sql`, then run `wv load`.

This prevents GitHub issue body updates from masking a local topology loss.

### Best Practices

- **Use `--gh` on every node** -- GitHub issues are how developers coordinate
- **Use aliases** -- `wv add "Fix auth" --alias=fix-auth --gh` makes the graph readable for everyone
- **Sync before pushing** -- `wv sync --gh && git push` ensures GitHub issues reflect your work
- **Don't manually edit `.weave/state.sql`** -- always use `wv` commands
- **One active node per developer** -- prevents stepping on each other's work
- **Run `wv load` before cross-machine sync** -- especially after pull/reboot/upgrade
- **Treat edge loss as state-recovery incident** -- restore `.weave/state.sql` first, then sync

### Edge System and Multi-Developer Limitations

The graph uses 8 typed edges (see [Data Model](WEAVE.md#33-edge-types) for the full reference). This
section documents how they behave in multi-developer scenarios and known limitations.

#### What works well (single-developer)

| Edge Type     | Role                                                        | Status |
| ------------- | ----------------------------------------------------------- | ------ |
| `blocks`      | Only type that gates `wv ready`; auto-unblocks on `wv done` | Solid  |
| `implements`  | Powers `wv tree` hierarchy (epic->feature->task)            | Solid  |
| `addresses`   | Tracks pitfall resolution; used by health score             | Solid  |
| `references`  | Discovery via context packs (top 5, sorted by weight)       | Solid  |
| `supersedes`  | Conflict resolution via `wv resolve --winner`               | Solid  |
| `relates_to`  | General links; bidirectional via `wv resolve --defer`       | Solid  |
| `contradicts` | Health penalty (-15/each); surfaced in context packs        | Solid  |
| `obsoletes`   | Node replacement via `wv resolve --merge`                   | Solid  |

The edge schema includes `weight` (float 0-1) and `context` (JSON) fields. Both are accepted and
stored but minimally used in queries today -- `weight` sorts related nodes in context packs,
`context` is displayed in `wv edges` output only.

#### Known limitations for multi-developer use

**No ownership or assignment model:**

There is no `owner`, `assignee`, or `claimed_by` field on nodes or edges. The only coordination
mechanism is GitHub issue assignees (set via `gh issue edit --add-assignee`). The graph itself
cannot answer "who is working on what?" without checking GitHub.

**Single-writer graph architecture:**

`.weave/state.sql` uses `merge=ours` in `.gitattributes` -- local dump always wins on merge. This
means:

- Two developers editing the graph concurrently will lose one's changes on `git pull`
- The "loser" must `wv sync --gh` to recover state from GitHub issues (Phase 2 backfill)
- There is no CRDT, operational transform, or edge-level merge strategy
- This is by design: the hot zone (tmpfs) is the source of truth, not the committed file

**No `wv unlink` command:**

Edges can only be removed by: (1) `wv delete` (removes the entire node + edges), (2) `wv resolve`
(removes `contradicts` edges), or (3) raw `sqlite3` on the hot zone DB. There is no
`wv unlink <from> <to> --type=<T>` command. This makes edge cleanup manual.

**Shallow cycle detection:**

`wv block` checks for 1-hop circular blocks (A blocks B, B blocks A) but not deeper cycles
(A->B->C->A). `implements` edges have no cycle detection at all. Deep cycles in `blocks` chains
would cause `wv ready` to never surface the affected nodes.

#### Future work (not scheduled)

These would be needed for true multi-developer support:

1. **Assignment model** -- `owner` field on nodes, `wv assign <id> <user>` command,
   `wv ready --mine` filtering
2. **Edge-level merge** -- replace `merge=ours` with a merge driver that diffs edges individually,
   or move to a CRDT-based state format
3. **`wv unlink` command** -- remove specific edges without deleting nodes
4. **Deep cycle detection** -- recursive CTE check on `blocks` chains during `wv block`
5. **Weight-based filtering** -- `wv ready --min-weight=0.8` or weight thresholds in context packs

These are tracked for consideration in a future release. The current system is designed and tested
for **single-developer + AI agent** workflows.
