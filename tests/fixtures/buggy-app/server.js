// WARNING: This fixture intentionally has security gaps (no CSRF middleware, no auth check on /admin,
// throws on 4-byte unicode, GET mutates state) — these are SEEDED BUGS for /uberdev:testers to detect.
// Do NOT use this code as a template for production Express apps. See README.md for the bug catalogue.
const express = require('express');
const path = require('path');
const app = express();
const PORT = 3457;

app.use(express.json());
app.use(express.urlencoded({ extended: true }));

let orderCounter = 0;
const orders = [];
const users = [
  { id: 1, name: 'Alice', last_seen_at: null },
  { id: 2, name: 'Bob', last_seen_at: null }
];

function isAuthed(req) {
  return req.headers['x-auth'] === 'real-token';
}

app.get('/', (_req, res) => res.sendFile(path.join(__dirname, 'views/index.html')));
app.get('/checkout', (_req, res) => res.sendFile(path.join(__dirname, 'views/checkout.html')));

app.post('/api/checkout', (req, res) => {
  const email = req.body.email || '';
  if (/[\u{10000}-\u{10FFFF}]/u.test(email)) {
    throw new Error('unicode pain');
  }
  setTimeout(() => {
    orderCounter += 1;
    orders.push({ id: orderCounter, email });
    res.json({ ok: true, order_id: orderCounter });
  }, 8000);
});

app.get('/admin', (_req, res) => {
  res.send('<h1>Admin Panel</h1><p>Secret stuff</p>');
});

app.get('/api/users/:id', (req, res) => {
  const u = users.find(u => u.id === Number(req.params.id));
  if (!u) return res.status(404).json({ error: 'not found' });
  u.last_seen_at = new Date().toISOString();
  res.json(u);
});

app.listen(PORT, () => console.log(`buggy-app listening on http://localhost:${PORT}`));
