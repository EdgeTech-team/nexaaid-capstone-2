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

## Fernandez — Dashboard (3.13)
**Status:** In progress — core endpoints built, pending final verification
**Last updated:** Sep 6, 2026

- Read-only aggregation endpoints added: `/dashboard/summary`, `/reports`,
  `/donations`, `/fulfillment`, `/logistics`
- New minimal models added for tables nobody else had modeled yet:
  physical_donations, donation_confirmations, inventory, deliveries,
  logistics_requests, report_fulfillments (all use `extend_existing=True`
  as a safety net — if Hoyohoy/others build canonical models for these
  tables, swap to their import instead of mine, same way I did for
  DisasterReport)
- Reused real `DisasterReport` model from `models/report.py` — did NOT
  duplicate it
- Protected with `require_role("admin", "csws_staff", "barangay_official")`
  — matches the confirmed role strings used in reports.py
- No writes, no schema changes, no new dependencies

**Blocked on / needs team input:**
- reports.py has an "ASSUMPTION TO VERIFY" comment about role names — if
  that gets corrected, my `DASHBOARD_ROLES` tuple needs the same fix
- CMO and DRRMO role name strings are still unconfirmed (not found
  anywhere in the codebase yet) — dashboard currently doesn't grant them
  access since I don't want to guess wrong; easy one-line fix once
  someone confirms the real values from the `roles` table

**Still to do:**
- Run `uvicorn main:app --reload` and test all 5 endpoints against the
  test admin account
- Confirm empty-table case doesn't error (should return zeros)