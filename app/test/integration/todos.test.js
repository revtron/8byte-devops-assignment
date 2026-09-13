const request = require('supertest');
const { createDb } = require('../../src/db');
const { createRepo } = require('../../src/todos/repo');
const { createApp } = require('../../src/app');

const url = process.env.DATABASE_URL;
const describeIfDb = url ? describe : describe.skip;
if (!url) {
  // eslint-disable-next-line no-console
  console.log('DATABASE_URL not set — skipping integration tests');
}

describeIfDb('todos API against PostgreSQL', () => {
  let db; let app;

  beforeAll(async () => {
    db = createDb(url);
    await db.init();
    await db.query('TRUNCATE todos RESTART IDENTITY');
    const config = { appEnv: 'test', version: 'it', port: 0 };
    const log = { info() {}, error() {}, warn() {}, child() { return this; } };
    app = createApp({ repo: createRepo(db), db, config, log });
  });

  afterAll(async () => { await db.close(); });

  test('health reports db ok', async () => {
    const res = await request(app).get('/health');
    expect(res.status).toBe(200);
    expect(res.body.db).toBe('ok');
  });

  test('full CRUD round trip', async () => {
    const created = await request(app).post('/api/todos').send({ title: 'integration' });
    expect(created.status).toBe(201);
    const id = created.body.id;

    const list = await request(app).get('/api/todos');
    expect(list.body).toEqual([expect.objectContaining({ id, title: 'integration', done: false })]);

    const patched = await request(app).patch(`/api/todos/${id}`).send({ done: true, title: 'done!' });
    expect(patched.status).toBe(200);
    expect(patched.body).toMatchObject({ id, title: 'done!', done: true });

    expect((await request(app).delete(`/api/todos/${id}`)).status).toBe(204);
    expect((await request(app).get('/api/todos')).body).toEqual([]);
  });

  test('metrics reflect the requests made', async () => {
    const res = await request(app).get('/metrics');
    expect(res.text).toMatch(/http_requests_total\{method="POST",route="\/api\/todos\/",status="201",env="test"\}/);
  });
});
