# Changelog

<!-- markdownlint-disable MD024 -->

## [1.4.1] - 2026-02-17

### Added

- Community section in README with links to Discussions and Issues
- Discussions guidance in CONTRIBUTING.md

## [1.4.0] - 2026-02-17

### Fixed

- **Phantom GH issue reopen prevention**: `wv sync --gh` Phase 1 no longer reopens GitHub issues
  that were closed by Weave itself. Before reopening, sync now checks the last comment for the Weave
  close marker (`Completed. Weave node`). This prevents the sync loop where a forgotten `wv done`
  caused sync to reopen an issue that was already properly closed. Fails open on API errors to
  preserve existing behavior.
- Mypy and Pylint issues resolved in `test_weave_gh_phases.py` (generic tuple type params, missing
  type annotations, unused arguments, line length)

### Added

- Edge system analysis and multi-developer limitations documented in `docs/DEVELOPMENT.md`
- Comprehensive release cycle documentation in `docs/DEVELOPMENT.md`
- `--tag` and `--release` flags for `build-release.sh` to automate Git tagging and GitHub Release
  creation
- Multi-developer workflow limitations noted in public README

## [1.3.1] - 2026-02-17

### Fixed

- Agent files (`.claude/agents/*.md`) now include required YAML frontmatter with `name` and
  `description` fields -- fixes Claude Code doctor parse errors on repos using Weave agents
- `wv sync --gh` now updates parent epic issue bodies (checkboxes + Mermaid) even when child issues
  are already closed -- previously the OPEN-only guard in `_handle_existing_issue` skipped body
  updates for closed issues, leaving epic checkboxes stale
- `pyproject.toml` version aligned to `1.3.x` (was `4.2.0` due to Poetry drift)

### Changed

- `build-release.sh` now ships `CLAUDE.md` (from template) and `.github/copilot-instructions.md` so
  both Claude Code and Copilot users get agent configs out of the box
- `build-release.sh` strips `[dependency-groups]` and `[tool.*]` sections from shipped
  `pyproject.toml` -- end users don't need dev tooling config (ruff, mypy, pytest, etc.)

## [1.3.0] - 2026-02-14

### Added

- `wv bulk-update` command -- update multiple nodes from JSON stdin with validation, dry-run, alias
  resolution, and support for alias/status/text/metadata/remove-keys fields
- Multi-developer workflow documentation in `docs/DEVELOPMENT.md`

### Fixed

- `wv-init-repo` now idempotent -- `wv init` failure on existing databases no longer kills the
  script. All sections (hooks, skills, agent config) execute regardless of DB state
- `wv-init-repo` exit code 1 on successful runs -- `[ ] && echo` pattern under `set -e` leaked
  non-zero exit when test condition was false. Replaced with `if/elif/fi`

## [1.2.0] - 2026-02-13

### Added

- `wv delete <id>` command -- permanently remove a node and its edges with `--force`, `--dry-run`,
  `--no-gh` flags. Archives node to JSONL before deletion, cascades edge cleanup, optionally closes
  linked GitHub issue. Warns if node has children unless `--force` (#633)
- `wv batch [file]` command -- execute multiple wv commands from file or stdin with `--dry-run` and
  `--stop-on-error` support. Enables bulk operations without custom scripts (#634)
- `wv tree --mermaid` -- built-in Mermaid graph generation with status colors
  (done/active/blocked/todo), implements and blocks edges, alias-preferred labels. Optional
  `--root=<id>` filter (#635)
- Plan parser: alias extraction from bold prefix (`**alias** -- description`), metadata tags
  `(priority: N)`, `(after: alias)`, `(status: done)`, two-pass dependency wiring with alias
  resolution (#629, #631)
- Plan parser: tasks created with `--force` to skip dedup check during bulk import
- `templates/PLAN.md.template` updated with new syntax documentation

### Fixed

- `wv init --force` now actually wipes DB + state files (previously `CREATE TABLE IF NOT EXISTS` was
  a no-op on existing data). Preserves `.weave/archive/` (#636)
- Dedup check on `wv add` relaxed: uses token-based AND matching (2+ significant words >4 chars)
  instead of exact phrase match. Reduces false positives during bulk import (#637)
- `wv plan --gh` rate limiting: 1-second throttle between GitHub API calls, errors surfaced instead
  of suppressed with `2>/dev/null`, failure count reported (#632)
- `_repo_hash()` newline mismatch: Python `hashlib.md5` now includes trailing `\n` to match bash
  `echo | md5sum` behavior. Fixed Mermaid graphs not propagating to GitHub issues (#639)
- `git pull --rebase --autostash` output leak: "Created autostash" message no longer contaminates
  `cmd_add` stdout when captured via `$()`. Fixes selftest failures and plan import issues
- `WV_CHECKPOINT_INTERVAL` default changed from 1800s to 0 -- auto-checkpoint now fires on every
  sync, preventing persistent dirty `.weave/` state
- `wv link` now resolves aliases for both from and to arguments
- Auto-create labels on `wv add --gh` for new repos
- Remove deprecated `sync-weave-gh.sh` from `install.sh`

## [1.1.0] - 2026-02-09

### Added

- `wv init` auto-recovery: detects missing hot zone after reboot, restores from `state.sql`
- `wv init --force` flag for intentional reinitialization
- `wv init` guard against accidental overwrite of existing data
- `install.sh --verify` runs `wv selftest` after install completes
- Generic CLAUDE.md template for target repos (replaces project-specific copy)
- 5-minute quickstart walkthrough in README
- `wv doctor` command for installation health checks
- `wv selftest` round-trip smoke test in isolated environment
- `wv tree` epic-to-feature-to-task hierarchy view
- `wv plan` markdown import as epic + linked tasks
- `wv context` context packs with caching and auto-invalidation
- `wv breadcrumbs` session context dump/restore
- `wv session-summary` session activity statistics
- `wv learnings` with `--category`, `--grep`, `--min-quality`, `--dedup` filters
- `wv audit-pitfalls` with resolution tracking
- `wv health --history` health score history log
- `wv quick` one-shot create+close for small tasks
- `wv ship` done+sync+push in one command
- Human-readable aliases for nodes (`--alias=`)
- Learning quality scoring with heuristic scores
- Learning deduplication via FTS5 phrase matching
- Auto-sync on write with configurable throttle (`WV_SYNC_INTERVAL`)
- Write-time validation warnings (orphans, missing learnings)
- Weave-ID trailers in auto-checkpoint commits
- GitHub issue templates with Weave ID field
- Bidirectional metadata sync with GitHub (labels, body markers)
- Live progress comments via `gh_notify()` hooks
- Mermaid dependency graphs in epic issue bodies
- Python sync module (3-phase sync replacing shell script)
- MCP server with 8+ tools for IDE integration
- Enhanced MCP tools: `weave_quick`, `weave_work`, `weave_ship`, `weave_overview`
- Comprehensive stress test suite (sync, concurrency, scale, fuzzing, recovery)
- Hook test suite (26 unit + 10 integration lifecycle tests)
- Context pack caching with automatic invalidation on graph changes

### Fixed

- `wv work` now sets status to `active` (was `in-progress`)
- `wv update` validates status enum (rejects invalid values)
- `wv prune --age=0h` rejected with error (was silently deleting all done nodes)
- FTS5 search safe with apostrophes and special characters
- `wv ready --json` returns `[]` when empty (was returning empty string)
- `wv path` no longer duplicates nodes in diamond dependencies
- Context pitfalls scoped to node ancestry (was globally broadcast)
- Health check validates status enum (was reporting 100/100 with invalid statuses)
- `wv done` no longer exits 141 (SIGPIPE) when closing GitHub issues
- `wv show` returns error for non-existent nodes (was exit 0)
- `wv prune` default age no longer produces invalid SQL
- `wv list --json` returns `[]` when empty
- Ghost edges removed and foreign key enforcement enabled

## [1.0.0] - 2026-02-02

Initial release: Weave v6.0 foundation.

- SQLite graph on tmpfs with WAL mode
- 26 CLI commands with modular `lib/` and `cmd/` split
- FTS5 full-text search
- XDG-compliant install layout
- Install lifecycle (`--dev`, `--uninstall`, `--upgrade`)
- Subagent context inheritance (`WV_ACTIVE`)
- Universal agent rule files (AGENTS.md, copilot-instructions.md)
- Regression test suite for all commands
