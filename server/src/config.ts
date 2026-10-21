import path from "node:path";

/** Runtime configuration, read once from the environment. */
export interface Config {
  port: number;
  host: string;
  /** Number of reverse-proxy hops to trust for X-Forwarded-For (nginx-proxy = 1). */
  trustProxyHops: number;
  logLevel: string;
  dataDir: string;
  dbPath: string;

  gameClientKey: string;
  adminToken: string;

  llmBaseUrl: string;
  llmApiKey: string;
  bahModel: string;
  bahMaxOutputTokens: number;
  bahHistoryTurns: number;
  bahMessageMaxChars: number;
  bahGameplayPath: string;
  bahFaqPath: string;
  /** Tokens (input + output, all sessions) Bah may spend per UTC day. 0 = unlimited. */
  bahDailyTokenBudget: number;

  chatLimitPerSession: number;
  chatLimitPerIp: number;
  chatLimitWindowSec: number;
  feedbackLimitPerIp: number;
  feedbackLimitWindowSec: number;
  modUploadLimitPerIp: number;
  modUploadLimitWindowSec: number;

  feedbackScreenshotMaxBytes: number;
  modMaxBytes: number;
}

function int(env: NodeJS.ProcessEnv, name: string, fallback: number): number {
  const raw = env[name];
  if (raw === undefined || raw.trim() === "") return fallback;
  const n = Number(raw);
  if (!Number.isFinite(n) || n < 0) throw new Error(`${name} must be a non-negative number, got "${raw}"`);
  return Math.floor(n);
}

function str(env: NodeJS.ProcessEnv, name: string, fallback: string): string {
  const raw = env[name];
  return raw === undefined || raw.trim() === "" ? fallback : raw.trim();
}

export function loadConfig(env: NodeJS.ProcessEnv = process.env): Config {
  const appRoot = process.cwd();
  const dataDir = path.resolve(str(env, "DATA_DIR", path.join(appRoot, "data")));
  const cfg: Config = {
    port: int(env, "PORT", 8080),
    host: str(env, "HOST", "0.0.0.0"),
    trustProxyHops: int(env, "TRUST_PROXY_HOPS", 1),
    logLevel: str(env, "LOG_LEVEL", "info"),
    dataDir,
    dbPath: path.resolve(str(env, "DB_PATH", path.join(dataDir, "city-invaders.db"))),

    gameClientKey: str(env, "GAME_CLIENT_KEY", ""),
    adminToken: str(env, "ADMIN_TOKEN", ""),

    llmBaseUrl: str(env, "LLM_BASE_URL", "https://openrouter.ai/api/v1").replace(/\/+$/, ""),
    llmApiKey: str(env, "LLM_API_KEY", ""),
    bahModel: str(env, "BAH_MODEL", "openai/gpt-4o-mini"),
    bahMaxOutputTokens: int(env, "BAH_MAX_OUTPUT_TOKENS", 400),
    bahHistoryTurns: int(env, "BAH_HISTORY_TURNS", 12),
    bahMessageMaxChars: int(env, "BAH_MESSAGE_MAX_CHARS", 500),
    bahGameplayPath: path.resolve(str(env, "BAH_GAMEPLAY_PATH", path.join(appRoot, "knowledge", "GAMEPLAY.md"))),
    bahFaqPath: path.resolve(str(env, "BAH_FAQ_PATH", path.join(appRoot, "knowledge", "bah_faq.json"))),
    bahDailyTokenBudget: int(env, "BAH_DAILY_TOKEN_BUDGET", 2_000_000),

    chatLimitPerSession: int(env, "CHAT_LIMIT_PER_SESSION", 20),
    chatLimitPerIp: int(env, "CHAT_LIMIT_PER_IP", 20),
    chatLimitWindowSec: int(env, "CHAT_LIMIT_WINDOW_SEC", 600),
    feedbackLimitPerIp: int(env, "FEEDBACK_LIMIT_PER_IP", 10),
    feedbackLimitWindowSec: int(env, "FEEDBACK_LIMIT_WINDOW_SEC", 3600),
    modUploadLimitPerIp: int(env, "MOD_UPLOAD_LIMIT_PER_IP", 5),
    modUploadLimitWindowSec: int(env, "MOD_UPLOAD_LIMIT_WINDOW_SEC", 3600),

    feedbackScreenshotMaxBytes: int(env, "FEEDBACK_SCREENSHOT_MAX_BYTES", 3 * 1024 * 1024),
    modMaxBytes: int(env, "MOD_MAX_BYTES", 25 * 1024 * 1024),
  };
  return cfg;
}

/** Fails fast in production when the secrets the service cannot work without are missing. */
export function assertProductionConfig(cfg: Config): void {
  const missing: string[] = [];
  if (!cfg.gameClientKey) missing.push("GAME_CLIENT_KEY");
  if (!cfg.adminToken) missing.push("ADMIN_TOKEN");
  if (missing.length) throw new Error(`Missing required environment variables: ${missing.join(", ")}`);
  if (cfg.adminToken.length < 24) throw new Error("ADMIN_TOKEN must be at least 24 characters");
}
