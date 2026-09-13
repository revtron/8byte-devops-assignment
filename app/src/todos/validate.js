const TITLE_MAX = 200;

function checkTitle(title) {
  if (title === undefined || title === null) return { error: 'title is required' };
  if (typeof title !== 'string') return { error: 'title must be a string' };
  const trimmed = title.trim();
  if (trimmed.length === 0) return { error: 'title is required' };
  if (trimmed.length > TITLE_MAX) return { error: `title must be at most ${TITLE_MAX} characters` };
  return { value: trimmed };
}

function validateCreate(body) {
  const { error, value } = checkTitle(body && body.title);
  if (error) return { ok: false, errors: [error] };
  return { ok: true, value: { title: value } };
}

function validateUpdate(body) {
  const src = body || {};
  const hasTitle = src.title !== undefined;
  const hasDone = src.done !== undefined;
  if (!hasTitle && !hasDone) {
    return { ok: false, errors: ['at least one of title, done is required'] };
  }
  const errors = [];
  const value = {};
  if (hasTitle) {
    const { error, value: title } = checkTitle(src.title);
    if (error) errors.push(error);
    else value.title = title;
  }
  if (hasDone) {
    if (typeof src.done !== 'boolean') errors.push('done must be a boolean');
    else value.done = src.done;
  }
  if (errors.length) return { ok: false, errors };
  return { ok: true, value };
}

module.exports = { validateCreate, validateUpdate, TITLE_MAX };
