# Changelog

<!-- markdownlint-disable MD024 -->

## Unreleased

## [1.67.0] - 2026-07-09

### Added

- **Unknown-taxonomy discovery surfaces** - `wv discover` now reports known-known,
  known-unknown, unknown-known, and candidate unknown-unknown evidence, and context/bootstrap
  surfaces embed bounded blindspot signals for active work.
- **Blindspot-pass workflow procedure** - the workflow templates now include a shared procedure for
  using bootstrap plus discovery output to probe blindspots before promoting findings.

### Changed

- **Discovery report composition hardened** - done-node seeding, source bucket limits, and metadata
  rendering now preserve partial evidence and traversal availability instead of collapsing producer
  issues into empty reports.
- **Crystallization/readiness docs refreshed** - the Rust signature patterns and crystallization
  proposal now reflect the July 2026 release and graph state.

### Fixed

- **`wv discover unknown_knowns` parses combined learning metadata** - discovery now reuses the
  context parser so dominant combined learning strings produce evidence correctly.
- **`wv discover` cache classification** - the read-only `discover` command is classified as cache
  exempt and covered by regression tests.

## [1.66.0] - 2026-07-06

### Added

- **Machine-readable MCP lifecycle/config contract** - `mcp/contract.json` now defines server scopes,
  expected startup policy, tool scope membership, and required configuration environment in one place.
  Workflow surface tests assert the contract so docs, generated configs, and MCP runtime expectations
  stay aligned.
- **Bounded `/goal` scoping command** - the Claude command now focuses on source-classified call
  telemetry, existing safeguards, and narrowly justified follow-up work instead of running a broad
  remediation audit by default.

### Changed

- **MCP startup and status diagnostics hardened** - Copilot MCP configs now set explicit
  `WV_AGENT_ID`, MCP startup can report structured health, and `mcp-status` surfaces startup/process
  diagnostics while preserving normal stdio protocol behavior.
- **MCP lifecycle docs aligned with the contract** - public README and MCP README wording now reflects
  the lifecycle/config contract, including scoped servers and generated client configuration.
- **Public release-note sanitization is shared** - `build-release.sh` now uses one sanitizer for the
  shipped changelog, source tag notes, and public GitHub release notes, so internal Weave node ids and
  dangling `Closes/Fixes/See/Ref wv-*` clauses do not leak into consumer-facing release text.

### Fixed

- **`wv query` rejects joined predicate strings** - single-argument forms like
  `status!=done MATCH "term"` now fail with a quoting hint instead of silently dropping filters or
  searching the whole joined string.

## [1.65.0] - 2026-06-29

### Added

- **Cross-agent install-drift self-heal and advisory** — editing weave source without re-running
  `install.sh` left the installed copy stale and only surfaced at commit time. `wv bootstrap` now
  emits an install-drift advisory at session start (every harness — Claude, Codex, Copilot), and the
  git pre-commit hook self-heals the drift, backed by a single helper in `wv-config.sh` shared by
  the CLI and the hook.

### Changed

- **Quality-scan prerequisite surfaces early** — the quality gate that blocks `wv done` when an
  active node touches tracked files but `quality.db` is missing/un-scanned now also surfaces as a
  non-blocking `wv bootstrap` advisory, so agents scan during work instead of being blocked at the
  finish line. Reuses the close gate's own `_preflight_policy_readiness` evaluator; the close gate
  is unchanged and stays authoritative.
- **`/tmp/weave-codex-<uid>` documented as the shared sandboxed-runtime hot zone** — comment-only
  alignment clarifying that Claude Code, Codex, and Copilot all use it (via `is_sandboxed_runtime`);
  only native/human shells use `/dev/shm/weave`. The `-codex` name is historical.
- **Edit-target read caveat encoded into the context-load policy** — `context-guard.sh` and the
  consumer templates now state that shell reads (`cat`/`grep`/`sed`) and code-search do not satisfy
  harness edit-guards; only a native read of the edit target does.

### Fixed

- **`wv load` no longer flags no-op deltas as corrupt** — comment-only "no-op UPDATE" deltas are
  intentional and are no longer reported as corruption via a two-stage grep.

## [1.64.0] - 2026-06-25

### Added

- **Cross-harness agent-source attribution** — telemetry now records which harness originated a `wv`
  call (Claude, Codex, VS Code Copilot) honestly across machines. Codex and Copilot are attested via
  host markers rather than guessed, behind a documented cross-harness call-source contract
.
- **Agent identity separated from hot-zone placement** — `resolve_agent_id` (identity) and
  `is_sandboxed_runtime` (placement) are now independent axes, and the run-cache key includes
  identity so concurrent Claude/Codex agents no longer leak each other's cached results.
- **Graph memory crystallized into Codex and Copilot surfaces** — `wv memory render --agent=codex`
  writes `.codex/weave.json` and `--agent=copilot` writes a managed block in
  `.github/copilot-instructions.md`, projecting active `type=memory` nodes plus recall/capture
  guidance so cross-harness agents discover and recall graph memory.
- **Dev-only `md2pdf-hook.sh`** — syncs PDF copies of docs on `.md` change (development tooling).
- **Repair Workflow guidance in the shipped `WORKFLOW.md`** — documents turning detected workflow
  defects into tracked remediation and the resumable `needs_human_verification` close, so consumers'
  workflow reference covers the repair loop.

### Changed

- **`wv ready` announces tree truncation** in its text output, matching the `--json` truncation
  sentinel so capped result sets are visible to humans, not just parsers.
- **`wv impact` full traversal includes `relates_to` edges**, so blast-radius reports follow the
  relationship the cross-agent recall study depends on.

### Fixed

- **Delta-replay durability** — `wv load` no longer reverts a newer `state.sql` when replaying stale
  local deltas. Node upserts now apply only when `excluded.updated_at >= nodes.updated_at`, and node
  UPDATE deltas carry an `updated_at` guard. Prevents cross-agent double-claims after a fresh
  hot-zone load.
- **Session-start snapshot guard** — the session-start hook refuses to commit a `.weave` snapshot
  smaller than HEAD, so a stale-DB shrink can no longer clobber the committed graph.
- **MCP server test suite isolated from the live Weave graph**, so running the MCP tests no longer
  reads or mutates the developer's working graph.

## [1.63.0] - 2026-06-21

### Added

- **Agent-neutral procedure delivery system** — workflow procedures now live once as host-neutral
  canonical sources (`templates/procedures/<name>.md`) with a small contract header (`id`,
  `description`, `fallback`, `visibility`, `adapters`, `claude_skill`, `resources`), installed to
  `$CONFIG_DIR/procedures/` and projected into each harness's native surface:
  - **Claude** — auto-discoverable `.claude/skills/<skill>/SKILL.md` (marker-managed, transactional
    swap that preserves hand-written skills).
  - **Codex** — managed entries in `.codex/weave.json`.
  - **Copilot** — a marker-delimited block in `.github/copilot-instructions.md`.
  - Codex/Copilot also resolve `wv guide --procedure=<id>` and MCP `weave_guide({procedure})` as a
    portable CLI/MCP fallback.
- **`wv guide --procedure=<id>`** and MCP **`weave_guide({procedure})`** — serve an installed
  canonical procedure body on demand (mutually exclusive with `--topic`).
- **Procedure visibility contract (`local` | `shared`)** — only `shared` + `ready` procedures
  project into consumer surfaces and ship in releases; a consumer can narrow (never widen) via
  `.weave/procedures-visibility.conf`.
- **`gen-procedures.sh` contract validator** — enforces one canonical source per id, adapter
  reachability, unambiguous Claude skill mapping, resource integrity, and portable references; runs
  as a projection gate before any consumer surface is mutated.

### Changed

- **WORKFLOW.md is now a thin reference** — extracted the grown-in-place procedures (epic decompose,
  graph hygiene, quality gate, repair, rules, session context, subagent delegation, agent memory,
  code search, pre-commit gate) into canonical procedures, leaving a procedure index plus the
  reference tables. WORKFLOW.md shrank from 697 to 261 lines. GitHub Integration stays as standing
  reference material (no `gh-sync.md`).
- **Install / release reconcile procedures as a managed set** — `install.sh` repopulates
  `$CONFIG_DIR/procedures/` with deletion semantics (a removed canonical procedure stops
  projecting), `build-release.sh` validates contracts and ships only `shared` + `ready` procedures,
  and adapter projection is transactional with same-id ownership preflight so hand-authored
  skills/entries are never overwritten.

### Fixed

- **Stale-projection cleanup** — demoting (`shared` → `local`), deleting, or drafting a procedure
  now prunes its managed Claude skill, Codex entry, and Copilot line on the next
  `wv init-repo --update`.

### Fixed

- **Memory import is idempotent** — re-importing unchanged Claude memory files or Codex
  `stage1_outputs` rows now skips existing `source_hash` values and reports a `skipped` count,
  preventing duplicate candidate nodes.
- **Runtime JSON-contract gaps closed** — several `wv` read surfaces now satisfy the weave-runtime
  IPC boundary:
  - `wv update` invalidates the context cache on every mutation, so a same-session runtime consumer
    never reads stale node state after a status/text/alias/metadata change.
  - `--json-v2` is now accepted by `wv sync`, `wv learnings`, and `wv search`, matching the json-v2
    contract already used elsewhere.
  - `wv tree --json` appends a trailing truncation sentinel
    (`{"_meta":"truncation","shown":N,"total":M,"truncated":true}`) when the node cap is hit, so
    consumers see truncation in the stdout payload instead of a stderr-only warning.
  - Context-cache invalidation now clears both `<id>.json` and `<id>-<mode>.json` key forms.

## [1.62.0] - 2026-06-19

### Added

- **Graph-native agent-memory substrate** — Weave now acts as the cross-harness durable-memory store
  for AI coding agents, with the graph as the single source of truth. New `wv memory` surface:
  - `wv memory` MVP — graph-native memory nodes (`metadata.type=memory`) with a `candidate` ->
    `active` lifecycle; candidates are excluded from `recall`/`ready` until promoted.
  - `wv memory scan` / `wv memory import` — detect and import harness-store memory as candidate
    nodes. Sources are scoped per harness (Claude project memory, Codex `memories_*.sqlite`
    `stage1_outputs`, Copilot), each carrying `source_agent` / `source_kind` provenance and a
    deterministic `source_hash` provenance. Codex hashes include `repo_root`; Claude hashes are
    file-content hashes. `wv memory import --source=codex` closes the Codex scan-only gap by
    importing repo-scoped `stage1_outputs` rows as candidate memory.
  - `wv memory crystallize` — promote graph candidates to active memory; operates graph-wide
    (source-agnostic) and is conservative on prose to avoid promoting low-signal text.
  - **Memory projections** — `wv memory render` projects active memory for a harness;
    `--agent=current` falls back to the full generated set for unknown/custom labels rather than
    rendering empty.
  - **Repo-scoped Claude memory capture hook** — captures durable Claude project memory scoped to
    the current repo.
- **Weaver IPC boundary specification** — `docs/WEAVER-IPC-BOUNDARY.md` defines the runtime<->graph
  contract (Layer B rule contract + runtime drift audit) between weave-runtime and the Weave graph.

### Changed

- **Unified authoritative blocking signal across read surfaces** — `wv` read surfaces now derive the
  blocking/ready state from a single authoritative predicate, and `pattern-audit` Check 6 + `doctor`
  are reconciled against it so CLI, hooks, and audit agree on node state.
- **`recall --agent` is now observable** — the agent label is honored as a provenance/projection
  signal instead of being silently inert; known agents, MCP/native callers, and unknown labels all
  see the same active memory set.
- **Doctor / pattern-audit memory-authority guards** — `doctor` and `pattern-audit` gained
  memory-authority checks (Check 9) that flag when graph memory diverges from harness stores; the
  dual-authority guard is generalized to Codex.

### Fixed

- **`install.sh` ast-grep download is now opt-in** — the installer no longer attempts an
  opportunistic network/toolchain install of ast-grep. Default install detects an existing binary
  only; pass `--with-ast-grep` (or `WITH_AST_GREP=1`) to allow the cargo/GitHub install, or
  `--no-ast-grep` to suppress the optional messaging. Prevents surprising network activity in
  public/sandbox installs.
- **Memory and findings excluded from prune** — graph memory nodes and findings are kept out of
  `wv prune` so durable memory and recorded findings are not garbage-collected.
- **Codex/Copilot evidence scans are repo-scoped** — evidence scans no longer leak across repos.
- **Impact seeds include done-file owners** — `wv impact` seeds now include file owners from
  completed nodes, widening the blast-radius signal.

## [1.61.0] - 2026-06-15

### Added

- **Scaffold-sync wiring for the pre-commit test gate** — the two consumer-proven gate improvements
  (test-bed: earth-engine-analysis) now auto-inherit via `wv init-repo` / scaffolding sync instead
  of being copy-paste-only templates:
  - `scripts/test-impacted.sh` — a fast, impact-scoped pre-commit test runner is seeded if-absent
    (executable). It runs the test command on ONLY the staged sources' mirror test dirs (nearest
    existing ancestor), falling back to the full suite when nothing resolves. Edit the CONFIG block
    (`SRC_PREFIX`/`TEST_ROOT`/`RUNNER`/`RUN_ENV`) per repo and route sources to it in
    `.weave/test-map.conf` (`src/ = scripts/test-impacted.sh`). Never overwritten on `--update`
    since it carries per-repo edits. Test-bed evidence: cut a localized change from 6.2s/1385 tests
    to ~1.1s.
  - `.weave/ci-weave-paths-ignore.snippet.yml` — a reference snippet (refreshed on `--update`)
    recommending a `paths-ignore: ['.weave/**']` workflow rule over the brittle `[skip ci]` commit
    token, which GitHub matches anywhere in the message (a real commit merely mentioning it
    self-skips).
  - Both templates ship to `~/.config/weave/` on install and are documented in `WORKFLOW.md` (new
    "Pre-commit Test Gate & CI Hygiene" section) and `CLAUDE.md.template`.

## [1.60.0] - 2026-06-15

### Added

- **`test-map.conf` glob / prefix / `[default]` keys** — suite selection for the pre-commit impact
  gate is no longer exact-match only. Keys may be globs (`src/**/*.py = suite`), directory prefixes
  (`src/ = suite`), or a fail-safe default (`* = suite`, or a `[default]` section). Per-file
  precedence: exact > glob/prefix > naming heuristic > `[default]`. Closes the silent-rot failure
  where unmapped consumer source files committed with zero suite coverage and no signal; the
  pre-commit hook now also prints a one-line notice when staged files match no entry.
- **Output budget bounding** — `wv tree` is capped (node cap + truncation line) and
  `wv audit-pitfalls` defaults to `--only-unaddressed --top=20`, with the MCP `weave_tree`
  description updated to match. Bounds token-heavy command output that entered agent/MCP context.
- **Pattern-audit Check 8** — raw `sqlite3` access to `quality.db` is now constrained to blessed
  helper paths, preserving the quality producer/consumer boundary and preventing schema drift in
  incidental probes.

### Fixed

- **Vendored git-hook source-seed gap** — `wv-init-repo` now _seeds_ a missing vendored hook source
  in `scripts/hooks/` (not only refreshes existing ones), so a consumer scaffolded before a hook was
  added converges to the canonical set instead of running an installed hook with no in-repo source.
- **`wv-init-repo --update` left stale git hooks** — an installed Weave hook whose header wording
  had drifted was mistaken for a custom hook and skipped, leaving `.git/hooks/` stale (flagged by
  `wv doctor` with a manual `install` step). The ownership test now matches any stable Weave
  signature, so a managed hook is refreshed while a genuinely custom hook is preserved. The
  post-update hint also lists `scripts/hooks/` changes and prints a node-aware commit sequence.
- **`wv quality` ast_cache.db leaked into nested `.weave/`** — the AST cache is now anchored at the
  git top-level regardless of scan path, so a subdir-scoped scan shares the one root cache instead
  of dropping an untracked, un-ignored `<subdir>/.weave/ast_cache.db`. `wv-init-repo` also seeds a
  filename-scoped recursive ignore (`**/.weave/ast_cache.db`) that cannot shadow `state.sql`.
- **Busy-wait poller guard (`bash-dedup`)** — the dedup hook now denies an `until/while`+`sleep`
  loop while a tracked background task is live (reusing the lock liveness signal), closing the gap
  where an ad-hoc poller spawned to watch a backgrounded command escaped the lock and busy-waited.

## [1.59.1] - 2026-06-12

### Fixed

- **`weave_query` was broken over MCP** — the handler routed through `wvRead()`, which appends
  `--mode=discover`, but `wv query` is the only read command without `--mode` support, so every call
  returned `unknown option: --mode=discover`. Pre-existing since the `wvRead` introduction (v1.58.0
  had the same call); surfaced by the codex v1.59.0 verification. Handler now calls `wv()` directly,
  and the parity suite gained a `weave_query` DB-read execution smoke so read-path breakage can no
  longer hide behind the shell-out smoke.

## [1.59.0] - 2026-06-12

### Added

- **MCP tier-3 parity flags exposed**: `weave_query.include`, `weave_health.history`,
  `weave_recover.session`, `weave_sync.dry_run`, `weave_record_edit.intent`/`.metadata` (now
  requires only `id` plus one payload), `weave_plan.template` (standalone template emit), and
  `weave_quality_patterns` gains the `promote` subcommand with `parent`/`dry_run` — promote was
  absent from the enum entirely. Parity baseline 41 -> 32; every remaining line is a deliberate
  exclusion, the EXPOSE debt is retired.
- **Table-driven MCP dispatch**: the 850-line `handleTool` switch (CC 237, the repo's
  worst function) is now a `Record<string, ToolHandler>` map — 45 entries, each handler returning
  result text or a full response envelope for enforcement paths. The `mcp/src/index.ts` quality-gate
  exemption is retired; no function in the file exceeds CC 20. Tier-2 parity flags exposed in the
  same pass: `weave_search.type`, `weave_code_search.filter`, `weave_impact.files` (seeds from file
  paths; `ids` no longer required when `files` given); `search --mode/--graph/--filter` reclassified
  as code-path flags already covered by `weave_code_search`. Parity baseline 43 -> 41.
- **Pattern-audit Check 7** — non-predicate Bash functions ending in a bare `[ cond ] && cmd` tail
  are now flagged, preventing implicit status leaks from becoming control-flow contracts.
- **MCP tier-1 parity flags exposed**: `weave_add` gains `criteria`/`risks` (claim-ready
  node creation per decomposition discipline), `weave_quick` gains `learning`, `weave_ship` gains
  `verification_method`/`verification_evidence`, and `weave_done` gains `verification_evidence` —
  agentic closes over MCP can now attach evidence instead of drawing the post-close advisory. Parity
  baseline shrank 49 → 43 (tests/test-mcp-parity.sh enforces shrink-never-grow).

### Fixed

- **`wv done` under a custom `WV_DB` leaked a "Completed" trail into the repo's
  `.weave/trails.md`.** `auto_sync` already skips repo-state writes for caller-supplied DB paths
  (`WV_DB_CUSTOM`); the done-trail writer lacked the same guard, so closing a scratch-graph node
  from a repo cwd dirtied real trail state. Same skip applied; explicit `wv trails save` is
  unaffected. Known limitation recorded: the MCP Vitest harness (async piped spawn) is incompatible
  with the Codex sandbox — verify MCP there via `tests/test-mcp-parity.sh` instead.
- **MCP `tools/call` failed entirely in sandboxed Node (Codex).** `spawnSync` there reports
  `error.code=EPERM` from a post-spawn probe even when the child ran and exited 0; the `wv()`
  wrapper treated any `error` as fatal. Errors are now fatal only when `status === null` (the spawn
  itself failed). The parity test gained an execution smoke (`tools/call weave_guide`) so
  spawn-layer breakage can no longer hide behind green schema/list parity.
- **`wv done --verification-method` was parsed but undocumented**, hiding it from `--help` — and
  therefore from the parity test, whose CLI contract is the help text. Now documented, plus exposed
  and forwarded as `weave_done.verification_method`.
- **`bootstrap-agent` telemetry claimed `scope: "persistent"` when instrumentation was disabled**,
  and the append probe created the default log file as a side effect. Now reports
  `enabled`/`writable` separately with `scope: disabled|persistent|unavailable`; when disabled the
  probe is side-effect-free.
- **Direct test execution on bare-PATH sandboxes**: `tests/test-schema-contract.sh` self-appends
  user tool dirs (poetry discovery), matching `scripts/wv` and the Makefile; pylint's stats cache
  moved to a writable tmp dir, removing EROFS warning noise.
- **Call-log instrumentation leaked bash redirection errors on unwritable `WV_CALL_LOG`.** The
  `2>/dev/null` came after the `>>` open, so read-only filesystems (Codex sandbox EROFS) printed
  `Read-only file system` on every `wv` invocation. The append is now a braced group with stderr
  silenced before the open; regression tests cover unwritable and writable paths.
- **`make check` failed at command discovery in sandbox shells.** Codex-style shells omit
  `~/.local/bin`/`~/.cargo/bin` from PATH, so `poetry` and `wv` were unfindable. The Makefile and
  `Makefile.template` now append both dirs — the same fallback `scripts/wv` applies for itself;
  documented in the WORKFLOW/AGENTS/CLAUDE templates.
- **`bootstrap-agent` quality readiness probed a nonexistent `quality_scans` table**, reporting
  `tools.quality.ready=false` after a successful scan. Now probes `scan_meta`, the actual scan-run
  table, matching the `search --code` readiness path.
- **`bootstrap-agent` telemetry block claimed `scope: "persistent"` without checking writability.**
  In read-only sandboxes new calls were silently unrecorded while `analyze sessions` read stale host
  data. The block now runs a real append probe and reports `writable` plus a warning and
  `scope: "unavailable"` when the log path cannot be opened.

## [1.58.0] - 2026-06-11

Onboarding-audit remediation release (docs/findings/AUDIT-2026-06-11-onboarding.md, sprints R1-R3).

### Fixed

- **P1: `wv done --verification-evidence` lost evidence containing apostrophes.** The verification
  metadata write interpolated jq-built JSON raw into SQL; an apostrophe broke the statement, the
  unchecked write failed silently, and the node closed without evidence — the post-close advisory
  then blamed the caller. Now escaped like every sibling write AND rc-checked: a failed metadata
  write aborts the close loudly. Apostrophe round-trip regression test added (A3-1,).
- **Hotspot threshold unified across three divergent definitions.** Scan summary counted all-scope,
  the report queried `WHERE hotspot > 0` then scope-filtered, and health-info hardcoded `0.5` — the
  summary claimed crossers the report hid. New `count_hotspots()` is the single owner of
  scope+threshold semantics; `top_hotspots()` applies the threshold in SQL; summary count and report
  list now share one filter (A2-1,).
- **`weave_guide` MCP enum allowed only 5 of the CLI's 10 guide topics** despite shelling out to
  `wv guide`. Enum extended to all 10; stale topic lists in AGENTS/copilot/WORKFLOW templates
  updated to match (A1-5,).

### Changed

- **The bash CLI is now production scope in quality views.** `.weave/quality.conf [classify]`
  promotes `scripts/cmd`, `scripts/lib`, `scripts/wv` — hotspots now surface the real crossers
  (wv-cmd-ops.sh 0.89, wv-cmd-core.sh 0.64) instead of hiding the product. Quality score drops
  accordingly; threshold/exemption recalibration is deliberate future work (A2-2,).
- **`wv --help` lists the five shipped-but-undocumented commands:** `impact`, `hotzone`,
  `pattern-audit`, `validate-finding`, `test-record`; `discovery` added to the guide-topic line.
  Help-surface test extended (A1-1,).
- **Session retro guidance prescribes `--since-days=1 --source=agent`** in close-session skill,
  WORKFLOW template, WEAVE.md, and agent docs — unfiltered call-stats are dominated by cheap hook
  calls and misread as agent behavior. WEAVE.md's stale `source` field values corrected to
  `agent|shell|hook|sync|test`.

### Hygiene

- ARCHITECTURE.md: MCP tool count corrected (31 → 45), dead `make wv-compliance` claim removed,
  header retitled as a dated baseline snapshot (A1-2/3/6,).
- Legacy `scripts/sync-weave-gh.sh` archived to `archive/scripts/`; `test-gh-stress.sh` repointed.
  Stray root `quality.db` and `9127bf5c/` hash-bug artifact removed (A1-4, A2-4,).

## [1.57.0] - 2026-06-10

### Added

- **Stale-signal gate on findings promotion.** `wv findings promote` now accepts `--since-days N`
  (default 30) and refuses to promote findings whose evidence is older than the threshold. Prevents
  stale findings from entering the graph with misleading urgency. Override with `--force`
.
- **`wv uninstall` command.** Removes Weave from `~/.local/bin/`, `~/.local/lib/weave/`,
  `~/.config/weave/`, and optionally `.weave/` in the current repo. Documented lifecycle companion
  to `wv init-repo`. Install help updated to surface the command.

### Fixed

- **Write-time enum guard for `finding.violation_type`.** `wv update` now validates
  `finding.violation_type` against the canonical enum at write time, not only at close time.
  Prevents invalid violation types from entering the DB silently.
- **Pattern C finding schema reconciled.** `violation_type` enum expanded with `measurement-gap`;
  `historical:tooling` remapped to `historical:defect`. Flat→nested schema inconsistency resolved
.
- **`wv sync --gh` defaults to fast mode.** Omitting `--mode` previously defaulted to `--mode=full`
  (exhaustive reconcile across entire graph), which under GH auth failures created duplicate issues
  and left done nodes with open GH issues. Default is now `--mode=fast` (routine close path). Use
  `--mode=full` deliberately for periodic reconcile.
- **`uninstall` classified as exempt in run-cache registry.** `wv pattern-audit` Check 1 now passes
  cleanly. Gate clock for Pattern A Rust port reset to 2026-06-10; not-before date 2026-06-24
.
- **`wv list --json` emits `created_at`/`updated_at` fields.** Stale-node UTC parse fixed for
  downstream consumers that calculate node age.
- **Telemetry call-log four-count correctness.** `WV_CALL_LOG` entry counts corrected for
  session-analysis consumers.

## [1.56.1] - 2026-06-09

### Fixed

- **Sentinel now differentiates clean-close from true crash.** A sentinel with an empty active-node
  list writes an informational note only; a CRASH RECOVERY trail entry is only written when active
  nodes were in-flight at session end. Eliminates false crash entries in trails.md from normal
  terminal closes after `/close-session`.
- **Floor-guard blocks codex-sandbox checkpoint-over-truth data loss.** `_sync_floor_guard_ok()`
  refuses to overwrite `state.sql` when the new dump contains fewer than `WV_SYNC_FLOOR_RATIO`
  (default 0.70) of the committed node count. Wired into both `cmd_sync` and `auto_sync`. Bypass for
  intentional shrinks via `--force` or `WV_FORCE_SYNC=1`. Root cause and recovery procedure
  documented in `docs/findings/sandbox-checkpoint-over-truth.md`.
- **weave-guide, epic-planner skills updated with placeholder IDs and repair workflow.** Fixes
  workflow examples to use `wv-XXXXXX` placeholder IDs and adds a Repair Workflow section.
  `test-crash-sentinel.sh` updated to match new informational-message behavior.

## [1.56.0] - 2026-06-07

### Added

- **Breadcrumbs skill for orientation-preserving handoffs.** `.claude/skills/breadcrumbs/` adds a
  compact session breadcrumb workflow so agents can leave decision, file, command, blocker, and
  next-step context before compaction or handoff.

### Changed

- **Codex hook dispatcher proposal captured for Rust migration planning.**
  `docs/PROPOSAL-codex-hooks-rust-dispatch.md` records the current hook taxonomy, observed
  latency/IO costs, and a phased migration path for replacing shell hook entrypoints with a single
  Rust dispatcher.

### Fixed

- **`wv impact --include-done` now honors done seed nodes.** Done seed nodes are no longer filtered
  out before traversal when callers explicitly request done-node inclusion.
- **Delegate phase write-check coverage follows the real phase FSM.** The regression test now
  asserts the write guard through the delegated phase path instead of relying on stale assumptions.
- **`wv list` row caps and hook fallbacks are harder to bypass.** The default 50-row cap now applies
  across caller modes without an explicit override, and Claude Code hook entrypoints have more
  robust `wv-hook-common.sh` source-path fallback handling.

## [1.55.0] - 2026-06-06

### Added

- **`wv guide --topic=discovery` reference card.** Documents the ground-truth toolset (`wv search`,
  `wv query`, `wv impact`, `wv edges`, `wv analyze`) with the search-vs-query distinction and three
  caller quirks (`--limit=` equals-form, IN-list quoting, impact done-seed). Steers agents toward
  targeted 600-token reads instead of 12k-token `wv list` bulk dumps.
- **`wv init-repo` reports code-index status.** Setup summary now appends a line showing whether
  `wv index` has been run; fresh repos display `Run: wv index.` so agents do not silently lose
  `wv search --code` capability.
- **Session-close retro surfaces top command by token cost.** The stop hook emits a soft note
  showing the highest-cost command from `wv analyze sessions --call-stats` when session analysis is
  enabled. The `close-session` skill documents the step and links to `wv guide --topic=discovery`
  for follow-up.
- **VS Code hooks directory README.** `.github/hooks/README.md` now documents the team-shared VS
  Code native hook location and distinguishes it from personal global hooks.

### Fixed

- **`wv pattern-audit` Check 2/3 counts no longer double on zero matches.** `grep -c` exits 1 with
  output `0` on no matches; the `|| echo 0` fallback was appending a second zero, producing
  `def_count="0 0"`. Both sites now move the fallback outside the command substitution.
- **Hook `wv-hook-common.sh` sourcing survives Claude Code desktop env.** `BASH_SOURCE[0]` fails to
  resolve in the Claude Code desktop app, leaving `HOOK_DIR` as CWD and both relative source paths
  missing. All 9 hooks now carry a third fallback to the absolute install path
  `${HOME}/.config/weave/lib/wv-hook-common.sh`, and `HOOK_DIR` resolution is hardened with
  `BASH_SOURCE[0]:-$0`.
- **`wv list` 50-row cap now fires regardless of tty/mode.** Claude Code's bash tool allocates a
  pseudo-tty, causing mode to resolve to `execute` and bypassing the previous discover-only cap. The
  default 50-row limit now applies to all callers without an explicit `--limit`, `--all`, or
  `--status=done`. Text mode appends a stderr hint pointing to `wv query` when the cap is reached.

## [1.54.2] - 2026-06-04

### Fixed

- **`wv work --reopen` now documented across all consumer surfaces.** The 1.54.1 behavior change
  that made done-node reopen explicit (`wv work <id> --reopen`) was not reflected in any
  consumer-facing document. `WORKFLOW.md`, `AGENTS.md.template`, the `wv-init-repo` AGENTS.md stub,
  and `.claude/agents/AGENTS.md` now all document the flag with the exact error message agents
  receive when they omit it.
- **`weave_work` MCP tool exposes `reopen` parameter.** The MCP tool previously had no way to reopen
  a done node — calling `weave_work` on a done node returned an error with no recovery path. The
  `reopen` boolean parameter is now wired through to `wv work --reopen`, and the tool description
  explains when it is required.
- **`WORKFLOW.md` command table corrections.** `wv ship` key flags updated from `--gh` to `--no-gh`
  (the agent-safe default since 1.54.1); `wv touch` gains `--files=path1,path2` (new in 1.54.0 for
  explicit `node_files` attribution); `wv work` gains `[--reopen]` in the key flags column.
- **`quality.local.conf` documented in the Quality Gate section of `WORKFLOW.md`.** The
  per-developer gitignored override layer (new in 1.54.0) was absent from agent-facing docs; agents
  had no way to discover it without reading source.
- **`Makefile.template` `wv-close` no longer uses `--no-verify`.** The flag was redundant
  (`.weave/`-only commits pass the pre-commit hook without it) and inconsistent with Rule 9 ("no
  hook bypass").
- **Consumer pre-commit hook no longer requires Weave fixture pytest dirs.** Staged Python commits
  now run optional focused pytest directories only when `tests/weave_quality/` or
  `tests/weave_indexer/` exists; consumer repos should route their own suites through
  `.weave/test-map.conf`.
- **`wv init-repo --update` refreshes the actual Git hook entrypoints.** Hook installation now
  writes `pre-commit`, `post-commit`, and `prepare-commit-msg` from the managed `*-weave.sh` sources
  instead of leaving stale Git entrypoints behind.

## [1.54.1] - 2026-06-04

### Added

- **Persistent MCP telemetry JSONL.** Set `WV_MCP_CALL_LOG=/path/to/mcp_calls.jsonl` to persist
  per-response MCP telemetry with `source=mcp`, tool name, scope, payload bytes, elapsed ms, and
  response metadata. This complements the existing `--instrument` stderr summary and lets Codex, VS
  Code, and other MCP clients be measured across sessions.

### Changed

- **Agent graph-discovery guidance now favors targeted readers.** MCP recovery text and agent-facing
  command references now point at `weave_bootstrap`, `weave_search`, `weave_ready`, `wv status`, and
  `wv query` before broad `wv list` scans.
- **Codex readiness setup is more portable and explicit.** `wv init-repo` and related readiness
  surfaces now prefer repo-local wrappers where needed and make Codex MCP registration state easier
  to inspect instead of relying on host-specific command availability.
- **Codex MCP registration defaults to the lite/read-only surface.** Stale full MCP registrations
  are pruned from Codex setup paths and default registration now targets the bounded lite server
  unless a broader surface is deliberately configured.
- **First-class Codex readiness diagnostics.** Codex-oriented bootstrap and doctor output now expose
  the safe command contract, `.codex/weave.json` expectations, and actionable registration warnings
  before agents enter a write workflow.
- **Sandbox-safe Codex telemetry configuration.** MCP telemetry paths now favor writable sandbox
  locations, and configuration failures are reported directly instead of implying instrumentation
  was enabled when the client could not write the requested state.
- **Codex-safe MCP lifecycle defaults.** MCP close/sync tools now avoid GitHub/network work by
  default so mounted Codex MCP servers do not get monopolized by long lifecycle calls. `weave_done`,
  `weave_batch_done`, and `weave_ship` pass `--no-gh` unless `WV_MCP_ALLOW_NETWORK=1` is set;
  `weave_sync` and `weave_close_session` run bounded local sync and return explicit CLI fallbacks
  for requested `wv sync --gh` work.
- **`wv ship-agent --no-gh` and `wv batch-done --no-gh`.** Agent-safe close flows can now suppress
  GitHub issue close/sync behavior consistently across single-node, batch, and MCP close surfaces.
- **MCP lifecycle documentation aligned across shipped surfaces.** `README.md`, `README.public.md`,
  and `mcp/README.md` now describe bounded local MCP close/sync behavior, CLI fallback for GitHub
  sync, and the explicit `WV_MCP_ALLOW_NETWORK=1` opt-in for clients where long network calls are
  acceptable.
- **Workflow-surface regression coverage for Codex-safe MCP.** `tests/test-workflow-surfaces.sh` now
  asserts the network opt-in, default `--no-gh`, and `wv sync --gh` CLI-fallback contract so the MCP
  lifecycle guidance cannot drift from the implementation.
- **Bash workflow-suite harness stabilized.** The shell regression suites now cover the Codex
  readiness and telemetry contracts with corrected id parsing, safer here-string handling under
  `pipefail`, and clearer diagnosis for long-running parallel/core test batches.
- **Concurrent schema migrations are serialized.** `wv add` and other concurrent CLI processes now
  take a hot-zone schema lock before running migrations, preventing FTS5 virtual-table constructor
  races that could report success while dropping rows in the parallel WAL stress test.
- **Release surfaces bumped to 1.54.1.** Version metadata now matches across `scripts/lib/VERSION`,
  `pyproject.toml`, MCP `package.json`/lockfile, MCP server metadata, `docs/WEAVE.md`, and generated
  Makefile template headers.
- **Pre-Rust readiness docs grounded in the implementation.** `PATTERNS-rust-signatures.md` and the
  pattern-crystallization proposal now reflect the current command classifications, `trails` as the
  canonical command (`breadcrumbs` remains only a compatibility alias), Pattern E as ready/decided,
  and Pattern F as blocked only on the impact S4 / Weaver IPC boundary.
- **Unified query reader proposal brought current.** `PROPOSAL-wv-query-unified-reader.md` and the
  proposal index now distinguish shipped Phase 2a query/search parity from pending Phase 2b reader
  wrappers. Query Phase 2 is no longer a Rust readiness blocker; telemetry core is documented as
  `WV_CALL_LOG` session analysis, while query-specific `_telemetry` helpers remain optional
  follow-up work.

### Fixed

- **Done-node reopen is explicit.** `wv update --status=active` and plain `wv work <done-id>` no
  longer reopen completed nodes. Follow-on edits must use `wv work <done-id> --reopen`, which
  records the intentional conversion back to tracked work and emits Pattern E telemetry when call
  logging is enabled.
- **Query Phase 2 test assertions are literal-safe.** `tests/test-query.sh` now uses literal
  contains checks for option-like strings, preventing grep option parsing from making `--code`
  separation assertions pass or fail for the wrong reason.

## [1.54.0] - 2026-06-02

### Added

- **`node_files` three-layer coverage — Codex MCP + ship-agent backfill + `weave_record_edit`.**
  File attribution (`node_files` table, consumed by `wv impact --files`) is now populated on all
  three agent surfaces, not just Claude Code CLI (which has the PostToolUse hook):
  - **Codex CLI**: `wv init-repo` now registers the Weave MCP server via `codex mcp add` after build
    so `weave_record_edit` is available inside Codex sandboxes. `.codex/weave.json` scaffold
    emitted.
  - **`wv ship-agent` git backfill**: Before closing, reads `created_at` from the node, queries
    `git log --name-only --since=<created_at>`, and inserts changed paths into `node_files`. Zero
    agent discipline required — retroactive coverage for every Codex session.
  - **`weave_record_edit` MCP tool** (graph scope): explicit `(id, path)` write to `node_files` via
    `wv touch --files=`. For VS Code Copilot and any MCP-capable surface without a PostToolUse hook.
  - **`wv touch --files=PATH[,PATH]`**: new flag; comma-separated path list inserted into
    `node_files`. Shared write path for the MCP tool and backfill.

- **`wv analyze sessions` — Pattern E (reopen spike) reporting.**
  `wv config enable session-analysis` now also counts `reopen_done_node` events per session.
  Surfaced as `reopen_count` in JSON output and a "Pattern E — reopen" summary line in the human
  table when count > 0. Closes a telemetry blind-spot identified in the dogfood battery.

- **`wv search --code` Phase 2 gate — `--code` isolation + recall parity.** Two new test sections in
  `tests/test-query.sh` (41/41 pass): verifies `--code` results are disjoint from graph-only results
  and that recall parity holds between FTS and hybrid modes.

- **`quality.local.conf` — gitignored per-repo quality override layer.** A second config layer
  (`.weave/quality.local.conf`) is loaded after the committed `quality.conf`. Lets individual
  developers suppress warn-level gates locally without touching the shared config. `test_gate=2`
  (block) is non-overridable: if the committed config sets a block gate, the local layer cannot
  downgrade it — team-wide blocks remain enforced. Added to `.gitignore` and to the `wv init-repo`
  scaffold so new repos get it ignored automatically.

- **Codex agent contract in `AGENTS.md` scaffold.** `wv init-repo --agent=codex` now emits a
  `github_sync` block in the Codex `AGENTS.md` that distinguishes local-only `wv sync` from
  external-network `wv sync --gh`, annotated with `requires_sandbox_approval`. Prevents Codex agents
  from silently skipping GitHub sync when network is gated.

- **`install.sh` hook fallback to lib dir.** Hook installation now falls back to
  `~/.local/lib/weave/hooks/` when the source repo hook is absent, enabling clean installs from the
  public `weave` repo that carries hooks in the lib dir but not the `.claude/` tree.

### Fixed

- **jq 1.6 compatibility in `wv impact --json` and `wv sync --gh`.** Replaced jq 1.7-only object
  construction shorthand (`{key,key2}`) with explicit `{key:.key}` form throughout `wv-cmd-graph.sh`
  and `wv-cmd-ops.sh`. On Debian stable (jq 1.6) the shorthand caused `wv impact --json` to crash
  silently, which surfaced as `test-hooks` reporting 2 failures and `test-graph` showing `0/0` in
  parallel mode (script exited before the `Results:` line).

- **`test_weave_gh_data.py` mock for `Path.is_dir()`.** The `P` mock class in
  `test_falls_back_to_candidate_when_exists` was missing `is_dir`, causing `AttributeError` in
  `_runtime_hot_zone_base()` on non-Codex environments where `codex_base` is checked.

- **`wv pattern-audit` Check 1 regression — `config` and `test-record` unclassified.** Both commands
  were added during the v1.53.0 era but never added to the cache write-list in `wv-cache.sh`.
  `config` mutates env/conf files; `test-record` appends to the JSONL ledger and upserts the DB —
  both are writes. `wv pattern-audit` Check 1 (all dispatch commands classified) now passes. Pattern
  A gate clock restarted from 2026-06-01.

- **`auto_checkpoint` noise commit when HEAD is at origin.** After a push, the first `wv add`/
  `wv done` would trigger `auto_sync → auto_checkpoint` with nothing unpushed, creating a
  `[skip ci]` checkpoint commit before the next real feature commit. Fixed: when
  `HEAD == origin/<branch>`, `auto_checkpoint` unstages `.weave/` and returns without committing.
  The graph state is already on disk (written by `auto_sync`); the next real commit or
  `wv sync --gh` picks it up naturally. Offline repos (no remote) are unaffected.

- **`wv impact --files` now seeds from `node_files`.** Previously the command only read
  `touched_files` (PostToolUse hook data); it now also consults `node_files` so impact results are
  correct for Codex and VS Code Copilot sessions where `touched_files` is not populated.

- **Python module path resolution centralised (`_wv_python_module_path` +
  `_wv_agent_python_exec_module`).** Duplicate path-resolution blocks in `wv-cmd-data.sh`,
  `wv-cmd-findings.sh`, `wv-cmd-indexer.sh`, and `wv-cmd-quality.sh` were replaced with two shared
  helpers in `wv-cmd-ops.sh`. Eliminates a class of "tool not found" failures in Codex sandboxes
  where Python module discovery fell through.

- **`wv init-repo --update` preserves existing `copilot-instructions.md` content.** A re-run of
  `wv init-repo --update` was overwriting the repo's existing Copilot instructions with the stub
  template, discarding project-specific guidance. The updater now appends only the managed Weave
  block and leaves non-Weave content intact.

- **`wv init-repo` includes Codex in all agent scaffolds.** `--agent=codex` was not emitted during
  general `wv init-repo` runs; it is now written unconditionally so `.codex/weave.json` and the
  Codex `AGENTS.md` block are included in every fresh init.

- **Test commits on GPG-signing systems.** Tests that create ephemeral git repos now configure those
  repos with `commit.gpgsign=false` locally, so sandboxed or CI runs do not require access to the
  user's GPG agent. Real repository commits continue to honor the user's signing configuration.

- **MCP README and `copilot-instructions.md` `weave_breadcrumbs` → `weave_trails` regression.** Two
  doc files still named `weave_breadcrumbs` as the primary tool in scope/session tables after the
  breadcrumbs→trails rename shipped in v1.53.0. Fixed to `weave_trails`; deprecated alias noted.

## [1.53.0] - 2026-05-31

### Added

- **`wv trails` — session context trail (replaces `wv breadcrumbs`).** Append-only storage for
  session context notes: `wv trails save [--message="..."]` appends a timestamped entry;
  `wv trails show` renders the current trail with staleness detection; `wv trails capsule <id>`
  attaches the trail to a node on close. The trail is capped and compressed on context compaction.
  `wv breadcrumbs` remains as a back-compat alias across CLI and MCP. The `trails` skill replaces
  the `breadcrumbs` skill.
- **`wv hotzone db`** — prints the resolved `brain.db` path for the current repo. Prevents agents
  from hand-rolling `/dev/shm` vs `/tmp/weave-codex-*` paths for raw `sqlite3` calls — a guessed
  path errors and, in a parallel tool batch, cancels sibling calls.
- **`wv pattern-audit` Check 6 — node-state invariant for deferral.** Fails when a node declares
  deferral in metadata (`deferred=true` or `blocked_on` set) while still in the ready queue
  (status=todo with no inbound blocking edge). Promotes a recurring learning from two separate
  findings to an enforced gate. `wv doctor` gains a matching advisory.
- **Phase 6 — verification boundary (test-correctness gate).** `wv done` is now the single owner of
  the "is this correct?" decision for tests as well as structural quality. A producer/consumer split
  (PROPOSAL graph-as-policy-boundary §4.6): suites record outcomes, `wv done` reads them and
  decides; it never runs a test runner.
  - **`test_results` ledger + `wv test-record <suite> --files=… --exit=N`** — one row per file keyed
    `(suite, path)`, fingerprint = the file's git blob hash. pre-commit and post-commit hooks record
    their suite outcomes automatically.
  - **`file_test_status` + `_done_refresh_test_status`** — before the status flip, each touched file
    is derived green / red / stale / unknown by comparing the recorded fingerprint to the file's
    current blob (the same pure function both sides compute).
  - **`test_gate` policy (0=off, 1=warn, 2=block), default off.** `block` ABORTs the close via the
    `nodes_policy_check` trigger; `warn` emits a non-blocking advisory in `wv done`. Honors
    `quality_exempt`, the non-code node types `finding`/`epic`/`session_history`, and
    `--skip-verification` (suppresses the warn advisory; block is a hard gate).
  - **Single-source trigger.** `nodes_policy_check` is now emitted from one `_policy_trigger_sql()`
    definition (mccabe + trend + test clauses); `db_init` and the last migration recreate it from
    there, ending the hand-copied-trigger drift hazard.
- **Durable gate config — `.weave/quality.conf [thresholds]`.** A new section sets
  `policy_thresholds` on every `wv load` (the same durable seam as `[exempt]`), so a repo's gate
  policy survives reboot (tmpfs `brain.db` / `policy_thresholds` is not in `state.sql`).
- **Impact-grounded pre-claim advisory.** `pre-claim-skills.sh` now enriches the pre-mortem advisory
  with real `wv impact` blast radius (impacted count, risk score, high-risk nodes, affected suites)
  and recognizes the `premortem` metadata key, ending a spurious risk-label nag.
- **`wv config` — one front door for the opt-in knobs (onboarding).**
  `list | get | set | unset | enable | disable`. `wv config enable session-analysis` writes
  `WV_CALL_LOG` to a new disk-sourced `~/.config/weave/config.env` (override dir `WV_CONFIG_DIR`)
  and creates the log dir; `wv config enable test-gate [warn|block]` writes the durable
  `.weave/quality.conf [thresholds]` and applies it live. No more memorising env-var names or config
  paths.
- **Disk-sourced global knobs (`config.env`).** `wv` reads `config.env` on every invocation — CLI
  and harness-spawned hooks alike — so enablement survives reboot and no longer depends on env
  inheritance (resolves the session-analysis log under-counting hook traffic).
- **`wv doctor` verification-layer checks.** Surfaces `test_gate` state, warns when the gate is set
  in the tmpfs DB but absent from `.weave/quality.conf` (session-only, resets on reboot), warns when
  `test-map.conf` is missing while the gate is live, and reports the `test_results` ledger count.
- **Suite-run cost tracking (`duration_ms`).** Each suite run is now timed: pre-commit and
  post-commit hooks measure wall-clock cost and pass it to `wv test-record --duration=MS`. The
  `test_results` ledger gains a `duration_ms` column (migrated in place), making per-suite run cost
  available wherever the ledger is consumed.
- **Durable suite-run history (`suite_runs.jsonl`).** `wv test-record` appends one JSONL line per
  suite run to an always-on disk log (`~/.local/share/weave/suite_runs.jsonl`, overridable via
  `wv config set WV_SUITE_LOG <path>`). The log survives `wv load` and reboot — unlike the tmpfs
  `test_results` table, which is current-state only. Each row records
  `{ts, repo, suite, files, exit, duration_ms, sha}`. No file content, no absolute paths.
- **`wv analyze suites` — suite-run history report.** Aggregates the durable history log per suite:
  run count, pass/fail counts, total / avg / p95 duration. Heaviest suites sorted first. Defaults to
  the current repo; `--all` shows all repos; `--repo=<path>` narrows to one. JSON in
  discover/bootstrap mode, text table otherwise.
- **`wv config --show-origin` — config provenance.** `wv config list --show-origin` annotates each
  active knob with the file that provides it (`config.env`, `quality.conf`, or "builtin default").
  `wv config get <KEY> --show-origin` prints the effective value and its source layer. Mirrors
  `git config --show-origin`; becomes essential once the per-repo user override layer lands.
- **`wv config enable test-gate` scaffolds `test-map.conf`.** When the gate is enabled and no
  `test-map.conf` exists, a commented starter file is written to `.weave/`. The scaffold detects the
  repo stack (pyproject.toml → Python, Cargo.toml → Rust, package.json → Node, Makefile → shell) and
  emits language-appropriate wrapper-script examples. Never auto-enforced — user must edit and
  uncomment. Removes the blank-page barrier to activating the gate.

### Fixed

- **Honest session-analysis reader.** `wv analyze sessions --call-stats` no longer implies a default
  log path the writer never populates. With logging off it reports "instrumentation disabled" and
  points to `wv config enable session-analysis`; "enabled but empty" is a distinct message.
- **pre-commit hook lib resolution.** The hook now resolves its lib dir like the `wv` binary does
  (repo-local `scripts/lib/` first, then the installed `~/.local/lib/weave/lib`). Consumer repos
  that run the installed binary and have no `scripts/lib/` previously lost `wv_set_phase` and the
  validators silently; they now self-heal from the installed libs.
- **`wv impact --files` fallback when no node tracks the path.** Previously returned a blank "0
  impacted, 0 suites" — readable as "safe" — when no node recorded the file in `touched_files`. Now
  consults `_impact_suites_for_files` so affected suites still surface, and warns "blast radius
  unknown, NOT safe" so the caller knows the graph coverage gap.
- **Auto-checkpoint hijack guard runs before `git pull --autostash`.** The guard that prevents the
  checkpoint from absorbing in-progress staged files previously ran after the pull, at which point
  autostash had already unstaged them. Moved before the pull so staged non-`.weave/` files abort the
  checkpoint before any index-touching operation.
- **Stray empty root lock files removed.** Spurious empty lock files in the repo root caused by an
  edge case in the lock-file cleanup path are removed; `.gitignore` updated to prevent recurrence.

### Documentation

- `docs/WEAVE.md § 4.7` (verification boundary), `docs/DEVELOPMENT.md` (gate machinery), README +
  README.public "Verification Gates" sections, and `wv guide --topic=verification`. `wv impact`
  added to the command references (was missing).
- New `wv guide --topic=instrumentation` and an "Opt-in instrumentation" knob table in README +
  README.public covering `wv config`, `config.env`, and the verification-gate toggle.
- New `wv guide --topic=config` — two-layer ownership matrix (user-global `config.env` vs
  repo-committed `quality.conf`), ownership rule, `wv config` quick reference with `--show-origin`,
  gitignore boundary, and related-topic pointers.

## [1.52.1] - 2026-05-29

### Fixed

- **Hot-zone resolution split-brain in sandboxed agent shells.** `resolve_hot_zone` chose the codex
  (`/tmp/weave-codex-$uid`) vs `/dev/shm/weave` base from `is_codex_runtime()`, which reads
  `CLAUDE_CODE_SSE_PORT`. The CLI inherits that env var but harness-spawned hook processes do not,
  so the CLI and the hooks resolved different hot zones — the session-phase transition written by
  `wv work` never reached the hook that gates edits. Resolution now also follows an already-existing
  `/tmp/weave-codex-$uid` zone (a filesystem signal both process contexts can see), so CLI and hooks
  converge on one zone without moving the live DB. Mirrored in the Python resolver. Non-codex hosts
  never create the dir, so there is no change to native `/dev/shm` behaviour.

## [1.52.0] - 2026-05-29

### Added

- **`wv impact` — work-graph blast-radius query.** Given a node or changed files, reports the
  impacted subtree, newly unblocked work, and a risk score (folding `cross_impl_deps`,
  `depth_from_root`, `blocks_count`, and `missing_criteria`). Modes: `--files=path1,path2` seeds the
  query from changed files; `--suites` emits a lightweight file→test-suite map with no graph
  traversal. `wv ready --with-impact` annotates ready work with blast radius.
- **MCP impact surface** — new `weave_impact` tool, plus a `with_impact` option on `weave_ready`,
  mirroring the CLI for MCP clients.
- **`wv pattern-audit`** — CI regression net for control-plane patterns. Checks cache-class
  classification of dispatch commands, single-definition of status/edge/finding enums,
  `.session_phase` write routing through `wv_set_phase`, hook `wv-hook-common.sh` wiring, and the
  `pre-action.sh` thin-dispatcher line budget.
- **`wv validate-finding <id>`** — validates finding-node metadata (required fields, violation type)
  and is invoked by the `pre-close-verification` hook.
- **`bash_cc_backend`** column surfaced in `wv quality scan`/`diff` output.

### Changed

- **Hook enforcement crystallized into named units.** All pre-action enforcement checks are now
  individually named `_hc_check_*` functions in `scripts/lib/wv-hook-common.sh` (installed-path,
  phase, active-node, stale-node, context-pack, contradictions, blockers) and `pre-action.sh` is a
  thin dispatcher. Each check has isolated unit tests. Shared hook setup (hot-zone, DB path, phase)
  is sourced from `wv-hook-common.sh` across all hooks.
- **Pre-commit test gating is impact-routed** — `pre-commit-weave.sh` selects which shell suites to
  run via `wv impact --suites` instead of a fixed list, so only suites affected by the staged files
  execute.

### Fixed

- **`$HOME/.claude/` memory-layer edits no longer require an active Weave node.** Edits under the
  agent's own memory/runtime directory are classified as external state, exempt from node/phase
  enforcement and the edit-hygiene tally. Scope is `$HOME/.claude/` only; project-local `.claude/`
  (hooks, settings, skills) stays governed.
- **Discover-phase commit gate** — `pre-commit-weave.sh` now blocks non-`.weave/` commits during the
  discover phase, matching the edit-time gate.
- **Sandbox runtime parity for hot-zone routing** — `is_codex_runtime` now treats Codex, Copilot,
  and Claude Code agent shells as codex-style sandboxes for hot-zone selection. These environments
  can lose `/dev/shm` continuity between tool calls; routing to `/tmp/weave-codex-*` keeps graph
  state stable across invocations.
- **Codex PATH and discovery hardening** — Codex and Weave tool PATH handling normalized so the `wv`
  shim and helper tools resolve consistently inside Codex shells.
- **`weave_gh` DB resolver parity with bash runtime** — `scripts/weave_gh/data.py::_resolve_db_path`
  now derives defaults from runtime mode (`codex`/container/native) and adds the missing
  `/tmp/weave-<uid>/<repo-hash>/brain.db` candidate. This closes Linux/container sandbox drift where
  Python sync paths could miss the active DB and read from the wrong namespace.
- **GitHub sync-status guidance hardening** — `wv guide --topic=github` no longer recommends
  `gh issue list --label weave-synced` (which can undercount on some repos). Guidance now uses an
  unfiltered open-issues query with local label filtering via `jq`.

## [1.51.8] - 2026-05-26

### Fixed

- **Run-cache write-list completeness** — `touch`, `unarchive`, `ship-agent`, and `findings` were
  missing from `_wv_run_cache_is_write_cmd`. All four mutate the graph; omitting them meant the
  run-cache sentinel was not touched after these calls, so a subsequent `wv bootstrap` or `wv ready`
  could serve stale output for up to 45s. Added alongside the existing list in `wv-cache.sh`.
  (`findings` invalidates on both `promote --apply` and `list`; acceptable given low call
  frequency.)
- **Context-cache invalidation gaps** — `cmd_touch` and `cmd_unarchive` were missing
  `invalidate_context_cache` calls. `wv touch` updates `current_intent` (read by `wv context`) and
  `wv unarchive` restores a pruned node into the live graph, making both neighbours' context stale.
  Fixed: both now call `invalidate_context_cache` after their respective DB writes.
- **Closing-phase enforcement window unbounded** — after `wv done`, `.session_phase` stayed
  `closing` indefinitely until the next `wv work`. Both gates (pre-action.sh edit-time and
  pre-commit-weave.sh commit-time) bypassed enforcement during this window, allowing unlimited
  untracked edits and commits. Both now reset the phase to `discover` after permitting a single
  operation (one edit, one commit), bounding the window to its intended one-shot semantics.

### Notes

- `wv allowed-tools` is a pure read (SELECT); the `allowed_tools` writes occur inside `wv done` and
  `wv work` which are already in the write-cmd list.
- MCP path asymmetry: `mcp/src/index.ts` does not read `.session_phase`. MCP uses its own gate
  (`MCP_READ_MODE`). If MCP-driven and Claude Code-driven edits are mixed across a `wv done`, the
  MCP edits do not participate in the closing-phase window. By design.

## [1.51.7] - 2026-05-26

### Performance

- **AST blob-SHA result cache** — `ASTCache` (`.weave/ast_cache.db`, gitignored) keyed on
  `(blob_sha, scanner_version)`. Unchanged files return cached `FileEntry` / `CKMetrics` /
  `FunctionCC` without calling `ast.parse()` or `_single_pass_ast()`. Survives `wv quality reset`.
  Post-reset scan (warm cache, no code changes): 3.1s → 1.2s. Combined with concurrent git: 4.7s →
  1.2s.
- **Concurrent git stats** — `enrich_all_git_stats` and `compute_co_changes` submitted to a 2-worker
  `ThreadPoolExecutor` before `_scan_files` starts; git `subprocess.run()` calls (GIL-free) overlap
  with CPU-bound Python analysis. Full scan: 4.7s → 3.1s (34%). Incremental: 0.8s → 0.5s.
- **Single-pass RFC + LCOM** — RFC counted during `_single_pass_ast` (method defs + call nodes per
  class), stored on `ASTAnalysis.class_rfc`; LCOM uses precomputed `self.x` attr sets from the CC
  visitor's `visit_Attribute` hook, with early-exit when no method references `self.x`. Full scan:
  ~7.8s → ~4.7s (40% reduction).

### Fixed

- **`deepeval_runner` readiness check** — replaced bare `_check_chunks_indexed` with
  `collect_readiness`; now surfaces `node_files` empty and `quality_db` state alongside chunk count.
  Warnings emitted to stderr when filtered cases will return 0 results.
- **`deepeval_runner` quality enrichment** — added `--quality-db` arg; per-file `churn`, `hotspot`,
  and `weave_nodes` count attached to case output via `enrich_results` when results are non-empty.
  Auto-resolved from `$WV_HOT_ZONE/quality.db`.
- **`deepeval_runner` docs** — `PYTHONPATH=scripts` added to all usage examples (module not on
  default Poetry path); quality-db usage example added; semble MCP-only limitation and AST-chunking
  gap documented.
- **`wv quality patterns` structural search** — `ast-grep run --pattern` has broken metavariable
  support for Python; switched to `scan --rule` (YAML temp file). Works for all languages; temp rule
  cleaned up in `finally` block.
- **`quality.conf` parsing** — `ConfigParser` now uses `inline_comment_prefixes=('#',)` and
  `allow_no_value=True`; previously caused `ParsingError` on `[exempt]` entries with inline `#`
  comments and no `=` delimiter.

## [1.51.6] - 2026-05-25

### Added

- **Bash ast-grep CC backend** (`scripts/weave_quality/bash_ast_grep.py`,
  `scripts/weave_quality/rules/bash_cc.yaml`) — structural AST-based cyclomatic complexity for Bash
  files using ast-grep + tree-sitter-bash. Counts `if`, `elif`, `case_item`, `for_statement`,
  `c_style_for_statement`, `while_statement` (covers `until` via aliasing), `&&`, `||`. Falls back
  to regex backend when ast-grep is unavailable; graceful degradation at file granularity. Backend
  aggregate recorded in `scan_meta.bash_cc_backend` (`"regex"` / `"ast-grep"` /
  `"ast-grep+fallback"`).
- **TypeScript ast-grep CC backend** (`scripts/weave_quality/typescript_parser.py`) — constructor
  detection fixed (removed `"constructor"` from method-keyword skip list; now captured by name
  pattern). CC assignment corrected to single-pass innermost-first enumeration using an `assigned`
  set to prevent double-counting across overlapping function ranges. Backend aggregate recorded in
  `scan_meta.ts_cc_backend`.
- **`wv quality patterns`** — list, scan, and promote structural pattern findings; store and query
  results from `pattern_findings` table. Requires ast-grep. See `wv quality patterns --help`.

### Fixed

- **`finish_scan()` backend metadata** — `bash_cc_backend` and `ts_cc_backend` now reflect actual
  per-file backend usage aggregated across `_scan_files()`, not binary presence at scan start.
  Prevents scan_meta from recording `"ast-grep"` on files that silently fell back to regex.
- **ast-grep YAML rules ASCII-only** — `rules/bash_cc.yaml` comments use ASCII only; em-dash
  characters in YAML comments caused ast-grep rule parse failures.
- **tree-sitter-bash kind aliasing documented** — `until_statement` and `select_statement` do not
  exist as distinct kinds; `until` maps to `while_statement`, `select` maps to `for_statement`.
  Invalid kind names removed; aliasing documented in rule comment.

## [1.51.5] - 2026-05-25

### Fixed

- **`lint-file` target consumer-owned** — moved outside `BEGIN/END WEAVE TARGETS` managed block;
  `init-repo` writes it once via `_lint_file_stub()` and never overwrites on `--update`. Migration
  guard appends stub to old repos where `lint-file` was inside the block. Consumers supply their own
  per-file linter recipe (ruff, eslint, rubocop, etc.).
- **Two-tool search pattern documented** — `README.md`, `README.public.md`, `WORKFLOW.md` updated
  with `wv search` (graph nodes) vs `wv search --code` / semble / any external tool (source files).
  Consumer's choice framing: Weave provides the built-in; semble, ripgrep, ast-grep are additive.
- **Why Weave tables updated** — Code search row added, Retrieval and Infrastructure rows reflect
  current state. Added maturation note: BM25+cosine RRF local, no cloud API required.
- **Version headings stripped from `README.public.md`** — `## Hook Determinism (v1.10.0+)` and
  `## Code Quality (v1.8.1)` cleaned to plain headings.

## [1.51.4] - 2026-05-25

### Fixed

- **GraphPolicyViolation resolution** surfaced in `WORKFLOW.md`, `dev-guide/SKILL.md` — agents now
  have the `.weave/quality.conf [exempt]` + `wv load` path documented in agent-facing templates.
- **runtime.md two-block architecture** in `install.sh` — `BEGIN/END WEAVE RUNTIME CONTENT` markers
  enable surgical `--update` without clobbering repo-specific content below.
- **Copilot pre-flight parity** — `templates/copilot-instructions.stub.md` and `install.sh` heredoc
  updated from `git status && wv status` to `wv bootstrap --json`.
- **Copilot stub `make format/lint` removed** — project-specific quality gates do not belong in
  Weave templates; only Weave-enforced invariants documented.
- **`Makefile.template` `lint-file` target** — changed from hardcoded `ruff check` (Python-only) to
  a no-op guidance block with examples for Python, JS/TS, Ruby. Consumers override for their stack.
- **install.sh copilot heredoc synced to stub** — missing sections (Sync modes, Context pack,
  `--standalone` shortcut, `wv touch`) propagated from stub to fallback heredoc.

## [1.51.3] - 2026-05-25

### Fixed

- **Core Workflow block** in `README.public.md` and `README.md` — step 0 updated from
  `git status && wv status` to `wv bootstrap --json`. Was missed during 1.51.1 parity pass which
  updated CLAUDE.md template and AGENTS.md but not the prose workflow blocks.

## [1.51.2] - 2026-05-25

### Fixed

- **`install.sh` AGENTS.md stub** — session-start (`wv bootstrap --json`), session-close sequence,
  and operating rules added to the heredoc written to `.claude/agents/AGENTS.md` in consumer repos.
  Step 0 corrected from `git status && wv status` to `wv bootstrap --json`.
- **`templates/AGENTS.md.template`** — same step 0 fix and workflow prose update, matching canonical
  `WORKFLOW.md`. This file ships as root-level `AGENTS.md` in the public weave repo.

## [1.51.1] - 2026-05-25

### Fixed

- **MCP tool count corrected to 40** in `README.md` and `README.public.md` (was 35 since v1.50.1
  added 5 tools but docs were not updated). `weave-inspect` scope count corrected to 19 (was 15).
- **MCP table gaps filled** — `weave_unlink`, `weave_block`, `weave_unarchive`, `weave_ready`,
  `weave_query`, `weave_recover`, `weave_code_search`, `weave_index` added to both README tables.

### Changed

- **`templates/CLAUDE.md.template`** — step 0 updated from `git status && wv status` to
  `wv bootstrap --json` to match canonical `WORKFLOW.md`. Workflow prose condensed.
- **`CLAUDE.md`** — managed block updated to match template; duplicate `## Workflow` section
  replaced with a one-line pointer to the canonical reference.
- **`.claude/agents/AGENTS.md`** — session-start (`wv bootstrap --json`), mid-session, and
  session-close sequences added; operating rules added; subagent table preserved.
- **`.weave/runtime.md`** — populated with repo-local Weave startup/close block, graph signal table,
  mid-session commands, and this-repo dev notes. Previously empty placeholder.

## [1.51.0] - 2026-05-24

### Added

- **`wv unarchive <id>`** — Restore a pruned node from `.weave/archive/` to the live graph. Searches
  JSONL archive files newest-first, previews with `--dry-run`. Covered by 10 new assertions in
  `tests/test-data.sh`. MCP `weave_unarchive` tool added.
- **MCP tools: `weave_unlink`, `weave_block`, `weave_ready`, `weave_query`, `weave_unarchive`** —
  Five new MCP tools bringing total to 40 (was 35). All tools verified against CLI parity.
- **`docs/wv-query.md`** — Phase 1 ship artifact documenting predicate syntax, examples, and JSON
  schema for `wv query`.

### Changed

- **Workflow reference completeness** — `templates/WORKFLOW.md` and
  `.github/copilot-instructions.md` commands tables updated with 25+ commands missing since
  v1.1–v1.49: `wv query`, `wv session-summary`, `wv digest`, `wv cache`, `wv hotzone list/gc`,
  `wv compact`, `wv doctor`, `wv recover`, `wv delete`, `wv unlink`, `wv edges`, `wv related`,
  `wv refs`, `wv audit-pitfalls`, `wv guide`, `wv reindex`, `wv preflight`, `wv clean-ghosts`,
  `wv edge-types`, `wv self-update`. `wv done` table entry gains `--no-gh` flag. `wv health` entry
  gains `--history[=N]`.
- **`wv done` help string** — `--no-gh` flag now visible in `wv done --help` (was implemented since
  v1.33 but missing from the usage string).
- **Session phases documentation** (D1) — Session phase table (`discover`/`execute`/`closing`) added
  to `templates/WORKFLOW.md` with phase transitions, active-node enforcement rules, and stale-node
  detection behavior.
- **Commit attribution documentation** (D2) — `prepare-commit-msg` hook attribution and manual
  amendment instructions added to workflow step 4.
- **Bootstrap-first session start** (D4) — Step 0 changed to `wv bootstrap --json` with token-cost
  annotation explaining it replaces 7 separate calls.
- **Code search guidance** (D5) — New "Code Search" subsection distinguishing graph FTS
  (`wv search`) from source code search (`wv search --code` / `mcp__semble__search`).
- **Ready re-ranking documentation** (D6) — `[touched N]` marker, 20-path `recent-edits.txt` ring,
  and tmpfs path documented in `templates/WORKFLOW.md`.
- **MCP tool count corrected** (D7) — `templates/WORKFLOW.md` and `copilot-instructions.md` updated
  from "35 tools" to "40 tools", "15-tool inspect subset" to "17-tool inspect subset".

### Fixed

- **`wv unarchive` INSERT into generated columns** — `priority` and `type` in the nodes table are
  `GENERATED ALWAYS AS... VIRTUAL`; SQLite rejects INSERTs that name them. Removed from INSERT
  column list.
- **`wv unarchive` set-e last-statement trap** — Two `[ -n "$r_alias" ] && echo` patterns at
  function boundaries returned exit 1 when alias was empty. Replaced with `if/fi` guards.
- **`pre-claim-skills.sh` alias gate (D3)** — Three-tier claim gate now enforces `done_criteria` →
  `risks` → `alias` in order. Missing alias produces a soft deny with repair instruction before any
  claim is allowed.
- **`cmd_doctor` CC 103→91** — Extracted `_doctor_check_git_hook` helper from two identical git
  commit hook check blocks in `cmd_doctor`. Resolves quality gate block at close time
  (`mccabe_max_sh` limit=100).

## [1.50.1] - 2026-05-23

### Fixed

- **Completed the post-`v1.50.0` version bump** — the MCP package surfaces, public design doc,
  changelog, and generated Makefile template now all advertise `1.50.1`, keeping the tagged source
  release internally consistent.

- **`wv done`/`wv ship` file-backed learning parsing now matches shell form** — newline-delimited
  `decision:`, `pattern:`, and `pitfall:` entries from `--learning-file` are parsed into the same
  structured metadata keys and hygiene score as inline `--learning="..."` input.

- **`wv search` help is discoverable again** — the topic help stub now matches the richer internal
  `wv search --help` surface, so `--code`, `--filter`, `--type`, and `--learning` guidance is shown
  through normal help entry points.

- **Weave breadcrumbs now inherit `merge=ours`** — generated `.gitattributes` blocks now include
  `.weave/breadcrumbs.md`, aligning it with the other locally authoritative Weave state files and
  suppressing noisy PR diffs via `linguist-generated` on the state dumps.

## [1.49.1] - 2026-05-23

### Fixed

- **`wv doctor` now warns on orphan hot-zones** (O5) — check 8b counts `/dev/shm/weave/` dirs whose
  `.repo_root` points to a non-existent directory, or that have no owner file and are not the
  current zone. Warns with count and suggests `wv hotzone gc`.

- **`wv doctor` hook-drift check is now bidirectional** (O1) — previously only detected repo-local
  hooks that were stale vs. the installed copy (forward direction). Now also detects hooks present
  in `~/.config/weave/hooks/` that are missing from the consumer repo's `.claude/hooks/` — surfaces
  new hooks added in newer releases that were never copied down via `wv init-repo --update`.

- **`wv init-repo --update` suppresses spurious Makefile diff** (O4) — the command always printed
  "weave targets updated" even when the only change was the version comment. Now compares new and
  existing Makefile content (with the `# Generated by wv-init-repo v…` line stripped); prints "weave
  targets up to date" and skips the write when content is otherwise identical.

- **`wv hotzone gc` added** (F3/O2) — new subcommand to remove orphan `/dev/shm/weave/` dirs from
  previous git repos or test runs. Supports `--dry-run`. Skips dirs with a brain.db modified in the
  last hour (active-session guard). `wv hotzone list` shows all known zones with their repo roots.

- **`test-core.sh` hot-zone isolation test no longer leaks** (O2) — `test_hot_zone_isolation`
  resolved the target hot-zone to `/dev/shm/weave/<hash>` (outside the temp dir) and never cleaned
  it. Teardown now explicitly removes the resolved path.

- **`.weave/.prune_epoch` gitignored** (O3) — the epoch marker was not in `.gitignore`, causing it
  to appear as an untracked file after every `wv prune`. Added to `.gitignore`.

## [1.49.0] - 2026-05-23

### Fixed

- **CRITICAL: Auto-prune is now opt-in (`WV_AUTO_PRUNE=1`)** — `db_ensure` previously fired a
  destructive DELETE of all done nodes older than 24 hours whenever the database exceeded 50 MB,
  without user awareness or consent. On one test machine this silently deleted 121 of 252 nodes.
  Default behavior is now warn-only: prints the DB size and suggests `wv prune --age=7d` or
  `WV_AUTO_PRUNE=1`. Destructive path is unchanged but requires explicit opt-in.

- **CRITICAL: Manual `wv prune` now deduplicates against today's archive** — `cmd_prune` appended to
  the daily JSONL unconditionally, producing exactly 2× duplication on back-to-back runs (verified
  690 → 1380 lines). Ported the dedup pattern from the auto-prune path: reads existing IDs from
  today's archive and excludes them from candidates before appending or deleting.

- **CRITICAL: `wv prune` no longer spam-comments closed GitHub issues** — every prune call ran
  `gh issue close --comment` on all candidates regardless of current issue state, adding a fresh
  "Pruned from Weave graph" comment to issues that had been closed for months. Added a pre-state
  check (`gh issue view --json state`); close + comment only fires when state is `OPEN`.

- **`wv prune --dry-run` now shows post-dedup candidates** — `--dry-run` returned before the dedup
  filter ran, showing inflated counts and IDs that would not actually be pruned on the live path.
  Moved dedup (read-only archive check) before the dry-run gate; `mkdir -p` deferred until after so
  dry-run remains side-effect-free. Verified: seeded 5 IDs into today's archive, dry-run count
  dropped from 42 → 37, all 5 seeded IDs excluded.

- **Hot-zone drift: `WV_PROJECT_DIR` fallback removed from `hot_zone_matches_repo`** — the function
  fell back to `WV_PROJECT_DIR` when no `.repo_root` owner file existed, causing every ownerless hot
  zone to appear to match the current repo. This suppressed leaked-override detection when
  `WV_HOT_ZONE` pointed to a foreign repo's zone. Unknown-owner zones now return 0 (accept) without
  the fallback — correct for new and test zones; only explicit wrong-owner files trigger rejection.

- **Size-check subshell export guard** — `_WV_SIZE_CHECKED` was set but not exported, so pipe
  subshells (e.g. `cmd_context "$id" --json | jq.`) inherited an empty value and re-fired the
  auto-prune check. Changed to `export _WV_SIZE_CHECKED=1`.

- **`wv context` pretty-prints without `--json`** — previously errored when called without `--json`.
  Now self-calls with `--json` and pipes through `jq.` for human-readable output.

- **Code indexer excludes `archive/` directory and `venv_*` prefixes** — `wv search --code` was
  indexing archived proposal docs (dominating code search results) and virtual-environment
  directories matched by prefix (e.g. `venv_ee`, 990 MB). Added `archive` to `_EXCLUDE_DIRS` and an
  `_is_excluded()` helper that also matches any path part starting with `venv`.

- **Code indexer skips futile chunks eviction** — auto-prune evicted the indexed-chunks cache even
  when the chunks table was smaller than the DB overhead, making the DB larger after eviction. Now
  checks `db_size - chunks_bytes <= WV_MAX_DB_SIZE` before evicting.

- **`test-multi-agent.sh` uses `HEAD` not hardcoded `master`** — `git push origin master` failed on
  machines with `defaultBranch=main`. Changed to `git push origin HEAD`.

### Performance

- **Vectorized cosine similarity in `wv search --code`** — replaced a per-blob `np.dot` loop with a
  single BLAS matrix multiply (`np.stack → matrix @ q_vec → np.argpartition`). 10–100× faster on
  large indexes with no change in result quality.

## [1.48.0] - 2026-05-21

### Added

- **Quality gate on `wv done`** — closing a node now checks that no file linked to the node has a
  function above the language-specific CC threshold: Python=25, Bash=100, TypeScript=15. The gate
  checks per-function CC (not file-level aggregate), so only oversized individual functions block
  the close. Exempt paths (monolithic scripts, archived code) via `.weave/quality.conf`:

  ```ini
  [exempt]
  install.sh   # full path match
  archive/     # directory prefix (trailing / required)
  ```

  Run `wv load` after editing the file to apply in an existing session. Full reference:
  `wv quality help` and `scripts/weave_quality/README.md` § Quality Gate.

- **`wv query` — unified predicate-based graph reader** — new command with full predicate parser
  supporting `key=value`, `key!=value`, `key>=N`, `key IN (a,b,c)`, `HAS key` (dual-schema aware for
  `learning`), and `MATCH "expr"` (FTS5 phrase search). Supports `--order` (recent/oldest/
  relevance/hygiene/stale), `--limit`, `--format` (table/json/short), and `--include`
  (learning/finding/hygiene). Phase 1 ships the backend; wrapper parity (replacing individual
  `wv list`, `wv learnings`, `wv search` flags) is Phase 2.

### Fixed

- **`wv-touched-files.sh` hook exits 1 silently** — `wv-resolve-project.sh` used bare
  `$WV_PROJECT_DIR` under `set -u` (unbound variable error), causing the PostToolUse hook to exit 1
  with no stderr output on every file edit when `WV_PROJECT_DIR` was not already exported. Fixed by
  using `${WV_PROJECT_DIR:-}` throughout the resolver. Also fixed `resolve_active_primary` returning
  exit 1 when no active node exists — added explicit `return 0`. Both bugs co-introduced May 9 in
  `b717fe97` + `169611e6`; shipped in v1.45.0–v1.47.2.
- **`stop-check.sh` auto-push stalls every response** — Tier 2 auto-push path added in v1.41.x
  called `wv sync --gh` (unbounded network call) with no timeout. On slow network or large graphs
  (900+ nodes) blocked every Claude Code response. Removed entirely; push responsibility stays in
  `session-end-sync.sh`. Added `"timeout": 15` to Stop hook entry in `settings.json`.
- **`post-edit-lint.sh` prettier rewrites files outside repo root** — hook matched any `.json` file
  by extension with no path guard, causing `~/.claude/settings.json` to be reformatted and fields
  stripped (the `timeout` fix above was being erased on every edit). Added
  `git rev-parse --show-toplevel` guard — prettier only runs within the project root.
- **`session-end-sync.sh` amend could corrupt work commits** — the amend-within-push-boundary logic
  introduced in v1.47.0 (`3b71ebff`) used only an elapsed-time proxy and unpushed check. Missing:
  (a) subject-line match verifying HEAD is a checkpoint commit, (b) no-non-.weave-files guard. Could
  amend a real work commit with `.weave/` state when a checkpoint had run within 2h and HEAD was not
  yet pushed. Now uses identical three-guard rule as `auto_checkpoint` in `wv-cmd-data.sh`.

### Refactored

- **`weave_quality/__main__.py`** — `cmd_scan` (CC 37→19), `cmd_diff` (CC 33→10), `cmd_promote` (CC
  28→17) decomposed into focused helpers to clear the repo's own py=25 quality gate. No behaviour
  change.
- **`weave_gh/phases.py`** — `_traverse_candidates` (CC 32→19) decomposed via
  `_build_candidate_dedup_context` and `_find_gh_match_by_body` helpers. Removes all `# noqa: C901`
  and `too-many-branches` suppressors.

## [1.47.2] - 2026-05-20

### Fixed

- **`wv ship` / `wv done` deadlocks on wv-self-managed files** — `pre-close-verification.sh` blocked
  every close attempt when `.claude/hooks/`, `.claude/skills/`, or `.claude/agents/` files appeared
  dirty. These files are wv infrastructure updated by `install.sh` / `wv init-repo --update`; they
  are not work product and should never gate a close. Fixed by: (a) calling
  `git update-index --refresh` before the dirty scan to clear stat-only mtime changes caused by
  hooks touching themselves on invocation, and (b) excluding `.claude/hooks/`, `.claude/skills/`,
  and `.claude/agents/` from the dirty-file scope entirely. The deadlock was self-defeating: the
  very `wv ship` invocation that should close the node re-triggered the hooks that dirtied the
  files. Filed as `docs/findings/ship-clean-tree-gate-self-defeating.md`.
- **`wv load` fails when state.sql contains benign SQLite runtime errors** — `sqlite3` exits 1 on
  non-fatal errors during import (e.g. malformed JSON in a generated column check) even when all
  rows were imported successfully. The load guard treated any non-zero exit as a corrupt dump and
  kept the stale database. Fixed to run the import unconditionally and validate the result via
  `SELECT COUNT(*) FROM nodes` instead of relying on the exit code.

## [1.47.1] - 2026-05-20

### Added

- **`wv done` / `wv ship` learning summary** — close output now shows which learning fields were
  actually saved and the hygiene score: `Learning saved: decision, pattern (hygiene: 3)`. If
  `--learning` was supplied but nothing was stored (jq failure), emits a warning instead. Makes
  silent learning loss immediately visible.

### Fixed

- **`wv ship --learning` silently dropped on jq 1.5 hosts** — `_done_store_learning` used named
  capture groups and case-insensitive regex flags requiring jq 1.6+; on jq 1.5 the entire jq
  invocation failed and the `|| echo "$cur_meta"` fallback silently discarded the learning. Fixed by
  pre-normalising marker case in bash (`sed` lowercase on `Decision:` / `Pattern:` / `Pitfall:`)
  before passing to jq, removing all `"i"` and named-capture patterns from the jq filter. The
  fallback is also hardened: failed complex parse now falls back to `jq '. + {learning: $l}'`
  instead of discarding the learning entirely.
- **`promoted_at` never set on manually created finding nodes** — nodes created via `wv add` /
  `wv update --metadata='{"type":"finding",...}'` never received a `promoted_at` timestamp because
  only the `wv findings promote` code path wrote it. Both `cmd_add` and `cmd_update` now stamp
  `promoted_at` immediately after the row write when `metadata.type = 'finding'` and `promoted_at`
  is not already set. Existing finding nodes are backfilled at DB migration time. (A SQLite trigger
  approach was attempted and rejected: `AFTER UPDATE OF metadata` triggers cause SIGSEGV on SQLite
  3.46 when virtual generated columns and warp session triggers coexist on the same table.)
- **`wv learnings --stale=N` silently ignored** — unknown flags passed to `wv learnings` were
  silently dropped; `--stale` in particular is only meaningful for `wv findings list`. The command
  now rejects `--stale=*` with a helpful redirect (`Did you mean: wv findings list --stale=N ?`) and
  rejects all other unknown `--*` flags with a usage hint.
- **Orphan warning suppressed for `type=finding`** — `validate_on_done` was emitting
  `⚠ Orphan node — no edges` on every finding close. Findings are capture-and-park nodes by design
  (no parent edge is expected); the warning is now suppressed when `metadata.type = 'finding'`.
- **`validate_on_done` verification-evidence check missed new-schema learning** — the implicit
  verification keyword scan only read `metadata.learning` (old schema). New-schema nodes that store
  content under `metadata.decision` / `.pattern` / `.pitfall` would false-positive the "No
  verification evidence" warning. Fixed to concatenate all four learning fields before scanning.
- **`wv learnings --recent=N` returned alphabetical ID order, not recency order** — when multiple
  nodes share the same `updated_at` timestamp (e.g. all shipped in the same second), the secondary
  sort `id ASC` produced alphabetical ordering, causing recently-shipped nodes with later IDs to
  appear last. Changed tiebreaker to `rowid DESC` so insertion order is used when timestamps are
  equal, matching expected recency semantics.

## [1.47.0] - 2026-05-20

### Added

- **`wv search --learning`** — filter search results to nodes that have captured learning content
  (decision, pattern, pitfall, or learning fields in metadata).
- **`wv search --type=TYPE`** — filter search results by `metadata.type` (e.g. `finding`, `task`,
  `epic`).
- **FTS5 learning index (`nodes_learning_fts`)** — `decision`, `pattern`, `pitfall`, and `learning`
  fields in node metadata are now indexed and searchable via `wv search`. Learning matches receive
  2× BM25 weight relative to title matches so captured knowledge surfaces higher in results. The
  index is populated by triggers on insert/update and backfilled at migration time for existing
  nodes.
- **`wv findings list --stale=N`** — filter findings promoted more than N days ago with no fix. Age
  in days is shown inline; findings ≥14 days old are highlighted yellow.
- **Staleness advisory in `context-guard.sh`** — session banner now warns when any finding node has
  been unreviewed for 14+ days (`⚠ N finding(s) unreviewed for 14+ days`).
- **`wv done` source-node advisory** — closing a node now emits a stderr advisory listing any open
  finding nodes whose `metadata.source_node` references the closed node.

### Changed

- **Finding schema** — `violation_type` is now required and enum-validated (8 values:
  `historical:defect`, `upstream:management-gap`, `upstream:logic-bug`, `upstream:schema-drift`,
  `repo:hygiene`, `repo:regression`, `test:gap`, `design:flaw`). The other four fields
  (`root_cause`, `proposed_fix`, `confidence`, `fixable`) are optional-when-present: omitting them
  is valid; supplying them triggers type validation. Both `wv done` and the pre-close verification
  hook enforce the same schema.
- **`wv findings promote`** — promoted findings now record `metadata.promoted_at` (ISO-8601 UTC) for
  use by staleness signals.

### Fixed

- **Home-dir rejection guard** — `wv-config.sh`, `wv-resolve-runtime.sh`, `wv-touched-files.sh`, and
  `weave_quality/__main__.py` now reject `$HOME` / `/root` as `REPO_ROOT` fallbacks. Fixes false
  hook-drift warnings on the dev machine when `wv doctor` was run outside a git repo.
- **`build-release.sh` tilde expansion** — `OUTPUT_DIR` is now expanded via
  `${OUTPUT_DIR/#\~/$HOME}` before use, preventing a stray `~/Projects/weave/` directory inside the
  project root when `--output=~/…` was passed.
- **Health score** — done nodes with pitfall learnings are no longer counted as unaddressed pitfall
  debt or actionable orphans; captured history, not open issues.
- **`wv tree --active`** — now filters `status='active'` only (was `status!='done'`, which let todo
  nodes appear when no active work existed).
- **`wv search --limit N`** — space form now accepted alongside `--limit=N`.
- **`wv doctor`** — consumer repos without a local `scripts/hooks/` directory no longer trigger a
  false hook-drift warning; `wv init-repo --update` keeps hooks current without a source dir to diff
  against.
- **`wv init-repo --update` (copilot-instructions)** — marker-aware surgical update: wraps
  `copilot-instructions.stub.md` in `BEGIN/END WEAVE` markers so repo-specific content is preserved
  across updates. `awk` replaces `sed` in both `CLAUDE.md` and `copilot-instructions.md` marker
  handlers, fixing a `sed 1,/REGEX/` first-line edge case where `BEGIN` at line 1 caused the
  before-block to capture the full file and prepend on every update. Pre-marker stub upgrade now
  detects and replaces the old Weave fingerprint rather than prepending a duplicate heading.
- **Checkpoint commit collapse** — `auto_checkpoint`, `cmd_sync`, and `pre-compact-context.sh` now
  amend the previous commit when it is an unpushed `.weave/`-only checkpoint, reducing per-session
  checkpoint noise from N commits to 1 per push boundary. Guard: subject matches checkpoint pattern
  AND no non-`.weave/` files in HEAD AND HEAD not yet pushed. Note: `session-end-sync.sh` received
  only a partial guard in this release (unpushed check only, missing subject + file-scope guards) —
  fully corrected in v1.48.0.

## [1.46.0] - 2026-05-17

### Added

- **`wv sync --gh --mode=fast|full|repair`** — sync now has three explicit modes:
  - `fast` (default for `wv ship` and session-end): bounded to the focus node plus its parent,
    children, and blockers; skips the broad GH→Weave reconcile phases.
  - `full` (explicit default for plain `wv sync --gh`): exhaustive bidirectional reconcile, backed
    by a structural digest cache (`.weave/sync-digest-cache.json`) that skips body-render work when
    neither the node nor its impacted set has changed.
  - `repair`: resumes an interrupted sync from `.weave/repair-checkpoint.json`. The checkpoint is
    persisted per-node so at most one node is lost on SIGINT/SIGTERM/crash. The handler prints the
    exact resume command (`wv sync --gh --mode=repair`) to stderr before exiting.
- **`wv sync --gh --node=<id>`** — focus a fast-mode sync on a specific node and its impacted set.
- **`wv recover` and `stop-hook` surface repair-mode** — when `.weave/repair-checkpoint.json` is
  present, both surfaces recommend `wv sync --gh --mode=repair` so the next session resumes instead
  of restarting the reconcile.
- **MCP `weave_sync` and `weave_close_session`** now expose `mode` (enum: `fast|full|repair`) and
  `weave_sync` additionally exposes `node` (focus id), forwarded to the underlying `wv sync`.
- **`wv help sync`** — now documents `--mode=` and `--node=` with usage hints per mode.

### Changed

- `wv sync` reports the active mode in its banner and final summary
  (`mode=<m> total=… candidates=… processed=… updated=… skipped=… digest_hits=… [resumed_from=N]`).
- Templates and root agent docs (`templates/WORKFLOW.md`, `templates/AGENTS.md.template`,
  `templates/CLAUDE.md.template`, `templates/copilot-instructions.stub.md`, `AGENTS.md`,
  `CLAUDE.md`, `.github/copilot-instructions.md`) document the new modes; the command-table row for
  `wv sync` lists `--mode=fast|full|repair` and `--node=<id>`.
- MCP tool counts updated: `weave` scope ships 35 tools, `weave-inspect` scope ships 17.

### Fixed

- MCP `vitest` count assertions in `mcp/src/index.test.ts` (all-scope: 33→35, inspect-scope: 15→17)
  to match the actual registered tool set, including `weave_code_search` and `weave_index`.

### Internal

- `scripts/weave_gh/repair_checkpoint.py` — checkpoint persistence layer (schema=1, atomic
  tmp+rename, graceful empty-on-corrupt).
- `scripts/weave_gh/phases.py` — `_traverse_candidates` accepts and writes a `checkpoint` dict,
  marks nodes processed idempotently, and reports `resumed_from` via `SyncStats`.
- `.gitignore` — adds `.weave/repair-checkpoint.json` and `.weave/sync-digest-cache.json`.

## [1.45.2] - 2026-05-15

### Fixed

- **Persistence boundary widening**: empty hot-zone sessions in uninitialized directories no longer
  materialize `.weave/` during `wv sync`, `session-end-sync.sh`, or Claude open/exit lifecycles. The
  persistence boundary now stays hot-zone-only until the graph has non-session state or the repo is
  explicitly initialized, with targeted regressions covering both direct sync and installed-hook
  session end behavior.

## [1.45.1] - 2026-05-13

### Fixed

- **Uninitialized repo opt-in boundary**: `db_init` no longer auto-creates `.weave/` on shared
  read/startup paths. Fresh git repos no longer gain `.weave/` from `wv health --json`, `wv load`,
  `context-guard.sh`, or `session-start-context.sh` until explicitly initialized. Targeted health
  and hook regressions now cover the boundary.

## [1.45.0] - 2026-05-10

### Added

- **Weave-native code search**: shipped `wv index`, `wv search --code`, `weave_index`, and
  `weave_code_search` with hybrid FTS5 + cosine retrieval, graph-enriched result context, and a
  dedicated migration/reference guide in `docs/weave-search.md`.

- **Policy readiness in preflight**: `wv preflight` now exposes structured `policy_readiness`, and
  MCP `weave_preflight` blocks policy-sensitive nodes only when tracked files make attribution and
  quality prerequisites real.

- **Canonical attribution substrate**: runtime resolution, primary-aware attribution helpers, and
  touched-files hook writes to `node_files` now align CLI, hooks, and MCP surfaces around the same
  tracked-file policy/search state.

### Changed

- **Search and preflight diagnostics**: readiness surfaces now report actionable prerequisite state
  in-band instead of collapsing missing setup into silent empty results or generic preflight JSON.

- **Visible MCP/workflow surfaces**: init, status, help, and docs were aligned with the live runtime
  behavior so CLI, MCP, templates, and workflow guidance describe the same operational surfaces.

### Fixed

- **Custom `WV_DB` code search hardening**: explicit `WV_DB` overrides no longer pollute foreign
  SQLite files with graph migrations, and hybrid/vector search now skips model bootstrap when the
  chunk store is malformed or not vector-ready.

- **Release and sync hardening**: ship/source-4 sync state, close-time commit hygiene, and
  source-head-before-tag release discipline now reduce tag/main drift and stale status surfacing.

## [1.44.0] - 2026-05-08

### Added

- **Runtime context policy fitting point**: `context-guard.sh` now writes the computed
  HIGH/MEDIUM/LOW policy to `.weave/.context_policy` on session start. `wv init-repo` generates
  `.weave/runtime.md` with the policy and workflow summary so weave-runtime agents receive
  project-specific instructions without an extra graph call.

- **`wv guide --topic=routing`**: new guide topic documenting phase-based token routing —
  READ_ONLY_TOOLS (cheap/local), EXECUTE_TRIGGERS (expensive), SYNTHESIZE_TRIGGERS, and
  BootstrapMode DISCOVERY vs EXECUTION — so CLI agents cooperate with the PhaseRouter.

- **Single-source context policy**: `_detect_load_policy` in weave-runtime now reads
  `.weave/.context_policy` first (written by `context-guard.sh`) before falling back to heuristics,
  eliminating divergence between the two independent implementations.

## [1.43.1] - 2026-05-08

### Fixed

- **Help/workflow surface alignment**: corrected `wv-init-repo` → `wv init-repo` in post-install
  summary (`install.sh`) and MCP status warning (`wv guide --topic=mcp`); added
  `wv bootstrap --json` as step 1 in `wv guide --topic=workflow`; added `weave_bootstrap` to MCP
  compound-tool listing and removed stale "23 total" tool count. Internal skill docs (dev-guide,
  plan-agent) updated to match.

## [1.43.0] - 2026-05-08

### Added

- **Focused CLI help routing**: `wv help <command>` and `wv <command> --help` now expose direct,
  command-scoped help across core commands and nested families such as `quality`, `findings`, and
  `analyze`.

- **Safer `wv update` metadata inputs**: `--metadata <json>` and `--metadata-file <path>` now
  support split-form and file-backed metadata merges with clearer diagnostics for invalid JSON or
  missing arguments.

### Changed

- **Canonical workflow/help surfaces aligned**: templates, hooks, MCP guidance, repo docs, and agent
  instructions now consistently present `wv init-repo` as the canonical bootstrap entrypoint, while
  retaining `wv-init-repo` as a compatibility wrapper.

- **MCP toolchain modernised**: MCP tests now run on Vitest, and the shipped public release manifest
  includes `mcp/vitest.config.ts` instead of the removed Jest config.

- **Multi-developer status docs corrected**: public and internal docs now reflect that delta merge
  (v1.24.0), CAS claim enforcement (v1.26.0), and `wv unlink` (v1.37.0) are shipped, while per-field
  merge and contradiction tooling remain future work.

### Fixed

- **Remote installer parity**: `install.sh` now fetches the same journal library, Claude hooks,
  skills, and Copilot stub assets in remote-download mode as it does from a local source checkout.

- **Help flag handling**: command-specific `--help` no longer falls through into positional
  validation errors for commands like `show` and `link`.

## [1.42.0] - 2026-04-19

### Added

- **`wv bootstrap --json`**: single composite command replacing the 8-call session-start sequence
  (status + list_active + show + context + ready + learnings). Returns status counts, active node
  with full context pack, ready work, recent learnings, and breadcrumb in one JSON blob. Covered by
  run-cache (45s TTL, sentinel invalidation on writes). Measured: 3,346 bytes vs 6,325 bytes (8
  calls) — 47% data reduction, 7 fewer process spawns per session start.

- **`wv update --echo`**: returns the updated node as inline JSON, eliminating the separate
  `wv show` call that callers used to verify writes. Cuts the update-verify round-trip from 2 calls
  to 1.

- **`wv touch --intent=TEXT`**: fire-and-forget metadata write with zero stdout. Designed for
  per-turn intent tracking — no process output means no token spend. Falls back to `wv update`
  silently when the node does not exist.

- **MCP `weave_bootstrap` and `weave_touch`**: MCP tool equivalents of the two new primitives.
  `weave_bootstrap` accepts `scope=session|lite|inspect`. `weave_touch` is available in
  `scope=graph`. Non-runtime MCP clients (Copilot, SDK agents) get the same token savings without
  WvClient changes.

- **Run-cache (Category F)**: amortises expensive read commands across agent turns. `wv context`,
  `wv show`, `wv list`, `wv ready`, `wv learnings`, `wv status`, and `wv bootstrap` are all cached
  with a 45s TTL. Write commands (`wv work`, `wv done`, `wv update`, `wv add`, `wv touch`) act as
  sentinels and invalidate the cache. Expected reduction: ~60% of read subprocess calls in
  multi-turn sessions.

- **Phase-aware enforcement (S6)**: session phase sentinel at `$WV_HOT_ZONE/.session_phase`
  eliminates the `WV_SKIP_PRECOMMIT=1` workaround in the normal `wv done -> git commit` flow. Three
  phases:
  - `discover` (session start) — edits allowed without active node; hooks skip the `wv list`
    subprocess entirely.
  - `execute` (after `wv work`) — active node required; current enforcement behaviour.
  - `closing` (after `wv done`) — commits allowed for recording the closed work. Written by
    `session-start-context.sh`, `cmd_work`, and `cmd_done`. Read by `pre-action.sh` and
    `pre-commit-weave.sh`. Missing sentinel falls back to `execute` (safe default).

### Fixed

- **selftest cascade**: `cmd_done` in selftest now passes `--skip-verification` to avoid the
  learning-required gate firing on synthetic test nodes, fixing 2/10 cascade failures.

## [1.41.3] - 2026-04-19

### Security

- **M1 — SQL injection in `wv add --status=`**: `cmd_add` now calls `validate_status` before the
  `INSERT`, matching `cmd_update`. Without the guard, a crafted `--status=` value could splice past
  the status literal and rewrite sibling columns.
- **M2 — SQL injection in `--remove-key=`**: a new `validate_metadata_key` helper
  (`^[A-Za-z_][A-Za-z0-9_.-]*$`) blocks injection payloads at both sinks (`cmd_update` and
  `cmd_bulk_update`). Keys splice into SQLite JSON-path literals without escape-doubling, so
  enum/regex validation was mandatory.
- **L1+L5 — hot zone hardening**: `/tmp/weave` fallback is now `/tmp/weave-$(id -u)` (eliminates
  shared-parent races on multi-user hosts). `db_init` and `cmd_load` set `umask 077` around mkdir
  and `chmod 700` the hot zone; `db_init` `chmod 600` on `brain.db`. `/dev/shm` default unchanged
  (its parent is already 1777 and we create per-repo subdir 0700).
- **L2 — explicit `usedforsecurity=False`** on `hashlib.md5` in `weave_gh.data` with inline comment.
  The hash is a filesystem namespace, not a security primitive; the flag documents intent and
  silences bandit B324.
- **L4 — bash-dedup liveness glob scoped to own UID**: `/tmp/claude-$(id -u)/…` so cross-user
  TASK_ID collisions cannot leak another user's output file.

### Tests

- `test_add_status_validation` and `test_remove_key_validation` added to `test-stress.sh`. Cover
  banana status, quote-breakout payload, `DROP TABLE` via `--remove-key`, and positive enum/regex
  coverage.

### Deferred

- **M3 — signed install manifest**: proposal-scope (GPG vs cosign + build-release.sh changes).


## [1.41.2] - 2026-04-19

### Fixed

- **Hygiene score penalises finding nodes**: the C1 session-summary rubric counted every node
  created in the session as a work item; bulk `wv findings promote --apply` therefore dragged the
  score from 100 to 65 because 168 new finding nodes had no `done_criteria`. Findings are audit
  records, not tasks, and never carry `done_criteria`. `_hygiene_score` now excludes
  `type == finding` from both the numerator and denominator of the criteria component (alongside the
  existing `session_history` exclusion). Surfaced during the v1.41.1 consolidation pass.
- **`wv findings list` unbounded output**: the list command emitted every finding with no default
  cap. After historical-pitfall promotion the same command that previously produced ~3 KB of output
  grew to ~26 KB (203 findings), re-introducing the exact token-spend class `wv learnings --cap` was
  designed to prevent. Default is now `--limit=20`; `--limit=N` and `--all` override. Footer reports
  "N of M finding(s) shown" when truncated.

### Docs

- CHANGELOG + CLI help updated for the new `--limit` / `--all` flags on `wv findings list`.

## [1.41.1] - 2026-04-19

### Fixed

- **`wv findings promote` edge semantic**: the `--apply` path emitted a `references` edge from the
  new finding to its source pitfall, but `wv audit-pitfalls` only counts
  `addresses | implements | supersedes` as resolvers. Promoted findings therefore never flipped
  their source pitfalls to `[ADDRESSED]` — the consolidation loop between the two features was
  silently broken. The edge type is now `addresses`; the finding-to-parent edge remains `references`
  (the parent is a grouping epic, not the thing being addressed). Surfaced and backfilled during a
  bulk consolidation run (229 pitfalls promoted + 29-row backfill of pre-existing edges).
- **`wv sync --gh` floods on bulk finding promotion**: every node type went through the same GH sync
  door, so `wv findings promote --apply` at scale created one GitHub issue per finding — ~180 issues
  in a single batch during consolidation. `sync_weave_to_github` now extends its existing skip
  predicate (`is_test`, `no_sync`) to include `node_type == "finding"`. Findings are internal audit
  records and should stay inside the graph. Regression test in
  `tests/test_weave_gh_phases.py::test_finding_nodes_are_skipped`.
- **`.claude/scheduled_tasks.lock` tracked in git**: the Claude Code scheduler creates and removes
  this transient lock file each session; it was committed once and every session opened with a
  `D.claude/scheduled_tasks.lock` entry in `git status`, masking real changes. Added to
  `.gitignore` (plus `.claude/*.lock` glob) and removed from the index via `git rm --cached`.

### Docs

- **`INDEX-PROPOSALS.md` drift**: `PROPOSAL-wv-active-counterweight.md` (Sprint A+B1+C1 shipped in
  v1.41.0) and `PROPOSAL-wv-post-split-hardening.md` were on disk but unlisted; added both under
  Active proposals with current lifecycle state. Baseline date bumped.
- **`wv --help` top-level findings line**: advertised only `(promote)`; the subcommand supports
  `list` too. Fixed to `(list, promote)`.
- **`wv findings promote --help`**: now notes that the finding → source_pitfall edge uses
  `addresses` so `wv audit-pitfalls` marks the source as `[ADDRESSED]`.

## [1.41.0] - 2026-04-18

### Added

- **Active counter-weight Sprint A — stale-active marker (A1)**: `wv ready` and `wv status` now flag
  any active node older than the staleness threshold (`WV_STALE_HOURS`, default 4h) with a
  `[stale Nh]` indicator so callers notice abandoned work before claiming new tasks.
- **Active counter-weight Sprint A — wv-call budget tally (A2)**: per-session `wv` invocations are
  tallied in `/dev/shm/weave/<hash>/session-budget.json`; one-shot advisory printed via the
  `bash-dedup-post.sh` PostToolUse hook when a budget threshold is crossed.
- **Active counter-weight Sprint A — contradiction detection (A3)**: `wv done --learning=` now runs
  an FTS5 overlap probe against prior learnings on the same node and flags polarity contradictions
  (positive vs negative verbs) by writing `learning_contradiction_noted` to metadata. Hard blocks
  are reserved for invariant violations; this is an advisory only.
- **Active counter-weight Sprint B1 — relevance boost in `wv ready`**: a new
  `.claude/hooks/wv-touched-files.sh` PostToolUse hook records each Edit/Write/NotebookEdit target
  into a per-session ring at `/dev/shm/weave/<hash>/recent-edits.txt` (cap 20, FIFO dedup) and into
  the active node's `metadata.touched_files` (cap 50, dedup). `wv ready` re-ranks rows whose
  `touched_files` intersect the ring and shows a `[touched N]` marker on boosted entries. Falls back
  to `created_at` ordering when the ring is empty or unreadable.
- **Active counter-weight Sprint C1 — per-session hygiene score in `wv session-summary`**: 0-100
  rubric across four 25-pt components (edit/active discipline, criteria coverage, learning coverage,
  call-discipline budget). Edit instrumentation lives in `pre-action.sh`. Trend history persists in
  a singleton graph node (`metadata.type=session_history`, capped at 20 entries) that is excluded
  from snapshot/delta queries.

### Fixed

- **`post-edit-lint.sh` honours `tool_response.success=false`**: replaced the
  `jq -r '.tool_response.success // true'` pattern (jq's alternative operator collapses explicit
  boolean false to its RHS) with `jq -e '.tool_response.success == false'`. Failing tool calls no
  longer trigger a lint pass on a never-written file. Same fix applied in `wv-touched-files.sh`.

## [1.40.1] - 2026-04-18

### Fixed

- **Agentic overlap suppression parity**: `WV_NONINTERACTIVE=1` now skips the FTS5 learning-overlap
  check entirely instead of only suppressing the tty prompt. This prevents unattended callers from
  emitting advisory `learning_overlap_noted` metadata for intentionally repetitive structured
  learnings.
- **`wv ship --no-overlap-check` parity**: `cmd_ship` now accepts and forwards `--no-overlap-check`
  to `cmd_done`, matching `wv done`.
- **MCP `weave_ship` parity**: added `no_overlap_check` to the MCP schema and command builder so MCP
  callers have the same overlap-control surface as `weave_done`.
- **Runtime archive hint portability**: `pre-action.sh` no longer hardcodes
  `~/Projects/weave-runtime`; it uses `WV_RUNTIME_REPO` when set and otherwise emits a repo-agnostic
  guidance message.

## [1.40.0] - 2026-04-17

### Fixed

- **`wv update --metadata` silent overwrite (H1.T1+T2)**: `cmd_update` merged new metadata into
  existing via a jq roundtrip with a trailing `|| echo "$metadata"` fallback. Any jq failure
  silently replaced the stored metadata with only the new keys, wiping `done_criteria`,
  `risk_level`, and siblings. Ported the merge to `json_patch(COALESCE(metadata, '{}'), '<new>')` in
  a single UPDATE — atomic, SQL-native, no silent fallback. Matches the `--remove-key` path (already
  `json_remove`-based). Regression tests cover empty→new, preserve+add, apostrophe round-trip,
  unicode + literal `||`, invalid-JSON rejection, and immediate update-then-claim readiness.
- **`auto_checkpoint` + `wv sync` commit hijack (H1.T3)**: both paths ran `git add.weave/` then
  committed whatever was staged — absorbing user-prestaged files into a generic
  `chore(weave): auto-checkpoint HH:MM` or `sync state` commit, silently rewriting named work. Both
  paths now enumerate staged files first and skip the commit (with a stderr warning) if any
  non-`.weave/` paths are present. Overridable via `WV_CHECKPOINT_ALL=1`. Regression tests in
  `tests/test-data.sh`.
- **`wv add --risks=medium|high|critical` missing `risks` key**: only `--risks=none|low` seeded both
  `risk_level` and `risks: []`; higher levels set just `risk_level`, so the pre-claim hook's
  `has("risks")` check emitted the "Consider /pre-mortem" advisory even when risk had been
  explicitly classified at add-time. Unified all five levels to seed both keys. Regression test in
  `test-core.sh` asserts both keys for every level. Surfaced during H1 sprint claim friction.
- **`pre-claim-skills.sh` false-block on unreadable state**: the hook read the target node via
  `wv show --json` and interpreted a jq failure on the empty result as "done_criteria missing",
  soft-denying the claim with `Run /ship-it before claiming wv-<id> () — done_criteria not set`
  (note the empty parens — the read returned no rows so NODE_TEXT was blank and HAS_SHIP_IT
  defaulted to false). The read hits transient windows (auto_sync rewriting state, DB lock
  contention, hot-zone hash mismatch between parent shell and hook process) that return `[]` on
  nodes that exist and are properly planned. Retrying passes immediately; each false block costs one
  model turn. Hook now fails open: if `wv show` returns zero rows, exit 0 silently and let `wv work`
  itself surface the clearer "node not found" error. Regression test in `test-hooks.sh` covers an
  unknown-ID payload. (H1.T1b).
- **`bash-dedup.sh` false-positive classification**: the hook classified long-running commands via
  substring regex over the raw `tool_input.command`. Anchors like
  `(^|[;[:space:]])make[[:space:]]+check` matched real invocations but also matched inside quoted
  argument text — e.g. a `wv done --learning="... ran make check 572/572..."` would acquire the
  `make-build` lock and hard-block the next unrelated command for up to 10 minutes. Hook now strips
  `"..."` / `'...'` regions before classifying, so structural anchors see only outer shell syntax.
  Npm/poetry patterns gained the same command-start anchor the others already had. Regression table
  in `test-hooks.sh` covers make/git push/pytest/npm keywords inside quoted `--learning` values plus
  a true-positive check that a bare `make check` still acquires the lock. Discovered when the hook
  blocked the `wv done` for the `--risks=` fix above.
- **`pre-action.sh` runtime guard bypass via symlinks (H2.T1)**: the hook blocked edits to paths
  containing literal `runtime/` or `archive/runtime/` but resolved the path with simple string
  matching. A symlink or `..` traversal could bypass the guard. Replaced with `realpath -m` +
  canonical prefix check so the block applies regardless of how the path is spelled. JSON schema
  audit test added to verify every hook event type in `test-hooks.sh`.

### Changed

- **Runtime archived to `archive/runtime/` (H3.T1)**: moved 88 source files and 39 test files from
  `runtime/` to `archive/runtime/` and `archive/tests/` respectively. Removed the `runtime`
  dependency group from `pyproject.toml` (anthropic, rich, textual, openai, keyring). Retargeted
  pyright, mypy, and pytest config to exclude `archive/`. Updated `build-release.sh` strip paths,
  `docs/ARCHITECTURE.md` §2 (marked archived), and `README.md` boundaries section. Bandit retargeted
  to `scripts/weave_gh` + `scripts/weave_quality` with `--skip B108,B324,B608` for intentional false
  positives (tmpfs paths, non-security MD5, internal SQL formatting). Runtime continues development
  in the separate `weave-runtime` repo.

## [1.39.0] - 2026-04-16

### Added

- **Runtime middleware protocol**: `MiddlewareProtocol` base class with `before_query`,
  `after_query`, `on_tool_result`, `on_turn_end` lifecycle hooks and `StackExecutor` for ordered
  dispatch.
- **Five middleware extractions (S3)**: `EnforcementMiddleware`, `CompactionMiddleware`,
  `BudgetMiddleware`, `WeaveGraphMiddleware`, `LintAfterEditMiddleware` /
  `SearchEfficiencyMiddleware` — all previously inline hooks now composable and independently
  testable.
- **Test parity gate**: Full parity audit of bash hook → middleware behavior, with gap-fill tests
  for error handling, seeding guard, after_query no-op, and aged_results propagation.

### Fixed

- **Learnings junk filter**: Structured-only nodes (containing `decision:`/`pattern:`/`pitfall:` but
  no raw `learning` key) no longer filtered as junk.
- **FTS5 search**: Multi-word queries now use OR-token matching instead of phrase match, improving
  recall for `wv search` and `_related_learnings`.

### Changed

- **Runtime split epic**: Updated done criteria — deferred `runtime/` removal behind stabilisation
  gate (3 clean standalone sessions). Crash-recovery metadata patched (6 missing commits added).

## [1.38.1] - 2026-04-16

### Fixed

- **Learnings duplicate storage**: Structured learnings (`decision:`/`pattern:`/`pitfall:`) no
  longer store a redundant raw `learning` key — halves token cost in JSON output.
- **MCP merge logic**: When both raw learning and typed params are provided via MCP tools
  (`weave_done`/`weave_batch_done`/`weave_ship`), raw learning is now appended as context instead of
  silently dropped.
- **Empty pipe segments**: Consecutive pipes (`| | |`) in learning strings are collapsed via
  `until()` loop before splitting, and all segments are trimmed — prevents ghost entries in parsed
  metadata.

## [1.38.0] - 2026-04-15

### Added

- **WV_CALL_LOG instrumentation**: Set `export WV_CALL_LOG=~/.local/share/weave/wv_calls.jsonl` to
  record every `wv` invocation with `{ts, cmd, stdout_bytes, stderr_bytes, elapsed_ms}`. Zero
  overhead when unset. Works alongside the Python runtime path (identical JSONL schema).
- **`wv analyze sessions --call-stats`**: Reads the call log and ranks commands by output volume —
  surfaces which `wv` commands inject the most tokens into agent context.
- **WEAVE.md §8.3 Call Instrumentation**: Public docs covering enable/log format/analyze usage.
- **`tests/test-analyze.sh`**: 7-test regression suite for `wv analyze sessions`.

### Fixed

- **Context cache invalidation**: `invalidate_context_cache` deleted `${id}.json` but cache files
  are named `${id}-${mode}.json` — stale cache was served after `wv link` within the same second,
  causing `wv context` to return an empty finding block.
- **`wv show` in discover mode**: `Intent:` field now renders in `discover` (non-tty/agentic) mode,
  not only in `execute`/full mode.
- **Stop-hook test**: Updated for auto-push behavior (uses a deletable bare remote so push fails and
  hard-block path is exercised).
- **Context-guard test**: Relaxed assertion from `policy:` to `policy` — agent path emits
  `policy=HIGH` (no colon), tty path emits `policy: HIGH`.
- **Multi-agent replay test**: Manifest-skip behavior was removed in v1.20.0; test now asserts
  idempotency (node count unchanged after double-load) rather than absence of "Replayed" message.
- **`test-init-repo.sh` counter**: Two `else` branches incremented `TESTS_PASSED` without
  `TESTS_RUN`, producing a spurious 58/57 summary; both now balanced.

## [1.37.4] - 2026-04-14

### Fixed

- bash-dedup: two-phase lock (pending/running) prevents orphaned locks when a PreToolUse hook
  hard-blocks a tool call (hooks run in parallel; PostToolUse never fires for blocked tools)
- bash-dedup: background task locks now auto-clear via fuser/lsof when the subprocess completes,
  using `tool_response.backgroundTaskId` to locate the task output file — no manual lock clearing or
  TTL wait required
- bash-dedup: PostToolUse clears ALL matching lock keys (not just first match) for compound commands
  matching multiple patterns
- bash-dedup: SessionStart hook clears all stale locks from prior sessions
- bash-dedup: reduced TTLs to realistic values (wv-sync 300→60s, git-push 120→60s, make-build
  1800→600s, pytest 300→120s)

## [1.37.3] - 2026-04-14

### Fixed

- **`install.sh` registers `PostToolUseFailure` for bash-dedup**: Commands that exit non-zero (e.g.
  `git push` with a bad upstream, exit 128) now clear the dedup lock. Previously the lock persisted
  until the 120s TTL, blocking all retry attempts with "Duplicate command blocked".

---

## [1.37.2] - 2026-04-14

### Fixed

- **`wv init-repo --update` now syncs `.claude/hooks/`**: Consumer repos with a local hooks
  directory are brought up to date from `~/.config/weave/hooks/` in a single command. Reports how
  many hooks were updated vs already current.
- **`wv doctor` hook drift message**: Now says `run: wv init-repo --update` instead of
  `run./install.sh` — the correct command for repos without `install.sh` on PATH.
- **`wv doctor --repair` handles hook drift**: Copies stale hooks from `~/.config/weave/hooks/` into
  the project `.claude/hooks/` (pull direction). Clears drift in one step.

---

## [1.37.1] - 2026-04-14

### Fixed

- **`wv show --json-v2` mode trimming**: `current_intent` (session bootstrap blob, ~600 bytes) is
  now stripped from metadata in bootstrap and discover modes. Execute/full mode retains it. Non-tty
  and `WV_AGENT=1` callers automatically get the trimmed output without `--mode=` flag.
- **`wv doctor` FTS5 integrity check**: `PRAGMA integrity_check` does not probe FTS5 shadow tables,
  so a corrupt FTS5 index could block all node writes while doctor reported healthy. Added a
  dedicated FTS5 probe (`integrity-check` special command) as check 10b. Added `wv doctor --repair`
  flag to auto-rebuild the index when corruption is detected.

---

## [1.37.0] - 2026-04-13

### Added

- **`wv unlink` command**: Removes a directed edge between two nodes
  (`wv unlink <from> <to> --type=<type>`). Validates the edge exists before deletion and evicts the
  context cache for both nodes on success.
- **`wv done --no-gh` flag**: Suppresses GitHub issue close when completing a node. Useful for
  recovery/cleanup nodes that track internal work without a corresponding GH issue.
- **`wv learnings` mode-aware output bounds**: Bootstrap callers default to 5 learnings; agent/MCP
  callers (`WV_AGENT=1`) default to 10. Explicit `--recent=N` always wins. Grep/category filtering
  applied before the cap. MCP `weave_learnings` inherits the agent cap via `WV_AGENT=1` — VS Code
  Copilot gets bounded output without adapter changes.
- **MCP `--instrument` flag**: Records per-tool payload bytes and emits total/avg/max summary on
  stderr. Useful for diagnosing which MCP tool calls dominate token usage.

### Fixed

- **`wv load` delta replay**: Removed manifest-based skip list. All non-pruned deltas are now always
  replayed on load. Fixes stale-node resurrection and test-node leakage caused by the manifest
  drifting from actual applied state. Delta replay is idempotent by design.
- **`wv show` non-tty exit code**: `wv show` was returning exit 1 when a node had no learning, even
  when output was otherwise valid. Now exits 0 on success regardless of learning presence.
- **`runtime/agent.py`: wire `call_log_path`**: `WvClient` now constructed with
  `call_log_path=~/.local/share/weave/wv_calls.jsonl` so `wv analyze sessions --call-stats` has data
  after an agent run.
- **Pre-claim hook: collapse 4 `wv show` calls to 1**: `pre-claim-skills.sh` now captures node JSON
  once and extracts `text`, `done_criteria`, and `risks` from the single result. Removes dead
  `NODE_TYPE` variable that was read but never used.
- **Pre-claim hook: `local` outside function (SC2168)**: Removed `local` keyword from two variables
  in the top-level script body of `pre-claim-skills.sh`.

## [1.36.0] - 2026-04-12

### Added

- **`wv compact` command**: Merges accumulated delta files into a single compacted snapshot.
  Includes coordination gate that refuses to compact while other agents hold active claims
  (`--force` to override). Emits warnings about agent sync state before proceeding.

### Fixed

- **Multi-agent: sqlite3 busy_timeout on all delta operations**: All 6 sqlite3 calls in
  `wv-delta.sh` now use `-cmd ".timeout 5000"` to retry under WAL contention instead of failing
  immediately with SQLITE_BUSY.
- **Multi-agent: prune SQL injection prevention**: All node ID interpolations in `cmd_prune` now use
  `sql_escape()` to prevent SQL injection from malformed node IDs.
- **Multi-agent: atomic prune transaction**: Prune DELETEs and `_warp_changes` reset are now wrapped
  in a single `BEGIN TRANSACTION..COMMIT` — no window for a concurrent `auto_sync` to snapshot
  partial deletes as a delta.
- **Multi-agent: compact coordination gate**: `wv compact` refuses to run while agents hold active
  claimed nodes, preventing silent delta loss for agents that haven't replayed yet.
- **Multi-agent: bootstrap staleness guard**: `SharedBootstrap.is_stale` property (5-minute
  `MAX_AGE`) replaces hardcoded 900s check in agent bootstrap resolution. Stale snapshots fall
  through to fresh graph queries.
- **Multi-agent: manifest mtime subsecond guard**: Changed manifest freshness comparison from `-ge`
  to `-gt` so same-second ties (second-granularity `stat -c %Y`) force safe full delta replay
  instead of trusting a potentially stale manifest.
- **Multi-agent: hive hot-zone cleanup**: Orchestrator now cleans up parent `/tmp/weave-hive/`
  directory after all agents complete (safe `rmdir` — only succeeds when empty).
- **Multi-agent: removed dead `wv_delta_apply` function**: Unreachable function reserved for Sprint
  2 removed from `wv-delta.sh`.
- **Auto-compact removed from `auto_sync`**: Automatic compaction during sync was unsafe in
  multi-agent topologies — agents that haven't replayed yet would permanently lose compacted deltas.

### Tests

- 15 new delta unit tests (`tests/test-delta-unit.sh`) covering changeset generation, alias conflict
  resolution, timestamp propagation, fail-fast replay, and reset.
- All 12 multi-agent integration tests passing.
- 572 Python tests passing.

### Docs

- Audited and corrected `docs/INDEX-PROPOSALS.md` — 39 shipped/superseded documents archived to
  `archive/docs/`. Only multi-agent proposal remains active.
- Updated `docs/ARCHITECTURE.md` with 4 completed subsections (multi-agent delta merge, TUI
  lifecycle, workflow hardening, session continuity bridge).

## [1.35.1] - 2026-04-11

### Fixed

- **Multi-agent delta replay — manifest written before replay**: Applied-deltas manifest
  (`.weave/.applied_deltas`) was updated before the sqlite3 replay call. A silent failure left
  deltas marked as applied but never replayed, causing permanent data loss on the receiving agent.
  Manifest is now written only after a successful replay.
- **Multi-agent delta replay — fail-fast mode**: Replay errors were swallowed
  (`2>/dev/null || warn`) and sqlite3 exited 0 after partial execution. Now uses `.bail on` so the
  first failing statement aborts sqlite3 non-zero, rolls back the transaction, and causes `cmd_load`
  to return non-zero without updating the manifest.
- **Multi-agent delta replay — INSERT OR REPLACE alias collision**: `wv_delta_changeset` emitted
  `INSERT OR REPLACE INTO nodes(...)` for delta INSERTs. SQLite OR REPLACE deletes the conflicting
  row before inserting, so a node sharing a unique alias with the incoming row would be silently
  deleted. Changed to `INSERT INTO... ON CONFLICT(id) DO UPDATE` targeting the primary key only.
- **Multi-agent delta replay — FTS shadow table filter removed**: Line-based grep filter for
  `nodes_fts`/`sqlite_sequence` rows was unsafe against multi-line SQL literals. Removed —
  `wv_delta_changeset` never emits FTS shadow tables so the filter was dead code and a risk.
- **Delta filename uniqueness**: Filenames used `<epoch_s>-<agent_id>.sql` with one-second
  resolution; two concurrent sync cycles on the same host overwrote each other. Now includes PID and
  random component: `<epoch_s>-<agent_id>-<pid>-<rand>.sql`.
- **Trigger schema upgrade**: `wv_delta_init` used `CREATE TRIGGER IF NOT EXISTS`, silently skipping
  trigger recreations after payload schema changes. Now drops and recreates all 6 triggers so
  existing DBs pick up new payload fields (`created_at`, `updated_at`).
- **Timestamp propagation in delta payloads**: Node INSERT and UPDATE triggers now capture
  `created_at` and `updated_at`. Changeset emits timestamps in INSERT statements and tracks
  `updated_at` changes in UPDATE diffs, preserving node chronology on receiving agents.

### Tests

- Multi-agent tests: all 12 passing (730/730 bash tests clean).

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

- **`wv sync` state.sql size**: FTS5 index was included in `sqlite3.dump` output, inflating
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
  duplicate long-running Bash commands (make check, wv sync --gh, git push,./install.sh, npm,
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
  intervening `git add.weave/ && git commit` left graph state uncommitted after push — causing the
  stop-hook to re-fire on every subsequent response.
- **`stop-check.sh`**: blocking message now instructs the full 3-step sequence
  (`wv sync --gh && git add.weave/ && git commit → git push`) when `.weave/` is dirty; AHEAD-only
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
  v1.24.0). Root cause: `$([ cond ] && echo...)` inside assignment returns exit 1 under `set -e`,
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
- **`wv-init-repo`.gitattributes** — Uses marker block with full template; strips orphaned comments
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
- **Bash CC parser: one-liner functions** — `func() {...; }` style definitions had no standalone
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
- **build-release.sh** — CLAUDE.md, AGENTS.md, and.github/copilot-instructions.md all generated
  from templates at build time (no longer ships memory-system-specific copies).

## [1.17.0] - 2026-03-06

### Added

- **VS Code hook enforcement** — hook scripts now handle both Claude Code tool names
  (`Edit`/`Write`/`Bash`) and VS Code tool names (`create_file`/`replace_string_in_file`/
  `run_in_terminal`). The `SHOULD_CHECK` filter in `pre-action.sh` and `tool_input` property
  extraction (`.file_path //.filePath`) cover both ecosystems. VS Code ignores matchers (all hooks
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

- **Sync data loss prevention**: All 3 `sqlite3.dump` sites (auto_sync, cmd_sync, post-GH re-dump)
  now use `.timeout 5000` to wait for write locks instead of returning empty. `cmd_sync` also guards
  against empty dumps before overwriting `state.sql`.
- **Context pitfall scoping**: Replaced blocks-only ancestry CTE with bidirectional
  neighborhood walk across all edge types (depth-limited to 4 hops). Pitfalls linked via
  `implements`/`addresses` edges are now included in context packs.
- **Health check false penalty**: Added `blocked-external` to allowed status set so
  legitimate nodes don't trigger health score deductions.
- **Context ancestors diamond dedup**: Changed `cmd_context` ancestors CTE from
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
  node metadata as `commits: ["abc1234",...]`. When a task has a parent epic (via `implements`
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
- **ShellCheck SC2015**: `_aggregate_epic_commits` call now uses `if/fi` instead of `&&... || true`
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
  settings.local.json,.vscode/mcp.json). Use `--force` to overwrite everything.
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
