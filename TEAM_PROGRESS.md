# NexaAid — Team Progress Log

## Castillo — Foundation (3.1 + 3.2)
**Status:** Done, merged to develop
**Last updated:** Sep 3, 2026

- Neon Postgres connected (pooled + direct URLs configured)
- Real schema discovered mid-build — DB already had full production tables,
  models rewritten to match (User: user_id/password_hash, normalized Role
  via role_id, not an enum) 
- Alembic baselined safely (schema-drop near-miss caught before running)
- core/auth.py: JWT login, password hashing, require_role() dependency
- /health, /health/secure, throwaway /token all tested working end-to-end
- Test admin: testadmin@gmail.com / testpass123 (role: admin) — usable by
  anyone needing a logged-in user before real registration exists

**For the team:** see note below on real column names + role table before
building anything that touches `users`.

---

## Hoyohoy — Auth/Registration (3.3)
**Status:** Not started
**Last updated:** —

---

## Mariquit — CSWS Disaster Unit (3.7, 3.10)
**Status:** Not started
**Last updated:** —

---

## Fernandez — Dashboard
**Status:** —