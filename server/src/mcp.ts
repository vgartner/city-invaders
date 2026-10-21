import fs from "node:fs";
import path from "node:path";
import type { FastifyInstance } from "fastify";
import { z } from "zod";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/streamableHttp.js";
import type { CallToolResult } from "@modelcontextprotocol/sdk/types.js";
import type { AppContext } from "./context.js";
import { FEEDBACK_KINDS, FEEDBACK_STATUSES, MOD_STATUSES } from "./db.js";

const json = (value: unknown): CallToolResult => ({
  content: [{ type: "text", text: JSON.stringify(value, null, 2) }],
});
const notFound = (what: string): CallToolResult => ({
  content: [{ type: "text", text: `${what} not found` }],
  isError: true,
});

/** Builds an MCP server exposing the admin tools. A fresh one serves each HTTP request (stateless mode). */
export function buildMcpServer(ctx: AppContext): McpServer {
  const { repo } = ctx;
  const server = new McpServer(
    { name: "city-invaders-api", version: "0.1.0" },
    {
      instructions:
        "Admin tools for the City Invaders backend: player feedback reports (bugs/ideas, with screenshots), " +
        "shared mods (approve by setting status 'published'), Bah assistant conversations and usage stats.",
    },
  );

  server.registerTool(
    "list_feedback",
    {
      description: "List feedback reports from players, newest first.",
      inputSchema: {
        status: z.enum(FEEDBACK_STATUSES).optional().describe("Filter by status"),
        kind: z.enum(FEEDBACK_KINDS).optional().describe("Filter by kind"),
        limit: z.number().int().min(1).max(500).default(50),
      },
      annotations: { readOnlyHint: true },
    },
    async ({ status, kind, limit }) =>
      json(
        repo.listFeedback({ status, kind, limit }).map((f) => ({
          id: f.id, kind: f.kind, status: f.status, map: f.map, game_version: f.game_version, os: f.os,
          has_screenshot: !!f.screenshot_file, created_at: f.created_at, text: f.text.slice(0, 300),
        })),
      ),
  );

  server.registerTool(
    "get_feedback",
    {
      description: "Get one feedback report with its notes history; the screenshot (if any) is attached as an image.",
      inputSchema: { id: z.number().int().positive() },
      annotations: { readOnlyHint: true },
    },
    async ({ id }) => {
      const f = repo.getFeedback(id);
      if (!f) return notFound(`feedback ${id}`);
      const { ip: _ip, ...rest } = f;
      const result = json({ ...rest, position: f.position_json ? JSON.parse(f.position_json) : null });
      if (f.screenshot_file) {
        try {
          const data = fs.readFileSync(path.join(ctx.dirs.screenshots, f.screenshot_file)).toString("base64");
          result.content.push({ type: "image", data, mimeType: "image/png" });
        } catch {
          result.content.push({ type: "text", text: "(screenshot file is missing on disk)" });
        }
      }
      return result;
    },
  );

  server.registerTool(
    "update_feedback",
    {
      description: "Set a feedback report's status (new, triaged, done, wontfix) and append a note.",
      inputSchema: {
        id: z.number().int().positive(),
        status: z.enum(FEEDBACK_STATUSES),
        note: z.string().max(4000).optional(),
      },
    },
    async ({ id, status, note }) => {
      if (!repo.updateFeedback(id, status, note ?? null)) return notFound(`feedback ${id}`);
      const { ip: _ip, ...f } = repo.getFeedback(id)!;
      return json(f);
    },
  );

  server.registerTool(
    "list_mods",
    {
      description: "List uploaded mods (all statuses unless filtered). New uploads are 'pending'.",
      inputSchema: {
        status: z.enum(MOD_STATUSES).optional(),
        limit: z.number().int().min(1).max(500).default(100),
      },
      annotations: { readOnlyHint: true },
    },
    async ({ status, limit }) => json(repo.listMods({ status, limit }).map(({ ip: _ip, ...m }) => m)),
  );

  server.registerTool(
    "get_mod",
    {
      description: "Get one mod's metadata (including the stored file name and sha256).",
      inputSchema: { id: z.number().int().positive() },
      annotations: { readOnlyHint: true },
    },
    async ({ id }) => {
      const m = repo.getMod(id);
      if (!m) return notFound(`mod ${id}`);
      const { ip: _ip, ...rest } = m;
      return json(rest);
    },
  );

  server.registerTool(
    "set_mod_status",
    {
      description: "Approve ('published'), reject ('rejected') or unpublish ('pending') a mod. Only published mods are listed to players.",
      inputSchema: { id: z.number().int().positive(), status: z.enum(MOD_STATUSES) },
    },
    async ({ id, status }) => {
      if (!repo.setModStatus(id, status)) return notFound(`mod ${id}`);
      const { ip: _ip, ...m } = repo.getMod(id)!;
      return json(m);
    },
  );

  server.registerTool(
    "list_conversations",
    {
      description: "List Bah conversations, most recently active first.",
      inputSchema: {
        limit: z.number().int().min(1).max(500).default(50),
        since: z.string().optional().describe("ISO date/time; only conversations active since then"),
      },
      annotations: { readOnlyHint: true },
    },
    async ({ limit, since }) => {
      let sinceIso: string | undefined;
      if (since) {
        const d = new Date(since);
        if (Number.isNaN(d.getTime())) return { content: [{ type: "text", text: "since is not a valid date" }], isError: true };
        sinceIso = d.toISOString();
      }
      return json(repo.listConversations(limit, sinceIso));
    },
  );

  server.registerTool(
    "get_conversation",
    {
      description: "Get a Bah conversation with every message, game context and token usage.",
      inputSchema: { id: z.string().describe("conversation_id (uuid)") },
      annotations: { readOnlyHint: true },
    },
    async ({ id }) => {
      const c = repo.getConversation(id);
      if (!c) return notFound(`conversation ${id}`);
      const messages = repo.allMessages(id).map(({ ip: _ip, conversation_id: _c, ...m }) => ({
        ...m,
        context: m.context_json ? JSON.parse(m.context_json) : undefined,
        context_json: undefined,
      }));
      return json({ ...c, messages });
    },
  );

  server.registerTool(
    "stats",
    {
      description: "Counts (sessions, conversations, messages, feedback, mods) and Bah tokens used today (UTC) against the daily budget.",
      inputSchema: {},
      annotations: { readOnlyHint: true },
    },
    async () => json({ ...repo.stats(), daily_token_budget: ctx.cfg.bahDailyTokenBudget, model: ctx.cfg.bahModel }),
  );

  return server;
}

/** Mounts the Streamable HTTP endpoint at /mcp (POST for JSON-RPC; GET/DELETE answer 405 in stateless mode). */
export function mcpRoutes(app: FastifyInstance, ctx: AppContext): void {
  const handler = async (req: import("fastify").FastifyRequest, reply: import("fastify").FastifyReply) => {
    const server = buildMcpServer(ctx);
    const transport = new StreamableHTTPServerTransport({ sessionIdGenerator: undefined, enableJsonResponse: true });
    reply.raw.on("close", () => {
      void transport.close();
      void server.close();
    });
    await server.connect(transport);
    reply.hijack();
    await transport.handleRequest(req.raw, reply.raw, req.body);
  };
  app.post("/mcp", { bodyLimit: 1024 * 1024 }, handler);
  app.get("/mcp", handler);
  app.delete("/mcp", handler);
}
