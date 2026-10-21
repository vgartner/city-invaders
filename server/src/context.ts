import fs from "node:fs";
import path from "node:path";
import type { Config } from "./config.js";
import type { Repo } from "./db.js";
import type { BahLlm } from "./bah.js";
import { SlidingWindowLimiter } from "./ratelimit.js";

/** Everything the routes and the MCP tools share. */
export interface AppContext {
  cfg: Config;
  repo: Repo;
  /** null when no LLM_API_KEY is configured: chat answers 503. */
  llm: BahLlm | null;
  systemPrompt: string;
  limiters: {
    chatSession: SlidingWindowLimiter;
    chatIp: SlidingWindowLimiter;
    feedbackIp: SlidingWindowLimiter;
    modUploadIp: SlidingWindowLimiter;
  };
  dirs: { screenshots: string; mods: string; tmp: string };
}

export function makeLimiters(cfg: Config): AppContext["limiters"] {
  return {
    chatSession: new SlidingWindowLimiter(cfg.chatLimitPerSession, cfg.chatLimitWindowSec * 1000),
    chatIp: new SlidingWindowLimiter(cfg.chatLimitPerIp, cfg.chatLimitWindowSec * 1000),
    feedbackIp: new SlidingWindowLimiter(cfg.feedbackLimitPerIp, cfg.feedbackLimitWindowSec * 1000),
    modUploadIp: new SlidingWindowLimiter(cfg.modUploadLimitPerIp, cfg.modUploadLimitWindowSec * 1000),
  };
}

export function makeDirs(dataDir: string): AppContext["dirs"] {
  const dirs = {
    screenshots: path.join(dataDir, "screenshots"),
    mods: path.join(dataDir, "mods"),
    tmp: path.join(dataDir, "tmp"),
  };
  for (const d of Object.values(dirs)) fs.mkdirSync(d, { recursive: true });
  return dirs;
}
