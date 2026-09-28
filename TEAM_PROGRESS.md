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

**Status:** Done
**Last updated:** Sep 6, 2026

- Donor self-registration, organization self-registration (starts "Pending"
  until an admin approves it), and admin-created internal staff accounts
  (CSWS, CMO, DRRMO, Barangay Rep) — all built on Castillo's
  password-hashing/`require_role()` foundation
- New: `api/v1/auth_router.py` (registration endpoints), `api/v1/admin_router.py`
  (admin-created accounts), `schemas/organization_schema.py`, `schemas/user_schema.py`
- Modified: `models/organization_model.py`, `models/user_rbac_model.py` to
  support the new registration fields
- Removed the old `api/v1/router.py` — routes now split across the new
  router files, so double-check everything is re-wired before merging
- Resolved environment issues (missing `python-jose`, wiped venv, stale DB
  password, missing `SECRET_KEY`) and confirmed registration/RBAC running
  end-to-end (200 OK)

**Note for the team:** touched `models/user_rbac_model.py`, which Ivan's
dashboard/report work also modified — diff this file carefully before merging.

---

---

## Mariquit — Module 2 (3.4, 3.11, 3.12) + Module 4 (3.7) + Module 6 (3.10)

### Done & tested (12/12 pytest passing)

- **3.4 Report Management**: full CRUD on disaster_reports, admin validate/reject
  with audit trail (validated_by, rejection_reason), SMS report ingestion
  (sms_report_metadata). Migrations applied to real Neon DB.
- **3.10 Delivery Tracking & Receipt Confirmation**: deliveries move through
  sequential statuses (Preparing → In Transit → Delivered), barangay confirms
  receipt (receipts table), which auto-recalculates the linked report's
  fulfillment_percentage/verification_status (report_fulfillments).
- Extended validate_report (3.4) to auto-create a report_fulfillments row,
  since 3.10/3.11 both depend on it existing.

- **3.7 Needs Monitoring**: added priority_level filter to GET /reports/,
  plus new GET /reports/monitoring endpoint joining disaster_reports with
  report_fulfillments (joinedload, avoids N+1) — returns fulfillment
  status/percentage/items alongside each report for staff/admin/barangay
  official roles.
- **3.11 AI-Assisted Priority Level Assignment**: rule-based scoring
  (core/priority_engine.py) triggered on report validation — factors in
  affected_families, estimated_quantity, disaster type severity, and
  current fulfillment status. Handles the manuscript's alt flows:
  insufficient data → "Needs Review", missing fulfillment record →
  scored as max unmet need, out-of-range score → "Review Required"
  safety fallback. Scoring weights/thresholds are a team-agreed rule,
  not manuscript-specified (manuscript intentionally leaves the formula
  open — see UC spec p.93-94).
### Still open / needs team input

- DisasterType stub currently only has 1 real row ("Flood") in the actual
  Neon DB — Typhoon/Fire/Earthquake severities in priority_engine.py's
  DISASTER_SEVERITY map are unreachable until whoever owns reference
  tables actually seeds those rows.
- Found a real mismatch: models/report.py's DisasterType stub maps the
  column as `name`, but the actual Postgres column is `type_name` — hasn't
  broken anything yet since nothing reads it, but will the moment code
  (like priority_engine.py) starts using report.disaster_type.name.
  Flagging for whoever owns reference/lookup tables.
  
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
