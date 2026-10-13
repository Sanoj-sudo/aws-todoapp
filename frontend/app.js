// All API calls use a relative /api path. Nginx on the web tier proxies
// /api to the internal ALB in front of the app tier, so the browser never
// talks to the private subnets directly.
const API = '/api';

const $ = (id) => document.getElementById(id);
let todos = [];
let filter = 'all';

// ---------- API helper ----------

async function request(path, options = {}) {
  const token = localStorage.getItem('token');
  const res = await fetch(`${API}${path}`, {
    ...options,
    headers: {
      'Content-Type': 'application/json',
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
    },
  });
  if (res.status === 401 && token) {
    logout();
    throw new Error('Session expired, please log in again');
  }
  if (!res.ok) {
    const body = await res.json().catch(() => ({}));
    throw new Error(body.error || `Request failed (HTTP ${res.status})`);
  }
  return res.status === 204 ? null : res.json();
}

// ---------- Toasts ----------

function toast(message, type = 'success') {
  const el = document.createElement('div');
  el.className = `toast ${type}`;
  el.textContent = message;
  $('toasts').appendChild(el);
  setTimeout(() => {
    el.classList.add('hide');
    el.addEventListener('animationend', () => el.remove());
  }, 2600);
}

// ---------- Views ----------

function showAuth() {
  $('auth-view').classList.remove('hidden');
  $('todo-view').classList.add('hidden');
  $('user-bar').classList.add('hidden');
}

function showTodos(user) {
  $('auth-view').classList.add('hidden');
  $('todo-view').classList.remove('hidden');
  $('user-bar').classList.remove('hidden');
  $('user-name').textContent = user.name;
  $('user-avatar').textContent = user.name
    .split(/\s+/).filter(Boolean).slice(0, 2).map((w) => w[0].toUpperCase()).join('');

  const hour = new Date().getHours();
  const part = hour < 12 ? 'Good morning' : hour < 18 ? 'Good afternoon' : 'Good evening';
  $('greeting').textContent = `${part}, ${user.name.split(' ')[0]} 👋`;
  $('today').textContent = new Date().toLocaleDateString(undefined, { weekday: 'long', month: 'long', day: 'numeric' });
  loadTodos();
}

// ---------- Auth ----------

document.querySelectorAll('.tab').forEach((tab) => {
  tab.onclick = () => {
    const name = tab.dataset.tab;
    document.querySelectorAll('.tab').forEach((t) => t.classList.toggle('active', t === tab));
    document.querySelector('.tabs').dataset.active = name;
    $('login-form').classList.toggle('hidden', name !== 'login');
    $('signup-form').classList.toggle('hidden', name !== 'signup');
    $('auth-error').textContent = '';
  };
});

document.querySelectorAll('.toggle-pw').forEach((btn) => {
  btn.onclick = () => {
    const input = btn.parentElement.querySelector('input');
    const show = input.type === 'password';
    input.type = show ? 'text' : 'password';
    btn.textContent = show ? '🙈' : '👁';
    btn.setAttribute('aria-label', show ? 'Hide password' : 'Show password');
  };
});

async function authenticate(path, form) {
  $('auth-error').textContent = '';
  const button = form.querySelector('button[type=submit]');
  button.disabled = true;
  button.classList.add('loading');
  try {
    const data = await request(path, {
      method: 'POST',
      body: JSON.stringify(Object.fromEntries(new FormData(form))),
    });
    localStorage.setItem('token', data.token);
    localStorage.setItem('user', JSON.stringify(data.user));
    form.reset();
    showTodos(data.user);
    toast(path.endsWith('signup') ? 'Account created. Welcome! 🎉' : 'Logged in');
  } catch (err) {
    $('auth-error').textContent = err.message;
  } finally {
    button.disabled = false;
    button.classList.remove('loading');
  }
}

$('login-form').onsubmit = (e) => { e.preventDefault(); authenticate('/auth/login', e.target); };
$('signup-form').onsubmit = (e) => { e.preventDefault(); authenticate('/auth/signup', e.target); };

function logout() {
  localStorage.removeItem('token');
  localStorage.removeItem('user');
  todos = [];
  showAuth();
}
$('logout').onclick = () => { logout(); toast('Logged out'); };

// ---------- Todos ----------

async function loadTodos() {
  try {
    todos = await request('/todos');
    $('todo-error').textContent = '';
    renderTodos();
  } catch (err) {
    $('todo-error').textContent = err.message;
  }
  loadInfra();
}

function renderStats() {
  const total = todos.length;
  const done = todos.filter((t) => t.completed).length;
  const pct = total ? Math.round((done / total) * 100) : 0;
  $('stat-total').textContent = total;
  $('stat-active').textContent = total - done;
  $('stat-done').textContent = done;
  $('todo-count').textContent = `${total - done} task${total - done === 1 ? '' : 's'} left`;
  $('progress-text').textContent = `${pct}%`;
  $('ring-fg').style.strokeDashoffset = 264 - (264 * pct) / 100;
  $('progress-ring').classList.toggle('complete', total > 0 && pct === 100);
}

function emptyState() {
  const li = document.createElement('li');
  li.className = 'empty';
  const [icon, title, text] =
    !todos.length ? ['📝', 'No tasks yet', 'Add your first task above to get started.']
    : filter === 'active' ? ['🎉', 'All done!', 'You have no tasks left. Nice work.']
    : ['🌱', 'Nothing completed yet', 'Tick off a task and it will show up here.'];
  li.innerHTML = `<span class="empty-icon">${icon}</span><b>${title}</b>${text}`;
  return li;
}

function formatDate(value) {
  const d = new Date(value);
  return isNaN(d) ? '' : d.toLocaleDateString(undefined, { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' });
}

function renderTodos() {
  renderStats();
  const list = $('todo-list');
  list.innerHTML = '';
  const visible = todos.filter((t) =>
    filter === 'all' ? true : filter === 'active' ? !t.completed : !!t.completed);

  if (!visible.length) {
    list.appendChild(emptyState());
    return;
  }

  visible.forEach((todo, i) => {
    const li = document.createElement('li');
    li.className = 'todo' + (todo.completed ? ' done' : '');
    li.style.animationDelay = `${Math.min(i, 10) * 30}ms`;

    const check = document.createElement('label');
    check.className = 'check';
    const checkbox = document.createElement('input');
    checkbox.type = 'checkbox';
    checkbox.checked = !!todo.completed;
    checkbox.setAttribute('aria-label', 'Mark as done');
    checkbox.onchange = () => {
      updateTodo(todo.id, { completed: checkbox.checked });
      if (checkbox.checked) toast('Task completed ✔');
    };
    check.append(checkbox, document.createElement('span'));

    const body = document.createElement('div');
    body.className = 'todo-body';
    const title = document.createElement('span');
    title.className = 'title';
    title.textContent = todo.title;
    title.ondblclick = () => startEdit(body, title, todo);
    const date = document.createElement('span');
    date.className = 'date';
    date.textContent = formatDate(todo.created_at);
    body.append(title, date);

    const actions = document.createElement('div');
    actions.className = 'actions';
    const edit = document.createElement('button');
    edit.className = 'icon-btn';
    edit.textContent = '✎';
    edit.title = 'Edit';
    edit.onclick = () => startEdit(body, title, todo);
    const del = document.createElement('button');
    del.className = 'icon-btn danger';
    del.textContent = '🗑';
    del.title = 'Delete';
    del.onclick = () => deleteTodo(todo.id, li);
    actions.append(edit, del);

    li.append(check, body, actions);
    list.appendChild(li);
  });
}

function startEdit(body, titleEl, todo) {
  if (body.querySelector('.edit-input')) return;
  const input = document.createElement('input');
  input.className = 'edit-input';
  input.value = todo.title;
  input.maxLength = 255;
  body.replaceChild(input, titleEl);
  input.focus();
  input.select();

  let done = false;
  const finish = (save) => {
    if (done) return;
    done = true;
    const value = input.value.trim();
    if (save && value && value !== todo.title) updateTodo(todo.id, { title: value });
    else renderTodos();
  };
  input.onkeydown = (e) => {
    if (e.key === 'Enter') finish(true);
    if (e.key === 'Escape') finish(false);
  };
  input.onblur = () => finish(true);
}

async function updateTodo(id, changes) {
  try {
    const updated = await request(`/todos/${id}`, { method: 'PUT', body: JSON.stringify(changes) });
    todos = todos.map((t) => (t.id === id ? updated : t));
  } catch (err) {
    toast(err.message, 'error');
  }
  renderTodos();
}

async function deleteTodo(id, li) {
  try {
    await request(`/todos/${id}`, { method: 'DELETE' });
    todos = todos.filter((t) => t.id !== id);
    li.classList.add('removing');
    li.addEventListener('animationend', renderTodos, { once: true });
    toast('Task deleted');
  } catch (err) {
    toast(err.message, 'error');
  }
}

$('todo-form').onsubmit = async (e) => {
  e.preventDefault();
  const input = $('todo-title');
  const button = e.target.querySelector('button');
  button.disabled = true;
  try {
    const todo = await request('/todos', { method: 'POST', body: JSON.stringify({ title: input.value }) });
    todos.unshift(todo);
    input.value = '';
    if (filter === 'completed') document.querySelector('.filter[data-filter=all]').click();
    else renderTodos();
  } catch (err) {
    toast(err.message, 'error');
  } finally {
    button.disabled = false;
    input.focus();
  }
};

document.querySelectorAll('.filter').forEach((btn) => {
  btn.onclick = () => {
    filter = btn.dataset.filter;
    document.querySelectorAll('.filter').forEach((b) => b.classList.toggle('active', b === btn));
    renderTodos();
  };
});

// ---------- Infrastructure footer (which instance served each tier) ----------

function setInfra(tier, ok, text) {
  $(`infra-${tier}`).textContent = text;
  $(`dot-${tier}`).className = 'dot ' + (ok ? 'ok' : 'err');
}

async function loadInfra() {
  try {
    // web-info.json is written by the web-tier EC2 user-data script.
    const res = await fetch('web-info.json', { cache: 'no-store' });
    const web = await res.json();
    setInfra('web', true, `${web.instance} · ${web.az}`);
  } catch {
    setInfra('web', true, 'local');
  }
  try {
    const res = await fetch(`${API}/health`, { cache: 'no-store' });
    const data = await res.json();
    setInfra('app', true, `${data.server.instanceId} · ${data.server.az}`);
    if (data.database === 'ok') setInfra('db', true, `MySQL ${data.dbVersion}`);
    else setInfra('db', false, `error: ${data.error}`);
  } catch {
    setInfra('app', false, 'unreachable');
    setInfra('db', false, 'unknown');
  }
}

// ---------- Start ----------

const savedUser = localStorage.getItem('user');
if (localStorage.getItem('token') && savedUser) {
  showTodos(JSON.parse(savedUser));
} else {
  showAuth();
  loadInfra();
}
