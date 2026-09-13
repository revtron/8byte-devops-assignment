const { validateCreate, validateUpdate, TITLE_MAX } = require('../../src/todos/validate');

describe('validateCreate', () => {
  test('accepts a trimmed non-empty title', () => {
    expect(validateCreate({ title: '  buy milk ' })).toEqual({ ok: true, value: { title: 'buy milk' } });
  });
  test('rejects missing body', () => {
    expect(validateCreate(undefined)).toEqual({ ok: false, errors: ['title is required'] });
  });
  test('rejects empty or whitespace title', () => {
    expect(validateCreate({ title: '   ' })).toEqual({ ok: false, errors: ['title is required'] });
  });
  test('rejects non-string title', () => {
    expect(validateCreate({ title: 42 })).toEqual({ ok: false, errors: ['title must be a string'] });
  });
  test('rejects title longer than TITLE_MAX', () => {
    const r = validateCreate({ title: 'x'.repeat(TITLE_MAX + 1) });
    expect(r).toEqual({ ok: false, errors: [`title must be at most ${TITLE_MAX} characters`] });
  });
});

describe('validateUpdate', () => {
  test('accepts done only', () => {
    expect(validateUpdate({ done: true })).toEqual({ ok: true, value: { done: true } });
  });
  test('accepts title only', () => {
    expect(validateUpdate({ title: 'new' })).toEqual({ ok: true, value: { title: 'new' } });
  });
  test('accepts both', () => {
    expect(validateUpdate({ title: 'new', done: false })).toEqual({ ok: true, value: { title: 'new', done: false } });
  });
  test('rejects empty update', () => {
    expect(validateUpdate({})).toEqual({ ok: false, errors: ['at least one of title, done is required'] });
  });
  test('rejects non-boolean done', () => {
    expect(validateUpdate({ done: 'yes' })).toEqual({ ok: false, errors: ['done must be a boolean'] });
  });
  test('rejects blank title', () => {
    expect(validateUpdate({ title: ' ' })).toEqual({ ok: false, errors: ['title is required'] });
  });
});
