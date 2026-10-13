// Application tier: Todo REST API with signup/login, backed by MySQL (RDS).
const express = require('express');
const cors = require('cors');
const mysql = require('mysql2/promise');
const bcrypt = require('bcryptjs');
const jwt = require('jsonwebtoken');
const os = require('os');

const PORT = process.env.PORT || 4000;
// Every app-tier instance must share the same secret so a token issued by
// one instance is accepted by the others behind the load balancer.
const JWT_SECRET = process.env.JWT_SECRET || 'dev-secret-change-me';
const DB_CONFIG = {
  host: process.env.DB_HOST || 'localhost',
  port: Number(process.env.DB_PORT || 3306),
  user: process.env.DB_USER || 'admin',
  password: process.env.DB_PASSWORD || 'password',
  database: process.env.DB_NAME || 'appdb',
  waitForConnections: true,
  connectionLimit: 10,
  connectTimeout: 5000,
};

const pool = mysql.createPool(DB_CONFIG);
const app = express();
app.use(cors());
app.use(express.json());

// Look up EC2 instance identity via IMDSv2 so the UI can show which
// app-tier instance / AZ served the request (useful for testing the ALB).
let instanceInfo = { instanceId: os.hostname(), az: 'local', privateIp: 'n/a' };
async function loadInstanceInfo() {
  const base = 'http://169.254.169.254/latest';
  try {
    const token = await (await fetch(`${base}/api/token`, {
      method: 'PUT',
      headers: { 'X-aws-ec2-metadata-token-ttl-seconds': '21600' },
      signal: AbortSignal.timeout(1000),
    })).text();
    const get = async (path) => (await fetch(`${base}/meta-data/${path}`, {
      headers: { 'X-aws-ec2-metadata-token': token },
      signal: AbortSignal.timeout(1000),
    })).text();
    instanceInfo = {
      instanceId: await get('instance-id'),
      az: await get('placement/availability-zone'),
      privateIp: await get('local-ipv4'),
    };
  } catch {
    // Not on EC2 (e.g. local docker) - keep hostname fallback.
  }
}

async function ensureSchema() {
  await pool.query(`
    CREATE TABLE IF NOT EXISTS users (
      id INT AUTO_INCREMENT PRIMARY KEY,
      name VARCHAR(100) NOT NULL,
      email VARCHAR(255) NOT NULL UNIQUE,
      password_hash VARCHAR(255) NOT NULL,
      created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
    )`);
  await pool.query(`
    CREATE TABLE IF NOT EXISTS todos (
      id INT AUTO_INCREMENT PRIMARY KEY,
      user_id INT NOT NULL,
      title VARCHAR(255) NOT NULL,
      completed BOOLEAN NOT NULL DEFAULT FALSE,
      created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
      CONSTRAINT fk_todos_user FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE,
      INDEX idx_todos_user (user_id)
    )`);
}

// Wrap async handlers so DB errors become 500 responses instead of crashes.
const handle = (fn) => (req, res) =>
  fn(req, res).catch((err) => {
    console.error(err);
    res.status(500).json({ error: 'Internal server error' });
  });

function issueToken(user) {
  return jwt.sign({ id: user.id, email: user.email, name: user.name }, JWT_SECRET, { expiresIn: '1d' });
}

function requireAuth(req, res, next) {
  const header = req.headers.authorization || '';
  const token = header.startsWith('Bearer ') ? header.slice(7) : null;
  if (!token) return res.status(401).json({ error: 'Not logged in' });
  try {
    req.user = jwt.verify(token, JWT_SECRET);
    next();
  } catch {
    res.status(401).json({ error: 'Session expired, please log in again' });
  }
}

// ---------- Health / infra ----------

// Lightweight health check for the internal ALB target group (no DB call,
// so an RDS outage doesn't take all app instances out of service).
app.get('/health', (req, res) => res.json({ status: 'ok' }));

// Full health: app + database connectivity.
app.get('/api/health', async (req, res) => {
  const result = { app: 'ok', database: 'unknown', server: instanceInfo };
  try {
    const [rows] = await pool.query('SELECT VERSION() AS version');
    result.database = 'ok';
    result.dbVersion = rows[0].version;
    result.dbHost = DB_CONFIG.host;
    res.json(result);
  } catch (err) {
    result.database = 'error';
    result.error = err.message;
    res.status(503).json(result);
  }
});

// ---------- Auth ----------

app.post('/api/auth/signup', handle(async (req, res) => {
  const name = (req.body.name || '').trim();
  const email = (req.body.email || '').trim().toLowerCase();
  const password = req.body.password || '';
  if (!name || !email || !password) return res.status(400).json({ error: 'Name, email and password are required' });
  if (!/^\S+@\S+\.\S+$/.test(email)) return res.status(400).json({ error: 'Invalid email address' });
  if (password.length < 6) return res.status(400).json({ error: 'Password must be at least 6 characters' });

  const hash = await bcrypt.hash(password, 10);
  try {
    const [result] = await pool.query(
      'INSERT INTO users (name, email, password_hash) VALUES (?, ?, ?)',
      [name, email, hash],
    );
    const user = { id: result.insertId, name, email };
    res.status(201).json({ token: issueToken(user), user });
  } catch (err) {
    if (err.code === 'ER_DUP_ENTRY') return res.status(409).json({ error: 'Email is already registered' });
    throw err;
  }
}));

app.post('/api/auth/login', handle(async (req, res) => {
  const email = (req.body.email || '').trim().toLowerCase();
  const password = req.body.password || '';
  const [rows] = await pool.query('SELECT * FROM users WHERE email = ?', [email]);
  const user = rows[0];
  if (!user || !(await bcrypt.compare(password, user.password_hash))) {
    return res.status(401).json({ error: 'Invalid email or password' });
  }
  const safeUser = { id: user.id, name: user.name, email: user.email };
  res.json({ token: issueToken(safeUser), user: safeUser });
}));

app.get('/api/auth/me', requireAuth, (req, res) => {
  res.json({ user: { id: req.user.id, name: req.user.name, email: req.user.email } });
});

// ---------- Todos (scoped to the logged-in user) ----------

app.get('/api/todos', requireAuth, handle(async (req, res) => {
  const [rows] = await pool.query(
    'SELECT id, title, completed, created_at FROM todos WHERE user_id = ? ORDER BY completed, id DESC',
    [req.user.id],
  );
  res.json(rows);
}));

app.post('/api/todos', requireAuth, handle(async (req, res) => {
  const title = (req.body.title || '').trim();
  if (!title) return res.status(400).json({ error: 'Title is required' });
  const [result] = await pool.query('INSERT INTO todos (user_id, title) VALUES (?, ?)', [req.user.id, title]);
  const [rows] = await pool.query('SELECT id, title, completed, created_at FROM todos WHERE id = ?', [result.insertId]);
  res.status(201).json(rows[0]);
}));

app.put('/api/todos/:id', requireAuth, handle(async (req, res) => {
  const fields = [];
  const values = [];
  if (typeof req.body.title === 'string' && req.body.title.trim()) {
    fields.push('title = ?');
    values.push(req.body.title.trim());
  }
  if (typeof req.body.completed === 'boolean') {
    fields.push('completed = ?');
    values.push(req.body.completed);
  }
  if (!fields.length) return res.status(400).json({ error: 'Nothing to update' });

  const [result] = await pool.query(
    `UPDATE todos SET ${fields.join(', ')} WHERE id = ? AND user_id = ?`,
    [...values, req.params.id, req.user.id],
  );
  if (!result.affectedRows) return res.status(404).json({ error: 'Todo not found' });
  const [rows] = await pool.query('SELECT id, title, completed, created_at FROM todos WHERE id = ?', [req.params.id]);
  res.json(rows[0]);
}));

app.delete('/api/todos/:id', requireAuth, handle(async (req, res) => {
  const [result] = await pool.query('DELETE FROM todos WHERE id = ? AND user_id = ?', [req.params.id, req.user.id]);
  if (!result.affectedRows) return res.status(404).json({ error: 'Todo not found' });
  res.status(204).end();
}));

app.listen(PORT, '0.0.0.0', async () => {
  console.log(`API listening on port ${PORT}, DB host ${DB_CONFIG.host}`);
  if (JWT_SECRET === 'dev-secret-change-me') console.warn('WARNING: using default JWT_SECRET');
  await loadInstanceInfo();
  // Retry schema creation so the API can start before the DB is reachable.
  for (let attempt = 1; attempt <= 10; attempt++) {
    try {
      await ensureSchema();
      console.log('Database schema ready');
      return;
    } catch (err) {
      console.error(`DB not ready (attempt ${attempt}): ${err.message}`);
      await new Promise((r) => setTimeout(r, 5000));
    }
  }
});
