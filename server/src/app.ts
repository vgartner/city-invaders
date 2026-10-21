import Fastify, { type FastifyInstance } from "fastify";
import multipart from "@fastify/multipart";
import type { Config } from "./config.js";
import { openDb, Repo } from "./db.js";
import { OpenAiCompatibleBahLlm, buildSystemPrompt, type BahLlm } from "./bah.js";
import { makeDirs, makeLimiters, type AppContext } from "./context.js";
import { ApiError, hasGameKey, isAdmin, sendError } from "./http.js";
import { bahRoutes } from "./routes/bah.js";
import { feedbackRoutes } from "./routes/feedback.js";
import { modRoutes } from "./routes/mods.js";
import { mcpRoutes } from "./mcp.js";

export interface BuildOptions {
  cfg: Config;
  /** Override the language model (tests). `undefined` = the OpenAI-compatible API when a key is set. */
  llm?: BahLlm | null;
  logger?: boolean;
}

export async function buildApp(opts: BuildOptions): Promise<{ app: FastifyInstance; ctx: AppContext }> {
  const { cfg } = opts;
  const app = Fastify({
    logger: opts.logger === false ? false : { level: cfg.logLevel, redact: ["req.headers.authorization", 'req.headers["x-game-key"]'] },
    // Trust exactly N proxy hops (nginx-proxy), so req.ip is the address nginx saw, not a spoofable header value.
    trustProxy: (_addr: string, hop: number) => hop < cfg.trustProxyHops,
    bodyLimit: 64 * 1024,
  });

  const db = openDb(cfg.dbPath);
  const llm =
    opts.llm !== undefined
      ? opts.llm
      : cfg.llmApiKey
        ? new OpenAiCompatibleBahLlm(cfg.llmBaseUrl, cfg.llmApiKey, cfg.bahModel, cfg.bahMaxOutputTokens)
        : null;
  const ctx: AppContext = {
    cfg,
    repo: new Repo(db),
    llm,
    systemPrompt: buildSystemPrompt(cfg.bahGameplayPath, cfg.bahFaqPath),
    limiters: makeLimiters(cfg),
    dirs: makeDirs(cfg.dataDir),
  };
  if (!llm) app.log.warn("LLM_API_KEY is not set: /api/bah/chat will answer 503");

  await app.register(multipart);

  app.setErrorHandler((err, req, reply) => {
    if (err instanceof ApiError) return sendError(reply, err);
    const e = err as { statusCode?: number; code?: string; message: string };
    if (e.code === "FST_ERR_CTP_BODY_TOO_LARGE") return sendError(reply, new ApiError(413, "payload_too_large", "request body is too large"));
    if (e.code === "FST_ERR_CTP_INVALID_MEDIA_TYPE") return sendError(reply, new ApiError(415, "unsupported_media_type", e.message));
    if (e.statusCode && e.statusCode >= 400 && e.statusCode < 500) {
      return sendError(reply, new ApiError(e.statusCode, "invalid_request", e.message));
    }
    req.log.error({ err }, "unhandled error");
    return sendError(reply, new ApiError(500, "internal_error", "internal error"));
  });

  app.setNotFoundHandler((_req, reply) => sendError(reply, new ApiError(404, "not_found", "route not found")));

  // Auth: /api/admin/* and /mcp need the admin bearer token; the rest of /api/* needs the game key
  // (the admin token is accepted there too, for testing with curl).
  app.addHook("onRequest", async (req, reply) => {
    const url = req.url.split("?")[0] ?? "";
    if (url.startsWith("/api/admin/") || url === "/mcp" || url.startsWith("/mcp/")) {
      if (!isAdmin(req, cfg.adminToken)) {
        reply.header("www-authenticate", 'Bearer realm="city-invaders-api"');
        return sendError(reply, new ApiError(401, "unauthorized", "admin bearer token required"));
      }
    } else if (url.startsWith("/api/")) {
      if (!hasGameKey(req, cfg.gameClientKey) && !isAdmin(req, cfg.adminToken)) {
        return sendError(reply, new ApiError(401, "unauthorized", "missing or wrong X-Game-Key"));
      }
    }
  });

  // the bare host (and vgdata-status's check) gets a short hello, not a 404
  app.get("/", async () => ({ name: "City Invaders API", ok: true }));

  app.get("/healthz", async () => {
    ctx.repo.db.prepare("SELECT 1").get();
    return { ok: true, bah: !!ctx.llm };
  });

  bahRoutes(app, ctx);
  feedbackRoutes(app, ctx);
  modRoutes(app, ctx);
  mcpRoutes(app, ctx);

  app.addHook("onClose", async () => {
    db.close();
  });

  return { app, ctx };
}
