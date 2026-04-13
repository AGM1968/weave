/**
 * Integration tests for Weave MCP Server
 *
 * Tests the MCP server by spawning it and sending JSON-RPC requests over stdio.
 */

import { spawn, spawnSync, ChildProcess } from "child_process";
import { chmodSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "fs";
import { tmpdir } from "os";
import { join, resolve } from "path";

const SERVER_PATH = resolve(__dirname, "../dist/index.js");
const REQUEST_TIMEOUT_MS = 15_000;

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

  constructor(extraArgs: string[] = [], extraEnv: NodeJS.ProcessEnv = {}) {
    this.server = spawn("node", [SERVER_PATH, ...extraArgs], {
      stdio: ["pipe", "pipe", "pipe"],
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

describe("Weave MCP Server", () => {
  let client: MCPTestClient;
  const createdNodeIds: string[] = [];

  async function createTrackedNode(text: string, metadata?: Record<string, unknown>): Promise<string> {
    const addResponse = await client.request("tools/call", {
      name: "weave_add",
      arguments: { text },
    });
    const addResult = addResponse.result as { content: { text: string }[] };
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
  });

  describe("tools/list", () => {
    it("should list all 31 tools (default scope=all)", async () => {
      const response = await client.request("tools/list");
      expect(response.error).toBeUndefined();

      const tools = (response.result as { tools: { name: string }[] }).tools;
      expect(tools).toHaveLength(31);

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
      expect(toolNames).toContain("weave_preflight");
      expect(toolNames).toContain("weave_sync");
      expect(toolNames).toContain("weave_resolve");
      expect(toolNames).toContain("weave_close_session");
      expect(toolNames).toContain("weave_tree");
      expect(toolNames).toContain("weave_learnings");
      expect(toolNames).toContain("weave_update");
      expect(toolNames).toContain("weave_breadcrumbs");
      expect(toolNames).toContain("weave_plan");
      expect(toolNames).toContain("weave_show");
      expect(toolNames).toContain("weave_delete");
      expect(toolNames).toContain("weave_quality_scan");
      expect(toolNames).toContain("weave_quality_hotspots");
      expect(toolNames).toContain("weave_quality_diff");
      expect(toolNames).toContain("weave_quality_functions");
    });

    it("should advertise phased read defaults and schema compatibility", async () => {
      const response = await client.request("tools/list");
      expect(response.error).toBeUndefined();

      const tools = (response.result as {
        tools: Array<{
          name: string;
          description: string;
          inputSchema: { properties?: Record<string, { enum?: string[] }> };
        }>;
      }).tools;
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

    it("weave_breadcrumbs show should return content", async () => {
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

    it("weave_add with backtick injection should not execute", async () => {
      const response = await client.request("tools/call", {
        name: "weave_add",
        arguments: { text: "`cat /etc/passwd`" },
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
      expect(commands).toEqual(expect.arrayContaining([
        expect.stringContaining(`show ${nodeId} --json-v2`),
        expect.stringContaining("list --json-v2"),
      ]));
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
      expect(commands).toEqual(expect.arrayContaining([
        expect.stringContaining("status --mode=discover"),
        expect.stringContaining(`context ${nodeId} --json --mode=discover`),
        expect.stringContaining("ready --mode=discover"),
      ]));
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
          arguments: { text: "status alias add", status: "in_progress" },
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

      expect(commands).toEqual(expect.arrayContaining([
        expect.stringContaining("add status alias add --status=active"),
        expect.stringContaining("status --mode=full"),
        expect.stringContaining(`context ${nodeId} --json --mode=bootstrap`),
        expect.stringContaining("ready --mode=full"),
        expect.stringContaining("learnings --json --mode=bootstrap"),
        expect.stringContaining("list --json-v2 --status=active"),
        expect.stringContaining("search sync --json --status=active"),
        expect.stringContaining(`update ${nodeId} --status=active`),
      ]));
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
      expect(stderr).toMatch(/\[weave-mcp-instrument\] payload scope=all tool=weave_status payload_bytes=\d+ is_error=false/);
      expect(stderr).toMatch(/\[weave-mcp-instrument\] payload scope=all tool=weave_show payload_bytes=\d+ is_error=false/);
      expect(stderr).toContain("[weave-mcp-instrument] === Payload summary (scope=all) ===");
      expect(stderr).toMatch(/\[weave-mcp-instrument\]\s+tools\/list: calls=1 total_bytes=\d+ avg_bytes=\d+ max_bytes=\d+/);
      expect(stderr).toMatch(/\[weave-mcp-instrument\]\s+weave_status: calls=1 total_bytes=\d+ avg_bytes=\d+ max_bytes=\d+/);
      expect(stderr).toContain("[weave-mcp-instrument] === Call summary (scope=all) ===");
      expect(stderr).toContain("[weave-mcp-instrument]   weave_status: 1");
      expect(stderr).toContain("[weave-mcp-instrument]   weave_show: 1");
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
        "weave_done",
        "weave_batch_done",
        "weave_list",
        "weave_resolve",
        "weave_update",
        "weave_delete",
      ])
    );
    expect(tools).toHaveLength(8);

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
        "weave_ship",
        "weave_recover",
        "weave_quick",
        "weave_overview",
        "weave_close_session",
        "weave_breadcrumbs",
        "weave_plan",
        "weave_edit_guard",
      ])
    );
    expect(tools).toHaveLength(9);
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
        "weave_status",
        "weave_health",
        "weave_preflight",
        "weave_sync",
        "weave_tree",
        "weave_learnings",
        "weave_guide",
        "weave_show",
        "weave_quality_scan",
        "weave_quality_hotspots",
        "weave_quality_diff",
        "weave_quality_functions",
      ])
    );
    expect(tools).toHaveLength(14);
  });
});
