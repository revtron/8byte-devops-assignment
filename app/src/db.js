const { Pool } = require('pg');

const SCHEMA = `
CREATE TABLE IF NOT EXISTS todos (
  id         SERIAL PRIMARY KEY,
  title      TEXT NOT NULL,
  done       BOOLEAN NOT NULL DEFAULT FALSE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);`;

function createDb(databaseUrl) {
  const pool = new Pool({ connectionString: databaseUrl, max: 5 });
  return {
    query: (text, params) => pool.query(text, params),
    ping: async () => { await pool.query('SELECT 1'); },
    init: async () => { await pool.query(SCHEMA); },
    close: () => pool.end(),
  };
}

module.exports = { createDb };
