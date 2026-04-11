# Changelog

<!-- markdownlint-disable MD024 -->

## [1.35.0] - 2026-04-11

### Fixed

- **pre-close-verification hook + wv done**: jq `//` alternative operator treats `false` as falsy,
  causing `finding.fixable = false` to be rejected as missing. Fixed both the hook and CLI to use
  `($field | type) == "boolean"` instead of `($field // null | type) == "boolean"`.
- **bash-dedup hook**: `wv sync` pattern matched anywhere in the command string, including inside
  quoted argument values (e.g. `--verification-evidence="...wv sync --gh..."`). Tightened regex to
  require command-segment boundary (start of string or after shell operator `[;&|]+`). Same fix
  applied to `git push` pattern.
- **bash-dedup hash inconsistency**: `bash-dedup.sh` and `bash-dedup-post.sh` used `printf '%s'` for
  repo hash (giving `9127bf5c`), diverging from the `echo` convention used by all other hooks and
  `wv-config.sh` (giving `175b8f29`). Standardised to `echo` across both files.
- **wv findings list / wv ready**: Finding text hard-truncated at 72/68 characters. Now uses
  `tput cols` with 120-char fallback so full sentences are visible in standard terminals.

### Tests

- Hook tests: 4 new cases covering inline `--verification-method` and `--verification-evidence`
  flags in pre-close-verification (previously untested branch).
- Hook tests: 3 new cases verifying `wv sync` inside quoted arguments does not create a dedup lock.

## [1.34.0] - 2026-04-10

### Added

- **Applied-deltas manifest** (`.weave/.applied_deltas`): `wv load` now records each successfully
  applied delta file and skips re-applying it on subsequent loads when `state.sql` has been updated
  since. Prevents double-replay of delta changesets when `wv load` is called multiple times between
  syncs. Guard condition: manifest is trusted only when `state.sql` mtime > manifest mtime (a sync
  ran after the last load, so `state.sql` incorporates those changes).

### Fixed

- **Delta changeset correctness — INSERT/UPDATE split**: `wv_delta_changeset` previously emitted
  `INSERT OR REPLACE` for both INSERT and UPDATE trigger events, silently overwriting all fields on
  any update. UPDATE events now emit `UPDATE nodes SET <changed-fields>` using field-level diff.
  Only fields that actually changed appear in the SET clause (NULL-safe `IS NOT` comparison via
  `rtrim` for trailing commas, no-op guard for identical writes). This is the primary correctness
  fix for concurrent multi-agent field edits where two agents modify different fields on the same
  node.
- **`_warp_changes` excluded from `dump_state_sql`**: the trigger-tracking table was previously
  included in `state.sql` dumps, causing `wv_delta_has_changes` to return true immediately after
  every fresh `wv load` (phantom change detection). `state.sql` now dumps `nodes` and `edges` only.
- **`wv init` test hang** (`#`-comment in SQL string): bash `#` is not a valid SQL comment token.
  The `_WV_DELTA_TRIGGERS_EDGES` shell variable contained a `#` comment that sqlite3 rejected,
  causing `wv init` to exit 1 under `set -e` in test environments. Converted to `--` SQL comments.
- **`wv health` exit 2 in test environments**: `ls *.jsonl` with no match exits 2; `set -o pipefail`
  propagated this through `_health_cache_summary`'s command substitution, making `wv health` exit 2
  in any directory with no Claude session JSONL. Fixed with `|| true` inside the subshell.

## [1.33.0] - 2026-04-08

### Added

- **`wv findings list`**: new subcommand showing all finding-type nodes with fixable/confidence/
  violation_type summary. Accepts `--fixable` to filter to actionable items and `--json` for
  machine-readable output.
- **`wv ready` findings section**: fixable finding nodes (with no active fix task) are surfaced as a
  separate "Findings to implement" section below the regular ready list. Finding nodes are excluded
  from the main ready list to avoid duplication.
- **`wv cache`**: new command reporting Claude Code prompt-cache health from recent session JSONLs.
  Shows per-session and aggregate `cache_read` vs `cache_creation` ratios, detects standalone Bun
  binary (sentinel bug risk), and flags `deferred_tools_delta` presence (session resume regression).
  Accepts `--sessions=N`, `--all` (all projects), and `--json`.
- **`wv health` cache summary**: `wv health` now includes a one-line Cache: entry showing the latest
  session's read ratio and status, with a pointer to `wv cache` for full detail.

## [1.32.0] - 2026-04-07

### Added

- **Historical findings promotion**: `wv findings promote` now mines completed-node learnings and
  historical finding/pitfall text into dry-run or applyable finding candidates.
- **Signal-class filtering**: historical promotions are typed as `defect`, `guardrail`,
  `root_cause`, or `tooling`, with additive flags to expose non-defect classes when requested.

### Fixed

- **Default findings noise**: tooling/version-scan chatter, operator workflow notes, and typing-only
  mypy guidance are suppressed from the default defect-only view unless tooling is explicitly
  included.
- **Historical findings ranking**: additive small windows now reserve visibility for requested
  classes, and operational guardrails no longer fall back into the default defect bucket.
- **Historical findings apply safety**: `--top` now defines the reviewed candidate window for both
  dry-run and apply, and `--apply` no longer backfills deeper-ranked items when reviewed candidates
  are skipped as already promoted.
- **Historical findings atomicity**: numbered multi-bug learnings split into separate candidates
  instead of shipping one bundled promotion, and known same-bug `_convert_sampled_features` variants
  no longer consume duplicate top-window slots.

## [1.31.0] - 2026-04-07

### Added

- **Finding phase workflow**: `wv finding <text>` creates a finding node linked to the current
  audit/work node. `pre-close-verification` enforces strict finding schema (summary, severity,
  location fields) before close. Graph and context commands include finding nodes in output.

### Fixed

- **Finding schema validation**: strict validation in `pre-close-verification` rejects malformed
  finding nodes at close time rather than at sync time.
- **`wv done` overlap advisory**: no longer errors when the learning similarity check returns an
  advisory-only result; close proceeds normally.
- **`wv sync --gh` stale lock recovery**: if the flock holder process is dead, the lock file is
  unlinked and acquisition retried automatically. Live holder logs its PID. Eliminates need for
  manual `rm -f /tmp/weave/sync.lock`.
- **`bash-dedup` hooks not registered**: `bash-dedup.sh` (PreToolUse) and `bash-dedup-post.sh`
  (PostToolUse) were copied by `install.sh` but never wired into `~/.claude/settings.json` —
  duplicate long-running commands (make check, wv sync --gh, git push) were not blocked.
- **`bash-dedup-post.sh` background detection**: belt-and-suspenders check reads both
  `tool_input.run_in_background` and `tool_response.output` pattern to preserve the dedup lock for
  background commands.

### Runtime (internal — not in public release)

- **Finding phase workflow (runtime)**: `wv_client.py` finding support; compliance and bootstrap
  context updated for finding node tracking.

## [1.30.0] - 2026-04-06

### Added

- **`wv done --verification-method` / `--verification-evidence`**: Inline verification flags
  eliminate the mandatory two-step `wv update` → `wv done` sequence. The pre-close hook recognises
  the flags directly in the command string; `cmd_done` writes them to metadata before the close path
  runs. Old `wv update` path still works.

### Fixed

- **`wv sync` state.sql size**: FTS5 index was included in `sqlite3 .dump` output, inflating
  state.sql from ~300KB to 55MB. The dump now excludes FTS shadow tables (`nodes_fts*`,
  `edges_fts*`), reducing state.sql by ~99%.

### Runtime (internal — not in public release)

- **OpenNodeHook**: `before_answer()` redirect fires when the agent reaches `done=True` with an
  unclosed wv_work node. One-shot to prevent loops; seeds pre-existing active nodes on turn-0 for
  continuation sessions.
- **Compliance R9/R10**: R9 flags `wv_done` for nodes never claimed via `wv_work`; R10 flags nodes
  left open at session end. Both support pre-claimed credit for continuation sessions.
- **Diminishing-returns fix**: `BudgetTracker` now includes `cache_creation_tokens` in the delta
  calculation; `_DIMINISHING_PASS_COUNT` raised 3→10. Prevents false session termination under
  Anthropic prompt caching.
- **Compliance bootstrap fallback**: `_parse_session` now parses `graph_active` from the turn-0 user
  message (`Work: N active`) when no `session_start` event is present — fixes spurious R10
  violations on all continuation sessions.

## [1.29.8] - 2026-04-05

### Fixed

- **`bash-dedup.sh` atomic lock**: replaced check-then-write with `set -o noclobber` redirect —
  eliminates TOCTOU race between simultaneous PreToolUse invocations.
- **`bash-dedup.sh` timestamp-based TTL**: lock now stores explicit epoch on line 1; stale check
  reads that value instead of relying on file mtime. TTLs raised to 30 min (make), 5 min
  (sync/install/pytest), 2 min (push).
- **`bash-dedup.sh` portable hash**: hash command chain `md5sum → md5 → sha256sum → "default"`
  prevents hook failure on macOS and other systems without GNU `md5sum`.

## [1.29.7] - 2026-04-05

### Added

- **`bash-dedup.sh` / `bash-dedup-post.sh` hooks**: PreToolUse/PostToolUse pair that prevents
  duplicate long-running Bash commands (make check, wv sync --gh, git push, ./install.sh, npm,
  pytest). Uses per-repo lock files with TTL-based expiry for background commands.

### Fixed

- **`wv_add --force` tool gap**: `WvClient.add()` and the `wv_add` tool schema/handler now expose
  the `--force` flag to bypass "similar active nodes exist" CLI warning.
- **R2 compliance score cap per rule**: `_score()` previously deducted per-violation, causing a
  single root-cause (no wv_work) to cascade to 0/100. Now capped at one deduction per rule.
- **Stale preflight test**: `test_runtime_phase1.py` assertion updated to match app behaviour after
  multi-active-node check was downgraded to warning in v1.29.6.
- **`wv_add` R1/R2 gate**: requires explicit `status=active` to satisfy discovery/claim phases —
  default-status adds do not silently satisfy compliance gates.

## [1.29.6] - 2026-04-05

### Fixed

- **`stop-check.sh` dirty weave state downgraded to soft warn**: hard block now fires only on
  unpushed commits (real work loss risk). Dirty `.weave/` with no unpushed commits exits 0 with a
  stderr note — auto-checkpoint handles the sync, no session interruption.
- **TUI multi-active-node check downgraded to warning**: `_agent_start_blocker` no longer
  hard-blocks when multiple nodes are active. A 4-second notification is shown and the agent
  proceeds — dev workflow legitimately keeps multiple nodes active; agent selects work via
  `wv_status`.

## [1.29.5] - 2026-04-05

### Fixed

- **`stop-check.sh` cooldown lock**: after emitting a hard block, subsequent responses within 120s
  emit a soft stderr warning instead of re-blocking — allows agent to execute sync commands without
  being blocked on every response. Lock is cleared on clean state; checks still run during cooldown.
- **`stop-check.sh` cooldown enforcement (P2)**: cooldown now suppresses the hard-block only, not
  the dirty-state checks — state detection still runs every response during the window.
- **`session-start-context.sh` session-start auto-commit**: `.weave/` writes during session start
  (crash-recovery breadcrumbs, migrations) are committed immediately before the first response,
  preventing the stop-hook from firing spuriously. Scoped to `.weave/` only to avoid capturing
  unrelated staged developer files (P1 fix).

## [1.29.4] - 2026-04-05

### Fixed

- **Sync sequence correctness**: `wv sync --gh` writes to `.weave/`, so `git push` without an
  intervening `git add .weave/ && git commit` left graph state uncommitted after push — causing the
  stop-hook to re-fire on every subsequent response.
- **`stop-check.sh`**: blocking message now instructs the full 3-step sequence
  (`wv sync --gh && git add .weave/ && git commit → git push`) when `.weave/` is dirty; AHEAD-only
  case simplified to `git push`.
- **`Makefile.template` `wv-push` target**: added conditional commit before `git push`.
- **`session_lifecycle.py` `quit_hygiene_state`**: `ahead > 0` early return now checks
  `dirty_weave`; combined state instructs full sequence instead of just `git push`.
- **16 normative docs and templates** corrected: `CLAUDE.md`, `AGENTS.md`, `install.sh`,
  `CONTRIBUTING.md`, `docs/DEVELOPMENT.md`, `docs/WEAVE.md`, `README.md`, `README.public.md`,
  `scripts/cmd/wv-cmd-ops.sh`, `.github/copilot-instructions.md`, and all four repo templates.
- **`stop-check.sh` cooldown lock**: after emitting a hard block, subsequent responses within 120s
  emit a soft stderr warning instead of re-blocking — allows agent to execute sync commands without
  being blocked on every response. Lock is cleared on clean state; checks still run during cooldown.
- **`session-start-context.sh` session-start auto-commit**: `.weave/` writes during session start
  (crash-recovery breadcrumbs, migrations) are committed immediately before the first response,
  preventing the stop-hook from firing spuriously with "unsaved weave state" on state the agent did
  not cause. Scoped to `.weave/` only — does not capture unrelated staged developer files.

## [1.29.3] - 2026-04-04

### Fixed

- **`cmd_load` sync regression**: developer reload (`wv load`) now pre-flushes live DB to
  `state.sql` via `auto_sync --force` before importing, preventing in-session `wv done` closures
  from reappearing as active after reload.
- **`auto_sync --force`**: new flag bypasses the stamp-file throttle, used internally by `wv done`
  and `wv load` to guarantee flush on critical operations.

## [1.29.2] - 2026-04-02

### Fixed

- **`wv sync --gh` Phase 2 (GH→Weave) now passes `--standalone`** when creating nodes from GitHub
  issues. Previously, importing an open GH issue with no Weave parent failed with "Error: --parent
  required when active epics exist" and silently discarded the node. GH-sourced nodes are orphans by
  nature; `--standalone` bypasses the orphan-prevention guard correctly.
- **`scripts/sync-weave-gh.sh`** (legacy bash sync): same fix — `--standalone` added to the `wv add`
  call in Phase 2.

## [1.29.1] - 2026-04-02

### Fixed

- **`wv prune --orphans-only` now skips the age filter** — previously the age clause was always
  applied, so done orphans touched by `wv sync --gh` today were silently excluded. `--orphans-only`
  now targets all unlinked done nodes regardless of age; the orphan filter is its own safety
  constraint.

### Docs

- **Graph Hygiene section** added to `templates/WORKFLOW.md` — `--orphans-only` vs `--age=`
  distinction, classify-before-prune checklist.
- **Orphan nodes pitfall** in `.github/copilot-instructions.md` expanded with classify-first
  workflow and `--orphans-only` guidance.

## [1.29.0] - 2026-04-02

### Added

- **`wv done --no-overlap-check`** — skip FTS5 learning-similarity check entirely for agentic
  callers. Replaces the `echo "s" | wv done` workaround. No prompt, no advisory.
- **`wv add --standalone`** — semantic alias for `--force`; makes deliberate orphan intent explicit
  for chore/doc nodes created outside an epic.
- **`weave_add` MCP: `standalone` parameter** — pass `--standalone` to CLI from MCP clients.
- **`weave_done` MCP: `no_overlap_check` parameter** — pass `--no-overlap-check` to CLI from MCP
  clients.
- **`done_criteria` hint suppression** — `wv work` omits the done-criteria advisory when node text
  already contains an actionable verb (add, implement, fix, test, etc.).
- **Implicit verification keyword suppression** — `wv done` suppresses the "no verification
  evidence" hint when `--learning` contains test/passed/verified/lint/make check/pytest/ruff/mypy.
- **Stale ops auto-clear** — `wv work` silently clears incomplete journal ops older than 30 minutes
  (left by failed syncs in prior sessions), preventing spurious recovery prompts.
- **Metadata size guard** — `wv done` warns if node metadata exceeds 50 KB; bloated metadata was
  root cause of `sqlite3 -json` hang during `wv sync`.
- **Templates updated** — `templates/WORKFLOW.md`, `templates/copilot-instructions.stub.md`, and
  `.github/copilot-instructions.md` now document the new flags and drop the `echo "s" | wv done`
  workaround.

## [1.28.7] - 2026-03-31

### Added

- **Static system prompt** — graph context (Weave node, blockers, learnings) moved from per-turn
  system prompt rebuild to a one-time turn-0 bootstrap message. Eliminates 4-6 `wv` subprocess calls
  per turn; system prompt is now stable across all turns enabling prompt caching.
- **Anthropic prompt caching** — system block now passed as a content object with
  `cache_control: {type: ephemeral}` for automatic cache hits on repeated calls. Estimated 7x
  reduction in billed system+tools tokens per multi-turn session.

### Fixed

- **Stale active nodes across TUI sessions** — three-layer defense: (1) `wv-close` auto-commits
  `.weave/` so state persists before hot zone is cleared, (2) `wv-bootstrap` guards against
  `git pull` clobbering uncommitted `state.sql`, (3) TUI startup auto-resets inherited active nodes
  to `todo` status with a user-visible message.
- **Compliance scores not committed** — `_run_compliance()` now runs before `make wv-close` so the
  `.weave/compliance-scores.tsv` row is written to disk before the session-end git commit step.

## [1.28.6] - 2026-03-31

### Added

- **WORKFLOW.md — Repair Workflow step 5**: Error classification tiers (transient/retry,
  blocker/recovery-node, user-required/stop) to prevent blind retry loops and ambiguity being
  papered over.
- **WORKFLOW.md — Rule 12**: Verify assumptions before acting — grep/read to confirm file paths,
  function names, and APIs before relying on them; treat compacted session context as unverified
  until re-read.
- **runtime/context.py — Rule 9**: Tool batching mandate — independent reads, searches, and graph
  queries must be issued in a single parallel response; never serialise parallel calls.
- **runtime/context.py — Rule 10**: Assumption validation, always injected into runtime system
  prompt — mirrors WORKFLOW.md rule 12 for universal coverage.
- Context-load policy renumbered from rule 9 → 11; suffix rules renumbered 10-12 → 12-14.

## [1.28.5] - 2026-03-31

### Fixed

- **Session restart notice** — `install.sh` now prints a restart reminder after every successful MCP
  rebuild. The MCP server process caches the old binary in memory; changes are not live until the
  session is restarted. Also added as step 8 in the dev-guide release sequence.

## [1.28.4] - 2026-03-31

### Documentation

- **No duplicate background commands rule** — `WORKFLOW.md` rule 10 and runtime system prompt rule
  12 now explicitly prohibit re-issuing long-running commands (`make check`, `wv sync --gh`,
  `npm run build`, `git push`) before their background completion notification arrives. Prevents
  double syncs, wasted build time, and conflicting writes.

## [1.28.3] - 2026-03-31

### Fixed

- **Similarity check for decomposition** — `wv add --parent` now skips the FTS5 similarity check.
  Child nodes naturally share vocabulary with their parent; the check was blocking most
  decomposition tasks and requiring `--force` on every node.
- **`weave_tree` MCP default** — returns a readable text tree by default instead of a raw JSON blob.
  Agents can opt into `json=true` or `mermaid=true` when those formats are needed.
- **Graph sidebar "Issues" header** — dimmed the static "Issues" prefix so the active filter tab
  carries the visual weight rather than the label.

## [1.28.2] - 2026-03-31

### Fixed

- **MCP ANSI stripping** — all 31 MCP tools were returning raw ANSI color codes (e.g. `\x1b[0;32m`)
  to agent consumers. Fixed in the `wv()` helper so the strip applies once for all tools.
- **`weave_add` force param** — passing `force: true` via MCP was silently ignored; the `--force`
  flag was never forwarded to the CLI. Now wired through correctly.
- **`weave_link` param names** — schema used `from`/`to` but agents consistently inferred
  `from_id`/`to_id` from the "Source node ID" description, causing schema validation errors. Renamed
  to `from_id`/`to_id` throughout schema and handler.
- **`weave_add` --gh warning noise** — the "No --gh flag" enforcement warning fired on every child
  node created with `--parent`. Suppressed for child nodes; only orphan epics need a GitHub issue.

## [1.28.1] - 2026-03-31

### Fixed

- **Workflow sequence** — `WORKFLOW.md` Core Workflow now shows the correct 8-step sequence:
  pre-flight (`git status && wv status`), commit work files before `wv done`, `wv sync --gh`, commit
  `.weave/` state if dirty, then push. Previously showed `wv sync` (no `--gh`) with no pre-flight or
  `.weave/` commit step. Runtime agent fallback updated to match.

## [1.28.0] - 2026-03-31

### Added

- **`wv_list` MCP tool** — new MCP tool enumerates nodes by status, enabling agents to query the
  graph without a shell. Adds `status` filter parameter; returns `[]` on empty result.

### Fixed

- **FTS5 auto-repair** — `wv search` now detects and repairs a corrupted FTS5 index automatically
  before returning results. Added `wv_search` synonym guidance for MCP callers.
- **E2 gate tightening** — pre-action hook now blocks stale active nodes that were not claimed in
  the current session, preventing ghost-active nodes from bypassing the no-edit guard.
- **Dynamic context-load-policy** — system prompt now injects the current context load policy
  (HIGH/MEDIUM/LOW) at runtime rather than a static default; adds small-file exemption so files
  under 200 lines are always readable regardless of policy level.
- **Review-epic-fidelity skill** — widened trigger pattern and made step 0 unconditional so the
  skill fires reliably on all epic review requests.

### CI

- **Bandit static analysis** — `make check` now runs `bandit` (Python security linter) as part of
  the full quality gate.

## [1.27.0] - 2026-03-27

### Added

- **Session continuity** — `session-start-context.sh` harvests the last user prompt from the Claude
  JSONL transcript on session start, injecting it as context so agents can recover their intent
  after a crash or restart. `wv show` displays `current_intent` when present in node metadata.
  Graph-first discipline rule added to CLAUDE.md: intent not in the graph does not survive a crash.

### Fixed

- **`wv done` learning-overlap non-interactive fix** — v1.26.5 fixed the `needs_human_verification`
  trigger path; this release fixes a second path: FTS5 similarity detecting a duplicate learning.
  Both paths previously blocked on `read` (stdin), hanging agentic callers indefinitely. Now stores
  `learning_overlap_noted` in metadata and exits cleanly. Resume with
  `wv done <id> --acknowledge-overlap`. `pending_close` state is now visible in `wv show`,
  `wv status`, and `wv list`.
- **`pre-close-verification.sh` hook schema** — the hook was emitting `"DENY"` (uppercase) in the
  `permissionDecision` field, which Claude silently ignores (case-sensitive: must be `"deny"`). Also
  corrected the exit code (was exit 2 hard-block; soft-deny requires exit 0 + JSON body). Distinct
  from the v1.26.5 fix to the same file, which addressed payload parsing (false-positive blocks on
  `wv work`).
- **GH sync assignee hardening** — `claimed_by` is a local hostname, not a GitHub login. The sync
  now validates assignees via `gh api repos/{repo}/assignees/{login}` before use, caches invalid
  logins per-session, and never includes `--assignee` in `gh issue create` (best-effort post-create
  only). Prevents repeated failed API calls on every sync cycle.

### Tests

- **JSONL bridge tests** — `tests/test-hooks.sh` gains 4 tests covering the session-continuity JSONL
  bridge: context injection on session start, graceful handling of missing/malformed JSONL, and
  current_intent round-trip via `wv show --json`.

## [1.26.5] - 2026-03-25

### Fixed

- **`wv done` pending-close for non-interactive flows** — learning overlap that requires human
  acknowledgement now persists `needs_human_verification` + `pending_close` metadata instead of
  blocking on stdin. Agents resume with `wv done <id> --acknowledge-overlap` rather than hanging.
- **GH issue blocker rendering** — synced GitHub issues now show only unresolved blockers in the
  "Blocked by" section; previously all blockers (including resolved deps) were listed.
- **Hook payload parsing** — `pre-claim-skills.sh` and `pre-close-verification.sh` now parse real
  Bash hook payloads (`tool_input.cmd`/`.command`), fixing false-positive blocks on `wv work`.
- **Session-end workflow alignment** — `session-end-sync.sh` updated to match documented protocol
  (automation exceptions, CI bypass policy).
- **Skills and agents drift** — `close-session`, `fix-issue`, `plan-agent`, `ship-it`, `weave`, and
  `wv-decompose-work` updated for current claim flow and epic hierarchy rules; `weave-guide` and
  `epic-planner` agents updated with repair workflow and decomposition guardrails.

### Documentation

- **`WORKFLOW.md` Repair Workflow section** — canonical guidance for turning detected workflow
  issues into tracked graph nodes during execution: detect → create node → breadcrumbs →
  pending-close for non-interactive resumption.

## [1.26.4] - 2026-03-23

### Fixed

- **Unblock cascade bypass** — six code paths could set a node to `done` without triggering the
  unblock cascade for blocked dependents: `cmd_done` (inline SQL), `cmd_add --status=done`,
  `cmd_update --status=done`, `cmd_quick`, `wv plan` (bulk import), and `wv prune` (no orphan
  filter). Extracted shared `_do_unblock_cascade()` function and wired it into all paths.
- **`wv prune --orphans-only`** — new flag restricts pruning to done nodes with no edges, preventing
  collateral deletion of done nodes that are part of the graph topology.
- **`wv add --parent` enforcement** — blocks orphan node creation when active epics exist unless
  `--parent` or `--force` is specified, preventing the orphan accumulation pattern.
- **`session-end-sync.sh` git push hang** — push retry loop (5 attempts, exponential backoff) now
  skipped when no git remote is configured, fixing ~30s hang in test repos.

## [1.26.3] - 2026-03-23

### Fixed

- **`sync --gh` Phase 3 silent failure** — `sync_closed_to_weave()` called `wv done` without
  `--skip-verification`, causing every GH→Weave close to silently fail (exit 1 swallowed by
  `check=False`). Nodes kept resurrecting as active on every sync. Now passes `--skip-verification`
  and `--learning` flags (#1483).
- **Test lint cleanup** — fixed 10 mypy `func-returns-value` errors, 2 pylint
  `use-implicit-booleaness-not-comparison` warnings, and 3 pylint `import-outside-toplevel` warnings
  in `test_weave_gh_phases.py`.

## [1.26.2] - 2026-03-23

### Fixed

- **`wv add` epic hint** — when active epics exist, displays their IDs after node creation to remind
  agents to use `--parent=<id>` and avoid orphan nodes.
- **`wv done` epic closure guard** — warns when closing an epic with no `implements` edges (no
  children linked via `--parent`), preventing silent flat-graph failures.
- **`wv load` status regression guard** — detects when `state.sql` has fewer `done` nodes than the
  current DB (un-synced closures), warns before overwriting, and backs up the live DB.
- **`pre-action.sh` bootstrapping catch-22** — `wv add`, `wv work`, `wv ready`, `wv status`,
  `wv list`, `wv show`, `wv sync`, `wv load`, and `wv doctor` are now whitelisted so the hook cannot
  block graph setup commands when 0 active nodes exist.
- **`stop-check.sh` idle node warning** — warns on active nodes with no update in >30 min (possible
  abandoned/crashed work) before the uncommitted-changes check.
- **`weave-audit` epic hierarchy check** — audit report now detects epics with no tracked children
  and deducts 15 points per childless epic from the health score.
- **`wv-decompose-work` skill** — all `wv add` examples now include mandatory `--parent=<id>` to
  prevent agents from creating flat graphs.
- **`WORKFLOW.md` Epic Decomposition section** — canonical reference updated with hierarchy rules,
  `--parent=` requirement, blocking setup, and cross-reference in Rule 1.

## [1.26.1] - 2026-03-23

### Fixed

- **`wv tree`** — `--root` now correctly anchors CTE in text and JSON modes (regression from
  v1.24.0). Root cause: `$([ cond ] && echo ...)` inside assignment returns exit 1 under `set -e`,
  silently killing `cmd_tree`. Fixed with `if/fi` guard.
- **`wv ready --subtree`** — CTE uses `UNION` instead of `UNION ALL` to prevent duplicate node IDs
  from diamond dependencies.
- **`wv sync --gh`** — blocked nodes are now included when creating GitHub issues. Previously the
  status filter excluded `'blocked'`, leaving epics and features with unresolved deps without GH
  issues.

## [1.26.0] - 2026-03-21

### Added

- **`wv work` atomic CAS claim** — race-free node claiming for multi-agent concurrency;
  `WV_AGENT_ID` stamps ownership; `--force` overrides a stale claim.
- **`wv ready --subtree=<epic>`** — topological partitioning (Algorithm C) scopes the ready queue to
  an epic's dependency tree.
- **`wv ready` claimed-by filter** — nodes claimed by other agents are hidden by default; `--all`
  shows them; `claimed_by` displayed in output.

### Fixed

- **Hook enforcement scope** — pre-action hook now only fires inside projects explicitly initialised
  with `wv-init-repo` (`.weave/` present). Editing personal notes, plain git repos, or `/tmp` no
  longer triggers the no-active-node block.
- **`journal_end` guaranteed** — interrupted `wv sync` no longer leaves the journal open, preventing
  DB lock contention on the next run.
- **`ORDER BY` determinism** — all multi-row queries now include an `id` tiebreaker; previously
  non-deterministic ordering caused flaky tests.
- **`metadata=null` after `json_remove`** — `wv list --json` / `wv show --json` no longer return
  `null` metadata for nodes with empty `{}`; fixes downstream `jq fromjson` failures.
- **Agent infrastructure** — hooks, `SKILL.md`, and agent definition files hardened for multi-agent
  operation (#1308).
- **Selftest isolation + prune-delta resurrection** (#1306, #1307).
- **Context pack ancestry** — `wv context` now walks `implements` edges (not only `blocks`) when
  collecting pitfalls from ancestor nodes; parses structured `decision/pattern/pitfall` learnings.
- **MCP server count** — `install.sh` now generates a 2-server config (drops `weave-graph` and
  `weave-session` scoped servers removed in v1.25.0).

## [1.25.0] - 2026-03-18

### Added

- **MCP instrumentation** — `--instrument` flag logs `tools/list` payload bytes, per-tool call
  counts, and exit summary to stderr. All output prefixed `[weave-mcp-instrument]`.
- **`--scope=lite` MCP profile** — 6 essential tools (overview, guide, edit_guard, status, work,
  done) at 2,147 bytes — 85% smaller than the full 14,509-byte `all` scope.

### Changed

- **MCP server consolidation** — Reduced from 4 servers to 2 (`weave` + `weave-inspect`). Removed
  `weave-graph` and `weave-session` scoped servers (zero token savings, only process overhead).
- **Agent definitions updated** — All 3 agents (epic-planner, learning-curator, weave-guide) now
  reference the consolidated `weave` server instead of scoped servers.
- **copilot-instructions.md** — Documents that Claude Code uses hooks+CLI, not MCP. MCP section
  updated for 2-server architecture.
- **SKILL.md trimmed** — `/weave` skill reduced from 25KB to 7KB (73%). Delegation design extracted
  to `docs/DESIGN-weave-delegation.md`.
- **Skill audit** — Removed 9 duplicate deprecation notices from 7 skills (AI paste bug from commit
  94ec383). Fixed `dev-guide` multiline YAML frontmatter.

### Fixed

- **Hook fast-paths** — `pre-action.sh`, `context-guard.sh`, and `post-edit-lint.sh` exit early for
  non-edit tools. PostToolUse hooks skip non-Write/Edit invocations in <1ms.
- **Context pack caching** — Stamp-file cache with automatic invalidation on edge changes
  (`wv link`, `wv block`, `wv resolve`). Second `wv context` call returns instantly.
- **`context-guard.sh` optimization** — Uses `git ls-files` instead of `find`, caches policy in
  `$WV_HOT_ZONE/context_policy`.

## [1.24.0] - 2026-03-17

### Added

- **RAM/system health metrics** — `wv health` now reports available RAM, tmpfs usage, and hot zone
  DB size. Score penalized at <1GB available (-5) and <500MB critical (-15). Visible in `--verbose`
  text and `--json` output under `system` object.
- **WORKFLOW.md "Session End Behavior" section** — Documents the two-level stop hook for both Claude
  Code and VS Code agents.

### Changed

- **Stop hook redesign** — Uncommitted changes now produce a soft warning (stderr, `exit 0`) instead
  of blocking. Only unpushed commits hard-block (`exit 1`). Prevents forced `/close-session` when
  the user is still working. 50/50 hook tests passing.

### Fixed

- **GH title truncation** — GitHub issue titles now truncated correctly.
- **Stop hook `.weave/` exclusion** — Broadened to exclude all `.weave/` files, not just deltas.
- **`wv-init-repo` .gitattributes** — Uses marker block with full template; strips orphaned comments
  from partial upgrades.

## [1.23.0] - 2026-03-16

### Added

- **Pure-bash delta tracking (`wv-delta.sh`)** — Replaces the `warp-session` Rust binary for all
  delta tracking operations. Five functions (`wv_delta_init`, `wv_delta_has_changes`,
  `wv_delta_reset`, `wv_delta_changeset`, `wv_delta_apply`) using `sqlite3` `json_extract()` and
  `quote()`. Same `_warp_changes` trigger schema, zero binary dependency. All public Weave users now
  get O(1) change detection, delta files, and multi-agent merge capability out of the box.
- **Self-healing delta init** — `wv_delta_has_changes()` auto-initializes triggers if
  `_warp_changes` table is missing, with shell variable cache to skip the probe after first init.
- **Delta subdirectories** — Deltas written to `deltas/YYYY-MM-DD/` subdirectories instead of flat
  `deltas/` to prevent single-directory bloat at scale.
- **GitHub diff suppression** — `.gitattributes` `-diff linguist-generated` on `.weave/` files
  prevents GitHub web UI and VS Code from stalling on large state.sql diffs.

### Removed

- **`warp-session` binary dependency** — All `command -v warp-session` guards removed from
  `scripts/`. The Rust binary remains in the warp repo as a research artifact. Zero `warp-session`
  references in production code paths.

### Fixed

- **NULL weight edge data loss** — `json_extract` returning NULL for edge weight caused string
  concatenation to produce NULL, silently dropping the entire changeset row. Fixed with `COALESCE`.
- **Edge DELETE defensive guard** — Unparseable edge `row_id` (missing colons) now emits a SQL
  warning comment instead of producing garbage SQL.

## [1.22.2] - 2026-03-14

### Fixed

- **No-op sync detection without warp-session** — `auto_sync()` now compares dump output against
  existing `state.sql` via `cmp -s` before proceeding. When state is unchanged, skips jsonl
  generation and `auto_checkpoint` entirely. Gives public Weave users (no `warp-session` binary)
  elimination of noise commits from unchanged state.
- **Safe amend guards** — `cmd_sync` final commit and `session-end-sync.sh` now check if HEAD has
  been pushed before amending. If `HEAD == origin/<branch>`, creates a new commit instead of
  amending, preventing non-fast-forward divergence after `git push`.
- **PreCompact respects `WV_CHECKPOINT_INTERVAL`** — Replaced hardcoded 600s throttle with
  `${WV_CHECKPOINT_INTERVAL:-600}`, consistent with `auto_checkpoint()` and `cmd_sync`.

## [1.22.1] - 2026-03-14

### Fixed

- **Checkpoint rate-limiting fully unified** — `auto_checkpoint()` now falls back to
  `git log --grep` when stamp file is missing (first call in session / after reboot), preventing the
  first checkpoint from always firing. `cmd_sync` final commit now checks throttle window and amends
  instead of creating a new commit. All hooks (SessionEnd, PreCompact) now update the stamp file
  after committing, so `auto_checkpoint()` sees them.
- **`wv-init-repo --force` preserves user Makefile targets** — Previously overwrote the entire
  Makefile; now only replaces the `BEGIN WEAVE TARGETS` block and preserves user-added targets.

### Added

- **warp-session integration** — `auto_sync()` uses `warp-session has-changes` for O(1) change
  detection (skips dump entirely if nothing changed) and `warp-session reset` after persist.
  `cmd_load()` calls `warp-session init` after migrations. All calls gracefully fall back if
  `warp-session` is not on PATH.
- **Delta persistence** — `auto_sync()` writes SQL changesets to `.weave/deltas/<epoch>.sql` before
  the full dump. Delta files are gitignored (operational, not audit).

## [1.22.0] - 2026-03-13

### Fixed

- **`wv prune` closes linked GitHub issues** — Before deleting nodes, extracts `gh_issue` from
  metadata and calls `gh issue close`. Previously left orphaned open GH issues when pruning
  GH-linked nodes.
- **Checkpoint commit noise** — Initial rate-limiting across commit paths. Bumped
  `WV_CHECKPOINT_INTERVAL` default from 0→600s. SessionEnd hook amends recent checkpoint within
  session (2h window). Added `sync state` to hook grep patterns.

## [1.21.0] - 2026-03-12

### Changed

- **Bash decomposition Sprint 2** — Extracted helpers from 6 high-CC functions across 4 command
  modules using `_prefix` globals pattern. CC reductions: `cmd_add` 42→22, `cmd_selftest` 42→9,
  `cmd_doctor` 37→28, `cmd_context` 41→28, `cmd_learnings` 46→25, `cmd_sync` 40→26.
- **Proposal: warp-session** — Added `docs/PROPOSAL-warp-session.md` for SQLite change-tracking
  triggers as Warp Phase 0.5 building block.

## [1.20.1] - 2026-03-10

### Fixed

- **`wv ready` / `wv list` text output noise** — Multiline JSON metadata was spilling into
  pipe-delimited text output, printing raw JSON fields as colored garbage lines. Text mode now
  excludes metadata column; JSON mode still returns full metadata.
- **`wv context` auto-inherit from primary node** — Falls back to `$WV_HOT_ZONE/primary` (set by
  `wv work`) when no ID or `WV_ACTIVE` is provided. Eliminates brittle env-var propagation
  requirement for agents and subprocesses.

## [1.20.0] - 2026-03-10

### Added

- **Primary active node binding** — `wv work` sets a primary node tracked in `$WV_HOT_ZONE/primary`.
  `wv status` shows "Primary:" label, pre-commit trailers use primary node, and `wv done`
  auto-clears. Multiple active nodes are still allowed but the primary provides unambiguous commit
  attribution.
- **Done-criteria enforcement** — `wv done` and `wv ship` now require `--learning="..."` or
  `--skip-verification`. Bypass with `WV_REQUIRE_LEARNING=0` for tests. Strengthens closure quality.
- **`wv health --strict` flag** — Exits non-zero when score < 100, for CI fail-on-warning pipelines.

### Fixed

- **Status vocabulary normalization** — MCP server used `in-progress` while CLI canonical set is
  `active`. Changed all 4 MCP tool enums, added `normalizeStatus()` compat shim for legacy callers,
  fixed dead `in-progress` display branch in import mapper.
- **Health exit code bug** — `wv health` exited non-zero on informational warnings (orphan nodes,
  stale actives) because the last `[ condition ] && echo` line returned 1. Now exits 0 for warnings,
  1 only for true errors (invalid statuses, contradictions).
- **Auto-checkpoint commit noise** — Rate-limited: PreCompact hook skips if <10min since last
  checkpoint, SessionEnd amends recent checkpoint instead of creating new commit.
- **Test suite fixes** — Health tests handle new non-zero exit on contradictions/invalid statuses,
  checkpoint trailer tests updated for primary node semantics. All 585 tests passing.

## [1.19.1] - 2026-03-08

### Fixed

- **Bash CC parser: structural brace matching** — `line.count("{") - line.count("}")` counted braces
  inside strings (`"${var}"`), parameter expansions (`${#arr[@]}`), and jq expressions as
  structural. Fixed by only counting `{` on function-definition lines and `}` on standalone lines.
- **Bash CC parser: one-liner functions** — `func() { ...; }` style definitions had no standalone
  closing `}`, causing function ranges to extend to EOF. Fixed by detecting `}` at end of the
  definition line.
- **Bash CC parser: heredoc content** — `}` inside heredocs (e.g. JSON in `cat << EOF`) was counted
  as structural function boundaries. Fixed by tracking heredoc start/end delimiters and skipping
  content.

## [1.19.0] - 2026-03-07

### Added

- **Edge context** — edges now carry auto-generated alias-based summaries (`auto: true`) or explicit
  semantic context via `--context=` on `wv link`/`wv block` and `--rationale=` on `wv resolve`.
  Auto-context is never overwritten by re-linking (three-condition UPSERT guard).
- **`wv health --fix`** — backfills all empty edge context with auto-generated summaries.
  Idempotent, safe for agent invocation. MCP `weave_health` also supports `fix` parameter.
- **MCP `weave_link` context** — `context` property added to MCP schema so VS Code agents can
  provide explicit edge context.
- **`cmd_block` node existence validation** — `wv block` now validates both node IDs exist before
  creating the edge (pre-existing silent failure fixed).
- **Bash per-function CC** — `wv quality functions` now reports per-function cyclomatic complexity
  for `.sh` files (was 0 for all bash files). Uses `_BRANCH_PATTERN` over each function's line
  range.
- **`wv context` surfaces edge context** — blockers and related nodes in context packs now include
  parsed `context` field (was silently dropped).

### Changed

- **Documentation** — edge context guidance added to WORKFLOW.md, AGENTS.md, CLAUDE.md, and
  DEVELOPMENT.md. Covers both CLI and MCP agent surfaces equally.

## [1.18.0] - 2026-03-06

### Changed

- **Documentation separation** — all agent instruction files (CLAUDE.md, AGENTS.md,
  copilot-instructions.md) are now minimal stubs pointing to `~/.config/weave/WORKFLOW.md` as the
  canonical reference. No workflow commands to drift in per-repo files.
- **WORKFLOW.md expanded** (60→114 lines) — canonical reference now covers all commands, rules,
  context packs, skills, and agents.
- **CLAUDE.md.template** uses `WEAVE-BLOCK-START/END` markers — `wv init-repo --update` can prepend
  or refresh the Weave block in existing CLAUDE.md files without overwriting project content.
- **AGENTS.md.template** — new generic stub (23 lines) replaces shipping memory-system's 205-line
  development reference to the public repo.
- **build-release.sh** — CLAUDE.md, AGENTS.md, and .github/copilot-instructions.md all generated
  from templates at build time (no longer ships memory-system-specific copies).

## [1.17.0] - 2026-03-06

### Added

- **VS Code hook enforcement** — hook scripts now handle both Claude Code tool names
  (`Edit`/`Write`/`Bash`) and VS Code tool names (`create_file`/`replace_string_in_file`/
  `run_in_terminal`). The `SHOULD_CHECK` filter in `pre-action.sh` and `tool_input` property
  extraction (`.file_path // .filePath`) cover both ecosystems. VS Code ignores matchers (all hooks
  fire on every tool), so this script-level fix closes the enforcement gap for `@copilot`.

- **Minimal copilot-instructions stub** — `wv init-repo --agent=copilot` now generates a 10-line
  stub referencing `weave_guide` (MCP) and `WORKFLOW.md`, replacing the 239-line workflow dump that
  drifted as Weave evolved. Template lives at `templates/copilot-instructions.stub.md`.

- **`.github/hooks/` scaffold** — `wv init-repo --agent=copilot` creates the VS Code-native hook
  directory (per `chat.hookFilesLocations` setting) for team-shared hook configurations.

- **`wv quick` now commits before closing** — creates node as `active`, stages tracked changes,
  commits, then closes to `done`. Previously inserted directly as `done`, which blocked the
  pre-commit hook.

- **9 new hook tests** — VS Code tool names (`create_file`, `replace_string_in_file`), camelCase
  `filePath` property extraction, installed-path guard for both naming conventions.

### Fixed

- **Ghost setting removal** — `wv init-repo --agent=copilot` no longer writes
  `chat.hooks.enabled: true` to `.vscode/settings.json` (confirmed unregistered by any extension).
  `--update` mode strips it from existing repos.

- **Hook matchers extended** — `PreToolUse` and `PostToolUse` matchers in `~/.claude/settings.json`
  now include VS Code tool names for Claude Code CLI correctness.

### Changed

- **Documentation: two-stable + one-preview agent model** — `AGENTS.md`, `DEVELOPMENT.md`,
  `.github/copilot-instructions.md`, and `PROPOSAL-wv-hook-determinism.md` updated to reflect the
  corrected enforcement model: `claude` CLI (stable), `@copilot` (stable, matchers ignored),
  `@claude` (preview). Requires `./install.sh` re-run for hook script + matcher updates.

## [1.16.1] - 2026-03-05

### Fixed

- **Journal incompleteness in `wv ship`** — `cmd_sync` returned exit code 1 when called from
  `cmd_ship` due to `[ "$_sync_journaled" = true ] && cmd` pattern at end of function. Under
  `set -euo pipefail`, the false test killed the caller before `journal_complete` could run. Every
  `wv ship` left an incomplete journal entry, triggering recovery noise on next invocation. Fixed by
  replacing `[ test ] && cmd` with `if/then/fi` at function boundaries.

## [1.16.0] - 2026-03-05

### Added

- **Crash sentinel detection** — session-start hook writes a sentinel file to `$WV_HOT_ZONE`; if
  present at next start, the previous session crashed. Auto-generates recovery breadcrumb with crash
  timestamp and active node list. Two-phase sentinel write catches crashes during DB load.

- **`wv recover --session`** — lists orphaned active nodes from crashed sessions. `--auto` re-claims
  all, `--json` returns `{status, orphaned_nodes, count}`.

- **Reboot recovery (secondary detection)** — when sentinel is lost (tmpfs cleared on reboot) but
  active nodes exist, session-start emits a soft warning suggesting `wv recover --session`.

- **`tests/test-crash-sentinel.sh`** — 38 tests covering sentinel lifecycle, crash detection,
  auto-breadcrumb, `wv recover --session`, reboot recovery, and 5-criterion crash benchmark
  simulation. Total test count: 568.

### Fixed

- **Context pack failure exit code** — changed from exit 2 (hard block) to exit 1 (soft warning) per
  hook determinism spec. Prevents false blocks from transient DB contention.

- **Secondary reboot detection** — used `[ ! -f "$SENTINEL" ]` after current session's sentinel was
  already written (always false). Fixed with `HAD_SENTINEL` flag set before write.

---

## [1.15.0] - 2026-03-05

### Added

- **Alt-A global hooks** — all 9 hooks registered globally in `~/.claude/settings.json` via
  `install.sh`. Per-project `settings.json` has no `hooks` key (shallow spread kills coexistence).

- **`wv init-repo` delegation** — `wv init-repo` subcommand delegates to standalone `wv-init-repo`
  binary instead of reimplementing in the main `wv` script.

- **`--agent=copilot|all` support** — `wv-init-repo` scaffolds VS Code Copilot configuration
  (`.vscode/mcp.json`, `.github/copilot-instructions.md`, `.vscode/settings.json` with
  `chat.hooks.enabled`).

### Fixed

- **Installed-path edit guard** — `pre-action.sh` blocks edits to `~/.local/bin/` and
  `~/.local/lib/weave/` with clear error directing to source files in `scripts/`.

---

## [1.14.0] - 2026-03-03

### Fixed

- **`quality.conf` config format** — `[exclude]` parser and `[classify]` parser both now strip
  inline `#` comments. The README incorrectly showed INI-style `patterns = \n    val` multi-line
  syntax; corrected to one-glob-per-line.

- **File classification heuristics table** — README listed `migrations/`, `vendor/`,
  `node_modules/`, `.min.js` as generated patterns; none exist in `classification.py`. Table now
  matches the code exactly (4 errors across 3 rows corrected).

- **`ScanMeta` docstring** — said "Two scans retained" but `db.py` uses `_MAX_SCANS=5` for trend
  data and `_FILES_SCANS=2` for raw file data. Docstring and `db.py` header updated.

- **`fn_cc` EAV key collisions** — `FunctionCC.to_eav_row()` keyed on `fn_cc:<name>`, colliding on
  `(path, scan_id, metric)` when two methods share a name in different classes within one file. Key
  is now `fn_cc:<name>@<line_start>`. Python identifiers cannot contain `@` so the split is
  unambiguous.

- **Gini penalty dead-letter at N=3** — the concentration penalty threshold 0.7 is mathematically
  unreachable for exactly 3 functions (max Gini = 0.667). Minimum raised to `N >= 4`, where max Gini
  = 0.75.

- **`make check` on Python-3-only systems** — `PYTHON ?= python` failed on Debian/Ubuntu after
  Python 2 EOL (no `python` symlink). Changed to `poetry run python`. `PYLINT` aligned to
  `$(PYTHON) -m pylint` for consistency.

### Added

- **`scanner_version` in `scan_meta`** — each scan now records the Weave version that produced it
  (`_migrate_v4`). If a scan detects the previous scan used a different version, it automatically
  forces a full re-scan so no stale metrics are carried forward. No manual `wv quality reset` needed
  after upgrading.

### Documentation

- **Known Limitations** — two new entries: hotspot threshold instability (absolute cutoff on min-max
  normalised scores) and `wv quality diff` git-stats caveat (previous score retroactively
  recalculated with current churn data).

- **Proposal docs superseded** — `PROPOSAL-wv-quality-depth.md`, `PROPOSAL-wv-quality-perf.md`, and
  `PROPOSAL-wv-mccabe-review.md` each carry a `SUPERSEDED` banner pointing to
  `scripts/weave_quality/README.md` as the single source of truth.

---

## [1.13.1] - 2026-03-03

### Fixed

- **`poetry install` now works out of the box** — `pyproject.toml` was missing
  `[tool.poetry] package-mode = false`. Poetry tried to install `weave-workflow` as a Python
  package, but no matching source directory exists (the CLI is a bash/Python hybrid, not a
  distributable package). Root cause: the Feb 2026 repo rename from `memory-system` →
  `weave-workflow` created a name/directory mismatch. `poetry install` in `CONTRIBUTING.md` now
  works without manual workarounds.

- **Dist releases now include the `package-mode = false` fix** — `build-release.sh` was stripping
  all `[tool.*]` sections from the distributed `pyproject.toml`, including `[tool.poetry]`. Changed
  to an explicit allowlist (strips only `ruff`, `mypy`, `pylint`, `pyright`, `pytest` sections). All
  prior dist releases (v1.2.0–v1.13.0) shipped a broken `pyproject.toml` for users following
  `CONTRIBUTING.md`.

---

## [1.13.0] - 2026-03-02

### Breaking Changes

- **Quality score now defaults to `scope=production`** — the score returned by `wv quality scan`,
  `wv quality hotspots`, and `wv quality diff` reflects production files only. Test files, scripts,
  and generated files are excluded. Repos that previously scored 0/100 due to test-file noise will
  see significantly higher scores. Use `--scope=all` to restore the old inclusive behaviour.

- **Score values differ from v1.12.x** — the scoring formula has been redesigned. Numeric scores are
  not comparable across this boundary. See the formula section below.

### Added

- **File classification** — every file is classified into `production`, `test`, `script`, or
  `generated` based on path heuristics (`tests/`, `test_*.py`, `scripts/`, `dist/`, etc.).
  Classification is stored in the DB and shown in `wv quality scan --json` (`category_counts`
  field). Override defaults per-project via `.weave/quality.conf`:

  ```ini
  [classify]
  production = scripts/mylib/   # promote library code living under scripts/
  ```

- **`--scope` flag** on `wv quality hotspots` and `wv quality diff` — accepts `production`
  (default), `all`, `test`, `script`, `generated`.

- **Category counts in scan JSON** — `wv quality scan --json` now includes:

  ```json
  { "category_counts": { "production": 69, "test": 69, "script": 48 } }
  ```

- **Scope field in hotspots/diff JSON** — `"scope": "production"` field confirms which filter was
  active.

### Changed

- **Scoring formula redesigned** (graduated per-function model, no density normalization):
  - **Per-function CC penalty**: 0.5 points per unit above CC=10, capped at 8 per function.
    Dispatch-tagged functions are exempt.
  - **Essential complexity penalty**: 0.5 points per unit above EV=4, capped at 3 per file.
  - **Hotspot penalty**: −5 per file above hotspot threshold (unchanged).
  - **Gini concentration penalty**: −1 per file with ≥3 functions and Gini >0.7.
  - Penalties are applied at face value — no density normalization. Repos with more absolute
    problems score lower regardless of repo size.
  - Score clamped to [0, 100] and returned as `int`.

- **Nested function CC boundary fix** — `_ComplexityVisitor` now uses a `per_function=True` guard
  that stops recursion at nested `FunctionDef` boundaries. Nested functions are reported as separate
  entries; their branches no longer inflate the outer function's CC. The fix mirrors the pattern
  already used by `_EssentialComplexityVisitor`.

### Fixed

- **fn_cc carry-forward gap** — `cmd_scan` now reloads `all_fn_cc` from the DB after the
  carry-forward section, ensuring unchanged files contribute their stored function CC to the quality
  score.

- **git_stats duplicate paths** — path list deduplicated before calling `enrich_all_git_stats` to
  prevent hotspot penalties being applied twice for carried-forward files.

### Calibration results

| Repo                  | v1.12.2 | v1.13.0 | Target |
| --------------------- | ------: | ------: | -----: |
| earth-engine-analysis |   0/100 |  38/100 |  30-50 |
| memory-system         | 100/100 |  79/100 |  50-80 |

Cross-validation against radon/mccabe 0.7.0: 5/8 production library functions exact match, 3/8
within ±2 (BoolOp counting — intentional divergence documented in `docs/CC-METHODOLOGY.md`).

---

## [1.12.2] - 2026-03-01

### Fixed

- **Quality scanner: DIT→direct_bases rename** — `len(cls.bases)` measures the number of direct base
  classes (breadth), not inheritance chain depth. Metric renamed from `dit` to `direct_bases` for
  semantic honesty. Old key retained in VALID_METRICS for backwards DB compatibility. (Issue 5)
- **Quality scanner: ExceptHandler ev depth** — `visit_ExceptHandler` now increments depth in the
  essential complexity visitor, so return statements inside `except` blocks register at a different
  structural depth than returns in the `try` body. Fixes ev(G) under-counting for try/except
  patterns. (Issue 8)

## [1.12.1] - 2026-03-01

### Fixed

- **Quality scanner: match/case CC** — `match` statement arms now contribute +1 CC each (was 0).
  Added `visit_match_case = _enter_branch` with Python 3.10 guard. (Issue 4)
- **Quality scanner: ev data loss** — `essential_complexity` was dropped during FunctionDetail →
  FunctionCC conversion. Added field to `FunctionCC`, fixed `to_eav_row()`, DB reconstruction, and
  `cmd_functions` output. (Issue 6)
- **Quality scanner: ast.parse exceptions** — broadened `except SyntaxError` to also catch
  `ValueError` (null bytes) and `RecursionError` (deeply nested code). (Issue 10)
- **Quality scanner: cmd_functions stderr** — text output now goes to stderr, consistent with
  cmd_scan, cmd_hotspots, and cmd_diff. Keeps stdout clean for `--json`. (Issue 11)

## [1.12.0] - 2026-03-01

### Fixed

- **MCP `wv()` stderr capture** — switched from `execFileSync` to `spawnSync`. Quality tools no
  longer return empty strings. Returns `stdout || stderr` (not concatenated) to preserve JSON
  integrity.
- **MCP quality `--json` flags** — all four quality handlers (scan, hotspots, diff, functions) now
  pass `--json` for structured output instead of human-readable stderr text.
- **Python < 3.10 compatibility** — `ast.Match` references in `python_parser.py` guarded with
  `sys.version_info >= (3, 10)`. No more `AttributeError` on conda Python 3.9.
- **Conda Python detection** — `wv-cmd-quality.sh` now checks `CONDA_PREFIX`/`CONDA_DEFAULT_ENV`
  specifically (was `VIRTUAL_ENV` which also fires inside Poetry venvs). Only falls back to system
  Python when conda's Python is actually < 3.10.
- **install.sh MCP auto-rebuild** — detects existing MCP installation and rebuilds automatically on
  `./install.sh`. No more stale MCP binaries after upstream source changes. Use `--no-mcp` to skip.

## [1.11.0] - 2026-03-01

### Added

- **`weave_edit_guard` MCP tool** — zero-arg pre-edit gate returning `isError: true` when no active
  Weave node exists. Closes the enforcement gap for VS Code Copilot and other MCP clients.
- **Hardened `weave_preflight`** — now parses JSON output and returns `isError: true` for missing
  nodes, contradictions, and unresolved blockers (was pass-through text).
- **VS Code hook enforcement** — cross-environment path resolution (`${CLAUDE_PROJECT_DIR:-.}`) in
  all hook commands. `wv-init-repo` enables `chat.hooks.enabled` in `.vscode/settings.json`.
- **Expanded Makefile targets** — 10 wv targets (was 3): wv-status, wv-overview, wv-ready, wv-gate,
  wv-health, wv-doctor, wv-sync, wv-push, wv-tree, wv-digest. Template updated to match.
- **`wv help` additions** — `ship`, `recover`, and `preflight` commands now listed in help output.

## [1.10.0] - 2026-02-28

### Added

- **Exit code hard blocks** — `pre-action.sh` uses exit 2 for unconditional blocks (no active node,
  contradictions, installed-path edits). No user override possible.
- **Structured hookSpecificOutput JSON** — "Ask" decisions in `pre-action.sh` output JSON with
  `decision`, `reason`, and `permissionDecisionReason` fields for model consumption.
- **DB health pre-flight** — Hooks compute hot zone path via `md5sum` and exit 0 early if DB is
  missing, preventing errors in non-Weave repos.
- **PostToolUse success guard** — `post-edit-lint.sh` checks `tool_response.success` before running
  lint, avoiding spurious errors on failed tool calls.
- **pre-claim-skills.sh hook** — Advisory PreToolUse hook that surfaces available Weave skills
  without blocking execution.
- **pre-close-verification.sh hook** — Soft deny (exit 0 + JSON) on `wv done` without verification
  evidence. Model can bypass with `--skip-verification`.
- **MCP matcher extended** — PreToolUse hook regex now matches `mcp__ide__executeCode` alongside
  Edit, Write, NotebookEdit, and Bash.
- **`wv health` in session start** — `session-start-context.sh` includes health score in context
  injection.
- **`git push` in session end** — `session-end-sync.sh` pushes after sync for data durability.
- **Makefile wv targets** — `wv-status`, `wv-gate`, `wv-sync` targets for CI integration and
  discoverability.

### Changed

- **Hooks promoted to settings.json** — Hook definitions moved from `.claude/settings.local.json`
  (gitignored) to `.claude/settings.json` (checked-in) for project-wide enforcement. _(Superseded by
  v1.15.0: hooks moved to global `~/.claude/settings.json`; per-project settings.json no longer has
  a hooks key.)_
- **wv-init-repo settings split** — `install.sh` now scaffolds both `settings.json` (hooks) and
  `settings.local.json` (permissions), with separate update logic. _(Superseded by v1.15.0:
  per-project settings.json is permissions-only.)_
- **Gitignore negation for settings.json** — `.gitignore` includes `!.claude/settings.json` to
  ensure hook config is tracked while other `.claude/` files remain ignored.

### Fixed

- **Exit code correction** — Changed `pre-action.sh` from exit 1 (non-blocking warning) to exit 2
  (hard block) for enforcement gates. Previously, the model could ignore hook denials.
- **GPG signing in tests** — Test harness disables `commit.gpgsign` to prevent GPG passphrase
  prompts in CI environments.

## [1.9.2] - 2026-02-27

### Fixed

- **GH sync body overwrite** — Re-imported nodes (`source=github`, no children) no longer overwrite
  rich issue bodies with sparse re-rendered content. Tasks, checkboxes, and Mermaid graphs are
  preserved when a node has been re-imported from GitHub without local graph context.

## [1.9.1] - 2026-02-27

### Added

- **CC Gini coefficient** — `wv quality hotspots` now includes per-file Gini (0.0 = uniform
  complexity, 1.0 = one monster function). `wv quality functions --json` returns
  `{functions, histogram, cc_gini}` object (was flat list)
- **CC histogram** — `wv quality functions` text output includes bucket distribution
  `[1-5, 6-10, 11-20, 21+]` and overall Gini for the scanned scope

### Changed

- **`wv quality functions --json` schema** — Returns
  `{functions: [...], histogram: {...}, cc_gini: float}` object instead of a flat list. Consumers
  must update to `data["functions"]`.

## [1.9.0] - 2026-02-26

### Added

- **Operation journal** — Append-only JSONL journal (`wv-journal.sh`) for crash-resilient multi-step
  operations (ship, sync, delete)
- **`wv recover`** — Resume incomplete operations from journal + `ship_pending` metadata fallback
- **Recovery triggers** — Auto-recover on `wv init`/`wv ship`, warn on `wv work` (D2 Option C)
- **`wv doctor` check 14** — Detects incomplete journal operations
- **Auto-sync suppression** — `_WV_IN_JOURNAL` guard prevents nested sync during journaled ops
- **Ship-pending metadata** — Survives reboot via `state.sql` for two-tier recovery
- **14 durability tests** — Crash simulation at each ship/sync/delete step

### Changed

- **Quality scan atomicity** — Entire scan wrapped in single SQLite transaction (was per-step
  commits). Crash mid-scan now rolls back cleanly instead of leaving partial data.

### Fixed

- **`strip_unistr` SQL-escaped quotes** — Regex now handles `''` (SQL-escaped single quotes) inside
  `unistr()` content (e.g. `O''Donovan`). Previous regex `[^']*` broke at the first quote. Also
  removed incorrect re-escaping that doubled `''` to `''''`, corrupting metadata on load. Affected
  repos with non-ASCII or apostrophe-containing learnings in `state.sql`.

## [1.8.1] - 2026-02-25

### Performance

- **Batch co-change analysis** — `compute_co_changes()` replaced ~500 `git diff-tree` subprocess
  spawns with a single `git log --name-only --no-merges` call. 1.65s → 0.09s on 75-file repo (18×).
  `file_co_changes()` now derives results from the shared co-change data instead of spawning its own
  subprocess loop.
- **Batch blob SHA via `git ls-tree`** — `git_blob_sha()` per-file subprocess calls (150 on 75
  files) replaced with a single `git ls-tree -r HEAD` lookup dict. 0.40s → 0 (eliminated).
- **Single-pass AST visitor** — 7 redundant top-level `ast.walk` calls per Python file collapsed
  into `_single_pass_ast()`. `ast.walk` call count dropped from 353K to 97K on 75 files (3.6×). WMC
  deduplicated via parent-class flag on per-function CC results.
- **Inline ownership computation** — `_compute_ownership()` dead first scan removed, author counts
  pre-computed during `_batch_git_stats` pass. Eliminates O(files × log_size) scaling bug.
- **Overall: 6.5s → 2.4s (2.7×)** on memory-system (75 files). earth-engine-analysis (175 files)
  scans in 5.5s. Subprocess calls reduced from ~654 to 5 (131×).

### Fixed

- **`wv load` unistr compat** — `wv load` now pipes `state.sql` through `strip_unistr` before
  feeding to sqlite3. Previously only the write path (`wv sync`) was protected. Machines with
  sqlite3 < 3.44 (e.g. Debian 12: 3.40.1) failed to load state.sql files generated by sqlite3 ≥ 3.44
  which emit `unistr()` calls for non-ASCII characters.
- **`db.py` retention comment** — header comment updated from "Retention: 2 scans" to match actual
  `_MAX_SCANS = 5` (set in v1.8.0).

## [1.8.0] - 2026-02-24

### Added

- **`wv quality functions`** — per-function cyclomatic complexity report for a file or directory.
  Lists every function with its CC, line range, and a `[dispatch]` tag for functions classified as
  pure dispatch (match/case or flat if/elif chains) which are exempt from the CC ≤ 10 threshold.
  `--json` output for MCP consumption.
- **Essential complexity (ev)** — AST-backed unstructured control-flow metric for Python files.
  `ev=1` is fully structured; `ev > 4` identifies structurally tangled code independent of total CC.
  Stored in `files.essential_complexity`, surfaced in `wv quality hotspots` text and JSON.
- **Indentation SD** — standard deviation of indentation levels, computed for both Python
  (AST-derived) and Bash (2-space heuristic). Identifies files with deep-nesting hotspots that CC
  alone misses. Stored in `files.indent_sd`, included in `wv quality hotspots --json`.
- **Ownership fraction + minor contributors** — per-file git authorship metrics.
  `ownership_fraction` = top-author commits / total commits; `minor_contributors` = count of authors
  contributing < 5% of commits. Only flagged as a risk when `total_authors >= 3` (gated to avoid
  noise on solo-developer projects). Stored in `git_stats`, included in
  `wv quality hotspots --json`.
- **Complexity trend direction** — least-squares slope over complexity history classifies each file
  as `deteriorating`, `stable`, or `refactored`. History is retained across up to 5 scans (was 2).
  Relative-slope threshold of 3% per scan distinguishes real trends from noise. Text output shows
  `↑`/`↓`/`~` symbols; JSON includes `trend_direction` field.
- **Enhanced hotspot + diff output** — `wv quality hotspots` text output now shows `ev=N` (Python
  files, when non-zero) and `trend=↑/↓/~`. JSON adds `essential_complexity`, `indent_sd`,
  `ownership_fraction`, `minor_contributors`, `trend_direction`. `wv quality diff` text output now
  shows trend arrows on changed files; JSON adds `trend_direction` to every improved/degraded entry.
- **Dispatch function detection** — functions whose body is a single `match`/`case` statement or a
  flat top-level `if`/`elif`/`else` chain (no nested control flow) are tagged `is_dispatch=True`.
  These are exempt from the CC ≤ 10 threshold in `wv quality functions` output.
- **Schema v2 migration** — idempotent `ALTER TABLE` adds `essential_complexity` and `indent_sd` to
  `files`, `ownership_fraction` and `minor_contributors` to `git_stats`, `detail` TEXT column to
  `file_metrics` (stores line range + dispatch flag as JSON). New `complexity_trend` table (one row
  per file per scan, CASCADE-deletes on scan prune). Safe to run on v1.7.x databases.
- **Makefile** — single entry point for all project linting and testing: `make check` (all),
  `make lint` (ruff), `make typecheck` (mypy), `make pylint`, `make shellcheck`, `make test`
  (pytest), `make fix` (ruff --fix), `make format` (ruff format).
- **shellcheck integration** — `.shellcheckrc` suppresses project-wide false positives (SC2155
  local/assign, SC2034 cross-source variables) with documented rationale. Genuine bugs fixed: SC2064
  trap expansion in `install.sh`, SC2164 cd without error handling, SC2124 array-to-string, SC2294
  eval bypass. `make shellcheck` target added.

### Fixed

- **fn_cc incremental scan bug** — per-function CC entries in `file_metrics` were not carried
  forward for unchanged files on incremental scans. Fixed by propagating EAV rows from the previous
  scan when a file's blob SHA is unchanged.
- **Pylint 10.00/10** — fixed all pylint warnings across `weave_quality/`, `weave_gh/`, and all test
  files. Key fixes: AST visitor method naming (`invalid-name` suppressed at class level to preserve
  Pylance `reportIncompatibleMethodOverride` compatibility), broad `except Exception` narrowed to
  specific types in `git_metrics.py`, all `import`-inside-functions moved to module top-level,
  `elif`-after-`return` chains replaced with `if` chains.

### Changed

- **Scan retention expanded** — `_MAX_SCANS` increased from 2 to 5. The `files` table retains the
  previous 2 scans for diff (unchanged). The `complexity_trend` table retains all 5 for slope
  computation. Old trend rows are cascade-deleted when scan_meta prunes.
- **Test suite expanded** — 239 tests (was 225). 14 new tests cover `compute_trend_direction` edge
  cases (stable/deteriorating/refactored, single-point, zero-mean guard) and
  `get_all_trend_directions` integration.

## [1.7.5] - 2026-02-24

### Fixed

- **Documentation lag**: Updated all documentation to reflect 28 MCP tools (was 23). Added 5 new
  tools (`weave_show`, `weave_delete`, `weave_quality_scan`, `weave_quality_hotspots`,
  `weave_quality_diff`) to MCP tool tables in README.md, README.public.md, mcp/README.md, and
  docs/WEAVE.md. Updated scope counts (graph 7→8, inspect 9→13), architecture diagrams, agent
  pairing table, and test descriptions.
- **v1.7.4 changelog gap**: Added 3 bug fixes that were released in v1.7.4 but missing from the
  changelog (test environment git init, post-edit-lint file guard, ID resolution regex).

## [1.7.4] - 2026-02-24

### Added

- **MCP: `weave_show`** — Single-node detail view tool exposing `wv show <id> --json`. Assigned to
  `inspect` scope.
- **MCP: `weave_delete`** — Destructive node removal with `force=true` guard. Assigned to `graph`
  scope. Supports `dry_run` preview and `no_gh` to skip GitHub issue closure.
- **MCP: `weave_quality_scan`** — Codebase quality metrics scan with 60s timeout for large repos.
  Assigned to `inspect` scope.
- **MCP: `weave_quality_hotspots`** — Ranked hotspot report with configurable limit and threshold.
  Assigned to `inspect` scope.
- **MCP: `weave_quality_diff`** — Delta report vs previous scan. Assigned to `inspect` scope.

MCP server now exposes 28 tools (was 23). All scope assignments updated. 24/24 MCP tests pass.

### Fixed

- **Test environment**: `setup_test_env()` in `test-core.sh` now runs `git init -q` to create a git
  repo in the temp directory. Without this, `wv context --json` hangs because it internally calls
  `git log --all --grep=...` which blocks indefinitely in a non-git directory.
- **Post-edit lint hook**: Added `[ -f "$FILE_PATH" ]` guard in `post-edit-lint.sh` before running
  `ruff` and `prettier`. Previously, the hook would fail when the edited file didn't exist on disk
  (e.g., during dry-run or test scenarios).
- **ID resolution regex**: Changed `_resolve_first_id` regex from `{4}` to `{4,6}` for hex digit
  matching. All Weave IDs use 6 hex characters, but the regex only matched 4, causing every ID to
  fall through to the slower `resolve_id()` path.

## [1.7.3] - 2026-02-23

### Fixed

- **Sync data loss prevention**: All 3 `sqlite3 .dump` sites (auto_sync, cmd_sync, post-GH re-dump)
  now use `.timeout 5000` to wait for write locks instead of returning empty. `cmd_sync` also guards
  against empty dumps before overwriting `state.sql`.
- **Context pitfall scoping (wv-517f)**: Replaced blocks-only ancestry CTE with bidirectional
  neighborhood walk across all edge types (depth-limited to 4 hops). Pitfalls linked via
  `implements`/`addresses` edges are now included in context packs.
- **Health check false penalty (wv-01e7)**: Added `blocked-external` to allowed status set so
  legitimate nodes don't trigger health score deductions.
- **Context ancestors diamond dedup (wv-77cd)**: Changed `cmd_context` ancestors CTE from
  `UNION ALL` to `UNION` to prevent duplicate ancestors in diamond dependency graphs.
- **Test hygiene**: Promoted 13 `assert_xfail` tests to real assertions — 0 known bugs remain in the
  stress test suite.

## [1.7.2] - 2026-02-23

### Fixed

- **`wv learnings` performance**: Replaced per-row jq subprocess loop (N \* 9 calls) with a single
  `jq -r` pipeline for the default path. On a repo with 85 learning nodes, time dropped from ~31s to
  0.14s (223x speedup). The `--show-graph` path reduces to 1 jq call per row (from 9).

## [1.7.1] - 2026-02-23

### Fixed

- **Quality scan performance**: Rewrote `enrich_all_git_stats()` to use a single
  `git log --name-only` pass instead of 3 subprocess calls per file. On a 318-file repo, scan time
  dropped from 38.3s to 2.0s (19x speedup). Falls back to per-file mode on batch failure.
- **`wv --help` missing quality entry**: Added `quality <sub>` to the Commands section.
- **`enrich-topology` indentation**: Was incorrectly nested under `plan` in help text.
- **Quality help sprint labels**: Removed internal "Sprint 4" references from subcommand
  descriptions.
- **`promote --parent` undocumented**: Added `--parent=<id>` as required flag in quality help.

### Added

- **`wv quality scan --exclude=<glob>`**: Repeatable glob-based file exclusion for scans (e.g.,
  `--exclude='venv_ee/*' --exclude='tests/*'`).

## [1.7.0] - 2026-02-23

### Added

- **Code quality as derived cache**: New `weave_quality` Python module providing code complexity
  metrics, git churn analysis, and hotspot detection. Zero external dependencies beyond Python
  stdlib + git CLI. Includes:
  - `models.py`: `FileMetrics`, `ProjectMetrics`, `ScanMeta` dataclasses
  - `git_metrics.py`: Git churn, age, authors, co-change frequency via subprocess
  - `python_parser.py`: AST-backed cyclomatic complexity, nesting depth, coupling (regex fallback)
  - `bash_heuristic.py`: Regex-based metrics for shell scripts
  - `hotspots.py`: Normalized `complexity x churn` hotspot scoring
  - `db.py`: `quality.db` schema, lifecycle, and staleness detection (per-repo, on tmpfs)
- **`wv quality scan [path]`**: Scans a repository for code quality metrics, populates `quality.db`
  with incremental results (file mtime + git blob SHA tracking). Reports summary to stderr.
- **`wv quality reset`**: Clears `quality.db` for a clean rescan.
- **`wv quality hotspots [--top=N]`**: Ranked hotspot report from `quality.db`. Warns when scan is
  stale (HEAD moved since last scan). Supports `--json` for programmatic consumption.
- **`wv quality diff`**: Delta report comparing current scan vs previous scan. Shows
  improved/degraded/new files by complexity delta. Two-scan retention model.
- **`wv quality promote --top=N`**: Creates summary Weave nodes from top findings in `quality.db`,
  linked via `references` edges to the active epic. Nodes include `metadata.code_ref` with
  path/symbol/range. Idempotent (skips already-promoted files).
- **`wv health` quality component**: Reads `quality.db` for latest scan score and hotspot count.
  Missing or stale data shows "no scan data" rather than failing.
- **`wv context` code quality enrichment**: When a work node has touched files (via commit history),
  pulls hotspot scores for those files from `quality.db` into the Context Pack output. Includes
  cyclomatic complexity, churn, and hotspot score per file.
- **Context enrichment dual-source resolution**: `wv context` now resolves files from both
  `git log --grep=<node-id>` (commit messages) AND `metadata.commits[]`/`metadata.commit` (hashes
  stored during onboarding). Previously, onboarded repos got zero code files in context packs.

### Fixed

- **Hot zone path propagation**: `--hot-zone` flag now correctly passed to `_wv_quality_python` in
  both `wv health` and `wv context` code paths. Previously, quality data was looked up in the wrong
  directory on remote machines.
- **Strict type compliance**: All `weave_quality` source and test files pass mypy strict mode,
  pylint, and ruff checks. Pyright configured in `pyproject.toml`.

## [1.6.4] - 2026-02-23

### Added

- **`wv enrich-topology` command**: One-command graph enrichment from a JSON spec. Supports
  `implements`/`blocks` edges, dry-run preview, and `--sync-gh` for issue body updates. Resolves
  nodes by Weave ID or GitHub issue number (`gh_issue`/`gh_pairs`).
- **Consistent Mermaid rendering**: All Mermaid graphs (CLI, GitHub sync, MCP) now share a single
  canonical source via `wv tree --mermaid [--root=<id>]`. GitHub sync uses
  `render_mermaid_from_tree()` with automatic fallback to the in-process renderer.
- **MCP `weave_tree` parameters**: `mermaid` (boolean) and `root` (string) parameters added to the
  MCP `weave_tree` tool, enabling Mermaid output directly from MCP clients.

### Fixed

- **Mermaid label parse errors**: Labels in `wv tree --mermaid` output are now double-quoted inside
  brackets (`["label"]`) and backticks are stripped. Prevents GitHub "Unable to render rich display"
  errors caused by unquoted parentheses/brackets being interpreted as Mermaid shape syntax.

## [1.6.3] - 2026-02-23

### Fixed

- **Mermaid graph rendering for parent issues**: Weave GitHub sync now renders `## Dependency Graph`
  for any node that has child tasks, regardless of `node_type`. This restores graph rendering for
  legacy/task-typed parent nodes that still represent epics in practice.
- **Regression coverage for GH rendering**: Added a renderer test case that verifies task-typed
  parents with children include Mermaid output, preventing future regressions.
- **Two-machine sync safety guidance**: Clarified that `wv sync --gh` round-trips node fields but
  does not round-trip edge topology, and documented the required `git pull` + `wv load` flow before
  cross-machine sync operations.

## [1.6.2] - 2026-02-22

### Fixed

- **SQLite cross-version dump compat**: `wv sync` now strips `unistr()` from `.dump` output via a
  Python post-processor. SQLite ≥ 3.44 emits `unistr('\uXXXX')` for non-ASCII chars; older versions
  (e.g. Debian 12 apt: 3.40.1) cannot parse these calls on `wv load`, causing "state.sql is corrupt"
  errors. Applies to all three `.dump` call sites in `auto_sync()` and `cmd_sync()`. Falls back to
  unmodified dump if python3 is unavailable.
- **Skill frontmatter audit stability**: All `.claude/skills/*/SKILL.md` frontmatter descriptions
  are now single-line with explicit WHAT+WHEN trigger wording to avoid parser/lint false positives
  from wrapped YAML values.
- **`resolve-refs` invocation path**: Updated skill guidance to use
  `~/.local/bin/wv refs $ARGUMENTS` instead of repo-relative `./scripts/resolve-refs.sh`, removing
  working-directory dependency.

## [1.6.0] - 2026-02-20

### Added

- **Agent pre-launch validation**: Before spawning any weave agent (epic-planner, learning-curator,
  weave-guide), the `/weave` skill reads the agent's `.md` file and checks for `Bash` in the `tools`
  frontmatter. Aborts with a clear error and falls back to inline execution if missing. Prevents
  silent ~25k-token burns from agents with no Bash access (Sprint 11 regression).
- **`tools` frontmatter on all weave agents**: `weave-guide`, `epic-planner`, and `learning-curator`
  now declare explicit tool lists (`Bash`, `Read`, `Grep`, `Glob`, etc.) so their access is
  unambiguous in any permission context.
- **Decompose pre-audit (step 1.5)**: `wv-decompose-work` and `/weave` epic-planner invocation now
  run a targeted `git log` + `grep` search before creating task nodes. Surfaces already-implemented
  work so it can be excluded from the breakdown (Sprint 11 T5: `seed_database.py` already existed).
- **Overlap warning with action prompt**: `wv done --learning` overlap detection now shows an
  interactive `[d]edup / [a]cknowledge / [s]kip` prompt when connected to a TTY, instead of a
  passive advisory. Choosing `d` or `s` prevents the learning from being saved; `a` proceeds.
  Non-TTY fallback preserves the original hint line.
- **Epic commit aggregation**: `wv done` now stores related commit SHAs (via `git log --grep`) in
  node metadata as `commits: ["abc1234", ...]`. When a task has a parent epic (via `implements`
  edge), child commits are aggregated onto the epic node incrementally. Enables navigating from epic
  to all implementing commits.
- **CLOSE phase mandatory gate**: `/weave` SKILL.md Phase 4 now has an explicit
  `⛔ Mandatory Pre-Close Gate` checklist that blocks `wv done` until the learning-curator agent has
  been invoked and produced structured learnings. Includes an anti-pattern example from Sprint 11 (6
  nodes with flat `--learning` strings, curator never called).
- **`weave_plan --gh` timeout scaled**: MCP `weave_plan` handler timeout raised from 60 s to 180 s
  when `--gh` is set, accommodating plans with 20+ tasks that require `sleep 1` between each GitHub
  issue creation to avoid secondary rate limits.

### Fixed

- **`wv plan --gh` secondary rate limit**: CLI already had `sleep 1` between GH issue creates (added
  in 067d50a); the MCP path now also has a sufficient timeout to complete large plans without
  `ETIMEDOUT`.
- **ShellCheck SC2015**: `_aggregate_epic_commits` call now uses `if/fi` instead of `&& ... || true`
  to avoid the false-positive where the `|| true` arm runs when the condition is true but the
  command fails.

## [1.5.4] - 2026-02-19

### Added

- **`wv guide --topic=mcp`**: New MCP topic covering server setup, compound tools, full tool
  listing, and CLI vs MCP comparison. Topics now: `workflow`, `github`, `learnings`, `context`,
  `mcp`.
- **`wv plan` zero-tasks diagnostic**: When a sprint section is found but no tasks are parsed, shows
  expected format, common issues, and exits 1 instead of silently creating an empty epic.
- **Learning format suggestion**: `wv done --learning="..."` now prints a tip to stderr when the
  learning text lacks `decision:`, `pattern:`, or `pitfall:` structured markers.

### Fixed

- **Hook hard gates**: `pre-close-verification.sh`, `stop-check.sh`, and `post-edit-lint.sh` now
  exit 1 on violations instead of advisory exit 0. JSON `"decision":"block"` output is now backed by
  actual blocking behavior.
- **`wv done --skip-verification`**: New flag to bypass the verification hard gate for trivial
  tasks.
- **`cmd_load` stderr**: Success messages redirected to stderr to prevent stdout pollution during
  auto-restore (7846fa1).
- **MCP server version**: Now tracks VERSION file (was stuck at 1.5.2).

### Changed

- **WEAVE.md**: Version 1.5.4, added `blocked-external` status, `wv guide` command reference, fixed
  MCP tool count (23) and skills/version references.
- **README.md**: Removed deprecated `sync-weave-gh.sh`, added `weave_guide` to MCP tools table,
  updated hook descriptions and counts.

## [1.5.3] - 2026-02-19

### Added

- **`wv guide`**: New command with 4 topics (`workflow`, `github`, `learnings`, `context`) — quick
  reference for any consumer without needing to open docs. Topics print concise cheat-sheets
  directly in the terminal.
- **`weave_guide` MCP tool**: Exposes `wv guide` to MCP-only consumers (Copilot, Claude Desktop,
  etc.) that cannot run CLI commands. Topic parameter is optional; defaults to full workflow
  reference.

### Fixed

- **`wv ship` ancestry detection**: Recursive CTE now walks the full `implements` edge chain instead
  of checking only the direct parent. GitHub issue now found and closed for epic → feature → task
  hierarchies of any depth.
- **Auto-restore after reboot**: `db_ensure` no longer conflicts with SQLite `.dump` schema output.
  Delegates to `cmd_load` (atomic temp-DB replace), eliminating false "failed to restore" errors.
- **`WeaveNode.priority`**: `int()` conversion now wrapped in `try/except` — non-numeric strings
  like `HIGH`/`MEDIUM`/`LOW` fall back to `2` instead of crashing `wv sync --gh`.

### Changed

- **Metadata key normalized**: `wv show --json` now returns metadata under `"metadata"` (not
  `"json(metadata)"`). Consistent with `wv list --json`. Update any `jq '.[0]."json(metadata)"'`
  calls to `jq '.[0].metadata'`.
- **Session-start hook**: Stale breadcrumbs (>24h old) are surfaced at session start with age and a
  reminder to run `wv breadcrumbs show`. Prevents context loss across sessions.
- **AGENTS.md + copilot-instructions.md**: Updated for `weave_guide`, normalized metadata key docs,
  and `wv guide` in session-start section.

## [1.5.2] - 2026-02-18

### Fixed

- MCP server version string now tracks package.json (was stuck at 1.5.0 in v1.5.1)
- Pre-release checklist in DEVELOPMENT.md now lists `mcp/src/index.ts` as 4th version location

### Changed

- Documented `wv ship` ordering requirement: commit code before ship (ship closes the node, blocking
  subsequent commits). Added to CLAUDE.md, AGENTS.md, copilot-instructions.md.

## [1.5.1] - 2026-02-18

### Added

- **`wv-init-repo --update`**: Updates managed files (hooks, skills, agents,
  copilot-instructions.md) in existing repos without overwriting user-customized files (CLAUDE.md,
  settings.local.json, .vscode/mcp.json). Use `--force` to overwrite everything.
- **All 16 skills shipped**: `wv-init-repo` now installs all 16 skills (was 3). Includes weave,
  weave-audit, sanity-check, ship-it, pre-mortem, plan-agent, zero-in, wv-clarify-spec,
  wv-decompose-work, wv-detect-loop, wv-guard-scope, wv-verify-complete, breadcrumbs, close-session,
  fix-issue, resolve-refs.
- **All 3 agent files shipped**: `wv-init-repo` installs weave-guide.md, epic-planner.md,
  learning-curator.md.
- **`pre-action.sh` hook**: Added to init-repo hook list (was missing).

### Fixed

- **CLAUDE.md Rules alignment**: Rules section in CLAUDE.md and templates/CLAUDE.md.template now
  matches AGENTS.md (10 rules + violation check). Previously missing: no untracked fixes, check
  context, bound session scope, plan mode bypass.
- **`plan-agent` skill missing from install.sh**: Skill directory was created but SKILL.md was never
  copied to config dir.

## [1.5.0] - 2026-02-18

### Added

- **`wv ship --gh`**: Auto-detects GitHub-linked nodes (or parent epics) and runs `wv sync --gh`
  after closing. No more forgotten epic body refreshes.
- **`wv add --parent=<id>`**: Links new nodes to a parent via `implements` edge at creation time.
  Validates parent exists before creating child. Prevents orphaned tasks.
- **Alias warning**: `wv add` emits `⚠ No alias` to stderr when creating non-epic nodes without
  `--alias`. Suppressed when `--force` or `--parent` is set to reduce noise on throwaway or
  already-linked nodes.
- **`blocked-external` status**: New status for external dependencies (third-party APIs, human
  approvals). Supported in validate, list, health, status, and tree commands.
- **Auto-breadcrumbs on `wv done`**: Appends completion timestamp, unblocked nodes, and next ready
  node to `.weave/breadcrumbs.md` automatically.
- **Learnings injection in `wv plan`**: After creating tasks from a plan file, FTS5 searches for
  related learnings/pitfalls and stores matching IDs in task `context_learnings` metadata.
- **`target_version` in `wv tree`**: Epic nodes with `target_version` metadata display a version
  suffix (e.g., `[v1.5.0]`) in tree output.
- **Pre-commit hook relaxation**: Whitespace-only changes bypass the active node requirement. Also
  supports `WV_STYLE_COMMIT=1` env var for formatting commits.
- **MCP server**: `blocked-external` added to all 4 status enums (search, add, list, update).
  `parent` property on `weave_add` tool (schema + handler). `gh` property on `weave_ship` tool
  (schema + handler). Server version bumped to 1.5.0.
- **Agent instruction updates**: All three agent files (CLAUDE.md, AGENTS.md,
  copilot-instructions.md) updated with `wv ship --gh`, `wv add --parent`, `blocked-external`
  status, parallel work patterns, learning quality rules, enrichment discipline, and
  `target_version` convention.
- **⚠ Plan mode bypass warning**: New pitfall documented in all agent instruction files — agents
  must not skip the Weave workflow when given a detailed spec or release plan. Each phase/task in a
  plan requires its own node, claim, and learning capture.

### Fixed

- **`wv init --force` output**: Now says "Initialized Weave" consistently (was "Reinitialized").
- **6-char ID regex**: Fixed `{4}` → `{4,6}` in `pre-close-verification.sh`, `pre-claim-skills.sh`,
  and `test-stress.sh`. Hooks were silently skipping all v1.2+ node IDs.
- **FTS5 dedup false positives in tests**: Added `--force` to health test node creation where
  similar text triggered dedup (e.g., "Fix for first issue" matching "Pitfall: First issue").
- **SQL injection surface in `wv add --parent`**: Parent validation now uses `sql_escape()` instead
  of raw interpolation (was safe due to `validate_id()` but inconsistent with rest of codebase).
- **`invalidate_context_cache` variable leak**: Loop variable `id` in `wv-cache.sh` was not declared
  `local`, clobbering the caller's `$id` when `cmd_link` triggered cache invalidation inside
  `cmd_add --parent`. Renamed to `local node_id`. This caused `wv add --parent` to return the
  parent's ID instead of the child's, breaking `--gh` metadata linkage.
- **`cmd_link` and `wv add --gh` stdout pollution**: Success messages from `cmd_link` ("Linked:")
  and GH issue creation ("GitHub issue #N created") were on stdout, contaminating captured output
  when composed inside other commands. Redirected both to stderr.

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
