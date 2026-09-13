(function () {
  const list = document.getElementById('list');
  const form = document.getElementById('add-form');
  const input = document.getElementById('title');
  const errorEl = document.getElementById('error');
  const countEl = document.getElementById('count');
  const badge = document.getElementById('badge');

  function showError(msg) {
    errorEl.textContent = msg;
    errorEl.hidden = !msg;
  }

  async function api(method, path, body) {
    const res = await fetch(path, {
      method,
      headers: body ? { 'content-type': 'application/json' } : {},
      body: body ? JSON.stringify(body) : undefined,
    });
    if (res.status === 204) return null;
    const data = await res.json().catch(() => ({}));
    if (!res.ok) throw new Error((data.errors && data.errors.join(', ')) || data.error || res.statusText);
    return data;
  }

  function render(todos) {
    list.innerHTML = '';
    todos.forEach((t) => {
      const li = document.createElement('li');
      li.className = 'item' + (t.done ? ' done' : '');
      const cb = document.createElement('input');
      cb.type = 'checkbox';
      cb.checked = t.done;
      cb.id = 'todo-' + t.id;
      cb.addEventListener('change', () => toggle(t.id, cb.checked));
      const label = document.createElement('label');
      label.htmlFor = cb.id;
      label.textContent = t.title;
      const del = document.createElement('button');
      del.type = 'button';
      del.textContent = '✕';
      del.title = 'Delete';
      del.addEventListener('click', () => remove(t.id));
      li.append(cb, label, del);
      list.appendChild(li);
    });
    countEl.textContent = todos.length + (todos.length === 1 ? ' item' : ' items');
  }

  async function refresh() {
    try {
      render(await api('GET', '/api/todos'));
      showError('');
    } catch (e) { showError('Could not load todos: ' + e.message); }
  }

  async function toggle(id, done) {
    try { await api('PATCH', '/api/todos/' + id, { done }); await refresh(); }
    catch (e) { showError(e.message); }
  }

  async function remove(id) {
    try { await api('DELETE', '/api/todos/' + id); await refresh(); }
    catch (e) { showError(e.message); }
  }

  form.addEventListener('submit', async (ev) => {
    ev.preventDefault();
    try {
      await api('POST', '/api/todos', { title: input.value });
      input.value = '';
      await refresh();
    } catch (e) { showError(e.message); }
  });

  fetch('/health').then((r) => r.json()).then((h) => {
    badge.textContent = h.env + ' · ' + h.version;
  }).catch(() => { badge.textContent = 'unknown'; });

  refresh();
})();
