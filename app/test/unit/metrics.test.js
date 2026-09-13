const express = require('express');
const request = require('supertest');
const { createMetrics } = require('../../src/metrics');

function buildApp() {
  const metrics = createMetrics({ env: 'test' });
  const app = express();
  app.use(metrics.middleware);
  app.get('/hello/:name', (req, res) => res.json({ hi: req.params.name }));
  app.get('/boom', (_req, res) => res.status(500).end());
  app.get('/metrics', metrics.handler);
  return { app, metrics };
}

describe('metrics', () => {
  test('exposes prometheus text format with default metrics', async () => {
    const { app } = buildApp();
    const res = await request(app).get('/metrics');
    expect(res.status).toBe(200);
    expect(res.headers['content-type']).toMatch(/text\/plain/);
    expect(res.text).toContain('process_cpu_user_seconds_total');
  });

  test('counts requests with route template, status and env labels', async () => {
    const { app } = buildApp();
    await request(app).get('/hello/alice');
    await request(app).get('/hello/bob');
    await request(app).get('/boom');
    const res = await request(app).get('/metrics');
    expect(res.text).toMatch(
      /http_requests_total\{method="GET",route="\/hello\/:name",status="200",env="test"\} 2/
    );
    expect(res.text).toMatch(
      /http_requests_total\{method="GET",route="\/boom",status="500",env="test"\} 1/
    );
    expect(res.text).toContain('http_request_duration_seconds_bucket');
  });

  test('labels unmatched routes as "unmatched"', async () => {
    const { app } = buildApp();
    await request(app).get('/does-not-exist');
    const res = await request(app).get('/metrics');
    expect(res.text).toMatch(
      /http_requests_total\{method="GET",route="unmatched",status="404",env="test"\} 1/
    );
  });
});
