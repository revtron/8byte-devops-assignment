const { loadConfig } = require('./config');
const { logger } = require('./logger');
const { createDb } = require('./db');
const { createRepo } = require('./todos/repo');
const { createApp } = require('./app');

async function main() {
  const config = loadConfig(process.env, { requireDb: true });
  const db = createDb(config.databaseUrl);
  await db.init();

  const app = createApp({ repo: createRepo(db), db, config, log: logger });
  const server = app.listen(config.port, () => {
    logger.info({ port: config.port, env: config.appEnv, version: config.version }, 'todo-app listening');
  });

  const shutdown = (signal) => {
    logger.info({ signal }, 'shutting down');
    server.close(async () => {
      await db.close();
      process.exit(0);
    });
    setTimeout(() => process.exit(1), 10000).unref();
  };
  process.on('SIGTERM', () => shutdown('SIGTERM'));
  process.on('SIGINT', () => shutdown('SIGINT'));
}

main().catch((err) => {
  logger.error({ err }, 'failed to start');
  process.exit(1);
});
