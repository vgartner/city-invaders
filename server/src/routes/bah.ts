import type { FastifyInstance } from "fastify";
import { z } from "zod";
import type { AppContext } from "../context.js";
import { ApiError, tooMany, validationError } from "../http.js";
import { LlmUnavailableError, wrapUserMessage, type ChatTurn } from "../bah.js";
import { utcDayStart } from "../db.js";

/** A conversation continues automatically when the session spoke to Bah within this window. */
const CONVERSATION_IDLE_MS = 6 * 60 * 60 * 1000;
const CONTEXT_MAX_JSON = 2000;

export function bahRoutes(app: FastifyInstance, ctx: AppContext): void {
  const { cfg, repo } = ctx;

  const body = z.object({
    session_id: z.uuid(),
    message: z.string().trim().min(1, "message is empty").max(cfg.bahMessageMaxChars, `message is longer than ${cfg.bahMessageMaxChars} characters`),
    lang: z.string().trim().regex(/^[A-Za-z]{2,3}([-_][A-Za-z0-9]{2,8})*$/, "lang must be a language tag like pt-BR").optional(),
    conversation_id: z.uuid().optional(),
    context: z
      .record(z.string().max(40), z.unknown())
      .refine((c) => JSON.stringify(c).length <= CONTEXT_MAX_JSON, `context is larger than ${CONTEXT_MAX_JSON} bytes of JSON`)
      .optional(),
  });

  app.post("/api/bah/chat", { bodyLimit: 16 * 1024 }, async (req, reply) => {
    const parsed = body.safeParse(req.body);
    if (!parsed.success) throw validationError(parsed.error);
    const b = parsed.data;
    const ip = req.ip;

    // Check both limits first, then record, so a rejected request does not consume the other one.
    const waitS = Math.max(ctx.limiters.chatSession.peek(b.session_id), ctx.limiters.chatIp.peek(ip));
    if (waitS > 0) throw tooMany(waitS, "Bah needs a break: too many messages, try again in a few minutes");

    if (!ctx.llm) throw new ApiError(503, "bah_unavailable", "Bah is not configured on this server");

    if (cfg.bahDailyTokenBudget > 0 && repo.tokensSince(utcDayStart()).budget >= cfg.bahDailyTokenBudget) {
      throw new ApiError(503, "daily_budget_exhausted", "Bah is resting for today, come back tomorrow", { "retry-after": "3600" });
    }
    ctx.limiters.chatSession.take(b.session_id);
    ctx.limiters.chatIp.take(ip);

    repo.touchSession(b.session_id, ip);

    let conv = b.conversation_id ? repo.getConversation(b.conversation_id) : undefined;
    if (conv && conv.session_id !== b.session_id) conv = undefined; // never continue someone else's chat
    if (!conv && !b.conversation_id) {
      conv = repo.latestConversation(b.session_id, new Date(Date.now() - CONVERSATION_IDLE_MS).toISOString());
    }
    if (!conv) conv = repo.createConversation(b.session_id, b.lang ?? null);

    const history: ChatTurn[] = repo
      .recentMessages(conv.id, cfg.bahHistoryTurns * 2)
      .map((m) => ({ role: m.role, content: m.content }));
    while (history.length && history[0]?.role !== "user") history.shift();

    const messages: ChatTurn[] = [...history, { role: "user", content: wrapUserMessage(b.message, b.context, b.lang) }];

    let result;
    try {
      result = await ctx.llm.complete({ system: ctx.systemPrompt, messages });
    } catch (e) {
      req.log.error({ err: e }, "bah llm call failed");
      if (e instanceof LlmUnavailableError) throw new ApiError(502, "bah_upstream_error", "Bah could not answer right now, try again");
      throw e;
    }
    const reply_ = result.text || "Bah, não entendi. Pode repetir?";

    repo.addExchange({
      conversationId: conv.id,
      userText: b.message,
      contextJson: b.context || b.lang ? JSON.stringify({ ...(b.context ?? {}), ...(b.lang ? { lang: b.lang } : {}) }) : null,
      assistantText: reply_,
      usage: result.usage,
      ip,
    });

    return reply.send({ reply: reply_, conversation_id: conv.id });
  });
}
