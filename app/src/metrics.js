const client = require('prom-client');

function createMetrics({ env }) {
  const register = new client.Registry();
  register.setDefaultLabels({ env });
  client.collectDefaultMetrics({ register });

  const requests = new client.Counter({
    name: 'http_requests_total',
    help: 'Total HTTP requests',
    labelNames: ['method', 'route', 'status', 'env'],
    registers: [register],
  });

  const duration = new client.Histogram({
    name: 'http_request_duration_seconds',
    help: 'HTTP request duration in seconds',
    labelNames: ['method', 'route', 'status', 'env'],
    buckets: [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5],
    registers: [register],
  });

  function routeLabel(req, res) {
    if (req.route && req.route.path) return (req.baseUrl || '') + req.route.path;
    if (res.statusCode === 404) return 'unmatched';
    return (req.baseUrl || '') + req.path;
  }

  function middleware(req, res, next) {
    const end = duration.startTimer();
    res.on('finish', () => {
      const labels = {
        method: req.method,
        route: routeLabel(req, res),
        status: String(res.statusCode),
        env,
      };
      requests.inc(labels);
      end(labels);
    });
    next();
  }

  async function handler(_req, res) {
    res.set('Content-Type', register.contentType);
    res.end(await register.metrics());
  }

  return { register, middleware, handler };
}

module.exports = { createMetrics };
