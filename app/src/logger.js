const pino = require('pino');

const logger = pino({
  level: process.env.LOG_LEVEL || 'info',
  base: { service: 'todo-app', env: process.env.APP_ENV || 'dev' },
  timestamp: pino.stdTimeFunctions.isoTime,
});

module.exports = { logger };
