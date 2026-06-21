/**
 * Integration tests for Weave MCP Server
 *
 * Tests the MCP server by spawning it and sending JSON-RPC requests over stdio.
 */

import { spawn, spawnSync, ChildProcess } from "child_process";
import { chmodSync, existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "fs";
import { tmpdir } from "os";
import { join, resolve } from "path";
import { afterAll, beforeAll, describe, expect, it } from "vitest";

const SERVER_PATH = resolve(__dirname, "../dist/index.js");
const REQUEST_TIMEOUT_MS = 30_000;

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

describe("Weave MCP Server", () => {
  let client: MCPTestClient;
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
    client = new MCPTestClient();
  });

  afterAll(async () => {
    await client.close();
    for (const id of [...createdNodeIds].reverse()) {
      deleteNodeDirect(id);
    }
  }, 60_000);

  describe("tools/list", () => {
    it("should list all 45 tools (default scope=all)", async () => {
      const response = await client.request("tools/list");
      expect(response.error).toBeUndefined();

      const tools = (response.result as { tools: { name: string }[] }).tools;
      expect(tools).toHaveLength(45);

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
    expect(tools).toHaveLength(13);

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
    expect(tools).toHaveLength(12);
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
    expect(tools).toHaveLength(22);
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
