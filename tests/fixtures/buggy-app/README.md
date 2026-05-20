# buggy-app — seeded-bug fixture for /uberdev:testers manual e2e validation

Run: `cd tests/fixtures/buggy-app && npm install && npm start` → http://localhost:3457

## Seeded bugs

1. **B1 — Double-click on /checkout submit creates duplicate orders** (violates `idempotent_submit`)
2. **B2 — Logged-out user can reach /admin via direct URL** (violates `auth_isolation`)
3. **B3 — /api/checkout returns 500 when payload contains 4-byte unicode** (violates `no_5xx`)
4. **B4 — Spinner on /checkout never clears if /api/checkout exceeds 5s** (violates `no_unbounded_loading`)
5. **B5 — Tab order skips the Cancel button in the /checkout modal** (violates `keyboard_complete`)
6. **B6 — GET /api/users/:id mutates state (sets last_seen_at)** (violates `idempotent_get`)

Validation target: squad should find ≥5 of these 6 in a single run with zero blocker-severity false positives.
