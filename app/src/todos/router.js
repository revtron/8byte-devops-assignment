const express = require('express');
const { validateCreate, validateUpdate } = require('./validate');

function parseId(raw) {
  const id = Number(raw);
  return Number.isInteger(id) && id > 0 ? id : null;
}

function createTodosRouter(repo) {
  const router = express.Router();

  router.get('/', async (_req, res, next) => {
    try {
      res.json(await repo.list());
    } catch (err) { next(err); }
  });

  router.post('/', async (req, res, next) => {
    const v = validateCreate(req.body);
    if (!v.ok) return res.status(400).json({ errors: v.errors });
    try {
      res.status(201).json(await repo.create(v.value));
    } catch (err) { next(err); }
  });

  router.patch('/:id', async (req, res, next) => {
    const id = parseId(req.params.id);
    if (id === null) return res.status(400).json({ error: 'id must be a positive integer' });
    const v = validateUpdate(req.body);
    if (!v.ok) return res.status(400).json({ errors: v.errors });
    try {
      const row = await repo.update(id, v.value);
      if (!row) return res.status(404).json({ error: 'not found' });
      res.json(row);
    } catch (err) { next(err); }
  });

  router.delete('/:id', async (req, res, next) => {
    const id = parseId(req.params.id);
    if (id === null) return res.status(400).json({ error: 'id must be a positive integer' });
    try {
      const removed = await repo.remove(id);
      if (!removed) return res.status(404).json({ error: 'not found' });
      res.status(204).end();
    } catch (err) { next(err); }
  });

  return router;
}

module.exports = { createTodosRouter };
