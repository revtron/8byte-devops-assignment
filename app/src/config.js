function loadConfig(env = process.env, { requireDb = false } = {}) {
  const port = env.PORT === undefined ? 3000 : Number(env.PORT);
  if (!Number.isInteger(port) || port <= 0) {
    throw new Error('PORT must be a number');
  }
  const databaseUrl = env.DATABASE_URL || undefined;
  if (requireDb && !databaseUrl) {
    throw new Error('DATABASE_URL is required');
  }
  return {
    port,
    appEnv: env.APP_ENV || 'dev',
    databaseUrl,
    version: env.APP_VERSION || 'dev',
  };
}

module.exports = { loadConfig };
