const request = require('supertest');
const pino = require('pino');
const { createApp } = require('../../src/app');

function fakeRepo() {
  let seq = 0;
  const items = new Map();
  return {
    items,
    list: jest.fn(async () => [...items.values()]),
    create: jest.fn(async ({ title }) => {
      const t = { id: ++seq, title, done: false, created_at: '2026-01-01T00:00:00.000Z' };
      items.set(t.id, t);
      return t;
    }),
    update: jest.fn(async (id, fields) => {
      const t = items.get(id);
      if (!t) return null;
      Object.assign(t, fields);
      return t;
    }),
    remove: jest.fn(async (id) => items.delete(id)),
  };
}

function build({ dbOk = true } = {}) {
  const repo = fakeRepo();
  const db = { ping: jest.fn(async () => { if (!dbOk) throw new Error('down'); }) };
  const config = { appEnv: 'test', version: 'v1', port: 0 };
  const log = pino({ level: 'silent' });
  return { app: createApp({ repo, db, config, log }), repo };
}

describe('GET /health', () => {
  test('200 when db is reachable', async () => {
    const { app } = build();
    const res = await request(app).get('/health');
    expect(res.status).toBe(200);
    expect(res.body).toEqual({ status: 'ok', env: 'test', version: 'v1', db: 'ok' });
  });
  test('503 when db ping fails', async () => {
    const { app } = build({ dbOk: false });
    const res = await request(app).get('/health');
    expect(res.status).toBe(503);
    expect(res.body).toEqual({ status: 'degraded', env: 'test', version: 'v1', db: 'error' });
  });
});

describe('GET /metrics', () => {
  test('serves prometheus metrics', async () => {
    const { app } = build();
    const res = await request(app).get('/metrics');
    expect(res.status).toBe(200);
    expect(res.text).toContain('http_requests_total');
  });
});

describe('/api/todos', () => {
  test('starts empty', async () => {
    const { app } = build();
    const res = await request(app).get('/api/todos');
    expect(res.status).toBe(200);
    expect(res.body).toEqual([]);
  });

  test('POST creates and returns 201', async () => {
    const { app } = build();
    const res = await request(app).post('/api/todos').send({ title: ' write tests ' });
    expect(res.status).toBe(201);
    expect(res.body).toMatchObject({ id: 1, title: 'write tests', done: false });
  });

  test('POST with invalid body returns 400 with errors', async () => {
    const { app } = build();
    const res = await request(app).post('/api/todos').send({ title: '' });
    expect(res.status).toBe(400);
    expect(res.body).toEqual({ errors: ['title is required'] });
  });

  test('PATCH updates done', async () => {
    const { app } = build();
    await request(app).post('/api/todos').send({ title: 'a' });
    const res = await request(app).patch('/api/todos/1').send({ done: true });
    expect(res.status).toBe(200);
    expect(res.body).toMatchObject({ id: 1, done: true });
  });

  test('PATCH unknown id returns 404', async () => {
    const { app } = build();
    const res = await request(app).patch('/api/todos/42').send({ done: true });
    expect(res.status).toBe(404);
    expect(res.body).toEqual({ error: 'not found' });
  });

  test('PATCH with non-numeric id returns 400', async () => {
    const { app } = build();
    const res = await request(app).patch('/api/todos/abc').send({ done: true });
    expect(res.status).toBe(400);
    expect(res.body).toEqual({ error: 'id must be a positive integer' });
  });

  test('DELETE removes and returns 204; second delete is 404', async () => {
    const { app } = build();
    await request(app).post('/api/todos').send({ title: 'a' });
    expect((await request(app).delete('/api/todos/1')).status).toBe(204);
    expect((await request(app).delete('/api/todos/1')).status).toBe(404);
  });

  test('unknown /api route returns JSON 404', async () => {
    const { app } = build();
    const res = await request(app).get('/api/nope');
    expect(res.status).toBe(404);
    expect(res.body).toEqual({ error: 'not found' });
  });

  test('repo failure returns JSON 500 without leaking details', async () => {
    const { app, repo } = build();
    repo.list.mockRejectedValueOnce(new Error('connection refused'));
    const res = await request(app).get('/api/todos');
    expect(res.status).toBe(500);
    expect(res.body).toEqual({ error: 'internal error' });
  });
});
