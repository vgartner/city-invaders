import fs from "node:fs";
import path from "node:path";
import type { FastifyInstance } from "fastify";
import { z } from "zod";
import type { AppContext } from "../context.js";
import { ApiError, tooMany, validationError } from "../http.js";
import { FEEDBACK_KINDS, FEEDBACK_STATUSES } from "../db.js";

const PNG_MAGIC = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);

export function feedbackRoutes(app: FastifyInstance, ctx: AppContext): void {
  const { cfg, repo } = ctx;
  // base64 grows data by 4/3; leave room for the JSON around it.
  const bodyLimit = Math.ceil((cfg.feedbackScreenshotMaxBytes * 4) / 3) + 64 * 1024;

  const position = z.union([
    z.object({ x: z.number(), y: z.number(), z: z.number() }).catchall(z.number()),
    z.array(z.number()).min(2).max(4),
  ]);

  const body = z.object({
    session_id: z.uuid(),
    kind: z.enum(FEEDBACK_KINDS),
    text: z.string().trim().min(1, "text is empty").max(4000, "text is longer than 4000 characters"),
    map: z.string().trim().max(64).optional(),
    position: position.optional(),
    game_version: z.string().trim().min(1).max(32),
    os: z.string().trim().min(1).max(64),
    screenshot_png_base64: z.string().max(bodyLimit).optional(),
  });

  app.post("/api/feedback", { bodyLimit }, async (req, reply) => {
    const parsed = body.safeParse(req.body);
    if (!parsed.success) throw validationError(parsed.error);
    const b = parsed.data;

    let png: Buffer | null = null;
    if (b.screenshot_png_base64) {
      const raw = b.screenshot_png_base64.replace(/^data:image\/png;base64,/, "");
      if (!/^[A-Za-z0-9+/\r\n]+={0,2}\s*$/.test(raw)) throw new ApiError(400, "invalid_screenshot", "screenshot_png_base64 is not base64");
      png = Buffer.from(raw, "base64");
      if (png.length > cfg.feedbackScreenshotMaxBytes) {
        throw new ApiError(413, "screenshot_too_large", `screenshot is larger than ${cfg.feedbackScreenshotMaxBytes} bytes`);
      }
      if (png.length < PNG_MAGIC.length || !png.subarray(0, 8).equals(PNG_MAGIC)) {
        throw new ApiError(400, "invalid_screenshot", "screenshot is not a PNG");
      }
    }

    const wait = ctx.limiters.feedbackIp.take(req.ip);
    if (wait > 0) throw tooMany(wait);

    repo.touchSession(b.session_id, req.ip);
    const id = repo.insertFeedback({
      sessionId: b.session_id,
      kind: b.kind,
      text: b.text,
      map: b.map ?? null,
      positionJson: b.position ? JSON.stringify(b.position) : null,
      gameVersion: b.game_version,
      os: b.os,
      ip: req.ip,
    });
    if (png) {
      const file = `feedback-${id}.png`;
      fs.writeFileSync(path.join(ctx.dirs.screenshots, file), png);
      repo.setFeedbackScreenshot(id, file);
    }
    return reply.code(201).send({ id });
  });

  // ---- admin (Bearer ADMIN_TOKEN) ------------------------------------------------------------

  const listQuery = z.object({
    status: z.enum(FEEDBACK_STATUSES).optional(),
    kind: z.enum(FEEDBACK_KINDS).optional(),
    limit: z.coerce.number().int().min(1).max(500).default(50),
  });

  app.get("/api/admin/feedback", async (req) => {
    const q = listQuery.safeParse(req.query);
    if (!q.success) throw validationError(q.error);
    return { items: repo.listFeedback(q.data) };
  });

  app.get<{ Params: { id: string } }>("/api/admin/feedback/:id", async (req) => {
    const f = repo.getFeedback(Number(req.params.id));
    if (!f) throw new ApiError(404, "not_found", "feedback not found");
    return f;
  });

  app.get<{ Params: { id: string } }>("/api/admin/feedback/:id/screenshot", async (req, reply) => {
    const f = repo.getFeedback(Number(req.params.id));
    if (!f?.screenshot_file) throw new ApiError(404, "not_found", "no screenshot");
    return reply.type("image/png").send(fs.createReadStream(path.join(ctx.dirs.screenshots, f.screenshot_file)));
  });

  const patchBody = z.object({ status: z.enum(FEEDBACK_STATUSES), note: z.string().max(4000).optional() });
  app.patch<{ Params: { id: string } }>("/api/admin/feedback/:id", async (req) => {
    const p = patchBody.safeParse(req.body);
    if (!p.success) throw validationError(p.error);
    const id = Number(req.params.id);
    if (!repo.updateFeedback(id, p.data.status, p.data.note ?? null)) throw new ApiError(404, "not_found", "feedback not found");
    return repo.getFeedback(id);
  });
}
