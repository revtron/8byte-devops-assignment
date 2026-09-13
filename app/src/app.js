const path = require('path');
const express = require('express');
const pinoHttp = require('pino-http');
const { createMetrics } = require('./metrics');
const { createTodosRouter } = require('./todos/router');
const { logger } = require('./logger');

function createApp({ repo, db, config, log = logger }) {
  const app = express();
  const metrics = createMetrics({ env: config.appEnv });

  app.disable('x-powered-by');
  app.use(metrics.middleware);

  const httpLoggerOpts = {
    autoLogging: { ignore: (req) => req.url === '/health' || req.url === '/metrics' },
    customProps: () => ({ env: config.appEnv, version: config.version }),
  };
  // pino-http requires a real pino instance for `logger` (it calls `.child()`
  // and relies on pino internals like `.levels`). Test doubles for `log` are
  // plain objects, so only wire it through when it looks like a real pino
  // logger; otherwise let pino-http build its own (silenced) instance.
  if (log && typeof log.child === 'function' && log.levels) {
    httpLoggerOpts.logger = log;
  } else {
    httpLoggerOpts.level = 'silent';
  }
  app.use(pinoHttp(httpLoggerOpts));
  app.use(express.json({ limit: '10kb' }));

  app.get('/health', async (_req, res) => {
    let dbStatus = 'ok';
    try {
      await db.ping();
    } catch (err) {
      dbStatus = 'error';
      log.error({ err }, 'health check: database unreachable');
    }
    const ok = dbStatus === 'ok';
    res.status(ok ? 200 : 503).json({
      status: ok ? 'ok' : 'degraded',
      env: config.appEnv,
      version: config.version,
      db: dbStatus,
    });
  });

  app.get('/metrics', metrics.handler);
  app.use('/api/todos', createTodosRouter(repo));
  app.use('/api', (_req, res) => res.status(404).json({ error: 'not found' }));
  app.use(express.static(path.join(__dirname, '..', 'public')));

  app.use((err, req, res, _next) => {
    if (err.type === 'entity.parse.failed') {
      return res.status(400).json({ error: 'invalid JSON body' });
    }
    log.error({ err, url: req.url }, 'unhandled error');
    res.status(500).json({ error: 'internal error' });
  });

  return app;
}

module.exports = { createApp };
