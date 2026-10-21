import { timingSafeEqual, createHash } from "node:crypto";
import type { FastifyReply, FastifyRequest } from "fastify";
import type { ZodError } from "zod";

/** Error body every endpoint uses: `{ error: <machine code>, message: <human text> }`. */
export class ApiError extends Error {
  constructor(
    readonly statusCode: number,
    readonly code: string,
    message: string,
    readonly headers: Record<string, string> = {},
  ) {
    super(message);
  }
}

export function sendError(reply: FastifyReply, err: ApiError): FastifyReply {
  for (const [k, v] of Object.entries(err.headers)) reply.header(k, v);
  return reply.code(err.statusCode).send({ error: err.code, message: err.message });
}

export function validationError(e: ZodError): ApiError {
  const first = e.issues[0];
  const where = first?.path.length ? first.path.join(".") + ": " : "";
  return new ApiError(400, "invalid_request", where + (first?.message ?? "invalid request"));
}

export function tooMany(retryAfterSec: number, message = "Too many requests, try again later"): ApiError {
  return new ApiError(429, "rate_limited", message, { "retry-after": String(retryAfterSec) });
}

/** Constant-time string comparison (hashes first so lengths do not leak). */
export function safeEqual(a: string, b: string): boolean {
  const ha = createHash("sha256").update(a).digest();
  const hb = createHash("sha256").update(b).digest();
  return timingSafeEqual(ha, hb) && a.length === b.length;
}

export function isAdmin(req: FastifyRequest, adminToken: string): boolean {
  if (!adminToken) return false;
  const h = req.headers.authorization;
  if (!h || !h.toLowerCase().startsWith("bearer ")) return false;
  return safeEqual(h.slice(7).trim(), adminToken);
}

export function hasGameKey(req: FastifyRequest, gameKey: string): boolean {
  if (!gameKey) return false;
  const h = req.headers["x-game-key"];
  return typeof h === "string" && safeEqual(h, gameKey);
}
