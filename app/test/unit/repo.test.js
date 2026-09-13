const { createRepo } = require('../../src/todos/repo');

function fakeDb(rows = []) {
  const calls = [];
  return {
    calls,
    query: jest.fn(async (text, params) => {
      calls.push({ text, params });
      return { rows, rowCount: rows.length };
    }),
  };
}

describe('repo', () => {
  test('list selects ordered by id', async () => {
    const db = fakeDb([{ id: 1, title: 'a', done: false, created_at: 't' }]);
    const repo = createRepo(db);
    const rows = await repo.list();
    expect(rows).toHaveLength(1);
    expect(db.calls[0].text).toMatch(/SELECT .* FROM todos ORDER BY id/i);
  });

  test('create inserts and returns the row', async () => {
    const db = fakeDb([{ id: 5, title: 'x', done: false, created_at: 't' }]);
    const repo = createRepo(db);
    const row = await repo.create({ title: 'x' });
    expect(row.id).toBe(5);
    expect(db.calls[0].text).toMatch(/INSERT INTO todos/i);
    expect(db.calls[0].params).toEqual(['x']);
  });

  test('update builds SET clause only for provided fields', async () => {
    const db = fakeDb([{ id: 5, title: 'x', done: true, created_at: 't' }]);
    const repo = createRepo(db);
    await repo.update(5, { done: true });
    expect(db.calls[0].text).toMatch(/UPDATE todos SET done = \$1 WHERE id = \$2/i);
    expect(db.calls[0].params).toEqual([true, 5]);
  });

  test('update returns null when no row matched', async () => {
    const repo = createRepo(fakeDb([]));
    expect(await repo.update(99, { title: 'y' })).toBeNull();
  });

  test('remove returns true only when a row was deleted', async () => {
    expect(await createRepo(fakeDb([{ id: 1 }])).remove(1)).toBe(true);
    expect(await createRepo(fakeDb([])).remove(1)).toBe(false);
  });
});
