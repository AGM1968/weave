/**
 * Integration tests for Weave MCP Server
 *
 * Tests the MCP server by spawning it and sending JSON-RPC requests over stdio.
 */

import { spawn, ChildProcess } from "child_process";
import { resolve } from "path";

const SERVER_PATH = resolve(__dirname, "../dist/index.js");

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
  private pending: Map<
    number,
    { resolve: (v: JsonRpcResponse) => void; reject: (e: Error) => void; timeout: NodeJS.Timeout }
  > = new Map();

  constructor(extraArgs: string[] = []) {
    this.server = spawn("node", [SERVER_PATH, ...extraArgs], {
      stdio: ["pipe", "pipe", "pipe"],
      env: {
        ...process.env,
        WV_PATH: resolve(__dirname, "../../scripts/wv"),
      },
    });

    this.server.stdout!.on("data", (data: Buffer) => {
      this.buffer += data.toString();
      this.processBuffer();
    });

    this.server.stderr!.on("data", (data: Buffer) => {
      // Server logs to stderr, ignore for tests
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
      }, 5000);

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
    this.server.kill("SIGKILL");
    await new Promise<void>((resolve) => {
      this.server.on("close", () => resolve());
      setTimeout(resolve, 1000); // Force resolve after 1s
    });
  }
}

describe("Weave MCP Server", () => {
  let client: MCPTestClient;

  beforeAll(() => {
    client = new MCPTestClient();
  });

  afterAll(async () => {
    await client.close();
  });

  describe("tools/list", () => {
    it("should list all 30 tools (default scope=all)", async () => {
      const response = await client.request("tools/list");
      expect(response.error).toBeUndefined();

      const tools = (response.result as { tools: { name: string }[] }).tools;
      expect(tools).toHaveLength(30);

      const toolNames = tools.map((t) => t.name);
      expect(toolNames).toContain("weave_search");
      expect(toolNames).toContain("weave_add");
      expect(toolNames).toContain("weave_done");
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

    it("weave_list should return node list", async () => {
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

    it("weave_tree should return JSON tree", async () => {
      const response = await client.request("tools/call", {
        name: "weave_tree",
        arguments: {},
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
      expect(result.content[0].text).not.toContain("root:");
    });

    // --- New tool tests (wv-5c5e0f) ---
    it("weave_show should return content for valid node", async () => {
      // First add a node to show
      const addResponse = await client.request("tools/call", {
        name: "weave_add",
        arguments: { text: "test-show-node" },
      });
      const addResult = addResponse.result as { content: { text: string }[] };
      const idMatch = addResult.content[0].text.match(/wv-[a-f0-9]+/);
      expect(idMatch).toBeTruthy();

      const response = await client.request("tools/call", {
        name: "weave_show",
        arguments: { id: idMatch![0] },
      });

      expect(response.error).toBeUndefined();
      const result = response.result as { content: { text: string }[] };
      expect(result.content).toBeDefined();
      const nodes = JSON.parse(result.content[0].text);
      expect(Array.isArray(nodes)).toBe(true);
      expect(nodes[0]).toHaveProperty("id");
      expect(nodes[0].id).toBe(idMatch![0]);
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
      ])
    );
    expect(tools).toHaveLength(8);
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
