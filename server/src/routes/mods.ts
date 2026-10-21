import fs from "node:fs";
import path from "node:path";
import { createHash, randomUUID } from "node:crypto";
import { pipeline } from "node:stream/promises";
import { Transform } from "node:stream";
import type { FastifyInstance } from "fastify";
import { z } from "zod";
import type { AppContext } from "../context.js";
import { ApiError, tooMany, validationError } from "../http.js";
import { MOD_STATUSES, publicMod } from "../db.js";

/** Local file header (PK\3\4) or an empty archive's end record (PK\5\6). */
function looksLikeZip(head: Buffer): boolean {
  return head.length >= 4 && head[0] === 0x50 && head[1] === 0x4b &&
    ((head[2] === 0x03 && head[3] === 0x04) || (head[2] === 0x05 && head[3] === 0x06));
}

function parseId(raw: string): number {
  const id = Number(raw);
  if (!Number.isInteger(id) || id <= 0) throw new ApiError(404, "not_found", "mod not found");
  return id;
}

export function modRoutes(app: FastifyInstance, ctx: AppContext): void {
  const { cfg, repo } = ctx;

  const fields = z.object({
    name: z.string().trim().min(1).max(80),
    author: z.string().trim().min(1).max(60),
    description: z.string().trim().max(2000).default(""),
    version: z.string().trim().min(1).max(32),
    game_version: z.string().trim().min(1).max(32),
    session_id: z.uuid(),
  });

  app.post("/api/mods", async (req, reply) => {
    if (!req.isMultipart()) throw new ApiError(415, "unsupported_media_type", "send multipart/form-data with a zip file");

    const wait = ctx.limiters.modUploadIp.peek(req.ip);
    if (wait > 0) throw tooMany(wait);

    const values: Record<string, string> = {};
    let tmpFile: string | null = null;
    let sha256 = "";
    let size = 0;
    let head = Buffer.alloc(0);

    try {
      for await (const part of req.parts({ limits: { fileSize: cfg.modMaxBytes, files: 1, fields: 10, fieldSize: 4096 } })) {
        if (part.type === "field") {
          values[part.fieldname] = String(part.value);
          continue;
        }
        if (tmpFile) { part.file.resume(); continue; }
        if (!/\.zip$/i.test(part.filename ?? "")) {
          part.file.resume();
          throw new ApiError(415, "not_a_zip", "the mod must be a .zip file");
        }
        tmpFile = path.join(ctx.dirs.tmp, `${randomUUID()}.zip`);
        const hash = createHash("sha256");
        const meter = new Transform({
          transform(chunk: Buffer, _enc, cb) {
            hash.update(chunk);
            size += chunk.length;
            if (head.length < 4) head = Buffer.concat([head, chunk.subarray(0, 4)]);
            cb(null, chunk);
          },
        });
        await pipeline(part.file, meter, fs.createWriteStream(tmpFile));
        if (part.file.truncated) throw new ApiError(413, "file_too_large", `the mod is larger than ${cfg.modMaxBytes} bytes`);
        sha256 = hash.digest("hex");
      }

      if (!tmpFile) throw new ApiError(400, "invalid_request", "missing file part (field name: file)");
      if (!looksLikeZip(head)) throw new ApiError(415, "not_a_zip", "the file is not a zip archive");

      const parsed = fields.safeParse(values);
      if (!parsed.success) throw validationError(parsed.error);
      const f = parsed.data;

      const waitAgain = ctx.limiters.modUploadIp.take(req.ip);
      if (waitAgain > 0) throw tooMany(waitAgain);

      repo.touchSession(f.session_id, req.ip);
      const id = repo.insertMod({
        name: f.name,
        author: f.author,
        description: f.description,
        version: f.version,
        gameVersion: f.game_version,
        sessionId: f.session_id,
        file: "pending",
        sizeBytes: size,
        sha256,
        ip: req.ip,
      });
      const file = `mod-${id}.zip`;
      fs.renameSync(tmpFile, path.join(ctx.dirs.mods, file));
      tmpFile = null;
      repo.db.prepare(`UPDATE mods SET file = ? WHERE id = ?`).run(file, id);
      return reply.code(201).send({ id, status: "pending", sha256 });
    } catch (e) {
      const err = e as { code?: string };
      if (err.code === "FST_REQ_FILE_TOO_LARGE") throw new ApiError(413, "file_too_large", `the mod is larger than ${cfg.modMaxBytes} bytes`);
      if (err.code === "FST_FILES_LIMIT") throw new ApiError(400, "invalid_request", "send exactly one file");
      throw e;
    } finally {
      if (tmpFile) fs.rm(tmpFile, { force: true }, () => {});
    }
  });

  const listQuery = z.object({ limit: z.coerce.number().int().min(1).max(500).default(100) });

  app.get("/api/mods", async (req) => {
    const q = listQuery.safeParse(req.query);
    if (!q.success) throw validationError(q.error);
    return { items: repo.listMods({ status: "published", limit: q.data.limit }).map(publicMod) };
  });

  app.get<{ Params: { id: string } }>("/api/mods/:id", async (req) => {
    const m = repo.getMod(parseId(req.params.id));
    if (!m || m.status !== "published") throw new ApiError(404, "not_found", "mod not found");
    return publicMod(m);
  });

  app.get<{ Params: { id: string } }>("/api/mods/:id/download", async (req, reply) => {
    const m = repo.getMod(parseId(req.params.id));
    if (!m || m.status !== "published") throw new ApiError(404, "not_found", "mod not found");
    repo.countModDownload(m.id);
    const safeName = `${m.name}-${m.version}`.replace(/[^A-Za-z0-9._-]+/g, "_").slice(0, 100) + ".zip";
    return reply
      .type("application/zip")
      .header("content-disposition", `attachment; filename="${safeName}"`)
      .header("content-length", String(m.size_bytes))
      .header("x-sha256", m.sha256)
      .send(fs.createReadStream(path.join(ctx.dirs.mods, m.file)));
  });

  // ---- admin (Bearer ADMIN_TOKEN) ------------------------------------------------------------

  const adminList = z.object({
    status: z.enum(MOD_STATUSES).optional(),
    limit: z.coerce.number().int().min(1).max(500).default(100),
  });
  app.get("/api/admin/mods", async (req) => {
    const q = adminList.safeParse(req.query);
    if (!q.success) throw validationError(q.error);
    return { items: repo.listMods(q.data) };
  });

  const patchBody = z.object({ status: z.enum(MOD_STATUSES) });
  app.patch<{ Params: { id: string } }>("/api/admin/mods/:id", async (req) => {
    const p = patchBody.safeParse(req.body);
    if (!p.success) throw validationError(p.error);
    const id = parseId(req.params.id);
    if (!repo.setModStatus(id, p.data.status)) throw new ApiError(404, "not_found", "mod not found");
    return repo.getMod(id);
  });
}
