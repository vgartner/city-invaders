import Database from "better-sqlite3";
import fs from "node:fs";
import path from "node:path";
import { randomUUID } from "node:crypto";

export type Db = Database.Database;

export const FEEDBACK_KINDS = ["bug", "idea", "other"] as const;
export type FeedbackKind = (typeof FEEDBACK_KINDS)[number];
export const FEEDBACK_STATUSES = ["new", "triaged", "done", "wontfix"] as const;
export type FeedbackStatus = (typeof FEEDBACK_STATUSES)[number];
export const MOD_STATUSES = ["pending", "published", "rejected"] as const;
export type ModStatus = (typeof MOD_STATUSES)[number];

const SCHEMA = `
CREATE TABLE IF NOT EXISTS sessions (
  id          TEXT PRIMARY KEY,
  first_seen  TEXT NOT NULL,
  last_seen   TEXT NOT NULL,
  last_ip     TEXT
);

CREATE TABLE IF NOT EXISTS conversations (
  id          TEXT PRIMARY KEY,
  session_id  TEXT NOT NULL REFERENCES sessions(id),
  lang        TEXT,
  created_at  TEXT NOT NULL,
  updated_at  TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS conversations_session ON conversations(session_id, updated_at);
CREATE INDEX IF NOT EXISTS conversations_updated ON conversations(updated_at);

CREATE TABLE IF NOT EXISTS messages (
  id                  INTEGER PRIMARY KEY AUTOINCREMENT,
  conversation_id     TEXT NOT NULL REFERENCES conversations(id),
  role                TEXT NOT NULL CHECK (role IN ('user', 'assistant')),
  content             TEXT NOT NULL,
  context_json        TEXT,
  model               TEXT,
  input_tokens        INTEGER NOT NULL DEFAULT 0,
  output_tokens       INTEGER NOT NULL DEFAULT 0,
  cache_read_tokens   INTEGER NOT NULL DEFAULT 0,
  cache_write_tokens  INTEGER NOT NULL DEFAULT 0,
  ip                  TEXT,
  created_at          TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS messages_conversation ON messages(conversation_id, id);
CREATE INDEX IF NOT EXISTS messages_created ON messages(created_at);

CREATE TABLE IF NOT EXISTS feedback (
  id               INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id       TEXT NOT NULL,
  kind             TEXT NOT NULL CHECK (kind IN ('bug', 'idea', 'other')),
  text             TEXT NOT NULL,
  map              TEXT,
  position_json    TEXT,
  game_version     TEXT NOT NULL,
  os               TEXT NOT NULL,
  screenshot_file  TEXT,
  status           TEXT NOT NULL DEFAULT 'new' CHECK (status IN ('new', 'triaged', 'done', 'wontfix')),
  ip               TEXT,
  created_at       TEXT NOT NULL,
  updated_at       TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS feedback_status ON feedback(status, id);

CREATE TABLE IF NOT EXISTS feedback_notes (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  feedback_id  INTEGER NOT NULL REFERENCES feedback(id),
  status       TEXT NOT NULL,
  note         TEXT,
  created_at   TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS feedback_notes_feedback ON feedback_notes(feedback_id, id);

CREATE TABLE IF NOT EXISTS mods (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  name          TEXT NOT NULL,
  author        TEXT NOT NULL,
  description   TEXT NOT NULL DEFAULT '',
  version       TEXT NOT NULL,
  game_version  TEXT NOT NULL,
  session_id    TEXT NOT NULL,
  file          TEXT NOT NULL,
  size_bytes    INTEGER NOT NULL,
  sha256        TEXT NOT NULL,
  status        TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'published', 'rejected')),
  downloads     INTEGER NOT NULL DEFAULT 0,
  ip            TEXT,
  created_at    TEXT NOT NULL,
  updated_at    TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS mods_status ON mods(status, id);
`;

export function openDb(dbPath: string): Db {
  if (dbPath !== ":memory:") fs.mkdirSync(path.dirname(dbPath), { recursive: true });
  const db = new Database(dbPath);
  db.pragma("journal_mode = WAL");
  db.pragma("foreign_keys = ON");
  db.pragma("busy_timeout = 5000");
  db.exec(SCHEMA);
  return db;
}

const now = (): string => new Date().toISOString();

/** Start of the current UTC day as an ISO string (timestamps are stored as ISO UTC). */
export function utcDayStart(d = new Date()): string {
  return new Date(Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate())).toISOString();
}

// ---------------------------------------------------------------------------
// Bah conversations
// ---------------------------------------------------------------------------

export interface ConversationRow {
  id: string;
  session_id: string;
  lang: string | null;
  created_at: string;
  updated_at: string;
}

export interface MessageRow {
  id: number;
  conversation_id: string;
  role: "user" | "assistant";
  content: string;
  context_json: string | null;
  model: string | null;
  input_tokens: number;
  output_tokens: number;
  cache_read_tokens: number;
  cache_write_tokens: number;
  ip: string | null;
  created_at: string;
}

export interface Usage {
  model: string;
  inputTokens: number;
  outputTokens: number;
  cacheReadTokens: number;
  cacheWriteTokens: number;
}

export class Repo {
  constructor(readonly db: Db) {}

  touchSession(sessionId: string, ip: string | null): void {
    const t = now();
    this.db
      .prepare(
        `INSERT INTO sessions (id, first_seen, last_seen, last_ip) VALUES (?, ?, ?, ?)
         ON CONFLICT(id) DO UPDATE SET last_seen = excluded.last_seen, last_ip = excluded.last_ip`,
      )
      .run(sessionId, t, t, ip);
  }

  getConversation(id: string): ConversationRow | undefined {
    return this.db.prepare(`SELECT * FROM conversations WHERE id = ?`).get(id) as ConversationRow | undefined;
  }

  /** The session's most recent conversation if it was active after `since`. */
  latestConversation(sessionId: string, since: string): ConversationRow | undefined {
    return this.db
      .prepare(
        `SELECT * FROM conversations WHERE session_id = ? AND updated_at >= ? ORDER BY updated_at DESC LIMIT 1`,
      )
      .get(sessionId, since) as ConversationRow | undefined;
  }

  createConversation(sessionId: string, lang: string | null): ConversationRow {
    const t = now();
    const row: ConversationRow = { id: randomUUID(), session_id: sessionId, lang, created_at: t, updated_at: t };
    this.db
      .prepare(`INSERT INTO conversations (id, session_id, lang, created_at, updated_at) VALUES (?, ?, ?, ?, ?)`)
      .run(row.id, row.session_id, row.lang, row.created_at, row.updated_at);
    return row;
  }

  /** Last `limit` messages of a conversation, oldest first. */
  recentMessages(conversationId: string, limit: number): MessageRow[] {
    const rows = this.db
      .prepare(`SELECT * FROM messages WHERE conversation_id = ? ORDER BY id DESC LIMIT ?`)
      .all(conversationId, limit) as MessageRow[];
    return rows.reverse();
  }

  allMessages(conversationId: string): MessageRow[] {
    return this.db
      .prepare(`SELECT * FROM messages WHERE conversation_id = ? ORDER BY id`)
      .all(conversationId) as MessageRow[];
  }

  /** Stores one user/assistant exchange atomically. */
  addExchange(args: {
    conversationId: string;
    userText: string;
    contextJson: string | null;
    assistantText: string;
    usage: Usage;
    ip: string | null;
  }): void {
    const insert = this.db.prepare(
      `INSERT INTO messages (conversation_id, role, content, context_json, model, input_tokens, output_tokens,
                             cache_read_tokens, cache_write_tokens, ip, created_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
    );
    const tx = this.db.transaction(() => {
      const t = now();
      insert.run(args.conversationId, "user", args.userText, args.contextJson, null, 0, 0, 0, 0, args.ip, t);
      const u = args.usage;
      insert.run(
        args.conversationId, "assistant", args.assistantText, null, u.model,
        u.inputTokens, u.outputTokens, u.cacheReadTokens, u.cacheWriteTokens, null, now(),
      );
      this.db.prepare(`UPDATE conversations SET updated_at = ? WHERE id = ?`).run(now(), args.conversationId);
    });
    tx();
  }

  /**
   * Tokens used since `since`. `budget` is what the daily budget counts: input + output +
   * cache writes + a tenth of cache reads (cache reads are billed at ~10% of input).
   */
  tokensSince(since: string): { input: number; output: number; cacheRead: number; cacheWrite: number; budget: number } {
    const r = this.db
      .prepare(
        `SELECT COALESCE(SUM(input_tokens),0) AS input, COALESCE(SUM(output_tokens),0) AS output,
                COALESCE(SUM(cache_read_tokens),0) AS cacheRead, COALESCE(SUM(cache_write_tokens),0) AS cacheWrite
         FROM messages WHERE created_at >= ?`,
      )
      .get(since) as { input: number; output: number; cacheRead: number; cacheWrite: number };
    return { ...r, budget: r.input + r.output + r.cacheWrite + Math.ceil(r.cacheRead / 10) };
  }

  listConversations(limit: number, since?: string) {
    return this.db
      .prepare(
        `SELECT c.id, c.session_id, c.lang, c.created_at, c.updated_at,
                COUNT(m.id) AS message_count,
                COALESCE(SUM(m.input_tokens + m.output_tokens), 0) AS tokens,
                (SELECT content FROM messages WHERE conversation_id = c.id AND role = 'user' ORDER BY id LIMIT 1) AS first_message
         FROM conversations c LEFT JOIN messages m ON m.conversation_id = c.id
         WHERE c.updated_at >= ?
         GROUP BY c.id ORDER BY c.updated_at DESC LIMIT ?`,
      )
      .all(since ?? "", limit);
  }

  // -------------------------------------------------------------------------
  // Feedback
  // -------------------------------------------------------------------------

  insertFeedback(f: {
    sessionId: string;
    kind: FeedbackKind;
    text: string;
    map: string | null;
    positionJson: string | null;
    gameVersion: string;
    os: string;
    ip: string | null;
  }): number {
    const t = now();
    const r = this.db
      .prepare(
        `INSERT INTO feedback (session_id, kind, text, map, position_json, game_version, os, ip, created_at, updated_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      )
      .run(f.sessionId, f.kind, f.text, f.map, f.positionJson, f.gameVersion, f.os, f.ip, t, t);
    return Number(r.lastInsertRowid);
  }

  setFeedbackScreenshot(id: number, file: string): void {
    this.db.prepare(`UPDATE feedback SET screenshot_file = ? WHERE id = ?`).run(file, id);
  }

  getFeedback(id: number) {
    const row = this.db.prepare(`SELECT * FROM feedback WHERE id = ?`).get(id) as FeedbackRow | undefined;
    if (!row) return undefined;
    const notes = this.db
      .prepare(`SELECT status, note, created_at FROM feedback_notes WHERE feedback_id = ? ORDER BY id`)
      .all(id) as { status: string; note: string | null; created_at: string }[];
    return { ...row, notes };
  }

  listFeedback(opts: { status?: FeedbackStatus; kind?: FeedbackKind; limit: number }): FeedbackRow[] {
    const where: string[] = [];
    const params: unknown[] = [];
    if (opts.status) { where.push("status = ?"); params.push(opts.status); }
    if (opts.kind) { where.push("kind = ?"); params.push(opts.kind); }
    const sql = `SELECT * FROM feedback ${where.length ? "WHERE " + where.join(" AND ") : ""} ORDER BY id DESC LIMIT ?`;
    return this.db.prepare(sql).all(...params, opts.limit) as FeedbackRow[];
  }

  updateFeedback(id: number, status: FeedbackStatus, note: string | null): boolean {
    const tx = this.db.transaction(() => {
      const t = now();
      const r = this.db.prepare(`UPDATE feedback SET status = ?, updated_at = ? WHERE id = ?`).run(status, t, id);
      if (r.changes === 0) return false;
      this.db
        .prepare(`INSERT INTO feedback_notes (feedback_id, status, note, created_at) VALUES (?, ?, ?, ?)`)
        .run(id, status, note, t);
      return true;
    });
    return tx();
  }

  // -------------------------------------------------------------------------
  // Mods
  // -------------------------------------------------------------------------

  insertMod(m: {
    name: string;
    author: string;
    description: string;
    version: string;
    gameVersion: string;
    sessionId: string;
    file: string;
    sizeBytes: number;
    sha256: string;
    ip: string | null;
  }): number {
    const t = now();
    const r = this.db
      .prepare(
        `INSERT INTO mods (name, author, description, version, game_version, session_id, file, size_bytes, sha256, ip, created_at, updated_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      )
      .run(m.name, m.author, m.description, m.version, m.gameVersion, m.sessionId, m.file, m.sizeBytes, m.sha256, m.ip, t, t);
    return Number(r.lastInsertRowid);
  }

  getMod(id: number): ModRow | undefined {
    return this.db.prepare(`SELECT * FROM mods WHERE id = ?`).get(id) as ModRow | undefined;
  }

  listMods(opts: { status?: ModStatus; limit: number }): ModRow[] {
    if (opts.status) {
      return this.db.prepare(`SELECT * FROM mods WHERE status = ? ORDER BY id DESC LIMIT ?`).all(opts.status, opts.limit) as ModRow[];
    }
    return this.db.prepare(`SELECT * FROM mods ORDER BY id DESC LIMIT ?`).all(opts.limit) as ModRow[];
  }

  setModStatus(id: number, status: ModStatus): boolean {
    return this.db.prepare(`UPDATE mods SET status = ?, updated_at = ? WHERE id = ?`).run(status, now(), id).changes > 0;
  }

  countModDownload(id: number): void {
    this.db.prepare(`UPDATE mods SET downloads = downloads + 1 WHERE id = ?`).run(id);
  }

  // -------------------------------------------------------------------------
  // Stats
  // -------------------------------------------------------------------------

  stats() {
    const count = (sql: string, ...p: unknown[]) => (this.db.prepare(sql).get(...p) as { n: number }).n;
    const group = (sql: string) =>
      Object.fromEntries((this.db.prepare(sql).all() as { k: string; n: number }[]).map((r) => [r.k, r.n]));
    const today = utcDayStart();
    return {
      sessions: count(`SELECT COUNT(*) AS n FROM sessions`),
      conversations: count(`SELECT COUNT(*) AS n FROM conversations`),
      messages: count(`SELECT COUNT(*) AS n FROM messages`),
      messages_today: count(`SELECT COUNT(*) AS n FROM messages WHERE created_at >= ?`, today),
      feedback_by_status: group(`SELECT status AS k, COUNT(*) AS n FROM feedback GROUP BY status`),
      feedback_by_kind: group(`SELECT kind AS k, COUNT(*) AS n FROM feedback GROUP BY kind`),
      mods_by_status: group(`SELECT status AS k, COUNT(*) AS n FROM mods GROUP BY status`),
      mod_downloads: count(`SELECT COALESCE(SUM(downloads),0) AS n FROM mods`),
      tokens_today: this.tokensSince(today),
    };
  }
}

export interface FeedbackRow {
  id: number;
  session_id: string;
  kind: FeedbackKind;
  text: string;
  map: string | null;
  position_json: string | null;
  game_version: string;
  os: string;
  screenshot_file: string | null;
  status: FeedbackStatus;
  ip: string | null;
  created_at: string;
  updated_at: string;
}

export interface ModRow {
  id: number;
  name: string;
  author: string;
  description: string;
  version: string;
  game_version: string;
  session_id: string;
  file: string;
  size_bytes: number;
  sha256: string;
  status: ModStatus;
  downloads: number;
  ip: string | null;
  created_at: string;
  updated_at: string;
}

/** Public view of a mod (no IP, session or storage path). */
export function publicMod(m: ModRow) {
  return {
    id: m.id,
    name: m.name,
    author: m.author,
    description: m.description,
    version: m.version,
    game_version: m.game_version,
    size_bytes: m.size_bytes,
    sha256: m.sha256,
    downloads: m.downloads,
    created_at: m.created_at,
    updated_at: m.updated_at,
  };
}
