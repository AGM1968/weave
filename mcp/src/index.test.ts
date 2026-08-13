/**
 * Integration tests for Weave MCP Server
 *
 * Tests the MCP server by spawning it and sending JSON-RPC requests over stdio.
 */

import { spawn, spawnSync, ChildProcess } from "child_process";
import { chmodSync, cpSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "fs";
import { tmpdir } from "os";
import { join, resolve } from "path";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { findWvCandidates, resolveAgentHarness, resolveAgentId, resolvePatternsListBudgetMs } from "./index";

const SERVER_PATH = resolve(__dirname, "../dist/index.js");
const REQUEST_TIMEOUT_MS = 30_000;
const CONTRACT = JSON.parse(readFileSync(resolve(__dirname, "../contract.json"), "utf-8")) as {
  scopes: Record<string, { tool_count: number; configured_by_default?: boolean; start_when?: string }>;
  servers: Array<{ name: string; scope: string; lifecycle: string; start_policy?: string }>;
  environment: { required: string[] };
};

// Graph-isolation env injected into every spawned wv / MCP-server process so the
// suite never mutates the developer's live Weave graph. The "Weave MCP Server"
// block points this at a throwaway WV_DB/WV_HOT_ZONE in beforeAll and resets it
// in afterAll; an explicit per-test WV_DB (e.g. the code-search fixture) still
// wins because it is spread after this. Without it, createTrackedNode /
// createActiveNodeDirect wrote fixtures into the real graph and any interrupted
// teardown left active nodes behind.
let GRAPH_ENV: NodeJS.ProcessEnv = {};

interface JsonRpcRequest {
  jsonrpc: "2.0";
  id: number;
  method: string;
  params?: Record<string, unknown>;
}

interface JsonRpcResponse {
  jsonrpc: "2.0";
  id: number;
  result?: unknown;
  error?: { code: number; message: string };
}

class MCPTestClient {
  private server: ChildProcess;
  private requestId = 0;
  private buffer = "";
  private stderrBuffer = "";
  private pending: Map<
    number,
    { resolve: (v: JsonRpcResponse) => void; reject: (e: Error) => void; timeout: NodeJS.Timeout }
  > = new Map();

  constructor(extraArgs: string[] = [], extraEnv: NodeJS.ProcessEnv = {}, cwd?: string) {
    this.server = spawn("node", [SERVER_PATH, ...extraArgs], {
      stdio: ["pipe", "pipe", "pipe"],
      cwd,
      env: {
        ...process.env,
        WV_PATH: resolve(__dirname, "../../scripts/wv"),
        ...GRAPH_ENV,
        ...extraEnv,
      },
    });

    this.server.stdout!.on("data", (data: Buffer) => {
      this.buffer += data.toString();
      this.processBuffer();
    });

    this.server.stderr!.on("data", (data: Buffer) => {
      this.stderrBuffer += data.toString();
    });
  }

  private processBuffer() {
    const lines = this.buffer.split("\n");
    this.buffer = lines.pop() || "";

    for (const line of lines) {
      if (!line.trim()) continue;
      try {
        const response = JSON.parse(line) as JsonRpcResponse;
        const pending = this.pending.get(response.id);
        if (pending) {
          clearTimeout(pending.timeout);
          this.pending.delete(response.id);
          pending.resolve(response);
        }
      } catch {
        // Not JSON, ignore
      }
    }
  }

  async request(method: string, params?: Record<string, unknown>): Promise<JsonRpcResponse> {
    const id = ++this.requestId;
    const request: JsonRpcRequest = {
      jsonrpc: "2.0",
      id,
      method,
      ...(params && { params }),
    };

    return new Promise((resolve, reject) => {
      const timeout = setTimeout(() => {
        if (this.pending.has(id)) {
          this.pending.delete(id);
          reject(new Error(`Request ${method} timed out`));
        }
      }, REQUEST_TIMEOUT_MS);

      this.pending.set(id, { resolve, reject, timeout });
      this.server.stdin!.write(JSON.stringify(request) + "\n");
    });
  }

  async close() {
    // Clear all pending timeouts
    for (const pending of this.pending.values()) {
      clearTimeout(pending.timeout);
    }
    this.pending.clear();

    this.server.stdin?.end();
    await new Promise<void>((resolve) => {
      let settled = false;
      const finish = () => {
        if (settled) return;
        settled = true;
        resolve();
      };
      this.server.on("close", finish);
      setTimeout(() => {
        if (settled) return;
        this.server.kill("SIGKILL");
        setTimeout(finish, 1000); // Force resolve after kill if needed
      }, 1000);
    });
  }

  getStderr(): string {
    return this.stderrBuffer;
  }
}

function extractNodeId(text: string): string {
  const idMatch = text.match(/wv-[a-f0-9]+/);
  if (!idMatch) {
    throw new Error(`Expected Weave node id in: ${text}`);
  }
  return idMatch[0];
}

interface LoggedWvWrapper {
  logPath: string;
  wvPath: string;
  cleanup: () => void;
}

function createLoggedWvWrapper(): LoggedWvWrapper {
  const dir = mkdtempSync(join(tmpdir(), "weave-mcp-wv-"));
  const logPath = join(dir, "wv-args.log");
  const wvPath = join(dir, "wv-wrapper.sh");
  const realWvPath = resolve(__dirname, "../../scripts/wv");
  const script = `#!/bin/sh
LOG_PATH=${JSON.stringify(logPath)}
REAL_WV=${JSON.stringify(realWvPath)}
printf '%s\n' "$*" >> "$LOG_PATH"
exec "$REAL_WV" "$@"
`;
  writeFileSync(wvPath, script, "utf-8");
  chmodSync(wvPath, 0o755);
  return {
    logPath,
    wvPath,
    cleanup: () => rmSync(dir, { recursive: true, force: true }),
  };
}

// wv-c4e639: a fake `wv` that returns a SPECIFIC (malformed/wrong-shape/
// wrong-exit-code) response for "quality patterns validate" only, passing
// every other invocation straight through to the real binary (needed for
// the MCP server's own startup/handshake and any other tool calls made
// against the same client). WV_PATH (checked first by findWvCandidates)
// is how the server is pointed at it.
// wv-8b3f8a: a minimal but structurally valid `coverage` object -- every
// value present is boolean, matching isValidPatternCoverage's own
// requirement, without needing to enumerate the full documented
// kind/scope/maturity/key sets a real cmd_patterns_validate run would.
// Fixtures below that aren't specifically testing coverage itself use
// this so they keep isolating whatever check they were originally
// written for, instead of failing on the (correctly stricter) envelope
// check first.
const VALID_COVERAGE = {
  kinds: { lexicon: false },
  match_scopes: { line: false },
  maturities: { candidate: false },
  optional_keys: { exempt: false },
};

function createFakeWvForValidate(stdout: string, exitCode: number): { wvPath: string; cleanup: () => void } {
  const dir = mkdtempSync(join(tmpdir(), "weave-mcp-fakewv-"));
  const wvPath = join(dir, "wv-fake.sh");
  const realWvPath = resolve(__dirname, "../../scripts/wv");
  const script = `#!/bin/sh
case "$*" in
  *"quality patterns validate"*)
    printf '%s' ${JSON.stringify(stdout)}
    exit ${exitCode}
    ;;
esac
exec ${JSON.stringify(realWvPath)} "$@"
`;
  writeFileSync(wvPath, script, "utf-8");
  chmodSync(wvPath, 0o755);
  return { wvPath, cleanup: () => rmSync(dir, { recursive: true, force: true }) };
}

function createFakeWvForReport(stdout: string, exitCode: number): { wvPath: string; cleanup: () => void } {
  const dir = mkdtempSync(join(tmpdir(), "weave-mcp-fakewv-report-"));
  const wvPath = join(dir, "wv-fake.sh");
  const realWvPath = resolve(__dirname, "../../scripts/wv");
  const script = `#!/bin/sh
case "$*" in
  *"quality patterns report"*)
    printf '%s' ${JSON.stringify(stdout)}
    exit ${exitCode}
    ;;
esac
exec ${JSON.stringify(realWvPath)} "$@"
`;
  writeFileSync(wvPath, script, "utf-8");
  chmodSync(wvPath, 0o755);
  return { wvPath, cleanup: () => rmSync(dir, { recursive: true, force: true }) };
}

function readLoggedCommands(logPath: string): string[] {
  try {
    return readFileSync(logPath, "utf-8")
      .split("\n")
      .map((line) => line.trim())
      .filter(Boolean);
  } catch {
    return [];
  }
}

function deleteNodeDirect(id: string): void {
  spawnSync(resolve(__dirname, "../../scripts/wv"), ["delete", id, "--force"], {
    stdio: "ignore",
    env: {
      ...process.env,
      ...GRAPH_ENV,
      NO_COLOR: "1",
      WV_AGENT: "1",
    },
  });
}

function createCodeSearchFixtureDb(): { dbPath: string; hotZone: string; cleanup: () => void } {
  const dir = mkdtempSync(join(tmpdir(), "weave-mcp-search-"));
  const dbPath = join(dir, "brain.db");
  spawnSync(
    "sqlite3",
    [dbPath, "CREATE TABLE chunks (id INTEGER PRIMARY KEY); CREATE TABLE node_files (node_id TEXT, path TEXT);"],
    {
      stdio: "ignore",
    }
  );
  return {
    dbPath,
    hotZone: dir,
    cleanup: () => rmSync(dir, { recursive: true, force: true }),
  };
}

// wv-6cd72e: a throwaway repo root (own hot zone, own .weave/patterns/) for
// weave_quality_patterns contract/parity tests -- passed as MCPTestClient's
// `cwd` so resolveProjectRoot() falls through to process.cwd() inside the
// spawned server, and _resolve_repo (Python) in turn falls through the same
// way (no REPO_ROOT env, no enclosing git repo under system tmp) to ITS OWN
// process.cwd() -- both land on `dir` without any env-var wiring needed.
function createQualityPatternsFixture(): {
  dir: string;
  hotZone: string;
  env: NodeJS.ProcessEnv;
  cleanup: () => void;
} {
  const dir = mkdtempSync(join(tmpdir(), "weave-mcp-qpatterns-"));
  const hotZone = mkdtempSync(join(tmpdir(), "weave-mcp-qpatterns-hz-"));
  mkdirSync(join(dir, ".weave", "patterns"), { recursive: true });
  return {
    dir,
    hotZone,
    env: { WV_HOT_ZONE: hotZone },
    cleanup: () => {
      rmSync(dir, { recursive: true, force: true });
      rmSync(hotZone, { recursive: true, force: true });
    },
  };
}

function createActiveNodeDirectWithEnv(text: string, extraEnv: NodeJS.ProcessEnv): string {
  const result = spawnSync(
    resolve(__dirname, "../../scripts/wv"),
    ["add", text, "--status=active", "--standalone", "--criteria=guard ok", "--risks=low"],
    {
      encoding: "utf-8",
      env: {
        ...process.env,
        ...extraEnv,
        NO_COLOR: "1",
        WV_AGENT: "1",
      },
    }
  );

  if (result.status !== 0) {
    throw new Error(result.stderr?.trim() || result.stdout?.trim() || "failed to create active node");
  }

  return extractNodeId(`${result.stdout || ""}\n${result.stderr || ""}`);
}

function createActiveNodeDirect(text: string): string {
  const result = spawnSync(
    resolve(__dirname, "../../scripts/wv"),
    ["add", text, "--status=active", "--standalone", "--criteria=guard ok", "--risks=low"],
    {
      encoding: "utf-8",
      env: {
        ...process.env,
        ...GRAPH_ENV,
        NO_COLOR: "1",
        WV_AGENT: "1",
      },
    }
  );

  if (result.status !== 0) {
    throw new Error(result.stderr?.trim() || result.stdout?.trim() || "failed to create active node");
  }

  return extractNodeId(`${result.stdout || ""}\n${result.stderr || ""}`);
}

describe("resolveAgentHarness / resolveAgentId cross-harness parity (wv-4d4c96 / wv-5fbc6c)", () => {
  const MARKER_VARS = ["WV_AGENT_ID", "CLAUDE_CODE_SSE_PORT", "CODEX_THREAD_ID", "CODEX_CI", "COPILOT_AGENT"] as const;
  let saved: Record<string, string | undefined>;

  beforeAll(() => {
    saved = Object.fromEntries(MARKER_VARS.map((k) => [k, process.env[k]]));
  });

  afterAll(() => {
    for (const k of MARKER_VARS) {
      if (saved[k] === undefined) delete process.env[k];
      else process.env[k] = saved[k];
    }
  });

  function setMarkers(vars: Partial<Record<(typeof MARKER_VARS)[number], string>>): void {
    for (const k of MARKER_VARS) {
      if (vars[k] === undefined) delete process.env[k];
      else process.env[k] = vars[k];
    }
  }

  it("resolves each harness alone", () => {
    setMarkers({ CLAUDE_CODE_SSE_PORT: "1" });
    expect(resolveAgentHarness()).toBe("claude");
    setMarkers({ CODEX_CI: "1" });
    expect(resolveAgentHarness()).toBe("codex");
    setMarkers({ COPILOT_AGENT: "1" });
    expect(resolveAgentHarness()).toBe("copilot");
    setMarkers({});
    expect(resolveAgentHarness()).toBe("human");
  });

  it("claude wins the claude/codex tie, matching the bash and python fixes (wv-4d4c96)", () => {
    setMarkers({ CLAUDE_CODE_SSE_PORT: "1", CODEX_CI: "1" });
    expect(resolveAgentHarness()).toBe("claude");
    expect(resolveAgentId()).toMatch(/^claude-/);
  });

  it("copilot still wins a three-way tie", () => {
    setMarkers({ CLAUDE_CODE_SSE_PORT: "1", CODEX_CI: "1", COPILOT_AGENT: "1" });
    expect(resolveAgentHarness()).toBe("copilot");
    expect(resolveAgentId()).toMatch(/^copilot-/);
  });

  it("explicit WV_AGENT_ID always wins over any marker", () => {
    setMarkers({ WV_AGENT_ID: "explicit-id", CLAUDE_CODE_SSE_PORT: "1", CODEX_CI: "1" });
    expect(resolveAgentId()).toBe("explicit-id");
  });

  it("produces the <harness>-<host>-<user> format scripts/weave_gh/phases.py recognizes as local", () => {
    setMarkers({ CLAUDE_CODE_SSE_PORT: "1" });
    expect(resolveAgentId()).toMatch(/^claude-.+-.+$/);
  });
});

describe("resolvePatternsListBudgetMs (wv-112599, external code review round 3 finding 4)", () => {
  // `Number(raw) || 60_000` used to let -1/Infinity/1.5 all pass straight
  // through as spawnSync's literal timeout -- Node throws on each of those
  // before `wv` even runs -- while 0 and unparseable text silently fell
  // back to 60000. Only a positive safe integer should ever reach
  // spawnSync; everything else falls back to the same 60000 default.
  it("accepts a positive safe integer as-is", () => {
    expect(resolvePatternsListBudgetMs("400")).toBe(400);
    expect(resolvePatternsListBudgetMs("60000")).toBe(60_000);
    expect(resolvePatternsListBudgetMs("1")).toBe(1);
  });

  it("falls back to 60000 for values that would make spawnSync throw", () => {
    expect(resolvePatternsListBudgetMs("-1")).toBe(60_000);
    expect(resolvePatternsListBudgetMs("Infinity")).toBe(60_000);
    expect(resolvePatternsListBudgetMs("-Infinity")).toBe(60_000);
    expect(resolvePatternsListBudgetMs("1.5")).toBe(60_000);
  });

  it("falls back to 60000 for zero, unset, and unparseable input, matching the valid-value fallback", () => {
    expect(resolvePatternsListBudgetMs("0")).toBe(60_000);
    expect(resolvePatternsListBudgetMs(undefined)).toBe(60_000);
    expect(resolvePatternsListBudgetMs("not-a-number")).toBe(60_000);
    expect(resolvePatternsListBudgetMs("")).toBe(60_000);
  });
});

describe("Weave MCP startup health", () => {
  it("keeps lifecycle metadata explicit for shipped scopes", () => {
    expect(CONTRACT.servers.map((server) => server.name)).toEqual([
      "weave",
      "weave-session",
      "weave-lite",
      "weave-inspect",
    ]);
    for (const server of CONTRACT.servers) {
      expect(server.lifecycle).toBe("client-managed-stdio");
      expect(server.start_policy).toBeTruthy();
      expect(CONTRACT.scopes[server.scope].configured_by_default).toBe(true);
      expect(CONTRACT.scopes[server.scope].start_when).toBeTruthy();
    }
    expect(CONTRACT.scopes.graph.configured_by_default).toBe(false);
    expect(CONTRACT.scopes.graph.start_when).toBeTruthy();
    expect(CONTRACT.environment.required).toEqual(expect.arrayContaining(["WV_PROJECT_ROOT", "WV_AGENT_ID"]));
  });

  it("emits structured startup health and exits without starting stdio", () => {
    const result = spawnSync("node", [SERVER_PATH, "--scope=lite", "--health-check"], {
      encoding: "utf-8",
      env: {
        ...process.env,
        WV_PATH: resolve(__dirname, "../../scripts/wv"),
        WV_PROJECT_ROOT: resolve(__dirname, "../.."),
        WV_AGENT_ID: "mcp-test-agent",
      },
    });

    if (result.error?.message.includes("EPERM")) {
      console.warn("Skipping startup health subprocess assertion: nested node spawn is blocked by this sandbox");
      return;
    }
    expect(result.error).toBeUndefined();
    expect(result.status).toBe(0);
    const payload = JSON.parse(result.stdout.trim()) as Record<string, unknown>;
    expect(payload.schema).toBe("weave-mcp-startup.v1");
    expect(payload.status).toBe("pass");
    expect(payload.server).toBe("weave-lite");
    expect(payload.scope).toBe("lite");
    expect(payload.tools).toBe(CONTRACT.scopes.lite.tool_count);
    expect(payload.agent_id).toBe("mcp-test-agent");
    expect(payload.project_root).toBe(resolve(__dirname, "../.."));
    expect(payload.wv_path).toBe(resolve(__dirname, "../../scripts/wv"));
    expect(payload.code).toBeNull();
    expect(payload.detail).toBeNull();
  });

  it("reports invalid_scope with a stable exit code and health-check code/detail", () => {
    const env = { ...process.env, WV_PATH: resolve(__dirname, "../../scripts/wv") };

    const plain = spawnSync("node", [SERVER_PATH, "--scope=bogus"], { encoding: "utf-8", env });
    if (plain.error?.message.includes("EPERM")) {
      console.warn("Skipping invalid-scope subprocess assertion: nested node spawn is blocked by this sandbox");
      return;
    }
    expect(plain.status).toBe(2);
    expect(plain.stderr).toContain('Invalid scope "bogus"');

    const health = spawnSync("node", [SERVER_PATH, "--scope=bogus", "--health-check"], { encoding: "utf-8", env });
    expect(health.status).toBe(2);
    const payload = JSON.parse(health.stdout.trim()) as Record<string, unknown>;
    expect(payload.status).toBe("fail");
    expect(payload.code).toBe("invalid_scope");
    expect(payload.detail).toContain('Invalid scope "bogus"');
  });

  it("reports bad_project_root with a stable exit code and health-check code/detail", () => {
    const env = {
      ...process.env,
      WV_PATH: resolve(__dirname, "../../scripts/wv"),
      WV_PROJECT_ROOT: "/nonexistent-project-root-xyz",
    };

    const plain = spawnSync("node", [SERVER_PATH, "--scope=lite"], { encoding: "utf-8", env });
    if (plain.error?.message.includes("EPERM")) {
      console.warn("Skipping bad-project-root subprocess assertion: nested node spawn is blocked by this sandbox");
      return;
    }
    expect(plain.status).toBe(4);
    expect(plain.stderr).toContain("/nonexistent-project-root-xyz");

    const health = spawnSync("node", [SERVER_PATH, "--scope=lite", "--health-check"], { encoding: "utf-8", env });
    expect(health.status).toBe(4);
    const payload = JSON.parse(health.stdout.trim()) as Record<string, unknown>;
    expect(payload.status).toBe("fail");
    expect(payload.code).toBe("bad_project_root");
    expect(payload.detail).toContain("/nonexistent-project-root-xyz");
  });

  it("reports wv_not_found from an isolated distribution", () => {
    // Copying the built entry point changes its module-relative development
    // fallback without touching the real repository or executable.
    const isolatedRoot = mkdtempSync(join(tmpdir(), "weave-mcp-no-wv-"));
    const isolatedDist = join(isolatedRoot, "mcp", "dist");
    const fakeHome = join(isolatedRoot, "home");
    mkdirSync(isolatedDist, { recursive: true });
    mkdirSync(fakeHome);
    cpSync(SERVER_PATH, join(isolatedDist, "index.js"));

    const priorWvPath = process.env.WV_PATH;
    try {
      const candidates = findWvCandidates("/nonexistent-home-xyz", "/nonexistent-module-dir-xyz");
      expect(candidates.length).toBeGreaterThan(0);
      for (const candidate of candidates) {
        expect(existsSync(candidate)).toBe(false);
      }
      const result = spawnSync("node", [join(isolatedDist, "index.js"), "--scope=lite", "--health-check"], {
        encoding: "utf-8",
        env: {
          ...process.env,
          HOME: fakeHome,
          NODE_PATH: resolve(__dirname, "../node_modules"),
          WV_PATH: "",
        },
      });
      if (result.error?.message.includes("EPERM")) {
        console.warn("Skipping missing-wv subprocess assertion: nested node spawn is blocked by this sandbox");
        return;
      }
      expect(result.status).toBe(3);
      const payload = JSON.parse(result.stdout.trim()) as Record<string, unknown>;
      expect(payload.status).toBe("fail");
      expect(payload.code).toBe("wv_not_found");
      expect(payload.detail).toContain("wv CLI not found");
    } finally {
      if (priorWvPath !== undefined) process.env.WV_PATH = priorWvPath;
      rmSync(isolatedRoot, { recursive: true, force: true });
    }
  });
});

describe("Weave MCP Server", () => {
  let client: MCPTestClient;
  let isolatedDir: string;
  const createdNodeIds: string[] = [];

  async function createTrackedNode(text: string, metadata?: Record<string, unknown>): Promise<string> {
    const addResponse = await client.request("tools/call", {
      name: "weave_add",
      arguments: { text, standalone: true },
    });
    expect(addResponse.error).toBeUndefined();
    const addResult = addResponse.result as { isError?: boolean; content: { text: string }[] };
    expect(addResult.isError).not.toBe(true);
    const id = extractNodeId(addResult.content[0].text);
    createdNodeIds.push(id);
    if (metadata) {
      await client.request("tools/call", {
        name: "weave_update",
        arguments: { id, metadata },
      });
    }
    return id;
  }

  beforeAll(() => {
    // Point the whole block at a throwaway graph so no test writes to the live
    // Weave DB. Materialize the schema first so wv commands operate on a real DB.
    isolatedDir = mkdtempSync(join(tmpdir(), "weave-mcp-graph-"));
    GRAPH_ENV = { WV_DB: join(isolatedDir, "brain.db"), WV_HOT_ZONE: isolatedDir };
    spawnSync(resolve(__dirname, "../../scripts/wv"), ["init"], {
      stdio: "ignore",
      env: { ...process.env, ...GRAPH_ENV, NO_COLOR: "1", WV_AGENT: "1" },
    });
    client = new MCPTestClient();
  });

  afterAll(async () => {
    await client.close();
    // Best-effort node deletes are kept for symmetry, but teardown no longer
    // depends on them: dropping the isolated dir removes the whole throwaway DB,
    // so an interrupted cleanup can never leave nodes in the live graph.
    for (const id of [...createdNodeIds].reverse()) {
      deleteNodeDirect(id);
    }
    GRAPH_ENV = {};
    rmSync(isolatedDir, { recursive: true, force: true });
  }, 60_000);

  describe("tools/list", () => {
    it("should list all tools from the default scope contract", async () => {
      const response = await client.request("tools/list");
      expect(response.error).toBeUndefined();

      const tools = (response.result as { tools: { name: string }[] }).tools;
      expect(tools).toHaveLength(CONTRACT.scopes.all.tool_count);

      const toolNames = tools.map((t) => t.name);
      expect(toolNames).toContain("weave_search");
      expect(toolNames).toContain("weave_add");
      expect(toolNames).toContain("weave_done");
      expect(toolNames).toContain("weave_edit_guard");
      expect(toolNames).toContain("weave_batch_done");
      expect(toolNames).toContain("weave_context");
      expect(toolNames).toContain("weave_list");
      expect(toolNames).toContain("weave_link");
      expect(toolNames).toContain("weave_status");
      expect(toolNames).toContain("weave_health");
      expect(toolNames).toContain("weave_quick");
      expect(toolNames).toContain("weave_work");
      expect(toolNames).toContain("weave_ship");
      expect(toolNames).toContain("weave_overview");
      expect(toolNames).toContain("weave_bootstrap");
      expect(toolNames).toContain("weave_preflight");
      expect(toolNames).toContain("weave_sync");
      expect(toolNames).toContain("weave_resolve");
      expect(toolNames).toContain("weave_close_session");
      expect(toolNames).toContain("weave_tree");
      expect(toolNames).toContain("weave_learnings");
      expect(toolNames).toContain("weave_update");
      expect(toolNames).toContain("weave_touch");
      expect(toolNames).toContain("weave_trails");
      expect(toolNames).toContain("weave_breadcrumbs");
      expect(toolNames).toContain("weave_plan");
      expect(toolNames).toContain("weave_show");
      expect(toolNames).toContain("weave_delete");
      expect(toolNames).toContain("weave_quality_scan");
      expect(toolNames).toContain("weave_quality_hotspots");
      expect(toolNames).toContain("weave_quality_diff");
      expect(toolNames).toContain("weave_quality_functions");
      expect(toolNames).toContain("weave_structural_search");
      expect(toolNames).toContain("weave_quality_patterns");
      expect(toolNames).toContain("weave_unlink");
      expect(toolNames).toContain("weave_block");
      expect(toolNames).toContain("weave_unarchive");
      expect(toolNames).toContain("weave_ready");
      expect(toolNames).toContain("weave_impact");
      expect(toolNames).toContain("weave_query");
      expect(toolNames).toContain("weave_code_search");
      expect(toolNames).toContain("weave_index");
    });

    it("should advertise phased read defaults and schema compatibility", async () => {
      const response = await client.request("tools/list");
      expect(response.error).toBeUndefined();

      const tools = (
        response.result as {
          tools: Array<{
            name: string;
            description: string;
            inputSchema: { properties?: Record<string, { enum?: string[] }> };
          }>;
        }
      ).tools;
      const byName = Object.fromEntries(tools.map((tool) => [tool.name, tool]));

      expect(byName.weave_list.description).toContain("json-v2");
      expect(byName.weave_show.description).toContain("json-v2");
      expect(byName.weave_status.description).toContain("discover mode");
      expect(byName.weave_overview.description).toContain("discover mode");
      expect(byName.weave_learnings.description).toContain("discover-mode bounded");

      expect(byName.weave_context.inputSchema.properties?.mode?.enum).toEqual([
        "bootstrap",
        "discover",
        "execute",
        "full",
      ]);
      expect(byName.weave_status.inputSchema.properties?.mode?.enum).toEqual([
        "bootstrap",
        "discover",
        "execute",
        "full",
      ]);
      expect(byName.weave_overview.inputSchema.properties?.mode?.enum).toEqual([
        "bootstrap",
        "discover",
        "execute",
        "full",
      ]);
      expect(byName.weave_learnings.inputSchema.properties?.mode?.enum).toEqual([
        "bootstrap",
        "discover",
        "execute",
        "full",
      ]);
      expect(byName.weave_learnings.inputSchema.properties?.category?.enum).toEqual([
        "decision",
        "pattern",
        "pitfall",
        "learning",
      ]);
      expect(byName.weave_add.inputSchema.properties?.status?.enum).toEqual(
        expect.arrayContaining(["active", "in-progress", "in_progress"])
      );
      // wv-07bd33: CLI `wv add --verification-plan` had no MCP schema
      // counterpart (tests/test-mcp-parity.sh drift). Guards the schema half
      // of the fix; the forwarding half is covered by the tools/call test
      // "forwards verification_plan to wv add" below.
      expect(
        (byName.weave_add.inputSchema.properties as Record<string, { type?: string }>)?.verification_plan?.type
      ).toBe("string");
      expect(byName.weave_list.inputSchema.properties?.status?.enum).toEqual(
        expect.arrayContaining(["active", "in-progress", "in_progress"])
      );
      expect(byName.weave_update.inputSchema.properties?.status?.enum).toEqual(
        expect.arrayContaining(["active", "in-progress", "in_progress"])
      );
    });
  });

  describe("tools/call", () => {
    it("weave_status should return status info", async () => {
      const response = await client.request("tools/call", {
        name: "weave_status",
        arguments: {},
      });

      expect(response.error).toBeUndefined();
      const result = response.result as { content: { text: string }[] };
      expect(result.content).toBeDefined();
      expect(result.content[0].text).toBeTruthy();
    });

    it("weave_overview should return composed overview sections", async () => {
      const response = await client.request("tools/call", {
        name: "weave_overview",
        arguments: {},
      });

      expect(response.error).toBeUndefined();
      const result = response.result as { content: { text: string }[] };
      expect(result.content).toBeDefined();
      expect(result.content[0].text).toContain("=== Status ===");
      expect(result.content[0].text).toContain("=== Ready Work ===");
    });

    it("weave_context should return JSON context for a node", async () => {
      const nodeId = await createTrackedNode("test-context-node");
      const response = await client.request("tools/call", {
        name: "weave_context",
        arguments: { id: nodeId },
      });

      expect(response.error).toBeUndefined();
      const result = response.result as { content: { text: string }[] };
      expect(result.content).toBeDefined();
      const context = JSON.parse(result.content[0].text);
      expect(context.node.id).toBe(nodeId);
      expect(Array.isArray(context.blockers)).toBe(true);
    });

    it("weave_impact should wrap wv impact --json", async () => {
      const seedId = await createTrackedNode("test-impact-seed");
      const depId = await createTrackedNode("test-impact-dependent");

      const linkResponse = await client.request("tools/call", {
        name: "weave_link",
        arguments: { from_id: seedId, to_id: depId, type: "blocks" },
      });
      expect(linkResponse.error).toBeUndefined();

      const response = await client.request("tools/call", {
        name: "weave_impact",
        arguments: { ids: [seedId], direction: "fwd" },
      });

      expect(response.error).toBeUndefined();
      const result = response.result as { content: { text: string }[] };
      const payload = JSON.parse(result.content[0].text) as {
        seeds: Array<{ node_id: string }>;
        impacted: Array<{ node_id: string }>;
      };
      expect(payload.seeds.map((s) => s.node_id)).toContain(seedId);
      expect(payload.impacted.map((n) => n.node_id)).toContain(depId);
    });

    it("weave_health should return health info", async () => {
      const response = await client.request("tools/call", {
        name: "weave_health",
        arguments: {},
      });

      expect(response.error).toBeUndefined();
      const result = response.result as { content: { text: string }[] };
      expect(result.content).toBeDefined();
      // Should be valid JSON
      const health = JSON.parse(result.content[0].text);
      expect(health).toHaveProperty("score");
    });

    it("weave_guide forwards procedure id to wv guide --procedure", async () => {
      // An unknown id round-trips through the CLI; the error echoes the exact id
      // and config path, proving the MCP surface forwards --procedure=<id> rather
      // than silently dropping it or sharing only the CLI backend by name.
      const response = await client.request("tools/call", {
        name: "weave_guide",
        arguments: { procedure: "zzz-mcp-fwd-probe" },
      });
      expect(response.error).toBeUndefined();
      const result = response.result as { isError?: boolean; content: { text: string }[] };
      expect(result.isError).toBe(true);
      expect(result.content[0].text).toContain("zzz-mcp-fwd-probe");
    });

    it("weave_guide rejects topic and procedure together", async () => {
      const response = await client.request("tools/call", {
        name: "weave_guide",
        arguments: { topic: "workflow", procedure: "session" },
      });
      expect(response.error).toBeUndefined();
      const result = response.result as { isError?: boolean; content: { text: string }[] };
      expect(result.isError).toBe(true);
      expect(result.content[0].text).toContain("either topic or procedure");
    });

    it("weave_guide advertises both topic and procedure in its schema", async () => {
      const response = await client.request("tools/list");
      expect(response.error).toBeUndefined();
      const tools = (
        response.result as {
          tools: Array<{ name: string; inputSchema: { properties?: Record<string, unknown> } }>;
        }
      ).tools;
      const guide = tools.find((t) => t.name === "weave_guide");
      expect(guide).toBeDefined();
      expect(guide?.inputSchema.properties).toHaveProperty("topic");
      expect(guide?.inputSchema.properties).toHaveProperty("procedure");
    });

    it("weave_list should return json-v2 node list", async () => {
      const nodeId = await createTrackedNode("test-list-node", { probe: "list-json-v2" });
      const response = await client.request("tools/call", {
        name: "weave_list",
        arguments: {},
      });

      expect(response.error).toBeUndefined();
      const result = response.result as { content: { text: string }[] };
      expect(result.content).toBeDefined();
      // Should be valid JSON array
      const nodes = JSON.parse(result.content[0].text);
      expect(Array.isArray(nodes)).toBe(true);
      const node = nodes.find((entry: { id: string }) => entry.id === nodeId);
      expect(node).toBeDefined();
      expect(node.metadata).toEqual(expect.objectContaining({ probe: "list-json-v2" }));
      expect(node).not.toHaveProperty("created_at");
      expect(node).not.toHaveProperty("updated_at");
    });

    it("weave_search should search nodes", async () => {
      const response = await client.request("tools/call", {
        name: "weave_search",
        arguments: { query: "weave" },
      });

      expect(response.error).toBeUndefined();
      const result = response.result as { content: { text: string }[] };
      expect(result.content).toBeDefined();
    });

    it("weave_tree should return text tree by default", async () => {
      const response = await client.request("tools/call", {
        name: "weave_tree",
        arguments: {},
      });

      expect(response.error).toBeUndefined();
      const result = response.result as { content: { text: string }[] };
      expect(result.content).toBeDefined();
      expect(result.content[0].text).toBeTruthy();
    });

    it("weave_tree with json=true should return JSON tree", async () => {
      const response = await client.request("tools/call", {
        name: "weave_tree",
        arguments: { json: true },
      });

      expect(response.error).toBeUndefined();
      const result = response.result as { content: { text: string }[] };
      expect(result.content).toBeDefined();
      const tree = JSON.parse(result.content[0].text);
      expect(Array.isArray(tree)).toBe(true);
    });

    it("weave_tree with active filter should work", async () => {
      const response = await client.request("tools/call", {
        name: "weave_tree",
        arguments: { active: true },
      });

      expect(response.error).toBeUndefined();
      const result = response.result as { content: { text: string }[] };
      expect(result.content).toBeDefined();
    });

    it("weave_learnings should return JSON array", async () => {
      const response = await client.request("tools/call", {
        name: "weave_learnings",
        arguments: {},
      });

      expect(response.error).toBeUndefined();
      const result = response.result as { content: { text: string }[] };
      expect(result.content).toBeDefined();
      const learnings = JSON.parse(result.content[0].text);
      expect(Array.isArray(learnings)).toBe(true);
    });

    it("weave_learnings with grep filter should work", async () => {
      const response = await client.request("tools/call", {
        name: "weave_learnings",
        arguments: { grep: "sync" },
      });

      expect(response.error).toBeUndefined();
      const result = response.result as { content: { text: string }[] };
      expect(result.content).toBeDefined();
    });

    it("weave_trails show should return content", async () => {
      const response = await client.request("tools/call", {
        name: "weave_trails",
        arguments: { action: "show" },
      });

      expect(response.error).toBeUndefined();
      const result = response.result as { content: { text: string }[] };
      expect(result.content).toBeDefined();
    });

    it("weave_breadcrumbs (deprecated alias) show should return content", async () => {
      const response = await client.request("tools/call", {
        name: "weave_breadcrumbs",
        arguments: { action: "show" },
      });

      expect(response.error).toBeUndefined();
      const result = response.result as { content: { text: string }[] };
      expect(result.content).toBeDefined();
    });

    it("weave_update should update a node", async () => {
      const response = await client.request("tools/call", {
        name: "weave_update",
        arguments: { id: "wv-0000", alias: "test-alias" },
      });

      expect(response.error).toBeUndefined();
      const result = response.result as { content: { text: string }[] };
      expect(result.content).toBeDefined();
      expect(result.content[0].text).toContain("Updated");
    });

    it("unknown tool should return error", async () => {
      const response = await client.request("tools/call", {
        name: "unknown_tool",
        arguments: {},
      });

      // MCP SDK returns error in result.isError
      const result = response.result as { isError?: boolean; content: { text: string }[] };
      expect(result.isError).toBe(true);
      expect(result.content[0].text).toContain("not available in scope");
    });

    // --- Shell injection prevention tests (Task 1 Sprint 9) ---
    it("weave_search should treat shell metacharacters as literal text", async () => {
      const response = await client.request("tools/call", {
        name: "weave_search",
        arguments: { query: "$(cat /etc/passwd)" },
      });
      // Should error with "no results" or similar — NOT leak file contents
      const result = response.result as { content: { text: string }[] };
      expect(result.content[0].text).not.toContain("root:");
    });

    it("weave_done with injection in learning should not execute", async () => {
      const response = await client.request("tools/call", {
        name: "weave_done",
        arguments: {
          id: "wv-0000",
          learning: "$(cat /etc/passwd)",
        },
      });
      // Should fail with "not found" or similar — NOT leak file contents
      const result = response.result as { isError?: boolean; content: { text: string }[] };
      expect(result.content[0].text).not.toContain("root:");
    });

    it("weave_done uses the lifecycle timeout for bounded close calls", () => {
      const sourcePath = resolve(__dirname, "index.ts");
      const handlerSource = readFileSync(existsSync(sourcePath) ? sourcePath : SERVER_PATH, "utf-8");
      expect(handlerSource).toContain("weave_done:");
      expect(handlerSource).toContain("result = wv(cmd, WV_LIFECYCLE_TIMEOUT)");
    });

    it("weave_done forwards an explicit completion file scope", async () => {
      const wrapper = createLoggedWvWrapper();
      const loggedClient = new MCPTestClient([], { WV_PATH: wrapper.wvPath });
      let commands: string[] = [];
      try {
        await loggedClient.request("tools/call", {
          name: "weave_done",
          arguments: {
            id: "wv-0000",
            completion_files: ["scripts/example.py", "tests/test-example.sh"],
          },
        });
        commands = readLoggedCommands(wrapper.logPath);
      } finally {
        await loggedClient.close();
        wrapper.cleanup();
      }
      expect(commands).toEqual(
        expect.arrayContaining([
          expect.stringContaining("done wv-0000 --completion-files=scripts/example.py,tests/test-example.sh"),
        ])
      );
    });

    it("weave_add with backtick injection should not execute", async () => {
      const response = await client.request("tools/call", {
        name: "weave_add",
        arguments: { text: "`cat /etc/passwd`", standalone: true },
      });
      // The node text should be the literal backtick string, not file contents
      const result = response.result as { content: { text: string }[] };
      createdNodeIds.push(extractNodeId(result.content[0].text));
      expect(result.content[0].text).not.toContain("root:");
    });

    it("weave_add forwards verification_plan to wv add (wv-07bd33)", async () => {
      const addResponse = await client.request("tools/call", {
        name: "weave_add",
        arguments: {
          text: "test-verification-plan-forwarding",
          standalone: true,
          verification_plan: "make check-full exits 0",
        },
      });
      expect(addResponse.error).toBeUndefined();
      const addResult = addResponse.result as { isError?: boolean; content: { text: string }[] };
      expect(addResult.isError).not.toBe(true);
      const nodeId = extractNodeId(addResult.content[0].text);
      createdNodeIds.push(nodeId);

      const showResponse = await client.request("tools/call", {
        name: "weave_show",
        arguments: { id: nodeId },
      });
      const showResult = showResponse.result as { content: { text: string }[] };
      const nodes = JSON.parse(showResult.content[0].text);
      expect(nodes[0].metadata).toEqual(expect.objectContaining({ verification_plan: "make check-full exits 0" }));
    });

    // --- New tool tests (wv-5c5e0f) ---
    it("weave_show should return json-v2 content for valid node", async () => {
      const nodeId = await createTrackedNode("test-show-node", { probe: "show-json-v2" });
      const response = await client.request("tools/call", {
        name: "weave_show",
        arguments: { id: nodeId },
      });

      expect(response.error).toBeUndefined();
      const result = response.result as { content: { text: string }[] };
      expect(result.content).toBeDefined();
      const nodes = JSON.parse(result.content[0].text);
      expect(Array.isArray(nodes)).toBe(true);
      expect(nodes[0]).toHaveProperty("id");
      expect(nodes[0].id).toBe(nodeId);
      expect(nodes[0].metadata).toEqual(expect.objectContaining({ probe: "show-json-v2" }));
      expect(nodes[0]).not.toHaveProperty("created_at");
      expect(nodes[0]).not.toHaveProperty("updated_at");
    });

    it("weave_delete without force should error", async () => {
      const response = await client.request("tools/call", {
        name: "weave_delete",
        arguments: { id: "wv-0000", force: false },
      });

      const result = response.result as { isError?: boolean; content: { text: string }[] };
      expect(result.isError).toBe(true);
      expect(result.content[0].text).toContain("force=true");
    });

    it("weave_delete with dry_run should preview without deleting", async () => {
      const response = await client.request("tools/call", {
        name: "weave_delete",
        arguments: { id: "wv-0000", force: true, dry_run: true },
      });

      expect(response.error).toBeUndefined();
      const result = response.result as { content: { text: string }[] };
      expect(result.content).toBeDefined();
    });

    it("weave_quality_hotspots should return content", async () => {
      const response = await client.request("tools/call", {
        name: "weave_quality_hotspots",
        arguments: {},
      });

      // May error if no quality.db exists, but should not crash
      const result = response.result as { content: { text: string }[] };
      expect(result.content).toBeDefined();
    });

    it("weave_quality_diff should return content", async () => {
      const response = await client.request("tools/call", {
        name: "weave_quality_diff",
        arguments: {},
      });

      // May error if no quality.db exists, but should not crash
      const result = response.result as { content: { text: string }[] };
      expect(result.content).toBeDefined();
    });

    it("weave_quality_patterns list additively surfaces scope and shadow_advisories (wv-6cd72e)", async () => {
      const fixture = createQualityPatternsFixture();
      const patternsClient = new MCPTestClient([], fixture.env, fixture.dir);
      try {
        const response = await patternsClient.request("tools/call", {
          name: "weave_quality_patterns",
          arguments: { subcommand: "list" },
        });
        expect(response.error).toBeUndefined();
        const result = response.result as { content: { text: string }[] };
        const payload = JSON.parse(result.content[0].text) as {
          rules: unknown[];
          scope: string | null;
          shadow_advisories: string[];
        };
        // Built-in default rules (scripts/weave_quality/default_patterns/)
        // are always present, regardless of the fixture's own (empty)
        // .weave/patterns/ dir.
        expect(Array.isArray(payload.rules)).toBe(true);
        expect(payload.rules.length).toBeGreaterThan(0);
        // No scan has run in this fixture -- scope stays null, additively
        // present rather than absent.
        expect(payload.scope).toBeNull();
        expect(payload.shadow_advisories).toEqual([]);
      } finally {
        await patternsClient.close();
        fixture.cleanup();
      }
    });

    it("weave_quality_patterns validate reports an invalid rule without hiding the rest (wv-6cd72e)", async () => {
      const fixture = createQualityPatternsFixture();
      // Unlike scan/list (fail closed on the first invalid rule), validate
      // reports every candidate independently -- see cmd_patterns_validate.
      writeFileSync(join(fixture.dir, ".weave", "patterns", "broken-rule.yaml"), "id: [unclosed\n", "utf-8");
      const patternsClient = new MCPTestClient([], fixture.env, fixture.dir);
      try {
        const response = await patternsClient.request("tools/call", {
          name: "weave_quality_patterns",
          arguments: { subcommand: "validate" },
        });
        expect(response.error).toBeUndefined();
        const result = response.result as { content: { text: string }[] };
        const payload = JSON.parse(result.content[0].text) as {
          rules: Array<{ rule_id: string; status: string; error?: string }>;
          valid: boolean;
        };
        expect(payload.valid).toBe(false);
        const broken = payload.rules.find((r) => r.rule_id === "broken-rule");
        expect(broken?.status).toBe("invalid");
        expect(broken?.error).toContain("missing or empty 'id'");
        // The rest of the (built-in) rules still validate independently --
        // one broken file must not hide the others.
        expect(payload.rules.some((r) => r.status === "valid")).toBe(true);
      } finally {
        await patternsClient.close();
        fixture.cleanup();
      }
    });

    it("weave_quality_patterns forwards path and preserves scan target/report scope (wv-6cd72e)", async () => {
      const fixture = createQualityPatternsFixture();
      writeFileSync(
        join(fixture.dir, ".weave", "patterns", "test-lexicon-rule.yaml"),
        "id: test-lexicon-rule\nlanguage: prose\nkind: regex\npatterns:\n  - forbidden\n",
        "utf-8"
      );
      writeFileSync(join(fixture.dir, "doc.md"), "This text contains the forbidden word.\n", "utf-8");
      const patternsClient = new MCPTestClient([], fixture.env, fixture.dir);
      try {
        const scanResponse = await patternsClient.request("tools/call", {
          name: "weave_quality_patterns",
          arguments: { subcommand: "scan", path: "doc.md" },
        });
        expect(scanResponse.error).toBeUndefined();
        const scanResult = scanResponse.result as { content: { text: string }[] };
        const scanPayload = JSON.parse(scanResult.content[0].text) as { findings: number };
        expect(scanPayload.findings).toBe(1);

        const reportResponse = await patternsClient.request("tools/call", {
          name: "weave_quality_patterns",
          arguments: { subcommand: "report", path: "doc.md" },
        });
        expect(reportResponse.error).toBeUndefined();
        const reportResult = reportResponse.result as { content: { text: string }[] };
        const reportPayload = JSON.parse(reportResult.content[0].text) as {
          scope: string | null;
          by_rule: Record<string, { findings: number }>;
        };
        // Preserved verbatim from the CLI's own --json payload -- the path
        // argument was forwarded, not reimplemented.
        expect(reportPayload.scope).toBe("doc.md");
        expect(reportPayload.by_rule["test-lexicon-rule"].findings).toBe(1);
      } finally {
        await patternsClient.close();
        fixture.cleanup();
      }
    });

    it("weave_quality_patterns direct report call rejects malformed JSON (wv-67a6e5)", async () => {
      // wv-67a6e5 (external code review round 3, finding 7): a DIRECT
      // {subcommand: "report"} call used to fall straight through to the
      // generic wv() helper -- any exit-0 stdout was returned as
      // successful tool content, no shape check at all.
      const fixture = createQualityPatternsFixture();
      const fakeWv = createFakeWvForReport("not valid json{{{", 0);
      const patternsClient = new MCPTestClient([], { ...fixture.env, WV_PATH: fakeWv.wvPath }, fixture.dir);
      try {
        const response = await patternsClient.request("tools/call", {
          name: "weave_quality_patterns",
          arguments: { subcommand: "report" },
        });
        const result = response.result as { isError?: boolean; content: { text: string }[] };
        expect(result.isError).toBe(true);
        expect(result.content[0].text).toContain("malformed JSON");
      } finally {
        await patternsClient.close();
        fakeWv.cleanup();
        fixture.cleanup();
      }
    });

    it.each([
      ["an empty object", "{}"],
      ["an empty array", "[]"],
      ["scope alone, missing by_rule/recurring_waivers/finding_count", JSON.stringify({ scope: "ok" })],
      [
        "every field present but wrongly typed",
        JSON.stringify({ by_rule: "bogus", recurring_waivers: 42, finding_count: -1, scope: "ok" }),
      ],
    ])(
      "weave_quality_patterns direct report call rejects %s as a wrong-shaped payload (wv-67a6e5)",
      async (_label, reportStdout) => {
        const fixture = createQualityPatternsFixture();
        const fakeWv = createFakeWvForReport(reportStdout, 0);
        const patternsClient = new MCPTestClient([], { ...fixture.env, WV_PATH: fakeWv.wvPath }, fixture.dir);
        try {
          const response = await patternsClient.request("tools/call", {
            name: "weave_quality_patterns",
            arguments: { subcommand: "report" },
          });
          const result = response.result as { isError?: boolean; content: { text: string }[] };
          expect(result.isError).toBe(true);
          expect(result.content[0].text).toContain("unexpected payload shape");
        } finally {
          await patternsClient.close();
          fakeWv.cleanup();
          fixture.cleanup();
        }
      }
    );

    it("weave_quality_patterns validate accepts a path argument (wv-6cd72e)", async () => {
      const fixture = createQualityPatternsFixture();
      const patternsClient = new MCPTestClient([], fixture.env, fixture.dir);
      try {
        const response = await patternsClient.request("tools/call", {
          name: "weave_quality_patterns",
          arguments: { subcommand: "validate", path: fixture.dir },
        });
        expect(response.error).toBeUndefined();
        const result = response.result as { content: { text: string }[] };
        const payload = JSON.parse(result.content[0].text) as { valid: boolean };
        expect(payload.valid).toBe(true);
      } finally {
        await patternsClient.close();
        fixture.cleanup();
      }
    });

    it("weave_quality_patterns validate rejects malformed JSON instead of returning it (wv-c4e639)", async () => {
      const fixture = createQualityPatternsFixture();
      const fakeWv = createFakeWvForValidate("not valid json{{{", 0);
      const patternsClient = new MCPTestClient([], { ...fixture.env, WV_PATH: fakeWv.wvPath }, fixture.dir);
      try {
        const response = await patternsClient.request("tools/call", {
          name: "weave_quality_patterns",
          arguments: { subcommand: "validate" },
        });
        const result = response.result as { isError?: boolean; content: { text: string }[] };
        expect(result.isError).toBe(true);
        expect(result.content[0].text).toContain("malformed JSON");
      } finally {
        await patternsClient.close();
        fakeWv.cleanup();
        fixture.cleanup();
      }
    });

    it("weave_quality_patterns validate rejects a wrong-shaped payload (wv-c4e639)", async () => {
      const fixture = createQualityPatternsFixture();
      // Well-formed JSON, but missing the required valid/rules fields --
      // e.g. a stray {"ok": true} from some unrelated future command
      // reusing this exit convention.
      const fakeWv = createFakeWvForValidate(JSON.stringify({ ok: true }), 0);
      const patternsClient = new MCPTestClient([], { ...fixture.env, WV_PATH: fakeWv.wvPath }, fixture.dir);
      try {
        const response = await patternsClient.request("tools/call", {
          name: "weave_quality_patterns",
          arguments: { subcommand: "validate" },
        });
        const result = response.result as { isError?: boolean; content: { text: string }[] };
        expect(result.isError).toBe(true);
        expect(result.content[0].text).toContain("unexpected payload shape");
      } finally {
        await patternsClient.close();
        fakeWv.cleanup();
        fixture.cleanup();
      }
    });

    it("weave_quality_patterns validate rejects an exit code that disagrees with its own payload (wv-c4e639)", async () => {
      const fixture = createQualityPatternsFixture();
      // Well-formed, correctly-shaped, internally CONSISTENT payload
      // (valid:false genuinely matches its one rules[] entry's own
      // status:"invalid" -- see wv-860c8c's rules[]/valid consistency
      // check, which fires first and must not be what trips this test),
      // but exit 0 while claiming valid: false -- cmd_patterns_validate's
      // own invariant is `0 if all_valid else 1`, so this combination
      // should never occur for a genuine run.
      const fakeWv = createFakeWvForValidate(
        JSON.stringify({
          valid: false,
          rules: [{ rule_id: "broken-rule", path: "/tmp/broken-rule.yaml", status: "invalid", error: "bad schema" }],
          coverage: VALID_COVERAGE,
        }),
        0
      );
      const patternsClient = new MCPTestClient([], { ...fixture.env, WV_PATH: fakeWv.wvPath }, fixture.dir);
      try {
        const response = await patternsClient.request("tools/call", {
          name: "weave_quality_patterns",
          arguments: { subcommand: "validate" },
        });
        const result = response.result as { isError?: boolean; content: { text: string }[] };
        expect(result.isError).toBe(true);
        expect(result.content[0].text).toContain("disagrees with its own payload");
      } finally {
        await patternsClient.close();
        fakeWv.cleanup();
        fixture.cleanup();
      }
    });

    it("weave_quality_patterns validate rejects an unexpected exit code (wv-c4e639)", async () => {
      const fixture = createQualityPatternsFixture();
      // exit 2 with well-formed-looking stdout -- a crash or partial
      // timeout write that happens to leave SOMETHING on stdout must
      // not be mistaken for a real result just because it's nonempty.
      const fakeWv = createFakeWvForValidate(JSON.stringify({ valid: true, rules: [] }), 2);
      const patternsClient = new MCPTestClient([], { ...fixture.env, WV_PATH: fakeWv.wvPath }, fixture.dir);
      try {
        const response = await patternsClient.request("tools/call", {
          name: "weave_quality_patterns",
          arguments: { subcommand: "validate" },
        });
        const result = response.result as { isError?: boolean; content: { text: string }[] };
        expect(result.isError).toBe(true);
        expect(result.content[0].text).toContain("unexpected code 2");
      } finally {
        await patternsClient.close();
        fakeWv.cleanup();
        fixture.cleanup();
      }
    });

    it("weave_quality_patterns list surfaces scope_error distinctly from a legitimate null scope (wv-5b9f55)", async () => {
      // wv-5b9f55 finding 8 (external code review): a genuine failure in
      // list's internal `report --json` call (used only to obtain scope)
      // used to be silently folded into the same scope: null a legitimate
      // "no scan has ever run" naturally produces -- indistinguishable to
      // a caller either way. This fake `wv` makes ONLY "quality patterns
      // report" fail (list's own primary call passes through to the real
      // binary untouched), so rules/shadow_advisories stay populated while
      // scope collapses to null WITH an additive scope_error explaining why.
      const fixture = createQualityPatternsFixture();
      const dir = mkdtempSync(join(tmpdir(), "weave-mcp-fakewv-report-"));
      const wvPath = join(dir, "wv-fake.sh");
      const realWvPath = resolve(__dirname, "../../scripts/wv");
      writeFileSync(
        wvPath,
        `#!/bin/sh\ncase "$*" in\n  *"quality patterns report"*)\n    echo "simulated report crash" >&2\n    exit 3\n    ;;\nesac\nexec ${JSON.stringify(realWvPath)} "$@"\n`,
        "utf-8"
      );
      chmodSync(wvPath, 0o755);
      const patternsClient = new MCPTestClient([], { ...fixture.env, WV_PATH: wvPath }, fixture.dir);
      try {
        const response = await patternsClient.request("tools/call", {
          name: "weave_quality_patterns",
          arguments: { subcommand: "list" },
        });
        expect(response.error).toBeUndefined();
        const result = response.result as { content: { text: string }[] };
        const payload = JSON.parse(result.content[0].text) as {
          rules: unknown[];
          scope: string | null;
          scope_error?: string;
          shadow_advisories: string[];
        };
        expect(Array.isArray(payload.rules)).toBe(true);
        expect(payload.rules.length).toBeGreaterThan(0);
        expect(payload.scope).toBeNull();
        expect(payload.scope_error).toContain("simulated report crash");
      } finally {
        await patternsClient.close();
        rmSync(dir, { recursive: true, force: true });
        fixture.cleanup();
      }
    });

    it("weave_quality_patterns list scopes its internal report call to path, not an unrelated ambient repo (wv-5b9f55)", async () => {
      // wv-5b9f55 finding 8 (external code review): report's own `repo`
      // resolution ignores any explicit path argument entirely for repo
      // purposes -- before this fix, list's internal report call inherited
      // repo resolution from the ambient REPO_ROOT/git-root/cwd instead of
      // the repo list itself was just asked to scope to. A deliberately
      // WRONG ambient REPO_ROOT (a second, unrelated repo) makes this
      // observable: report's own _report_scope canonicalization of its
      // stored last-scan target ("doc.md") against `repo` can only produce
      // the clean relative "doc.md" label when `repo` genuinely matches
      // where "doc.md" actually lives -- any other repo makes the target
      // un-relativizable, falling back to the full absolute path string
      // instead. (A second, related bug this same fix closes: report must
      // run with NO explicit path argument at all here -- forwarding
      // list's own repo-root path onto report's command line made report
      // treat it as an EXPLICIT SCAN TARGET override, always collapsing
      // scope to the degenerate "." instead of the real stored target.)
      const fixture = createQualityPatternsFixture();
      const wrongRepo = mkdtempSync(join(tmpdir(), "weave-mcp-wrong-repo-"));
      writeFileSync(
        join(fixture.dir, ".weave", "patterns", "test-lexicon-rule.yaml"),
        "id: test-lexicon-rule\nlanguage: prose\nkind: regex\npatterns:\n  - forbidden\n",
        "utf-8"
      );
      writeFileSync(join(fixture.dir, "doc.md"), "This text contains the forbidden word.\n", "utf-8");
      const patternsClient = new MCPTestClient([], { ...fixture.env, REPO_ROOT: wrongRepo }, fixture.dir);
      try {
        const scanResponse = await patternsClient.request("tools/call", {
          name: "weave_quality_patterns",
          arguments: { subcommand: "scan", path: "doc.md" },
        });
        expect(scanResponse.error).toBeUndefined();

        const response = await patternsClient.request("tools/call", {
          name: "weave_quality_patterns",
          arguments: { subcommand: "list", path: fixture.dir },
        });
        expect(response.error).toBeUndefined();
        const result = response.result as { content: { text: string }[] };
        const payload = JSON.parse(result.content[0].text) as { scope: string | null };
        // Clean relative label -- report's own repo agreed with list's,
        // despite the ambient REPO_ROOT pointing somewhere else entirely.
        expect(payload.scope).toBe("doc.md");
      } finally {
        await patternsClient.close();
        rmSync(wrongRepo, { recursive: true, force: true });
        fixture.cleanup();
      }
    });

    it("weave_quality_patterns list's own repo-root path is not mistaken for an explicit report target (wv-5b9f55)", async () => {
      // wv-5b9f55 finding 8 (external code review), isolated from the
      // ambient-repo mismatch above: even with NO wrong ambient REPO_ROOT
      // at all, forwarding list's own repo-root `path` onto report's
      // command line made report treat it as an EXPLICIT SCAN TARGET
      // override (_canonicalize_target(repo, explicit_path)) rather than
      // letting it fall through to its normal "last stored scan target"
      // lookup -- collapsing scope to the degenerate "." (target == repo)
      // instead of the real stored target ("doc.md") every time list was
      // called with an explicit path at all.
      const fixture = createQualityPatternsFixture();
      writeFileSync(
        join(fixture.dir, ".weave", "patterns", "test-lexicon-rule.yaml"),
        "id: test-lexicon-rule\nlanguage: prose\nkind: regex\npatterns:\n  - forbidden\n",
        "utf-8"
      );
      writeFileSync(join(fixture.dir, "doc.md"), "This text contains the forbidden word.\n", "utf-8");
      const patternsClient = new MCPTestClient([], fixture.env, fixture.dir);
      try {
        const scanResponse = await patternsClient.request("tools/call", {
          name: "weave_quality_patterns",
          arguments: { subcommand: "scan", path: "doc.md" },
        });
        expect(scanResponse.error).toBeUndefined();

        const response = await patternsClient.request("tools/call", {
          name: "weave_quality_patterns",
          arguments: { subcommand: "list", path: fixture.dir },
        });
        expect(response.error).toBeUndefined();
        const result = response.result as { content: { text: string }[] };
        const payload = JSON.parse(result.content[0].text) as { scope: string | null };
        expect(payload.scope).toBe("doc.md");
      } finally {
        await patternsClient.close();
        fixture.cleanup();
      }
    });

    it("weave_quality_patterns list surfaces a managed-rule shadow advisory (wv-6cd72e)", async () => {
      const fixture = createQualityPatternsFixture();
      const managedDir = join(fixture.dir, ".weave", "patterns", "managed");
      const configDir = join(fixture.dir, "config");
      const installedManagedDir = join(configDir, "quality-patterns", "managed");
      mkdirSync(managedDir, { recursive: true });
      mkdirSync(installedManagedDir, { recursive: true });
      writeFileSync(join(managedDir, ".overridden"), "shadowed-rule.yaml\n", "utf-8");
      writeFileSync(join(installedManagedDir, "manifest.txt"), "shadowed-rule.yaml\n", "utf-8");
      writeFileSync(
        join(installedManagedDir, "shadowed-rule.yaml"),
        "id: shadowed-rule\nlanguage: prose\nkind: regex\npatterns:\n  - managed\n",
        "utf-8"
      );
      writeFileSync(
        join(fixture.dir, ".weave", "patterns", "shadowed-rule.yaml"),
        "id: shadowed-rule\nlanguage: prose\nkind: regex\npatterns:\n  - absent\n",
        "utf-8"
      );
      const patternsClient = new MCPTestClient(
        [],
        { ...fixture.env, WV_CONFIG_DIR: configDir },
        fixture.dir
      );
      try {
        const response = await patternsClient.request("tools/call", {
          name: "weave_quality_patterns",
          arguments: { subcommand: "list" },
        });
        expect(response.error).toBeUndefined();
        const result = response.result as { content: { text: string }[] };
        const payload = JSON.parse(result.content[0].text) as {
          rules: Array<{ rule_id: string }>;
          shadow_advisories: string[];
        };
        // stdout's own rule listing is untouched by the advisory -- it's
        // additive, not a replacement.
        expect(payload.rules.some((r) => r.rule_id === "shadowed-rule")).toBe(true);
        expect(payload.shadow_advisories).toHaveLength(1);
        expect(payload.shadow_advisories[0]).toContain("shadowed-rule");
        expect(payload.shadow_advisories[0]).toContain("shadows an available");
      } finally {
        await patternsClient.close();
        fixture.cleanup();
      }
    });

    it("weave_quality_patterns list's internal report call resolves the requested repo even when the MCP server's own project root differs (wv-20adef)", async () => {
      // wv-20adef (external code review round 2): setting REPO_ROOT itself
      // in the report subprocess's env (wv-5b9f55's original fix) does not
      // survive the real `wv` wrapper -- the bash entry point's own
      // wv-config.sh unconditionally reassigns REPO_ROOT from
      // `git rev-parse --show-toplevel` against the wv subprocess's own
      // cwd (resolveProjectRoot(), the MCP SERVER's project root), before
      // _resolve_repo(None) in Python ever sees the value the MCP server
      // set. Every earlier test's MCPTestClient happened to be spawned
      // FROM the same directory as the requested repo, so this went
      // unnoticed -- here the MCP server's own cwd is a genuinely
      // unrelated directory, exposing the mismatch.
      const fixture = createQualityPatternsFixture();
      const mcpCwd = mkdtempSync(join(tmpdir(), "weave-mcp-unrelated-cwd-"));
      writeFileSync(
        join(fixture.dir, ".weave", "patterns", "test-lexicon-rule.yaml"),
        "id: test-lexicon-rule\nlanguage: prose\nkind: regex\npatterns:\n  - forbidden\n",
        "utf-8"
      );
      writeFileSync(join(fixture.dir, "doc.md"), "This text contains the forbidden word.\n", "utf-8");
      // Seed the scan directly (not through this test's own MCP client,
      // which is deliberately anchored elsewhere) -- cmd_patterns_scan's
      // own repo resolution (_resolve_repo(None)) always follows cwd, so
      // this subprocess's cwd is what makes it target fixture.dir.
      const scanResult = spawnSync(
        resolve(__dirname, "../../scripts/wv"),
        ["quality", "patterns", "scan", "--json", "doc.md"],
        {
          cwd: fixture.dir,
          encoding: "utf-8",
          env: { ...process.env, ...fixture.env, NO_COLOR: "1", WV_AGENT: "1" },
        }
      );
      expect(scanResult.status).toBe(0);

      const patternsClient = new MCPTestClient([], fixture.env, mcpCwd);
      try {
        const response = await patternsClient.request("tools/call", {
          name: "weave_quality_patterns",
          arguments: { subcommand: "list", path: fixture.dir },
        });
        expect(response.error).toBeUndefined();
        const result = response.result as { content: { text: string }[] };
        const payload = JSON.parse(result.content[0].text) as { scope: string | null; scope_error?: string };
        // A clean "doc.md" label (not null, not a scope_error) proves
        // report's own repo resolution followed fixture.dir -- the repo
        // list itself was scoped to -- not mcpCwd.
        expect(payload.scope_error).toBeUndefined();
        expect(payload.scope).toBe("doc.md");
      } finally {
        await patternsClient.close();
        rmSync(mcpCwd, { recursive: true, force: true });
        fixture.cleanup();
      }
    });

    it("weave_quality_patterns validate rejects a null entry in rules[] (wv-860c8c)", async () => {
      const fixture = createQualityPatternsFixture();
      const fakeWv = createFakeWvForValidate(
        JSON.stringify({ valid: true, rules: [null], coverage: VALID_COVERAGE }),
        0
      );
      const patternsClient = new MCPTestClient([], { ...fixture.env, WV_PATH: fakeWv.wvPath }, fixture.dir);
      try {
        const response = await patternsClient.request("tools/call", {
          name: "weave_quality_patterns",
          arguments: { subcommand: "validate" },
        });
        const result = response.result as { isError?: boolean; content: { text: string }[] };
        expect(result.isError).toBe(true);
        expect(result.content[0].text).toContain("unexpected shape");
      } finally {
        await patternsClient.close();
        fakeWv.cleanup();
        fixture.cleanup();
      }
    });

    it("weave_quality_patterns validate rejects a rules[] entry missing rule_id/path/error (wv-860c8c)", async () => {
      const fixture = createQualityPatternsFixture();
      const fakeWv = createFakeWvForValidate(
        JSON.stringify({ valid: true, rules: [{ status: "invalid" }], coverage: VALID_COVERAGE }),
        0
      );
      const patternsClient = new MCPTestClient([], { ...fixture.env, WV_PATH: fakeWv.wvPath }, fixture.dir);
      try {
        const response = await patternsClient.request("tools/call", {
          name: "weave_quality_patterns",
          arguments: { subcommand: "validate" },
        });
        const result = response.result as { isError?: boolean; content: { text: string }[] };
        expect(result.isError).toBe(true);
        expect(result.content[0].text).toContain("unexpected shape");
      } finally {
        await patternsClient.close();
        fakeWv.cleanup();
        fixture.cleanup();
      }
    });

    it("weave_quality_patterns validate rejects valid:false with an all-valid rules[] (wv-860c8c)", async () => {
      const fixture = createQualityPatternsFixture();
      const fakeWv = createFakeWvForValidate(
        JSON.stringify({
          valid: false,
          rules: [{ rule_id: "r", path: "/tmp/r.yaml", status: "valid", language: "python" }],
          coverage: VALID_COVERAGE,
        }),
        1
      );
      const patternsClient = new MCPTestClient([], { ...fixture.env, WV_PATH: fakeWv.wvPath }, fixture.dir);
      try {
        const response = await patternsClient.request("tools/call", {
          name: "weave_quality_patterns",
          arguments: { subcommand: "validate" },
        });
        const result = response.result as { isError?: boolean; content: { text: string }[] };
        expect(result.isError).toBe(true);
        expect(result.content[0].text).toContain("disagrees with its own rules[] statuses");
      } finally {
        await patternsClient.close();
        fakeWv.cleanup();
        fixture.cleanup();
      }
    });

    it("weave_quality_patterns validate rejects an empty rules[] (wv-8b3f8a)", async () => {
      // wv-8b3f8a (external code review round 3 re-audit): {valid: true,
      // rules: []} used to pass -- every() is vacuously true on an empty
      // array for both the per-entry shape check and the valid/entries
      // consistency check. _DEFAULT_PATTERNS_DIR always ships built-in
      // rules, so an empty rules[] is not a reachable state from a
      // working install.
      const fixture = createQualityPatternsFixture();
      const fakeWv = createFakeWvForValidate(JSON.stringify({ valid: true, rules: [], coverage: VALID_COVERAGE }), 0);
      const patternsClient = new MCPTestClient([], { ...fixture.env, WV_PATH: fakeWv.wvPath }, fixture.dir);
      try {
        const response = await patternsClient.request("tools/call", {
          name: "weave_quality_patterns",
          arguments: { subcommand: "validate" },
        });
        const result = response.result as { isError?: boolean; content: { text: string }[] };
        expect(result.isError).toBe(true);
        expect(result.content[0].text).toContain("unexpected payload shape");
      } finally {
        await patternsClient.close();
        fakeWv.cleanup();
        fixture.cleanup();
      }
    });

    it("weave_quality_patterns validate rejects a valid entry missing language (wv-8b3f8a)", async () => {
      // cmd_patterns_validate always sets entry["language"] on every
      // status=="valid" entry (and clears it again if a later duplicate-
      // id collision demotes it to "invalid") -- a valid entry without
      // one is exactly as unreachable as an invalid one without `error`.
      const fixture = createQualityPatternsFixture();
      const fakeWv = createFakeWvForValidate(
        JSON.stringify({
          valid: true,
          rules: [{ rule_id: "r", path: "/tmp/r.yaml", status: "valid" }],
          coverage: VALID_COVERAGE,
        }),
        0
      );
      const patternsClient = new MCPTestClient([], { ...fixture.env, WV_PATH: fakeWv.wvPath }, fixture.dir);
      try {
        const response = await patternsClient.request("tools/call", {
          name: "weave_quality_patterns",
          arguments: { subcommand: "validate" },
        });
        const result = response.result as { isError?: boolean; content: { text: string }[] };
        expect(result.isError).toBe(true);
        expect(result.content[0].text).toContain("unexpected shape");
      } finally {
        await patternsClient.close();
        fakeWv.cleanup();
        fixture.cleanup();
      }
    });

    it("weave_quality_patterns validate rejects a valid entry carrying a leftover error field (wv-731450)", async () => {
      // wv-731450 (external code review round 3 re-audit): cmd_patterns_validate
      // builds an entry inside exactly one of two mutually exclusive
      // branches -- the try sets status/language, the except sets
      // status/error -- so a status=="valid" entry with an `error`
      // tagging along is exactly as unreachable as one missing `language`.
      const fixture = createQualityPatternsFixture();
      const fakeWv = createFakeWvForValidate(
        JSON.stringify({
          valid: true,
          rules: [{ rule_id: "r", path: "/tmp/r.yaml", status: "valid", language: "python", error: "boom" }],
          coverage: VALID_COVERAGE,
        }),
        0
      );
      const patternsClient = new MCPTestClient([], { ...fixture.env, WV_PATH: fakeWv.wvPath }, fixture.dir);
      try {
        const response = await patternsClient.request("tools/call", {
          name: "weave_quality_patterns",
          arguments: { subcommand: "validate" },
        });
        const result = response.result as { isError?: boolean; content: { text: string }[] };
        expect(result.isError).toBe(true);
        expect(result.content[0].text).toContain("unexpected shape");
      } finally {
        await patternsClient.close();
        fakeWv.cleanup();
        fixture.cleanup();
      }
    });

    it("weave_quality_patterns validate rejects an invalid entry carrying a leftover language field (wv-731450)", async () => {
      const fixture = createQualityPatternsFixture();
      const fakeWv = createFakeWvForValidate(
        JSON.stringify({
          valid: false,
          rules: [{ rule_id: "r", path: "/tmp/r.yaml", status: "invalid", error: "boom", language: "python" }],
          coverage: VALID_COVERAGE,
        }),
        1
      );
      const patternsClient = new MCPTestClient([], { ...fixture.env, WV_PATH: fakeWv.wvPath }, fixture.dir);
      try {
        const response = await patternsClient.request("tools/call", {
          name: "weave_quality_patterns",
          arguments: { subcommand: "validate" },
        });
        const result = response.result as { isError?: boolean; content: { text: string }[] };
        expect(result.isError).toBe(true);
        expect(result.content[0].text).toContain("unexpected shape");
      } finally {
        await patternsClient.close();
        fakeWv.cleanup();
        fixture.cleanup();
      }
    });

    it.each([
      [
        "a missing coverage field",
        { valid: true, rules: [{ rule_id: "r", path: "/tmp/r.yaml", status: "valid", language: "python" }] },
      ],
      [
        "coverage missing a required group",
        {
          valid: true,
          rules: [{ rule_id: "r", path: "/tmp/r.yaml", status: "valid", language: "python" }],
          coverage: { kinds: {}, match_scopes: {}, maturities: {} },
        },
      ],
      [
        "coverage with a non-boolean value",
        {
          valid: true,
          rules: [{ rule_id: "r", path: "/tmp/r.yaml", status: "valid", language: "python" }],
          coverage: { kinds: { lexicon: "yes" }, match_scopes: {}, maturities: {}, optional_keys: {} },
        },
      ],
      [
        "coverage whose groups are all vacuously empty (wv-731450)",
        {
          valid: true,
          rules: [{ rule_id: "r", path: "/tmp/r.yaml", status: "valid", language: "python" }],
          coverage: { kinds: {}, match_scopes: {}, maturities: {}, optional_keys: {} },
        },
      ],
    ])("weave_quality_patterns validate rejects %s (wv-8b3f8a)", async (_label, payload) => {
      const fixture = createQualityPatternsFixture();
      const fakeWv = createFakeWvForValidate(JSON.stringify(payload), 0);
      const patternsClient = new MCPTestClient([], { ...fixture.env, WV_PATH: fakeWv.wvPath }, fixture.dir);
      try {
        const response = await patternsClient.request("tools/call", {
          name: "weave_quality_patterns",
          arguments: { subcommand: "validate" },
        });
        const result = response.result as { isError?: boolean; content: { text: string }[] };
        expect(result.isError).toBe(true);
        expect(result.content[0].text).toContain("unexpected payload shape");
      } finally {
        await patternsClient.close();
        fakeWv.cleanup();
        fixture.cleanup();
      }
    });

    it("weave_quality_patterns validate accepts a genuine well-formed payload (wv-8b3f8a)", async () => {
      const fixture = createQualityPatternsFixture();
      const fakeWv = createFakeWvForValidate(
        JSON.stringify({
          valid: false,
          rules: [
            { rule_id: "good", path: "/tmp/good.yaml", status: "valid", language: "python" },
            { rule_id: "bad", path: "/tmp/bad.yaml", status: "invalid", error: "boom" },
          ],
          coverage: VALID_COVERAGE,
        }),
        1
      );
      const patternsClient = new MCPTestClient([], { ...fixture.env, WV_PATH: fakeWv.wvPath }, fixture.dir);
      try {
        const response = await patternsClient.request("tools/call", {
          name: "weave_quality_patterns",
          arguments: { subcommand: "validate" },
        });
        expect(response.error).toBeUndefined();
        const result = response.result as { isError?: boolean; content: { text: string }[] };
        expect(result.isError).toBeFalsy();
        const payload = JSON.parse(result.content[0].text) as { valid: boolean; rules: unknown[] };
        expect(payload.valid).toBe(false);
        expect(payload.rules).toHaveLength(2);
      } finally {
        await patternsClient.close();
        fakeWv.cleanup();
        fixture.cleanup();
      }
    });

    it("weave_quality_patterns list rejects empty stdout instead of fabricating rules: [] (wv-ce5ca6)", async () => {
      const fixture = createQualityPatternsFixture();
      const dir = mkdtempSync(join(tmpdir(), "weave-mcp-fakewv-list-"));
      const wvPath = join(dir, "wv-fake.sh");
      const realWvPath = resolve(__dirname, "../../scripts/wv");
      writeFileSync(
        wvPath,
        `#!/bin/sh\ncase "$*" in\n  *"quality patterns list"*)\n    exit 0\n    ;;\nesac\nexec ${JSON.stringify(realWvPath)} "$@"\n`,
        "utf-8"
      );
      chmodSync(wvPath, 0o755);
      const patternsClient = new MCPTestClient([], { ...fixture.env, WV_PATH: wvPath }, fixture.dir);
      try {
        const response = await patternsClient.request("tools/call", {
          name: "weave_quality_patterns",
          arguments: { subcommand: "list" },
        });
        const result = response.result as { isError?: boolean; content: { text: string }[] };
        expect(result.isError).toBe(true);
        expect(result.content[0].text).toContain("unexpected payload shape");
      } finally {
        await patternsClient.close();
        rmSync(dir, { recursive: true, force: true });
        fixture.cleanup();
      }
    });

    it.each([
      ["a scalar", "42"],
      ["an object", "{}"],
      ["null", "null"],
      ["an array with an invalid entry", JSON.stringify([{ rule_id: "x" }])],
    ])("weave_quality_patterns list rejects %s as rules (wv-ce5ca6)", async (_label, stdout) => {
      const fixture = createQualityPatternsFixture();
      const dir = mkdtempSync(join(tmpdir(), "weave-mcp-fakewv-list-"));
      const wvPath = join(dir, "wv-fake.sh");
      const realWvPath = resolve(__dirname, "../../scripts/wv");
      writeFileSync(
        wvPath,
        `#!/bin/sh\ncase "$*" in\n  *"quality patterns list"*)\n    printf '%s' ${JSON.stringify(stdout)}\n    exit 0\n    ;;\nesac\nexec ${JSON.stringify(realWvPath)} "$@"\n`,
        "utf-8"
      );
      chmodSync(wvPath, 0o755);
      const patternsClient = new MCPTestClient([], { ...fixture.env, WV_PATH: wvPath }, fixture.dir);
      try {
        const response = await patternsClient.request("tools/call", {
          name: "weave_quality_patterns",
          arguments: { subcommand: "list" },
        });
        const result = response.result as { isError?: boolean; content: { text: string }[] };
        expect(result.isError).toBe(true);
        expect(result.content[0].text).toContain("unexpected payload shape");
      } finally {
        await patternsClient.close();
        rmSync(dir, { recursive: true, force: true });
        fixture.cleanup();
      }
    });

    it.each([
      [
        "failed with hits:null but no error",
        JSON.stringify([{ rule_id: "r", path: "/tmp/r.yaml", status: "failed", hits: null }]),
      ],
      [
        "success with hits:null instead of a count",
        JSON.stringify([{ rule_id: "r", path: "/tmp/r.yaml", status: "success", hits: null }]),
      ],
      ["an unrecognized status", JSON.stringify([{ rule_id: "r", path: "/tmp/r.yaml", status: "bogus", hits: null }])],
      [
        "negative hits on success",
        JSON.stringify([{ rule_id: "r", path: "/tmp/r.yaml", status: "success", hits: -1 }]),
      ],
      [
        "fractional hits on success",
        JSON.stringify([{ rule_id: "r", path: "/tmp/r.yaml", status: "success", hits: 1.5 }]),
      ],
      [
        "not_run with a nonnull hits",
        JSON.stringify([{ rule_id: "r", path: "/tmp/r.yaml", status: "not_run", hits: 0 }]),
      ],
      [
        "success carrying a leftover error field (wv-731450)",
        JSON.stringify([{ rule_id: "r", path: "/tmp/r.yaml", status: "success", hits: 0, error: "scan failed" }]),
      ],
      [
        "not_run carrying a leftover error field (wv-731450)",
        JSON.stringify([{ rule_id: "r", path: "/tmp/r.yaml", status: "not_run", hits: null, error: "boom" }]),
      ],
    ])(
      "weave_quality_patterns list rejects %s as an impossible status/hits combination (wv-885d12)",
      async (_label, stdout) => {
        const fixture = createQualityPatternsFixture();
        const dir = mkdtempSync(join(tmpdir(), "weave-mcp-fakewv-list-"));
        const wvPath = join(dir, "wv-fake.sh");
        const realWvPath = resolve(__dirname, "../../scripts/wv");
        writeFileSync(
          wvPath,
          `#!/bin/sh\ncase "$*" in\n  *"quality patterns list"*)\n    printf '%s' ${JSON.stringify(stdout)}\n    exit 0\n    ;;\nesac\nexec ${JSON.stringify(realWvPath)} "$@"\n`,
          "utf-8"
        );
        chmodSync(wvPath, 0o755);
        const patternsClient = new MCPTestClient([], { ...fixture.env, WV_PATH: wvPath }, fixture.dir);
        try {
          const response = await patternsClient.request("tools/call", {
            name: "weave_quality_patterns",
            arguments: { subcommand: "list" },
          });
          const result = response.result as { isError?: boolean; content: { text: string }[] };
          expect(result.isError).toBe(true);
          expect(result.content[0].text).toContain("unexpected payload shape");
        } finally {
          await patternsClient.close();
          rmSync(dir, { recursive: true, force: true });
          fixture.cleanup();
        }
      }
    );

    it("weave_quality_patterns list accepts each of the three genuine status/hits states (wv-885d12)", async () => {
      const fixture = createQualityPatternsFixture();
      const dir = mkdtempSync(join(tmpdir(), "weave-mcp-fakewv-list-"));
      const wvPath = join(dir, "wv-fake.sh");
      const realWvPath = resolve(__dirname, "../../scripts/wv");
      const stdout = JSON.stringify([
        { rule_id: "a", path: "/tmp/a.yaml", status: "not_run", hits: null },
        { rule_id: "b", path: "/tmp/b.yaml", status: "failed", hits: null, error: "boom" },
        { rule_id: "c", path: "/tmp/c.yaml", status: "success", hits: 0 },
      ]);
      writeFileSync(
        wvPath,
        `#!/bin/sh\ncase "$*" in\n  *"quality patterns list"*)\n    printf '%s' ${JSON.stringify(stdout)}\n    exit 0\n    ;;\nesac\nexec ${JSON.stringify(realWvPath)} "$@"\n`,
        "utf-8"
      );
      chmodSync(wvPath, 0o755);
      const patternsClient = new MCPTestClient([], { ...fixture.env, WV_PATH: wvPath }, fixture.dir);
      try {
        const response = await patternsClient.request("tools/call", {
          name: "weave_quality_patterns",
          arguments: { subcommand: "list" },
        });
        expect(response.error).toBeUndefined();
        const result = response.result as { content: { text: string }[] };
        const payload = JSON.parse(result.content[0].text) as { rules: unknown[] };
        expect(payload.rules).toHaveLength(3);
      } finally {
        await patternsClient.close();
        rmSync(dir, { recursive: true, force: true });
        fixture.cleanup();
      }
    });

    it("weave_quality_patterns list does not label an unrelated stderr warning as a shadow advisory (wv-ce5ca6)", async () => {
      const fixture = createQualityPatternsFixture();
      const dir = mkdtempSync(join(tmpdir(), "weave-mcp-fakewv-list-"));
      const wvPath = join(dir, "wv-fake.sh");
      const realWvPath = resolve(__dirname, "../../scripts/wv");
      writeFileSync(
        wvPath,
        `#!/bin/sh
case "$*" in
  *"quality patterns list"*)
    echo "⚠ some unrelated future warning that also starts with the glyph" >&2
    printf '%s' '[{"rule_id":"r","path":"/tmp/r.yaml","status":"not_run","hits":null}]'
    exit 0
    ;;
esac
exec ${JSON.stringify(realWvPath)} "$@"
`,
        "utf-8"
      );
      chmodSync(wvPath, 0o755);
      const patternsClient = new MCPTestClient([], { ...fixture.env, WV_PATH: wvPath }, fixture.dir);
      try {
        const response = await patternsClient.request("tools/call", {
          name: "weave_quality_patterns",
          arguments: { subcommand: "list" },
        });
        expect(response.error).toBeUndefined();
        const result = response.result as { content: { text: string }[] };
        const payload = JSON.parse(result.content[0].text) as { shadow_advisories: string[] };
        expect(payload.shadow_advisories).toEqual([]);
      } finally {
        await patternsClient.close();
        rmSync(dir, { recursive: true, force: true });
        fixture.cleanup();
      }
    });

    it.each([
      ["an empty object", "{}"],
      ["an empty array", "[]"],
      ["a non-string scope", JSON.stringify({ scope: 42 })],
      // wv-67a6e5 (external code review round 3, finding 7): a
      // well-typed `scope` alone used to be sufficient here -- this
      // payload is missing by_rule/recurring_waivers/finding_count
      // entirely, which the shared isValidPatternReportPayload validator
      // (now used by both list's internal call and a direct report call)
      // rejects.
      ["scope alone, missing by_rule/recurring_waivers/finding_count", JSON.stringify({ scope: "ok" })],
    ])(
      "weave_quality_patterns list surfaces scope_error for report returning %s (wv-ce5ca6)",
      async (_label, reportStdout) => {
        const fixture = createQualityPatternsFixture();
        const dir = mkdtempSync(join(tmpdir(), "weave-mcp-fakewv-report-"));
        const wvPath = join(dir, "wv-fake.sh");
        const realWvPath = resolve(__dirname, "../../scripts/wv");
        writeFileSync(
          wvPath,
          `#!/bin/sh\ncase "$*" in\n  *"quality patterns report"*)\n    printf '%s' ${JSON.stringify(reportStdout)}\n    exit 0\n    ;;\nesac\nexec ${JSON.stringify(realWvPath)} "$@"\n`,
          "utf-8"
        );
        chmodSync(wvPath, 0o755);
        const patternsClient = new MCPTestClient([], { ...fixture.env, WV_PATH: wvPath }, fixture.dir);
        try {
          const response = await patternsClient.request("tools/call", {
            name: "weave_quality_patterns",
            arguments: { subcommand: "list" },
          });
          expect(response.error).toBeUndefined();
          const result = response.result as { content: { text: string }[] };
          const payload = JSON.parse(result.content[0].text) as {
            rules: unknown[];
            scope: string | null;
            scope_error?: string;
          };
          expect(Array.isArray(payload.rules)).toBe(true);
          expect(payload.rules.length).toBeGreaterThan(0);
          expect(payload.scope).toBeNull();
          expect(payload.scope_error).toContain("unexpected payload shape");
        } finally {
          await patternsClient.close();
          rmSync(dir, { recursive: true, force: true });
          fixture.cleanup();
        }
      }
    );

    it("weave_quality_patterns list's internal report call only gets what's left of the shared budget, not a fresh one (wv-c9ea87)", async () => {
      // wv-c9ea87 (external code review round 2): the primary list call
      // and its internal report call each used to get an independent,
      // fresh 60s timeout -- a slow primary call followed by a report call
      // that also stalls could block one synchronous MCP request for
      // close to 120s combined. WV_MCP_PATTERNS_LIST_BUDGET_MS lets this
      // test observe the shared-budget behavior in milliseconds instead of
      // waiting anywhere near a real 60s: the primary call alone (300ms)
      // already exhausts a 400ms shared budget, so report must be SKIPPED
      // entirely -- not given a fresh budget that would let its own 1s
      // sleep complete.
      const fixture = createQualityPatternsFixture();
      const dir = mkdtempSync(join(tmpdir(), "weave-mcp-fakewv-budget-"));
      const wvPath = join(dir, "wv-fake.sh");
      const realWvPath = resolve(__dirname, "../../scripts/wv");
      writeFileSync(
        wvPath,
        `#!/bin/sh
case "$*" in
  *"quality patterns list"*)
    sleep 0.3
    printf '%s' '[{"rule_id":"r","path":"/tmp/r.yaml","status":"not_run","hits":null}]'
    exit 0
    ;;
  *"quality patterns report"*)
    sleep 4
    printf '%s' '{"scope":null}'
    exit 0
    ;;
esac
exec ${JSON.stringify(realWvPath)} "$@"
`,
        "utf-8"
      );
      chmodSync(wvPath, 0o755);
      const patternsClient = new MCPTestClient(
        [],
        { ...fixture.env, WV_PATH: wvPath, WV_MCP_PATTERNS_LIST_BUDGET_MS: "400" },
        fixture.dir
      );
      try {
        const start = Date.now();
        const response = await patternsClient.request("tools/call", {
          name: "weave_quality_patterns",
          arguments: { subcommand: "list" },
        });
        const elapsed = Date.now() - start;
        expect(response.error).toBeUndefined();
        const result = response.result as { content: { text: string }[] };
        const payload = JSON.parse(result.content[0].text) as { scope: string | null; scope_error?: string };
        expect(payload.scope_error).toContain("budget");
        // A wide margin below primary(300ms) + report(4000ms) combined --
        // proves report never actually ran (a fresh-budget report call
        // would have pushed this past ~4300ms). Generous enough to absorb
        // process-spawn/stdio overhead without becoming flaky.
        expect(elapsed).toBeLessThan(3000);
      } finally {
        await patternsClient.close();
        rmSync(dir, { recursive: true, force: true });
        fixture.cleanup();
      }
    });

    it("weave_code_search reports readiness when chunks or graph context are missing", async () => {
      const fixture = createCodeSearchFixtureDb();
      const searchClient = new MCPTestClient([], { WV_DB: fixture.dbPath, WV_HOT_ZONE: fixture.hotZone });

      try {
        const response = await searchClient.request("tools/call", {
          name: "weave_code_search",
          arguments: { query: "nosuchterm", mode: "fts", graph: true },
        });

        expect(response.error).toBeUndefined();
        const result = response.result as { content: { text: string }[] };
        const payload = JSON.parse(result.content[0].text) as {
          results: unknown[];
          readiness: {
            chunks: { ready: boolean; status: string };
            node_files: { ready: boolean; status: string };
            quality_db: { ready: boolean; status: string };
          };
        };

        expect(Array.isArray(payload.results)).toBe(true);
        expect(payload.results).toHaveLength(0);
        expect(payload.readiness.chunks.ready).toBe(false);
        expect(payload.readiness.chunks.status).toBe("empty");
        expect(payload.readiness.node_files.ready).toBe(false);
        expect(payload.readiness.quality_db.ready).toBe(false);
      } finally {
        await searchClient.close();
        fixture.cleanup();
      }
    });

    it("weave_preflight blocks policy-sensitive nodes when quality prerequisites are missing", async () => {
      const dir = mkdtempSync(join(tmpdir(), "weave-mcp-preflight-"));
      const dbPath = join(dir, "brain.db");
      const env = { WV_DB: dbPath, WV_HOT_ZONE: dir, WV_PROJECT_ROOT: resolve(__dirname, "../..") };
      const createdId = createActiveNodeDirectWithEnv("test-policy-preflight", env);
      const resolvedNodeId =
        spawnSync(
          "sqlite3",
          [dbPath, "SELECT id FROM nodes WHERE text='test-policy-preflight' ORDER BY updated_at DESC LIMIT 1;"],
          {
            encoding: "utf-8",
            stdio: ["ignore", "pipe", "ignore"],
          }
        ).stdout.trim() || createdId;
      const preflightClient = new MCPTestClient([], env);

      spawnSync(
        "sqlite3",
        [dbPath, `INSERT OR IGNORE INTO node_files(node_id, path) VALUES ('${resolvedNodeId}', 'src/policy.py');`],
        {
          stdio: "ignore",
        }
      );

      try {
        const response = await preflightClient.request("tools/call", {
          name: "weave_preflight",
          arguments: { id: resolvedNodeId },
        });

        const result = response.result as { content: { text: string }[]; isError?: boolean };
        expect(result.isError).toBe(true);
        expect(result.content[0].text).toContain("not policy-ready");
        expect(result.content[0].text).toContain("wv quality scan . --json");
      } finally {
        await preflightClient.close();
        rmSync(dir, { recursive: true, force: true });
      }
    });

    it("weave_edit_guard should return content", async () => {
      const response = await client.request("tools/call", {
        name: "weave_edit_guard",
        arguments: {},
      });

      const result = response.result as {
        content: { text: string }[];
        isError?: boolean;
      };
      expect(result.content).toBeDefined();
      expect(result.content[0].text).toBeDefined();
      // With an active node (from the test env), should return OK or error — either is valid
      // The key is it doesn't crash and returns structured output
    });

    it("weave_edit_guard honors WV_PROJECT_ROOT outside repo cwd", async () => {
      const nodeId = createActiveNodeDirect("test-edit-guard-project-root");
      createdNodeIds.push(nodeId);

      const outsideRepoCwd = mkdtempSync(join(tmpdir(), "weave-mcp-cwd-"));
      const rootAwareClient = new MCPTestClient([], { WV_PROJECT_ROOT: resolve(__dirname, "../..") }, outsideRepoCwd);

      try {
        const response = await rootAwareClient.request("tools/call", {
          name: "weave_edit_guard",
          arguments: {},
        });

        const result = response.result as {
          content: { text: string }[];
          isError?: boolean;
        };

        expect(result.isError).not.toBe(true);
        expect(result.content[0].text).toContain("OK");
      } finally {
        await rootAwareClient.close();
        rmSync(outsideRepoCwd, { recursive: true, force: true });
      }
    });

    it("forwards --json-v2 for show and list", async () => {
      const nodeId = await createTrackedNode("test-forward-json-v2");
      const wrapper = createLoggedWvWrapper();
      const loggedClient = new MCPTestClient([], { WV_PATH: wrapper.wvPath });
      let commands: string[] = [];
      try {
        await loggedClient.request("tools/call", {
          name: "weave_show",
          arguments: { id: nodeId },
        });
        await loggedClient.request("tools/call", {
          name: "weave_list",
          arguments: {},
        });
        commands = readLoggedCommands(wrapper.logPath);
      } finally {
        await loggedClient.close();
        wrapper.cleanup();
      }
      expect(commands).toEqual(
        expect.arrayContaining([
          expect.stringContaining(`show ${nodeId} --json-v2`),
          expect.stringContaining("list --json-v2"),
        ])
      );
    });

    it("forwards --no-overlap-check for weave_ship", async () => {
      const nodeId = "wv-0000";
      const wrapper = createLoggedWvWrapper();
      const loggedClient = new MCPTestClient([], { WV_PATH: wrapper.wvPath });
      let commands: string[] = [];
      try {
        await loggedClient.request("tools/call", {
          name: "weave_ship",
          arguments: {
            id: nodeId,
            learning:
              "decision: keep ship parity with done | pattern: expose overlap opt-out through all agent paths | pitfall: wrappers drift when flags are added only to one close surface",
            no_overlap_check: true,
          },
        });

        commands = readLoggedCommands(wrapper.logPath);
      } finally {
        await loggedClient.close();
        wrapper.cleanup();
      }
      expect(commands).toEqual(
        expect.arrayContaining([
          expect.stringContaining(`ship-agent ${nodeId} --json --learning=`),
          expect.stringContaining("--no-overlap-check"),
        ])
      );
    });

    it("forwards discover mode for status, context, and overview reads", async () => {
      const nodeId = await createTrackedNode("test-forward-mode");
      const wrapper = createLoggedWvWrapper();
      const loggedClient = new MCPTestClient([], { WV_PATH: wrapper.wvPath });
      let commands: string[] = [];
      try {
        await loggedClient.request("tools/call", {
          name: "weave_status",
          arguments: {},
        });
        await loggedClient.request("tools/call", {
          name: "weave_context",
          arguments: { id: nodeId },
        });
        await loggedClient.request("tools/call", {
          name: "weave_overview",
          arguments: {},
        });
        commands = readLoggedCommands(wrapper.logPath);
      } finally {
        await loggedClient.close();
        wrapper.cleanup();
      }
      expect(commands).toEqual(
        expect.arrayContaining([
          expect.stringContaining("status --mode=discover"),
          expect.stringContaining(`context ${nodeId} --json --mode=discover`),
          expect.stringContaining("ready --mode=discover"),
        ])
      );
      expect(commands.filter((cmd) => cmd.includes("status --mode=discover")).length).toBeGreaterThanOrEqual(2);
    });

    it("forwards explicit mode overrides and legacy status aliases", async () => {
      const nodeId = await createTrackedNode("test-forward-explicit-mode");
      const wrapper = createLoggedWvWrapper();
      const loggedClient = new MCPTestClient([], { WV_PATH: wrapper.wvPath });
      let commands: string[] = [];
      try {
        const addResponse = await loggedClient.request("tools/call", {
          name: "weave_add",
          arguments: { text: "status alias add", status: "in_progress", standalone: true },
        });
        createdNodeIds.push(extractNodeId((addResponse.result as { content: { text: string }[] }).content[0].text));

        await loggedClient.request("tools/call", {
          name: "weave_status",
          arguments: { mode: "full" },
        });
        await loggedClient.request("tools/call", {
          name: "weave_context",
          arguments: { id: nodeId, mode: "bootstrap" },
        });
        await loggedClient.request("tools/call", {
          name: "weave_overview",
          arguments: { mode: "full" },
        });
        await loggedClient.request("tools/call", {
          name: "weave_learnings",
          arguments: { mode: "bootstrap" },
        });
        await loggedClient.request("tools/call", {
          name: "weave_list",
          arguments: { status: "in-progress" },
        });
        await loggedClient.request("tools/call", {
          name: "weave_search",
          arguments: { query: "sync", status: "in_progress" },
        });
        await loggedClient.request("tools/call", {
          name: "weave_update",
          arguments: { id: nodeId, status: "in-progress" },
        });
        commands = readLoggedCommands(wrapper.logPath);
      } finally {
        await loggedClient.close();
        wrapper.cleanup();
      }

      expect(commands).toEqual(
        expect.arrayContaining([
          expect.stringContaining("add status alias add --status=active"),
          expect.stringContaining("status --mode=full"),
          expect.stringContaining(`context ${nodeId} --json --mode=bootstrap`),
          expect.stringContaining("ready --mode=full"),
          expect.stringContaining("learnings --json --mode=bootstrap"),
          expect.stringContaining("list --json-v2 --status=active"),
          expect.stringContaining("search sync --json --status=active"),
          expect.stringContaining(`update ${nodeId} --status=active`),
        ])
      );
    });

    it("emits payload-byte instrumentation for tool responses", async () => {
      const nodeId = await createTrackedNode("test-instrument-payload");
      const instrumentedClient = new MCPTestClient(["--instrument"]);
      try {
        await instrumentedClient.request("tools/list");
        await instrumentedClient.request("tools/call", {
          name: "weave_status",
          arguments: {},
        });
        await instrumentedClient.request("tools/call", {
          name: "weave_show",
          arguments: { id: nodeId },
        });
      } finally {
        await instrumentedClient.close();
      }

      const stderr = instrumentedClient.getStderr();
      expect(stderr).toMatch(/\[weave-mcp-instrument\] payload scope=all tool=tools\/list payload_bytes=\d+ tools=\d+/);
      expect(stderr).toMatch(
        /\[weave-mcp-instrument\] payload scope=all tool=weave_status payload_bytes=\d+ is_error=false/
      );
      expect(stderr).toMatch(
        /\[weave-mcp-instrument\] payload scope=all tool=weave_show payload_bytes=\d+ is_error=false/
      );
      expect(stderr).toContain("[weave-mcp-instrument] === Payload summary (scope=all) ===");
      expect(stderr).toMatch(
        /\[weave-mcp-instrument\]\s+tools\/list: calls=1 total_bytes=\d+ avg_bytes=\d+ max_bytes=\d+/
      );
      expect(stderr).toMatch(
        /\[weave-mcp-instrument\]\s+weave_status: calls=1 total_bytes=\d+ avg_bytes=\d+ max_bytes=\d+/
      );
      expect(stderr).toContain("[weave-mcp-instrument] === Call summary (scope=all) ===");
      expect(stderr).toContain("[weave-mcp-instrument]   weave_status: 1");
      expect(stderr).toContain("[weave-mcp-instrument]   weave_show: 1");
    });

    it("persists MCP payload telemetry to JSONL when WV_MCP_CALL_LOG is set", async () => {
      const dir = mkdtempSync(join(tmpdir(), "weave-mcp-telemetry-"));
      const logPath = join(dir, "mcp-calls.jsonl");
      const loggedClient = new MCPTestClient([], { WV_MCP_CALL_LOG: logPath });
      try {
        await loggedClient.request("tools/list");
        await loggedClient.request("tools/call", {
          name: "weave_status",
          arguments: {},
        });
      } finally {
        await loggedClient.close();
      }

      try {
        const entries = readFileSync(logPath, "utf-8")
          .trim()
          .split("\n")
          .map((line) => JSON.parse(line) as Record<string, unknown>);

        expect(entries).toHaveLength(2);
        expect(entries[0]).toMatchObject({
          source: "mcp",
          scope: "all",
          tool: "tools/list",
        });
        expect(entries[0].payload_bytes).toEqual(expect.any(Number));
        expect(entries[0].elapsed_ms).toEqual(expect.any(Number));
        expect(entries[0].tools).toEqual(expect.any(Number));
        expect(entries[1]).toMatchObject({
          source: "mcp",
          scope: "all",
          tool: "weave_status",
          is_error: false,
        });
        expect(entries[1].payload_bytes).toEqual(expect.any(Number));
        expect(entries[1].elapsed_ms).toEqual(expect.any(Number));
      } finally {
        rmSync(dir, { recursive: true, force: true });
      }
    });
  });
});

// --- Scope filtering tests ---
describe("Weave MCP Server --scope=graph", () => {
  let client: MCPTestClient;

  beforeAll(() => {
    client = new MCPTestClient(["--scope=graph"]);
  });

  afterAll(async () => {
    await client.close();
  });

  it("should only expose graph tools", async () => {
    const response = await client.request("tools/list");
    expect(response.error).toBeUndefined();
    const tools = (response.result as { tools: { name: string }[] }).tools;
    const toolNames = tools.map((t) => t.name);

    expect(toolNames).toEqual(
      expect.arrayContaining([
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
      ])
    );
    expect(tools).toHaveLength(CONTRACT.scopes.graph.tool_count);

    // Should NOT include inspect or session tools
    expect(toolNames).not.toContain("weave_search");
    expect(toolNames).not.toContain("weave_work");
    expect(toolNames).not.toContain("weave_overview");
    expect(toolNames).not.toContain("weave_tree");
    expect(toolNames).not.toContain("weave_breadcrumbs");
  });

  it("should reject out-of-scope tool calls", async () => {
    const response = await client.request("tools/call", {
      name: "weave_status",
      arguments: {},
    });
    const result = response.result as { isError?: boolean; content: { text: string }[] };
    expect(result.isError).toBe(true);
    expect(result.content[0].text).toContain('not available in scope "graph"');
  });
});

describe("Weave MCP Server --scope=session", () => {
  let client: MCPTestClient;

  beforeAll(() => {
    client = new MCPTestClient(["--scope=session"]);
  });

  afterAll(async () => {
    await client.close();
  });

  it("should only expose session tools", async () => {
    const response = await client.request("tools/list");
    expect(response.error).toBeUndefined();
    const tools = (response.result as { tools: { name: string }[] }).tools;
    const toolNames = tools.map((t) => t.name);

    expect(toolNames).toEqual(
      expect.arrayContaining([
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
      ])
    );
    expect(tools).toHaveLength(CONTRACT.scopes.session.tool_count);
  });
});

describe("Weave MCP Server --scope=inspect", () => {
  let client: MCPTestClient;

  beforeAll(() => {
    client = new MCPTestClient(["--scope=inspect"]);
  });

  afterAll(async () => {
    await client.close();
  });

  it("should only expose inspect tools", async () => {
    const response = await client.request("tools/list");
    expect(response.error).toBeUndefined();
    const tools = (response.result as { tools: { name: string }[] }).tools;
    const toolNames = tools.map((t) => t.name);

    expect(toolNames).toEqual(
      expect.arrayContaining([
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
      ])
    );
    expect(tools).toHaveLength(CONTRACT.scopes.inspect.tool_count);
  });
});

describe("Weave MCP Server telemetry source tagging", () => {
  // Regression: the server inherits the session's WV_CALL_SOURCE=agent; without
  // the wvEnv override every internal wv subprocess (e.g. weave_edit_guard's
  // `wv list` per edit) is logged as a direct agent call, inflating
  // per-command rows in `wv analyze sessions --source=agent`.
  it("tags internal wv subprocesses as source=mcp even when the session env says agent", async () => {
    const logPath = join(tmpdir(), `wv-mcp-srctag-${process.pid}-${Date.now()}.jsonl`);
    // Fresh WV_CONFIG_DIR: config.env is sourced with set -a and would
    // override the ambient WV_CALL_LOG with the user's real log path.
    const cfgDir = mkdtempSync(join(tmpdir(), "wv-srctag-cfg-"));
    const tagged = new MCPTestClient([], {
      WV_CALL_LOG: logPath,
      WV_CALL_SOURCE: "agent",
      WV_CONFIG_DIR: cfgDir,
    });
    try {
      const resp = await tagged.request("tools/call", {
        name: "weave_status",
        arguments: {},
      });
      expect(resp.error).toBeUndefined();
      const entries = readFileSync(logPath, "utf-8")
        .trim()
        .split("\n")
        .filter((l) => l.trim() !== "")
        .map((l) => JSON.parse(l) as { source?: string; cmd?: string });
      expect(entries.length).toBeGreaterThan(0);
      for (const entry of entries) {
        expect(entry.source).toBe("mcp");
      }
    } finally {
      await tagged.close();
      rmSync(logPath, { force: true });
      rmSync(cfgDir, { recursive: true, force: true });
    }
  }, 60_000);
});
