import { test, describe, before, after } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { createHash } from "node:crypto";
import type { FastifyInstance } from "fastify";
import { buildApp } from "../src/app.js";
import { loadConfig } from "../src/config.js";
import type { BahLlm, ChatTurn } from "../src/bah.js";

const GAME_KEY = "test-game-key";
const ADMIN = "test-admin-token-0123456789abcdef";
const SESSION = "3f1c2d4e-5a6b-4c7d-8e9f-0a1b2c3d4e5f";
const game = { "x-game-key": GAME_KEY };
const admin = { authorization: `Bearer ${ADMIN}` };

/** Fake model: echoes how many turns it got, records the last call. */
class FakeLlm implements BahLlm {
  calls: { system: string; messages: ChatTurn[] }[] = [];
  async complete(args: { system: string; messages: ChatTurn[] }) {
    this.calls.push(args);
    return {
      text: `Bah! turno ${args.messages.length}`,
      usage: { model: "fake", inputTokens: 100, outputTokens: 20, cacheReadTokens: 0, cacheWriteTokens: 0 },
    };
  }
}

// Smallest valid PNG (1x1) and a tiny "zip" (end-of-central-directory record only).
const PNG_1x1 = Buffer.from(
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==",
  "base64",
);
const EMPTY_ZIP = Buffer.concat([Buffer.from([0x50, 0x4b, 0x05, 0x06]), Buffer.alloc(18)]);

function multipart(fields: Record<string, string>, file?: { name: string; data: Buffer }) {
  const boundary = "----cityinvaderstest";
  const chunks: Buffer[] = [];
  for (const [k, v] of Object.entries(fields)) {
    chunks.push(Buffer.from(`--${boundary}\r\nContent-Disposition: form-data; name="${k}"\r\n\r\n${v}\r\n`));
  }
  if (file) {
    chunks.push(Buffer.from(`--${boundary}\r\nContent-Disposition: form-data; name="file"; filename="${file.name}"\r\nContent-Type: application/zip\r\n\r\n`));
    chunks.push(file.data, Buffer.from("\r\n"));
  }
  chunks.push(Buffer.from(`--${boundary}--\r\n`));
  return { payload: Buffer.concat(chunks), headers: { "content-type": `multipart/form-data; boundary=${boundary}` } };
}

describe("city-invaders-api", () => {
  let app: FastifyInstance;
  let llm: FakeLlm;
  let dataDir: string;

  before(async () => {
    dataDir = fs.mkdtempSync(path.join(os.tmpdir(), "ci-api-"));
    const cfg = loadConfig({
      DATA_DIR: dataDir,
      GAME_CLIENT_KEY: GAME_KEY,
      ADMIN_TOKEN: ADMIN,
      BAH_GAMEPLAY_PATH: path.resolve("knowledge/GAMEPLAY.md"),
      BAH_FAQ_PATH: path.resolve("knowledge/bah_faq.json"),
      CHAT_LIMIT_PER_SESSION: "3",
      CHAT_LIMIT_PER_IP: "100",
    });
    llm = new FakeLlm();
    ({ app } = await buildApp({ cfg, llm, logger: false }));
  });

  after(async () => {
    await app.close();
    fs.rmSync(dataDir, { recursive: true, force: true });
  });

  test("healthz is public", async () => {
    const r = await app.inject({ method: "GET", url: "/healthz" });
    assert.equal(r.statusCode, 200);
    assert.equal(r.json().ok, true);
  });

  test("game routes need X-Game-Key", async () => {
    const r = await app.inject({ method: "GET", url: "/api/mods" });
    assert.equal(r.statusCode, 401);
    assert.equal(r.json().error, "unauthorized");
  });

  test("bah chat: replies, keeps history, builds prompt from the docs", async () => {
    const r1 = await app.inject({
      method: "POST", url: "/api/bah/chat", headers: game,
      payload: { session_id: SESSION, message: "Como acho as torres?", lang: "pt-BR", context: { map: "gasometro", health: 40 } },
    });
    assert.equal(r1.statusCode, 200, r1.body);
    const b1 = r1.json();
    assert.equal(b1.reply, "Bah! turno 1");
    assert.match(b1.conversation_id, /^[0-9a-f-]{36}$/);

    const call = llm.calls.at(-1)!;
    assert.match(call.system, /City Invaders/);
    assert.match(call.system, /Coletor/); // from bah_faq.json
    assert.match(call.system, /relay antenna/); // from GAMEPLAY.md
    assert.match(call.messages[0]!.content, /<game_state>.*"map":"gasometro".*<\/game_state>/);

    const r2 = await app.inject({
      method: "POST", url: "/api/bah/chat", headers: game,
      payload: { session_id: SESSION, message: "E o enxame?" },
    });
    assert.equal(r2.json().conversation_id, b1.conversation_id);
    assert.equal(r2.json().reply, "Bah! turno 3"); // user, assistant, user
  });

  test("bah chat: validation and per-session rate limit", async () => {
    const long = await app.inject({
      method: "POST", url: "/api/bah/chat", headers: game,
      payload: { session_id: SESSION, message: "x".repeat(501) },
    });
    assert.equal(long.statusCode, 400);
    assert.equal(long.json().error, "invalid_request");

    const badId = await app.inject({ method: "POST", url: "/api/bah/chat", headers: game, payload: { session_id: "nope", message: "oi" } });
    assert.equal(badId.statusCode, 400);

    // limit is 3 per session; two were used above
    const ok = await app.inject({ method: "POST", url: "/api/bah/chat", headers: game, payload: { session_id: SESSION, message: "oi" } });
    assert.equal(ok.statusCode, 200);
    const limited = await app.inject({ method: "POST", url: "/api/bah/chat", headers: game, payload: { session_id: SESSION, message: "oi" } });
    assert.equal(limited.statusCode, 429);
    assert.equal(limited.json().error, "rate_limited");
    assert.ok(Number(limited.headers["retry-after"]) > 0);
  });

  test("feedback: stores report and screenshot, admin can triage", async () => {
    const r = await app.inject({
      method: "POST", url: "/api/feedback", headers: game,
      payload: {
        session_id: SESSION, kind: "bug", text: "Fell through the floor near the Gasômetro",
        map: "gasometro", position: { x: 1.5, y: 0, z: -20 }, game_version: "0.9.0", os: "Windows 11",
        screenshot_png_base64: PNG_1x1.toString("base64"),
      },
    });
    assert.equal(r.statusCode, 201, r.body);
    const id = r.json().id as number;
    assert.ok(fs.existsSync(path.join(dataDir, "screenshots", `feedback-${id}.png`)));

    const notPng = await app.inject({
      method: "POST", url: "/api/feedback", headers: game,
      payload: { session_id: SESSION, kind: "idea", text: "x", game_version: "0.9.0", os: "Windows", screenshot_png_base64: "aGVsbG8=" },
    });
    assert.equal(notPng.statusCode, 400);
    assert.equal(notPng.json().error, "invalid_screenshot");

    const noAuth = await app.inject({ method: "PATCH", url: `/api/admin/feedback/${id}`, headers: game, payload: { status: "triaged" } });
    assert.equal(noAuth.statusCode, 401);

    const patch = await app.inject({ method: "PATCH", url: `/api/admin/feedback/${id}`, headers: admin, payload: { status: "triaged", note: "repro on map edge" } });
    assert.equal(patch.statusCode, 200, patch.body);
    assert.equal(patch.json().status, "triaged");
    assert.equal(patch.json().notes[0].note, "repro on map edge");
  });

  test("mods: upload is pending, rejects non-zip, published after approval", async () => {
    const fields = { name: "Lajeado Night", author: "Tchê", description: "Night sky", version: "1.0", game_version: "0.9.0", session_id: SESSION };

    const bad = multipart(fields, { name: "evil.zip", data: Buffer.from("MZ not a zip") });
    const rBad = await app.inject({ method: "POST", url: "/api/mods", headers: { ...game, ...bad.headers }, payload: bad.payload });
    assert.equal(rBad.statusCode, 415);
    assert.equal(rBad.json().error, "not_a_zip");

    const good = multipart(fields, { name: "night.zip", data: EMPTY_ZIP });
    const r = await app.inject({ method: "POST", url: "/api/mods", headers: { ...game, ...good.headers }, payload: good.payload });
    assert.equal(r.statusCode, 201, r.body);
    const { id, sha256 } = r.json();
    assert.equal(sha256, createHash("sha256").update(EMPTY_ZIP).digest("hex"));

    const listed = await app.inject({ method: "GET", url: "/api/mods", headers: game });
    assert.equal(listed.json().items.length, 0);
    assert.equal((await app.inject({ method: "GET", url: `/api/mods/${id}/download`, headers: game })).statusCode, 404);

    await app.inject({ method: "PATCH", url: `/api/admin/mods/${id}`, headers: admin, payload: { status: "published" } });

    const listed2 = await app.inject({ method: "GET", url: "/api/mods", headers: game });
    assert.equal(listed2.json().items.length, 1);
    assert.equal(listed2.json().items[0].ip, undefined);
    const dl = await app.inject({ method: "GET", url: `/api/mods/${id}/download`, headers: game });
    assert.equal(dl.statusCode, 200);
    assert.equal(dl.headers["content-type"], "application/zip");
    assert.deepEqual(dl.rawPayload, EMPTY_ZIP);
  });

  test("mcp: needs bearer, lists tools, returns stats and feedback with image", async () => {
    const rpc = (method: string, params: unknown, headers: Record<string, string> = admin) =>
      app.inject({
        method: "POST", url: "/mcp",
        headers: { ...headers, accept: "application/json, text/event-stream", "content-type": "application/json" },
        payload: { jsonrpc: "2.0", id: 1, method, params },
      });

    assert.equal((await rpc("tools/list", {}, game)).statusCode, 401);

    const init = await rpc("initialize", { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "test", version: "1" } });
    assert.equal(init.statusCode, 200, init.body);
    assert.equal(init.json().result.serverInfo.name, "city-invaders-api");

    const tools = await rpc("tools/list", {});
    const names = tools.json().result.tools.map((t: { name: string }) => t.name).sort();
    assert.deepEqual(names, [
      "get_conversation", "get_feedback", "get_mod", "list_conversations", "list_feedback",
      "list_mods", "set_mod_status", "stats", "update_feedback",
    ]);

    const stats = await rpc("tools/call", { name: "stats", arguments: {} });
    const s = JSON.parse(stats.json().result.content[0].text);
    assert.equal(s.tokens_today.input, 300);
    assert.equal(s.feedback_by_kind.bug, 1);

    const fb = await rpc("tools/call", { name: "get_feedback", arguments: { id: 1 } });
    const content = fb.json().result.content;
    assert.equal(content[1].type, "image");
    assert.equal(content[1].mimeType, "image/png");
  });
});
