#!/usr/bin/env node
/**
 * Weave MCP Server
 *
 * Exposes Weave CLI graph operations as MCP tools for AI assistants.
 * Uses stdio transport for compatibility with all MCP clients.
 *
 * Tools:
 *   weave_search   - Full-text search across nodes
 *   weave_add      - Create a new node
 *   weave_done     - Mark node complete
 *   weave_batch_done - Close multiple nodes at once
 *   weave_context  - Get Context Pack for a node
 *   weave_list     - List nodes with filters
 *   weave_link     - Create semantic edges
 *   weave_unlink   - Remove a semantic edge between two nodes
 *   weave_block    - Create a blocking edge (shorthand for weave_link with type=blocks)
 *   weave_unarchive - Restore a pruned node from .weave/archive/ to the live graph
 *   weave_status   - Compact status summary
 *   weave_ready    - List unblocked nodes ready to claim
 *   weave_impact   - Blast-radius analysis from one or more seed nodes
 *   weave_query    - Flexible predicate query over nodes
 *   weave_health   - Graph health check
 *   weave_quick    - Quick-add and start working
 *   weave_work     - Claim a node to work on
 *   weave_ship     - Complete + sync in one step; pending Git sync is surfaced separately
 *   weave_overview - Session start overview (status + digest + trails)
 *   weave_bootstrap - Single-call session context (status + context + ready + learnings)
 *   weave_show     - Single-node detail view
 *   weave_touch   - Fire-and-forget metadata write (zero token cost)
 *   weave_delete   - Permanently remove a node (requires force)
 *   weave_quality_scan - Scan codebase for quality metrics
 *   weave_quality_hotspots - Ranked hotspot report
 *   weave_quality_diff - Delta report vs previous scan
 *   weave_quality_functions - Per-function CC report with dispatch tagging
 *   weave_structural_search - Find code by structural AST pattern (requires ast-grep)
 *   weave_code_search - Hybrid code search over indexed chunks (FTS5 BM25 + cosine RRF)
 *   weave_index     - Index code files into brain.db for semantic search
 */

import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { CallToolRequestSchema, ListToolsRequestSchema, Tool } from "@modelcontextprotocol/sdk/types.js";
import { execFileSync, spawnSync } from "child_process";
import { accessSync, appendFileSync, constants, existsSync, mkdirSync, readFileSync, statSync } from "fs";
import { hostname, userInfo } from "os";
import { dirname, join, resolve } from "path";

// --- Scope definitions ---
// Each scope exposes a subset of tools for context-silo'd subagents.
// "all" (default) exposes everything for backward compatibility.
export type Scope = "graph" | "session" | "inspect" | "lite" | "all";

export const SCOPE_TOOLS: Record<Exclude<Scope, "all">, string[]> = {
  graph: [
    "weave_add",
    "weave_link",
    "weave_unlink",
    "weave_block",
    "weave_unarchive",
    "weave_done",
    "weave_batch_done",
    "weave_list",
    "weave_resolve",
    "weave_update",
    "weave_touch",
    "weave_record_edit",
    "weave_delete",
  ],
  session: [
    "weave_work",
    "weave_ready",
    "weave_ship",
    "weave_recover",
    "weave_quick",
    "weave_overview",
    "weave_bootstrap",
    "weave_close_session",
    "weave_trails",
    "weave_breadcrumbs",
    "weave_plan",
    "weave_edit_guard",
  ],
  lite: [
    "weave_overview",
    "weave_bootstrap",
    "weave_guide",
    "weave_edit_guard",
    "weave_status",
    "weave_work",
    "weave_done",
  ],
  inspect: [
    "weave_context",
    "weave_search",
    "weave_query",
    "weave_status",
    "weave_ready",
    "weave_impact",
    "weave_health",
    "weave_preflight",
    "weave_bootstrap",
    "weave_sync",
    "weave_tree",
    "weave_learnings",
    "weave_guide",
    "weave_show",
    "weave_quality_scan",
    "weave_quality_hotspots",
    "weave_quality_diff",
    "weave_quality_functions",
    "weave_structural_search",
    "weave_quality_patterns",
    "weave_code_search",
    "weave_index",
  ],
};

// Stable startup error taxonomy. Each code maps to a fixed exit status so
// callers (health checks, process supervisors) can branch on the number
// without parsing message text; the message itself is still carried for
// humans via STARTUP_ERROR.detail / --health-check's "detail" field.
export type StartupErrorCode = "invalid_scope" | "wv_not_found" | "bad_project_root" | "startup_failure";

export const STARTUP_EXIT_CODES: Record<StartupErrorCode, number> = {
  invalid_scope: 2,
  wv_not_found: 3,
  bad_project_root: 4,
  startup_failure: 1,
};

let STARTUP_ERROR: { code: StartupErrorCode; message: string } | null = null;

function failStartup(code: StartupErrorCode, message: string): void {
  STARTUP_ERROR = STARTUP_ERROR || { code, message };
  if (!HEALTH_CHECK) {
    console.error(message);
    process.exit(STARTUP_EXIT_CODES[code]);
  }
}

const HEALTH_CHECK = process.argv.includes("--health-check");

function parseScope(): Scope {
  const arg = process.argv.find((a) => a.startsWith("--scope="));
  if (!arg) return "all";
  const value = arg.split("=")[1] as Scope;
  if (!["graph", "session", "inspect", "lite", "all"].includes(value)) {
    failStartup("invalid_scope", `Invalid scope "${value}". Valid: graph, session, inspect, lite, all`);
    return "all"; // health-check mode: keep resolving remaining fields for the report
  }
  return value;
}

const ACTIVE_SCOPE = parseScope();

// Find wv CLI - check common locations. Exported so tests can verify candidate
// resolution without spawning a subprocess (the real dev-mode fallback below
// always resolves inside this repo, so a full end-to-end "not found" spawn
// can't be simulated without deleting/moving files).
export function findWvCandidates(home: string | undefined, moduleDir: string): string[] {
  return [
    process.env.WV_PATH,
    home ? `${home}/.local/bin/wv` : undefined,
    "/usr/local/bin/wv",
    // Dev mode: relative to this package
    `${moduleDir}/../../scripts/wv`,
  ].filter(Boolean) as string[];
}

function findWvPath(): string {
  const paths = findWvCandidates(process.env.HOME, __dirname);

  for (const p of paths) {
    try {
      accessSync(p, constants.X_OK);
      return p;
    } catch {
      continue;
    }
  }

  throw new Error("wv CLI not found. Install with: cd weave && ./install.sh");
}

let WV_PATH = "";
let WV_PATH_ERROR = "";
try {
  WV_PATH = findWvPath();
} catch (error: unknown) {
  WV_PATH_ERROR = (error as Error).message;
  failStartup("wv_not_found", WV_PATH_ERROR);
}

// Read from package.json (shipped alongside dist/ both in-repo and in the
// installed layout) instead of hardcoding, so a version bump can't drift out
// of sync with what the server reports.
function resolvePkgVersion(): string {
  try {
    const pkg = JSON.parse(readFileSync(join(__dirname, "..", "package.json"), "utf-8"));
    return typeof pkg.version === "string" ? pkg.version : "unknown";
  } catch {
    return "unknown";
  }
}

const PKG_VERSION = resolvePkgVersion();

function validateProjectRoot(): void {
  const explicit = process.env.WV_PROJECT_ROOT || process.env.WV_PROJECT_DIR;
  if (!explicit) return;
  const ok = existsSync(explicit) && statSync(explicit).isDirectory();
  if (!ok) {
    failStartup("bad_project_root", `Project root "${explicit}" does not exist or is not a directory.`);
  }
}

validateProjectRoot();

// Default timeout for wv commands (30s). Sync handlers override this.
const WV_TIMEOUT = 30_000;
const WV_LIFECYCLE_TIMEOUT = 15_000;
// wv-c9ea87: the shared deadline for one weave_quality_patterns "list" call
// (its own primary scan/list invocation plus its internal "report" call --
// see wvQualityPatternsList). Overridable only for tests that need to
// observe the shared-budget behavior without waiting anywhere near a real
// 60s in CI; production deployments should never set this.
//
// wv-112599 (external code review round 3, finding 4): `Number(raw) ||
// 60_000` let -1/Infinity/1.5 all pass through as the literal spawnSync
// timeout -- Node throws on each of those before `wv` even runs -- while
// 0 and unparseable text silently fell back to 60000, an inconsistent mix
// of "reject" and "silently default" for different kinds of bad input.
// Node's own timeout contract (see spawnSync's `options.timeout`) only
// accepts a positive safe integer, so that's the sole value accepted here
// too; anything else (including 0, negative, fractional, non-finite, or
// unset/unparseable) consistently falls back to the 60s default instead
// of ever reaching spawnSync.
export function resolvePatternsListBudgetMs(raw: string | undefined): number {
  const value = Number(raw);
  return Number.isSafeInteger(value) && value > 0 ? value : 60_000;
}
const PATTERNS_LIST_BUDGET_MS = resolvePatternsListBudgetMs(process.env.WV_MCP_PATTERNS_LIST_BUDGET_MS);
const MCP_ALLOW_NETWORK = process.env.WV_MCP_ALLOW_NETWORK === "1";
const MCP_STARTUP_REPORT = process.env.WV_MCP_STARTUP_REPORT === "1";
const STATUS_SCHEMA_VALUES = [
  "todo",
  "active",
  "done",
  "blocked",
  "blocked-external",
  "in-progress",
  "in_progress",
] as const;
const READ_MODES = ["bootstrap", "discover", "execute", "full"] as const;
const LEARNING_CATEGORIES = ["decision", "pattern", "pitfall", "learning"] as const;
type ReadMode = (typeof READ_MODES)[number];
const MCP_READ_MODE: ReadMode = "discover";

function resolveProjectRoot(): string {
  return process.env.WV_PROJECT_ROOT || process.env.WV_PROJECT_DIR || process.cwd();
}

// Mirrors resolve_agent_harness() in scripts/lib/wv-resolve-runtime.sh (bash) and
// _is_codex_runtime()-adjacent identity handling in scripts/weave_gh/phases.py.
// Kept in sync by hand across all three languages -- there is no single source
// any of them import from. See docs/AGENT-IDENTITY-CONTRACT.md for the full
// contract (wv-5fbc6c).
// Precedence copilot > claude > codex on ambiguity: Copilot's marker is
// self-set with no known leak vector; CODEX_THREAD_ID/CODEX_CI can be
// co-present with a genuine top-level Claude Code session and must not win
// (wv-4d4c96 — that direction previously mislabeled real Claude sessions codex).
const AGENT_HARNESS_PRECEDENCE = ["copilot", "claude", "codex"] as const;
type AgentHarness = (typeof AGENT_HARNESS_PRECEDENCE)[number] | "human";

export function resolveAgentHarness(): AgentHarness {
  const present: Array<(typeof AGENT_HARNESS_PRECEDENCE)[number]> = [];
  if (process.env.CLAUDE_CODE_SSE_PORT) present.push("claude");
  if (process.env.CODEX_THREAD_ID || process.env.CODEX_CI === "1") present.push("codex");
  if (process.env.COPILOT_AGENT === "1") present.push("copilot");

  if (present.length === 0) return "human";
  if (present.length === 1) return present[0];

  const winner = AGENT_HARNESS_PRECEDENCE.find((h) => present.includes(h)) ?? present[0];
  console.error(
    `wv-mcp: ambiguous agent markers (${present.join(" ")}); using ${winner} precedence. ` +
      `Set WV_AGENT_ID to make identity explicit.`
  );
  return winner;
}

// Mirrors resolve_agent_id() (bash): explicit WV_AGENT_ID always wins; otherwise
// <harness>-<host>-<user>, matching the format scripts/weave_gh/phases.py
// recognizes as a local (non-GH-login) claim.
export function resolveAgentId(): string {
  if (process.env.WV_AGENT_ID) return process.env.WV_AGENT_ID;
  let host = "host";
  let user = "user";
  try {
    host = hostname();
  } catch {
    // keep fallback
  }
  try {
    user = userInfo().username;
  } catch {
    // keep fallback
  }
  return `${resolveAgentHarness()}-${host}-${user}`;
}

function startupReport(status: "pass" | "fail" = "pass"): Record<string, unknown> {
  return {
    schema: "weave-mcp-startup.v1",
    status,
    code: STARTUP_ERROR?.code ?? null,
    detail: STARTUP_ERROR?.message ?? null,
    server: ACTIVE_SCOPE === "all" ? "weave" : `weave-${ACTIVE_SCOPE}`,
    scope: ACTIVE_SCOPE,
    tools: SCOPED_TOOLS.length,
    pid: process.pid,
    version: PKG_VERSION,
    wv_path: WV_PATH || null,
    wv_path_error: WV_PATH_ERROR || null,
    project_root: resolveProjectRoot(),
    agent_id: resolveAgentId(),
    call_log: MCP_CALL_LOG || null,
    allow_network: MCP_ALLOW_NETWORK,
  };
}

function wvEnv(extraEnv: NodeJS.ProcessEnv = {}): NodeJS.ProcessEnv {
  const projectRoot = process.env.WV_PROJECT_ROOT || process.env.WV_PROJECT_DIR || "";
  return {
    ...process.env,
    NO_COLOR: "1",
    WV_AGENT: "1",
    WV_ACTIVE: process.env.WV_ACTIVE || "",
    // Tag MCP-internal fan-out distinctly: the server inherits the session's
    // WV_CALL_SOURCE=agent, so without this every internal subprocess (e.g.
    // weave_edit_guard's `wv list` per edit) is logged as a direct agent call,
    // inflating per-command rows in `wv analyze sessions --source=agent`.
    WV_CALL_SOURCE: "mcp",
    ...(projectRoot ? { WV_PROJECT_DIR: projectRoot } : {}),
    ...extraEnv,
  };
}

function stripAnsi(raw: string): string {
  return raw.replace(/\x1b\[[0-9;]*m/g, "");
}

function spawnWv(args: string[], timeout: number = WV_TIMEOUT, extraEnv: NodeJS.ProcessEnv = {}) {
  return spawnSync(WV_PATH, args, {
    encoding: "utf-8",
    maxBuffer: 10 * 1024 * 1024, // 10MB
    timeout,
    cwd: resolveProjectRoot(),
    env: wvEnv(extraEnv),
  });
}

// Execute wv command safely using spawnSync (no shell interpolation).
// Args are passed as an array — user input never touches a shell.
// Uses spawnSync to capture both stdout and stderr, since some wv subcommands
// (e.g. quality scan, quality hotspots) write output to stderr.
function wv(args: string[], timeout: number = WV_TIMEOUT): string {
  const result = spawnWv(args, timeout);
  // Sandboxed Node (Codex) can report error.code=EPERM from a post-spawn probe
  // even though the child ran and exited 0 — when status is a number the child
  // really ran, so the exit code is the truth; error is fatal only when the
  // spawn itself failed (status === null).
  if (result.error && result.status === null) {
    throw new Error(result.error.message || "wv command failed");
  }
  if (result.status !== 0) {
    throw new Error(result.stderr?.trim() || result.stdout?.trim() || `wv exited with code ${result.status}`);
  }
  // Prefer stdout (structured output, --json). Fall back to stderr for commands
  // that write primary output there (legacy quality subcommands without --json).
  const raw = result.stdout?.trim() || result.stderr?.trim() || "";
  return stripAnsi(raw);
}

// weave_quality_patterns' "list" subcommand additively surfaces two
// advisories the underlying CLI's own `--json` payload deliberately keeps
// OUT of stdout, to never change that bare array's shape for existing
// scripted consumers (see cmd_patterns_list's own comment in
// scripts/weave_quality/__main__.py): the scan scope/target (shown only in
// TEXT mode) and managed-rule shadow warnings (always stderr-only, in both
// modes). Neither is re-derived here — both come from the CLI's OWN
// already-computed values, just read from a different channel/subcommand
// than the plain `wv` proxy normally uses (wv-6cd72e).
// wv-ce5ca6 (external code review round 2): a "rule state" entry from
// `patterns list --json` is {rule_id: string, path: string, status: string,
// hits: number|null, [error: string]} (see cmd_patterns_list's own
// rule_states.append(...)) -- checked structurally so a scalar, an object,
// null, or an array containing any invalid entry is rejected outright
// instead of silently passed through as "rules".
//
// wv-885d12 (external code review round 3 re-audit): the round-2 fix above
// only checked each FIELD's own type in isolation -- `status` was any
// nonempty string, `hits` was any number or null, with no cross-field
// invariant at all. cmd_patterns_list's own producer contract
// (scripts/weave_quality/__main__.py:2453-2463, mirroring
// record_pattern_rule_failure/record_pattern_rule_success's own DB
// invariants) only ever produces exactly three states: "not_run" with
// hits:null; "failed" with hits:null and a nonempty `error`; "success"
// with a nonnegative integer `hits`. {status:"failed", hits:null} with no
// error, {status:"success", hits:null}, an unrecognized status like
// "bogus", and negative/fractional hits were all still accepted before
// this -- none of them a reachable state from a working install.
//
// wv-731450 (external code review round 3 re-audit): "success"/"not_run"
// still accepted an opposite-state `error` field tagging along (e.g.
// {status:"success", hits:0, error:"scan failed"}) -- cmd_patterns_list's
// own state dict only ever ADDS "error" inside the `if receipt["error"]`
// branch, and record_pattern_rule_success (db.py) explicitly writes
// error=NULL on every success upsert, so a success/not_run entry
// carrying `error` is exactly as unreachable as the cases above.
function isValidPatternListEntry(value: unknown): boolean {
  if (value === null || typeof value !== "object" || Array.isArray(value)) return false;
  const entry = value as Record<string, unknown>;
  if (typeof entry.rule_id !== "string" || entry.rule_id.length === 0) return false;
  if (typeof entry.path !== "string" || entry.path.length === 0) return false;
  switch (entry.status) {
    case "not_run":
      return entry.hits === null && !("error" in entry);
    case "failed":
      return entry.hits === null && typeof entry.error === "string" && entry.error.length > 0;
    case "success":
      return Number.isInteger(entry.hits) && (entry.hits as number) >= 0 && !("error" in entry);
    default:
      return false;
  }
}

// The exact managed-shadow advisory _wv quality patterns list_ ever prints
// (cmd_patterns_list, wv-f0b306) -- both rule_id occurrences must match via
// backreference, so an unrelated stderr line that merely happens to start
// with the same glyph (a future warning, a stray tool message) is never
// mislabeled as this specific advisory.
//
// wv-8d16bd (external code review round 3 re-audit): the message gained a
// "AND run 'wv init-repo --update'" clause -- deleting the local copy alone
// doesn't resync the managed version, and following the OLD advice as
// written silently dropped the rule entirely. Keep this regex byte-for-byte
// in sync with cmd_patterns_list's own f-string.
const SHADOW_ADVISORY_RE =
  /^⚠ (\S+): \.weave\/patterns\/\1\.yaml shadows an available managed rule of the same id \(never applied\) — delete the local copy AND run 'wv init-repo --update' to sync the managed version, if this was a completed promotion$/;

function wvQualityPatternsList(cmd: string[], patPath: string | undefined): string {
  // wv-c9ea87 (external code review round 2): list's own scan and its
  // internal report call each used to get an independent, fresh 60s
  // timeout budget -- a slow scan followed by a report call that also
  // stalls could block this single synchronous MCP request for close to
  // 120s combined, well past what a calling client's own timeout expects.
  // One shared deadline now covers the whole call; the report call only
  // ever gets whatever's left of it, never a fresh budget of its own.
  const deadline = Date.now() + PATTERNS_LIST_BUDGET_MS;
  const result = spawnWv(cmd, PATTERNS_LIST_BUDGET_MS);
  if (result.error && result.status === null) {
    throw new Error(result.error.message || "wv command failed");
  }
  if (result.status !== 0) {
    throw new Error(result.stderr?.trim() || result.stdout?.trim() || `wv exited with code ${result.status}`);
  }
  // wv-ce5ca6 (external code review round 2): stdout was previously
  // defaulted to the literal string "[]" whenever it was empty (`||
  // "[]"`), fabricating a clean "zero rules" result indistinguishable
  // from a genuine crash that produced no output on an exit-0 path; and
  // whatever the parsed JSON turned out to be -- a scalar, an object,
  // null, or an array with invalid entries mixed in -- was accepted as
  // "rules" with no shape check at all. `_DEFAULT_PATTERNS_DIR` always
  // ships built-in rules (see _candidate_pattern_files), so a genuinely
  // empty or malformed rules array from a working install should never
  // happen -- fail loudly instead of returning either fabricated or
  // unchecked content.
  const stdout = stripAnsi(result.stdout?.trim() || "");
  let parsedRules: unknown;
  try {
    parsedRules = stdout ? JSON.parse(stdout) : null;
  } catch {
    throw new Error(`wv quality patterns list produced malformed JSON: ${stdout.slice(0, 200)}`);
  }
  if (!Array.isArray(parsedRules) || parsedRules.length === 0 || !parsedRules.every(isValidPatternListEntry)) {
    throw new Error(
      `wv quality patterns list returned an unexpected payload shape: ${stdout.slice(0, 200) || "(empty output)"}`
    );
  }
  const rules = parsedRules;
  const shadowAdvisories = stripAnsi(result.stderr || "")
    .split("\n")
    .map((line) => line.trim())
    .filter((line) => SHADOW_ADVISORY_RE.test(line));
  // scope comes from `report`'s own --json payload, which already computes
  // it from the SAME underlying source (latest_pattern_run's stored
  // target, or an explicit path) as list's own text-mode header — see
  // _report_scope's docstring: "the label is the raw target string,
  // matching how list shows 'last scanned: <target>'". Reusing report's
  // already-additive scope field avoids re-deriving scope-resolution logic
  // here; a failure to obtain it (e.g. no scan has ever run) is
  // non-fatal — the rule listing itself is still the primary payload.
  //
  // wv-5b9f55 finding 8 (external code review): report's own path
  // handling is NOT symmetric with list's, in TWO ways.
  //
  // (a) cmd_patterns_list resolves `repo` via _resolve_repo(patPath) --
  // patPath (when given) IS the repository root. cmd_patterns_report
  // resolves `repo` via _resolve_repo(None) UNCONDITIONALLY -- an
  // explicit path there is never the repo itself. WV_REPO_ROOT_OVERRIDE
  // is the env var _resolve_repo(None) checks first (ahead of REPO_ROOT
  // -- see wv-20adef below for why REPO_ROOT itself doesn't survive):
  // setting it here, resolved the identical way list's own path
  // argument already is (Path(...).resolve(), mirrored via Node's
  // resolve() against the SAME subprocess cwd both calls share), makes
  // this one report subprocess call agree with list's own repo without
  // touching report's CLI contract.
  //
  // wv-20adef (external code review round 2): this used to set REPO_ROOT
  // itself, which does NOT survive the real `wv` wrapper -- the bash
  // entry point's own wv-config.sh unconditionally reassigns REPO_ROOT
  // from `git rev-parse --show-toplevel` against the wv SUBPROCESS's own
  // cwd (resolveProjectRoot(), the MCP server's project root -- see
  // spawnWv), discarding whatever this extraEnv set, before
  // _resolve_repo(None) in Python ever runs. That only went unnoticed
  // because every existing test's fixture happened to spawn the MCP
  // server itself from the same directory as `patPath`, so wv-config.sh's
  // own recomputed REPO_ROOT coincidentally agreed anyway.
  // WV_REPO_ROOT_OVERRIDE is a name wv-config.sh never touches, so it
  // survives the wrapper intact whenever the MCP server's own project
  // root differs from the repo a `list`/`validate` call is scoped to.
  //
  // (b) Forwarding patPath onto report's OWN command line (as before)
  // compounds the mismatch further: report treats a path ARGUMENT as an
  // EXPLICIT SCAN TARGET override (_canonicalize_target(repo,
  // explicit_path)), skipping its normal "last stored scan target"
  // lookup entirely -- so passing list's own repo-root patPath through
  // made report canonicalize THAT root against itself, always
  // collapsing scope to the degenerate "." (target == repo) instead of
  // whatever sub-target list's own last scan actually targeted. report
  // must run with NO explicit path argument here -- only REPO_ROOT --
  // so it naturally falls through to reporting on latest_pattern_run's
  // own stored target, scoped against the CORRECT repo via (a).
  //
  // A genuine command failure (nonzero exit, a timeout, malformed JSON)
  // is also no longer silently folded into the same `scope: null` a
  // legitimate "no scan has ever run" naturally produces — the two are
  // indistinguishable to a caller otherwise, and the former is exactly
  // the kind of problem a caller deciding whether to trust `scope` at
  // all needs to know about. Surfaced additively as `scope_error`,
  // still non-fatal to the primary rule-listing payload.
  const reportCmd = ["quality", "patterns", "report", "--json"];
  const reportEnv: NodeJS.ProcessEnv = patPath ? { WV_REPO_ROOT_OVERRIDE: resolve(resolveProjectRoot(), patPath) } : {};
  let scope: string | null = null;
  let scopeError: string | null = null;
  // wv-c9ea87: only whatever's left of the shared 60s deadline above, not
  // a fresh budget -- a report call that would start after the deadline
  // has already passed is skipped entirely rather than handed a zero or
  // negative timeout (spawnSync treats a falsy timeout as "no timeout").
  const reportBudget = deadline - Date.now();
  if (reportBudget <= 0) {
    scopeError = "wv quality patterns list's shared 60s budget was exhausted before its internal report call could run";
  } else {
    const reportResult = spawnWv(reportCmd, reportBudget, reportEnv);
    if (reportResult.error && reportResult.status === null) {
      scopeError = reportResult.error.message || "wv quality patterns report failed";
    } else if (reportResult.status !== 0) {
      scopeError = stripAnsi(
        reportResult.stderr?.trim() ||
          reportResult.stdout?.trim() ||
          `wv quality patterns report exited with code ${reportResult.status}`
      );
    } else {
      // wv-ce5ca6: {}, [], and {scope: 42} used to all parse successfully
      // and produce no scope_error -- `report.scope ?? null` treats a
      // MISSING key the same as an explicit null, and never checks that
      // `report` is even an object at all, let alone that `scope` (when
      // present) is a string. cmd_patterns_report always sets
      // report["scope"] = scope_label (str | None) on its own dict --
      // require exactly that shape.
      //
      // wv-67a6e5 (external code review round 3, finding 7): this used to
      // check only the `scope` field in isolation -- {by_rule: "bogus",
      // recurring_waivers: 42, finding_count: -1, scope: "ok"} passed. Now
      // shares the SAME full-contract validator direct `report` calls use
      // (isValidPatternReportPayload); a report call still degrades to a
      // non-fatal `scope_error` here (list's own rules[] payload remains
      // the primary, still-useful result either way), it just no longer
      // trusts `scope` off a payload that fails everywhere else.
      const reportStdout = stripAnsi(reportResult.stdout?.trim() || "");
      let parsedReport: unknown;
      try {
        parsedReport = JSON.parse(reportStdout);
      } catch {
        scopeError = "wv quality patterns report produced malformed JSON";
        parsedReport = undefined;
      }
      if (parsedReport !== undefined) {
        if (isValidPatternReportPayload(parsedReport)) {
          scope = parsedReport.scope;
        } else {
          scopeError = `wv quality patterns report returned an unexpected payload shape: ${reportStdout.slice(0, 200)}`;
        }
      }
    }
  }
  const payload: Record<string, unknown> = { rules, scope, shadow_advisories: shadowAdvisories };
  if (scopeError !== null) payload.scope_error = scopeError;
  return JSON.stringify(payload);
}

// wv-860c8c (external code review round 2): a "validate" rule entry
// (cmd_patterns_validate's own results.append(entry)) is {rule_id: string,
// path: string, status: "valid"|"invalid", [language: string],
// [error: string]} -- status=="invalid" always carries its own `error`
// (see the PatternRuleValidationError except-branch and the duplicate-id
// collision branch, both of which set entry["error"] whenever they set
// status to "invalid"). Checked structurally so {rules: [null]} or
// {rules: [{status: "invalid"}]} (no rule_id/path/error at all) are
// rejected instead of accepted as real per-rule results.
//
// wv-8b3f8a (external code review round 3 re-audit): a status=="valid"
// entry was accepted with no further check at all -- but
// cmd_patterns_validate always sets entry["language"] = validate_pattern_
// rule(...)'s own return value in that branch (scripts/weave_quality/
// __main__.py:2324-2326), and clears it again if a later duplicate-id
// collision demotes the entry to "invalid" (entry.pop("language", None)).
// A valid entry missing `language` is exactly as unreachable from a
// working install as an invalid one missing `error`.
//
// wv-731450 (external code review round 3 re-audit): "valid" still
// accepted an opposite-state `error` field, and "invalid" still accepted
// a leftover `language` field. cmd_patterns_validate's own entry dict is
// built exclusively inside one of two mutually exclusive branches (the
// try succeeds and sets status/language, or the except sets
// status/error) -- language and error are never both present on the
// same entry, so either combination is exactly as unreachable as a
// missing required field.
function isValidPatternValidateEntry(value: unknown): boolean {
  if (value === null || typeof value !== "object" || Array.isArray(value)) return false;
  const entry = value as Record<string, unknown>;
  if (typeof entry.rule_id !== "string" || entry.rule_id.length === 0) return false;
  if (typeof entry.path !== "string" || entry.path.length === 0) return false;
  if (entry.status === "valid") {
    return typeof entry.language === "string" && entry.language.length > 0 && !("error" in entry);
  }
  if (entry.status === "invalid") {
    return typeof entry.error === "string" && entry.error.length > 0 && !("language" in entry);
  }
  return false;
}

// wv-8b3f8a (external code review round 3 re-audit): cmd_patterns_validate
// always sets payload["coverage"] = {kinds, match_scopes, maturities,
// optional_keys} (scripts/weave_quality/__main__.py:2372-2382), each a
// dict mapping every documented schema value for that group to whether a
// currently-valid rule actually exercises it -- i.e. an object whose own
// values are all booleans. Checked structurally, not just "is an object",
// the same way rules[] entries are.
//
// wv-731450 (external code review round 3 re-audit): each group's own
// check was `Object.values(group).every(...)`, vacuously true for `{}` --
// {kinds:{}, match_scopes:{}, maturities:{}, optional_keys:{}} passed.
// cmd_patterns_validate builds every group from a fixed, nonempty Python
// tuple (_PROSE_SCHEMA_KINDS/_MATCH_SCOPES/_MATURITIES/_OPTIONAL_KEYS,
// __main__.py:2237-2246) mapped unconditionally to True/False -- the
// SET of keys per group never varies, only the booleans do, so a group
// with zero keys is exactly as unreachable as one with a non-boolean
// value. Deliberately NOT cross-checking the exact enumerated key names
// here (that would hand-duplicate the Python schema constants in TS as a
// second source of truth, the tradeoff wv-8b3f8a's own decision already
// weighed against) -- nonempty is the boundary this check can enforce
// without that duplication.
function isValidPatternCoverage(value: unknown): boolean {
  if (value === null || typeof value !== "object" || Array.isArray(value)) return false;
  const coverage = value as Record<string, unknown>;
  return (["kinds", "match_scopes", "maturities", "optional_keys"] as const).every((key) => {
    const group = coverage[key];
    if (group === null || typeof group !== "object" || Array.isArray(group)) return false;
    const entries = Object.values(group as Record<string, unknown>);
    return entries.length > 0 && entries.every((v) => typeof v === "boolean");
  });
}

// weave_quality_patterns' "validate" subcommand deliberately returns a
// NONZERO exit code when it finds an invalid rule (cmd_patterns_validate:
// `return 0 if all_valid else 1`) -- unlike scan/list/report, where a
// nonzero exit really does mean something went wrong, validate's own stdout
// JSON is a fully useful, successfully-produced result either way ("some
// rules are invalid" is a normal finding, not a crash). The generic wv()
// helper treats any nonzero exit as a thrown error, which would otherwise
// swallow a legitimate {"rules": [...], "valid": false} payload behind an
// "Error: ..." wrapper (wv-6cd72e).
//
// Accepting "exit in {0,1}" alone is NOT sufficient (wv-c4e639, external
// code review finding 3): a genuine crash that happens to exit 0 or 1 with
// partial/garbage/empty stdout (a truncated timeout write, a malformed-JSON
// regression, an unrelated future command reusing this exit convention)
// would otherwise be returned as if it were a real result. Only two exact
// shapes are accepted: exit 0 with {valid: true, rules: [...]}, or exit 1
// with {valid: false, rules: [...]} -- parsed and shape-checked, and cross-
// checked against cmd_patterns_validate's own `0 if all_valid else 1`
// invariant (a payload claiming valid:true at exit 1, or vice versa, is
// exactly as suspect as a missing field and rejected the same way).
//
// wv-860c8c (external code review round 2): the envelope check alone
// ({valid: boolean, rules: array}) still accepted {valid:true,
// rules:[null]}, {valid:true, rules:[{status:"invalid"}]}, and
// {valid:false, rules:[]} -- none of them impossible per the envelope
// shape, all three impossible per cmd_patterns_validate's own contract.
// Every rules[] entry is now checked structurally (isValidPatternValidateEntry),
// and `valid` is cross-checked against the entries' own statuses, not just
// against the exit code.
function wvQualityPatternsValidate(cmd: string[]): string {
  const result = spawnWv(cmd, 60_000);
  if (result.error && result.status === null) {
    throw new Error(result.error.message || "wv command failed");
  }
  if (result.status !== 0 && result.status !== 1) {
    // The "unexpected code" message must always lead -- a crash that
    // still leaves SOMETHING on stdout/stderr (a partial timeout write,
    // stray unrelated output) must not silently take priority over the
    // one fact that actually matters here (wv-c4e639: an earlier version
    // let stdout content win over this message whenever stdout was
    // merely nonempty, which is exactly the "trust nonempty output"
    // mistake this whole fix exists to close).
    const detail = result.stderr?.trim() || result.stdout?.trim();
    throw new Error(
      `wv quality patterns validate exited with unexpected code ${result.status}` +
        (detail ? `: ${detail.slice(0, 200)}` : "")
    );
  }
  const stdout = stripAnsi(result.stdout?.trim() || "");
  let payload: unknown;
  try {
    payload = JSON.parse(stdout);
  } catch {
    throw new Error(
      `wv quality patterns validate produced malformed JSON (exit ${result.status}): ` +
        (stdout.slice(0, 200) || result.stderr?.trim() || "(empty output)")
    );
  }
  const rec = payload as { valid?: unknown; rules?: unknown; coverage?: unknown } | null;
  if (
    rec === null ||
    typeof rec !== "object" ||
    typeof rec.valid !== "boolean" ||
    !Array.isArray(rec.rules) ||
    // wv-8b3f8a (external code review round 3 re-audit): {valid: true,
    // rules: []} used to pass -- Array.prototype.every is vacuously true
    // on an empty array for BOTH checks below, so an empty rules[] never
    // tripped either one. _DEFAULT_PATTERNS_DIR always ships built-in
    // rules (same reasoning wv-ce5ca6 already established for `list`),
    // so a genuinely empty rules[] from a working install should never
    // happen -- fail loudly instead of accepting a vacuously "clean"
    // result.
    rec.rules.length === 0 ||
    !isValidPatternCoverage(rec.coverage)
  ) {
    throw new Error(
      `wv quality patterns validate returned an unexpected payload shape (exit ${result.status}): ${stdout.slice(0, 200)}`
    );
  }
  const rules = rec.rules as unknown[];
  if (!rules.every(isValidPatternValidateEntry)) {
    throw new Error(
      `wv quality patterns validate returned a rules[] entry with an unexpected shape (exit ${result.status}): ${stdout.slice(0, 200)}`
    );
  }
  const allEntriesValid = rules.every((entry) => (entry as { status: string }).status === "valid");
  if (rec.valid !== allEntriesValid) {
    throw new Error(
      `wv quality patterns validate's top-level "valid" (${rec.valid}) disagrees with its own rules[] statuses ` +
        `(exit ${result.status}): ${stdout.slice(0, 200)}`
    );
  }
  const expectedStatus = rec.valid ? 0 : 1;
  if (result.status !== expectedStatus) {
    throw new Error(
      `wv quality patterns validate exit code (${result.status}) disagrees with its own payload ` +
        `(valid: ${rec.valid}) -- expected exit ${expectedStatus}`
    );
  }
  return stdout;
}

// wv-67a6e5 (external code review round 3, finding 7): cmd_patterns_report's
// own contract (scripts/weave_quality/db.py's pattern_adjudication_report,
// plus cmd_patterns_report itself additively setting `scope`) always
// produces {by_rule: object, recurring_waivers: array, finding_count:
// nonnegative integer, scope: string|null}. wvQualityPatternsList's own
// internal report call used to check only `scope`'s shape -- {}, [], and
// other malformed-but-truthy payloads passed as long as a `scope` field
// happened to be a string or absent-as-null. A DIRECT weave_quality_patterns
// report call skipped validation entirely, falling through to the generic
// wv() helper, which returns any exit-0 stdout (including "[]", "{}", or
// malformed JSON) as successful tool content. One shared validator now
// covers both call sites.
function isValidPatternReportPayload(value: unknown): value is {
  by_rule: Record<string, unknown>;
  recurring_waivers: unknown[];
  finding_count: number;
  scope: string | null;
} {
  if (value === null || typeof value !== "object" || Array.isArray(value)) return false;
  const report = value as Record<string, unknown>;
  return (
    typeof report.by_rule === "object" &&
    report.by_rule !== null &&
    !Array.isArray(report.by_rule) &&
    Array.isArray(report.recurring_waivers) &&
    Number.isInteger(report.finding_count) &&
    (report.finding_count as number) >= 0 &&
    (report.scope === null || typeof report.scope === "string")
  );
}

// A direct `weave_quality_patterns` call with subcommand "report" -- unlike
// list's own internal report call, a malformed/empty/wrong-shaped payload
// here IS the entire result, so it throws (fatal) rather than degrading to
// a non-fatal `scope_error` alongside other primary content.
function wvQualityPatternsReport(cmd: string[]): string {
  const result = spawnWv(cmd, 60_000);
  if (result.error && result.status === null) {
    throw new Error(result.error.message || "wv command failed");
  }
  if (result.status !== 0) {
    throw new Error(result.stderr?.trim() || result.stdout?.trim() || `wv exited with code ${result.status}`);
  }
  const stdout = stripAnsi(result.stdout?.trim() || "");
  let payload: unknown;
  try {
    payload = stdout ? JSON.parse(stdout) : null;
  } catch {
    throw new Error(`wv quality patterns report produced malformed JSON: ${stdout.slice(0, 200)}`);
  }
  if (!isValidPatternReportPayload(payload)) {
    throw new Error(
      `wv quality patterns report returned an unexpected payload shape: ${stdout.slice(0, 200) || "(empty output)"}`
    );
  }
  return stdout;
}

function wvHealthJson(timeout: number = WV_TIMEOUT): string {
  const result = spawnWv(["health", "--json"], timeout);
  if (result.error && result.status === null) {
    throw new Error(result.error.message || "wv command failed");
  }
  const stdout = result.stdout?.trim() || "";
  if (stdout) {
    return stripAnsi(stdout);
  }
  throw new Error(result.stderr?.trim() || `wv health --json exited with code ${result.status}`);
}

function wvRead(args: string[], timeout: number = WV_TIMEOUT, mode?: ReadMode): string {
  return wv([...args, `--mode=${mode ?? MCP_READ_MODE}`], timeout);
}

function mcpNetworkFallback(command: string): string {
  return [
    "MCP network/GitHub lifecycle work is disabled by default to keep mounted MCP servers responsive.",
    `Run from the CLI if needed: ${command}`,
    "Set WV_MCP_ALLOW_NETWORK=1 in the MCP server environment to allow MCP to run it directly.",
  ].join("\n");
}

// Tool definitions
const TOOLS: Tool[] = [
  {
    name: "weave_search",
    description: "Full-text search across Weave nodes. Returns matching nodes ranked by relevance.",
    inputSchema: {
      type: "object",
      properties: {
        query: {
          type: "string",
          description: "Search query (supports stemming)",
        },
        limit: {
          type: "number",
          description: "Maximum results to return (default: 10)",
        },
        status: {
          type: "string",
          enum: [...STATUS_SCHEMA_VALUES],
          description: "Filter by status (legacy in-progress/in_progress map to active)",
        },
        type: {
          type: "string",
          description: "Filter by metadata.type (e.g. finding, task, epic, learning)",
        },
      },
      required: ["query"],
    },
  },
  {
    name: "weave_add",
    description:
      "Create a new Weave node. Returns the generated node ID. IMPORTANT: Always set gh=true to create a linked GitHub issue, and provide an alias for readability.",
    inputSchema: {
      type: "object",
      properties: {
        text: {
          type: "string",
          description: "Node text/description",
        },
        status: {
          type: "string",
          enum: [...STATUS_SCHEMA_VALUES],
          description: "Initial status (default: todo; legacy in-progress/in_progress map to active)",
        },
        metadata: {
          type: "object",
          description: "JSON metadata (e.g., {type: 'task', priority: 1})",
        },
        gh: {
          type: "boolean",
          description:
            "Create a linked GitHub issue. Should ALWAYS be true unless explicitly told otherwise -- orphan nodes without GH issues lose traceability.",
        },
        alias: {
          type: "string",
          description:
            "Human-readable alias (e.g., 'fix-login-bug'). Should ALWAYS be set -- makes the graph readable and commands easier.",
        },
        parent: {
          type: "string",
          description:
            "Parent node ID to link via 'implements' edge (e.g., 'wv-a1b2'). Prevents orphan tasks -- always set for non-epic nodes.",
        },
        force: {
          type: "boolean",
          description: "Skip similarity check and create node even if similar nodes exist.",
        },
        standalone: {
          type: "boolean",
          description:
            "Create node without a parent even when epics exist. Semantic alias for force=true — use this when orphan intent is deliberate (chore/doc nodes, standalone fixes).",
        },
        criteria: {
          type: "string",
          description:
            "Pipe-delimited done criteria (e.g., 'tests pass|docs updated'). Set at creation time — the pre-claim hook requires done_criteria, so claim-ready nodes need this.",
        },
        risks: {
          type: "string",
          description: "Risk level for the work (e.g., 'low', 'medium', 'high').",
        },
        verification_plan: {
          type: "string",
          description:
            "What would count as done, recorded upfront. Surfaced again as a reminder if wv done is later blocked for missing verification.",
        },
      },
      required: ["text"],
    },
  },
  {
    name: "weave_done",
    description:
      "Mark a Weave node as complete. Always include a learning for non-trivial work -- captures decisions, patterns, and pitfalls for future sessions.",
    inputSchema: {
      type: "object",
      properties: {
        id: {
          type: "string",
          description: "Node ID (e.g., wv-a1b2)",
        },
        learning: {
          type: "string",
          description:
            "Learning to capture. Use pipe-delimited format: 'decision: X | pattern: Y | pitfall: Z'. Or use the typed fields below instead.",
        },
        decision: {
          type: "string",
          description: "What was decided and why (stored as top-level metadata key).",
        },
        pattern: {
          type: "string",
          description: "Reusable pattern or technique discovered (stored as top-level metadata key).",
        },
        pitfall: {
          type: "string",
          description: "What went wrong or what to avoid (stored as top-level metadata key).",
        },
        no_warn: {
          type: "boolean",
          description: "Suppress validation hints (useful on machines without test env)",
        },
        no_overlap_check: {
          type: "boolean",
          description:
            "Skip FTS5 learning-similarity check entirely — no prompt, no advisory. Use in agent/script contexts where stdin is unavailable.",
        },
        verification_method: {
          type: "string",
          description:
            "How the work was verified (e.g., 'make check', 'bash tests/test-core.sh'). Pair with verification_evidence.",
        },
        verification_evidence: {
          type: "string",
          description:
            "Inline verification evidence (test output, command results). Attach for non-trivial closes — closes without evidence draw a post-close advisory.",
        },
        completion_files: {
          type: "array",
          items: { type: "string" },
          minItems: 1,
          description:
            "Attributed repository-relative files to use as the explicit completion quality scope. Historical file attribution remains unchanged.",
        },
      },
      required: ["id"],
    },
  },
  {
    name: "weave_batch_done",
    description:
      "Close multiple nodes at once. Useful for completing a group of related tasks from a sprint. Applies the same learning to all nodes.",
    inputSchema: {
      type: "object",
      properties: {
        ids: {
          type: "array",
          items: { type: "string" },
          description: "Array of node IDs to close (e.g., ['wv-a1b2', 'wv-c3d4'])",
        },
        learning: {
          type: "string",
          description: "Learning to capture for all nodes. Use pipe-delimited format or typed fields below.",
        },
        decision: {
          type: "string",
          description: "What was decided and why.",
        },
        pattern: {
          type: "string",
          description: "Reusable pattern or technique discovered.",
        },
        pitfall: {
          type: "string",
          description: "What went wrong or what to avoid.",
        },
        no_warn: {
          type: "boolean",
          description: "Suppress validation hints",
        },
      },
      required: ["ids"],
    },
  },
  {
    name: "weave_context",
    description:
      "Get a node Context Pack as JSON: node details, blockers, ancestors, related nodes, and learnings. Defaults to lean discover-mode output for agent callers.",
    inputSchema: {
      type: "object",
      properties: {
        id: {
          type: "string",
          description: "Node ID (optional if WV_ACTIVE is set)",
        },
        mode: {
          type: "string",
          enum: [...READ_MODES],
          description: "Optional output mode override (default: discover for MCP/agent callers)",
        },
      },
      required: [],
    },
  },
  {
    name: "weave_list",
    description:
      "List Weave nodes as compact json-v2 records. Metadata is a nested object and created_at/updated_at are omitted.",
    inputSchema: {
      type: "object",
      properties: {
        status: {
          type: "string",
          enum: [...STATUS_SCHEMA_VALUES],
          description: "Filter by status (legacy in-progress/in_progress map to active)",
        },
        all: {
          type: "boolean",
          description: "Include done nodes (default: false)",
        },
        mode: {
          type: "string",
          enum: ["bootstrap", "discover", "execute", "full"],
          description:
            "Output mode controlling default row cap. discover (default for agents) caps at 20 rows; full has no cap. Use --all or status='done' to bypass entirely.",
        },
      },
      required: [],
    },
  },
  {
    name: "weave_link",
    description: "Create a semantic edge between two nodes.",
    inputSchema: {
      type: "object",
      properties: {
        from_id: {
          type: "string",
          description: "Source node ID (e.g. 'wv-a1b2')",
        },
        to_id: {
          type: "string",
          description: "Target node ID (e.g. 'wv-c3d4')",
        },
        type: {
          type: "string",
          enum: [
            "blocks",
            "relates_to",
            "implements",
            "contradicts",
            "supersedes",
            "references",
            "obsoletes",
            "addresses",
          ],
          description: "Edge type",
        },
        weight: {
          type: "number",
          description: "Edge weight 0.0-1.0 (default: 1.0)",
        },
        context: {
          type: "string",
          description: 'Edge context JSON (e.g. \'{"reason": "API dependency"}\')',
        },
      },
      required: ["from_id", "to_id", "type"],
    },
  },
  {
    name: "weave_unlink",
    description: "Remove a semantic edge between two nodes.",
    inputSchema: {
      type: "object",
      properties: {
        from_id: {
          type: "string",
          description: "Source node ID (e.g. 'wv-a1b2')",
        },
        to_id: {
          type: "string",
          description: "Target node ID (e.g. 'wv-c3d4')",
        },
        type: {
          type: "string",
          enum: [
            "blocks",
            "relates_to",
            "implements",
            "contradicts",
            "supersedes",
            "references",
            "obsoletes",
            "addresses",
          ],
          description: "Edge type to remove",
        },
      },
      required: ["from_id", "to_id", "type"],
    },
  },
  {
    name: "weave_block",
    description: "Create a blocking edge from one node to another. Shorthand for weave_link with type=blocks.",
    inputSchema: {
      type: "object",
      properties: {
        from_id: {
          type: "string",
          description: "Blocking node ID — the node that blocks (e.g. 'wv-a1b2')",
        },
        to_id: {
          type: "string",
          description: "Blocked node ID — the node being blocked (e.g. 'wv-c3d4')",
        },
        context: {
          type: "string",
          description: "Optional reason for the block",
        },
      },
      required: ["from_id", "to_id"],
    },
  },
  {
    name: "weave_unarchive",
    description:
      "Restore a pruned node from .weave/archive/ back into the live graph. Searches archive JSONL files newest-first.",
    inputSchema: {
      type: "object",
      properties: {
        id: {
          type: "string",
          description: "Node ID to restore (e.g. 'wv-a1b2')",
        },
        dry_run: {
          type: "boolean",
          description: "Preview what would be restored without writing",
        },
        with_edges: {
          type: "boolean",
          description: "Also reconstruct edges where both endpoints are live (skips dangling edges)",
        },
      },
      required: ["id"],
    },
  },
  {
    name: "weave_status",
    description:
      "Get compact status text for agent callers: active work, ready count, blocked count, and pending-close state. Defaults to discover mode.",
    inputSchema: {
      type: "object",
      properties: {
        mode: {
          type: "string",
          enum: [...READ_MODES],
          description: "Optional output mode override (default: discover for MCP/agent callers)",
        },
      },
      required: [],
    },
  },
  {
    name: "weave_ready",
    description:
      "List unblocked, unclaimed nodes ready to work on. Equivalent to 'wv ready'. Returns JSON array by default for agent callers.",
    inputSchema: {
      type: "object",
      properties: {
        subtree: {
          type: "string",
          description: "Restrict to descendants of this node ID",
        },
        all: {
          type: "boolean",
          description: "Include all statuses, not just ready",
        },
        count: {
          type: "boolean",
          description: "Return count only",
        },
        mode: {
          type: "string",
          enum: [...READ_MODES],
          description: "Optional output mode override",
        },
        with_impact: {
          type: "boolean",
          description: "Attach blast-radius impact summary to each ready node",
        },
      },
      required: [],
    },
  },
  {
    name: "weave_impact",
    description:
      "Run blast-radius analysis from one or more seed nodes. Wraps 'wv impact --json' and returns impacted nodes, unblocked nodes, edges, and optional quality/risk detail.",
    inputSchema: {
      type: "object",
      properties: {
        ids: {
          type: "array",
          items: { type: "string" },
          description: "Seed node IDs (e.g. ['wv-a1b2', 'wv-c3d4'])",
        },
        depth: {
          type: "number",
          description: "Traversal depth (default: 3)",
        },
        direction: {
          type: "string",
          enum: ["fwd", "rev", "both"],
          description: "Traversal direction (default: both)",
        },
        full: {
          type: "boolean",
          description: "Include extended edge set (resolves/references/supersedes/obsoletes)",
        },
        include_done: {
          type: "boolean",
          description: "Include done nodes in impacted output",
        },
        all: {
          type: "boolean",
          description: "Remove node cap",
        },
        quality: {
          type: "boolean",
          description: "Attach code_quality payload per impacted node",
        },
        files: {
          type: "string",
          description:
            "Comma-separated file paths; derives seed nodes from touched_files metadata. Alternative to ids.",
        },
      },
    },
  },
  {
    name: "weave_query",
    description:
      "Flexible predicate query over nodes. Supports status/tag/HAS/MATCH predicates. Example predicates: 'status=todo', 'tag=auth', 'HAS learning', 'MATCH auth middleware'. Multiple predicates are ANDed.",
    inputSchema: {
      type: "object",
      properties: {
        predicates: {
          type: "array",
          items: { type: "string" },
          description: "Query predicates (e.g. ['status=todo', 'HAS learning', 'MATCH auth'])",
        },
        format: {
          type: "string",
          enum: ["table", "json", "ids", "text"],
          description: "Output format (default: json for MCP callers)",
        },
        order: {
          type: "string",
          enum: ["recent", "alpha", "priority"],
          description: "Sort order (default: recent)",
        },
        limit: {
          type: "number",
          description: "Max results (default: 20)",
        },
        include: {
          type: "string",
          description: "Include an extra node type normally hidden from results (e.g. 'finding')",
        },
      },
      required: [],
    },
  },
  {
    name: "weave_health",
    description: "Run health check on Weave graph. Returns score and any issues found.",
    inputSchema: {
      type: "object",
      properties: {
        verbose: {
          type: "boolean",
          description: "Include detailed diagnostics",
        },
        fix: {
          type: "boolean",
          description: "Auto-fix issues (e.g. backfill empty edge context with auto-generated summaries)",
        },
        history: {
          type: "number",
          description: "Include the N most recent health-history entries",
        },
      },
      required: [],
    },
  },
  {
    name: "weave_quick",
    description:
      "Record a trivial completed task. Creates a done node with learning in one step. Equivalent to add + done + sync.",
    inputSchema: {
      type: "object",
      properties: {
        text: {
          type: "string",
          description: "Node text/description",
        },
        learning: {
          type: "string",
          description:
            "Learning to capture on the auto-closed node. Use pipe-delimited format: 'decision: X | pattern: Y | pitfall: Z'.",
        },
      },
      required: ["text"],
    },
  },
  {
    name: "weave_work",
    description:
      "Claim a node to work on. Sets WV_ACTIVE context for subagent inheritance. Use reopen=true to explicitly reopen a done node back to active tracked work — without it, calling weave_work on a done node returns an error.",
    inputSchema: {
      type: "object",
      properties: {
        id: {
          type: "string",
          description: "Node ID to claim (e.g., wv-a1b2)",
        },
        reopen: {
          type: "boolean",
          description:
            "Reopen a done node back to active tracked work. Required when the node status is 'done' — omitting it returns an error.",
        },
      },
      required: ["id"],
    },
  },
  {
    name: "weave_ship",
    description:
      "Complete current work with a bounded local close + sync. GitHub/network sync is disabled by default in MCP; when requested, the response includes the CLI command to run outside MCP unless WV_MCP_ALLOW_NETWORK=1 is set. Always include a learning for non-trivial work.",
    inputSchema: {
      type: "object",
      properties: {
        id: {
          type: "string",
          description: "Node ID to complete",
        },
        learning: {
          type: "string",
          description:
            "Learning to capture. Use pipe-delimited format: 'decision: X | pattern: Y | pitfall: Z'. Or use the typed fields below instead.",
        },
        decision: {
          type: "string",
          description: "What was decided and why (stored as top-level metadata key).",
        },
        pattern: {
          type: "string",
          description: "Reusable pattern or technique discovered (stored as top-level metadata key).",
        },
        pitfall: {
          type: "string",
          description: "What went wrong or what to avoid (stored as top-level metadata key).",
        },
        gh: {
          type: "boolean",
          description: "Request GitHub sync. In MCP this returns a CLI fallback unless WV_MCP_ALLOW_NETWORK=1 is set.",
        },
        no_overlap_check: {
          type: "boolean",
          description:
            "Skip FTS5 learning-similarity check entirely — no prompt, no advisory. Use in agent/script contexts where stdin is unavailable.",
        },
        verification_method: {
          type: "string",
          description:
            "How the work was verified (e.g., 'make check', 'bash tests/test-core.sh'). Pair with verification_evidence.",
        },
        verification_evidence: {
          type: "string",
          description:
            "Inline verification evidence (test output, command results). Attach for non-trivial closes — closes without evidence draw a post-close advisory.",
        },
      },
      required: ["id"],
    },
  },
  {
    name: "weave_recover",
    description:
      "Resume incomplete multi-step operations. Checks journal for interrupted ship/sync/delete operations and retries the incomplete step. Falls back to ship_pending metadata for reboot recovery. Safe to call anytime — returns empty if no recovery needed.",
    inputSchema: {
      type: "object",
      properties: {
        json: { type: "boolean", description: "Return JSON output" },
        auto: {
          type: "boolean",
          description: "Auto-recover without prompting (non-interactive)",
        },
        session: {
          type: "boolean",
          description: "Inspect orphaned active work for the current session",
        },
      },
    },
  },
  {
    name: "weave_overview",
    description:
      "Get a session-start overview: status summary, health digest, context policy, trails, and ready work. Status and ready sections default to discover mode for agent callers.",
    inputSchema: {
      type: "object",
      properties: {
        mode: {
          type: "string",
          enum: [...READ_MODES],
          description: "Optional output mode override for the status and ready sections (default: discover)",
        },
      },
      required: [],
    },
  },
  {
    name: "weave_bootstrap",
    description:
      "Single-call session context for agents. Returns status, active node with full context pack, ready work, and recent learnings in one JSON blob. Use this instead of calling status+list+show+context+ready+learnings separately.",
    inputSchema: {
      type: "object",
      properties: {
        learnings: {
          type: "number",
          description: "Number of recent learnings to include (default: 5)",
        },
        ready: {
          type: "number",
          description: "Number of ready nodes to include (default: 10)",
        },
      },
      required: [],
    },
  },
  {
    name: "weave_preflight",
    description:
      "Pre-action checks for a node: existence, blockers, done_criteria, contradictions, context load. Returns structured JSON. Call before starting work.",
    inputSchema: {
      type: "object",
      properties: {
        id: {
          type: "string",
          description: "Node ID to check (e.g., wv-a1b2)",
        },
      },
      required: ["id"],
    },
  },
  {
    name: "weave_edit_guard",
    description:
      "MANDATORY: Call this before ANY file edit. Returns OK if an active Weave node exists with no blockers or contradictions. Returns an error if no active node — you must claim work first. This is the MCP equivalent of the PreToolUse hook gate.",
    inputSchema: {
      type: "object",
      properties: {},
      required: [],
    },
  },
  {
    name: "weave_sync",
    description:
      "Persist graph to disk. GitHub/network sync is disabled by default in MCP; when gh=true, the response includes the CLI command to run outside MCP unless WV_MCP_ALLOW_NETWORK=1 is set. Use mode='fast' for routine close paths, full for exhaustive reconcile, repair after an interrupted run.",
    inputSchema: {
      type: "object",
      properties: {
        gh: {
          type: "boolean",
          description: "Request GitHub sync. In MCP this returns a CLI fallback unless WV_MCP_ALLOW_NETWORK=1 is set.",
        },
        mode: {
          type: "string",
          enum: ["fast", "full", "repair"],
          description:
            "Sync mode (default: full). 'fast' bounds work to the focus node and its impacted set; 'repair' resumes from .weave/repair-checkpoint.json after an interrupted run.",
        },
        node: {
          type: "string",
          description: "Focus node id (required for mode='fast' when called outside ship/session-end).",
        },
        dry_run: {
          type: "boolean",
          description: "Show what would be synced without writing",
        },
      },
      required: [],
    },
  },
  {
    name: "weave_resolve",
    description:
      "Resolve contradictions or duplicates between two nodes. Use --winner to pick one, --merge to combine, or --defer to postpone.",
    inputSchema: {
      type: "object",
      properties: {
        node1: {
          type: "string",
          description: "First node ID",
        },
        node2: {
          type: "string",
          description: "Second node ID",
        },
        mode: {
          type: "string",
          enum: ["winner", "merge", "defer"],
          description: "Resolution mode",
        },
        winner: {
          type: "string",
          description: "Winner node ID (required if mode=winner)",
        },
        rationale: {
          type: "string",
          description: "Reason for resolution",
        },
      },
      required: ["node1", "node2", "mode"],
    },
  },
  {
    name: "weave_close_session",
    description:
      "End-of-session checkup: bounded local sync, repo-status checks, active-node warning, and optional GitHub CLI fallback. Pass mode='repair' if the previous sync was interrupted (.weave/repair-checkpoint.json present).",
    inputSchema: {
      type: "object",
      properties: {
        gh: {
          type: "boolean",
          description:
            "Request GitHub sync. In MCP this returns a CLI fallback unless WV_MCP_ALLOW_NETWORK=1 is set. Default: false.",
        },
        mode: {
          type: "string",
          enum: ["fast", "full", "repair"],
          description:
            "Sync mode (default: full). Use 'repair' to resume from .weave/repair-checkpoint.json after an interrupted run.",
        },
      },
      required: [],
    },
  },
  {
    name: "weave_tree",
    description:
      "View epic hierarchy as a tree. Output is capped at 50 nodes (shallowest first) with a truncation summary and '+N more' subtree markers — use root=<id> to expand a marked subtree, or all=true to lift the cap (full dump can be very large). Returns readable text tree by default. Use mermaid=true for a Mermaid dependency graph, or json=true for raw JSON.",
    inputSchema: {
      type: "object",
      properties: {
        active: {
          type: "boolean",
          description: "Filter to non-done subtrees only (default: false)",
        },
        depth: {
          type: "number",
          description: "Maximum recursion depth",
        },
        mermaid: {
          type: "boolean",
          description: "Return Mermaid graph instead of text tree (default: false)",
        },
        json: {
          type: "boolean",
          description: "Return raw JSON array instead of text tree (default: false)",
        },
        root: {
          type: "string",
          description: "Filter to subtree rooted at this node ID or alias",
        },
        all: {
          type: "boolean",
          description: "Lift the 50-node output cap and return the full tree (default: false)",
        },
      },
      required: [],
    },
  },
  {
    name: "weave_learnings",
    description:
      "Query captured learnings as JSON. Defaults to discover-mode bounded output for agent callers; use recent or mode to widen or narrow the result set explicitly.",
    inputSchema: {
      type: "object",
      properties: {
        grep: {
          type: "string",
          description: "Keyword filter (e.g., 'SIGPIPE', 'sync')",
        },
        recent: {
          type: "number",
          description: "Limit to N most recent learnings",
        },
        category: {
          type: "string",
          enum: [...LEARNING_CATEGORIES],
          description: "Filter by learning type",
        },
        node: {
          type: "string",
          description: "Filter to learnings from a specific node",
        },
        mode: {
          type: "string",
          enum: [...READ_MODES],
          description: "Optional output mode override (default: discover for MCP/agent callers)",
        },
        min_quality: {
          type: "number",
          description: "Minimum hygiene score (0-5); filters out low-quality learnings",
        },
        dedup: {
          type: "boolean",
          description: "Find and surface duplicate/redundant learnings via token overlap",
        },
        all: {
          type: "boolean",
          description: "Include all learnings (bypasses the junk/template filter)",
        },
      },
      required: [],
    },
  },
  {
    name: "weave_update",
    description:
      "Modify a node's metadata, status, text, or alias. Metadata is MERGED into existing keys (not replaced). Use remove_key to delete individual metadata keys.",
    inputSchema: {
      type: "object",
      properties: {
        id: {
          type: "string",
          description: "Node ID (e.g., wv-a1b2)",
        },
        status: {
          type: "string",
          enum: [...STATUS_SCHEMA_VALUES],
          description: "New status (legacy in-progress/in_progress map to active)",
        },
        text: {
          type: "string",
          description: "New node text/description",
        },
        metadata: {
          type: "object",
          description:
            "JSON metadata to merge into existing keys (e.g., {commit: 'abc123'}). Existing keys are preserved.",
        },
        alias: {
          type: "string",
          description: "Human-readable alias",
        },
        remove_key: {
          type: "string",
          description: "Remove a single metadata key by name (e.g., 'gh_issue')",
        },
      },
      required: ["id"],
    },
  },
  {
    name: "weave_touch",
    description:
      "Fire-and-forget metadata write. Updates node metadata silently with zero token cost — no output returned. Use for per-turn intent setting or lightweight metadata updates where confirmation is not needed.",
    inputSchema: {
      type: "object",
      properties: {
        id: {
          type: "string",
          description: "Node ID (e.g., wv-a1b2)",
        },
        metadata: {
          type: "object",
          description: "JSON metadata to merge into existing keys",
        },
        intent: {
          type: "string",
          description: "Shorthand for setting current_intent metadata (alternative to metadata param)",
        },
      },
      required: ["id"],
    },
  },
  {
    name: "weave_record_edit",
    description:
      "Record a file path as touched by the active node. Writes directly to node_files for impact attribution. Call after each file edit on surfaces where the PostToolUse hook is unavailable (VS Code Copilot, Codex CLI).",
    inputSchema: {
      type: "object",
      properties: {
        id: {
          type: "string",
          description: "Node ID (e.g., wv-a1b2)",
        },
        path: {
          type: "string",
          description: "Repo-relative file path that was edited (e.g., src/utils/helpers.ts)",
        },
        intent: {
          type: "string",
          description: "Free-text intent note merged into node metadata (wv touch --intent)",
        },
        metadata: {
          type: "object",
          description: "JSON metadata to merge silently into the node (wv touch --metadata)",
        },
      },
      required: ["id"],
    },
  },
  {
    name: "weave_trails",
    description:
      "Save, show, or clear session trails (append-only handoff path). Use to leave context notes for future sessions or agents.",
    inputSchema: {
      type: "object",
      properties: {
        action: {
          type: "string",
          enum: ["save", "show", "clear"],
          description: "Action to perform (default: show)",
        },
        message: {
          type: "string",
          description: "Session note to save (required when action is 'save')",
        },
      },
      required: [],
    },
  },
  {
    name: "weave_breadcrumbs",
    description: "Deprecated alias for weave_trails (kept one release for back-compat). Use weave_trails.",
    inputSchema: {
      type: "object",
      properties: {
        action: {
          type: "string",
          enum: ["save", "show", "clear"],
          description: "Action to perform (default: show)",
        },
        message: {
          type: "string",
          description: "Session note to save (required when action is 'save')",
        },
      },
      required: [],
    },
  },
  {
    name: "weave_guide",
    description:
      "Workflow quick reference for Weave. Returns human-readable guidance on the core workflow, GitHub integration, learnings format, or context policy. Call with no topic for the 5-step workflow overview.",
    inputSchema: {
      type: "object",
      properties: {
        topic: {
          type: "string",
          enum: [
            "workflow",
            "github",
            "learnings",
            "context",
            "routing",
            "mcp",
            "verification",
            "instrumentation",
            "config",
            "discovery",
          ],
          description:
            "Topic to show: workflow (default, 5-step process), github (issue integration), learnings (format + commands), context (load policy + wv context usage), routing (phase loop + tool classes), mcp (server setup + tools), verification (test-map + gate flow), instrumentation (opt-in knobs), config (durable knobs), discovery (read-only audit toolset)",
        },
        procedure: {
          type: "string",
          description: "Installed canonical procedure id. Mutually exclusive with topic; returns the procedure body.",
        },
      },
      required: [],
    },
  },
  {
    name: "weave_plan",
    description:
      "Import a markdown plan file as an epic with linked task nodes. One call creates epic + N tasks + implements edges + optional GitHub issues. The plan file must have '### Sprint N: Title' sections with numbered tasks.",
    inputSchema: {
      type: "object",
      properties: {
        file: {
          type: "string",
          description: "Path to markdown plan file",
        },
        sprint: {
          type: "number",
          description: "Which sprint section to import (e.g., 1, 2, 3)",
        },
        gh: {
          type: "boolean",
          description: "Create linked GitHub issues for each node",
        },
        dry_run: {
          type: "boolean",
          description: "Preview what would be created without creating nodes",
        },
        template: {
          type: "boolean",
          description: "Emit the plan template instead of importing (file/sprint not needed)",
        },
      },
      required: [],
    },
  },
  {
    name: "weave_show",
    description:
      "Show a single node as compact json-v2. Metadata is promoted to a nested object and heavy timestamps are omitted for lean agent use.",
    inputSchema: {
      type: "object",
      properties: {
        id: {
          type: "string",
          description: "Node ID (wv-XXXXXX) or alias",
        },
      },
      required: ["id"],
    },
  },
  {
    name: "weave_delete",
    description:
      "Permanently remove a Weave node and its edges. DESTRUCTIVE — requires force=true to confirm. Use dry_run=true to preview what would be deleted.",
    inputSchema: {
      type: "object",
      properties: {
        id: {
          type: "string",
          description: "Node ID (wv-XXXXXX) or alias to delete",
        },
        force: {
          type: "boolean",
          description: "REQUIRED: must be true to confirm deletion",
        },
        dry_run: {
          type: "boolean",
          description: "Preview what would be deleted without actually deleting",
        },
        no_gh: {
          type: "boolean",
          description: "Skip closing linked GitHub issue",
        },
      },
      required: ["id", "force"],
    },
  },
  {
    name: "weave_quality_scan",
    description:
      "Scan a codebase directory for quality metrics (complexity, churn, hotspots). Creates or updates a quality.db in the target directory. Returns summary with file count, scan time, and quality score.",
    inputSchema: {
      type: "object",
      properties: {
        path: {
          type: "string",
          description: "Directory to scan (defaults to current repo root)",
        },
        exclude: {
          type: "string",
          description: "Glob pattern to exclude (e.g., 'test/**')",
        },
      },
    },
  },
  {
    name: "weave_quality_hotspots",
    description:
      "Show ranked hotspot report from the most recent quality scan. Hotspots are files with high complexity × high churn. Returns top findings sorted by score.",
    inputSchema: {
      type: "object",
      properties: {
        path: {
          type: "string",
          description: "Directory containing quality.db (defaults to current repo root)",
        },
        limit: {
          type: "number",
          description: "Maximum hotspots to return (default: 10)",
        },
        threshold: {
          type: "number",
          description: "Minimum score threshold (0-100, default: 0)",
        },
      },
    },
  },
  {
    name: "weave_quality_diff",
    description:
      "Show delta report comparing current quality scan against the previous one. Highlights new hotspots, resolved hotspots, and score changes.",
    inputSchema: {
      type: "object",
      properties: {
        path: {
          type: "string",
          description: "Directory containing quality.db (defaults to current repo root)",
        },
      },
    },
  },
  {
    name: "weave_quality_functions",
    description:
      "Show per-function cyclomatic complexity (CC) report for a file or directory. Dispatch-tagged functions are identified. Returns all functions with CC > threshold (default: 10).",
    inputSchema: {
      type: "object",
      properties: {
        path: {
          type: "string",
          description: "File or directory to analyse (defaults to current repo root)",
        },
        threshold: {
          type: "number",
          description: "CC threshold — only show functions at or above this value (default: 10)",
        },
      },
    },
  },
  {
    name: "weave_structural_search",
    description:
      "Find code by structural AST pattern using ast-grep (tree-sitter). Matches code structure, not text. Use for: finding all calls to a function, all try/except patterns, all for-loops with a condition. Requires ast-grep binary (install via ./install.sh). Returns [{file, line, column, match_text, node_kind}]. Use alongside semble (semantic) and weave_code_search (FTS) for orthogonal search.",
    inputSchema: {
      type: "object",
      properties: {
        pattern: {
          type: "string",
          description: "ast-grep structural pattern (e.g. '$F($$$ARGS)' matches any function call)",
        },
        lang: {
          type: "string",
          description: "Language: python, bash, typescript, go, rust, javascript, ...",
        },
        repo: {
          type: "string",
          description: "Repository root to search (defaults to current repo root)",
        },
      },
      required: ["pattern", "lang"],
    },
  },
  {
    name: "weave_quality_patterns",
    description:
      "Run structural and prose quality rules, validate rule definitions, adjudicate stable findings, and report per-rule decided precision and recurring waivers. Scanner results remain unadjudicated evidence until labeled.",
    inputSchema: {
      type: "object",
      properties: {
        subcommand: {
          type: "string",
          enum: ["scan", "list", "validate", "adjudicate", "report", "promote"],
          description:
            "scan: run rules; list: show rule receipts (response additively includes scope and shadow_advisories, see below); validate: check every candidate rule file independently and report prose schema coverage; adjudicate: label a stable finding; report: decided precision and recurring waivers, scoped to path; promote: create Weave nodes",
        },
        path: {
          type: "string",
          description:
            "For list/validate: the repository ROOT (base for .weave/patterns/ rule lookup) — must be a directory; a file here silently limits results to built-in rules only, since that project's own custom/managed rules are never found (default: current repo root). For scan/report: a scan TARGET within the repo — a single file or a directory (default for scan: current repo root; for report: the last scan's own target). Not applicable to adjudicate/promote.",
        },
        parent: {
          type: "string",
          description: "Parent node ID for promoted findings (promote only, required there)",
        },
        dry_run: {
          type: "boolean",
          description: "Show what promote would create without creating nodes",
        },
        finding_key: {
          type: "string",
          description: "Stable qf-* finding key (adjudicate only)",
        },
        disposition: {
          type: "string",
          enum: ["accepted_defect", "false_positive", "waived", "unresolved"],
          description: "Human finding disposition (adjudicate only)",
        },
        note: {
          type: "string",
          description: "Human rationale or waiver reference (adjudicate only)",
        },
      },
      required: ["subcommand"],
    },
  },
  {
    name: "weave_code_search",
    description:
      "Hybrid code search over indexed chunks (FTS5 BM25 + cosine RRF blend). Run weave_index first. Returns file locations with relevance scores and optional Weave node context. Use instead of semble for project-local code search.",
    inputSchema: {
      type: "object",
      properties: {
        query: {
          type: "string",
          description: "Natural-language or code query",
        },
        limit: {
          type: "number",
          description: "Max results (default: 10)",
        },
        mode: {
          type: "string",
          enum: ["hybrid", "fts", "vector"],
          description: "Search mode (default: hybrid)",
        },
        graph: {
          type: "boolean",
          description: "Attach active Weave nodes and quality churn to results",
        },
        filter: {
          type: "string",
          description: "Constrain code chunks by graph edge type (--filter expression)",
        },
      },
      required: ["query"],
    },
  },
  {
    name: "weave_index",
    description:
      "Index code files into brain.db chunks table for semantic search. Must be run before weave_code_search. Stores FTS5 content and float32 embeddings.",
    inputSchema: {
      type: "object",
      properties: {
        path: {
          type: "string",
          description: "Root directory to index (default: project root)",
        },
        no_embed: {
          type: "boolean",
          description: "Skip embeddings, index FTS content only",
        },
        ext: {
          type: "string",
          description: "Comma-separated extensions (default: .py .ts .js .sh .go .rs .md)",
        },
      },
    },
  },
];

// Filter tools based on active scope
function getToolsForScope(scope: Scope, allTools: Tool[]): Tool[] {
  if (scope === "all") return allTools;
  const allowed = new Set(SCOPE_TOOLS[scope]);
  return allTools.filter((t) => allowed.has(t.name));
}

const SCOPED_TOOLS = getToolsForScope(ACTIVE_SCOPE, TOOLS);

// --- Instrumentation ---
// Logs payload sizes and per-tool call counts to stderr for baseline measurement.
// Enable with --instrument flag; disable in production.
const INSTRUMENT = process.argv.includes("--instrument");
const MCP_CALL_LOG = process.env.WV_MCP_CALL_LOG || "";
const toolCallCounts = new Map<string, number>();
const toolPayloadStats = new Map<string, { calls: number; totalBytes: number; maxBytes: number }>();
let mcpCallLogWarned = false;

function logInstrumentation(msg: string): void {
  if (INSTRUMENT) console.error(`[weave-mcp-instrument] ${msg}`);
}

function extraFields(extra: string[]): Record<string, string | boolean | number> {
  const fields: Record<string, string | boolean | number> = {};
  for (const item of extra) {
    const [key, ...rest] = item.split("=");
    if (!key || rest.length === 0) continue;
    const value = rest.join("=");
    if (value === "true" || value === "false") fields[key] = value === "true";
    else if (/^-?\d+$/.test(value)) fields[key] = Number(value);
    else fields[key] = value;
  }
  return fields;
}

function appendMcpCallLog(entry: Record<string, unknown>): void {
  if (!MCP_CALL_LOG) return;
  try {
    mkdirSync(dirname(MCP_CALL_LOG), { recursive: true });
    appendFileSync(MCP_CALL_LOG, `${JSON.stringify(entry)}\n`, "utf8");
  } catch (error: unknown) {
    if (mcpCallLogWarned) return;
    mcpCallLogWarned = true;
    const err = error as Error;
    console.error(`[weave-mcp-instrument] MCP call log disabled: ${err.message}`);
  }
}

function recordPayloadInstrumentation(tool: string, payload: unknown, extra: string[] = [], elapsedMs?: number): void {
  if (!INSTRUMENT && !MCP_CALL_LOG) return;
  const bytes = Buffer.byteLength(JSON.stringify(payload), "utf8");
  if (INSTRUMENT) {
    const stats = toolPayloadStats.get(tool) ?? { calls: 0, totalBytes: 0, maxBytes: 0 };
    stats.calls += 1;
    stats.totalBytes += bytes;
    stats.maxBytes = Math.max(stats.maxBytes, bytes);
    toolPayloadStats.set(tool, stats);
    const suffix = extra.length > 0 ? ` ${extra.join(" ")}` : "";
    logInstrumentation(`payload scope=${ACTIVE_SCOPE} tool=${tool} payload_bytes=${bytes}${suffix}`);
  }
  appendMcpCallLog({
    ts: Date.now() / 1000,
    source: "mcp",
    scope: ACTIVE_SCOPE,
    tool,
    payload_bytes: bytes,
    ...(elapsedMs === undefined ? {} : { elapsed_ms: elapsedMs }),
    ...extraFields(extra),
  });
}

if (INSTRUMENT) {
  process.on("exit", () => {
    if (toolPayloadStats.size > 0) {
      const sortedPayloads = [...toolPayloadStats.entries()].sort((a, b) => b[1].totalBytes - a[1].totalBytes);
      console.error(`[weave-mcp-instrument] === Payload summary (scope=${ACTIVE_SCOPE}) ===`);
      for (const [tool, stats] of sortedPayloads) {
        const avgBytes = Math.round(stats.totalBytes / stats.calls);
        console.error(
          `[weave-mcp-instrument]   ${tool}: calls=${stats.calls} total_bytes=${stats.totalBytes} avg_bytes=${avgBytes} max_bytes=${stats.maxBytes}`
        );
      }
    }
    if (toolCallCounts.size === 0) return;
    const sorted = [...toolCallCounts.entries()].sort((a, b) => b[1] - a[1]);
    console.error(`[weave-mcp-instrument] === Call summary (scope=${ACTIVE_SCOPE}) ===`);
    for (const [tool, count] of sorted) {
      console.error(`[weave-mcp-instrument]   ${tool}: ${count}`);
    }
  });
}

// Normalize legacy status values to canonical enum
function normalizeStatus(status: string | undefined): string | undefined {
  if (!status) return status;
  const COMPAT_MAP: Record<string, string> = {
    "in-progress": "active",
    in_progress: "active",
  };
  return COMPAT_MAP[status] ?? status;
}

// Tool handlers
// ── Tool dispatch table ──────────────────────────────────────────────────────
// Each handler returns either the result text or, for enforcement paths
// (preflight/edit_guard), a complete ToolResponse envelope with isError set.
type ToolResponse = { content: { type: "text"; text: string }[]; isError?: boolean };
type ToolHandler = (args: Record<string, unknown>) => string | ToolResponse;

const TOOL_HANDLERS: Record<string, ToolHandler> = {
  weave_search: (args) => {
    let result: string;
    const query = args.query as string;
    const limit = args.limit as number | undefined;
    const status = normalizeStatus(args.status as string | undefined);
    const nodeType = args.type as string | undefined;
    const cmd = ["search", query, "--json"];
    if (limit) cmd.push(`--limit=${limit}`);
    if (status) cmd.push(`--status=${status}`);
    if (nodeType) cmd.push(`--type=${nodeType}`);
    result = wv(cmd);
    return result;
  },

  weave_add: (args) => {
    let result: string;
    const text = args.text as string;
    const status = normalizeStatus(args.status as string | undefined);
    const metadata = args.metadata as Record<string, unknown> | undefined;
    const gh = args.gh as boolean | undefined;
    const alias = args.alias as string | undefined;
    const parent = args.parent as string | undefined;
    const force = args.force as boolean | undefined;
    const standalone = args.standalone as boolean | undefined;
    const criteria = args.criteria as string | undefined;
    const risks = args.risks as string | undefined;
    const verificationPlan = args.verification_plan as string | undefined;
    const cmd = ["add", text];
    if (status) cmd.push(`--status=${status}`);
    if (metadata) cmd.push(`--metadata=${JSON.stringify(metadata)}`);
    if (gh) cmd.push("--gh");
    if (alias) cmd.push(`--alias=${alias}`);
    if (parent) cmd.push(`--parent=${parent}`);
    if (standalone) cmd.push("--standalone");
    else if (force) cmd.push("--force");
    if (criteria) cmd.push(`--criteria=${criteria}`);
    if (risks) cmd.push(`--risks=${risks}`);
    if (verificationPlan) cmd.push(`--verification-plan=${verificationPlan}`);
    result = wv(cmd);
    // Enforcement warnings — suppress --gh nudge for child nodes (only epic needs a GH issue)
    const warnings: string[] = [];
    if (!gh && !parent) warnings.push("WARNING: No --gh flag. Node has no GitHub issue. Use gh=true for traceability.");
    if (!alias) warnings.push("WARNING: No alias set. Use alias parameter for readable node names.");
    if (warnings.length) result += "\n\n" + warnings.join("\n");
    return result;
  },

  weave_done: (args) => {
    let result: string;
    const id = args.id as string;
    let learning = args.learning as string | undefined;
    const decision = args.decision as string | undefined;
    const pattern = args.pattern as string | undefined;
    const pitfall = args.pitfall as string | undefined;
    const noWarn = args.no_warn as boolean | undefined;
    const noOverlapCheck = args.no_overlap_check as boolean | undefined;

    // Compose pipe-delimited learning string from typed params
    // Merge: typed params compose structured prefix; raw learning appended as context
    if (decision || pattern || pitfall) {
      const parts: string[] = [];
      if (decision) parts.push(`decision: ${decision}`);
      if (pattern) parts.push(`pattern: ${pattern}`);
      if (pitfall) parts.push(`pitfall: ${pitfall}`);
      const structured = parts.join(" | ");
      learning = learning ? `${structured} | ${learning}` : structured;
    }

    const verificationMethod = args.verification_method as string | undefined;
    const verificationEvidence = args.verification_evidence as string | undefined;
    const completionFiles = args.completion_files as string[] | undefined;
    const cmd = ["done", id];
    if (learning) cmd.push(`--learning=${learning}`);
    if (verificationMethod) cmd.push(`--verification-method=${verificationMethod}`);
    if (verificationEvidence) cmd.push(`--verification-evidence=${verificationEvidence}`);
    if (completionFiles) cmd.push(`--completion-files=${completionFiles.join(",")}`);
    if (noWarn) cmd.push("--no-warn");
    if (noOverlapCheck) cmd.push("--no-overlap-check");
    if (!MCP_ALLOW_NETWORK) cmd.push("--no-gh");
    result = wv(cmd, WV_LIFECYCLE_TIMEOUT);
    if (!learning && !decision && !pattern && !pitfall)
      result +=
        "\n\nWARNING: No learning captured. Consider: what decision, pattern, or pitfall should future sessions know?";
    return result;
  },

  weave_batch_done: (args) => {
    let result: string;
    const ids = args.ids as string[];
    let learning = args.learning as string | undefined;
    const decision = args.decision as string | undefined;
    const pattern = args.pattern as string | undefined;
    const pitfall = args.pitfall as string | undefined;
    const noWarn = args.no_warn as boolean | undefined;

    if (decision || pattern || pitfall) {
      const parts: string[] = [];
      if (decision) parts.push(`decision: ${decision}`);
      if (pattern) parts.push(`pattern: ${pattern}`);
      if (pitfall) parts.push(`pitfall: ${pitfall}`);
      const structured = parts.join(" | ");
      learning = learning ? `${structured} | ${learning}` : structured;
    }

    const cmd = ["batch-done", ...ids];
    if (learning) cmd.push(`--learning=${learning}`);
    if (noWarn) cmd.push("--no-warn");
    if (!MCP_ALLOW_NETWORK) cmd.push("--no-gh");
    result = wv(cmd);
    return result;
  },

  weave_context: (args) => {
    let result: string;
    const id = args.id as string | undefined;
    const mode = args.mode as ReadMode | undefined;
    const cmd = id ? ["context", id, "--json"] : ["context", "--json"];
    result = wvRead(cmd, WV_TIMEOUT, mode);
    return result;
  },

  weave_list: (args) => {
    let result: string;
    const status = normalizeStatus(args.status as string | undefined);
    const all = args.all as boolean | undefined;
    const mode = args.mode as ReadMode | undefined;
    const cmd = ["list", "--json-v2"];
    if (status) cmd.push(`--status=${status}`);
    if (all) cmd.push("--all");
    result = wvRead(cmd, WV_TIMEOUT, mode);
    return result;
  },

  weave_link: (args) => {
    let result: string;
    const from = args.from_id as string;
    const to = args.to_id as string;
    const type = args.type as string;
    const weight = args.weight as number | undefined;
    const context = args.context as string | undefined;
    const cmd = ["link", from, to, `--type=${type}`];
    if (weight !== undefined) cmd.push(`--weight=${weight}`);
    if (context) cmd.push(`--context=${context}`);
    result = wv(cmd);
    return result;
  },

  weave_unlink: (args) => {
    let result: string;
    const from = args.from_id as string;
    const to = args.to_id as string;
    const type = args.type as string;
    result = wv(["unlink", from, to, `--type=${type}`]);
    return result;
  },

  weave_block: (args) => {
    let result: string;
    const from = args.from_id as string;
    const to = args.to_id as string;
    const context = args.context as string | undefined;
    const cmd = ["block", from, to];
    if (context) cmd.push(`--context=${context}`);
    result = wv(cmd);
    return result;
  },

  weave_unarchive: (args) => {
    let result: string;
    const id = args.id as string;
    const dryRun = args.dry_run as boolean | undefined;
    const withEdges = args.with_edges as boolean | undefined;
    const cmd = ["unarchive", id];
    if (dryRun) cmd.push("--dry-run");
    if (withEdges) cmd.push("--with-edges");
    result = wv(cmd);
    return result;
  },

  weave_status: (args) => {
    let result: string;
    const mode = args.mode as ReadMode | undefined;
    result = wvRead(["status"], WV_TIMEOUT, mode);
    return result;
  },

  weave_ready: (args) => {
    let result: string;
    const subtree = args.subtree as string | undefined;
    const all = args.all as boolean | undefined;
    const count = args.count as boolean | undefined;
    const mode = args.mode as ReadMode | undefined;
    const withImpact = args.with_impact as boolean | undefined;
    const cmd = ["ready", "--json"];
    if (subtree) cmd.push(`--subtree=${subtree}`);
    if (all) cmd.push("--all");
    if (count) cmd.push("--count");
    if (withImpact) cmd.push("--with-impact");
    result = wvRead(cmd, WV_TIMEOUT, mode);
    return result;
  },

  weave_impact: (args) => {
    let result: string;
    const ids = (args.ids as string[] | undefined) ?? [];
    const files = args.files as string | undefined;
    if (ids.length === 0 && !files) {
      throw new Error("weave_impact requires seed ids in 'ids' or paths in 'files'");
    }
    const depth = args.depth as number | undefined;
    const direction = args.direction as string | undefined;
    const full = args.full as boolean | undefined;
    const includeDone = args.include_done as boolean | undefined;
    const all = args.all as boolean | undefined;
    const quality = args.quality as boolean | undefined;

    const cmd = ["impact", ...ids, "--json"];
    if (files) cmd.push(`--files=${files}`);
    if (depth !== undefined) cmd.push(`--depth=${depth}`);
    if (direction) cmd.push(`--direction=${direction}`);
    if (full) cmd.push("--full");
    if (includeDone) cmd.push("--include-done");
    if (all) cmd.push("--all");
    if (quality) cmd.push("--quality");
    result = wv(cmd);
    return result;
  },

  weave_query: (args) => {
    let result: string;
    const predicates = (args.predicates as string[] | undefined) ?? [];
    const format = (args.format as string | undefined) ?? "json";
    const order = args.order as string | undefined;
    const limit = args.limit as number | undefined;
    const include = args.include as string | undefined;
    const cmd = ["query", `--format=${format}`];
    if (order) cmd.push(`--order=${order}`);
    if (limit !== undefined) cmd.push(`--limit=${limit}`);
    if (include) cmd.push(`--include=${include}`);
    for (const p of predicates) {
      if (p.startsWith("HAS ") || p.startsWith("MATCH ")) {
        const [kw, ...rest] = p.split(" ");
        cmd.push(kw, rest.join(" "));
      } else {
        cmd.push(p);
      }
    }
    // wv query is the only read command without --mode support — wvRead's
    // appended --mode=discover makes it error (codex finding, v1.59.0).
    result = wv(cmd, WV_TIMEOUT);
    return result;
  },

  weave_health: (args) => {
    let result: string;
    const verbose = args.verbose as boolean | undefined;
    const fix = args.fix as boolean | undefined;
    const history = args.history as number | undefined;
    if (!verbose && !fix && history === undefined) {
      return wvHealthJson();
    }
    const cmd = ["health", "--json"];
    if (verbose) cmd.push("--verbose");
    if (fix) cmd.push("--fix");
    if (history !== undefined) cmd.push(`--history=${history}`);
    result = wv(cmd);
    return result;
  },

  weave_quick: (args) => {
    let result: string;
    const text = args.text as string;
    const learning = args.learning as string | undefined;
    const cmd = ["quick", text];
    if (learning) cmd.push(`--learning=${learning}`);
    result = wv(cmd);
    return result;
  },

  weave_work: (args) => {
    let result: string;
    const id = args.id as string;
    const reopen = args.reopen as boolean | undefined;
    const cmd = ["work", id];
    if (reopen) cmd.push("--reopen");
    result = wv(cmd);
    return result;
  },

  weave_ship: (args) => {
    let result: string;
    const id = args.id as string;
    let learning = args.learning as string | undefined;
    const decision = args.decision as string | undefined;
    const pattern = args.pattern as string | undefined;
    const pitfall = args.pitfall as string | undefined;
    const gh = args.gh as boolean | undefined;
    const noOverlapCheck = args.no_overlap_check as boolean | undefined;

    // Compose pipe-delimited learning string from typed params
    // Merge: typed params compose structured prefix; raw learning appended as context
    if (decision || pattern || pitfall) {
      const parts: string[] = [];
      if (decision) parts.push(`decision: ${decision}`);
      if (pattern) parts.push(`pattern: ${pattern}`);
      if (pitfall) parts.push(`pitfall: ${pitfall}`);
      const structured = parts.join(" | ");
      learning = learning ? `${structured} | ${learning}` : structured;
    }

    const verificationMethod = args.verification_method as string | undefined;
    const verificationEvidence = args.verification_evidence as string | undefined;
    const cmd = ["ship-agent", id, "--json"];
    if (learning) cmd.push(`--learning=${learning}`);
    if (verificationMethod) cmd.push(`--verification-method=${verificationMethod}`);
    if (verificationEvidence) cmd.push(`--verification-evidence=${verificationEvidence}`);
    const networkFallback = gh && !MCP_ALLOW_NETWORK ? mcpNetworkFallback(`wv sync --gh --mode=fast --node=${id}`) : "";
    if (gh && MCP_ALLOW_NETWORK) cmd.push("--gh");
    if (!MCP_ALLOW_NETWORK) cmd.push("--no-gh");
    if (noOverlapCheck) cmd.push("--no-overlap-check");
    result = wv(cmd, WV_LIFECYCLE_TIMEOUT);
    if (networkFallback) result += `\n\n${networkFallback}`;
    return result;
  },

  weave_recover: (args) => {
    let result: string;
    const cmd = ["recover"];
    if ((args as Record<string, unknown>).json) cmd.push("--json");
    if ((args as Record<string, unknown>).auto) cmd.push("--auto");
    if ((args as Record<string, unknown>).session) cmd.push("--session");
    result = wv(cmd);
    return result;
  },

  weave_overview: (args) => {
    let result: string;
    const mode = args.mode as ReadMode | undefined;
    const parts: string[] = [];
    try {
      parts.push("=== Status ===\n" + wvRead(["status"], WV_TIMEOUT, mode));
    } catch {
      /* skip */
    }
    try {
      parts.push("\n=== Digest ===\n" + wv(["digest"]));
    } catch {
      /* skip */
    }
    try {
      parts.push("\n=== Trails ===\n" + wv(["trails", "show"]));
    } catch {
      /* skip */
    }
    try {
      parts.push("\n=== Ready Work ===\n" + wvRead(["ready"], WV_TIMEOUT, mode));
    } catch {
      /* skip */
    }
    // Context load policy (replaces session-start hook injection)
    // Try dev layout first (__dirname/../../scripts/), then installed (~/.config/weave/)
    try {
      const devPath = `${__dirname}/../../scripts/context-guard.sh`;
      const installedPath = `${process.env.HOME}/.config/weave/context-guard.sh`;
      let scriptPath: string | undefined;
      try {
        accessSync(devPath, constants.X_OK);
        scriptPath = devPath;
      } catch {
        /* not dev */
      }
      if (!scriptPath) {
        try {
          accessSync(installedPath, constants.X_OK);
          scriptPath = installedPath;
        } catch {
          /* not installed */
        }
      }
      if (scriptPath) {
        const policy = execFileSync("bash", [scriptPath], {
          encoding: "utf-8",
          timeout: 5000,
          env: { ...process.env, NO_COLOR: "1", WV_AGENT: "1" },
        }).trim();
        const policyLine = policy.split("\n").find((l) => l.startsWith("policy:"));
        if (policyLine) parts.push("\n=== Context Policy ===\n" + policyLine);
      } else {
        parts.push("\n=== Context Policy ===\nUnavailable (context-guard.sh not found)");
      }
    } catch {
      /* skip — context-guard.sh execution failed */
    }
    result = parts.join("\n");
    return result;
  },

  weave_bootstrap: (args) => {
    let result: string;
    const learnings = args.learnings as number | undefined;
    const ready = args.ready as number | undefined;
    const cmd = ["bootstrap", "--json"];
    if (learnings) cmd.push(`--learnings=${learnings}`);
    if (ready) cmd.push(`--ready=${ready}`);
    result = wv(cmd);
    return result;
  },

  weave_preflight: (args) => {
    let result: string;
    const id = args.id as string;
    const preflightJson = wv(["preflight", id]);
    // Parse preflight result and return isError for enforcement conditions
    try {
      const pf = JSON.parse(preflightJson);
      if (!pf.node_exists) {
        return {
          content: [
            {
              type: "text",
              text: `Error: Node ${id} not found. Use weave_search, weave_ready, or weave_bootstrap to find available nodes.`,
            },
          ],
          isError: true,
        };
      }
      if (!pf.node_active) {
        return {
          content: [
            {
              type: "text",
              text: `Warning: Node ${id} is not active. Claim it first with \`wv work ${id}\` before editing files.`,
            },
          ],
          isError: false,
        };
      }
      if (Array.isArray(pf.contradictions) && pf.contradictions.length > 0) {
        return {
          content: [
            {
              type: "text",
              text: `Error: Contradictions detected on node ${id}:\n${pf.contradictions.join("\n")}\n\nResolve with \`wv resolve\` before proceeding.`,
            },
          ],
          isError: true,
        };
      }
      if (pf.has_blockers) {
        return {
          content: [
            {
              type: "text",
              text: `Error: Node ${id} has unresolved blockers. Complete blocking work first or run \`wv show ${id}\` to see blockers.`,
            },
          ],
          isError: true,
        };
      }
      if (pf.policy_readiness?.blocking) {
        const detail = pf.policy_readiness.detail || "Policy-sensitive completion is not ready.";
        const hint = pf.policy_readiness.hint ? `\n\n${pf.policy_readiness.hint}` : "";
        return {
          content: [
            {
              type: "text",
              text: `Error: Node ${id} is not policy-ready.\n${detail}${hint}`,
            },
          ],
          isError: true,
        };
      }
    } catch {
      // JSON parse failed — fall through with raw output
    }
    result = preflightJson;
    return result;
  },

  weave_edit_guard: () => {
    let result: string;
    // Mirror pre-action.sh: check for active node, contradictions, blockers
    // Returns isError:true if no active node — Copilot sees this as a blocking error
    try {
      const activeJson = wv(["list", "--status=active", "--json"]);
      const activeNodes = JSON.parse(activeJson);
      if (!Array.isArray(activeNodes) || activeNodes.length === 0) {
        return {
          content: [
            {
              type: "text",
              text: [
                "ERROR: No active Weave node. You MUST claim work before editing files.",
                "",
                "Run one of:",
                "  wv work <id>                         — Claim an existing task",
                '  wv add "<description>" --gh --alias=<short-name> --status=active --criteria="c1|c2" --risks=low  — Create + claim new task',
                '  wv quick "<description>"             — Track trivial one-step work',
                "",
                'Use `wv search "<topic>"`, `wv ready`, `wv bootstrap --json`, weave_overview, or weave_bootstrap to find available work.',
              ].join("\n"),
            },
          ],
          isError: true,
        };
      }
      // Active node exists — check for contradictions and blockers
      const nodeId = activeNodes[0].id as string;
      try {
        const ctxJson = wvRead(["context", nodeId, "--json"]);
        const ctx = JSON.parse(ctxJson);
        if (Array.isArray(ctx.contradictions) && ctx.contradictions.length > 0) {
          const contraList = ctx.contradictions
            .map((c: { id: string; text: string }) => `  - ${c.id}: ${c.text}`)
            .join("\n");
          return {
            content: [
              {
                type: "text",
                text: `ERROR: Contradictions detected on active node ${nodeId}:\n${contraList}\n\nResolve with \`wv resolve\` before editing files.`,
              },
            ],
            isError: true,
          };
        }
        const unresolvedBlockers = Array.isArray(ctx.blockers)
          ? ctx.blockers.filter((b: { status: string }) => b.status !== "done")
          : [];
        if (unresolvedBlockers.length > 0) {
          const blockerList = unresolvedBlockers
            .map((b: { id: string; text: string }) => `  - ${b.id}: ${b.text}`)
            .join("\n");
          return {
            content: [
              {
                type: "text",
                text: `ERROR: Active node ${nodeId} has unresolved blockers:\n${blockerList}\n\nComplete blocking work first.`,
              },
            ],
            isError: true,
          };
        }
      } catch {
        // Context pack generation failed — warn but allow (graceful degradation)
      }
      result = `OK: Active node ${nodeId} — "${activeNodes[0].text}". Proceed with edit.`;
    } catch {
      // wv not available or DB not loaded — allow (graceful degradation)
      result = "OK: Weave not available — edit guard skipped.";
    }
    return result;
  },

  weave_sync: (args) => {
    let result: string;
    const gh = args.gh as boolean | undefined;
    const mode = args.mode as string | undefined;
    const node = args.node as string | undefined;
    const networkFallback =
      gh && !MCP_ALLOW_NETWORK
        ? mcpNetworkFallback(`wv sync --gh${mode ? ` --mode=${mode}` : ""}${node ? ` --node=${node}` : ""}`)
        : "";
    const dryRun = args.dry_run as boolean | undefined;
    const cmd = gh && MCP_ALLOW_NETWORK ? ["sync", "--gh"] : ["sync"];
    if (mode) cmd.push(`--mode=${mode}`);
    if (node) cmd.push(`--node=${node}`);
    if (dryRun) cmd.push("--dry-run");
    result = wv(cmd, WV_LIFECYCLE_TIMEOUT);
    if (networkFallback) result += `\n\n${networkFallback}`;
    return result;
  },

  weave_resolve: (args) => {
    let result: string;
    const node1 = args.node1 as string;
    const node2 = args.node2 as string;
    const mode = args.mode as string;
    const winner = args.winner as string | undefined;
    const rationale = args.rationale as string | undefined;
    const cmd = ["resolve", node1, node2];
    if (mode === "winner" && winner) {
      cmd.push(`--winner=${winner}`);
    } else if (mode === "merge") {
      cmd.push("--merge");
    } else if (mode === "defer") {
      cmd.push("--defer");
    }
    if (rationale) cmd.push(`--rationale=${rationale}`);
    result = wv(cmd);
    return result;
  },

  weave_close_session: (args) => {
    let result: string;
    const gh = (args.gh as boolean) ?? false;
    const mode = args.mode as string | undefined;
    const parts: string[] = [];

    // 1. Sync graph (+ optional GH)
    try {
      const syncCmd = gh && MCP_ALLOW_NETWORK ? ["sync", "--gh"] : ["sync"];
      if (mode) syncCmd.push(`--mode=${mode}`);
      parts.push("=== Sync ===\n" + wv(syncCmd, WV_LIFECYCLE_TIMEOUT));
      if (gh && !MCP_ALLOW_NETWORK) {
        parts.push("\n=== GitHub Sync ===\n" + mcpNetworkFallback(`wv sync --gh${mode ? ` --mode=${mode}` : ""}`));
      }
    } catch (e) {
      parts.push("=== Sync ===\nError: " + (e as Error).message);
    }

    // 2. Check uncommitted files
    try {
      const uncommitted = execFileSync("git", ["status", "--porcelain"], {
        encoding: "utf-8",
        env: { ...process.env },
      }).trim();
      if (uncommitted) {
        parts.push("\n=== Uncommitted Files ===\n" + uncommitted);
      } else {
        parts.push("\n=== Uncommitted Files ===\nNone — working tree clean");
      }
    } catch {
      parts.push("\n=== Uncommitted Files ===\nCould not check");
    }

    // 3. Check unpushed commits
    try {
      const unpushed = execFileSync("git", ["log", "@{u}..HEAD", "--oneline"], {
        encoding: "utf-8",
        env: { ...process.env },
      }).trim();
      if (unpushed) {
        parts.push("\n=== Unpushed Commits ===\n" + unpushed);
      } else {
        parts.push("\n=== Unpushed Commits ===\nNone — up to date with remote");
      }
    } catch {
      parts.push("\n=== Unpushed Commits ===\nCould not check");
    }

    // 4. Active nodes warning
    try {
      const status = wvRead(["status"]);
      if (status.includes("active") && !status.includes("0 active")) {
        parts.push("\n=== Warning ===\n" + "Active nodes still open — consider closing with weave_done or weave_ship");
      }
    } catch {
      /* skip */
    }

    result = parts.join("\n");
    return result;
  },

  weave_tree: (args) => {
    let result: string;
    const active = args.active as boolean | undefined;
    const depth = args.depth as number | undefined;
    const mermaid = args.mermaid as boolean | undefined;
    const json = args.json as boolean | undefined;
    const root = args.root as string | undefined;
    const all = args.all as boolean | undefined;
    const cmd = ["tree"];
    if (mermaid) cmd.push("--mermaid");
    else if (json) cmd.push("--json");
    if (active) cmd.push("--active");
    if (depth !== undefined) cmd.push(`--depth=${depth}`);
    if (root) cmd.push(`--root=${root}`);
    if (all) cmd.push("--all");
    result = wv(cmd);
    return result;
  },

  weave_learnings: (args) => {
    let result: string;
    const grep = args.grep as string | undefined;
    const recent = args.recent as number | undefined;
    const category = args.category as string | undefined;
    const node = args.node as string | undefined;
    const mode = args.mode as ReadMode | undefined;
    const minQuality = args.min_quality as number | undefined;
    const dedup = args.dedup as boolean | undefined;
    const all = args.all as boolean | undefined;
    const cmd = ["learnings", "--json"];
    if (grep) cmd.push(`--grep=${grep}`);
    if (recent !== undefined) cmd.push(`--recent=${recent}`);
    if (category) cmd.push(`--category=${category}`);
    if (node) cmd.push(`--node=${node}`);
    if (mode) cmd.push(`--mode=${mode}`);
    if (minQuality !== undefined) cmd.push(`--min-quality=${minQuality}`);
    if (dedup) cmd.push("--dedup");
    if (all) cmd.push("--all");
    result = wv(cmd);
    return result;
  },

  weave_update: (args) => {
    let result: string;
    const id = args.id as string;
    const status = normalizeStatus(args.status as string | undefined);
    const text = args.text as string | undefined;
    const metadata = args.metadata as Record<string, unknown> | undefined;
    const alias = args.alias as string | undefined;
    const removeKey = args.remove_key as string | undefined;

    // --remove-key is a standalone operation (returns immediately)
    if (removeKey) {
      return wv(["update", id, `--remove-key=${removeKey}`]);
    }

    const cmd = ["update", id];
    if (status) cmd.push(`--status=${status}`);
    if (text) cmd.push(`--text=${text}`);
    if (metadata) cmd.push(`--metadata=${JSON.stringify(metadata)}`);
    if (alias) cmd.push(`--alias=${alias}`);
    result = wv(cmd);
    return result;
  },

  weave_touch: (args) => {
    let result: string;
    const id = args.id as string;
    const metadata = args.metadata as Record<string, unknown> | undefined;
    const intent = args.intent as string | undefined;
    const cmd = ["touch", id];
    if (metadata) cmd.push(`--metadata=${JSON.stringify(metadata)}`);
    if (intent) cmd.push(`--intent=${intent}`);
    wv(cmd);
    result = "ok";
    return result;
  },

  weave_record_edit: (args) => {
    let result: string;
    const id = args.id as string;
    const path = args.path as string | undefined;
    const intent = args.intent as string | undefined;
    const metadata = args.metadata as Record<string, unknown> | undefined;
    if (!path && !intent && !metadata) {
      throw new Error("weave_record_edit requires at least one of: path, intent, metadata");
    }
    const cmd = ["touch", id];
    if (path) cmd.push(`--files=${path}`);
    if (intent) cmd.push(`--intent=${intent}`);
    if (metadata) cmd.push(`--metadata=${JSON.stringify(metadata)}`);
    wv(cmd);
    result = "ok";
    return result;
  },

  weave_breadcrumbs: (args) => {
    let result: string;
    // weave_breadcrumbs is a back-compat alias; both route to the `trails` CLI.
    const action = (args.action as string) || "show";
    const message = args.message as string | undefined;
    const cmd = ["trails", action];
    if (action === "save" && message) cmd.push(`--message=${message}`);
    result = wv(cmd);
    return result;
  },

  weave_guide: (args) => {
    let result: string;
    const topic = args.topic as string | undefined;
    const procedure = args.procedure as string | undefined;
    if (topic && procedure) {
      throw new Error("weave_guide accepts either topic or procedure, not both");
    }
    const cmd = ["guide"];
    if (procedure) cmd.push(`--procedure=${procedure}`);
    else if (topic) cmd.push(`--topic=${topic}`);
    result = wv(cmd);
    return result;
  },

  weave_plan: (args) => {
    let result: string;
    const template = args.template as boolean | undefined;
    if (template) {
      return wv(["plan", "--template"]);
    }
    const file = args.file as string | undefined;
    const sprint = args.sprint as number | undefined;
    if (!file || sprint === undefined) {
      throw new Error("weave_plan requires 'file' and 'sprint' (or template=true)");
    }
    const gh = args.gh as boolean | undefined;
    const dryRun = args.dry_run as boolean | undefined;
    const cmd = ["plan", file, `--sprint=${sprint}`];
    if (gh) cmd.push("--gh");
    if (dryRun) cmd.push("--dry-run");
    // --gh: sleep 1 between each issue create (secondary rate limit); 20 tasks ≈ 60s minimum
    const planTimeout = gh ? 180_000 : 60_000;
    result = wv(cmd, planTimeout);
    return result;
  },

  weave_show: (args) => {
    let result: string;
    const id = args.id as string;
    result = wv(["show", id, "--json-v2"]);
    return result;
  },

  weave_delete: (args) => {
    let result: string;
    const id = args.id as string;
    const force = args.force as boolean;
    const dryRun = args.dry_run as boolean | undefined;
    const noGh = args.no_gh as boolean | undefined;
    if (!force) {
      throw new Error("weave_delete requires force=true to confirm deletion. This is a destructive operation.");
    }
    const cmd = ["delete", id, "--force"];
    if (dryRun) cmd.push("--dry-run");
    if (noGh) cmd.push("--no-gh");
    result = wv(cmd);
    return result;
  },

  weave_quality_scan: (args) => {
    let result: string;
    const path = args.path as string | undefined;
    const exclude = args.exclude as string | undefined;
    const cmd = ["quality", "scan", "--json"];
    if (path) cmd.push(path);
    if (exclude) cmd.push(`--exclude=${exclude}`);
    result = wv(cmd, 60_000); // scans can be slow on large repos
    return result;
  },

  weave_quality_hotspots: (args) => {
    let result: string;
    const path = args.path as string | undefined;
    const limit = args.limit as number | undefined;
    const threshold = args.threshold as number | undefined;
    const cmd = ["quality", "hotspots", "--json"];
    if (path) cmd.push(path);
    if (limit) cmd.push(`--limit=${limit}`);
    if (threshold) cmd.push(`--threshold=${threshold}`);
    result = wv(cmd);
    return result;
  },

  weave_quality_diff: (args) => {
    let result: string;
    const path = args.path as string | undefined;
    const cmd = ["quality", "diff", "--json"];
    if (path) cmd.push(path);
    result = wv(cmd);
    return result;
  },

  weave_quality_functions: (args) => {
    let result: string;
    const path = args.path as string | undefined;
    const threshold = args.threshold as number | undefined;
    const cmd = ["quality", "functions", "--json"];
    if (path) cmd.push(path);
    if (threshold !== undefined) cmd.push(`--threshold=${threshold}`);
    result = wv(cmd);
    return result;
  },

  weave_structural_search: (args) => {
    let result: string;
    const pattern = args.pattern as string;
    const lang = args.lang as string;
    const repo = args.repo as string | undefined;
    const cmd = ["quality", "structural-search", "--json", `--pattern=${pattern}`, `--lang=${lang}`];
    if (repo) cmd.push(`--repo=${repo}`);
    result = wv(cmd, 30_000);
    return result;
  },

  weave_quality_patterns: (args) => {
    const subcommand = args.subcommand as string;
    const patPath = args.path as string | undefined;
    const patParent = args.parent as string | undefined;
    const patDryRun = args.dry_run as boolean | undefined;
    const findingKey = args.finding_key as string | undefined;
    const disposition = args.disposition as string | undefined;
    const note = args.note as string | undefined;
    const cmd = ["quality", "patterns", subcommand, "--json"];
    // scan/list/validate/report all accept the same optional scope path --
    // forwarded uncategorically here for parity, exactly as the CLI itself
    // consumes it for each (wv-6cd72e): no path-handling logic is
    // reimplemented, only the argument is passed through.
    if (subcommand === "scan" || subcommand === "list" || subcommand === "validate" || subcommand === "report") {
      if (patPath) cmd.push(patPath);
    } else if (subcommand === "adjudicate") {
      if (!findingKey || !disposition) {
        throw new Error("weave_quality_patterns adjudicate requires finding_key and disposition");
      }
      cmd.push(findingKey, disposition);
      if (note) cmd.push(`--note=${note}`);
    } else if (subcommand === "promote") {
      if (!patParent) {
        throw new Error("weave_quality_patterns promote requires parent");
      }
      cmd.push(`--parent=${patParent}`);
      if (patDryRun) cmd.push("--dry-run");
    }
    if (subcommand === "list") {
      return wvQualityPatternsList(cmd, patPath);
    }
    if (subcommand === "validate") {
      return wvQualityPatternsValidate(cmd);
    }
    if (subcommand === "report") {
      return wvQualityPatternsReport(cmd);
    }
    return wv(cmd, 60_000);
  },

  weave_code_search: (args) => {
    let result: string;
    const query = args.query as string;
    const limit = args.limit as number | undefined;
    const mode = args.mode as string | undefined;
    const graph = args.graph as boolean | undefined;
    const filter = args.filter as string | undefined;
    const cmd = ["search", "--code", query, "--json"];
    if (limit) cmd.push(`--limit=${limit}`);
    if (mode) cmd.push(`--mode=${mode}`);
    if (graph) cmd.push("--graph");
    if (filter) cmd.push(`--filter=${filter}`);
    result = wv(cmd, 120_000);
    return result;
  },

  weave_index: (args) => {
    let result: string;
    const path = args.path as string | undefined;
    const noEmbed = args.no_embed as boolean | undefined;
    const ext = args.ext as string | undefined;
    const cmd = ["index", "--json"];
    if (path) cmd.push(path);
    if (noEmbed) cmd.push("--no-embed");
    if (ext) cmd.push(`--ext=${ext}`);
    result = wv(cmd, 300_000);
    return result;
  },
};

// weave_trails shared a fallthrough case with weave_breadcrumbs in the old
// switch — same handler, two tool names.
TOOL_HANDLERS.weave_trails = TOOL_HANDLERS.weave_breadcrumbs;

function handleTool(name: string, args: Record<string, unknown>): ToolResponse {
  const handler = TOOL_HANDLERS[name];
  if (!handler) {
    throw new Error(`Unknown tool: ${name}`);
  }
  const result = handler(args);
  if (typeof result === "string") {
    return { content: [{ type: "text", text: result }] };
  }
  return result;
}

// Create and run server
async function main() {
  if (HEALTH_CHECK) {
    const status = STARTUP_ERROR ? "fail" : "pass";
    console.log(JSON.stringify(startupReport(status)));
    process.exit(STARTUP_ERROR ? STARTUP_EXIT_CODES[STARTUP_ERROR.code] : 0);
  }

  const scopeLabel = ACTIVE_SCOPE === "all" ? "" : `-${ACTIVE_SCOPE}`;
  const server = new Server(
    {
      name: `weave-mcp-server${scopeLabel}`,
      version: PKG_VERSION,
    },
    {
      capabilities: {
        tools: {},
      },
    }
  );

  // List available tools (filtered by scope)
  server.setRequestHandler(ListToolsRequestSchema, async () => {
    const startedAt = Date.now();
    const payload = { tools: SCOPED_TOOLS };
    recordPayloadInstrumentation("tools/list", payload, [`tools=${SCOPED_TOOLS.length}`], Date.now() - startedAt);
    return payload;
  });

  // Handle tool calls (enforce scope)
  server.setRequestHandler(CallToolRequestSchema, async (request) => {
    const { name, arguments: args } = request.params;

    // Reject tools not in active scope
    if (!SCOPED_TOOLS.some((t) => t.name === name)) {
      return {
        content: [
          {
            type: "text",
            text: `Error: Tool "${name}" is not available in scope "${ACTIVE_SCOPE}"`,
          },
        ],
        isError: true,
      };
    }

    // Instrumentation: count per-tool calls
    if (INSTRUMENT) {
      const count = (toolCallCounts.get(name) || 0) + 1;
      toolCallCounts.set(name, count);
      logInstrumentation(`call scope=${ACTIVE_SCOPE} tool=${name} count=${count}`);
    }

    const startedAt = Date.now();
    try {
      const response = handleTool(name, (args as Record<string, unknown>) || {});
      recordPayloadInstrumentation(
        name,
        response,
        [`is_error=${response.isError ? "true" : "false"}`],
        Date.now() - startedAt
      );
      return response;
    } catch (error: unknown) {
      const err = error as Error;
      const response = {
        content: [{ type: "text", text: `Error: ${err.message}` }],
        isError: true,
      };
      recordPayloadInstrumentation(name, response, ["is_error=true"], Date.now() - startedAt);
      return response;
    }
  });

  // Start stdio transport
  const transport = new StdioServerTransport();
  await server.connect(transport);

  if (MCP_STARTUP_REPORT) {
    console.error(JSON.stringify({ event: "weave_mcp_startup", ...startupReport("pass") }));
  }
  console.error(`Weave MCP server started (scope=${ACTIVE_SCOPE}, ${SCOPED_TOOLS.length} tools)`);
}

// Guard so tests can `import` this module (e.g. to exercise findWvCandidates)
// without starting the stdio server or re-running module-level startup checks
// as a side effect. Every real invocation runs this file directly (`node
// dist/index.js`, the package.json `bin` entry), so require.main === module
// there; only an in-process require/import skips the auto-start.
if (require.main === module) {
  main().catch((error) => {
    console.error(`[startup_failure] Fatal error: ${(error as Error).message ?? error}`);
    process.exit(STARTUP_EXIT_CODES.startup_failure);
  });
}
