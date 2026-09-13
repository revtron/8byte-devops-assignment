const COLUMNS = 'id, title, done, created_at';

function createRepo(db) {
  return {
    async list() {
      const { rows } = await db.query(`SELECT ${COLUMNS} FROM todos ORDER BY id`);
      return rows;
    },

    async create({ title }) {
      const { rows } = await db.query(
        `INSERT INTO todos (title) VALUES ($1) RETURNING ${COLUMNS}`,
        [title]
      );
      return rows[0];
    },

    async update(id, fields) {
      const sets = [];
      const params = [];
      for (const key of ['title', 'done']) {
        if (fields[key] !== undefined) {
          params.push(fields[key]);
          sets.push(`${key} = $${params.length}`);
        }
      }
      params.push(id);
      const { rows } = await db.query(
        `UPDATE todos SET ${sets.join(', ')} WHERE id = $${params.length} RETURNING ${COLUMNS}`,
        params
      );
      return rows[0] || null;
    },

    async remove(id) {
      const { rowCount } = await db.query('DELETE FROM todos WHERE id = $1 RETURNING id', [id]);
      return rowCount > 0;
    },
  };
}

module.exports = { createRepo };
