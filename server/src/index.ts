import { assertProductionConfig, loadConfig } from "./config.js";
import { buildApp } from "./app.js";

const cfg = loadConfig();
assertProductionConfig(cfg);

const { app } = await buildApp({ cfg });

const shutdown = async (signal: string) => {
  app.log.info({ signal }, "shutting down");
  await app.close();
  process.exit(0);
};
process.on("SIGTERM", () => void shutdown("SIGTERM"));
process.on("SIGINT", () => void shutdown("SIGINT"));

await app.listen({ port: cfg.port, host: cfg.host });
